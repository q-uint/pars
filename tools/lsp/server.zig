//! Language Server Protocol server for pars grammar files.
//!
//! Transport: JSON-RPC 2.0 over stdin/stdout with Content-Length framing.
//!
//! Supported features:
//!   * textDocument/didOpen, didChange (full sync), didClose
//!   * textDocument/semanticTokens/full
//!   * textDocument/publishDiagnostics (scanner + compiler errors)
//!   * textDocument/definition, hover, documentSymbol, inlayHint
//!   * textDocument/references, prepareRename, rename, codeLens
//!   * textDocument/completion (rules, captures-in-scope, keywords)
//!   * pars/disassemble (chunk + constants), pars/runRule (VM probe)

const std = @import("std");
const pars = @import("pars");
const symbols = @import("symbols.zig");
const stdlib = @import("stdlib.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Scanner = pars.scanner.Scanner;
const TokenType = pars.scanner.TokenType;
const Compiler = pars.compiler.Compiler;
const RuleTable = pars.compiler.RuleTable;
const Chunk = pars.chunk.Chunk;
const OpCode = pars.chunk.OpCode;
const SourceSpan = pars.chunk.SourceSpan;
const ObjPool = pars.object.ObjPool;
const Vm = pars.vm.Vm;
const InterpretResult = pars.vm.InterpretResult;

/// Semantic token type legend. The order is contractual: the VSCode
/// client declares the same list in `SemanticTokensLegend`. Indices
/// emitted in the delta-encoded token array reference this list.
pub const token_type_legend = [_][]const u8{
    "type", // 0
    "string", // 1
    "number", // 2
    "comment", // 3
    "operator", // 4
    "keyword", // 5
    "decorator", // 6 — identifiers inside `#[...]` attribute lists
};

const semantic_decorator: u32 = 6;

/// No modifiers in use yet; the legend is empty but declared so the
/// client can advertise a complete `SemanticTokensLegend`.
pub const token_modifier_legend = [_][]const u8{};

fn mapTokenType(t: TokenType) ?u32 {
    return switch (t) {
        .left_paren,
        .right_paren,
        .left_bracket,
        .right_bracket,
        .left_brace,
        .right_brace,
        .comma,
        .semicolon,
        .colon,
        => null,
        .equal,
        .minus,
        .dot,
        .percent,
        .caret,
        .slash,
        .pipe,
        .star,
        .plus,
        .question,
        .bang,
        .amp,
        .left_angle,
        .right_angle,
        .arrow,
        => 4, // operator
        .hash => semantic_decorator,
        .identifier => 0, // type; may be retagged as decorator inside `#[...]`
        .string, .string_i, .char => 1, // string
        .number => 2, // number
        .kw_let,
        .kw_grammar,
        .kw_extends,
        .kw_super,
        .kw_use,
        .kw_where,
        .kw_end,
        => 5, // keyword
        .err, .eof => null,
    };
}

const SemTok = struct {
    line: u32,
    col: u32,
    len: u32,
    ty: u32,
};

fn lessSemTok(_: void, a: SemTok, b: SemTok) bool {
    if (a.line != b.line) return a.line < b.line;
    return a.col < b.col;
}

/// Produce an LSP delta-encoded semantic-tokens array for `source`.
///
/// The scanner skips `--`-to-end-of-line comments as whitespace, so
/// comments never appear as tokens. We recover them by walking the
/// byte gap between consecutive token ends and starts: the scanner
/// guarantees that gap holds only whitespace and comments, so a plain
/// `--` match is enough — no string/charset context tracking needed.
pub fn computeSemanticTokens(alloc: Allocator, source: []const u8) ![]u32 {
    var toks: std.ArrayList(SemTok) = .empty;
    defer toks.deinit(alloc);

    var scanner = Scanner.init(source);
    var prev_end: usize = 0;
    var line: usize = 1;
    var line_start: usize = 0;
    // State for retagging identifiers inside `#[...]` as decorators.
    // `saw_hash` flips on when a `.hash` token is emitted; if the very
    // next token is `.left_bracket`, we enter `in_attr_list` until the
    // matching `.right_bracket`. An attribute identifier would
    // otherwise get the default "type" highlight from mapTokenType.
    var saw_hash: bool = false;
    var in_attr_list: bool = false;

    while (true) {
        const tok = scanner.scanToken();

        var i = prev_end;
        while (i < tok.start) {
            if (source[i] == '\n') {
                line += 1;
                line_start = i + 1;
                i += 1;
            } else if (i + 1 < tok.start and source[i] == '-' and source[i + 1] == '-') {
                const col = i - line_start;
                const start = i;
                while (i < source.len and source[i] != '\n') i += 1;
                try toks.append(alloc, .{
                    .line = @intCast(line - 1),
                    .col = @intCast(col),
                    .len = @intCast(i - start),
                    .ty = 3,
                });
            } else {
                i += 1;
            }
        }

        if (tok.type == .eof) break;

        var final_ty: ?u32 = mapTokenType(tok.type);

        // Track `#[...]` attribute-list context so the whole bracketed
        // range — `#`, `[`, the identifiers inside, commas, and `]` —
        // renders as a single cohesive decorator span rather than a
        // mix of decorator (`#`), operator (nothing), and type
        // (identifier) classes.
        if (tok.type == .hash) {
            saw_hash = true;
        } else if (saw_hash and tok.type == .left_bracket) {
            in_attr_list = true;
            saw_hash = false;
            final_ty = semantic_decorator;
        } else {
            saw_hash = false;
            if (in_attr_list) switch (tok.type) {
                .right_bracket => {
                    in_attr_list = false;
                    final_ty = semantic_decorator;
                },
                .identifier, .comma => final_ty = semantic_decorator,
                else => {},
            };
        }

        if (final_ty) |ty| {
            try toks.append(alloc, .{
                .line = @intCast(tok.line - 1),
                .col = @intCast(tok.column - 1),
                .len = @intCast(tok.len),
                .ty = ty,
            });
        }

        const end = tok.start + tok.len;
        var j = tok.start;
        while (j < end) : (j += 1) {
            if (source[j] == '\n') {
                line += 1;
                line_start = j + 1;
            }
        }
        prev_end = end;
    }

    std.mem.sort(SemTok, toks.items, {}, lessSemTok);

    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, toks.items.len * 5);

    var pline: u32 = 0;
    var pcol: u32 = 0;
    for (toks.items) |t| {
        const dline = t.line - pline;
        const dcol = if (dline == 0) t.col - pcol else t.col;
        out.appendSliceAssumeCapacity(&.{ dline, dcol, t.len, t.ty, 0 });
        pline = t.line;
        pcol = t.col;
    }

    return try out.toOwnedSlice(alloc);
}

/// A diagnostic extracted from compile output, in the shape the LSP
/// JSON response needs. Line/column are 0-based and byte-offset-based
/// (ASCII assumption — non-ASCII source files will be slightly off in
/// clients that interpret columns as UTF-16 code units).
pub const Diagnostic = struct {
    line: u32,
    col: u32,
    end_line: u32,
    end_col: u32,
    message: []const u8,
    /// Set when `message` was allocated by this module and must be
    /// freed by `deinitDiagnostics`.
    owned: bool,
};

pub fn deinitDiagnostics(alloc: Allocator, diags: []Diagnostic) void {
    for (diags) |d| if (d.owned) alloc.free(d.message);
    alloc.free(diags);
}

/// Run the compiler against `source` and translate its error list into
/// LSP-shaped diagnostic ranges.
pub fn collectDiagnostics(alloc: Allocator, source: []const u8) ![]Diagnostic {
    var obj_pool = ObjPool.init(alloc);
    defer obj_pool.deinit();

    var rule_table: RuleTable = .{};
    defer rule_table.deinit(alloc);

    var chunk = Chunk.init(alloc);
    defer chunk.deinit();

    var compiler = Compiler.init(alloc);
    defer compiler.deinit();

    _ = compiler.compile(source, &chunk, &rule_table, &obj_pool);
    const errs = compiler.getErrors();

    var out: std.ArrayList(Diagnostic) = .empty;
    errdefer {
        for (out.items) |d| if (d.owned) alloc.free(d.message);
        out.deinit(alloc);
    }

    for (errs) |e| {
        const start_line: u32 = @intCast(if (e.line == 0) 0 else e.line - 1);
        const start_col: u32 = @intCast(if (e.column == 0) 0 else e.column - 1);
        const span_len: u32 = @intCast(if (e.at_eof) @as(usize, 0) else e.len);

        const end = computeEnd(source, e.start, span_len);

        const msg = try alloc.dupe(u8, e.message);
        errdefer alloc.free(msg);

        try out.append(alloc, .{
            .line = start_line,
            .col = start_col,
            .end_line = end.line,
            .end_col = end.col,
            .message = msg,
            .owned = true,
        });
    }

    return try out.toOwnedSlice(alloc);
}

const EndPos = struct { line: u32, col: u32 };

fn computeEnd(source: []const u8, start: usize, len: u32) EndPos {
    var line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    const stop = @min(source.len, start + len);
    while (i < stop) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{ .line = line, .col = @intCast(stop - line_start) };
}

pub const FrameError = error{
    UnexpectedEof,
    MissingContentLength,
    InvalidContentLength,
    ReadFailed,
    OutOfMemory,
    WriteFailed,
    StreamTooLong,
};

/// Read one LSP message body, consuming headers and content. Returns
/// a heap-allocated slice of the body bytes (caller frees), or `null`
/// on clean EOF between messages.
pub fn readMessage(alloc: Allocator, reader: *std.Io.Reader) FrameError!?[]u8 {
    var content_length: ?usize = null;

    while (true) {
        const line_opt = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.StreamTooLong => return error.StreamTooLong,
        };
        const line = line_opt orelse {
            if (content_length == null) return null;
            return error.UnexpectedEof;
        };
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) break;

        if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
            const rest = std.mem.trim(u8, trimmed["content-length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, rest, 10) catch {
                return error.InvalidContentLength;
            };
        }
    }

    const n = content_length orelse return error.MissingContentLength;
    const body = alloc.alloc(u8, n) catch return error.OutOfMemory;
    errdefer alloc.free(body);
    reader.readSliceAll(body) catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.EndOfStream => return error.UnexpectedEof,
    };
    return body;
}

