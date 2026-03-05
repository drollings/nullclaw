/// --from-json subcommand: non-interactive config generation from wizard answers.
///
/// Accepts a JSON string with wizard answers, applies them to the config,
/// saves, scaffolds the workspace, and prints {"status":"ok"} on success.
/// Used by nullhub to configure nullclaw without interactive terminal input.
const std = @import("std");
const onboard = @import("onboard.zig");
const channel_catalog = @import("channel_catalog.zig");
const config_mod = @import("config.zig");
const Config = config_mod.Config;

const WizardAnswers = struct {
    provider: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    model: ?[]const u8 = null,
    memory: ?[]const u8 = null,
    tunnel: ?[]const u8 = null,
    autonomy: ?[]const u8 = null,
    gateway_port: ?u16 = null,
    /// Comma-separated channel keys (e.g. "cli,webhook,web").
    channels: ?[]const u8 = null,
    /// Override config/workspace directory (used by nullhub for instance isolation).
    /// Falls back to NULLCLAW_HOME env, then ~/.nullclaw/.
    home: ?[]const u8 = null,
};

const AutonomySelectionError = error{InvalidAutonomyLevel};

fn isKnownTunnelProvider(tunnel: []const u8) bool {
    for (onboard.tunnel_options) |option| {
        if (std.mem.eql(u8, option, tunnel)) return true;
    }
    return false;
}

fn applyAutonomySelection(cfg: *Config, autonomy: []const u8) AutonomySelectionError!void {
    if (std.mem.eql(u8, autonomy, "supervised")) {
        cfg.autonomy.level = .supervised;
        cfg.autonomy.require_approval_for_medium_risk = true;
        cfg.autonomy.block_high_risk_commands = true;
        return;
    }
    if (std.mem.eql(u8, autonomy, "autonomous")) {
        cfg.autonomy.level = .full;
        cfg.autonomy.require_approval_for_medium_risk = false;
        cfg.autonomy.block_high_risk_commands = true;
        return;
    }
    if (std.mem.eql(u8, autonomy, "fully_autonomous")) {
        cfg.autonomy.level = .full;
        cfg.autonomy.require_approval_for_medium_risk = false;
        cfg.autonomy.block_high_risk_commands = false;
        return;
    }
    return error.InvalidAutonomyLevel;
}

fn applyChannelKey(webhook_selected: *bool, channel_key: []const u8) void {
    const meta = channel_catalog.findByKey(channel_key) orelse return;
    if (!channel_catalog.isBuildEnabled(meta.id)) return;
    switch (meta.id) {
        .webhook => webhook_selected.* = true,
        .cli, .web => {}, // Always enabled by default, no config needed.
        else => {}, // Other channels need manual config; silently skip.
    }
}

fn applyChannelsFromString(cfg: *Config, channels_csv: []const u8) void {
    var webhook_selected = false;

    var it = std.mem.splitScalar(u8, channels_csv, ',');
    while (it.next()) |raw_key| {
        const channel_key = std.mem.trim(u8, raw_key, " ");
        if (channel_key.len == 0) continue;
        applyChannelKey(&webhook_selected, channel_key);
    }

    cfg.channels.webhook = if (webhook_selected) .{ .port = cfg.gateway.port } else null;
}

fn initConfigWithCustomHome(backing_allocator: std.mem.Allocator, home_dir: []const u8) !Config {
    const arena_ptr = try backing_allocator.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer {
        arena_ptr.deinit();
        backing_allocator.destroy(arena_ptr);
    }
    const allocator = arena_ptr.allocator();

    var cfg = Config{
        .workspace_dir = "",
        .config_path = "",
        .allocator = allocator,
        .arena = arena_ptr,
    };

    const config_path = try std.fs.path.join(allocator, &.{ home_dir, "config.json" });
    const workspace_dir = try std.fs.path.join(allocator, &.{ home_dir, "workspace" });
    cfg.config_path = config_path;
    cfg.workspace_dir = workspace_dir;
    cfg.workspace_dir_override = workspace_dir;

    if (std.fs.openFileAbsolute(config_path, .{})) |file| {
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 1024 * 64);
        cfg.parseJson(content) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                std.debug.print("Warning: failed to parse config.json: {s}\n", .{@errorName(err)});
            },
        };
    } else |_| {
        // No existing config at custom path.
    }

    // Enforce home-scoped paths for isolated instances.
    cfg.config_path = config_path;
    cfg.workspace_dir = workspace_dir;
    cfg.workspace_dir_override = workspace_dir;
    cfg.syncFlatFields();

    return cfg;
}

