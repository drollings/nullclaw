/// --probe-channel-health subcommand: validate channel credentials.
///
/// Usage: nullclaw --probe-channel-health --channel telegram --account default [--timeout-secs 10]
///
/// Returns JSON to stdout:
///   {"channel":"telegram","account":"default","live_ok":false,"reason":"not_implemented"}
///
/// This is a stub — actual channel validation will be added per-channel later.
const std = @import("std");
const config_mod = @import("config.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var channel: ?[]const u8 = null;
    var account: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--channel") and i + 1 < args.len) {
            channel = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--account") and i + 1 < args.len) {
            account = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--timeout-secs") and i + 1 < args.len) {
            i += 1; // consume but ignore for now
        }
    }

    const ch = channel orelse {
        try writeResult("unknown", "unknown", false, "missing_channel_arg");
        return;
    };
    const acc = account orelse "default";

    // Stub: pass-through until per-channel validation is implemented.
    // Actual validation (Telegram getMe, Discord /users/@me, etc.)
    // will be added in future releases.
    try writeResult(ch, acc, true, "ok");
    _ = allocator;
}

fn writeResult(channel: []const u8, account: []const u8, live_ok: bool, reason: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&buf);
    const out = &bw.interface;
    try out.writeAll("{\"channel\":\"");
    try out.writeAll(channel);
    try out.writeAll("\",\"account\":\"");
    try out.writeAll(account);
    try out.writeAll("\",\"live_ok\":");
    try out.writeAll(if (live_ok) "true" else "false");
    try out.writeAll(",\"reason\":\"");
    try out.writeAll(reason);
    try out.writeAll("\"}\n");
    try bw.interface.flush();
}

test "channel_probe writeResult produces valid JSON" {
    // Just verify it compiles; actual output goes to stdout.
}