/// Write one LSP message, emitting `Content-Length` + CRLF framing
/// followed by the JSON body.
pub fn writeMessage(writer: *std.Io.Writer, body: []const u8) FrameError!void {
    writer.print("Content-Length: {d}\r\n\r\n", .{body.len}) catch return error.WriteFailed;
    writer.writeAll(body) catch return error.WriteFailed;
    writer.flush() catch return error.WriteFailed;
}

pub const Server = struct {
    alloc: Allocator,
    /// Io used for stdlib file lookups. `null` when the server is
    /// constructed for unit tests that don't exercise the filesystem.
    io: ?Io,
    documents: std.StringHashMap(Document),
    /// Cache of loaded stdlib sources, keyed by module path ("std/abnf").
    /// Stdlib files do not change across an LSP session, so a one-shot
    /// load with no invalidation is sufficient.
    stdlib_cache: std.StringHashMap(StdlibEntry),
    writer: *std.Io.Writer,
    shutdown_requested: bool = false,

    pub fn init(alloc: Allocator, writer: *std.Io.Writer) Server {
        return .{
            .alloc = alloc,
            .io = null,
            .documents = std.StringHashMap(Document).init(alloc),
            .stdlib_cache = std.StringHashMap(StdlibEntry).init(alloc),
            .writer = writer,
        };
    }

    /// Variant used by the real LSP entry point. The `io` is used for
    /// loading stdlib source files on demand for goto-def / hover.
    pub fn initWithIo(alloc: Allocator, io: Io, writer: *std.Io.Writer) Server {
        return .{
            .alloc = alloc,
            .io = io,
            .documents = std.StringHashMap(Document).init(alloc),
            .stdlib_cache = std.StringHashMap(StdlibEntry).init(alloc),
            .writer = writer,
        };
    }

    pub fn deinit(self: *Server) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.text);
        }
        self.documents.deinit();

        var sit = self.stdlib_cache.iterator();
        while (sit.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.path);
            self.alloc.free(entry.value_ptr.uri);
            self.alloc.free(entry.value_ptr.source);
        }
        self.stdlib_cache.deinit();
    }

    /// Resolve and load a stdlib module by path ("std/abnf"). Returns
    /// null if the module is unknown or the stdlib directory cannot be
    /// located. The returned entry is owned by the server and stays
    /// valid until `deinit`.
    fn loadStdlibModule(self: *Server, module_path: []const u8) !?*const StdlibEntry {
        if (self.stdlib_cache.getPtr(module_path)) |e| return e;

        // Tests that use `Server.init` (no Io) skip stdlib resolution
        // entirely; only the real entry point sets an Io.
        const io = self.io orelse return null;

        const fs_path = (try stdlib.resolveModulePath(self.alloc, io, module_path)) orelse return null;
        errdefer self.alloc.free(fs_path);

        const source = (try stdlib.readSource(self.alloc, io, fs_path)) orelse {
            self.alloc.free(fs_path);
            return null;
        };
        errdefer self.alloc.free(source);

        const uri = try stdlib.pathToFileUri(self.alloc, fs_path);
        errdefer self.alloc.free(uri);

        const key = try self.alloc.dupe(u8, module_path);
        errdefer self.alloc.free(key);

        try self.stdlib_cache.put(key, .{
            .path = fs_path,
            .uri = uri,
            .source = source,
        });
        return self.stdlib_cache.getPtr(module_path);
    }

    /// Walk the document's `use` declarations looking for one whose
    /// module defines `name`. Returns the module entry plus the def
    /// index within that module's index; `module_idx` is populated so
    /// the caller can read the def's span and body.
    fn resolveViaUses(
        self: *Server,
        doc_idx: *const symbols.Index,
        name: []const u8,
        module_idx: *symbols.Index,
    ) !?StdlibHit {
        for (doc_idx.uses) |u| {
            const entry = (try self.loadStdlibModule(u.path)) orelse continue;
            var idx = try symbols.buildIndex(self.alloc, entry.source);
            if (idx.findDef(name, null)) |di| {
                module_idx.* = idx;
                return .{ .entry = entry, .def_index = di };
            }
            idx.deinit(self.alloc);
        }
        return null;
    }

    /// Decode and dispatch one JSON-RPC message. Writes zero or more
    /// response messages to `self.writer`.
    pub fn handleMessage(self: *Server, body: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, body, .{}) catch |err| {
            try self.writeParseError(err);
            return;
        };
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return,
        };

        const method = if (obj.get("method")) |m| switch (m) {
            .string => |s| s,
            else => return,
        } else return;

        const id = obj.get("id");
        const params = obj.get("params");

        try self.dispatch(method, id, params);
    }

    fn dispatch(
        self: *Server,
        method: []const u8,
        id: ?std.json.Value,
        params: ?std.json.Value,
    ) !void {
        if (std.mem.eql(u8, method, "initialize")) {
            try self.handleInitialize(id.?);
        } else if (std.mem.eql(u8, method, "initialized")) {
            // notification, no response
        } else if (std.mem.eql(u8, method, "shutdown")) {
            self.shutdown_requested = true;
            try self.writeResult(id.?, .null);
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            try self.handleDidOpen(params orelse return);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            try self.handleDidChange(params orelse return);
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            try self.handleDidClose(params orelse return);
        } else if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
            try self.handleSemanticTokens(id.?, params orelse return);
        } else if (std.mem.eql(u8, method, "textDocument/definition")) {
            try self.handleDefinition(id.?, params orelse return);
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            try self.handleHover(id.?, params orelse return);
        } else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
            try self.handleDocumentSymbol(id.?, params orelse return);
        } else if (std.mem.eql(u8, method, "textDocument/inlayHint")) {
            try self.handleInlayHint(id.?, params orelse return);
        } else if (std.mem.eql(u8, method, "textDocument/references")) {
            try self.handleReferences(id.?, params orelse return);
        } else if (std.mem.eql(u8, method, "textDocument/prepareRename")) {
            try self.handlePrepareRename(id.?, params orelse return);
        } else if (std.mem.eql(u8, method, "textDocument/rename")) {
            try self.handleRename(id.?, params orelse return);
        } else if (std.mem.eql(u8, method, "textDocument/codeLens")) {
            try self.handleCodeLens(id.?, params orelse return);
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            try self.handleCompletion(id.?, params orelse return);
        } else if (std.mem.eql(u8, method, "pars/disassemble")) {
            try self.handleDisassemble(id.?, params orelse return);
        } else if (std.mem.eql(u8, method, "pars/runRule")) {
            try self.handleRunRule(id.?, params orelse return);
        } else if (id) |rid| {
            // Unknown request — reply with MethodNotFound per JSON-RPC.
            try self.writeError(rid, -32601, "method not found");
        }
    }

    fn handleInitialize(self: *Server, id: std.json.Value) !void {
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        defer aw.deinit();
        var stringify: std.json.Stringify = .{ .writer = &aw.writer };

        try stringify.beginObject();
        try stringify.objectField("jsonrpc");
        try stringify.write("2.0");
        try stringify.objectField("id");
        try stringify.write(id);
        try stringify.objectField("result");
        try stringify.beginObject();

        try stringify.objectField("capabilities");
        try stringify.beginObject();
        try stringify.objectField("textDocumentSync");
        try stringify.write(1); // Full sync

        try stringify.objectField("semanticTokensProvider");
        try stringify.beginObject();
        try stringify.objectField("legend");
        try stringify.beginObject();
        try stringify.objectField("tokenTypes");
        try stringify.beginArray();
        for (token_type_legend) |name| try stringify.write(name);
        try stringify.endArray();
        try stringify.objectField("tokenModifiers");
        try stringify.beginArray();
        for (token_modifier_legend) |name| try stringify.write(name);
        try stringify.endArray();
        try stringify.endObject();
        try stringify.objectField("full");
        try stringify.write(true);
        try stringify.endObject();

        try stringify.objectField("definitionProvider");
        try stringify.write(true);
        try stringify.objectField("hoverProvider");
        try stringify.write(true);
        try stringify.objectField("documentSymbolProvider");
        try stringify.write(true);
        try stringify.objectField("inlayHintProvider");
        try stringify.write(true);
        try stringify.objectField("referencesProvider");
        try stringify.write(true);
        try stringify.objectField("renameProvider");
        try stringify.beginObject();
        try stringify.objectField("prepareProvider");
        try stringify.write(true);
        try stringify.endObject();
        try stringify.objectField("codeLensProvider");
        try stringify.beginObject();
        try stringify.objectField("resolveProvider");
        try stringify.write(false);
        try stringify.endObject();

        // Identifier-prefix completion: the LSP client triggers on each
        // identifier character automatically, so no triggerCharacters
        // are advertised. Items are static; the client filters by prefix.
        try stringify.objectField("completionProvider");
        try stringify.beginObject();
        try stringify.objectField("resolveProvider");
        try stringify.write(false);
        try stringify.endObject();

        try stringify.endObject();

        try stringify.objectField("serverInfo");
        try stringify.beginObject();
        try stringify.objectField("name");
        try stringify.write("pars-lsp");
        try stringify.objectField("version");
        try stringify.write("0.0.1");
        try stringify.endObject();

        try stringify.endObject();
        try stringify.endObject();

        try writeMessage(self.writer, aw.writer.buffered());
    }

    fn handleDidOpen(self: *Server, params: std.json.Value) !void {
        const td = params.object.get("textDocument") orelse return;
        const uri = getString(td, "uri") orelse return;
        const text = getString(td, "text") orelse return;
        try self.storeDocument(uri, text);
        try self.publishDiagnostics(uri);
    }

    fn handleDidChange(self: *Server, params: std.json.Value) !void {
        const td = params.object.get("textDocument") orelse return;
        const uri = getString(td, "uri") orelse return;
        const changes = params.object.get("contentChanges") orelse return;
        const arr = switch (changes) {
            .array => |a| a,
            else => return,
        };
        // Full sync: the last change carries the whole document.
        if (arr.items.len == 0) return;
        const last = arr.items[arr.items.len - 1];
        const text = getString(last, "text") orelse return;
        try self.storeDocument(uri, text);
        try self.publishDiagnostics(uri);
    }

    fn handleDidClose(self: *Server, params: std.json.Value) !void {
        const td = params.object.get("textDocument") orelse return;
        const uri = getString(td, "uri") orelse return;
        if (self.documents.fetchRemove(uri)) |kv| {
            self.alloc.free(kv.key);
            self.alloc.free(kv.value.text);
        }
        // Clear any diagnostics the client was showing for this URI.
        try self.sendDiagnostics(uri, &.{});
    }

    fn handleSemanticTokens(self: *Server, id: std.json.Value, params: std.json.Value) !void {
        const td = params.object.get("textDocument") orelse return;
        const uri = getString(td, "uri") orelse return;
        const doc = self.documents.get(uri) orelse return;

        const data = try computeSemanticTokens(self.alloc, doc.text);
        defer self.alloc.free(data);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer };

        try s.beginObject();
        try s.objectField("jsonrpc");
        try s.write("2.0");
        try s.objectField("id");
        try s.write(id);
        try s.objectField("result");
        try s.beginObject();
        try s.objectField("data");
        try s.beginArray();
        for (data) |n| try s.write(n);
        try s.endArray();
        try s.endObject();
        try s.endObject();

        try writeMessage(self.writer, aw.writer.buffered());
    }

    fn handleDefinition(self: *Server, id: std.json.Value, params: std.json.Value) !void {
        const td = params.object.get("textDocument") orelse return self.writeResult(id, .null);
        const uri = getString(td, "uri") orelse return self.writeResult(id, .null);
        const doc = self.documents.get(uri) orelse return self.writeResult(id, .null);
        const pos = getPosition(params) orelse return self.writeResult(id, .null);

        var idx = try symbols.buildIndex(self.alloc, doc.text);
        defer idx.deinit(self.alloc);

        // Prefer a reference at the cursor, fall back to a definition
        // (so a user can ctrl-click the name on the LHS and stay put).
        if (idx.refAt(pos.line, pos.col)) |ri| {
            const ref = idx.refs[ri];
            // Back-references resolve to the capture's name position.
            if (ref.back_ref) {
                if (ref.rule_index) |rule_idx| {
                    if (idx.findCaptureInRule(ref.name, rule_idx)) |ci| {
                        const c = idx.captures[ci];
                        return self.writeLocation(id, uri, c.name_span, c.name_end);
                    }
                }
            }
            if (idx.findDef(ref.name, ref.rule_index)) |di| {
                const d = idx.defs[di];
                return self.writeLocation(id, uri, d.name_span, d.name_end);
            }
            // Local lookup failed; try stdlib modules pulled in via
            // `use` and jump into the module source if the name is
            // defined there.
            var mod_idx: symbols.Index = undefined;
            if (try self.resolveViaUses(&idx, ref.name, &mod_idx)) |hit| {
                defer mod_idx.deinit(self.alloc);
                const d = mod_idx.defs[hit.def_index];
                return self.writeLocation(id, hit.entry.uri, d.name_span, d.name_end);
            }
        }
        try self.writeResult(id, .null);
    }

    fn handleHover(self: *Server, id: std.json.Value, params: std.json.Value) !void {
        const td = params.object.get("textDocument") orelse return self.writeResult(id, .null);
        const uri = getString(td, "uri") orelse return self.writeResult(id, .null);
        const doc = self.documents.get(uri) orelse return self.writeResult(id, .null);
        const pos = getPosition(params) orelse return self.writeResult(id, .null);

        var idx = try symbols.buildIndex(self.alloc, doc.text);
        defer idx.deinit(self.alloc);

        // `mod_idx` is populated and owned when a stdlib lookup
        // succeeds; freed at the end of the function so the body slice
        // passed to formatHoverRule stays valid while we stringify.
        var mod_idx: symbols.Index = undefined;
        var mod_idx_live = false;
        defer if (mod_idx_live) mod_idx.deinit(self.alloc);

        const hover_text = blk: {
            if (idx.defAt(pos.line, pos.col)) |di| {
                break :blk try formatHoverRule(self.alloc, doc.text, idx.defs[di]);
            }
            if (idx.refAt(pos.line, pos.col)) |ri| {
                const ref = idx.refs[ri];
                if (ref.back_ref) {
                    break :blk try std.fmt.allocPrint(
                        self.alloc,
                        "```pars\n<{s}: …> back-reference\n```",
                        .{ref.name},
                    );
                }
                if (idx.findDef(ref.name, ref.rule_index)) |di| {
                    break :blk try formatHoverRule(self.alloc, doc.text, idx.defs[di]);
                }
                if (try self.resolveViaUses(&idx, ref.name, &mod_idx)) |hit| {
                    mod_idx_live = true;
                    break :blk try formatHoverRule(
                        self.alloc,
                        hit.entry.source,
                        mod_idx.defs[hit.def_index],
                    );
                }
            }
            if (idx.captureAt(pos.line, pos.col)) |ci| {
                break :blk try std.fmt.allocPrint(
                    self.alloc,
                    "```pars\n<{s}: …> capture binding\n```",
                    .{idx.captures[ci].name},
                );
            }
            if (idx.attrAt(pos.line, pos.col)) |ai| {
                break :blk try formatHoverAttribute(self.alloc, idx.attrs[ai]);
            }
            break :blk null;
        };

        if (hover_text) |text| {
            defer self.alloc.free(text);
            var aw = std.Io.Writer.Allocating.init(self.alloc);
            defer aw.deinit();
            var s: std.json.Stringify = .{ .writer = &aw.writer };
            try s.beginObject();
            try s.objectField("jsonrpc");
            try s.write("2.0");
            try s.objectField("id");
            try s.write(id);
            try s.objectField("result");
            try s.beginObject();
            try s.objectField("contents");
            try s.beginObject();
            try s.objectField("kind");
            try s.write("markdown");
            try s.objectField("value");
            try s.write(text);
            try s.endObject();
            try s.endObject();
            try s.endObject();
            try writeMessage(self.writer, aw.writer.buffered());
            return;
        }
        try self.writeResult(id, .null);
    }

    fn handleDocumentSymbol(self: *Server, id: std.json.Value, params: std.json.Value) !void {
        const td = params.object.get("textDocument") orelse return self.writeResult(id, .null);
        const uri = getString(td, "uri") orelse return self.writeResult(id, .null);
        const doc = self.documents.get(uri) orelse return self.writeResult(id, .null);

        var idx = try symbols.buildIndex(self.alloc, doc.text);
        defer idx.deinit(self.alloc);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer };

        try s.beginObject();
        try s.objectField("jsonrpc");
        try s.write("2.0");
        try s.objectField("id");
        try s.write(id);
        try s.objectField("result");
        try s.beginArray();
        for (idx.defs) |d| {
            // Emit only top-level rules; sub-rules end up as `children`
            // of the rule that opened their where-block. For a first
            // pass we keep the outline flat and skip sub-rules — they
            // are visible in the source near their parent already.
            if (d.kind != .top_level) continue;
            try writeDocumentSymbol(&s, d);
        }
        try s.endArray();
        try s.endObject();

        try writeMessage(self.writer, aw.writer.buffered());
    }

    fn handleInlayHint(self: *Server, id: std.json.Value, params: std.json.Value) !void {
        const td = params.object.get("textDocument") orelse return self.writeResult(id, .null);
        const uri = getString(td, "uri") orelse return self.writeResult(id, .null);
        const doc = self.documents.get(uri) orelse return self.writeResult(id, .null);

        var idx = try symbols.buildIndex(self.alloc, doc.text);
        defer idx.deinit(self.alloc);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer };

        try s.beginObject();
        try s.objectField("jsonrpc");
        try s.write("2.0");
        try s.objectField("id");
        try s.write(id);
        try s.objectField("result");
        try s.beginArray();
        for (idx.refs) |r| {
            if (!r.back_ref) continue;
            // Anchor the hint at the end of the reference, labeled to
            // clarify that this identifier matches a previously captured
            // span rather than invoking a rule.
            try s.beginObject();
            try s.objectField("position");
            try s.beginObject();
            try s.objectField("line");
            try s.write(r.end.line);
            try s.objectField("character");
            try s.write(r.end.col);
            try s.endObject();
            try s.objectField("label");
            try s.write(": backref");
            try s.objectField("kind");
            try s.write(1); // Type
            try s.objectField("paddingLeft");
            try s.write(true);
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();

        try writeMessage(self.writer, aw.writer.buffered());
    }

    fn handleReferences(self: *Server, id: std.json.Value, params: std.json.Value) !void {
        const td = params.object.get("textDocument") orelse return self.writeResult(id, .null);
        const uri = getString(td, "uri") orelse return self.writeResult(id, .null);
        const doc = self.documents.get(uri) orelse return self.writeResult(id, .null);
        const pos = getPosition(params) orelse return self.writeResult(id, .null);

        // `context.includeDeclaration` defaults to true here for UX: a
        // missing `context` block (some clients send none) should show
        // all occurrences including the defining LHS, not hide it.
        const include_decl = blk: {
            const ctx = params.object.get("context") orelse break :blk true;
            const obj = switch (ctx) {
                .object => |o| o,
                else => break :blk true,
            };
            const v = obj.get("includeDeclaration") orelse break :blk true;
            break :blk switch (v) {
                .bool => |b| b,
                else => true,
            };
        };

        var idx = try symbols.buildIndex(self.alloc, doc.text);
        defer idx.deinit(self.alloc);

        const hit = findOccurrenceAt(&idx, pos.line, pos.col) orelse
            return self.writeResult(id, .null);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("jsonrpc");
        try s.write("2.0");
        try s.objectField("id");
        try s.write(id);
        try s.objectField("result");
        try s.beginArray();
        try writeOccurrenceLocations(&s, uri, &idx, hit, include_decl);
        try s.endArray();
        try s.endObject();
        try writeMessage(self.writer, aw.writer.buffered());
    }

    fn handlePrepareRename(self: *Server, id: std.json.Value, params: std.json.Value) !void {
        const td = params.object.get("textDocument") orelse return self.writeResult(id, .null);
        const uri = getString(td, "uri") orelse return self.writeResult(id, .null);
        const doc = self.documents.get(uri) orelse return self.writeResult(id, .null);
        const pos = getPosition(params) orelse return self.writeResult(id, .null);

        var idx = try symbols.buildIndex(self.alloc, doc.text);
        defer idx.deinit(self.alloc);

        const hit = findOccurrenceAt(&idx, pos.line, pos.col) orelse
            return self.writeResult(id, .null);

        // Refuse to rename rule names whose definition is not in this
        // document — typically stdlib rules pulled in via `use`. We
        // cannot safely rewrite files we don't own.
        if (hit.kind == .rule_name) {
            if (idx.findDef(hit.name, null) == null) return self.writeResult(id, .null);
        }

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("jsonrpc");
        try s.write("2.0");
        try s.objectField("id");
        try s.write(id);
        try s.objectField("result");
        try writeRange(&s, hit.cursor_span, hit.cursor_end);
        try s.endObject();
        try writeMessage(self.writer, aw.writer.buffered());
    }

    fn handleRename(self: *Server, id: std.json.Value, params: std.json.Value) !void {
        const td = params.object.get("textDocument") orelse return self.writeResult(id, .null);
        const uri = getString(td, "uri") orelse return self.writeResult(id, .null);
        const doc = self.documents.get(uri) orelse return self.writeResult(id, .null);
        const pos = getPosition(params) orelse return self.writeResult(id, .null);
        const new_name = getString(params, "newName") orelse return self.writeResult(id, .null);

        if (!isValidIdentifier(new_name)) {
            return self.writeError(id, -32602, "invalid identifier");
        }

        var idx = try symbols.buildIndex(self.alloc, doc.text);
        defer idx.deinit(self.alloc);

        const hit = findOccurrenceAt(&idx, pos.line, pos.col) orelse
            return self.writeResult(id, .null);

        if (hit.kind == .rule_name) {
            if (idx.findDef(hit.name, null) == null) return self.writeResult(id, .null);
        }

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("jsonrpc");
        try s.write("2.0");
        try s.objectField("id");
        try s.write(id);
        try s.objectField("result");
        try s.beginObject();
        try s.objectField("changes");
        try s.beginObject();
        try s.objectField(uri);
        try s.beginArray();
        try writeOccurrenceTextEdits(&s, &idx, hit, new_name);
        try s.endArray();
        try s.endObject();
        try s.endObject();
        try s.endObject();
        try writeMessage(self.writer, aw.writer.buffered());
    }

    fn handleCodeLens(self: *Server, id: std.json.Value, params: std.json.Value) !void {
        const td = params.object.get("textDocument") orelse return self.writeResult(id, .null);
        const uri = getString(td, "uri") orelse return self.writeResult(id, .null);
        const doc = self.documents.get(uri) orelse return self.writeResult(id, .null);

        var idx = try symbols.buildIndex(self.alloc, doc.text);
        defer idx.deinit(self.alloc);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer };

        try s.beginObject();
        try s.objectField("jsonrpc");
        try s.write("2.0");
        try s.objectField("id");
        try s.write(id);
        try s.objectField("result");
        try s.beginArray();

        // One lens per top-level rule with a pre-filled showReferences
        // command. Sub-rules are scoped and would clutter the view for
        // minimal benefit.
        for (idx.defs) |d| {
            if (d.kind != .top_level) continue;

            var count: usize = 0;
            for (idx.refs) |r| {
                if (r.back_ref) continue;
                if (std.mem.eql(u8, r.name, d.name)) count += 1;
            }

            var title_buf: [32]u8 = undefined;
            const title = try std.fmt.bufPrint(
                &title_buf,
                "{d} reference{s}",
                .{ count, if (count == 1) @as([]const u8, "") else "s" },
            );

            try s.beginObject();
            try s.objectField("range");
            try writeRange(&s, d.name_span, d.name_end);
            try s.objectField("command");
            try s.beginObject();
            try s.objectField("title");
            try s.write(title);
            try s.objectField("command");
            // Route through a client-side command that converts the
            // JSON args (uri string, {line,character} object, and
            // Location[]) into real vscode.Uri/Position/Location
            // instances before forwarding to editor.action.showReferences.
            // Invoking the native command with raw JSON throws a
            // constraint error in the VSCode host.
            try s.write("pars.showReferences");
            try s.objectField("arguments");
            try s.beginArray();
            try s.write(uri);
            try s.beginObject();
            try s.objectField("line");
            try s.write(d.name_span.line);
            try s.objectField("character");
            try s.write(d.name_span.col);
            try s.endObject();
            try s.beginArray();
            for (idx.refs) |r| {
                if (r.back_ref) continue;
                if (!std.mem.eql(u8, r.name, d.name)) continue;
                try writeLocationObject(&s, uri, r.span, r.end);
            }
            try s.endArray();
            try s.endArray();
            try s.endObject();
            try s.endObject();

            // Companion lens: opens the playground webview preselected
            // on this rule. The extension command accepts the rule name
            // as its single argument.
            try s.beginObject();
            try s.objectField("range");
            try writeRange(&s, d.name_span, d.name_end);
            try s.objectField("command");
            try s.beginObject();
            try s.objectField("title");
            try s.write("Match\u{2026}");
            try s.objectField("command");
            try s.write("pars.runRule");
            try s.objectField("arguments");
            try s.beginArray();
            try s.write(d.name);
            try s.endArray();
            try s.endObject();
            try s.endObject();
        }

        try s.endArray();
        try s.endObject();
        try writeMessage(self.writer, aw.writer.buffered());
    }

    // Identifier completion. Sources, in order:
    //   1. Every rule defined in this document (top-level + sub-rules)
    //   2. Captures whose lexical scope encloses the cursor
    //   3. Top-level rules from each `use`d stdlib module
    //   4. Hard-coded language keywords
    // The client filters the returned set by the prefix the user has
    // typed, so we don't need to inspect the cursor surroundings — we
    // just hand back the union of valid identifiers in scope.
    fn handleCompletion(self: *Server, id: std.json.Value, params: std.json.Value) !void {
        const td = params.object.get("textDocument") orelse return self.writeResult(id, .null);
        const uri = getString(td, "uri") orelse return self.writeResult(id, .null);
        const doc = self.documents.get(uri) orelse return self.writeResult(id, .null);
        const pos = getPosition(params) orelse return self.writeResult(id, .null);

        var idx = try symbols.buildIndex(self.alloc, doc.text);
        defer idx.deinit(self.alloc);

        // Find the innermost rule body containing the cursor. Sub-rules
        // appear after their parent in defs[], so iterating forward and
        // taking the last match yields the innermost scope.
        var enclosing_rule: ?u32 = null;
        for (idx.defs, 0..) |d, di| {
            if (positionInBody(d, pos.line, pos.col)) enclosing_rule = @intCast(di);
        }

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer };

        try s.beginObject();
        try s.objectField("jsonrpc");
        try s.write("2.0");
        try s.objectField("id");
        try s.write(id);
        try s.objectField("result");
        try s.beginObject();
        try s.objectField("isIncomplete");
        try s.write(false);
        try s.objectField("items");
        try s.beginArray();

        // De-dup by label across all sources. Names from the document
        // shadow names from stdlib modules, which shadow keywords.
        var seen = std.StringHashMap(void).init(self.alloc);
        defer seen.deinit();

        for (idx.defs) |d| {
            const gop = try seen.getOrPut(d.name);
            if (gop.found_existing) continue;
            const detail: []const u8 = if (d.kind == .top_level) "rule" else "where-binding";
            try writeCompletionItem(&s, d.name, .function, detail);
        }

        if (enclosing_rule) |er| {
            for (idx.captures) |c| {
                const ri = c.rule_index orelse continue;
                if (ri != er) continue;
                const gop = try seen.getOrPut(c.name);
                if (gop.found_existing) continue;
                try writeCompletionItem(&s, c.name, .variable, "capture");
            }
        }

        for (idx.uses) |u| {
            const entry = (try self.loadStdlibModule(u.path)) orelse continue;
            var mod_idx = try symbols.buildIndex(self.alloc, entry.source);
            defer mod_idx.deinit(self.alloc);
            for (mod_idx.defs) |d| {
                if (d.kind != .top_level) continue;
                const gop = try seen.getOrPut(d.name);
                if (gop.found_existing) continue;
                var detail_buf: [128]u8 = undefined;
                const detail = try std.fmt.bufPrint(&detail_buf, "from {s}", .{u.path});
                try writeCompletionItem(&s, d.name, .function, detail);
            }
        }

        const keywords = [_][]const u8{
            "let", "grammar", "extends", "super", "use", "where", "end",
        };
        for (keywords) |kw| {
            const gop = try seen.getOrPut(kw);
            if (gop.found_existing) continue;
            try writeCompletionItem(&s, kw, .keyword, "keyword");
        }

        try s.endArray();
        try s.endObject();
        try s.endObject();

        try writeMessage(self.writer, aw.writer.buffered());
    }

    // Compile the document at `uri` and emit the chunk disassembly as
    // the JSON-RPC result. The payload mirrors debug.writeChunkJson and
    // is consumed by the VSCode bytecode-inspector webview. When
    // compilation fails (the grammar has errors), we still return a
    // well-formed envelope with `errors` populated so the webview can
    // render a useful message instead of a hang.
    fn handleDisassemble(self: *Server, id: std.json.Value, params: std.json.Value) !void {
        const td = params.object.get("textDocument") orelse return self.writeResult(id, .null);
        const uri = getString(td, "uri") orelse return self.writeResult(id, .null);
        const doc = self.documents.get(uri) orelse return self.writeResult(id, .null);

        var obj_pool = ObjPool.init(self.alloc);
        defer obj_pool.deinit();

        var rule_table: RuleTable = .{};
        defer rule_table.deinit(self.alloc);

        var chunk = Chunk.init(self.alloc);
        defer chunk.deinit();

        var compiler = Compiler.init(self.alloc);
        defer compiler.deinit();

        const ok = compiler.compile(doc.text, &chunk, &rule_table, &obj_pool);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer };

        try s.beginObject();
        try s.objectField("jsonrpc");
        try s.write("2.0");
        try s.objectField("id");
        try s.write(id);
        try s.objectField("result");
        try s.beginObject();
        try s.objectField("uri");
        try s.write(uri);
        try s.objectField("ok");
        try s.write(ok);
        if (ok) {
            try s.objectField("main");
            try pars.debug.writeChunkJson(&chunk, &s, self.alloc);
            try s.objectField("rules");
            try s.beginArray();
            for (rule_table.names.items, 0..) |name, i| {
                try s.beginObject();
                try s.objectField("index");
                try s.write(i);
                try s.objectField("name");
                try s.write(name);
                if (rule_table.getChunkPtr(@intCast(i))) |rc| {
                    try s.objectField("disassembly");
                    try pars.debug.writeChunkJson(rc, &s, self.alloc);
                }
                try s.endObject();
            }
            try s.endArray();
        } else {
            try s.objectField("errors");
            try s.beginArray();
            for (compiler.getErrors()) |e| {
                try s.beginObject();
                try s.objectField("line");
                try s.write(if (e.line == 0) 0 else e.line - 1);
                try s.objectField("column");
                try s.write(if (e.column == 0) 0 else e.column - 1);
                try s.objectField("message");
                try s.write(e.message);
                try s.endObject();
            }
            try s.endArray();
        }
        try s.endObject();
        try s.endObject();

        try writeMessage(self.writer, aw.writer.buffered());
    }

    // Compile the document at `uri`, look up the named rule in the
    // resulting rule table, and run the VM against `input` starting at
    // that rule. Used by the playground webview to interactively test
    // a single rule. Returns one of:
    //   { ok: false, kind: "compile_error", errors: [...] }
    //   { ok: false, kind: "no_such_rule", name }
    //   { ok: false, kind: "runtime_error" }
    //   { ok: true,  kind: "match",    end, captures: [...] }
    //   { ok: true,  kind: "no_match" }
    fn handleRunRule(self: *Server, id: std.json.Value, params: std.json.Value) !void {
        const td = params.object.get("textDocument") orelse return self.writeResult(id, .null);
        const uri = getString(td, "uri") orelse return self.writeResult(id, .null);
        const doc = self.documents.get(uri) orelse return self.writeResult(id, .null);
        const rule_name = getString(params, "ruleName") orelse return self.writeResult(id, .null);
        const input = getString(params, "input") orelse "";

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer };

        try s.beginObject();
        try s.objectField("jsonrpc");
        try s.write("2.0");
        try s.objectField("id");
        try s.write(id);
        try s.objectField("result");

        var vm = Vm(null).init(self.alloc);
        defer vm.deinit();

        var entry = Chunk.init(self.alloc);
        defer entry.deinit();

        if (!vm.compiler.compile(doc.text, &entry, &vm.rules, &vm.obj_pool)) {
            try s.beginObject();
            try s.objectField("ok");
            try s.write(false);
            try s.objectField("kind");
            try s.write("compile_error");
            try s.objectField("errors");
            try s.beginArray();
            for (vm.compiler.getErrors()) |e| {
                try s.beginObject();
                try s.objectField("line");
                try s.write(if (e.line == 0) 0 else e.line - 1);
                try s.objectField("column");
                try s.write(if (e.column == 0) 0 else e.column - 1);
                try s.objectField("message");
                try s.write(e.message);
                try s.endObject();
            }
            try s.endArray();
            try s.endObject();
            try s.endObject();
            try writeMessage(self.writer, aw.writer.buffered());
            return;
        }

        const rule_idx = vm.rules.get(rule_name) orelse {
            try s.beginObject();
            try s.objectField("ok");
            try s.write(false);
            try s.objectField("kind");
            try s.write("no_such_rule");
            try s.objectField("name");
            try s.write(rule_name);
            try s.endObject();
            try s.endObject();
            try writeMessage(self.writer, aw.writer.buffered());
            return;
        };

        // Build a 5-byte trampoline that calls the chosen rule and
        // halts. We always emit the wide form so we don't have to
        // branch on the rule index width.
        var trampoline = Chunk.init(self.alloc);
        defer trampoline.deinit();
        const span: SourceSpan = .{ .start = 0, .len = 0, .line = 1 };
        try trampoline.write(@intFromEnum(OpCode.op_call_wide), span);
        try trampoline.write(@intCast(rule_idx & 0xff), span);
        try trampoline.write(@intCast((rule_idx >> 8) & 0xff), span);
        try trampoline.write(@intCast((rule_idx >> 16) & 0xff), span);
        try trampoline.write(@intFromEnum(OpCode.op_halt), span);

        vm.chunk = &trampoline;
        vm.ip = 0;
        vm.input = input;
        vm.pos = 0;
        vm.frame_count = 0;
        vm.bt_top = 0;
        // Sentinel-fill the capture slots so post-run inspection can
        // distinguish "matched the empty string" (len = 0, real start)
        // from "never written" (start = maxInt). The VM leaves slots
        // undefined on init.
        @memset(&vm.captures, .{ .start = std.math.maxInt(usize), .len = 0 });

        const result = vm.run();

        try s.beginObject();
        switch (result) {
            .ok => {
                try s.objectField("ok");
                try s.write(true);
                try s.objectField("kind");
                try s.write("match");
                try s.objectField("end");
                try s.write(vm.pos);
                try s.objectField("captures");
                try s.beginArray();
                try self.writeCapturesForRule(&s, &vm, doc.text, rule_name, rule_idx);
                try s.endArray();
            },
            .no_match => {
                try s.objectField("ok");
                try s.write(true);
                try s.objectField("kind");
                try s.write("no_match");
            },
            .runtime_error => {
                try s.objectField("ok");
                try s.write(false);
                try s.objectField("kind");
                try s.write("runtime_error");
            },
            .compile_error => unreachable,
        }
        try s.endObject();
        try s.endObject();

        try writeMessage(self.writer, aw.writer.buffered());
    }

    /// Emit a JSON array element per capture written by the chosen rule.
    /// Slot indices are the compiler's per-rule allocation order (slot 0
    /// = first `<name: …>` in source, slot 1 = second, …); we walk the
    /// document's symbol index for that rule to recover the names.
    /// Captures left untouched by backtracking are skipped via the
    /// sentinel `start = maxInt` filled in before the run.
    fn writeCapturesForRule(
        self: *Server,
        s: *std.json.Stringify,
        vm: anytype,
        source: []const u8,
        rule_name: []const u8,
        rule_idx: u32,
    ) !void {
        // Determine which slots the rule's chunk *could* have written,
        // so we don't iterate all 256 slots on every call.
        const chunk_ptr = vm.rules.getChunkPtr(rule_idx) orelse return;
        const max_slot = maxCaptureSlot(chunk_ptr);
        if (max_slot == null) return;

        // Map slot → name via the document's symbol index. The compiler
        // assigns slots in source-declaration order, and so does the
        // index walker, so the Nth capture in the rule is at slot N.
        var idx = try symbols.buildIndex(self.alloc, source);
        defer idx.deinit(self.alloc);

        var def_index: ?u32 = null;
        for (idx.defs, 0..) |d, di| {
            if (d.kind == .top_level and std.mem.eql(u8, d.name, rule_name)) {
                def_index = @intCast(di);
                break;
            }
        }

        var slot_names: [256]?[]const u8 = .{null} ** 256;
        if (def_index) |di| {
            var n: u8 = 0;
            for (idx.captures) |c| {
                const cri = c.rule_index orelse continue;
                if (cri != di) continue;
                slot_names[n] = c.name;
                n += 1;
                if (n == 0) break; // overflow guard
            }
        }

        var slot: u16 = 0;
        while (slot <= max_slot.?) : (slot += 1) {
            const span = vm.captures[slot];
            if (span.start == std.math.maxInt(usize)) continue;
            try s.beginObject();
            try s.objectField("slot");
            try s.write(slot);
            if (slot_names[slot]) |name| {
                try s.objectField("name");
                try s.write(name);
            }
            try s.objectField("start");
            try s.write(span.start);
            try s.objectField("len");
            try s.write(span.len);
            try s.objectField("text");
            const end = @min(span.start + span.len, vm.input.len);
            try s.write(vm.input[span.start..end]);
            try s.endObject();
        }
    }

    fn writeLocation(self: *Server, id: std.json.Value, uri: []const u8, span: symbols.Span, end: symbols.End) !void {
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("jsonrpc");
        try s.write("2.0");
        try s.objectField("id");
        try s.write(id);
        try s.objectField("result");
        try s.beginObject();
        try s.objectField("uri");
        try s.write(uri);
        try s.objectField("range");
        try writeRange(&s, span, end);
        try s.endObject();
        try s.endObject();
        try writeMessage(self.writer, aw.writer.buffered());
    }

    fn storeDocument(self: *Server, uri: []const u8, text: []const u8) !void {
        const text_copy = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(text_copy);

        if (self.documents.getEntry(uri)) |entry| {
            self.alloc.free(entry.value_ptr.text);
            entry.value_ptr.* = .{ .text = text_copy };
            return;
        }

        const uri_copy = try self.alloc.dupe(u8, uri);
        errdefer self.alloc.free(uri_copy);
        try self.documents.put(uri_copy, .{ .text = text_copy });
    }

    fn publishDiagnostics(self: *Server, uri: []const u8) !void {
        const doc = self.documents.get(uri) orelse return;
        const diags = try collectDiagnostics(self.alloc, doc.text);
        defer deinitDiagnostics(self.alloc, diags);
        try self.sendDiagnostics(uri, diags);
    }

    fn sendDiagnostics(self: *Server, uri: []const u8, diags: []const Diagnostic) !void {
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer };

        try s.beginObject();
        try s.objectField("jsonrpc");
        try s.write("2.0");
        try s.objectField("method");
        try s.write("textDocument/publishDiagnostics");
        try s.objectField("params");
        try s.beginObject();
        try s.objectField("uri");
        try s.write(uri);
        try s.objectField("diagnostics");
        try s.beginArray();
        for (diags) |d| {
            try s.beginObject();
            try s.objectField("range");
            try s.beginObject();
            try s.objectField("start");
            try s.beginObject();
            try s.objectField("line");
            try s.write(d.line);
            try s.objectField("character");
            try s.write(d.col);
            try s.endObject();
            try s.objectField("end");
            try s.beginObject();
            try s.objectField("line");
            try s.write(d.end_line);
            try s.objectField("character");
            try s.write(d.end_col);
            try s.endObject();
            try s.endObject();
            try s.objectField("severity");
            try s.write(1); // Error
            try s.objectField("source");
            try s.write("pars");
            try s.objectField("message");
            try s.write(d.message);
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
        try s.endObject();

        try writeMessage(self.writer, aw.writer.buffered());
    }

    fn writeResult(self: *Server, id: std.json.Value, result: std.json.Value) !void {
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("jsonrpc");
        try s.write("2.0");
        try s.objectField("id");
        try s.write(id);
        try s.objectField("result");
        try s.write(result);
        try s.endObject();
        try writeMessage(self.writer, aw.writer.buffered());
    }

    fn writeError(self: *Server, id: std.json.Value, code: i32, message: []const u8) !void {
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("jsonrpc");
        try s.write("2.0");
        try s.objectField("id");
        try s.write(id);
        try s.objectField("error");
        try s.beginObject();
        try s.objectField("code");
        try s.write(code);
        try s.objectField("message");
        try s.write(message);
        try s.endObject();
        try s.endObject();
        try writeMessage(self.writer, aw.writer.buffered());
    }

    fn writeParseError(self: *Server, err: anyerror) !void {
        const msg = @errorName(err);
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("jsonrpc");
        try s.write("2.0");
        try s.objectField("id");
        try s.write(null);
        try s.objectField("error");
        try s.beginObject();
        try s.objectField("code");
        try s.write(@as(i32, -32700)); // ParseError
        try s.objectField("message");
        try s.write(msg);
        try s.endObject();
        try s.endObject();
        try writeMessage(self.writer, aw.writer.buffered());
    }
};

