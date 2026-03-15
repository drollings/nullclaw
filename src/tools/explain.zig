const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const explain_mod = @import("../explain/root.zig");
const explain_staged = explain_mod.staged;
const explain_summarize = explain_mod.summarize;
const ExplainConfig = @import("../config_types.zig").ExplainConfig;

/// MCP tool: search the pre-compiled AST guidance index (`.explain.db`).
///
/// The database is compiled externally by explain-gen.
/// NullClaw is a read-only consumer.  This tool performs BM25 full-text search
/// and returns staged markdown output with prose, code excerpts, and metadata.
///
/// Optional local LLM summarization is controlled by `config.explain.enabled`.
pub const ExplainTool = struct {
    workspace_dir: []const u8,
    /// Optional local-LLM summarization config.  When set and `enabled = true`,
    /// explain results are summarized before being returned to the agent.
    explain_config: ?ExplainConfig = null,

    pub const tool_name = "explain";
    pub const tool_description =
        "Search the codebase AST guidance index for functions, types, and definitions " ++
        "matching a query. Returns staged markdown output with prose explanations, " ++
        "source code excerpts, and cross-references. Requires a pre-compiled .explain.db " ++
        "(run explain-gen to generate it).";
    pub const tool_params =
        \\{"type":"object","properties":{"query":{"type":"string","description":"Search terms describing what you are looking for"},"limit":{"type":"integer","description":"Maximum results to return (default: 10, max: 50)"}},"required":["query"]}
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
        _ = limit; // staged pipeline uses its own internal limits

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

        const stages = explain_staged.executeStaged(allocator, &db, query, self.workspace_dir) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Search failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        defer {
            explain_mod.freeStages(allocator, stages);
            allocator.free(stages);
        }

        if (stages.len == 0) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "No results found for: {s}\n\nTip: broaden your search terms, or run explain-gen to rebuild the index.",
                .{query},
            );
            return ToolResult{ .success = true, .output = msg };
        }

        // Optional local-LLM summarization: summarize results when configured and enabled.
        if (self.explain_config) |cfg| {
            if (cfg.enabled) {
                if (explain_summarize.summarizeResults(allocator, query, stages, cfg)) |summary| {
                    return ToolResult{ .success = true, .output = summary };
                }
                // On failure, fall through to raw staged output below.
            }
        }

        const output = try explain_staged.formatStaged(allocator, query, stages, null, self.workspace_dir);
        return ToolResult{ .success = true, .output = output };
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "explain-gen") != null);
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
            \\  source TEXT,module TEXT NOT NULL,node_type TEXT NOT NULL,name TEXT NOT NULL,
            \\  signature TEXT,comment TEXT,line INTEGER,used_by TEXT,
            \\  language TEXT NOT NULL DEFAULT 'zig',last_modified INTEGER NOT NULL);
            \\CREATE VIRTUAL TABLE fts_search USING fts5(name,comment,module,signature,
            \\  content='ast_nodes',content_rowid='id');
            \\INSERT INTO ast_nodes VALUES(1,'src/widget.zig.json','src/widget.zig','src.widget','fn_decl','renderWidget',
            \\  'fn renderWidget(ctx: *Context) void','Renders the main widget.',10,'["src/main.zig"]','zig',0);
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
}
