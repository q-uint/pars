const std = @import("std");

/// Object type tag. Every heap-allocated object carries one of these so
/// the VM can dispatch on it without knowing the concrete payload.
pub const ObjType = enum {
    literal,
    charset,
};

/// A heap-allocated object tracked by the VM for lifetime management.
/// All Objs form a singly-linked intrusive list so the VM can walk every
/// live allocation at shutdown (and eventually during garbage collection).
pub const Obj = struct {
    obj_type: ObjType,
    next: ?*Obj,

    pub fn asLiteral(self: *Obj) *ObjLiteral {
        std.debug.assert(self.obj_type == .literal);
        return @fieldParentPtr("obj", self);
    }

    pub fn asCharset(self: *Obj) *ObjCharset {
        std.debug.assert(self.obj_type == .charset);
        return @fieldParentPtr("obj", self);
    }
};

/// A heap-allocated, owned byte sequence used for literal string matching.
/// The header and character data live in a single contiguous allocation
/// (flexible array member pattern): the `len` bytes of character data
/// follow the struct in memory. Use `chars()` to obtain a slice over them.
pub const ObjLiteral = struct {
    obj: Obj,
    len: usize,

    /// Return the character data that trails this header in memory.
    pub fn chars(self: *ObjLiteral) []u8 {
        const base: [*]u8 = @ptrCast(self);
        return base[@sizeOf(ObjLiteral)..][0..self.len];
    }

    pub fn asObj(self: *ObjLiteral) *Obj {
        return &self.obj;
    }
};

/// A 256-bit bitvector representing a character set. Each bit corresponds
/// to a byte value 0-255; a set bit means that byte is a member. This
/// fixed-size representation makes charset membership a single array
/// lookup and bit test.
pub const ObjCharset = struct {
    obj: Obj,
    bits: [32]u8,

    pub fn contains(self: *const ObjCharset, byte: u8) bool {
        return (self.bits[byte >> 3] & (@as(u8, 1) << @intCast(byte & 0x07))) != 0;
    }

    pub fn asObj(self: *ObjCharset) *Obj {
        return &self.obj;
    }
};

// Module-global object list and allocator. The VM initialises these
// before compilation and takes ownership of the list at shutdown.
var objects: ?*Obj = null;
var obj_allocator: std.mem.Allocator = undefined;

/// Prepare the object module for allocations. Must be called before any
/// object creation (typically at VM init time).
pub fn init(allocator: std.mem.Allocator) void {
    obj_allocator = allocator;
    objects = null;
}

const lit_alignment: std.mem.Alignment = @enumFromInt(std.math.log2_int(
    usize,
    @alignOf(ObjLiteral),
));

/// Allocate a new ObjLiteral that owns a copy of `source`. The header
/// and character data occupy a single contiguous allocation.
pub fn copyLiteral(source: []const u8) !*ObjLiteral {
    const raw = try obj_allocator.alignedAlloc(u8, lit_alignment, @sizeOf(ObjLiteral) + source.len);
    const lit: *ObjLiteral = @ptrCast(@alignCast(raw.ptr));
    lit.* = .{
        .obj = .{ .obj_type = .literal, .next = objects },
        .len = source.len,
    };
    @memcpy(raw[@sizeOf(ObjLiteral)..], source);
    objects = &lit.obj;
    return lit;
}

/// Allocate a new ObjCharset with the given 256-bit membership vector.
pub fn createCharset(bits: [32]u8) !*ObjCharset {
    const cs = try obj_allocator.create(ObjCharset);
    cs.* = .{
        .obj = .{ .obj_type = .charset, .next = objects },
        .bits = bits,
    };
    objects = &cs.obj;
    return cs;
}

/// Walk the intrusive object list and free every allocation.
pub fn freeObjects() void {
    var obj = objects;
    while (obj) |o| {
        const next = o.next;
        freeObject(o);
        obj = next;
    }
    objects = null;
}