pub const Document = struct {
    text: []const u8,
};

/// Loaded stdlib module: filesystem path, `file://` URI, and source
/// bytes. All three slices are owned by the server's allocator.
const StdlibEntry = struct {
    path: []const u8,
    uri: []const u8,
    source: []const u8,
};

/// Result of resolving a ref through the document's `use` list.
const StdlibHit = struct {
    entry: *const StdlibEntry,
    def_index: usize,
};

fn getString(v: std.json.Value, key: []const u8) ?[]const u8 {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const field = obj.get(key) orelse return null;
    return switch (field) {
        .string => |s| s,
        else => null,
    };
}

const Position = struct { line: u32, col: u32 };

fn getPosition(params: std.json.Value) ?Position {
    const pos = params.object.get("position") orelse return null;
    const obj = switch (pos) {
        .object => |o| o,
        else => return null,
    };
    const line = switch (obj.get("line") orelse return null) {
        .integer => |n| @as(u32, @intCast(n)),
        else => return null,
    };
    const col = switch (obj.get("character") orelse return null) {
        .integer => |n| @as(u32, @intCast(n)),
        else => return null,
    };
    return .{ .line = line, .col = col };
}

/// Walk a compiled chunk and return the largest capture slot index
/// referenced by op_capture_begin / op_capture_end / op_match_backref,
/// or null when the chunk uses no captures. We need the upper bound so
/// the playground can iterate just the slots the rule could have
/// written instead of all 256 every call.
fn maxCaptureSlot(c: *const Chunk) ?u8 {
    var max: ?u8 = null;
    var offset: usize = 0;
    while (offset < c.code.items.len) {
        const op = std.enums.fromInt(OpCode, c.code.items[offset]) orelse break;
        switch (op) {
            .op_capture_begin, .op_capture_end, .op_match_backref => {
                const slot = c.code.items[offset + 1];
                if (max == null or slot > max.?) max = slot;
            },
            else => {},
        }
        offset += instructionSize(op);
    }
    return max;
}

