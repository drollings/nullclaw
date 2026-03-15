const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const net_security = @import("../root.zig").net_security;
const http_util = @import("../http_util.zig");

const log = std.log.scoped(.http_request);

pub const HttpRequestTool = struct {
    allowed_domains: []const []const u8 = &.{},
    max_response_size: u32 = 1_000_000,
    timeout_secs: u64 = 60,

    pub const tool_name = "http_request";
    pub const tool_description = "Perform a network HTTP request (GET, POST, etc.) to an external API or website. Returns the status code and response body.";
    pub const tool_params =
        \\{"type":"object","properties":{"method":{"type":"string","enum":["GET","POST","PUT","PATCH","DELETE"],"default":"GET"},"url":{"type":"string","description":"Target URL (must start with https://)"},"headers":{"type":"object","additionalProperties":{"type":"string"},"description":"Optional HTTP headers"},"body":{"type":"string","description":"Optional request body (for POST/PUT/PATCH)"}},"required":["url"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *HttpRequestTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *HttpRequestTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const url = root.getString(args, "url") orelse
            return ToolResult.fail("Missing 'url' parameter");

        const method_str = root.getString(args, "method") orelse "GET";

        // Stricter URL validation for tools: HTTPS only
        if (!std.mem.startsWith(u8, url, "https://")) {
            return ToolResult.fail("Only https:// URLs are allowed for security");
        }

        const host = net_security.extractHost(url) orelse
            return ToolResult.fail("Invalid URL: cannot extract host");

        const uri = std.Uri.parse(url) catch
            return ToolResult.fail("Invalid URL format");
        const default_port: u16 = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) 443 else 80;
        const resolved_port: u16 = uri.port orelse default_port;

        // SSRF protection and DNS-rebinding hardening:
        // resolve once, validate global address, and connect directly to it.
        const connect_host = net_security.resolveConnectHost(allocator, host, resolved_port) catch |err| switch (err) {
            error.LocalAddressBlocked => return ToolResult.fail("Blocked local/private host"),
            else => return ToolResult.fail("Unable to verify host safety"),
        };
        defer allocator.free(connect_host);

        if (self.allowed_domains.len > 0) {
            if (!net_security.hostMatchesAllowlist(host, self.allowed_domains)) {
                return ToolResult.fail("Domain not in allowlist");
            }
        }

        const method = validateMethod(method_str) orelse {
            const msg = try std.fmt.allocPrint(allocator, "Unsupported HTTP method: {s}", .{method_str});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };

        var header_list: std.ArrayListUnmanaged([2][]const u8) = .empty;
        errdefer {
            for (header_list.items) |h| {
                allocator.free(h[0]);
                allocator.free(h[1]);
            }
            header_list.deinit(allocator);
        }
        if (args.get("headers")) |h| {
            if (h == .object) {
                var it = h.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* == .string) {
                        try header_list.append(allocator, .{
                            try allocator.dupe(u8, entry.key_ptr.*),
                            try allocator.dupe(u8, entry.value_ptr.*.string),
                        });
                    }
                }
            }
        }
        const custom_headers = header_list.items;
        defer {
            for (header_list.items) |h| {
                allocator.free(h[0]);
                allocator.free(h[1]);
            }
            header_list.deinit(allocator);
        }

        const body = root.getString(args, "body");

        var curl_stderr: ?[]u8 = null;
        defer if (curl_stderr) |buf| allocator.free(buf);

        const status_result = runCurlRequestWithStatus(
            allocator,
            methodToSlice(method),
            url,
            host,
            resolved_port,
            connect_host,
            custom_headers,
            body,
            self.timeout_secs,
            &curl_stderr,
            @intCast(self.max_response_size),
        ) catch |err| {
            if (err == error.CurlInterrupted) {
                return ToolResult.fail("Interrupted by /stop");
            }
            const msg = if (curl_stderr) |stderr_msg|
                try std.fmt.allocPrint(allocator, "HTTP request failed: {s}", .{stderr_msg})
            else
                try std.fmt.allocPrint(allocator, "HTTP request failed with error: {}", .{err});
            defer allocator.free(msg);
            return ToolResult.fail(msg);
        };
        defer allocator.free(status_result.body);

        const status_code = status_result.status_code;
        const success = status_code >= 200 and status_code < 300;

        // Build redacted headers display for custom request headers
        const redacted = try redactHeadersForDisplay(allocator, custom_headers);
        defer allocator.free(redacted);

        const output = try std.fmt.allocPrint(allocator,
            \\Status: {d}
            \\URL: {s}
            \\Headers: {s}
            \\
            \\{s}
        , .{ status_code, url, redacted, status_result.body });

        return .{
            .success = success,
            .output = output,
        };
    }
};

