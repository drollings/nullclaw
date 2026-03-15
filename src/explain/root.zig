//! explain — Read-only BM25 search over pre-compiled `.explain.db` SQLite databases.
//!
//! NullClaw is a *consumer* of `.explain.db` files produced by explain-gen.
//! All indexing and sync work is performed externally by explain-gen.
//!
//! Public API:
//!   resolveDatabasePath(allocator, workspace_dir) -> []u8
//!       Checks NULLCLAW_EXPLAIN_DB env var, then <workspace>/.explain.db,
//!       then <workspace>/.ast-explain/ast-explain.db (legacy).
//!       Returns the first path that exists as a regular file, or error.DbNotFound.
//!
//!   ExplainDb.init(allocator, db_path)  — open existing database (read-only)
//!   ExplainDb.deinit()                  — close the database
//!   ExplainDb.search(allocator, query, limit) -> []SearchResult
//!   ExplainDb.searchWithAliases(allocator, query, limit, aliases) -> []SearchResult
//!   freeSearchResult(allocator, r)      — free an individual result
//!
//!   loadSemanticAliases(allocator, path) -> ?SemanticAliases
//!
//! Schema for .explain.db (created by explain-gen):
//!   ast_nodes(id, file_path, source, module, node_type, name, signature,
//!             comment, line, used_by, language, file_type, file_hash, last_modified)
//!   fts_search USING fts5(name, comment, module, signature,
//!                          content='ast_nodes', content_rowid='id')

const std = @import("std");
const build_options = @import("build_options");
const log = std.log.scoped(.explain);

// ---------------------------------------------------------------------------
// Guard: whole module is no-op when SQLite is not compiled in
// ---------------------------------------------------------------------------

pub const enabled = build_options.enable_sqlite;

// ---------------------------------------------------------------------------
// Sub-module: staged explain pipeline
// ---------------------------------------------------------------------------

pub const staged = @import("staged.zig");

// ---------------------------------------------------------------------------
// SQLite C bindings (shared with memory/engines/sqlite.zig)
// ---------------------------------------------------------------------------

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const SQLITE_STATIC: c.sqlite3_destructor_type = null;
const BUSY_TIMEOUT_MS: c_int = 5000;

// ---------------------------------------------------------------------------
// Stage types (used by the staged explain pipeline in staged.zig)
// ---------------------------------------------------------------------------

/// Classifies the kind of content in a Stage.
pub const StageKind = enum {
    /// Human-readable explanation from module or member comment.
    prose,
    /// Verbatim source code excerpt.  Never altered by LLM.
    code,
    /// Structured metadata: keywords, see_also, skills from guidance JSON.
    metadata,
    /// Matching bullet from INSIGHTS.md or CAPABILITIES.md.
    insight,
    /// Excerpt from a SKILL.md document.
    skill_doc,
};

/// A single unit of information collected by the staged explain pipeline.
/// All string fields are owned by this struct; call freeStage() to release.
pub const Stage = struct {
    kind: StageKind,
    /// Content to display (prose text, code block, metadata text, etc.).
    content: []const u8,
    /// Origin of this stage: relative source path, skill name, or "inbox".
    source: []const u8,
    /// Line number within `source` (optional, for code stages).
    line: ?u32 = null,
};

/// Free all allocations owned by a single Stage.
pub fn freeStage(allocator: std.mem.Allocator, s: Stage) void {
    allocator.free(s.content);
    allocator.free(s.source);
}

/// Free a slice of Stages and all allocations they own.
pub fn freeStages(allocator: std.mem.Allocator, stages: []const Stage) void {
    for (stages) |s| freeStage(allocator, s);
}

// ---------------------------------------------------------------------------
// Semantic aliases for query expansion
// ---------------------------------------------------------------------------

/// A single alias entry mapping a key to expansion values.
pub const SemanticAlias = struct {
    key: []const u8,
    values: []const []const u8,
};