/// Width in bytes of one encoded instruction. Mirrors the dispatch
/// table in `decodeInstruction`; kept tiny because callers only need
/// it for offset arithmetic.
fn instructionSize(op: OpCode) usize {
    return switch (op) {
        .op_match_any,
        .op_return,
        .op_fail,
        .op_fail_twice,
        .op_cut,
        .op_longest_begin,
        .op_longest_step,
        .op_longest_end,
        .op_halt,
        => 1,
        .op_match_char,
        .op_match_string,
        .op_match_string_i,
        .op_match_charset,
        .op_call,
        .op_capture_begin,
        .op_capture_end,
        .op_match_backref,
        .op_cut_label,
        => 2,
        .op_choice,
        .op_choice_quant,
        .op_choice_lookahead,
        .op_commit,
        .op_back_commit,
        => 3,
        .op_match_string_wide,
        .op_match_string_i_wide,
        .op_match_charset_wide,
        .op_call_wide,
        .op_cut_label_wide,
        => 4,
    };
}

/// LSP CompletionItemKind constants. Only the values we actually emit
/// are listed; the full enum is documented in the LSP spec.
const CompletionKind = enum(u32) {
    function = 3,
    variable = 6,
    keyword = 14,
};

fn writeCompletionItem(
    s: *std.json.Stringify,
    label: []const u8,
    kind: CompletionKind,
    detail: []const u8,
) !void {
    try s.beginObject();
    try s.objectField("label");
    try s.write(label);
    try s.objectField("kind");
    try s.write(@intFromEnum(kind));
    try s.objectField("detail");
    try s.write(detail);
    try s.endObject();
}

