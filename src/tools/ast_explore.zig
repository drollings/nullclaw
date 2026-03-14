const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const ast_explain = @import("../ast_explain/root.zig");

/// MCP tool: search the AST guidance index with BM25 full-text search.
///
/// Queries the FTS5 index in `.ast-explain/ast-explain.db` and returns ranked
/// results with module, name, type, and signature.  Suitable for RALPH-loop
/// codebase exploration.
pub const AstExploreTool = struct {
    workspace_dir: []const u8,

    pub const tool_name = "ast_explore";
    pub const tool_description =
        "Search the codebase AST guidance index for functions, types, and definitions " ++
        "matching a query. Returns results ranked by BM25 relevance. " ++
        "Run ast_sync first to build the index.";
    pub const tool_params =
        \\{"type":"object","properties":{"query":{"type":"string","description":"Search terms (space-separated words, each matched with OR)"},"limit":{"type":"integer","description":"Maximum results to return (default: 10, max: 50)"}},"required":["query"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *AstExploreTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *AstExploreTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        if (comptime !ast_explain.enabled) {
            return ToolResult.fail("ast_explore requires SQLite support (build with -Dengines=sqlite)");
        }

        const query = root.getString(args, "query") orelse
            return ToolResult.fail("Missing 'query' parameter");
        if (query.len == 0) return ToolResult.fail("'query' must not be empty");

        const limit_raw = root.getInt(args, "limit") orelse 10;
        const limit: usize = if (limit_raw > 0 and limit_raw <= 50) @intCast(limit_raw) else 10;

        const db_path = ast_explain.resolveDatabasePath(allocator, self.workspace_dir) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to resolve db path: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        defer allocator.free(db_path);

        var db = ast_explain.AstDb.init(allocator, db_path) catch |err| {
            if (err == error.SqliteOpenFailed) {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "AST guidance database not found at {s}. Run ast_sync first.",
                    .{db_path},
                );
                return ToolResult{ .success = false, .output = msg };
            }
            const msg = try std.fmt.allocPrint(allocator, "Failed to open AST guidance database: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        defer db.deinit();

        const results = db.search(allocator, query, limit) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Search failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        defer {
            for (results) |r| ast_explain.freeSearchResult(allocator, r);
            allocator.free(results);
        }

        if (results.len == 0) {
            const msg = try std.fmt.allocPrint(allocator, "No results found for: {s}", .{query});
            return ToolResult{ .success = true, .output = msg };
        }

        return formatResults(allocator, query, results);
    }

    fn formatResults(
        allocator: std.mem.Allocator,
        query: []const u8,
        results: []const ast_explain.SearchResult,
    ) !ToolResult {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);

        try buf.appendSlice(allocator, "# AST Explore: ");
        try buf.appendSlice(allocator, query);
        try buf.append(allocator, '\n');

        var count_str: [20]u8 = undefined;
        const n_str = std.fmt.bufPrint(&count_str, "{d}", .{results.len}) catch "?";
        try buf.appendSlice(allocator, n_str);
        try buf.appendSlice(allocator, if (results.len == 1) " result\n\n" else " results\n\n");

        for (results, 1..) |r, i| {
            var idx_buf: [20]u8 = undefined;
            const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch "?";
            try buf.appendSlice(allocator, idx_str);
            try buf.appendSlice(allocator, ". **");
            try buf.appendSlice(allocator, r.name);
            try buf.appendSlice(allocator, "** (");
            try buf.appendSlice(allocator, r.node_type);
            try buf.appendSlice(allocator, ") — `");
            try buf.appendSlice(allocator, r.module);
            try buf.appendSlice(allocator, "`\n");
            if (r.signature) |sig| {
                try buf.appendSlice(allocator, "   Signature: `");
                try buf.appendSlice(allocator, sig);
                try buf.appendSlice(allocator, "`\n");
            }
            var score_buf: [32]u8 = undefined;
            const score_str = std.fmt.bufPrint(&score_buf, "   Score: {d:.3}\n", .{r.score}) catch "";
            try buf.appendSlice(allocator, score_str);
        }

        return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "ast_explore tool name" {
    var t = AstExploreTool{ .workspace_dir = "/tmp" };
    try std.testing.expectEqualStrings("ast_explore", t.tool().name());
}

test "ast_explore schema has query" {
    var t = AstExploreTool{ .workspace_dir = "/tmp" };
    const schema = t.tool().parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "query") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "limit") != null);
}

test "ast_explore missing query" {
    var t = AstExploreTool{ .workspace_dir = "/tmp" };
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "ast_explore no database returns error" {
    if (comptime !ast_explain.enabled) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    var t = AstExploreTool{ .workspace_dir = workspace };
    const parsed = try root.parseTestArgs("{\"query\": \"frobnicate\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ast_sync") != null);
}

test "ast_explore round-trip with real index" {
    if (comptime !ast_explain.enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);

    // Build the index manually
    try tmp.dir.makePath(".ast-explain/src");
    const json_data =
        \\{
        \\  "meta": { "module": "src.widget", "source": "src/widget.zig", "language": "zig" },
        \\  "comment": "Widget module.",
        \\  "members": [
        \\    { "type": "fn_decl", "name": "render", "comment": "Renders the widget to screen." }
        \\  ]
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = ".ast-explain/src/widget.zig.json", .data = json_data });

    const db_path = try ast_explain.resolveDatabasePath(allocator, workspace);
    defer allocator.free(db_path);

    var db = try ast_explain.AstDb.init(allocator, db_path);
    const src_dir = try ast_explain.resolveSrcDir(allocator, workspace);
    defer allocator.free(src_dir);
    _ = try db.syncFromDir(allocator, src_dir);
    db.deinit();

    var t = AstExploreTool{ .workspace_dir = workspace };
    const parsed = try root.parseTestArgs("{\"query\": \"render\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "render") != null);
}
