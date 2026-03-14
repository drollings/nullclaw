const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const ast_explain = @import("../ast_explain/root.zig");

/// MCP tool: synchronize the AST guidance index from `.ast-explain/src/` JSON files.
///
/// Walks `.ast-explain/src/**/*.json` under `workspace_dir` and upserts any file
/// whose mtime has changed since the last sync run.  Creates the database and
/// `.ast-explain/` directory if they do not yet exist.
pub const AstSyncTool = struct {
    workspace_dir: []const u8,

    pub const tool_name = "ast_sync";
    pub const tool_description =
        "Synchronize the AST guidance index with .ast-explain/src/ JSON files. " ++
        "Run this after ast-guidance generates or updates guidance JSON files.";
    pub const tool_params =
        \\{"type":"object","properties":{"force":{"type":"boolean","description":"Reindex all files, ignoring mtime (default: false)"}},"required":[]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *AstSyncTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *AstSyncTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        if (comptime !ast_explain.enabled) {
            return ToolResult.fail("ast_sync requires SQLite support (build with -Dengines=sqlite)");
        }

        _ = root.getBool(args, "force"); // reserved for future --force support

        ast_explain.ensureDir(self.workspace_dir) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to create .ast-explain dir: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };

        const db_path = ast_explain.resolveDatabasePath(allocator, self.workspace_dir) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to resolve db path: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        defer allocator.free(db_path);

        var db = ast_explain.AstDb.init(allocator, db_path) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to open AST guidance database: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        defer db.deinit();

        const src_dir = ast_explain.resolveSrcDir(allocator, self.workspace_dir) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to resolve src dir: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        defer allocator.free(src_dir);

        const stats = db.syncFromDir(allocator, src_dir) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Sync failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };

        const out = try std.fmt.allocPrint(
            allocator,
            "AST guidance sync complete: {d} updated, {d} skipped, {d} errors",
            .{ stats.synced, stats.skipped, stats.errors },
        );
        return ToolResult{ .success = true, .output = out };
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "ast_sync tool name" {
    var t = AstSyncTool{ .workspace_dir = "/tmp" };
    try std.testing.expectEqualStrings("ast_sync", t.tool().name());
}

test "ast_sync schema has force" {
    var t = AstSyncTool{ .workspace_dir = "/tmp" };
    const schema = t.tool().parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "force") != null);
}

test "ast_sync execute with missing src dir succeeds gracefully" {
    if (comptime !ast_explain.enabled) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    var t = AstSyncTool{ .workspace_dir = workspace };
    const tl = t.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();

    const result = try tl.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);

    // Missing src dir is treated as 0 files — should still succeed
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "sync complete") != null);
}