fn validateMethod(method: []const u8) ?std.http.Method {
    if (std.ascii.eqlIgnoreCase(method, "GET")) return .GET;
    if (std.ascii.eqlIgnoreCase(method, "POST")) return .POST;
    if (std.ascii.eqlIgnoreCase(method, "PUT")) return .PUT;
    if (std.ascii.eqlIgnoreCase(method, "DELETE")) return .DELETE;
    if (std.ascii.eqlIgnoreCase(method, "PATCH")) return .PATCH;
    if (std.ascii.eqlIgnoreCase(method, "HEAD")) return .HEAD;
    if (std.ascii.eqlIgnoreCase(method, "OPTIONS")) return .OPTIONS;
    return null;
}

fn methodToSlice(m: std.http.Method) []const u8 {
    return switch (m) {
        .GET => "GET",
        .POST => "POST",
        .PUT => "PUT",
        .PATCH => "PATCH",
        .DELETE => "DELETE",
        .HEAD => "HEAD",
        .OPTIONS => "OPTIONS",
        .CONNECT => "CONNECT",
        .TRACE => "TRACE",
    };
}

fn shouldUseCurlResolve(host: []const u8) bool {
    return std.mem.indexOfScalar(u8, net_security.stripHostBrackets(host), ':') == null;
}

fn buildCurlResolveEntry(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    connect_host: []const u8,
) ![]u8 {
    const host_for_resolve = net_security.stripHostBrackets(host);
    const connect_target = if (std.mem.indexOfScalar(u8, connect_host, ':') != null)
        try std.fmt.allocPrint(allocator, "[{s}]", .{connect_host})
    else
        try allocator.dupe(u8, connect_host);
    defer allocator.free(connect_target);

    return std.fmt.allocPrint(allocator, "{s}:{d}:{s}", .{ host_for_resolve, port, connect_target });
}