/// Loaded semantic aliases (owned by caller).
pub const SemanticAliases = struct {
    aliases: []SemanticAlias,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *@This()) void {
        for (self.aliases) |a| {
            self.allocator.free(a.key);
            for (a.values) |v| self.allocator.free(v);
            self.allocator.free(a.values);
        }
        self.allocator.free(self.aliases);
    }

    /// Expand query tokens using aliases. Returns owned slice of owned strings.
    /// Caller must free the returned slice and each string.
    pub fn expandTokens(
        self: @This(),
        allocator: std.mem.Allocator,
        tokens: []const []const u8,
    ) ![]const []const u8 {
        var expanded: std.ArrayList([]const u8) = .{};
        errdefer {
            for (expanded.items) |t| allocator.free(t);
            expanded.deinit(allocator);
        }

        var seen_lowercase: std.StringHashMapUnmanaged(void) = .{};
        defer {
            var it = seen_lowercase.keyIterator();
            while (it.next()) |k| allocator.free(k.*);
            seen_lowercase.deinit(allocator);
        }

        for (tokens) |tok| {
            const lower = try std.ascii.allocLowerString(allocator, tok);
            const contains_lower = seen_lowercase.contains(lower);
            if (!contains_lower) {
                try seen_lowercase.put(allocator, lower, {});
            }
            if (contains_lower) {
                allocator.free(lower);
                continue;
            }

            try expanded.append(allocator, try allocator.dupe(u8, tok));

            for (self.aliases) |alias| {
                if (std.ascii.eqlIgnoreCase(tok, alias.key)) {
                    for (alias.values) |val| {
                        const val_lower = try std.ascii.allocLowerString(allocator, val);
                        if (seen_lowercase.contains(val_lower)) {
                            allocator.free(val_lower);
                            continue;
                        }
                        try seen_lowercase.put(allocator, val_lower, {});
                        try expanded.append(allocator, try allocator.dupe(u8, val));
                    }
                }
            }
        }

        return try expanded.toOwnedSlice(allocator);
    }
};