fn loadConfigForFromJson(allocator: std.mem.Allocator, custom_home: ?[]const u8) !Config {
    if (custom_home) |home_dir| {
        return initConfigWithCustomHome(allocator, home_dir);
    }
    return Config.load(allocator) catch try onboard.initFreshConfig(allocator);
}

/// Apply providers from the wizard's providers array (new multi-provider format).
/// Sets default_provider and default_model from the first entry, and creates
/// ProviderEntry array from all entries.
fn applyProvidersFromArray(cfg: *Config, items: []const std.json.Value) !void {
    if (items.len == 0) return;

    // First entry sets default_provider and default_model
    if (items[0] == .object) {
        const first = items[0].object;
        if (first.get("provider")) |v| {
            if (v == .string) {
                const provider_info = onboard.resolveProviderForQuickSetup(v.string) orelse {
                    std.debug.print("error: unknown provider '{s}'\n", .{v.string});
                    std.process.exit(1);
                };
                cfg.default_provider = try cfg.allocator.dupe(u8, provider_info.key);
            }
        }
        if (first.get("model")) |v| {
            if (v == .string and v.string.len > 0) {
                cfg.default_model = try cfg.allocator.dupe(u8, v.string);
            }
        }
    }

    // Create ProviderEntry array from all entries
    var entries_list: std.ArrayListUnmanaged(config_mod.ProviderEntry) = .empty;
    for (items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const name = if (obj.get("provider")) |v|
            (if (v == .string) v.string else continue)
        else
            continue;
        const api_key = if (obj.get("api_key")) |v|
            (if (v == .string and v.string.len > 0) v.string else null)
        else
            null;

        const resolved = onboard.resolveProviderForQuickSetup(name) orelse continue;
        try entries_list.append(cfg.allocator, .{
            .name = try cfg.allocator.dupe(u8, resolved.key),
            .api_key = if (api_key) |k| try cfg.allocator.dupe(u8, k) else null,
        });
    }

    if (entries_list.items.len > 0) {
        cfg.providers = try entries_list.toOwnedSlice(cfg.allocator);
    }
}

