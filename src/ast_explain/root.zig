//! ast-explain — BM25-searchable index over `.ast-explain/src/**/*.json` guidance files.
//!
//! Maintains a separate SQLite database at `<workspace>/.ast-explain/ast-explain.db`
//! and exposes an `AstDb` handle for sync and search operations.
//!
//! Public API:
//!   AstDb.init(allocator, db_path)   — open/create the database
//!   AstDb.deinit()                   — close the database
//!   AstDb.syncFromDir(allocator, src_dir_path) — ingest JSON files
//!   AstDb.search(allocator, query, limit)      — BM25 search
//!   AstDb.freeSearchResult(allocator, r)       — free a search result
//!
//! Schema mirrors ast-guidance's db.zig schema for compatibility.

const std = @import("std");
const build_options = @import("build_options");
const log = std.log.scoped(.ast_explain);

// ---------------------------------------------------------------------------
// Guard: whole module is no-op when SQLite is not compiled in
// ---------------------------------------------------------------------------

pub const enabled = build_options.enable_sqlite;

// ---------------------------------------------------------------------------
// SQLite C bindings (shared with memory/engines/sqlite.zig)
// ---------------------------------------------------------------------------

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const SQLITE_STATIC: c.sqlite3_destructor_type = null;
const BUSY_TIMEOUT_MS: c_int = 5000;

// ---------------------------------------------------------------------------
// SearchResult
// ---------------------------------------------------------------------------

pub const SearchResult = struct {
    file_path: []const u8,
    module: []const u8,
    node_type: []const u8,
    name: []const u8,
    signature: ?[]const u8,
    score: f64,
};

pub fn freeSearchResult(allocator: std.mem.Allocator, r: SearchResult) void {
    allocator.free(r.file_path);
    allocator.free(r.module);
    allocator.free(r.node_type);
    allocator.free(r.name);
    if (r.signature) |s| allocator.free(s);
}

// ---------------------------------------------------------------------------
// AstDb — database handle
// ---------------------------------------------------------------------------