/// Load semantic aliases from a JSON file.
/// Returns null if the file does not exist or cannot be parsed.
pub fn loadSemanticAliases(allocator: std.mem.Allocator, path: []const u8) !?SemanticAliases {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 64 * 1024) catch return null;
    defer allocator.free(content);

    const Value = std.json.Value;
    var parsed = std.json.parseFromSlice(Value, allocator, content, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const aliases_arr = parsed.value.object.get("aliases") orelse return null;
    if (aliases_arr != .array) return null;

    var out: std.ArrayList(SemanticAlias) = .{};
    errdefer {
        for (out.items) |a| {
            allocator.free(a.key);
            for (a.values) |v| allocator.free(v);
            allocator.free(a.values);
        }
        out.deinit(allocator);
    }

    for (aliases_arr.array.items) |item| {
        if (item != .object) continue;
        const key_val = item.object.get("key") orelse continue;
        const values_val = item.object.get("values") orelse continue;
        if (key_val != .string or values_val != .array) continue;

        var vals: std.ArrayList([]const u8) = .{};
        errdefer {
            for (vals.items) |v| allocator.free(v);
            vals.deinit(allocator);
        }

        for (values_val.array.items) |v| {
            if (v == .string) {
                try vals.append(allocator, try allocator.dupe(u8, v.string));
            }
        }

        try out.append(allocator, .{
            .key = try allocator.dupe(u8, key_val.string),
            .values = try vals.toOwnedSlice(allocator),
        });
    }

    return .{
        .aliases = try out.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

// ---------------------------------------------------------------------------
// SearchResult — full set of fields from ast_nodes
// ---------------------------------------------------------------------------

pub const SearchResult = struct {
    file_path: []const u8,
    /// Relative path to the actual source file (meta.source from guidance JSON).
    source: []const u8,
    module: []const u8,
    node_type: []const u8,
    name: []const u8,
    signature: ?[]const u8,
    comment: ?[]const u8,
    line: ?u32,
    /// Parsed used_by paths — owned slice; each element is owned.
    used_by: [][]const u8,
    language: []const u8,
    score: f64,
};

pub fn freeSearchResult(allocator: std.mem.Allocator, r: SearchResult) void {
    allocator.free(r.file_path);
    allocator.free(r.source);
    allocator.free(r.module);
    allocator.free(r.node_type);
    allocator.free(r.name);
    if (r.signature) |s| allocator.free(s);
    if (r.comment) |cm| allocator.free(cm);
    for (r.used_by) |ub| allocator.free(ub);
    allocator.free(r.used_by);
    allocator.free(r.language);
}

// ---------------------------------------------------------------------------
// ExplainDb — read-only database handle
// ---------------------------------------------------------------------------

pub const ExplainDb = struct {
    db: ?*c.sqlite3,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Open an existing `.explain.db` at `db_path` for read-only access.
    /// Returns error.SqliteOpenFailed if the file does not exist or cannot be opened.
    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !Self {
        if (comptime !enabled) return error.SqliteNotEnabled;

        const db_path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(db_path_z);

        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(
            db_path_z.ptr,
            &db,
            c.SQLITE_OPEN_READONLY,
            null,
        );
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            log.debug("sqlite3_open_v2({s}) failed: rc={d}", .{ db_path, rc });
            return error.SqliteOpenFailed;
        }

        _ = c.sqlite3_busy_timeout(db, BUSY_TIMEOUT_MS);

        var self_ = Self{ .db = db, .allocator = allocator };
        self_.configurePragmas();
        return self_;
    }

    pub fn deinit(self: *Self) void {
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
            self.db = null;
        }
    }

    fn configurePragmas(self: *Self) void {
        const pragmas = [_][:0]const u8{
            "PRAGMA temp_store = MEMORY;",
            "PRAGMA cache_size = -2000;",
        };
        for (pragmas) |pragma| {
            var err_msg: [*c]u8 = null;
            _ = c.sqlite3_exec(self.db, pragma, null, null, &err_msg);
            if (err_msg) |msg| c.sqlite3_free(msg);
        }
    }

    // ── Search ─────────────────────────────────────────────────────

    /// BM25 full-text search.  Returns results ordered best-first.
    /// Caller must call `freeSearchResult` on each element and free the slice.
    pub fn search(
        self: *Self,
        allocator: std.mem.Allocator,
        query_text: []const u8,
        limit: usize,
    ) ![]SearchResult {
        return self.searchWithAliases(allocator, query_text, limit, null);
    }

    /// BM25 full-text search with optional semantic alias expansion.
    /// Caller must call `freeSearchResult` on each element and free the slice.
    pub fn searchWithAliases(
        self: *Self,
        allocator: std.mem.Allocator,
        query_text: []const u8,
        limit: usize,
        aliases: ?SemanticAliases,
    ) ![]SearchResult {
        const trimmed = std.mem.trim(u8, query_text, " \t\n\r");
        if (trimmed.len == 0) return allocator.alloc(SearchResult, 0);

        // Tokenize, strip trailing punctuation, filter stop words.
        var tokens: std.ArrayList([]const u8) = .{};
        defer {
            for (tokens.items) |t| allocator.free(t);
            tokens.deinit(allocator);
        }
        var it = std.mem.tokenizeAny(u8, trimmed, " \t\n\r");
        while (it.next()) |word| {
            var clean = word;
            while (clean.len > 0) {
                const last = clean[clean.len - 1];
                if (last == '?' or last == '.' or last == ',' or last == '!' or last == ':') {
                    clean = clean[0 .. clean.len - 1];
                } else break;
            }
            if (clean.len == 0) continue;
            if (isStopWord(clean)) continue;
            try tokens.append(allocator, try allocator.dupe(u8, clean));
        }

        // Expand tokens with semantic aliases if available.
        const expanded_tokens: []const []const u8 = if (aliases) |a| blk: {
            const exp = a.expandTokens(allocator, tokens.items) catch break :blk tokens.items;
            for (tokens.items) |t| allocator.free(t);
            tokens.clearAndFree(allocator);
            break :blk exp;
        } else tokens.items;

        // Build FTS5 quoted-OR query.
        var fts_buf: std.ArrayList(u8) = .{};
        defer fts_buf.deinit(allocator);
        var first = true;
        for (expanded_tokens) |tok| {
            if (!first) try fts_buf.appendSlice(allocator, " OR ");
            try fts_buf.append(allocator, '"');
            for (tok) |ch| {
                if (ch == '"') try fts_buf.appendSlice(allocator, "\"\"") else try fts_buf.append(allocator, ch);
            }
            try fts_buf.append(allocator, '"');
            first = false;
        }
        if (fts_buf.items.len == 0) {
            // All tokens were stop words — fall back to raw query.
            try fts_buf.appendSlice(allocator, trimmed);
        }
        try fts_buf.append(allocator, 0); // null-terminate

        const sql =
            "SELECT n.file_path, COALESCE(n.source, ''), n.module, n.node_type, n.name," ++
            "       n.signature, n.comment, n.line, n.used_by," ++
            "       COALESCE(n.language, 'zig')," ++
            "       bm25(fts_search) as score " ++
            "FROM fts_search f " ++
            "JOIN ast_nodes n ON n.id = f.rowid " ++
            "WHERE fts_search MATCH ?1 " ++
            "ORDER BY score " ++
            "LIMIT ?2";

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) {
            log.debug("prepare search failed: rc={d}", .{rc});
            return allocator.alloc(SearchResult, 0);
        }
        defer _ = c.sqlite3_finalize(stmt);

        const fts_query = fts_buf.items[0 .. fts_buf.items.len - 1];
        _ = c.sqlite3_bind_text(stmt, 1, fts_query.ptr, @intCast(fts_query.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(limit * 2)); // fetch extra for reranking

        var results: std.ArrayList(SearchResult) = .empty;
        errdefer {
            for (results.items) |r| freeSearchResult(allocator, r);
            results.deinit(allocator);
        }

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const result = try readRow(stmt.?, allocator);
            try results.append(allocator, result);
        }

        // Rerank by node type: boost definitions, penalise tests.
        rankByNodeType(results.items);

        // Free expanded tokens if allocated by alias expansion.
        if (aliases != null and expanded_tokens.ptr != tokens.items.ptr) {
            for (expanded_tokens) |t| allocator.free(t);
            allocator.free(@constCast(expanded_tokens));
        }

        // Trim to `limit`.
        const result_slice = try results.toOwnedSlice(allocator);
        if (result_slice.len <= limit) return result_slice;
        for (result_slice[limit..]) |r| freeSearchResult(allocator, r);
        @memset(result_slice[limit..], result_slice[0]);
        const final = allocator.realloc(result_slice, limit) catch result_slice[0..limit];
        return @constCast(final);
    }

    /// Adjust scores based on node_type: boost definitions, penalise tests.
    fn rankByNodeType(results: []SearchResult) void {
        for (results) |*r| {
            if (std.mem.eql(u8, r.node_type, "struct") or
                std.mem.eql(u8, r.node_type, "fn_decl") or
                std.mem.eql(u8, r.node_type, "enum") or
                std.mem.eql(u8, r.node_type, "const") or
                std.mem.eql(u8, r.node_type, "type"))
            {
                r.score *= 1.5;
            } else if (std.mem.eql(u8, r.node_type, "method") or
                std.mem.eql(u8, r.node_type, "method_private"))
            {
                r.score *= 1.2;
            } else if (std.mem.eql(u8, r.node_type, "test_decl")) {
                r.score *= 0.3;
            } else if (std.mem.eql(u8, r.node_type, "module")) {
                r.score *= 0.8;
            }
        }
        std.sort.block(SearchResult, results, {}, struct {
            fn lessThan(_: void, a: SearchResult, b: SearchResult) bool {
                return a.score > b.score;
            }
        }.lessThan);
    }
};