fn freeObject(obj: *Obj) void {
    switch (obj.obj_type) {
        .literal => {
            const lit = obj.asLiteral();
            const raw: [*]align(lit_alignment.toByteUnits()) u8 = @ptrCast(lit);
            obj_allocator.free(raw[0 .. @sizeOf(ObjLiteral) + lit.len]);
        },
        .charset => {
            const cs = obj.asCharset();
            obj_allocator.destroy(cs);
        },
    }
}

/// Content-based equality. Two literals are equal when their byte
/// sequences match; two charsets are equal when their bitvectors match.
/// Objects of different types are never equal.
pub fn objEql(a: *Obj, b: *Obj) bool {
    if (a == b) return true;
    if (a.obj_type != b.obj_type) return false;
    return switch (a.obj_type) {
        .literal => std.mem.eql(u8, a.asLiteral().chars(), b.asLiteral().chars()),
        .charset => std.mem.eql(u8, &a.asCharset().bits, &b.asCharset().bits),
    };
}

/// Format an object for display (debug / REPL output).
pub fn printObject(obj: *Obj) void {
    switch (obj.obj_type) {
        .literal => {
            const lit = obj.asLiteral();
            std.debug.print("{s}", .{lit.chars()});
        },
        .charset => {
            std.debug.print("[charset]", .{});
        },
    }
}

test "copyLiteral creates an owned copy" {
    const alloc = std.testing.allocator;
    init(alloc);
    defer freeObjects();

    const source = "hello";
    const lit = try copyLiteral(source);
    try std.testing.expectEqualStrings("hello", lit.chars());
    // Verify it is a distinct allocation, not aliasing the source.
    try std.testing.expect(lit.chars().ptr != source.ptr);
}

test "charset membership" {
    const alloc = std.testing.allocator;
    init(alloc);
    defer freeObjects();

    var bits: [32]u8 = .{0} ** 32;
    // Set 'a' (97) and 'z' (122).
    bits['a' >> 3] |= @as(u8, 1) << @intCast('a' & 0x07);
    bits['z' >> 3] |= @as(u8, 1) << @intCast('z' & 0x07);

    const cs = try createCharset(bits);
    try std.testing.expect(cs.contains('a'));
    try std.testing.expect(cs.contains('z'));
    try std.testing.expect(!cs.contains('b'));
    try std.testing.expect(!cs.contains('A'));
}

test "distinct literals with same content are equal" {
    const alloc = std.testing.allocator;
    init(alloc);
    defer freeObjects();

    const a = try copyLiteral("hello");
    const b = try copyLiteral("hello");
    try std.testing.expect(a != b); // different pointers
    try std.testing.expect(objEql(a.asObj(), b.asObj())); // same content
}

test "literals with different content are not equal" {
    const alloc = std.testing.allocator;
    init(alloc);
    defer freeObjects();

    const a = try copyLiteral("hello");
    const b = try copyLiteral("world");
    try std.testing.expect(!objEql(a.asObj(), b.asObj()));
}

test "charsets with same bits are equal" {
    const alloc = std.testing.allocator;
    init(alloc);
    defer freeObjects();

    var bits: [32]u8 = .{0} ** 32;
    bits['a' >> 3] |= @as(u8, 1) << @intCast('a' & 0x07);

    const a = try createCharset(bits);
    const b = try createCharset(bits);
    try std.testing.expect(objEql(a.asObj(), b.asObj()));
}

test "literal and charset are never equal" {
    const alloc = std.testing.allocator;
    init(alloc);
    defer freeObjects();

    const lit = try copyLiteral("a");
    const bits: [32]u8 = .{0} ** 32;
    const cs = try createCharset(bits);
    try std.testing.expect(!objEql(lit.asObj(), cs.asObj()));
}

test "freeObjects walks the full list" {
    const alloc = std.testing.allocator;
    init(alloc);

    _ = try copyLiteral("one");
    _ = try copyLiteral("two");
    const bits: [32]u8 = .{0} ** 32;
    _ = try createCharset(bits);

    // Three objects on the list. freeObjects must release all of them
    // without leaking (the testing allocator will catch leaks).
    freeObjects();
}