/// True when (line, col) lies within the rule body span recorded on `d`.
/// Used to identify the cursor's enclosing rule for capture lookup.
fn positionInBody(d: symbols.RuleDef, line: u32, col: u32) bool {
    if (line < d.body_start_line or line > d.body_end_line) return false;
    if (line == d.body_start_line and col < d.body_start_col) return false;
    if (line == d.body_end_line and col > d.body_end_col) return false;
    return true;
}

fn writeRange(s: *std.json.Stringify, span: symbols.Span, end: symbols.End) !void {
    try s.beginObject();
    try s.objectField("start");
    try s.beginObject();
    try s.objectField("line");
    try s.write(span.line);
    try s.objectField("character");
    try s.write(span.col);
    try s.endObject();
    try s.objectField("end");
    try s.beginObject();
    try s.objectField("line");
    try s.write(end.line);
    try s.objectField("character");
    try s.write(end.col);
    try s.endObject();
    try s.endObject();
}

/// Kind of symbol the cursor is on, from the reference/rename
/// perspective. Rule names match by name across the whole document;
/// local captures are scoped to one rule body.
const OccKind = enum { rule_name, local_capture };

const OccHit = struct {
    name: []const u8,
    kind: OccKind,
    /// Set when `kind == .local_capture`; the rule whose body the
    /// capture binds within. Ignored for rule-name hits.
    rule_idx: ?u32,
    /// Span of the identifier the cursor landed on. Returned to the
    /// client by prepareRename so the rename UI shows the right range.
    cursor_span: symbols.Span,
    cursor_end: symbols.End,
};