// ---------------------------------------------------------------------------
// Stop-word filter
// ---------------------------------------------------------------------------

/// Return true when `word` is a common English stop word that adds noise to
/// FTS5 queries.  Case-insensitive; only checks short words (≤ 6 chars).
fn isStopWord(word: []const u8) bool {
    if (word.len > 6) return false;
    var buf: [6]u8 = undefined;
    const lower = std.ascii.lowerString(buf[0..word.len], word);
    const stops = [_][]const u8{
        "a",    "an",   "and",  "are",  "as",   "at",   "be",   "by",
        "do",   "for",  "get",  "has",  "how",  "i",    "if",   "in",
        "is",   "it",   "its",  "no",   "not",  "of",   "on",   "or",
        "our",  "out",  "so",   "the",  "to",   "use",  "used", "was",
        "what", "when", "with", "do",   "from", "this", "that", "we",
        "can",  "did",  "does", "does", "you",  "will", "why",  "any",
    };
    for (stops) |s| if (std.mem.eql(u8, lower, s)) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Column helpers
// ---------------------------------------------------------------------------

fn readRow(stmt: *c.sqlite3_stmt, allocator: std.mem.Allocator) !SearchResult {
    // Columns: file_path(0), source(1), module(2), node_type(3), name(4),
    //          signature(5), comment(6), line(7), used_by(8), language(9), score(10)
    const line_val: ?u32 = blk: {
        if (c.sqlite3_column_type(stmt, 7) == c.SQLITE_NULL) break :blk null;
        const n = c.sqlite3_column_int64(stmt, 7);
        if (n <= 0) break :blk null;
        break :blk @intCast(n);
    };
    const used_by = try parseUsedByCol(stmt, 8, allocator);
    return SearchResult{
        .file_path = try dupeCol(stmt, 0, allocator),
        .source = try dupeCol(stmt, 1, allocator),
        .module = try dupeCol(stmt, 2, allocator),
        .node_type = try dupeCol(stmt, 3, allocator),
        .name = try dupeCol(stmt, 4, allocator),
        .signature = try dupeColNullable(stmt, 5, allocator),
        .comment = try dupeColNullable(stmt, 6, allocator),
        .line = line_val,
        .used_by = used_by,
        .language = try dupeCol(stmt, 9, allocator),
        .score = -c.sqlite3_column_double(stmt, 10), // BM25 returns negative → flip
    };
}

/// Parse a JSON-array column (e.g. `["a","b"]`) into an owned slice of owned strings.
/// Returns an empty slice when the column is NULL or not a JSON array.
fn parseUsedByCol(stmt: *c.sqlite3_stmt, col: c_int, allocator: std.mem.Allocator) ![][]const u8 {
    if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) return &.{};
    const raw = c.sqlite3_column_text(stmt, col);
    if (raw == null) return &.{};
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    const json_text = @as([*]const u8, @ptrCast(raw))[0..len];

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return &.{};
    defer parsed.deinit();

    if (parsed.value != .array) return &.{};
    const arr = parsed.value.array.items;
    var out: std.ArrayList([]const u8) = .{};
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }
    for (arr) |item| {
        if (item != .string) continue;
        try out.append(allocator, try allocator.dupe(u8, item.string));
    }
    return try out.toOwnedSlice(allocator);
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
    if (len == 0) return null;
    return try allocator.dupe(u8, @as([*]const u8, @ptrCast(raw))[0..len]);
}

