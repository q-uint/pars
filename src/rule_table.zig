const std = @import("std");
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;

/// Maps rule names to numeric indices and stores compiled chunks in a
/// flat array for direct-index dispatch. The name map is used at
/// compile time; at runtime op_call uses the index to jump straight
/// to the chunk without a hash lookup.
/// Per-rule attribute flags set by the compiler from `#[...]`
/// declarations and read by the VM to select runtime behavior. New
/// attributes (e.g. `#[memo]`, `#[trace]`) are added here as new
/// fields, which keeps the compiler/VM interface stable: neither has
/// to grow an extra function parameter per attribute.
pub const RuleAttrs = packed struct {
    /// Direct left recursion via Warth's seed-growing algorithm
    /// (ADR 010). When false, the VM reports left recursion as a
    /// runtime error; when true, it grows a per-call seed instead.
    lr: bool = false,
};

pub const RuleTable = struct {
    by_name: std.StringHashMapUnmanaged(u32) = .empty,
    chunks: std.ArrayListUnmanaged(?Chunk) = .empty,
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    // Parallel to `chunks`: attribute flags declared on the rule.
    // Default-initialized on first reference; set by the compiler
    // when the rule declaration carries `#[...]` annotations.
    attrs: std.ArrayListUnmanaged(RuleAttrs) = .empty,

    /// Return the index for `name`, allocating a new slot if this is
    /// the first reference. Forward references get a null chunk that
    /// ruleDeclaration fills in later.
    pub fn getOrCreateIndex(self: *RuleTable, alloc: std.mem.Allocator, name: []const u8) !u32 {
        const gop = try self.by_name.getOrPut(alloc, name);
        if (!gop.found_existing) {
            const idx: u32 = @intCast(self.chunks.items.len);
            gop.value_ptr.* = idx;
            try self.chunks.append(alloc, null);
            try self.names.append(alloc, name);
            try self.attrs.append(alloc, .{});
        }
        return gop.value_ptr.*;
    }

    pub fn setChunk(self: *RuleTable, index: u32, c: Chunk) void {
        if (self.chunks.items[index]) |*old| old.deinit();
        self.chunks.items[index] = c;
    }

    pub fn getChunkPtr(self: *RuleTable, index: u32) ?*Chunk {
        if (self.chunks.items[index]) |*c| return c;
        return null;
    }

    pub fn setAttrs(self: *RuleTable, index: u32, a: RuleAttrs) void {
        self.attrs.items[index] = a;
    }

    pub fn getAttrs(self: *const RuleTable, index: u32) RuleAttrs {
        return self.attrs.items[index];
    }

    pub fn count(self: *const RuleTable) usize {
        return self.by_name.count();
    }

    pub fn get(self: *const RuleTable, name: []const u8) ?u32 {
        return self.by_name.get(name);
    }

    pub fn deinit(self: *RuleTable, alloc: std.mem.Allocator) void {
        for (self.chunks.items) |*slot| {
            if (slot.*) |*c| c.deinit();
        }
        self.chunks.deinit(alloc);
        self.names.deinit(alloc);
        self.attrs.deinit(alloc);
        self.by_name.deinit(alloc);
    }
};
