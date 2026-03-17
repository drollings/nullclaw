const std = @import("std");
const root = @import("root.zig");
const config_types = @import("../config_types.zig");
const json_util = @import("../json_util.zig");

pub const PROTOCOL_VERSION: i64 = 2;

pub const Manifest = struct {
    health_supported: ?bool = null,
    streaming_supported: ?bool = null,
    send_rich_supported: ?bool = null,
    typing_supported: ?bool = null,
};

pub const InboundMessage = struct {
    sender_id: []const u8,
    chat_id: []const u8,
    content: []const u8,
    session_key: ?[]const u8 = null,
    media: []const []const u8 = &.{},
    metadata_value: ?std.json.Value = null,
};

pub const Error = error{
    InvalidPluginManifest,
    InvalidPluginResponse,
    PluginRequestFailed,
    PluginRequestRejected,
    HealthMethodNotSupported,
    MethodNotSupported,
    UnsupportedPluginProtocolVersion,
};

pub fn parseManifestResponse(allocator: std.mem.Allocator, response_line: []const u8) !Manifest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_line, .{}) catch
        return Error.InvalidPluginManifest;
    defer parsed.deinit();

    if (parsed.value != .object) return Error.InvalidPluginManifest;
    const obj = parsed.value.object;
    if (obj.get("error")) |_| return Error.PluginRequestFailed;

    const result = obj.get("result") orelse return Error.InvalidPluginManifest;
    if (result != .object) return Error.InvalidPluginManifest;

    const protocol_version_value = result.object.get("protocol_version") orelse return Error.InvalidPluginManifest;
    if (protocol_version_value != .integer) return Error.InvalidPluginManifest;
    if (protocol_version_value.integer != PROTOCOL_VERSION) {
        return Error.UnsupportedPluginProtocolVersion;
    }

    var manifest = Manifest{};
    if (result.object.get("capabilities")) |capabilities_value| {
        if (capabilities_value != .object) return Error.InvalidPluginManifest;
        if (capabilities_value.object.get("health")) |health_value| {
            if (health_value != .bool) return Error.InvalidPluginManifest;
            manifest.health_supported = health_value.bool;
        }
        if (capabilities_value.object.get("streaming")) |streaming_value| {
            if (streaming_value != .bool) return Error.InvalidPluginManifest;
            manifest.streaming_supported = streaming_value.bool;
        }
        if (capabilities_value.object.get("send_rich")) |send_rich_value| {
            if (send_rich_value != .bool) return Error.InvalidPluginManifest;
            manifest.send_rich_supported = send_rich_value.bool;
        }
        if (capabilities_value.object.get("typing")) |typing_value| {
            if (typing_value != .bool) return Error.InvalidPluginManifest;
            manifest.typing_supported = typing_value.bool;
        }
    }
    return manifest;
}

pub fn buildStartParams(allocator: std.mem.Allocator, config: config_types.ExternalChannelConfig) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"runtime\":{\"name\":");
    try json_util.appendJsonString(&buf, allocator, config.runtime_name);
    try buf.appendSlice(allocator, ",\"account_id\":");
    try json_util.appendJsonString(&buf, allocator, config.account_id);
    try buf.appendSlice(allocator, ",\"state_dir\":");
    try json_util.appendJsonString(&buf, allocator, config.state_dir);
    try buf.appendSlice(allocator, "},\"config\":");
    try buf.appendSlice(allocator, config.plugin_config_json);
    try buf.append(allocator, '}');

    return buf.toOwnedSlice(allocator);
}

