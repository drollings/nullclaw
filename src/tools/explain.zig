const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const explain_mod = @import("../explain/root.zig");

/// MCP tool: search the pre-compiled AST guidance index (`.explain.db`).
///
/// The database is compiled externally by `ast-guidance` (`make explain-sync`).
/// NullClaw is a read-only consumer.  This tool performs BM25 full-text search
/// and returns ranked results with signatures, comments, line numbers, and
/// `used_by` cross-references.
///
/// Optional local LLM summarization is controlled by `config.explain.enabled`.
pub const ExplainTool = struct {
    workspace_dir: []const u8,

    pub const tool_name = "explain";
    pub const tool_description =
        "Search the codebase AST guidance index for functions, types, and definitions " ++
        "matching a query. Returns ranked results with signatures, comments, line numbers, " ++
        "and cross-references. Requires a pre-compiled .explain.db " ++
        "(run 'make explain-sync' in ast-guidance to generate it).";
    pub const tool_params =
        \\{"type":"object","properties":{"query":{"type":"string","description":"Search terms describing what you are looking for"},"limit":{"type":"integer","description":"Maximum results to return (default: 10, max: 50)"},"json":{"type":"boolean","description":"Return raw JSON instead of human-readable text"}},"required":["query"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ExplainTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *ExplainTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        if (comptime !explain_mod.enabled) {
            return ToolResult.fail("explain requires SQLite support (build with -Dengines=sqlite)");
        }

        const query = root.getString(args, "query") orelse
            return ToolResult.fail("Missing 'query' parameter");
        if (query.len == 0) return ToolResult.fail("'query' must not be empty");

        const limit_raw = root.getInt(args, "limit") orelse 10;
        const limit: usize = if (limit_raw > 0 and limit_raw <= 50) @intCast(limit_raw) else 10;
        const json_mode = root.getBool(args, "json") orelse false;

        // Resolve database path.
        const db_path = explain_mod.resolveDatabasePath(allocator, self.workspace_dir) catch |err| {
            if (err == error.DbNotFound) {
                const msg = try explain_mod.missingDbMessage(allocator, self.workspace_dir);
                return ToolResult{ .success = false, .output = msg };
            }
            const msg = try std.fmt.allocPrint(
                allocator,
                "Failed to resolve .explain.db path: {s}",
                .{@errorName(err)},
            );
            return ToolResult{ .success = false, .output = msg };
        };
        defer allocator.free(db_path);

        var db = explain_mod.ExplainDb.init(allocator, db_path) catch |err| {
            if (err == error.SqliteOpenFailed) {
                const msg = try explain_mod.missingDbMessage(allocator, self.workspace_dir);
                return ToolResult{ .success = false, .output = msg };
            }
            const msg = try std.fmt.allocPrint(
                allocator,
                "Failed to open .explain.db at {s}: {s}",
                .{ db_path, @errorName(err) },
            );
            return ToolResult{ .success = false, .output = msg };
        };
        defer db.deinit();

        const results = db.search(allocator, query, limit) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Search failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        defer {
            for (results) |r| explain_mod.freeSearchResult(allocator, r);
            allocator.free(results);
        }

        if (results.len == 0) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "No results found for: {s}\n\nTip: broaden your search terms, or run 'make explain-sync' in ast-guidance to rebuild the index.",
                .{query},
            );
            return ToolResult{ .success = true, .output = msg };
        }

        if (json_mode) {
            return formatJsonOutput(allocator, query, results);
        } else {
            return formatTextOutput(allocator, query, results);
        }
    }

    /// Human-readable output format.
    fn formatTextOutput(
        allocator: std.mem.Allocator,
        query: []const u8,
        results: []const explain_mod.SearchResult,
    ) !ToolResult {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);

        try buf.appendSlice(allocator, "# Explain: ");
        try buf.appendSlice(allocator, query);
        try buf.appendSlice(allocator, "\n\n");

        for (results, 1..) |r, i| {
            // "1. functionName (fn_decl) — src.module.path"
            var n_buf: [16]u8 = undefined;
            const n_str = std.fmt.bufPrint(&n_buf, "{d}", .{i}) catch "?";
            try buf.appendSlice(allocator, n_str);
            try buf.appendSlice(allocator, ". **");
            try buf.appendSlice(allocator, r.name);
            try buf.appendSlice(allocator, "** (");
            try buf.appendSlice(allocator, r.node_type);
            try buf.appendSlice(allocator, ") — ");
            try buf.appendSlice(allocator, r.module);
            if (r.line) |ln| {
                var ln_buf: [16]u8 = undefined;
                const ln_str = std.fmt.bufPrint(&ln_buf, ":{d}", .{ln}) catch "";
                try buf.appendSlice(allocator, ln_str);
            }
            try buf.append(allocator, '\n');

            // Comment line.
            if (r.comment) |comment| {
                const nl = std.mem.indexOfScalar(u8, comment, '\n') orelse comment.len;
                const snippet = comment[0..@min(nl, 120)];
                try buf.appendSlice(allocator, "   ");
                try buf.appendSlice(allocator, snippet);
                try buf.append(allocator, '\n');
            }

            // Signature.
            if (r.signature) |sig| {
                try buf.appendSlice(allocator, "   `");
                try buf.appendSlice(allocator, sig);
                try buf.appendSlice(allocator, "`\n");
            }

            // Used-by cross-references.
            if (r.used_by) |ub| {
                if (ub.len > 2) { // non-empty JSON array has at least "[]"
                    try buf.appendSlice(allocator, "   Used by: ");
                    try buf.appendSlice(allocator, ub);
                    try buf.append(allocator, '\n');
                }
            }

            try buf.append(allocator, '\n');
        }

        return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }

    /// JSON output format.
    fn formatJsonOutput(
        allocator: std.mem.Allocator,
        query: []const u8,
        results: []const explain_mod.SearchResult,
    ) !ToolResult {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);

        try buf.appendSlice(allocator, "{\"query\":\"");
        try appendJsonEscaped(&buf, allocator, query);
        try buf.appendSlice(allocator, "\",\"results\":[\n");

        for (results, 0..) |r, i| {
            try buf.appendSlice(allocator, "  {");
            try buf.appendSlice(allocator, "\"module\":\"");
            try appendJsonEscaped(&buf, allocator, r.module);
            try buf.appendSlice(allocator, "\",\"name\":\"");
            try appendJsonEscaped(&buf, allocator, r.name);
            try buf.appendSlice(allocator, "\",\"type\":\"");
            try appendJsonEscaped(&buf, allocator, r.node_type);
            try buf.appendSlice(allocator, "\"");

            if (r.signature) |sig| {
                try buf.appendSlice(allocator, ",\"signature\":\"");
                try appendJsonEscaped(&buf, allocator, sig);
                try buf.appendSlice(allocator, "\"");
            }
            if (r.comment) |comment| {
                const nl = std.mem.indexOfScalar(u8, comment, '\n') orelse comment.len;
                try buf.appendSlice(allocator, ",\"comment\":\"");
                try appendJsonEscaped(&buf, allocator, comment[0..@min(nl, 200)]);
                try buf.appendSlice(allocator, "\"");
            }
            if (r.line) |ln| {
                var ln_buf: [16]u8 = undefined;
                const ln_str = std.fmt.bufPrint(&ln_buf, ",\"line\":{d}", .{ln}) catch "";
                try buf.appendSlice(allocator, ln_str);
            }
            if (r.used_by) |ub| {
                // used_by is already a JSON array string — embed verbatim.
                try buf.appendSlice(allocator, ",\"used_by\":");
                try buf.appendSlice(allocator, ub);
            }
            var score_buf: [32]u8 = undefined;
            const score_str = std.fmt.bufPrint(&score_buf, ",\"score\":{d:.4}", .{r.score}) catch "";
            try buf.appendSlice(allocator, score_str);
            try buf.appendSlice(allocator, "}");
            if (i < results.len - 1) try buf.appendSlice(allocator, ",");
            try buf.append(allocator, '\n');
        }

        try buf.appendSlice(allocator, "]}\n");

        return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }

    fn appendJsonEscaped(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) !void {
        for (s) |ch| {
            switch (ch) {
                '"' => try buf.appendSlice(allocator, "\\\""),
                '\\' => try buf.appendSlice(allocator, "\\\\"),
                '\n' => try buf.appendSlice(allocator, "\\n"),
                '\r' => try buf.appendSlice(allocator, "\\r"),
                '\t' => try buf.appendSlice(allocator, "\\t"),
                else => try buf.append(allocator, ch),
            }
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "explain tool name" {
    var t = ExplainTool{ .workspace_dir = "/tmp" };
    try std.testing.expectEqualStrings("explain", t.tool().name());
}

test "explain schema has query and limit" {
    var t = ExplainTool{ .workspace_dir = "/tmp" };
    const schema = t.tool().parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "query") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "limit") != null);
}