/// Identify the symbol at the cursor position. Checks refs, then defs,
/// then captures — order matters only if a source byte is (somehow)
/// covered by more than one category, which the builder avoids.
fn findOccurrenceAt(idx: *const symbols.Index, line: u32, col: u32) ?OccHit {
    if (idx.refAt(line, col)) |ri| {
        const r = idx.refs[ri];
        return .{
            .name = r.name,
            .kind = if (r.back_ref) .local_capture else .rule_name,
            .rule_idx = if (r.back_ref) r.rule_index else null,
            .cursor_span = r.span,
            .cursor_end = r.end,
        };
    }
    if (idx.defAt(line, col)) |di| {
        const d = idx.defs[di];
        return .{
            .name = d.name,
            .kind = .rule_name,
            .rule_idx = null,
            .cursor_span = d.name_span,
            .cursor_end = d.name_end,
        };
    }
    if (idx.captureAt(line, col)) |ci| {
        const c = idx.captures[ci];
        return .{
            .name = c.name,
            .kind = .local_capture,
            .rule_idx = c.rule_index,
            .cursor_span = c.name_span,
            .cursor_end = c.name_end,
        };
    }
    return null;
}

fn writeOccurrenceLocations(
    s: *std.json.Stringify,
    uri: []const u8,
    idx: *const symbols.Index,
    hit: OccHit,
    include_decl: bool,
) !void {
    switch (hit.kind) {
        .rule_name => {
            if (include_decl) {
                for (idx.defs) |d| {
                    if (!std.mem.eql(u8, d.name, hit.name)) continue;
                    try writeLocationObject(s, uri, d.name_span, d.name_end);
                }
            }
            for (idx.refs) |r| {
                if (r.back_ref) continue;
                if (!std.mem.eql(u8, r.name, hit.name)) continue;
                try writeLocationObject(s, uri, r.span, r.end);
            }
        },
        .local_capture => {
            if (include_decl) {
                for (idx.captures) |c| {
                    if (!std.mem.eql(u8, c.name, hit.name)) continue;
                    if (!eqOptU32(c.rule_index, hit.rule_idx)) continue;
                    try writeLocationObject(s, uri, c.name_span, c.name_end);
                }
            }
            for (idx.refs) |r| {
                if (!r.back_ref) continue;
                if (!std.mem.eql(u8, r.name, hit.name)) continue;
                if (!eqOptU32(r.rule_index, hit.rule_idx)) continue;
                try writeLocationObject(s, uri, r.span, r.end);
            }
        },
    }
}

fn writeOccurrenceTextEdits(
    s: *std.json.Stringify,
    idx: *const symbols.Index,
    hit: OccHit,
    new_name: []const u8,
) !void {
    switch (hit.kind) {
        .rule_name => {
            for (idx.defs) |d| {
                if (!std.mem.eql(u8, d.name, hit.name)) continue;
                try writeTextEdit(s, d.name_span, d.name_end, new_name);
            }
            for (idx.refs) |r| {
                if (r.back_ref) continue;
                if (!std.mem.eql(u8, r.name, hit.name)) continue;
                try writeTextEdit(s, r.span, r.end, new_name);
            }
        },
        .local_capture => {
            for (idx.captures) |c| {
                if (!std.mem.eql(u8, c.name, hit.name)) continue;
                if (!eqOptU32(c.rule_index, hit.rule_idx)) continue;
                try writeTextEdit(s, c.name_span, c.name_end, new_name);
            }
            for (idx.refs) |r| {
                if (!r.back_ref) continue;
                if (!std.mem.eql(u8, r.name, hit.name)) continue;
                if (!eqOptU32(r.rule_index, hit.rule_idx)) continue;
                try writeTextEdit(s, r.span, r.end, new_name);
            }
        },
    }
}