pub fn buildSendParams(
    allocator: std.mem.Allocator,
    config: config_types.ExternalChannelConfig,
    target: []const u8,
    message: []const u8,
    media: []const []const u8,
    stage: root.Channel.OutboundStage,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"runtime\":{\"name\":");
    try json_util.appendJsonString(&buf, allocator, config.runtime_name);
    try buf.appendSlice(allocator, ",\"account_id\":");
    try json_util.appendJsonString(&buf, allocator, config.account_id);
    try buf.appendSlice(allocator, "},\"message\":{\"target\":");
    try json_util.appendJsonString(&buf, allocator, target);
    try buf.appendSlice(allocator, ",\"text\":");
    try json_util.appendJsonString(&buf, allocator, message);
    try buf.appendSlice(allocator, ",\"stage\":");
    try json_util.appendJsonString(&buf, allocator, stageToSlice(stage));
    try buf.appendSlice(allocator, ",\"media\":[");
    for (media, 0..) |item, index| {
        if (index > 0) try buf.append(allocator, ',');
        try json_util.appendJsonString(&buf, allocator, item);
    }
    try buf.appendSlice(allocator, "]}}");

    return buf.toOwnedSlice(allocator);
}

pub fn buildSendRichParams(
    allocator: std.mem.Allocator,
    config: config_types.ExternalChannelConfig,
    target: []const u8,
    payload: root.Channel.OutboundPayload,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendRuntimeObject(&buf, allocator, config);
    try buf.appendSlice(allocator, ",\"message\":{\"target\":");
    try json_util.appendJsonString(&buf, allocator, target);
    try buf.appendSlice(allocator, ",\"text\":");
    try json_util.appendJsonString(&buf, allocator, payload.text);
    try buf.appendSlice(allocator, ",\"attachments\":[");
    for (payload.attachments, 0..) |attachment, index| {
        if (index > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"kind\":");
        try json_util.appendJsonString(&buf, allocator, attachmentKindToSlice(attachment.kind));
        try buf.appendSlice(allocator, ",\"target\":");
        try json_util.appendJsonString(&buf, allocator, attachment.target);
        if (attachment.caption) |caption| {
            try buf.appendSlice(allocator, ",\"caption\":");
            try json_util.appendJsonString(&buf, allocator, caption);
        }
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "],\"choices\":[");
    for (payload.choices, 0..) |choice, index| {
        if (index > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"id\":");
        try json_util.appendJsonString(&buf, allocator, choice.id);
        try buf.appendSlice(allocator, ",\"label\":");
        try json_util.appendJsonString(&buf, allocator, choice.label);
        try buf.appendSlice(allocator, ",\"submit_text\":");
        try json_util.appendJsonString(&buf, allocator, choice.submit_text);
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "]}}");
    return buf.toOwnedSlice(allocator);
}

pub fn buildTypingParams(
    allocator: std.mem.Allocator,
    config: config_types.ExternalChannelConfig,
    recipient: []const u8,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendRuntimeObject(&buf, allocator, config);
    try buf.appendSlice(allocator, ",\"recipient\":");
    try json_util.appendJsonString(&buf, allocator, recipient);
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

pub fn parseInboundMessageParams(allocator: std.mem.Allocator, params_value: std.json.Value) !InboundMessage {
    if (params_value != .object) return Error.InvalidPluginResponse;
    const message_value = params_value.object.get("message") orelse return Error.InvalidPluginResponse;
    if (message_value != .object) return Error.InvalidPluginResponse;
    const message_obj = message_value.object;

    return .{
        .sender_id = requiredNonEmptyString(message_obj, "sender_id") orelse return Error.InvalidPluginResponse,
        .chat_id = requiredNonEmptyString(message_obj, "chat_id") orelse return Error.InvalidPluginResponse,
        .content = requiredString(message_obj, "text") orelse return Error.InvalidPluginResponse,
        .session_key = stringValue(message_obj, "session_key"),
        .media = try parseMediaSlice(allocator, message_obj),
        .metadata_value = try parseMetadataValue(message_obj),
    };
}

pub fn parseHealthResponse(allocator: std.mem.Allocator, response_line: []const u8) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_line, .{}) catch
        return Error.InvalidPluginResponse;
    defer parsed.deinit();

    if (parsed.value != .object) return Error.InvalidPluginResponse;
    const obj = parsed.value.object;
    if (obj.get("error")) |err_value| {
        if (isMethodNotFoundError(err_value)) return Error.HealthMethodNotSupported;
        return Error.PluginRequestFailed;
    }

    const result = obj.get("result") orelse return Error.InvalidPluginResponse;
    if (result != .object) return Error.InvalidPluginResponse;

    const healthy_val = result.object.get("healthy");
    const ok_val = result.object.get("ok");
    const connected_val = result.object.get("connected");
    const logged_in_val = result.object.get("logged_in");

    if (healthy_val) |v| {
        if (v == .bool) return v.bool;
        return Error.InvalidPluginResponse;
    }

    var healthy = true;
    var seen_signal = false;

    if (ok_val) |v| {
        if (v != .bool) return Error.InvalidPluginResponse;
        healthy = healthy and v.bool;
        seen_signal = true;
    }
    if (connected_val) |v| {
        if (v != .bool) return Error.InvalidPluginResponse;
        healthy = healthy and v.bool;
        seen_signal = true;
    }
    if (logged_in_val) |v| {
        if (v != .bool) return Error.InvalidPluginResponse;
        healthy = healthy and v.bool;
        seen_signal = true;
    }

    if (!seen_signal) return Error.InvalidPluginResponse;
    return healthy;
}