// ---------------------------------------------------------------------------
// Database path resolution
// ---------------------------------------------------------------------------

pub const DbNotFound = error.DbNotFound;

/// Resolve the path to `.explain.db` using the priority order:
///   1. `NULLCLAW_EXPLAIN_DB` environment variable (full path)
///   2. `<workspace>/.explain.db`
///   3. `<workspace>/.ast-explain/ast-explain.db` (legacy)
///
/// Returns the first path that exists as a regular file.
/// Returns error.DbNotFound when none are present.
/// Caller owns the returned string.
pub fn resolveDatabasePath(allocator: std.mem.Allocator, workspace_dir: []const u8) ![]u8 {
    // 1. Environment variable override.
    if (std.process.getEnvVarOwned(allocator, "NULLCLAW_EXPLAIN_DB")) |env_path| {
        return env_path;
    } else |_| {}

    // 2. Project-local .explain.db
    const local_path = try std.fmt.allocPrint(allocator, "{s}/.explain.db", .{workspace_dir});
    if (fileExists(local_path)) return local_path;
    allocator.free(local_path);

    // 3. Legacy path from prior implementation.
    const legacy_path = try std.fmt.allocPrint(
        allocator,
        "{s}/.ast-explain/ast-explain.db",
        .{workspace_dir},
    );
    if (fileExists(legacy_path)) return legacy_path;
    allocator.free(legacy_path);

    return error.DbNotFound;
}