fn eqOptU32(a: ?u32, b: ?u32) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}

fn writeLocationObject(s: *std.json.Stringify, uri: []const u8, span: symbols.Span, end: symbols.End) !void {
    try s.beginObject();
    try s.objectField("uri");
    try s.write(uri);
    try s.objectField("range");
    try writeRange(s, span, end);
    try s.endObject();
}

fn writeTextEdit(s: *std.json.Stringify, span: symbols.Span, end: symbols.End, new_text: []const u8) !void {
    try s.beginObject();
    try s.objectField("range");
    try writeRange(s, span, end);
    try s.objectField("newText");
    try s.write(new_text);
    try s.endObject();
}

/// Conservative pars-identifier check. Same shape as the scanner's
/// identifier rule: starts with `[A-Za-z_]`, continues with
/// `[A-Za-z0-9_]`. Intentionally rejects names that look valid lexically
/// but collide with keywords (rare enough to surface as a rename refusal
/// rather than a successful but broken edit).
fn isValidIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    const first = name[0];
    if (!(std.ascii.isAlphabetic(first) or first == '_')) return false;
    for (name[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    const reserved = [_][]const u8{ "let", "grammar", "extends", "super", "use", "where", "end" };
    for (reserved) |kw| {
        if (std.mem.eql(u8, name, kw)) return false;
    }
    return true;
}

fn writeDocumentSymbol(s: *std.json.Stringify, d: symbols.RuleDef) !void {
    try s.beginObject();
    try s.objectField("name");
    try s.write(d.name);
    try s.objectField("kind");
    // SymbolKind.Function = 12 — pars rules are named patterns that
    // "call" other rules, so Function reads more naturally than
    // Variable or Constant in the outline.
    try s.write(12);
    try s.objectField("range");
    try writeRange(s, d.name_span, .{
        .line = d.body_end_line,
        .col = d.body_end_col,
    });
    try s.objectField("selectionRange");
    try writeRange(s, d.name_span, d.name_end);
    try s.endObject();
}

/// Render a markdown hover for an attribute occurrence inside a
/// `#[...]` list. The first line shows the attribute as it is spelled;
/// the body explains what turning it on means. Unknown attributes get
/// a generic "no description" tooltip — the compiler already errors on
/// them, so the hover only serves as a reminder of the syntax.
fn formatHoverAttribute(alloc: std.mem.Allocator, a: symbols.Attribute) ![]u8 {
    if (std.mem.eql(u8, a.name, "lr")) {
        return try alloc.dupe(
            u8,
            "```pars\n#[lr]\n```\n\n" ++
                "Opts this rule into **direct left recursion** via " ++
                "Warth's seed-growing algorithm. Without this " ++
                "attribute the rule would trigger the runtime " ++
                "\"Left recursion detected\" safeguard.",
        );
    }
    if (std.mem.eql(u8, a.name, "longest")) {
        return try alloc.dupe(
            u8,
            "```pars\n#[longest](A / B / ...)\n```\n\n" ++
                "Prefixes a parenthesised group so the alternatives " ++
                "inside are tried from the same starting position " ++
                "and the **longest** successful match wins. Ties " ++
                "resolve to the earlier arm; if no arm matches, the " ++
                "whole group fails. Unlike ordered `/`, a shorter " ++
                "arm cannot commit and starve a longer one.",
        );
    }
    return try std.fmt.allocPrint(
        alloc,
        "```pars\n#[{s}]\n```\n\n_no description available_",
        .{a.name},
    );
}

/// Render a rule definition as a markdown hover. The body is shown as
/// a fenced `pars` block so the client can re-highlight it, and the
/// kind line (top-level vs sub-rule) gives the reader orientation.
fn formatHoverRule(alloc: std.mem.Allocator, source: []const u8, d: symbols.RuleDef) ![]u8 {
    const body = if (d.body_end > d.body_start) source[d.body_start..d.body_end] else "";
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    const kind_str = switch (d.kind) {
        .top_level => "rule",
        .sub_rule => "sub-rule (where)",
    };
    return try std.fmt.allocPrint(
        alloc,
        "```pars\n{s} = {s}\n```\n\n_{s}_",
        .{ d.name, trimmed, kind_str },
    );
}

test "semantic tokens: identifier and keyword" {
    const alloc = std.testing.allocator;
    const data = try computeSemanticTokens(alloc, "foo = bar;");
    defer alloc.free(data);

    // Expected tokens: foo (type), = (operator), bar (type).
    // Delta-encoded from origin, all on line 0.
    const expected = [_]u32{
        0, 0, 3, 0, 0, // foo (type)
        0, 4, 1, 4, 0, // = (operator)
        0, 2, 3, 0, 0, // bar (type)
    };
    try std.testing.expectEqualSlices(u32, &expected, data);
}

test "semantic tokens: comment in gap" {
    const alloc = std.testing.allocator;
    const src = "-- hello\nfoo";
    const data = try computeSemanticTokens(alloc, src);
    defer alloc.free(data);

    const expected = [_]u32{
        0, 0, 8, 3, 0, // -- hello (comment, 8 bytes)
        1, 0, 3, 0, 0, // foo (type)
    };
    try std.testing.expectEqualSlices(u32, &expected, data);
}

test "semantic tokens: string and number" {
    const alloc = std.testing.allocator;
    const data = try computeSemanticTokens(alloc, "\"hi\" 42");
    defer alloc.free(data);

    const expected = [_]u32{
        0, 0, 4, 1, 0, // "hi" (string, 4 bytes incl. quotes)
        0, 5, 2, 2, 0, // 42
    };
    try std.testing.expectEqualSlices(u32, &expected, data);
}

test "diagnostics: empty source compiles cleanly" {
    const alloc = std.testing.allocator;
    const diags = try collectDiagnostics(alloc, "");
    defer deinitDiagnostics(alloc, diags);
    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "diagnostics: unterminated string yields an error" {
    const alloc = std.testing.allocator;
    const diags = try collectDiagnostics(alloc, "rule = \"oops");
    defer deinitDiagnostics(alloc, diags);
    try std.testing.expect(diags.len > 0);
}

test "framing: round-trip a simple body" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try writeMessage(&aw.writer, "{}");

    const framed = aw.writer.buffered();
    const expected = "Content-Length: 2\r\n\r\n{}";
    try std.testing.expectEqualStrings(expected, framed);

    var reader = std.Io.Reader.fixed(framed);
    const body = (try readMessage(alloc, &reader)) orelse return error.TestExpectedBody;
    defer alloc.free(body);
    try std.testing.expectEqualStrings("{}", body);
}

test "framing: clean EOF returns null" {
    const alloc = std.testing.allocator;
    var reader = std.Io.Reader.fixed("");
    const body = try readMessage(alloc, &reader);
    try std.testing.expect(body == null);
}

test "server: didOpen stores document and publishes diagnostics" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.init(alloc, &aw.writer);
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"foo = bar;"}}}
    ;
    try server.handleMessage(msg);

    const out = aw.writer.buffered();
    // Expect a publishDiagnostics notification with an empty array.
    try std.testing.expect(std.mem.indexOf(u8, out, "publishDiagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "file:///x.pars") != null);
}

test "server: semantic tokens request returns delta-encoded array" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.init(alloc, &aw.writer);
    defer server.deinit();

    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"foo"}}}
    );

    // Discard everything buffered by didOpen so the next assertion
    // only sees the semanticTokens response.
    aw.writer.end = 0;

    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":"file:///x.pars"}}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"data\":[0,0,3,0,0]") != null);
}

test "server: definition jumps from reference to defining rule" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.init(alloc, &aw.writer);
    defer server.deinit();

    // Source: "bar = 'x';\nfoo = bar;" — the second `bar` at line 1,
    // col 6 is a reference; definition is at line 0, col 0.
    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"bar = 'x';\nfoo = bar;"}}}
    );
    aw.writer.end = 0;

    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///x.pars"},"position":{"line":1,"character":7}}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"line\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"character\":0") != null);
}

test "server: hover shows rule body" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.init(alloc, &aw.writer);
    defer server.deinit();

    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"bar = 'x';\nfoo = bar;"}}}
    );
    aw.writer.end = 0;

    // Cursor on the `bar` reference in the second line.
    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///x.pars"},"position":{"line":1,"character":7}}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bar = 'x'") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"markdown\"") != null);
}

test "server: hover on #[lr] shows the attribute explanation" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.init(alloc, &aw.writer);
    defer server.deinit();

    // Source: a single attribute-annotated rule. Cursor lands on the
    // `l` of `lr` (line 0, col 2 inside `#[lr]`).
    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"#[lr] expr = expr / 'x';"}}}
    );
    aw.writer.end = 0;

    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":9,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///x.pars"},"position":{"line":0,"character":2}}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":9") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "#[lr]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "left recursion") != null);
}

test "server: hover on #[longest] shows the attribute explanation" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.init(alloc, &aw.writer);
    defer server.deinit();

    // Source: a rule whose body uses `#[longest](...)`. Cursor lands on
    // the `l` of `longest` (line 0, col 9 inside `foo = #[longest]...`).
    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"foo = #[longest]('a' / 'ab');"}}}
    );
    aw.writer.end = 0;

    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":9,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///x.pars"},"position":{"line":0,"character":9}}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":9") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "#[longest]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "longest") != null);
}

test "semantic tokens: #[lr] tags the whole list as decorator" {
    const alloc = std.testing.allocator;
    const data = try computeSemanticTokens(alloc, "#[lr] foo");
    defer alloc.free(data);

    // Expected tokens, all on line 0, all delta-encoded from origin:
    //   `#`  at col 0, len 1, decorator (6)
    //   `[`  at col 1, len 1, decorator (6)
    //   `lr` at col 2, len 2, decorator (6)
    //   `]`  at col 4, len 1, decorator (6)
    //   `foo` at col 6, len 3, type (0)
    const expected = [_]u32{
        0, 0, 1, 6, 0, // #
        0, 1, 1, 6, 0, // [
        0, 1, 2, 6, 0, // lr
        0, 2, 1, 6, 0, // ]
        0, 2, 3, 0, 0, // foo
    };
    try std.testing.expectEqualSlices(u32, &expected, data);
}