/// Merge channel configurations from the wizard's JSON object into config.json.
///
/// Wizard sends channels as: {"telegram": {"default": {"bot_token": "..."}}}
/// Config.json expects:       {"channels": {"telegram": {"accounts": {"default": {"bot_token": "..."}}}}}
///
/// After cfg.save() wrote the base config, this function reads it back,
/// merges the wizard's channel configs (wrapped with "accounts"), and writes it back.
fn mergeChannelsIntoConfig(allocator: std.mem.Allocator, config_path: []const u8, wizard_channels: std.json.ObjectMap) !void {
    // Read existing config.json
    const file = try std.fs.openFileAbsolute(config_path, .{});
    const content = try file.readToEndAlloc(allocator, 1024 * 256);
    defer allocator.free(content);
    file.close();

    // Parse existing config as Value tree
    const config_parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{ .allocate = .alloc_always }) catch return;
    defer config_parsed.deinit();

    if (config_parsed.value != .object) return;

    // Get channels section
    const channels_ptr = config_parsed.value.object.getPtr("channels") orelse return;
    if (channels_ptr.* != .object) return;

    // For each channel type in wizard input
    var ch_iter = wizard_channels.iterator();
    while (ch_iter.next()) |entry| {
        const channel_type = entry.key_ptr.*;
        const accounts_obj = entry.value_ptr.*;
        if (accounts_obj != .object) continue;

        // Skip cli (boolean flag, not an accounts object)
        if (std.mem.eql(u8, channel_type, "cli")) continue;

        // Wrap wizard format in "accounts" to match config.json format:
        // {"default": {"bot_token": "..."}} → {"accounts": {"default": {"bot_token": "..."}}}
        var channel_obj = std.json.ObjectMap.init(allocator);
        channel_obj.put("accounts", accounts_obj) catch continue;

        channels_ptr.*.object.put(channel_type, .{ .object = channel_obj }) catch continue;
    }

    // Serialize back to config.json using pretty-print
    const json_out = std.json.Stringify.valueAlloc(allocator, config_parsed.value, .{ .whitespace = .indent_2 }) catch return;
    defer allocator.free(json_out);

    const out_file = std.fs.createFileAbsolute(config_path, .{}) catch return;
    defer out_file.close();
    out_file.writeAll(json_out) catch return;
}

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("error: --from-json requires a JSON argument\n", .{});
        std.process.exit(1);
    }

    const json_str = args[0];
    const parsed = std.json.parseFromSlice(
        WizardAnswers,
        allocator,
        json_str,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        std.debug.print("error: invalid JSON\n", .{});
        std.process.exit(1);
    };
    defer parsed.deinit();
    const answers = parsed.value;

    // Raw JSON parse for providers array and channels object
    const raw_parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_str,
        .{ .allocate = .alloc_always },
    ) catch null;
    defer if (raw_parsed) |rp| rp.deinit();

    const env_home = std.process.getEnvVarOwned(allocator, "NULLCLAW_HOME") catch null;
    defer if (env_home) |v| allocator.free(v);

    // Resolve home directory: JSON home > NULLCLAW_HOME env > default (~/.nullclaw/)
    const custom_home: ?[]const u8 = answers.home orelse env_home;

    // Load config. For custom home, read/write only that home path.
    var cfg = try loadConfigForFromJson(allocator, custom_home);
    defer cfg.deinit();

    // Check for providers array in raw JSON (new wizard format)
    const has_providers_array = blk: {
        if (raw_parsed) |rp| {
            if (rp.value == .object) {
                if (rp.value.object.get("providers")) |prov_val| {
                    if (prov_val == .array and prov_val.array.items.len > 0) {
                        break :blk true;
                    }
                }
            }
        }
        break :blk false;
    };

    if (has_providers_array) {
        // New multi-provider format from wizard
        const prov_arr = raw_parsed.?.value.object.get("providers").?.array;
        try applyProvidersFromArray(&cfg, prov_arr.items);
    } else {
        // Legacy flat provider/api_key/model fields
        if (answers.provider) |p| {
            const provider_info = onboard.resolveProviderForQuickSetup(p) orelse {
                std.debug.print("error: unknown provider '{s}'\n", .{p});
                std.process.exit(1);
            };
            cfg.default_provider = try cfg.allocator.dupe(u8, provider_info.key);

            if (answers.api_key) |key| {
                const entries = try cfg.allocator.alloc(config_mod.ProviderEntry, 1);
                entries[0] = .{
                    .name = try cfg.allocator.dupe(u8, provider_info.key),
                    .api_key = try cfg.allocator.dupe(u8, key),
                };
                cfg.providers = entries;
            }
        } else if (answers.api_key) |key| {
            const entries = try cfg.allocator.alloc(config_mod.ProviderEntry, 1);
            entries[0] = .{
                .name = try cfg.allocator.dupe(u8, cfg.default_provider),
                .api_key = try cfg.allocator.dupe(u8, key),
            };
            cfg.providers = entries;
        }

        // Apply model (explicit or derive from provider)
        if (answers.model) |m| {
            cfg.default_model = try cfg.allocator.dupe(u8, m);
        } else if (answers.provider != null) {
            cfg.default_model = try cfg.allocator.dupe(u8, onboard.defaultModelForProvider(cfg.default_provider));
        }
    }

    // Apply memory backend
    if (answers.memory) |m| {
        const backend = onboard.resolveMemoryBackendForQuickSetup(m) catch |err| switch (err) {
            error.UnknownMemoryBackend => {
                std.debug.print("error: unknown memory backend '{s}'\n", .{m});
                std.process.exit(1);
            },
            error.MemoryBackendDisabledInBuild => {
                std.debug.print("error: memory backend '{s}' is disabled in this build\n", .{m});
                std.process.exit(1);
            },
        };
        cfg.memory.backend = backend.name;
        cfg.memory.profile = onboard.memoryProfileForBackend(backend.name);
        cfg.memory.auto_save = backend.auto_save_default;
    }

    // Apply tunnel provider
    if (answers.tunnel) |t| {
        if (!isKnownTunnelProvider(t)) {
            std.debug.print("error: invalid tunnel provider '{s}'\n", .{t});
            std.process.exit(1);
        }
        cfg.tunnel.provider = try cfg.allocator.dupe(u8, t);
    }

    // Apply autonomy level
    if (answers.autonomy) |a| {
        applyAutonomySelection(&cfg, a) catch {
            std.debug.print("error: invalid autonomy level '{s}'\n", .{a});
            std.process.exit(1);
        };
    }

    // Apply gateway port
    if (answers.gateway_port) |port| {
        if (port == 0) {
            std.debug.print("error: gateway_port must be > 0\n", .{});
            std.process.exit(1);
        }
        cfg.gateway.port = port;
    }

    // Apply channels (comma-separated string, e.g. "cli,web,webhook").
    // Unknown or unsupported channels are silently skipped.
    if (answers.channels) |channels_csv| {
        applyChannelsFromString(&cfg, channels_csv);
    }

    // Ensure a valid default model exists even when omitted in JSON payload.
    if (cfg.default_model == null) {
        cfg.default_model = try cfg.allocator.dupe(u8, onboard.defaultModelForProvider(cfg.default_provider));
    }

    // Sync flat convenience fields
    cfg.syncFlatFields();
    cfg.validate() catch |err| {
        Config.printValidationError(err);
        std.process.exit(1);
    };

    // Ensure parent config directory and workspace directory exist
    if (std.fs.path.dirname(cfg.workspace_dir)) |parent| {
        std.fs.makeDirAbsolute(parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    std.fs.makeDirAbsolute(cfg.workspace_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Scaffold workspace files
    try onboard.scaffoldWorkspace(allocator, cfg.workspace_dir, &onboard.ProjectContext{}, null);

    // Save config
    try cfg.save();

    // After save, merge channel configs from wizard's channels object into config.json.
    // The channels object has format: {"telegram": {"default": {"bot_token": "..."}}}
    // which needs wrapping with "accounts" to match config.json format.
    if (raw_parsed) |rp| {
        if (rp.value == .object) {
            if (rp.value.object.get("channels")) |ch_val| {
                if (ch_val == .object and ch_val.object.count() > 0) {
                    mergeChannelsIntoConfig(allocator, cfg.config_path, ch_val.object) catch |err| {
                        std.debug.print("warning: failed to merge channel configs: {s}\n", .{@errorName(err)});
                    };
                }
            }
        }
    }

    // Output success as JSON to stdout
    var stdout_buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&stdout_buf);
    try bw.interface.writeAll("{\"status\":\"ok\"}\n");
    try bw.interface.flush();
}

test "from_json requires JSON argument" {
    // Cannot easily test process.exit in-process; just verify the function signature compiles.
    // The real integration test is: nullclaw --from-json '{"provider":"openrouter"}'
}

test "isKnownTunnelProvider validates wizard options" {
    try std.testing.expect(isKnownTunnelProvider("none"));
    try std.testing.expect(isKnownTunnelProvider("cloudflare"));
    try std.testing.expect(!isKnownTunnelProvider("invalid-tunnel"));
}

test "applyAutonomySelection rejects invalid value" {
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
    };
    try std.testing.expectError(error.InvalidAutonomyLevel, applyAutonomySelection(&cfg, "danger-mode"));
}

test "applyChannelsFromString enables webhook from csv" {
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
    };

    applyChannelsFromString(&cfg, "cli,webhook,web");
    try std.testing.expect(cfg.channels.webhook != null);
    try std.testing.expectEqual(@as(u16, 3000), cfg.channels.webhook.?.port);
}

test "applyChannelsFromString ignores unknown channels" {
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
    };

    // Unknown channels are silently skipped (future-proofing).
    applyChannelsFromString(&cfg, "cli,web,future-channel,telegram");
    try std.testing.expect(cfg.channels.webhook == null);
}
