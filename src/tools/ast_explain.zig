const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const ast_explain = @import("../ast_explain/root.zig");

/// MCP tool: search the AST guidance index and return results with contextual summary.
///
/// Performs the same BM25 search as `ast_explore` but formats output as a structured
/// JSON payload with a human-readable summary header — suitable for feeding into
/// subsequent agent reasoning steps or the RALPH loop.
///
/// Milestone 4 (local inference) will add an AI-generated summary field when a
/// local LLM is configured.  Until then, the summary is generated from result metadata.
pub const AstExplainTool = struct {
    workspace_dir: []const u8,

    pub const tool_name = "ast_explain";
    pub const tool_description =
        "Search the codebase AST guidance index and return a contextual explanation of the results. " ++
        "Use when you need to understand code structure, find relevant functions or types, or get " ++
        "a summary of what a module provides. Returns ranked results with signatures and descriptions.";
    pub const tool_params =
        \\{"type":"object","properties":{"query":{"type":"string","description":"Search terms describing what you are looking for"},"limit":{"type":"integer","description":"Maximum results to include (default: 5, max: 20)"}},"required":["query"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *AstExplainTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *AstExplainTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        if (comptime !ast_explain.enabled) {
            return ToolResult.fail("ast_explain requires SQLite support (build with -Dengines=sqlite)");
        }

        const query = root.getString(args, "query") orelse
            return ToolResult.fail("Missing 'query' parameter");
        if (query.len == 0) return ToolResult.fail("'query' must not be empty");

        const limit_raw = root.getInt(args, "limit") orelse 5;
        const limit: usize = if (limit_raw > 0 and limit_raw <= 20) @intCast(limit_raw) else 5;

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
            const msg = try std.fmt.allocPrint(
                allocator,
                "No AST guidance found for: {s}\n\nSuggestion: run ast_sync to update the index, or try broader search terms.",
                .{query},
            );
            return ToolResult{ .success = true, .output = msg };
        }

        return formatExplainOutput(allocator, query, results);
    }

    /// Format explain output: summary line followed by JSON results array.
    fn formatExplainOutput(
        allocator: std.mem.Allocator,
        query: []const u8,
        results: []const ast_explain.SearchResult,
    ) !ToolResult {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);

        // Summary line
        var n_buf: [20]u8 = undefined;
        const n_str = std.fmt.bufPrint(&n_buf, "{d}", .{results.len}) catch "?";
        try buf.appendSlice(allocator, "Found ");
        try buf.appendSlice(allocator, n_str);
        try buf.appendSlice(allocator, if (results.len == 1) " result" else " results");
        try buf.appendSlice(allocator, " for \"");
        try buf.appendSlice(allocator, query);
        try buf.appendSlice(allocator, "\":\n\n");

        // JSON array of results
        try buf.appendSlice(allocator, "[\n");
        for (results, 0..) |r, i| {
            try buf.appendSlice(allocator, "  {\n");

            try buf.appendSlice(allocator, "    \"module\": \"");
            try appendJsonEscaped(&buf, allocator, r.module);
            try buf.appendSlice(allocator, "\",\n");

            try buf.appendSlice(allocator, "    \"name\": \"");
            try appendJsonEscaped(&buf, allocator, r.name);
            try buf.appendSlice(allocator, "\",\n");

            try buf.appendSlice(allocator, "    \"type\": \"");
            try appendJsonEscaped(&buf, allocator, r.node_type);
            try buf.appendSlice(allocator, "\",\n");

            if (r.signature) |sig| {
                try buf.appendSlice(allocator, "    \"signature\": \"");
                try appendJsonEscaped(&buf, allocator, sig);
                try buf.appendSlice(allocator, "\",\n");
            } else {
                try buf.appendSlice(allocator, "    \"signature\": null,\n");
            }

            var score_buf: [32]u8 = undefined;
            const score_str = std.fmt.bufPrint(&score_buf, "{d:.4}", .{r.score}) catch "0";
            try buf.appendSlice(allocator, "    \"score\": ");
            try buf.appendSlice(allocator, score_str);
            try buf.append(allocator, '\n');

            try buf.appendSlice(allocator, "  }");
            if (i < results.len - 1) try buf.appendSlice(allocator, ",");
            try buf.append(allocator, '\n');
        }
        try buf.appendSlice(allocator, "]\n");

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

test "ast_explain tool name" {
    var t = AstExplainTool{ .workspace_dir = "/tmp" };
    try std.testing.expectEqualStrings("ast_explain", t.tool().name());
}

test "ast_explain schema has query" {
    var t = AstExplainTool{ .workspace_dir = "/tmp" };
    const schema = t.tool().parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "query") != null);
}

test "ast_explain missing query" {
    var t = AstExplainTool{ .workspace_dir = "/tmp" };
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "ast_explain no database returns helpful error" {
    if (comptime !ast_explain.enabled) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    var t = AstExplainTool{ .workspace_dir = workspace };
    const parsed = try root.parseTestArgs("{\"query\": \"widget\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ast_sync") != null);
}

test "ast_explain round-trip with real index" {
    if (comptime !ast_explain.enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);

    try tmp.dir.makePath(".ast-explain/src");
    const json_data =
        \\{
        \\  "meta": { "module": "src.parser", "source": "src/parser.zig", "language": "zig" },
        \\  "comment": "Parser module.",
        \\  "members": [
        \\    { "type": "fn_decl", "name": "parse", "signature": "fn parse(input: []const u8) !Ast", "comment": "Parses the input into an AST." }
        \\  ]
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = ".ast-explain/src/parser.zig.json", .data = json_data });

    const db_path = try ast_explain.resolveDatabasePath(allocator, workspace);
    defer allocator.free(db_path);

    var db = try ast_explain.AstDb.init(allocator, db_path);
    const src_dir = try ast_explain.resolveSrcDir(allocator, workspace);
    defer allocator.free(src_dir);
    _ = try db.syncFromDir(allocator, src_dir);
    db.deinit();

    var t = AstExplainTool{ .workspace_dir = workspace };
    const parsed = try root.parseTestArgs("{\"query\": \"parse\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "parse") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "score") != null);
}