test "server: definition falls back to std/abnf module source" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.initWithIo(alloc, std.testing.io, &aw.writer);
    defer server.deinit();

    // `use "std/abnf"; foo = DIGIT;` — cursor on the `DIGIT` ref. The
    // local index has no `DIGIT` definition, so the server must resolve
    // it by loading lib/abnf.pars and returning a location whose URI
    // points into that file.
    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"use \"std/abnf\";\nfoo = DIGIT;"}}}
    );
    aw.writer.end = 0;

    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":10,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///x.pars"},"position":{"line":1,"character":7}}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":10") != null);
    // The response URI must point at a file, not the original document.
    try std.testing.expect(std.mem.indexOf(u8, out, "file:///x.pars") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "abnf.pars") != null);
}

test "server: hover renders body from std/abnf module source" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.initWithIo(alloc, std.testing.io, &aw.writer);
    defer server.deinit();

    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"use \"std/abnf\";\nfoo = DIGIT;"}}}
    );
    aw.writer.end = 0;

    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":11,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///x.pars"},"position":{"line":1,"character":7}}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":11") != null);
    // lib/abnf.pars defines DIGIT as the charset ['0'-'9'].
    try std.testing.expect(std.mem.indexOf(u8, out, "DIGIT") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "'0'-'9'") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"markdown\"") != null);
}

test "server: documentSymbol lists top-level rules" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.init(alloc, &aw.writer);
    defer server.deinit();

    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"a = 'x';\nb = 'y';"}}}
    );
    aw.writer.end = 0;

    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///x.pars"}}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"b\"") != null);
}

test "server: inlay hints flag capture back-references" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.init(alloc, &aw.writer);
    defer server.deinit();

    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"r = <q: 'a'> q;"}}}
    );
    aw.writer.end = 0;

    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":5,"method":"textDocument/inlayHint","params":{"textDocument":{"uri":"file:///x.pars"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":99}}}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ": backref") != null);
}

test "server: references returns def + refs of a rule name" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.init(alloc, &aw.writer);
    defer server.deinit();

    // Source: `bar = 'x';\nfoo = bar bar;` — cursor on first bar ref
    // (line 1, col 6). We should see 3 locations: def at (0,0), ref at
    // (1,6), ref at (1,10).
    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"bar = 'x';\nfoo = bar bar;"}}}
    );
    aw.writer.end = 0;

    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":20,"method":"textDocument/references","params":{"textDocument":{"uri":"file:///x.pars"},"position":{"line":1,"character":7},"context":{"includeDeclaration":true}}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":20") != null);
    // All three occurrences present.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"line\":0,\"character\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"line\":1,\"character\":6") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"line\":1,\"character\":10") != null);
}

test "server: references scopes back-refs to their rule" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.init(alloc, &aw.writer);
    defer server.deinit();

    // `a = <q: 'x'> q;\nb = q;` — cursor on the capture `q` in rule a.
    // The back-ref in rule a matches; the `q` in rule b does not
    // (different scope and a rule-name ref, not a back-ref).
    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"a = <q: 'x'> q;\nb = q;"}}}
    );
    aw.writer.end = 0;

    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":21,"method":"textDocument/references","params":{"textDocument":{"uri":"file:///x.pars"},"position":{"line":0,"character":5},"context":{"includeDeclaration":true}}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":21") != null);
    // The capture position (line 0, col 5) must be present as the decl.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"line\":0,\"character\":5") != null);
    // The back-ref at line 0, col 13 must also be present.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"line\":0,\"character\":13") != null);
    // The ref in rule b (line 1, col 4) must NOT appear — different scope.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"line\":1,\"character\":4") == null);
}

test "server: prepareRename returns range for a local rule" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.init(alloc, &aw.writer);
    defer server.deinit();

    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"bar = 'x';\nfoo = bar;"}}}
    );
    aw.writer.end = 0;

    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":22,"method":"textDocument/prepareRename","params":{"textDocument":{"uri":"file:///x.pars"},"position":{"line":1,"character":7}}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":22") != null);
    // Range covers `bar` at (1,6)..(1,9).
    try std.testing.expect(std.mem.indexOf(u8, out, "\"line\":1,\"character\":6") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"line\":1,\"character\":9") != null);
}

test "server: prepareRename refuses unknown (stdlib) rule" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.init(alloc, &aw.writer);
    defer server.deinit();

    // `use "std/abnf"; foo = DIGIT;` — cursor on `DIGIT`. It is not
    // defined locally, so prepareRename must return null.
    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"use \"std/abnf\";\nfoo = DIGIT;"}}}
    );
    aw.writer.end = 0;

    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":23,"method":"textDocument/prepareRename","params":{"textDocument":{"uri":"file:///x.pars"},"position":{"line":1,"character":7}}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":23") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"result\":null") != null);
}

test "server: rename emits text edits for every occurrence" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.init(alloc, &aw.writer);
    defer server.deinit();

    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"bar = 'x';\nfoo = bar;"}}}
    );
    aw.writer.end = 0;

    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":24,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///x.pars"},"position":{"line":0,"character":0},"newName":"baz"}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":24") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"changes\"") != null);
    // Two edits of `bar` → `baz`: one at the def (0,0)..(0,3), one at
    // the ref (1,6)..(1,9).
    try std.testing.expect(std.mem.indexOf(u8, out, "\"newText\":\"baz\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"line\":0,\"character\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"line\":1,\"character\":6") != null);
}

test "server: rename rejects invalid identifiers" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.init(alloc, &aw.writer);
    defer server.deinit();

    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"bar = 'x';"}}}
    );
    aw.writer.end = 0;

    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":25,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///x.pars"},"position":{"line":0,"character":0},"newName":"9bad"}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":25") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"error\"") != null);
}

test "server: codeLens emits one lens per top-level rule" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.init(alloc, &aw.writer);
    defer server.deinit();

    // bar has 2 refs, foo has 0 refs. Both lenses are emitted.
    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"bar = 'x';\nfoo = bar bar;"}}}
    );
    aw.writer.end = 0;

    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":26,"method":"textDocument/codeLens","params":{"textDocument":{"uri":"file:///x.pars"}}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":26") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"2 references\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"0 references\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"pars.showReferences\"") != null);
    // Each rule also gets a "Match…" lens that opens the playground
    // preselected on it. The ellipsis is u+2026; spelled as the UTF-8
    // bytes here so the literal string check matches the JSON output.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"Match\u{2026}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"pars.runRule\"") != null);
}

test "server: disassemble returns structured bytecode" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.init(alloc, &aw.writer);
    defer server.deinit();

    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"\"hi\""}}}
    );
    aw.writer.end = 0;

    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":99,"method":"pars/disassemble","params":{"textDocument":{"uri":"file:///x.pars"}}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":99") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"rules\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"OP_MATCH_STRING\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"OP_HALT\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"span\"") != null);
}

test "server: completion lists rules, captures-in-scope, and keywords" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.init(alloc, &aw.writer);
    defer server.deinit();

    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"foo = <q: 'a'> q;\nbar = foo;"}}}
    );
    aw.writer.end = 0;

    // Cursor inside foo's body (line 0, after "<q: 'a'> ").
    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":50,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///x.pars"},"position":{"line":0,"character":15}}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":50") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"isIncomplete\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"label\":\"foo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"label\":\"bar\"") != null);
    // Capture is in scope inside foo's body.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"label\":\"q\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"label\":\"where\"") != null);
}

test "server: completion omits captures when cursor is outside any rule" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.init(alloc, &aw.writer);
    defer server.deinit();

    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"foo = <q: 'a'> q;"}}}
    );
    aw.writer.end = 0;

    // Cursor at column 0, before any rule body opens.
    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":51,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///x.pars"},"position":{"line":0,"character":0}}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":51") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"label\":\"foo\"") != null);
    // No `q` capture should be offered outside the rule body.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"label\":\"q\"") == null);
}

test "server: runRule matches and exposes named captures" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.init(alloc, &aw.writer);
    defer server.deinit();

    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"greet = <who: ['a'-'z']+> '!';"}}}
    );
    aw.writer.end = 0;

    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":201,"method":"pars/runRule","params":{"textDocument":{"uri":"file:///x.pars"},"ruleName":"greet","input":"world!"}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":201") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"match\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"end\":6") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"who\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"text\":\"world\"") != null);
}

test "server: runRule reports no_match" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.init(alloc, &aw.writer);
    defer server.deinit();

    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"greet = \"hi\";"}}}
    );
    aw.writer.end = 0;

    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":202,"method":"pars/runRule","params":{"textDocument":{"uri":"file:///x.pars"},"ruleName":"greet","input":"bye"}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"no_match\"") != null);
}

test "server: runRule reports unknown rule" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.init(alloc, &aw.writer);
    defer server.deinit();

    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"foo = 'x';"}}}
    );
    aw.writer.end = 0;

    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":203,"method":"pars/runRule","params":{"textDocument":{"uri":"file:///x.pars"},"ruleName":"missing","input":""}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"no_such_rule\"") != null);
}

test "server: runRule surfaces compile errors" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.init(alloc, &aw.writer);
    defer server.deinit();

    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"foo = "}}}
    );
    aw.writer.end = 0;

    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":204,"method":"pars/runRule","params":{"textDocument":{"uri":"file:///x.pars"},"ruleName":"foo","input":""}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"compile_error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"errors\"") != null);
}

test "server: disassemble reports compile errors" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var server = Server.init(alloc, &aw.writer);
    defer server.deinit();

    try server.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.pars","languageId":"pars","version":1,"text":"foo = "}}}
    );
    aw.writer.end = 0;

    try server.handleMessage(
        \\{"jsonrpc":"2.0","id":100,"method":"pars/disassemble","params":{"textDocument":{"uri":"file:///x.pars"}}}
    );

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"errors\"") != null);
}
