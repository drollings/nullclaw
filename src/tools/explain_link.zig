//! explain_link — link explain search results to a stored memory entry.
//!
//! This tool queries the `.explain.db` index for a given term and stores the
//! formatted results as a memory entry under the provided key.  It allows the
//! agent to explicitly associate code context with a named memory so that later
//! `memory_recall` calls surface it alongside text memories.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const Memory = @import("../memory/root.zig").Memory;
const MemoryCategory = @import("../memory/root.zig").MemoryCategory;
const explain_mod = @import("../explain/root.zig");
const explain_staged = explain_mod.staged;

/// Tool: link explain search results to a stored memory entry.
pub const ExplainLinkTool = struct {
    workspace_dir: []const u8,
    /// Memory backend.  If null the tool reports an error instead of panicking.
    mem: ?Memory = null,

    pub const tool_name = "explain_link";
    pub const tool_description =
        "Link explain search results to a stored memory entry for future recall. " ++
        "Queries the .explain.db index for 'query' and stores the results under 'memory_key'. " ++
        "Requires both a pre-compiled .explain.db and a configured memory backend.";
    pub const tool_params =
        \\{"type":"object","properties":{"memory_key":{"type":"string","description":"Key under which to store the linked code context"},"query":{"type":"string","description":"Explain search query (function name, type, concept)"}},"required":["memory_key","query"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ExplainLinkTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *ExplainLinkTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        if (comptime !explain_mod.enabled) {
            return ToolResult.fail("explain_link requires SQLite support (build with -Dengines=sqlite)");
        }

        const memory_key = root.getString(args, "memory_key") orelse
            return ToolResult.fail("Missing 'memory_key' parameter");
        if (memory_key.len == 0) return ToolResult.fail("'memory_key' must not be empty");

        const query = root.getString(args, "query") orelse
            return ToolResult.fail("Missing 'query' parameter");
        if (query.len == 0) return ToolResult.fail("'query' must not be empty");

        // Require a memory backend.
        const mem = self.mem orelse
            return ToolResult.fail("No memory backend configured — cannot link explain results");

        // Open the explain database.
        const db_path = explain_mod.resolveDatabasePath(allocator, self.workspace_dir) catch |err| {
            if (err == error.DbNotFound) {
                const msg = try explain_mod.missingDbMessage(allocator, self.workspace_dir);
                return ToolResult{ .success = false, .output = msg };
            }
            const msg = try std.fmt.allocPrint(allocator, "Failed to resolve .explain.db: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        defer allocator.free(db_path);

        var db = explain_mod.ExplainDb.init(allocator, db_path) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to open .explain.db: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        defer db.deinit();

        // Run the staged pipeline.
        const stages = explain_staged.executeStaged(allocator, &db, query, self.workspace_dir) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Explain search failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        defer {
            explain_mod.freeStages(allocator, stages);
            allocator.free(stages);
        }

        if (stages.len == 0) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "No results found for '{s}' — nothing stored under '{s}'.",
                .{ query, memory_key },
            );
            return ToolResult{ .success = false, .output = msg };
        }

        // Format the results as the memory content.
        const content = try explain_staged.formatStaged(allocator, query, stages, null, self.workspace_dir);
        defer allocator.free(content);

        // Store in memory (category: core — code context is long-lived).
        mem.store(memory_key, content, .core, null) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to store memory: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };

        const out = try std.fmt.allocPrint(
            allocator,
            "Linked {d} explain result(s) for '{s}' to memory key '{s}'.",
            .{ stages.len, query, memory_key },
        );
        return ToolResult{ .success = true, .output = out };
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "explain_link tool name" {
    var t = ExplainLinkTool{ .workspace_dir = "/tmp" };
    try std.testing.expectEqualStrings("explain_link", t.tool().name());
}

test "explain_link schema has memory_key and query" {
    var t = ExplainLinkTool{ .workspace_dir = "/tmp" };
    const schema = t.tool().parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "memory_key") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "query") != null);
}

test "explain_link missing memory_key returns error" {
    var t = ExplainLinkTool{ .workspace_dir = "/tmp" };
    const parsed = try root.parseTestArgs("{\"query\":\"foo\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "explain_link missing query returns error" {
    var t = ExplainLinkTool{ .workspace_dir = "/tmp" };
    const parsed = try root.parseTestArgs("{\"memory_key\":\"code/widget\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "explain_link no memory backend returns error" {
    if (comptime !explain_mod.enabled) return error.SkipZigTest;
    var t = ExplainLinkTool{ .workspace_dir = "/tmp", .mem = null };
    const parsed = try root.parseTestArgs("{\"memory_key\":\"code/widget\",\"query\":\"widget\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0 and !result.success) std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
}

test "explain_link no database returns helpful error" {
    if (comptime !explain_mod.enabled) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    // No memory backend — should fail with "No memory backend configured".
    var t = ExplainLinkTool{ .workspace_dir = workspace, .mem = null };
    const parsed = try root.parseTestArgs("{\"memory_key\":\"code/widget\",\"query\":\"widget\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0 and !result.success) std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
}
