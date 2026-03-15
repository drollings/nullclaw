//! explain/summarize — Optional local-LLM summarization of staged explain results.
//!
//! Called only when `config.explain.enabled = true`.  Sends the staged results
//! to a local inference endpoint (default: ollama) and returns a concise summary.
//! On any error the caller falls back to the raw staged markdown output.

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.explain_summarize);
const explain_root = @import("root.zig");
const Stage = explain_root.Stage;
const ExplainConfig = @import("../config_types.zig").ExplainConfig;
const providers = @import("../providers/root.zig");

/// Maximum characters from staged results to include in the summarization prompt.
/// Keeps the LLM call fast and predictable.
const MAX_STAGE_CHARS: usize = 4_000;

/// Summarize staged explain results using a local LLM.
///
/// Returns an owned string (caller must free), or null when summarization is
/// skipped (disabled, empty stages, test mode) or fails.
pub fn summarizeResults(
    allocator: std.mem.Allocator,
    query: []const u8,
    stages: []const Stage,
    config: ExplainConfig,
) ?[]const u8 {
    // Skip in test mode to avoid network calls during tests.
    if (builtin.is_test) return null;

    if (stages.len == 0) return null;
    if (!config.enabled) return null;

    const summary = summarizeResultsImpl(allocator, query, stages, config) catch |err| {
        log.warn("explain summarization failed: {s}", .{@errorName(err)});
        return null;
    };
    return summary;
}

fn summarizeResultsImpl(
    allocator: std.mem.Allocator,
    query: []const u8,
    stages: []const Stage,
    config: ExplainConfig,
) ![]const u8 {
    const prompt_text = try buildSummarizationPrompt(allocator, query, stages);
    defer allocator.free(prompt_text);

    const sys = "You are a code navigation assistant. Summarize the following explain results concisely (≤150 words). Focus on what the code does and where it lives.";

    var holder = providers.ProviderHolder.fromConfig(
        allocator,
        config.provider,
        config.api_key,
        config.base_url,
        true, // native_tools (unused for simple chat)
        null, // user_agent
    );
    defer holder.deinit();

    return holder.provider().chatWithSystem(
        allocator,
        sys,
        prompt_text,
        config.model,
        @floatCast(config.temperature),
    );
}

/// Build a summarization prompt from staged results.
/// Caller owns the returned slice.
pub fn buildSummarizationPrompt(
    allocator: std.mem.Allocator,
    query: []const u8,
    stages: []const Stage,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.print("Query: {s}\n\nResults:\n", .{query});

    var chars_written: usize = 0;
    for (stages) |stage| {
        if (chars_written >= MAX_STAGE_CHARS) break;
        const excerpt_len = @min(stage.content.len, 200);
        const excerpt = stage.content[0..excerpt_len];
        try w.print("- [{s}] {s}\n  {s}\n\n", .{ @tagName(stage.kind), stage.source, excerpt });
        chars_written += 10 + stage.source.len + excerpt_len;
    }

    try w.writeAll("\nProvide a concise summary (≤150 words) of the relevant findings.\n");

    return buf.toOwnedSlice(allocator);
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "buildSummarizationPrompt contains query" {
    const allocator = std.testing.allocator;
    const stages: []const Stage = &.{
        .{ .kind = .prose, .content = "Renders the widget.", .source = "src/widget.zig" },
    };
    const result = try buildSummarizationPrompt(allocator, "renderWidget", stages);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "renderWidget") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "widget.zig") != null);
}

test "buildSummarizationPrompt empty stages" {
    const allocator = std.testing.allocator;
    const stages: []const Stage = &.{};
    const result = try buildSummarizationPrompt(allocator, "nothing", stages);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "nothing") != null);
}

test "summarizeResults returns null in test mode" {
    const allocator = std.testing.allocator;
    const stages: []const Stage = &.{
        .{ .kind = .prose, .content = "Some code.", .source = "src/foo.zig" },
    };
    const cfg: ExplainConfig = .{ .enabled = true };
    const result = summarizeResults(allocator, "foo", stages, cfg);
    // In test mode (builtin.is_test), always returns null.
    try std.testing.expect(result == null);
}

test "summarizeResults returns null when disabled" {
    const allocator = std.testing.allocator;
    const stages: []const Stage = &.{
        .{ .kind = .code, .content = "fn foo() void {}", .source = "src/foo.zig" },
    };
    const cfg: ExplainConfig = .{ .enabled = false };
    const result = summarizeResults(allocator, "foo", stages, cfg);
    try std.testing.expect(result == null);
}