pub fn validateRpcSuccess(allocator: std.mem.Allocator, response_line: []const u8) !void {
    var parsed = try parseSuccessResponse(allocator, response_line);
    defer parsed.deinit();
}

pub fn validateStartedResponse(allocator: std.mem.Allocator, response_line: []const u8) !void {
    var parsed = try parseSuccessResponse(allocator, response_line);
    defer parsed.deinit();
    try requireTrueResultField(parsed.value.object.get("result").?.object, "started");
}

pub fn validateAcceptedResponse(allocator: std.mem.Allocator, response_line: []const u8) !void {
    var parsed = try parseSuccessResponse(allocator, response_line);
    defer parsed.deinit();
    try requireTrueResultField(parsed.value.object.get("result").?.object, "accepted");
}

fn parseSuccessResponse(allocator: std.mem.Allocator, response_line: []const u8) !std.json.Parsed(std.json.Value) {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_line, .{}) catch
        return Error.InvalidPluginResponse;
    errdefer parsed.deinit();

    if (parsed.value != .object) return Error.InvalidPluginResponse;
    const obj = parsed.value.object;
    if (obj.get("error")) |err_value| {
        if (isMethodNotFoundError(err_value)) return Error.MethodNotSupported;
        return Error.PluginRequestFailed;
    }
    const result = obj.get("result") orelse return Error.InvalidPluginResponse;
    if (result != .object) return Error.InvalidPluginResponse;
    return parsed;
}

fn requireTrueResultField(result_obj: std.json.ObjectMap, field_name: []const u8) !void {
    const value = result_obj.get(field_name) orelse return Error.InvalidPluginResponse;
    if (value != .bool) return Error.InvalidPluginResponse;
    if (!value.bool) return Error.PluginRequestRejected;
}

fn appendRuntimeObject(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    config: config_types.ExternalChannelConfig,
) !void {
    try buf.appendSlice(allocator, "{\"runtime\":{\"name\":");
    try json_util.appendJsonString(buf, allocator, config.runtime_name);
    try buf.appendSlice(allocator, ",\"account_id\":");
    try json_util.appendJsonString(buf, allocator, config.account_id);
    try buf.append(allocator, '}');
}

fn requiredString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn requiredNonEmptyString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = requiredString(obj, key) orelse return null;
    return if (value.len > 0) value else null;
}

fn stringValue(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string and value.string.len > 0) value.string else null;
}

