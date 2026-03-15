//! staged.zig — Staged explain pipeline for `nullclaw explain`.
//!
//! Implements a hybrid FTS5 + guidance JSON pipeline.  Key exported functions:
//!
//!   executeStaged()   — FTS5 search → collect Stage slices
//!   formatStaged()    — render []Stage to markdown output

const std = @import("std");
const explain_root = @import("root.zig");

const ExplainDb = explain_root.ExplainDb;
const SearchResult = explain_root.SearchResult;
const Stage = explain_root.Stage;
const StageKind = explain_root.StageKind;
const freeSearchResult = explain_root.freeSearchResult;
const freeStages = explain_root.freeStages;

/// Check if a file path matches common test file patterns (language-agnostic).
/// Used to filter test files from "Used by" display.
fn isTestPath(rel_path: []const u8) bool {
    const basename = std.fs.path.basename(rel_path);
    const stem = blk: {
        const ext = std.fs.path.extension(basename);
        break :blk if (ext.len > 0) basename[0 .. basename.len - ext.len] else basename;
    };
    if (std.mem.endsWith(u8, stem, "_test")) return true;
    if (std.mem.startsWith(u8, stem, "test_")) return true;
    if (std.mem.eql(u8, stem, "tests")) return true;
    if (std.mem.indexOf(u8, rel_path, "/test/") != null) return true;
    if (std.mem.indexOf(u8, rel_path, "/tests/") != null) return true;
    if (std.mem.indexOf(u8, rel_path, "\\test\\") != null) return true;
    if (std.mem.indexOf(u8, rel_path, "\\tests\\") != null) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Stage collection entry point
// ---------------------------------------------------------------------------

/// Collect all stages for a query by searching the FTS5 database and loading
/// supporting data from source files.
///
/// Returned slice is owned by the caller; free with explain_root.freeStages()
/// then allocator.free(slice).
pub fn executeStaged(
    allocator: std.mem.Allocator,
    db: *ExplainDb,
    query: []const u8,
    workspace: []const u8,
) ![]Stage {
    return executeStagedWithAliases(allocator, db, query, workspace, null);
}

/// Collect stages with optional semantic alias expansion.
pub fn executeStagedWithAliases(
    allocator: std.mem.Allocator,
    db: *ExplainDb,
    query: []const u8,
    workspace: []const u8,
    aliases: ?explain_root.SemanticAliases,
) ![]Stage {
    // ── FTS5 search with alias expansion ────────────────────────────────────
    const results = try db.searchWithAliases(allocator, query, 15, aliases);
    defer {
        for (results) |r| freeSearchResult(allocator, r);
        allocator.free(results);
    }

    var stages: std.ArrayList(Stage) = .{};
    errdefer {
        freeStages(allocator, stages.items);
        stages.deinit(allocator);
    }

    // ── Prose stages: module + member comments ───────────────────────────────
    // Track seen (source, name) pairs to avoid duplicate prose entries.
    var seen_prose: std.StringHashMapUnmanaged(void) = .{};
    defer {
        var it = seen_prose.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen_prose.deinit(allocator);
    }

    for (results[0..@min(10, results.len)]) |r| {
        const comment = r.comment orelse continue;
        if (comment.len < 10) continue; // skip trivial stubs

        // Key: "source\x00name" to dedup per-member comments.
        const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ r.source, r.name });
        defer allocator.free(key);
        if (seen_prose.contains(key)) continue;
        try seen_prose.put(allocator, try allocator.dupe(u8, key), {});

        const prose_src = if (std.mem.eql(u8, r.node_type, "module"))
            try allocator.dupe(u8, r.source)
        else
            try std.fmt.allocPrint(allocator, "{s}:{s}", .{ r.source, r.name });

        try stages.append(allocator, .{
            .kind = .prose,
            .content = try allocator.dupe(u8, comment),
            .source = prose_src,
            .line = r.line,
        });
    }

    // ── Code stages: source excerpts for top 3 unique source files ───────────
    var seen_code_files: std.StringHashMapUnmanaged(void) = .{};
    defer seen_code_files.deinit(allocator);

    for (results) |r| {
        if (seen_code_files.count() >= 3) break;
        // Use file_path as the key for the guidance JSON; use source as the
        // actual file to read (relative to workspace).
        const src_ref = if (r.source.len > 0) r.source else r.file_path;
        if (src_ref.len == 0) continue;
        if (seen_code_files.contains(src_ref)) continue;
        const line = r.line orelse continue;

        try seen_code_files.put(allocator, src_ref, {});

        const excerpt = extractSourceExcerpt(allocator, workspace, src_ref, line, r.node_type) catch continue;
        if (excerpt.len == 0) {
            allocator.free(excerpt);
            continue;
        }

        try stages.append(allocator, .{
            .kind = .code,
            .content = excerpt,
            .source = try allocator.dupe(u8, src_ref),
            .line = line,
        });
    }

    // ── Metadata stages: guidance JSON keywords / see_also / skills ──────────
    var seen_guidance: std.StringHashMapUnmanaged(void) = .{};
    defer seen_guidance.deinit(allocator);

    for (results[0..@min(5, results.len)]) |r| {
        if (seen_guidance.contains(r.file_path)) continue;
        try seen_guidance.put(allocator, r.file_path, {});

        const src_ref = if (r.source.len > 0) r.source else r.file_path;
        const meta = buildMetadataStage(allocator, r, src_ref) catch continue;
        const meta_stage = meta orelse continue;
        try stages.append(allocator, meta_stage);
    }

    // ── See-also traversal for sparse results ────────────────────────────────
    // If we have few stages, follow used_by paths for more context.
    if (stages.items.len < 5 and results.len > 0) {
        var seen_sources: std.StringHashMapUnmanaged(void) = .{};
        defer {
            var kit = seen_sources.keyIterator();
            while (kit.next()) |k| allocator.free(k.*);
            seen_sources.deinit(allocator);
        }

        for (stages.items) |s| {
            if (s.kind == .code or s.kind == .prose) {
                try seen_sources.put(allocator, try allocator.dupe(u8, s.source), {});
            }
        }

        for (results[0..@min(3, results.len)]) |r| {
            if (r.used_by.len == 0) continue;

            for (r.used_by[0..@min(3, r.used_by.len)]) |ub_path| {
                if (seen_sources.contains(ub_path)) continue;

                const excerpt = extractSourceExcerpt(allocator, workspace, ub_path, 1, "module") catch continue;
                if (excerpt.len == 0) {
                    allocator.free(excerpt);
                    continue;
                }

                try seen_sources.put(allocator, try allocator.dupe(u8, ub_path), {});
                try stages.append(allocator, .{
                    .kind = .code,
                    .content = excerpt,
                    .source = try allocator.dupe(u8, ub_path),
                    .line = 1,
                });

                if (stages.items.len >= 8) break;
            }
            if (stages.items.len >= 8) break;
        }
    }

    return stages.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Output formatting