pub const AstDb = struct {
    db: ?*c.sqlite3,

    const Self = @This();

    /// Open (or create) the guidance database at `db_path`, applying schema migrations.
    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !Self {
        if (comptime !enabled) return error.SqliteNotEnabled;

        const db_path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(db_path_z);

        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(db_path_z.ptr, &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            log.debug("sqlite3_open({s}) failed: rc={d}", .{ db_path, rc });
            return error.SqliteOpenFailed;
        }

        _ = c.sqlite3_busy_timeout(db, BUSY_TIMEOUT_MS);

        var self_ = Self{ .db = db };
        try self_.configurePragmas();
        try self_.migrate();
        return self_;
    }

    pub fn deinit(self: *Self) void {
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
            self.db = null;
        }
    }

    // ── Schema ─────────────────────────────────────────────────────

    fn configurePragmas(self: *Self) !void {
        const pragmas = [_][:0]const u8{
            "PRAGMA journal_mode = WAL;",
            "PRAGMA synchronous  = NORMAL;",
            "PRAGMA temp_store   = MEMORY;",
            "PRAGMA cache_size   = -2000;",
        };
        for (pragmas) |pragma| {
            var err_msg: [*c]u8 = null;
            const rc = c.sqlite3_exec(self.db, pragma, null, null, &err_msg);
            if (err_msg) |msg| c.sqlite3_free(msg);
            _ = rc;
        }
    }

    fn migrate(self: *Self) !void {
        const sql =
            \\CREATE TABLE IF NOT EXISTS ast_nodes (
            \\  id            INTEGER PRIMARY KEY,
            \\  file_path     TEXT    NOT NULL,
            \\  module        TEXT    NOT NULL,
            \\  node_type     TEXT    NOT NULL,
            \\  name          TEXT    NOT NULL,
            \\  signature     TEXT,
            \\  last_modified INTEGER NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_ast_file  ON ast_nodes(file_path);
            \\CREATE INDEX IF NOT EXISTS idx_ast_mtime ON ast_nodes(file_path, last_modified);
            \\
            \\CREATE VIRTUAL TABLE IF NOT EXISTS fts_search USING fts5(
            \\  name,
            \\  comment,
            \\  module,
            \\  content='ast_nodes',
            \\  content_rowid='id'
            \\);
            \\
            \\CREATE TRIGGER IF NOT EXISTS ast_nodes_ai
            \\  AFTER INSERT ON ast_nodes BEGIN
            \\    INSERT INTO fts_search(rowid, name, comment, module)
            \\    VALUES (new.id, new.name, '', new.module);
            \\  END;
            \\
            \\CREATE TRIGGER IF NOT EXISTS ast_nodes_ad
            \\  AFTER DELETE ON ast_nodes BEGIN
            \\    INSERT INTO fts_search(fts_search, rowid, name, comment, module)
            \\    VALUES ('delete', old.id, old.name, '', old.module);
            \\  END;
            \\
            \\CREATE TRIGGER IF NOT EXISTS ast_nodes_au
            \\  AFTER UPDATE ON ast_nodes BEGIN
            \\    INSERT INTO fts_search(fts_search, rowid, name, comment, module)
            \\    VALUES ('delete', old.id, old.name, '', old.module);
            \\    INSERT INTO fts_search(rowid, name, comment, module)
            \\    VALUES (new.id, new.name, '', new.module);
            \\  END;
        ;
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            logSqliteErr("migrate", "schema", rc, err_msg, self.db);
            if (err_msg) |msg| c.sqlite3_free(msg);
            return error.MigrationFailed;
        }
    }

    // ── Sync ───────────────────────────────────────────────────────

    /// Walk `src_dir_path` and upsert stale JSON guidance files into the index.
    /// Uses per-file ArenaAllocators to bound peak memory usage.
    pub fn syncFromDir(self: *Self, allocator: std.mem.Allocator, src_dir_path: []const u8) !SyncStats {
        var src_dir = std.fs.cwd().openDir(src_dir_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                log.warn("guidance src dir not found: {s}", .{src_dir_path});
                return .{};
            }
            return err;
        };
        defer src_dir.close();

        var walker = try src_dir.walk(allocator);
        defer walker.deinit();

        var stats: SyncStats = .{};

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".json")) continue;

            const rel_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_dir_path, entry.path });
            defer allocator.free(rel_path);

            const stat = std.fs.cwd().statFile(rel_path) catch |err| {
                log.warn("stat({s}): {s}", .{ rel_path, @errorName(err) });
                continue;
            };
            const mtime_sec: i64 = @intCast(@divTrunc(stat.mtime, std.time.ns_per_s));

            if (try self.fileIsUpToDate(rel_path, mtime_sec)) {
                stats.skipped += 1;
                continue;
            }

            var file_arena = std.heap.ArenaAllocator.init(allocator);
            defer file_arena.deinit();

            self.indexFile(file_arena.allocator(), rel_path, mtime_sec) catch |err| {
                log.warn("indexFile({s}): {s}", .{ rel_path, @errorName(err) });
                stats.errors += 1;
                continue;
            };
            stats.synced += 1;
        }

        log.info("sync complete: {d} updated, {d} skipped, {d} errors", .{ stats.synced, stats.skipped, stats.errors });
        return stats;
    }

    pub const SyncStats = struct {
        synced: usize = 0,
        skipped: usize = 0,
        errors: usize = 0,
    };

    fn fileIsUpToDate(self: *Self, file_path: []const u8, mtime: i64) !bool {
        const sql = "SELECT last_modified FROM ast_nodes WHERE file_path = ?1 LIMIT 1";
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return false;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, file_path.ptr, @intCast(file_path.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const stored_mtime = c.sqlite3_column_int64(stmt, 0);
            return stored_mtime == mtime;
        }
        return false;
    }

    fn indexFile(self: *Self, allocator: std.mem.Allocator, file_path: []const u8, mtime: i64) !void {
        const file_data = try std.fs.cwd().readFileAlloc(allocator, file_path, 8 * 1024 * 1024);
        defer allocator.free(file_data);

        const parsed = try parseGuidanceJson(allocator, file_data);

        try self.execSimple("BEGIN");
        errdefer self.execSimpleNoErr("ROLLBACK");

        try self.deleteFileRecords(file_path);
        try self.insertModule(file_path, parsed.module, parsed.module_comment, mtime);
        for (parsed.members) |m| {
            try self.insertMember(file_path, parsed.module, m, mtime);
        }

        try self.execSimple("COMMIT");
    }

    fn deleteFileRecords(self: *Self, file_path: []const u8) !void {
        const sql = "DELETE FROM ast_nodes WHERE file_path = ?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, file_path.ptr, @intCast(file_path.len), SQLITE_STATIC);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.StepFailed;
    }

    fn insertModule(self: *Self, file_path: []const u8, module: []const u8, comment: ?[]const u8, mtime: i64) !void {
        const sql =
            "INSERT INTO ast_nodes(file_path, module, node_type, name, signature, last_modified) " ++
            "VALUES (?1, ?2, 'module', ?3, NULL, ?4)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        const name = comment orelse module;
        _ = c.sqlite3_bind_text(stmt, 1, file_path.ptr, @intCast(file_path.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, module.ptr, @intCast(module.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 3, name.ptr, @intCast(name.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 4, mtime);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.StepFailed;
    }

    fn insertMember(self: *Self, file_path: []const u8, module: []const u8, m: ParsedMember, mtime: i64) !void {
        const sql =
            "INSERT INTO ast_nodes(file_path, module, node_type, name, signature, last_modified) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5, ?6)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, file_path.ptr, @intCast(file_path.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, module.ptr, @intCast(module.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 3, m.node_type.ptr, @intCast(m.node_type.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 4, m.name.ptr, @intCast(m.name.len), SQLITE_STATIC);
        if (m.signature) |sig| {
            _ = c.sqlite3_bind_text(stmt, 5, sig.ptr, @intCast(sig.len), SQLITE_STATIC);
        } else {
            _ = c.sqlite3_bind_null(stmt, 5);
        }
        _ = c.sqlite3_bind_int64(stmt, 6, mtime);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.StepFailed;

        // Patch FTS row to include comment for richer BM25 scoring.
        if (m.comment) |comment| {
            const rowid = c.sqlite3_last_insert_rowid(self.db);
            self.updateFtsComment(rowid, m.name, comment, module) catch {};
        }
    }

    fn updateFtsComment(self: *Self, rowid: i64, name: []const u8, comment: []const u8, module: []const u8) !void {
        const del_sql = "INSERT INTO fts_search(fts_search, rowid, name, comment, module) VALUES('delete',?1,?2,'',?3)";
        const ins_sql = "INSERT INTO fts_search(rowid, name, comment, module) VALUES(?1,?2,?3,?4)";

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, del_sql, -1, &stmt, null) == c.SQLITE_OK) {
            _ = c.sqlite3_bind_int64(stmt, 1, rowid);
            _ = c.sqlite3_bind_text(stmt, 2, name.ptr, @intCast(name.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_text(stmt, 3, module.ptr, @intCast(module.len), SQLITE_STATIC);
            _ = c.sqlite3_step(stmt);
            _ = c.sqlite3_finalize(stmt);
        }

        stmt = null;
        if (c.sqlite3_prepare_v2(self.db, ins_sql, -1, &stmt, null) == c.SQLITE_OK) {
            _ = c.sqlite3_bind_int64(stmt, 1, rowid);
            _ = c.sqlite3_bind_text(stmt, 2, name.ptr, @intCast(name.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_text(stmt, 3, comment.ptr, @intCast(comment.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_text(stmt, 4, module.ptr, @intCast(module.len), SQLITE_STATIC);
            _ = c.sqlite3_step(stmt);
            _ = c.sqlite3_finalize(stmt);
        }
    }

    // ── Search ─────────────────────────────────────────────────────

    /// BM25 full-text search.  Returns results ordered best-first.
    /// Caller must free each result field with `freeSearchResult` and free the slice.
    pub fn search(
        self: *Self,
        allocator: std.mem.Allocator,
        query_text: []const u8,
        limit: usize,
    ) ![]SearchResult {
        const trimmed = std.mem.trim(u8, query_text, " \t\n\r");
        if (trimmed.len == 0) return allocator.alloc(SearchResult, 0);

        // Build quoted-OR FTS5 query from whitespace-separated tokens.
        var fts_buf: std.ArrayList(u8) = .empty;
        defer fts_buf.deinit(allocator);
        var it = std.mem.tokenizeAny(u8, trimmed, " \t\n\r");
        var first = true;
        while (it.next()) |word| {
            if (!first) try fts_buf.appendSlice(allocator, " OR ");
            try fts_buf.append(allocator, '"');
            for (word) |ch| {
                if (ch == '"') try fts_buf.appendSlice(allocator, "\"\"") else try fts_buf.append(allocator, ch);
            }
            try fts_buf.append(allocator, '"');
            first = false;
        }
        if (fts_buf.items.len == 0) return allocator.alloc(SearchResult, 0);
        try fts_buf.append(allocator, 0); // null-terminate

        const sql =
            "SELECT n.file_path, n.module, n.node_type, n.name, n.signature, " ++
            "       bm25(fts_search) as score " ++
            "FROM fts_search f " ++
            "JOIN ast_nodes n ON n.id = f.rowid " ++
            "WHERE fts_search MATCH ?1 " ++
            "ORDER BY score " ++
            "LIMIT ?2";

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return allocator.alloc(SearchResult, 0);
        defer _ = c.sqlite3_finalize(stmt);

        const fts_query = fts_buf.items[0 .. fts_buf.items.len - 1];
        _ = c.sqlite3_bind_text(stmt, 1, fts_query.ptr, @intCast(fts_query.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(limit));

        var results: std.ArrayList(SearchResult) = .empty;
        errdefer {
            for (results.items) |r| freeSearchResult(allocator, r);
            results.deinit(allocator);
        }

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const result = try readSearchResult(stmt.?, allocator);
            try results.append(allocator, result);
        }

        return results.toOwnedSlice(allocator);
    }

    // ── SQL utilities ──────────────────────────────────────────────

    fn execSimple(self: *Self, sql: [:0]const u8) !void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            logSqliteErr("exec", sql, rc, err_msg, self.db);
            if (err_msg) |msg| c.sqlite3_free(msg);
            return error.ExecFailed;
        }
    }

    fn execSimpleNoErr(self: *Self, sql: [:0]const u8) void {
        var err_msg: [*c]u8 = null;
        _ = c.sqlite3_exec(self.db, sql, null, null, &err_msg);
        if (err_msg) |msg| c.sqlite3_free(msg);
    }
};

// ---------------------------------------------------------------------------
// Column helpers
// ---------------------------------------------------------------------------

fn readSearchResult(stmt: *c.sqlite3_stmt, allocator: std.mem.Allocator) !SearchResult {
    return SearchResult{
        .file_path = try dupeCol(stmt, 0, allocator),
        .module = try dupeCol(stmt, 1, allocator),
        .node_type = try dupeCol(stmt, 2, allocator),
        .name = try dupeCol(stmt, 3, allocator),
        .signature = try dupeColNullable(stmt, 4, allocator),
        .score = -c.sqlite3_column_double(stmt, 5), // BM25 returns negative → flip to positive
    };
}

fn dupeCol(stmt: *c.sqlite3_stmt, col: c_int, allocator: std.mem.Allocator) ![]u8 {
    const raw = c.sqlite3_column_text(stmt, col);
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    if (raw == null or len == 0) return allocator.dupe(u8, "");
    return allocator.dupe(u8, @as([*]const u8, @ptrCast(raw))[0..len]);
}

fn dupeColNullable(stmt: *c.sqlite3_stmt, col: c_int, allocator: std.mem.Allocator) !?[]u8 {
    if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) return null;
    const raw = c.sqlite3_column_text(stmt, col);
    if (raw == null) return null;
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    return try allocator.dupe(u8, @as([*]const u8, @ptrCast(raw))[0..len]);
}

fn logSqliteErr(context: []const u8, sql: []const u8, rc: c_int, err_msg: [*c]u8, db: ?*c.sqlite3) void {
    if (err_msg) |msg| {
        log.warn("sqlite {s} failed (rc={d}, sql={s}): {s}", .{ context, rc, sql, std.mem.span(msg) });
        return;
    }
    if (db) |d| {
        log.warn("sqlite {s} failed (rc={d}, sql={s}): {s}", .{ context, rc, sql, std.mem.span(c.sqlite3_errmsg(d)) });
        return;
    }
    log.warn("sqlite {s} failed (rc={d}, sql={s})", .{ context, rc, sql });
}

// ---------------------------------------------------------------------------
// JSON parsing — extract fields from GuidanceDoc format
// ---------------------------------------------------------------------------

const ParsedMember = struct {
    node_type: []const u8,
    name: []const u8,
    signature: ?[]const u8,
    comment: ?[]const u8,
};

const ParsedDoc = struct {
    module: []const u8,
    module_comment: ?[]const u8,
    members: []ParsedMember,
};

fn parseGuidanceJson(arena: std.mem.Allocator, json_data: []const u8) !ParsedDoc {
    const Value = std.json.Value;
    const parsed = try std.json.parseFromSlice(Value, arena, json_data, .{
        .ignore_unknown_fields = true,
    });

    const root_val = parsed.value;
    if (root_val != .object) return error.InvalidJson;

    const meta_val = root_val.object.get("meta") orelse return error.MissingMeta;
    if (meta_val != .object) return error.MissingMeta;
    const module_val = meta_val.object.get("module") orelse return error.MissingModule;
    if (module_val != .string) return error.MissingModule;
    const module = module_val.string;

    const comment: ?[]const u8 = blk: {
        const cv = root_val.object.get("comment") orelse break :blk null;
        if (cv != .string) break :blk null;
        break :blk cv.string;
    };

    var members_list: std.ArrayList(ParsedMember) = .empty;

    const members_val = root_val.object.get("members") orelse {
        return .{ .module = module, .module_comment = comment, .members = &.{} };
    };
    if (members_val != .array) {
        return .{ .module = module, .module_comment = comment, .members = &.{} };
    }

    for (members_val.array.items) |item| {
        if (item != .object) continue;
        const m = parseMemberValue(item);
        try members_list.append(arena, m);
        // Recurse into nested members (e.g. methods inside a struct).
        if (item.object.get("members")) |nested_val| {
            if (nested_val == .array) {
                for (nested_val.array.items) |nested_item| {
                    if (nested_item != .object) continue;
                    try members_list.append(arena, parseMemberValue(nested_item));
                }
            }
        }
    }

    return .{
        .module = module,
        .module_comment = comment,
        .members = try members_list.toOwnedSlice(arena),
    };
}

fn parseMemberValue(item: std.json.Value) ParsedMember {
    const node_type: []const u8 = blk: {
        const tv = item.object.get("type") orelse break :blk "unknown";
        if (tv != .string) break :blk "unknown";
        break :blk tv.string;
    };
    const name: []const u8 = blk: {
        const nv = item.object.get("name") orelse break :blk "";
        if (nv != .string) break :blk "";
        break :blk nv.string;
    };
    const signature: ?[]const u8 = blk: {
        const sv = item.object.get("signature") orelse break :blk null;
        if (sv != .string) break :blk null;
        break :blk sv.string;
    };
    const comment: ?[]const u8 = blk: {
        const cv = item.object.get("comment") orelse break :blk null;
        if (cv != .string) break :blk null;
        if (cv.string.len < 4) break :blk null;
        break :blk cv.string;
    };
    return .{ .node_type = node_type, .name = name, .signature = signature, .comment = comment };
}

// ---------------------------------------------------------------------------
// Path utilities
// ---------------------------------------------------------------------------

/// Resolve the guidance database path: `<workspace>/.ast-explain/ast-explain.db`.
/// Caller owns the returned string.
pub fn resolveDatabasePath(allocator: std.mem.Allocator, workspace_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.ast-explain/ast-explain.db", .{workspace_dir});
}

/// Resolve the guidance src dir: `<workspace>/.ast-explain/src`.
/// Caller owns the returned string.
pub fn resolveSrcDir(allocator: std.mem.Allocator, workspace_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.ast-explain/src", .{workspace_dir});
}

/// Ensure the `.ast-explain` directory exists under `workspace_dir`.
pub fn ensureDir(workspace_dir: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&buf, "{s}/.ast-explain", .{workspace_dir}) catch return error.PathTooLong;
    std.fs.cwd().makePath(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseGuidanceJson extracts module and members" {
    const json =
        \\{
        \\  "meta": { "module": "src.foo.bar", "source": "src/foo/bar.zig", "language": "zig" },
        \\  "comment": "Does something useful.",
        \\  "members": [
        \\    { "type": "fn_decl", "name": "doThing", "signature": "fn doThing() void", "comment": "Does the thing." },
        \\    { "type": "struct",  "name": "MyState" }
        \\  ]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const doc = try parseGuidanceJson(arena.allocator(), json);
    try std.testing.expectEqualStrings("src.foo.bar", doc.module);
    try std.testing.expectEqualStrings("Does something useful.", doc.module_comment.?);
    try std.testing.expectEqual(@as(usize, 2), doc.members.len);
    try std.testing.expectEqualStrings("doThing", doc.members[0].name);
    try std.testing.expectEqualStrings("Does the thing.", doc.members[0].comment.?);
    try std.testing.expectEqualStrings("MyState", doc.members[1].name);
    try std.testing.expect(doc.members[1].comment == null);
}

test "parseGuidanceJson handles missing meta gracefully" {
    const json =
        \\{"foo": "bar"}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MissingMeta, parseGuidanceJson(arena.allocator(), json));
}

test "AstDb init and schema creation" {
    if (comptime !enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const db_path = try std.fmt.allocPrint(allocator, "{s}/ast-explain.db", .{tmp_path});
    defer allocator.free(db_path);

    var db = try AstDb.init(allocator, db_path);
    defer db.deinit();

    // Schema health check
    var err_msg: [*c]u8 = null;
    const rc = c.sqlite3_exec(db.db, "SELECT 1 FROM ast_nodes LIMIT 1", null, null, &err_msg);
    if (err_msg) |msg| c.sqlite3_free(msg);
    try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), rc);
}

test "AstDb full sync and search round-trip" {
    if (comptime !enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const db_path = try std.fmt.allocPrint(allocator, "{s}/ast-explain.db", .{tmp_path});
    defer allocator.free(db_path);

    try tmp.dir.makeDir("src");
    const json_data =
        \\{
        \\  "meta": { "module": "src.mymod", "source": "src/mymod.zig", "language": "zig" },
        \\  "comment": "The best module.",
        \\  "members": [
        \\    { "type": "fn_decl", "name": "frobnicate", "comment": "Frobnicates the widget." }
        \\  ]
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "src/mymod.zig.json", .data = json_data });

    var db = try AstDb.init(allocator, db_path);
    defer db.deinit();

    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{tmp_path});
    defer allocator.free(src_dir);

    const stats = try db.syncFromDir(allocator, src_dir);
    try std.testing.expectEqual(@as(usize, 1), stats.synced);
    try std.testing.expectEqual(@as(usize, 0), stats.errors);

    const results = try db.search(allocator, "frobnicate", 10);
    defer {
        for (results) |r| freeSearchResult(allocator, r);
        allocator.free(results);
    }

    try std.testing.expect(results.len >= 1);
    try std.testing.expectEqualStrings("frobnicate", results[0].name);
}

test "AstDb search empty query returns empty" {
    if (comptime !enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const db_path = try std.fmt.allocPrint(allocator, "{s}/ast-explain.db", .{tmp_path});
    defer allocator.free(db_path);

    var db = try AstDb.init(allocator, db_path);
    defer db.deinit();

    const results = try db.search(allocator, "  ", 10);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "resolveDatabasePath" {
    const allocator = std.testing.allocator;
    const path = try resolveDatabasePath(allocator, "/workspace");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/workspace/.ast-explain/ast-explain.db", path);
}