fn runCurlRequestWithStatus(
    allocator: std.mem.Allocator,
    method: []const u8,
    url: []const u8,
    host: []const u8,
    resolved_port: u16,
    connect_host: []const u8,
    headers: []const [2][]const u8,
    body: ?[]const u8,
    timeout_secs: u64,
    stderr_out: ?*?[]u8,
    max_response_size: usize,
) !http_util.HttpResponse {
    if (stderr_out) |out| out.* = null;

    var argv_buf: [64][]const u8 = undefined;
    var argc: usize = 0;
    const reserved_tail_args: usize = if (body != null) 5 else 3;

    argv_buf[argc] = "curl";
    argc += 1;
    argv_buf[argc] = "-sS";
    argc += 1;
    argv_buf[argc] = "-X";
    argc += 1;
    argv_buf[argc] = method;
    argc += 1;
    argv_buf[argc] = "--max-time";
    argc += 1;
    var timeout_buf: [20]u8 = undefined;
    const timeout_str = try std.fmt.bufPrint(&timeout_buf, "{d}", .{timeout_secs});
    argv_buf[argc] = timeout_str;
    argc += 1;

    var resolve_entry: ?[]u8 = null;
    defer if (resolve_entry) |entry| allocator.free(entry);
    if (shouldUseCurlResolve(host)) {
        resolve_entry = try buildCurlResolveEntry(allocator, host, resolved_port, connect_host);
        argv_buf[argc] = "--resolve";
        argc += 1;
        argv_buf[argc] = resolve_entry.?;
        argc += 1;
    }

    var header_lines: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (header_lines.items) |line| allocator.free(line);
        header_lines.deinit(allocator);
    }

    for (headers) |h| {
        // Reserve room for trailing args:
        // -w "\n%{http_code}" <url> and optional --data-binary @-
        if (argc + 2 + reserved_tail_args > argv_buf.len) break;
        const line = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ h[0], h[1] });
        try header_lines.append(allocator, line);
        argv_buf[argc] = "-H";
        argc += 1;
        argv_buf[argc] = line;
        argc += 1;
    }

    if (body != null) {
        if (argc + 2 + 3 > argv_buf.len) return error.CurlArgsOverflow;
        argv_buf[argc] = "--data-binary";
        argc += 1;
        argv_buf[argc] = "@-";
        argc += 1;
    }

    if (argc + 3 > argv_buf.len) return error.CurlArgsOverflow;
    argv_buf[argc] = "-w";
    argc += 1;
    argv_buf[argc] = "\n%{http_code}";
    argc += 1;
    argv_buf[argc] = url;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = if (body != null) .Pipe else .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const cancel_flag = http_util.currentThreadInterruptFlag();
    const AtomicBool = std.atomic.Value(bool);
    const CancelCtx = struct {
        child: *std.process.Child,
        cancel_flag: *const AtomicBool,
        done: *AtomicBool,
    };
    const watcherFn = struct {
        fn run(ctx: *CancelCtx) void {
            while (!ctx.done.load(.acquire)) {
                if (ctx.cancel_flag.load(.acquire)) {
                    if (comptime @import("builtin").os.tag == .windows) {
                        std.os.windows.TerminateProcess(ctx.child.id, 1) catch {};
                    } else {
                        std.posix.kill(ctx.child.id, std.posix.SIG.TERM) catch {};
                    }
                    break;
                }
                std.Thread.sleep(20 * std.time.ns_per_ms);
            }
        }
    }.run;
    var done = AtomicBool.init(false);
    var watcher: ?std.Thread = null;
    var cancel_ctx: CancelCtx = undefined;
    if (cancel_flag) |flag| {
        cancel_ctx = .{ .child = &child, .cancel_flag = flag, .done = &done };
        watcher = std.Thread.spawn(.{}, watcherFn, .{&cancel_ctx}) catch null;
    }
    defer {
        done.store(true, .release);
        if (watcher) |t| t.join();
    }

    if (body) |b| {
        if (child.stdin) |stdin_file| {
            stdin_file.writeAll(b) catch {
                stdin_file.close();
                child.stdin = null;
                _ = child.kill() catch {};
                _ = child.wait() catch {};
                return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlWriteError;
            };
            stdin_file.close();
            child.stdin = null;
        } else {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlWriteError;
        }
    }

    const stdout = child.stdout.?.readToEndAlloc(allocator, max_response_size + 64) catch {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlReadError;
    };
    errdefer allocator.free(stdout);

    const stderr_raw = if (child.stderr) |stderr_file|
        stderr_file.readToEndAlloc(allocator, 16 * 1024) catch null
    else
        null;
    defer if (stderr_raw) |buf| allocator.free(buf);

    var stderr_copy: ?[]u8 = try duplicateTrimmedStderr(allocator, stderr_raw);
    defer if (stderr_copy) |buf| allocator.free(buf);

    const term = child.wait() catch return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlWaitError;
    switch (term) {
        .Exited => |code| if (code != 0 and !(cancel_flag != null and cancel_flag.?.load(.acquire))) {
            if (stderr_out) |out| {
                out.* = stderr_copy;
                stderr_copy = null;
            }
            return error.CurlFailed;
        },
        else => return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlFailed,
    }

    if (cancel_flag != null and cancel_flag.?.load(.acquire)) return error.CurlInterrupted;

    const status_sep = std.mem.lastIndexOfScalar(u8, stdout, '\n') orelse {
        if (stderr_out) |out| {
            out.* = stderr_copy;
            stderr_copy = null;
        }
        return error.CurlParseError;
    };
    const status_raw = std.mem.trim(u8, stdout[status_sep + 1 ..], " \t\r\n");
    if (status_raw.len != 3) {
        if (stderr_out) |out| {
            out.* = stderr_copy;
            stderr_copy = null;
        }
        return error.CurlParseError;
    }
    const status_code = std.fmt.parseInt(u16, status_raw, 10) catch {
        if (stderr_out) |out| {
            out.* = stderr_copy;
            stderr_copy = null;
        }
        return error.CurlParseError;
    };
    const body_slice = stdout[0..status_sep];
    const response_body = try allocator.dupe(u8, body_slice);
    allocator.free(stdout);

    return .{
        .status_code = status_code,
        .body = response_body,
    };
}