/// Check whether a path points to a readable regular file.
fn fileExists(path: []const u8) bool {
    const f = std.fs.openFileAbsolute(path, .{}) catch return false;
    f.close();
    return true;
}

/// Build a human-readable error message listing the expected database locations.
/// Caller owns the returned string.
pub fn missingDbMessage(allocator: std.mem.Allocator, workspace_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        \\No .explain.db found. Run explain-gen to index your codebase.
        \\Expected locations:
        \\  - $NULLCLAW_EXPLAIN_DB  (env var, if set)
        \\  - {s}/.explain.db
        \\  - {s}/.ast-explain/ast-explain.db
    ,
        .{ workspace_dir, workspace_dir },
    );
}

// ---------------------------------------------------------------------------
// JSON parsing helpers (used by external indexing tools, kept here for tests)
// ---------------------------------------------------------------------------

pub const ParsedMember = struct {
    node_type: []const u8,
    name: []const u8,
    signature: ?[]const u8,
    comment: ?[]const u8,
    line: ?u32,
};

pub const ParsedDoc = struct {
    module: []const u8,
    module_comment: ?[]const u8,
    source: []const u8,
    used_by: []const []const u8,
    members: []ParsedMember,
};

/// Parse a guidance JSON file into a `ParsedDoc`.
/// All strings are owned by the arena; call `arena.deinit()` to free.
pub fn parseGuidanceJson(arena: std.mem.Allocator, json_data: []const u8) !ParsedDoc {
    const Value = std.json.Value;
    const parsed = try std.json.parseFromSlice(Value, arena, json_data, .{
        .ignore_unknown_fields = true,
    });

    const root_val = parsed.value;
    if (root_val != .object) return error.InvalidJson;

    // ── meta ────────────────────────────────────────────────────────────────
    const meta_val = root_val.object.get("meta") orelse return error.MissingMeta;
    if (meta_val != .object) return error.MissingMeta;
    const module_val = meta_val.object.get("module") orelse return error.MissingModule;
    if (module_val != .string) return error.MissingModule;
    const module = module_val.string;

    const source: []const u8 = blk: {
        const sv = meta_val.object.get("source") orelse break :blk "";
        if (sv != .string) break :blk "";
        break :blk sv.string;
    };

    // ── module comment ───────────────────────────────────────────────────────
    const comment: ?[]const u8 = blk: {
        const cv = root_val.object.get("comment") orelse break :blk null;
        if (cv != .string or cv.string.len == 0) break :blk null;
        break :blk cv.string;
    };

    // ── used_by ──────────────────────────────────────────────────────────────
    var used_by_list: std.ArrayList([]const u8) = .empty;
    if (root_val.object.get("used_by")) |ubv| {
        if (ubv == .array) {
            for (ubv.array.items) |item| {
                if (item == .string and item.string.len > 0) {
                    try used_by_list.append(arena, item.string);
                }
            }
        }
    }

    // ── members ──────────────────────────────────────────────────────────────
    var members_list: std.ArrayList(ParsedMember) = .empty;

    const members_val = root_val.object.get("members") orelse {
        return .{
            .module = module,
            .module_comment = comment,
            .source = source,
            .used_by = try used_by_list.toOwnedSlice(arena),
            .members = &.{},
        };
    };
    if (members_val != .array) {
        return .{
            .module = module,
            .module_comment = comment,
            .source = source,
            .used_by = try used_by_list.toOwnedSlice(arena),
            .members = &.{},
        };
    }

    for (members_val.array.items) |item| {
        if (item != .object) continue;
        const m = parseMemberValue(item);
        try members_list.append(arena, m);
        // Recurse one level into nested members (struct methods).
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
        .source = source,
        .used_by = try used_by_list.toOwnedSlice(arena),
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
        if (sv != .string or sv.string.len == 0) break :blk null;
        break :blk sv.string;
    };
    const comment: ?[]const u8 = blk: {
        const cv = item.object.get("comment") orelse break :blk null;
        if (cv != .string or cv.string.len < 4) break :blk null;
        break :blk cv.string;
    };
    const line: ?u32 = blk: {
        const lv = item.object.get("line") orelse break :blk null;
        break :blk switch (lv) {
            .integer => |n| if (n > 0) @as(u32, @intCast(n)) else null,
            .float => |f| if (f > 0) @as(u32, @intFromFloat(f)) else null,
            else => null,
        };
    };
    return .{
        .node_type = node_type,
        .name = name,
        .signature = signature,
        .comment = comment,
        .line = line,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseGuidanceJson extracts module, used_by, members with line" {
    const json =
        \\{
        \\  "meta": { "module": "src.foo.bar", "source": "src/foo/bar.zig", "language": "zig" },
        \\  "comment": "Does something useful.",
        \\  "used_by": ["src/main.zig", "src/agent.zig"],
        \\  "members": [
        \\    { "type": "fn_decl", "name": "doThing", "signature": "fn doThing() void",
        \\      "comment": "Does the thing.", "line": 42 },
        \\    { "type": "struct",  "name": "MyState", "line": 88 }
        \\  ]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const doc = try parseGuidanceJson(arena.allocator(), json);
    try std.testing.expectEqualStrings("src.foo.bar", doc.module);
    try std.testing.expectEqualStrings("src/foo/bar.zig", doc.source);
    try std.testing.expectEqualStrings("Does something useful.", doc.module_comment.?);
    try std.testing.expectEqual(@as(usize, 2), doc.used_by.len);
    try std.testing.expectEqualStrings("src/main.zig", doc.used_by[0]);
    try std.testing.expectEqual(@as(usize, 2), doc.members.len);
    try std.testing.expectEqualStrings("doThing", doc.members[0].name);
    try std.testing.expectEqualStrings("Does the thing.", doc.members[0].comment.?);
    try std.testing.expectEqual(@as(?u32, 42), doc.members[0].line);
    try std.testing.expectEqual(@as(?u32, 88), doc.members[1].line);
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

test "parseGuidanceJson handles empty used_by" {
    const json =
        \\{
        \\  "meta": { "module": "src.foo", "source": "src/foo.zig", "language": "zig" },
        \\  "members": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parseGuidanceJson(arena.allocator(), json);
    try std.testing.expectEqual(@as(usize, 0), doc.used_by.len);
    try std.testing.expectEqual(@as(usize, 0), doc.members.len);
    try std.testing.expect(doc.module_comment == null);
}

test "missingDbMessage includes workspace path" {
    const msg = try missingDbMessage(std.testing.allocator, "/my/workspace");
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "/my/workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "NULLCLAW_EXPLAIN_DB") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, ".explain.db") != null);
}

test "ExplainDb search on pre-built database" {
    if (comptime !enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const db_path = try std.fmt.allocPrint(allocator, "{s}/test.explain.db", .{tmp_path});
    defer allocator.free(db_path);

    // Build schema with a write-mode connection.
    {
        const db_path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(db_path_z);
        var db: ?*c.sqlite3 = null;
        _ = c.sqlite3_open(db_path_z.ptr, &db);
        defer _ = c.sqlite3_close(db);

        const schema =
            \\CREATE TABLE ast_nodes (
            \\  id            INTEGER PRIMARY KEY,
            \\  file_path     TEXT    NOT NULL,
            \\  source        TEXT,
            \\  module        TEXT    NOT NULL,
            \\  node_type     TEXT    NOT NULL,
            \\  name          TEXT    NOT NULL,
            \\  signature     TEXT,
            \\  comment       TEXT,
            \\  line          INTEGER,
            \\  used_by       TEXT,
            \\  language      TEXT    NOT NULL DEFAULT 'zig',
            \\  last_modified INTEGER NOT NULL
            \\);
            \\CREATE VIRTUAL TABLE fts_search USING fts5(
            \\  name, comment, module, signature,
            \\  content='ast_nodes',
            \\  content_rowid='id'
            \\);
            \\INSERT INTO ast_nodes(file_path,source,module,node_type,name,signature,comment,line,used_by,language,last_modified)
            \\  VALUES('src/parser.zig.json','src/parser.zig','src.parser','fn_decl','frobnicate',
            \\         'fn frobnicate(input: []const u8) !void',
            \\         'Frobnicates the widget.',42,'["src/main.zig"]','zig',0);
            \\INSERT INTO fts_search(rowid,name,comment,module,signature)
            \\  VALUES(1,'frobnicate','Frobnicates the widget.','src.parser','fn frobnicate(input: []const u8) !void');
        ;
        var err_msg: [*c]u8 = null;
        _ = c.sqlite3_exec(db, schema, null, null, &err_msg);
        if (err_msg) |msg| c.sqlite3_free(msg);
    }

    var db = try ExplainDb.init(allocator, db_path);
    defer db.deinit();

    const results = try db.search(allocator, "frobnicate", 10);
    defer {
        for (results) |r| freeSearchResult(allocator, r);
        allocator.free(results);
    }

    try std.testing.expect(results.len >= 1);
    try std.testing.expectEqualStrings("frobnicate", results[0].name);
    try std.testing.expectEqualStrings("src.parser", results[0].module);
    try std.testing.expectEqualStrings("fn_decl", results[0].node_type);
    try std.testing.expectEqualStrings("src/parser.zig", results[0].source);
    try std.testing.expectEqualStrings("zig", results[0].language);
    try std.testing.expect(results[0].signature != null);
    try std.testing.expect(results[0].comment != null);
    try std.testing.expectEqual(@as(?u32, 42), results[0].line);
    try std.testing.expectEqual(@as(usize, 1), results[0].used_by.len);
    try std.testing.expectEqualStrings("src/main.zig", results[0].used_by[0]);
}

test "ExplainDb search empty query returns empty" {
    if (comptime !enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const db_path = try std.fmt.allocPrint(allocator, "{s}/empty.explain.db", .{tmp_path});
    defer allocator.free(db_path);
    {
        const db_path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(db_path_z);
        var db: ?*c.sqlite3 = null;
        _ = c.sqlite3_open(db_path_z.ptr, &db);
        defer _ = c.sqlite3_close(db);
        var err_msg: [*c]u8 = null;
        _ = c.sqlite3_exec(db,
            \\CREATE TABLE ast_nodes(id INTEGER PRIMARY KEY,file_path TEXT NOT NULL,
            \\  source TEXT,module TEXT NOT NULL,node_type TEXT NOT NULL,name TEXT NOT NULL,
            \\  signature TEXT,comment TEXT,line INTEGER,used_by TEXT,
            \\  language TEXT NOT NULL DEFAULT 'zig',last_modified INTEGER NOT NULL);
            \\CREATE VIRTUAL TABLE fts_search USING fts5(name,comment,module,signature,
            \\  content='ast_nodes',content_rowid='id');
        , null, null, &err_msg);
        if (err_msg) |msg| c.sqlite3_free(msg);
    }

    var db = try ExplainDb.init(allocator, db_path);
    defer db.deinit();

    const results = try db.search(allocator, "   ", 10);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "isStopWord filters common words" {
    try std.testing.expect(isStopWord("the"));
    try std.testing.expect(isStopWord("is"));
    try std.testing.expect(isStopWord("how"));
    try std.testing.expect(!isStopWord("frobnicate"));
    try std.testing.expect(!isStopWord("search"));
}

test "SemanticAliases expandTokens deduplicates" {
    const allocator = std.testing.allocator;
    var aliases = SemanticAliases{
        .allocator = allocator,
        .aliases = &.{},
    };
    defer aliases.deinit();

    const tokens = [_][]const u8{ "foo", "bar" };
    const expanded = try aliases.expandTokens(allocator, &tokens);
    defer {
        for (expanded) |t| allocator.free(t);
        allocator.free(expanded);
    }
    try std.testing.expectEqual(@as(usize, 2), expanded.len);
}