// ---------------------------------------------------------------------------

/// Format a []Stage slice into clean markdown output.
/// If `summary` is non-null it is prepended as the synthesized answer block.
/// Returns an owned allocation; caller must free.
pub fn formatStaged(
    allocator: std.mem.Allocator,
    query: []const u8,
    stages: []const Stage,
    summary: ?[]const u8,
    workspace: []const u8,
) ![]u8 {
    _ = workspace;
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.print("# Explain: {s}\n\n", .{query});

    // ── Synthesized summary (optional) ───────────────────────────────────────
    if (summary) |s| {
        const trimmed = std.mem.trim(u8, s, " \t\n\r");
        if (trimmed.len > 0) {
            try w.print("{s}\n\n", .{trimmed});
        }
    }

    try w.writeAll("---\n\n");

    // ── Group stages by source ────────────────────────────────────────────────
    var source_order: std.ArrayList([]const u8) = .{};
    defer source_order.deinit(allocator);
    var seen_srcs: std.StringHashMapUnmanaged(void) = .{};
    defer seen_srcs.deinit(allocator);

    for (stages) |s| {
        if (s.kind == .insight or s.kind == .skill_doc) continue;
        if (seen_srcs.contains(s.source)) continue;
        try seen_srcs.put(allocator, s.source, {});
        try source_order.append(allocator, s.source);
    }

    // Emit source sections.
    for (source_order.items) |src| {
        var has_content = false;
        for (stages) |s| {
            if (!std.mem.eql(u8, s.source, src)) continue;
            if (s.kind == .prose) {
                if (!has_content) {
                    try w.print("## Source: `{s}`\n\n", .{src});
                    has_content = true;
                }
                try w.print("{s}\n\n", .{std.mem.trim(u8, s.content, " \t\n\r")});
            }
        }

        for (stages) |s| {
            if (!std.mem.eql(u8, s.source, src)) continue;
            if (s.kind != .code) continue;

            if (!has_content) {
                try w.print("## Source: `{s}`\n\n", .{src});
                has_content = true;
            }

            const lang = langFromPath(src);
            if (s.line) |ln| {
                try w.print("```{s}\n// {s}:{d}\n", .{ lang, src, ln });
            } else {
                try w.print("```{s}\n// {s}\n", .{ lang, src });
            }
            try w.print("{s}", .{s.content});
            try w.writeAll("\n```\n\n");
        }
    }

    // ── Skill doc stages ──────────────────────────────────────────────────────
    var skill_header_written = false;
    for (stages) |s| {
        if (s.kind != .skill_doc) continue;
        if (!skill_header_written) {
            try w.writeAll("## Knowledge Base\n\n**READ BEFORE IMPLEMENTING**\n\n");
            skill_header_written = true;
        }
        const excerpt = std.mem.trim(u8, s.content, " \t\n\r");
        const first_nl = std.mem.indexOfScalar(u8, excerpt, '\n') orelse excerpt.len;
        try w.print("- **{s}**: {s}\n", .{ s.source, excerpt[0..@min(first_nl, 200)] });
    }
    if (skill_header_written) try w.writeByte('\n');

    // ── References: collect all metadata stages ───────────────────────────────
    var all_keywords: std.ArrayList(u8) = .{};
    defer all_keywords.deinit(allocator);
    var all_see_also: std.ArrayList(u8) = .{};
    defer all_see_also.deinit(allocator);
    var all_skills: std.ArrayList(u8) = .{};
    defer all_skills.deinit(allocator);

    var seen_kw: std.StringHashMapUnmanaged(void) = .{};
    defer seen_kw.deinit(allocator);
    var seen_see_also: std.StringHashMapUnmanaged(void) = .{};
    defer seen_see_also.deinit(allocator);
    var seen_skills_ref: std.StringHashMapUnmanaged(void) = .{};
    defer seen_skills_ref.deinit(allocator);

    for (stages) |s| {
        if (s.kind != .metadata) continue;
        var lines = std.mem.splitScalar(u8, s.content, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "keywords: ")) {
                const v = line["keywords: ".len..];
                var parts = std.mem.splitSequence(u8, v, ", ");
                while (parts.next()) |part| {
                    const p = std.mem.trim(u8, part, " \t");
                    if (p.len == 0 or seen_kw.contains(p)) continue;
                    try seen_kw.put(allocator, p, {});
                    if (all_keywords.items.len > 0) try all_keywords.appendSlice(allocator, ", ");
                    try all_keywords.appendSlice(allocator, p);
                }
            } else if (std.mem.startsWith(u8, line, "used_by: ")) {
                const v = line["used_by: ".len..];
                var parts = std.mem.splitSequence(u8, v, ", ");
                while (parts.next()) |part| {
                    const p = std.mem.trim(u8, part, " \t");
                    if (p.len == 0 or seen_see_also.contains(p)) continue;
                    try seen_see_also.put(allocator, p, {});
                    if (all_see_also.items.len > 0) try all_see_also.appendSlice(allocator, ", ");
                    try all_see_also.appendSlice(allocator, p);
                }
            } else if (std.mem.startsWith(u8, line, "skills: ")) {
                const v = line["skills: ".len..];
                var parts = std.mem.splitSequence(u8, v, ", ");
                while (parts.next()) |part| {
                    const p = std.mem.trim(u8, part, " \t");
                    if (p.len == 0 or seen_skills_ref.contains(p)) continue;
                    try seen_skills_ref.put(allocator, p, {});
                    if (all_skills.items.len > 0) try all_skills.appendSlice(allocator, ", ");
                    try all_skills.appendSlice(allocator, p);
                }
            }
        }
    }

    if (all_keywords.items.len > 0 or all_see_also.items.len > 0 or all_skills.items.len > 0) {
        try w.writeAll("## References\n\n");
        if (all_keywords.items.len > 0) try w.print("- **Keywords**: {s}\n", .{all_keywords.items});
        if (all_see_also.items.len > 0) try w.print("- **Used by**: {s}\n", .{all_see_also.items});
        if (all_skills.items.len > 0) try w.print("- **Skills**: {s}\n", .{all_skills.items});
    }

    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Source excerpt extraction