fn duplicateTrimmedStderr(allocator: std.mem.Allocator, raw: ?[]const u8) !?[]u8 {
    const bytes = raw orelse return null;
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return null;
    const copied = try allocator.dupe(u8, trimmed);
    return copied;
}

fn isSensitiveHeader(name: []const u8) bool {
    // Convert to lowercase for comparison
    var lower_buf: [256]u8 = undefined;
    // Fail closed: oversized header names are treated as sensitive.
    if (name.len > lower_buf.len) return true;
    const lower = lower_buf[0..name.len];
    for (name, 0..) |c, i| {
        lower[i] = std.ascii.toLower(c);
    }
    if (std.mem.indexOf(u8, lower, "authorization") != null) return true;
    if (std.mem.indexOf(u8, lower, "api-key") != null) return true;
    if (std.mem.indexOf(u8, lower, "token") != null) return true;
    if (std.mem.indexOf(u8, lower, "cookie") != null) return true;
    return false;
}

fn redactHeadersForDisplay(allocator: std.mem.Allocator, headers: []const [2][]const u8) ![]u8 {
    if (headers.len == 0) return try allocator.dupe(u8, "{}");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '{');
    for (headers, 0..) |h, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.append(allocator, '"');
        try buf.appendSlice(allocator, h[0]);
        try buf.appendSlice(allocator, "\": \"");
        if (isSensitiveHeader(h[0])) {
            try buf.appendSlice(allocator, "[REDACTED]");
        } else {
            try buf.appendSlice(allocator, h[1]);
        }
        try buf.append(allocator, '"');
    }
    try buf.append(allocator, '}');

    return try buf.toOwnedSlice(allocator);
}

// --- Tests ---

test "HttpRequestTool name and description" {
    var hrt = HttpRequestTool{};
    const t = hrt.tool();
    try std.testing.expectEqualStrings(HttpRequestTool.tool_name, t.name());
    try std.testing.expect(t.description().len > 0);
    try std.testing.expect(t.parametersJson()[0] == '{');
}

test "HttpRequestTool validates https only" {
    var hrt = HttpRequestTool{};
    const parsed = try root.parseTestArgs("{\"url\": \"http://example.com\"}");
    defer parsed.deinit();
    const result = try hrt.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "HttpRequestTool enforces allowlist" {
    var hrt = HttpRequestTool{ .allowed_domains = &.{ "safe.com" } };
    const parsed = try root.parseTestArgs("{\"url\": \"https://evil.com\"}");
    defer parsed.deinit();
    const result = try hrt.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "redactHeadersForDisplay redacts api-key and token" {
    const headers = [_][2][]const u8{
        .{ "Content-Type", "application/json" },
        .{ "Authorization", "Bearer secret-token" },
        .{ "x-api-key", "secret-key" },
    };
    const result = try redactHeadersForDisplay(std.testing.allocator, &headers);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"Authorization\": \"[REDACTED]\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"x-api-key\": \"[REDACTED]\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"Content-Type\": \"application/json\"") != null);
}

test "redactHeadersForDisplay empty returns empty json" {
    const result = try redactHeadersForDisplay(std.testing.allocator, &.{});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{}", result);
}