fn parseMediaSlice(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]const []const u8 {
    const media_value = obj.get("media") orelse return &.{};
    if (media_value != .array) return Error.InvalidPluginResponse;
    if (media_value.array.items.len == 0) return &.{};

    const media = try allocator.alloc([]const u8, media_value.array.items.len);
    var idx: usize = 0;
    errdefer allocator.free(media);
    for (media_value.array.items) |item| {
        if (item != .string or item.string.len == 0) return Error.InvalidPluginResponse;
        media[idx] = item.string;
        idx += 1;
    }
    return media;
}

fn parseMetadataValue(obj: std.json.ObjectMap) !?std.json.Value {
    const metadata_value = obj.get("metadata") orelse return null;
    if (metadata_value != .object) return Error.InvalidPluginResponse;
    return metadata_value;
}

fn stageToSlice(stage: root.Channel.OutboundStage) []const u8 {
    return switch (stage) {
        .chunk => "chunk",
        .final => "final",
    };
}

fn attachmentKindToSlice(kind: root.Channel.OutboundAttachmentKind) []const u8 {
    return switch (kind) {
        .image => "image",
        .document => "document",
        .video => "video",
        .audio => "audio",
        .voice => "voice",
    };
}

fn isMethodNotFoundError(err_value: std.json.Value) bool {
    if (err_value != .object) return false;
    if (err_value.object.get("code")) |code_value| {
        if (code_value == .integer and code_value.integer == -32601) {
            return true;
        }
    }
    if (err_value.object.get("message")) |message_value| {
        if (message_value == .string) {
            const message = message_value.string;
            return std.ascii.indexOfIgnoreCase(message, "method not found") != null or
                std.ascii.indexOfIgnoreCase(message, "not implemented") != null or
                std.ascii.indexOfIgnoreCase(message, "unknown method") != null;
        }
    }
    return false;
}

test "buildSendParams nests runtime and message payloads" {
    const allocator = std.testing.allocator;
    const params = try buildSendParams(allocator, .{
        .account_id = "main",
        .runtime_name = "whatsapp_web",
        .transport = .{ .command = "plugin" },
    }, "chat-1", "hello", &.{ "a.png", "b.jpg" }, .chunk);
    defer allocator.free(params);

    try std.testing.expect(std.mem.indexOf(u8, params, "\"runtime\":{\"name\":\"whatsapp_web\",\"account_id\":\"main\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"message\":{\"target\":\"chat-1\",\"text\":\"hello\",\"stage\":\"chunk\",\"media\":[\"a.png\",\"b.jpg\"]}") != null);
}

test "buildSendRichParams serializes attachments and choices" {
    const allocator = std.testing.allocator;
    const attachments = [_]root.Channel.OutboundAttachment{
        .{ .kind = .image, .target = "/tmp/a.png", .caption = "cover" },
    };
    const choices = [_]root.Channel.OutboundChoice{
        .{ .id = "yes", .label = "Yes", .submit_text = "yes" },
    };
    const params = try buildSendRichParams(allocator, .{
        .account_id = "main",
        .runtime_name = "plugin_chat",
        .transport = .{ .command = "plugin" },
    }, "chat-9", .{
        .text = "hello",
        .attachments = &attachments,
        .choices = &choices,
    });
    defer allocator.free(params);

    try std.testing.expect(std.mem.indexOf(u8, params, "\"attachments\":[{\"kind\":\"image\",\"target\":\"/tmp/a.png\",\"caption\":\"cover\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"choices\":[{\"id\":\"yes\",\"label\":\"Yes\",\"submit_text\":\"yes\"}]") != null);
}

test "buildTypingParams serializes runtime and recipient" {
    const allocator = std.testing.allocator;
    const params = try buildTypingParams(allocator, .{
        .account_id = "main",
        .runtime_name = "plugin_chat",
        .transport = .{ .command = "plugin" },
    }, "room-1");
    defer allocator.free(params);

    try std.testing.expectEqualStrings("{\"runtime\":{\"name\":\"plugin_chat\",\"account_id\":\"main\"},\"recipient\":\"room-1\"}", params);
}