test "explain missing query returns error" {
    var t = ExplainTool{ .workspace_dir = "/tmp" };
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "explain no database returns helpful error" {
    if (comptime !explain_mod.enabled) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    var t = ExplainTool{ .workspace_dir = workspace };
    const parsed = try root.parseTestArgs("{\"query\": \"widget\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "explain-sync") != null);
}

test "explain round-trip with pre-built database" {
    if (comptime !explain_mod.enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create .explain.db with the correct schema.
    const db_path = try std.fmt.allocPrint(allocator, "{s}/.explain.db", .{tmp_path});
    defer allocator.free(db_path);
    {
        const db_path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(db_path_z);
        var db: ?*explain_mod.c.sqlite3 = null;
        _ = explain_mod.c.sqlite3_open(db_path_z.ptr, &db);
        defer _ = explain_mod.c.sqlite3_close(db);
        var err_msg: [*c]u8 = null;
        _ = explain_mod.c.sqlite3_exec(db,
            \\CREATE TABLE ast_nodes(id INTEGER PRIMARY KEY,file_path TEXT NOT NULL,
            \\  module TEXT NOT NULL,node_type TEXT NOT NULL,name TEXT NOT NULL,
            \\  signature TEXT,comment TEXT,line INTEGER,used_by TEXT,last_modified INTEGER NOT NULL);
            \\CREATE VIRTUAL TABLE fts_search USING fts5(name,comment,module,signature,
            \\  content='ast_nodes',content_rowid='id');
            \\INSERT INTO ast_nodes VALUES(1,'src/widget.zig.json','src.widget','fn_decl','renderWidget',
            \\  'fn renderWidget(ctx: *Context) void','Renders the main widget.',10,'["src/main.zig"]',0);
            \\INSERT INTO fts_search(rowid,name,comment,module,signature)
            \\  VALUES(1,'renderWidget','Renders the main widget.','src.widget','fn renderWidget(ctx: *Context) void');
        , null, null, &err_msg);
        if (err_msg) |msg| explain_mod.c.sqlite3_free(msg);
    }

    var t = ExplainTool{ .workspace_dir = tmp_path };
    const parsed = try root.parseTestArgs("{\"query\": \"renderWidget\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "renderWidget") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "src.widget") != null);
}