// ---------------------------------------------------------------------------

/// Load source file and extract an excerpt starting at `start_line` (1-based).
/// Extracts complete functions/structs by tracking brace depth.
/// Returns an owned allocation; caller must free.
pub fn extractSourceExcerpt(
    allocator: std.mem.Allocator,
    workspace: []const u8,
    rel_source: []const u8,
    start_line: u32,
    node_type: []const u8,
) ![]u8 {
    const abs_path = try std.fs.path.join(allocator, &.{ workspace, rel_source });
    defer allocator.free(abs_path);

    const file = std.fs.openFileAbsolute(abs_path, .{}) catch return allocator.dupe(u8, "");
    defer file.close();

    const src = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return allocator.dupe(u8, "");
    defer allocator.free(src);

    return extractExcerptFromSource(allocator, src, start_line, node_type);
}

/// Extract a complete logical unit (function/struct/etc) starting at `start_line` (1-based).
/// Uses brace counting to find the end of the scope.
/// For functions: extracts the entire function.
/// For structs/enums/unions: abbreviates to declarations only.
/// Returns an owned allocation.
pub fn extractExcerptFromSource(
    allocator: std.mem.Allocator,
    src: []const u8,
    start_line: u32,
    node_type: []const u8,
) ![]u8 {
    const is_fn = std.mem.eql(u8, node_type, "fn_decl") or
        std.mem.eql(u8, node_type, "fn_private") or
        std.mem.eql(u8, node_type, "method") or
        std.mem.eql(u8, node_type, "method_private");
    const is_container = std.mem.eql(u8, node_type, "struct") or
        std.mem.eql(u8, node_type, "enum") or
        std.mem.eql(u8, node_type, "union");

    var lines: std.ArrayList([]const u8) = .{};
    defer lines.deinit(allocator);

    var iter = std.mem.splitScalar(u8, src, '\n');
    var line_no: u32 = 0;
    var brace_depth: isize = 0;
    var started_scope: bool = false;
    var scope_start_depth: isize = 0;

    while (iter.next()) |raw| {
        line_no += 1;
        if (line_no < start_line) continue;

        const trimmed = std.mem.trimRight(u8, raw, "\r");
        const is_first = line_no == start_line;

        var line_brace_delta: isize = 0;
        var found_open = false;
        for (trimmed) |ch| {
            if (ch == '{') {
                line_brace_delta += 1;
                found_open = true;
            } else if (ch == '}') {
                line_brace_delta -= 1;
            }
        }

        if (!started_scope and found_open) {
            started_scope = true;
            scope_start_depth = brace_depth + 1;
        }

        // Skip separator comments.
        if (std.mem.startsWith(u8, std.mem.trimLeft(u8, trimmed, " \t"), "// ---")) continue;

        // For containers, abbreviate: show declarations and comments only.
        if (is_container and started_scope and brace_depth > scope_start_depth) {
            const stripped = std.mem.trimLeft(u8, trimmed, " \t");
            if (stripped.len > 0 and stripped[0] != '/' and stripped[0] != '*' and
                !std.mem.startsWith(u8, stripped, "pub ") and
                !std.mem.startsWith(u8, stripped, "fn ") and
                !std.mem.startsWith(u8, stripped, "const ") and
                !std.mem.startsWith(u8, stripped, "var ") and
                !std.mem.startsWith(u8, stripped, "//") and
                !std.mem.startsWith(u8, stripped, "///") and
                !std.mem.eql(u8, stripped, "},") and
                !std.mem.eql(u8, stripped, "}"))
            {
                brace_depth += line_brace_delta;
                continue;
            }
        }

        try lines.append(allocator, trimmed);
        brace_depth += line_brace_delta;

        if (started_scope and brace_depth < scope_start_depth) break;

        // Stop at next top-level declaration if we haven't opened a scope yet.
        if (!started_scope and !is_first and trimmed.len > 0 and trimmed[0] != ' ' and trimmed[0] != '\t') {
            if (std.mem.startsWith(u8, trimmed, "pub ") or
                std.mem.startsWith(u8, trimmed, "fn ") or
                std.mem.startsWith(u8, trimmed, "const ") or
                std.mem.startsWith(u8, trimmed, "var ") or
                std.mem.startsWith(u8, trimmed, "test ") or
                std.mem.startsWith(u8, trimmed, "///"))
            {
                _ = lines.pop();
                break;
            }
        }

        if (!is_fn and !is_container and lines.items.len >= 200) break;
    }

    // Prune trailing blank/comment-only lines.
    while (lines.items.len > 0) {
        const last = lines.items[lines.items.len - 1];
        const trimmed_last = std.mem.trim(u8, last, " \t\r");
        if (trimmed_last.len == 0 or std.mem.startsWith(u8, trimmed_last, "//")) {
            _ = lines.pop();
        } else {
            break;
        }
    }

    if (lines.items.len == 0) return allocator.dupe(u8, "");

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    for (lines.items, 0..) |line, idx| {
        if (idx > 0) try buf.append(allocator, '\n');
        try buf.appendSlice(allocator, line);
    }
    return buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Metadata stage builder
// ---------------------------------------------------------------------------

/// Build a metadata Stage from a SearchResult's used_by and guidance info.
/// Returns null when there is no useful metadata.
fn buildMetadataStage(
    allocator: std.mem.Allocator,
    r: SearchResult,
    source: []const u8,
) !?Stage {
    var meta_buf: std.ArrayList(u8) = .{};
    errdefer meta_buf.deinit(allocator);
    const mw = meta_buf.writer(allocator);

    // keywords: from the result name and module.
    if (r.name.len > 0 and !std.mem.eql(u8, r.name, r.module)) {
        try mw.print("keywords: {s}\n", .{r.name});
    }

    // used_by: reverse dependency paths (exclude test files).
    if (r.used_by.len > 0) {
        var count: usize = 0;
        for (r.used_by[0..@min(5, r.used_by.len)]) |ub| {
            if (isTestPath(ub)) continue;
            if (count == 0) {
                try mw.writeAll("used_by: ");
            } else {
                try mw.writeAll(", ");
            }
            try mw.writeAll(ub);
            count += 1;
        }
        if (count > 0) try mw.writeByte('\n');
    }

    if (meta_buf.items.len == 0) return null;

    return Stage{
        .kind = .metadata,
        .content = try meta_buf.toOwnedSlice(allocator),
        .source = try allocator.dupe(u8, source),
    };
}

// ---------------------------------------------------------------------------
// Utility helpers
// ---------------------------------------------------------------------------

/// Determine fenced code block language from a file extension.
fn langFromPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".zig")) return "zig";
    if (std.mem.endsWith(u8, path, ".py")) return "python";
    if (std.mem.endsWith(u8, path, ".rs")) return "rust";
    if (std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".tsx")) return "typescript";
    if (std.mem.endsWith(u8, path, ".js")) return "javascript";
    return "text";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "extractExcerptFromSource extracts function body" {
    const src =
        \\pub fn hello(x: u32) u32 {
        \\    return x + 1;
        \\}
        \\
        \\pub fn other() void {}
    ;
    const result = try extractExcerptFromSource(std.testing.allocator, src, 1, "fn_decl");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "return x + 1") != null);
    // Should not include "other" function
    try std.testing.expect(std.mem.indexOf(u8, result, "other") == null);
}

test "extractExcerptFromSource returns empty for out-of-range start line" {
    const src = "pub fn foo() void {}";
    const result = try extractExcerptFromSource(std.testing.allocator, src, 999, "fn_decl");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "formatStaged includes query and source sections" {
    const allocator = std.testing.allocator;
    const stages = [_]Stage{
        .{ .kind = .prose, .content = "Does something useful.", .source = "src/foo.zig" },
    };
    const output = try formatStaged(allocator, "test query", &stages, null, "/tmp");
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "test query") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "src/foo.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Does something useful.") != null);
}

test "isTestPath identifies test files" {
    try std.testing.expect(isTestPath("src/foo_test.zig"));
    try std.testing.expect(isTestPath("src/test_foo.zig"));
    try std.testing.expect(isTestPath("src/tests.zig"));
    try std.testing.expect(isTestPath("src/tests/foo.zig"));
    try std.testing.expect(!isTestPath("src/foo.zig"));
    try std.testing.expect(!isTestPath("src/testing_util.zig"));
}