test "parseManifestResponse requires matching protocol version" {
    const manifest = try parseManifestResponse(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocol_version\":2,\"capabilities\":{\"health\":true,\"streaming\":true,\"send_rich\":true,\"typing\":false}}}",
    );
    try std.testing.expectEqual(@as(?bool, true), manifest.health_supported);
    try std.testing.expectEqual(@as(?bool, true), manifest.streaming_supported);
    try std.testing.expectEqual(@as(?bool, true), manifest.send_rich_supported);
    try std.testing.expectEqual(@as(?bool, false), manifest.typing_supported);

    try std.testing.expectError(
        Error.UnsupportedPluginProtocolVersion,
        parseManifestResponse(
            std.testing.allocator,
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocol_version\":1}}",
        ),
    );
}

test "parseInboundMessageParams reads nested message envelope" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"message\":{\"sender_id\":\"5511\",\"chat_id\":\"room-1\",\"text\":\"hello\",\"session_key\":\"custom\",\"media\":[\"a.png\"],\"metadata\":{\"peer_kind\":\"group\"}}}",
        .{},
    );
    defer parsed.deinit();

    const msg = try parseInboundMessageParams(allocator, parsed.value);
    defer if (msg.media.len > 0) allocator.free(msg.media);

    try std.testing.expectEqualStrings("5511", msg.sender_id);
    try std.testing.expectEqualStrings("room-1", msg.chat_id);
    try std.testing.expectEqualStrings("hello", msg.content);
    try std.testing.expectEqualStrings("custom", msg.session_key.?);
    try std.testing.expectEqual(@as(usize, 1), msg.media.len);
    try std.testing.expect(msg.metadata_value != null);
}

test "parseInboundMessageParams rejects non-object metadata" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"message\":{\"sender_id\":\"5511\",\"chat_id\":\"room-1\",\"text\":\"hello\",\"metadata\":\"bad\"}}",
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectError(Error.InvalidPluginResponse, parseInboundMessageParams(allocator, parsed.value));
}

test "parseInboundMessageParams rejects non-string media entries" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"message\":{\"sender_id\":\"5511\",\"chat_id\":\"room-1\",\"text\":\"hello\",\"media\":[\"ok\",1]}}",
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectError(Error.InvalidPluginResponse, parseInboundMessageParams(allocator, parsed.value));
}

test "parseHealthResponse honors connectivity booleans" {
    try std.testing.expect(try parseHealthResponse(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"healthy\":true}}",
    ));
    try std.testing.expect(!(try parseHealthResponse(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true,\"connected\":true,\"logged_in\":false}}",
    )));
}

test "parseHealthResponse rejects ambiguous empty result" {
    try std.testing.expectError(
        Error.InvalidPluginResponse,
        parseHealthResponse(
            std.testing.allocator,
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}",
        ),
    );
}

test "validateRpcSuccess returns method not supported for missing method" {
    try std.testing.expectError(
        Error.MethodNotSupported,
        validateRpcSuccess(
            std.testing.allocator,
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"method not found\"}}",
        ),
    );
}

test "validateRpcSuccess requires result object" {
    try std.testing.expectError(
        Error.InvalidPluginResponse,
        validateRpcSuccess(
            std.testing.allocator,
            "{\"jsonrpc\":\"2.0\",\"id\":1}",
        ),
    );
}

test "validateStartedResponse rejects false started flag" {
    try std.testing.expectError(
        Error.PluginRequestRejected,
        validateStartedResponse(
            std.testing.allocator,
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"started\":false}}",
        ),
    );
}

test "validateAcceptedResponse requires accepted true" {
    try std.testing.expectError(
        Error.PluginRequestRejected,
        validateAcceptedResponse(
            std.testing.allocator,
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"accepted\":false}}",
        ),
    );

    try validateAcceptedResponse(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"accepted\":true}}",
    );
}
