const std = @import("std");

pub const Options = struct {
    pattern_only: bool = false,
    ignore_case: bool = false,
    dry_run: bool = false,
    quiet: bool = false,
    no_skip_list: bool = false,
    show_lines: bool = false,
    stats_json: bool = false,
    max_depth: ?usize = null,
    exts: []const []const u8 = &.{},
};

pub const Stats = struct {
    matches: std.atomic.Value(usize) = .init(0),
    files_matched: std.atomic.Value(usize) = .init(0),
    files_scanned: std.atomic.Value(usize) = .init(0),

    pub fn addMatches(self: *Stats, n: usize) void {
        _ = self.matches.fetchAdd(n, .monotonic);
    }
    pub fn incFilesMatched(self: *Stats) void {
        _ = self.files_matched.fetchAdd(1, .monotonic);
    }
    pub fn incFilesScanned(self: *Stats) void {
        _ = self.files_scanned.fetchAdd(1, .monotonic);
    }
};

inline fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn eqCase(a: u8, b: u8, ci: bool) bool {
    return if (ci) lower(a) == lower(b) else a == b;
}

const lane_count = std.simd.suggestVectorLength(u8) orelse 16;
const Lane = @Vector(lane_count, u8);
const Mask = std.meta.Int(.unsigned, lane_count);

// two-byte SIMD prefilter (first+last of pattern) narrows candidates before
// the scalar BMH verification runs, cutting false positives on sparse data.
// Walks every set bit within a vector before advancing to the next block,
// so a run of false positives inside one lane doesn't restart the scan.
fn scanLanes(haystack: []const u8, pos: usize, first: u8, last: u8, offset: usize, m: *const Matcher) ?usize {
    const first_v: Lane = @splat(first);
    const last_v: Lane = @splat(last);
    var i = pos;
    while (i + offset + lane_count <= haystack.len) : (i += lane_count) {
        const a: Lane = haystack[i..][0..lane_count].*;
        const b: Lane = haystack[i + offset ..][0..lane_count].*;
        const hit = (a == first_v) & (b == last_v);
        var mask: Mask = @bitCast(hit);
        while (mask != 0) {
            const bit = @ctz(mask);
            const cand = i + bit;
            if (m.verify(haystack, cand)) return cand;
            mask &= mask - 1;
        }
    }
    return null;
}

// Boyer-Moore-Horspool with a 256-entry skip table, SIMD-prefiltered scan.
pub const Matcher = struct {
    pattern: []const u8,
    skip: [256]usize,
    ignore_case: bool,
    first_lower: u8,
    last_lower: u8,

    pub fn init(pattern: []const u8, ignore_case: bool) Matcher {
        var m = Matcher{
            .pattern = pattern,
            .skip = undefined,
            .ignore_case = ignore_case,
            .first_lower = if (pattern.len > 0) (if (ignore_case) lower(pattern[0]) else pattern[0]) else 0,
            .last_lower = if (pattern.len > 0) (if (ignore_case) lower(pattern[pattern.len - 1]) else pattern[pattern.len - 1]) else 0,
        };
        const n = pattern.len;
        for (&m.skip) |*s| s.* = n;
        if (n > 0) {
            var i: usize = 0;
            while (i < n - 1) : (i += 1) {
                const c = if (ignore_case) lower(pattern[i]) else pattern[i];
                m.skip[c] = n - 1 - i;
            }
        }
        return m;
    }

    fn verify(self: *const Matcher, haystack: []const u8, pos: usize) bool {
        var j: usize = 1;
        while (j + 1 < self.pattern.len) : (j += 1) {
            if (!eqCase(haystack[pos + j], self.pattern[j], self.ignore_case)) return false;
        }
        return true;
    }

    // case-sensitive single-byte pattern and case-insensitive paths fall back
    // to scalar BMH; the case-sensitive multi-byte path gets the SIMD prefilter.
    pub fn find(self: *const Matcher, haystack: []const u8, from: usize) ?usize {
        const n = self.pattern.len;
        if (n == 0 or n > haystack.len) return null;
        if (self.ignore_case or n < 2) return self.findScalar(haystack, from);

        const offset = n - 1;
        const simd_limit = if (haystack.len >= offset + lane_count) haystack.len - offset - lane_count + 1 else from;
        if (from < simd_limit) {
            if (scanLanes(haystack, from, self.first_lower, self.last_lower, offset, self)) |cand| return cand;
        }
        return self.findScalar(haystack, @max(simd_limit, from));
    }

    fn findScalar(self: *const Matcher, haystack: []const u8, from: usize) ?usize {
        const n = self.pattern.len;
        var pos = from;
        const last = n - 1;
        const last_c = self.last_lower;
        while (pos + n <= haystack.len) {
            const hc = if (self.ignore_case) lower(haystack[pos + last]) else haystack[pos + last];
            if (hc == last_c) {
                var j: usize = 0;
                var ok = true;
                while (j < n) : (j += 1) {
                    if (!eqCase(haystack[pos + j], self.pattern[j], self.ignore_case)) {
                        ok = false;
                        break;
                    }
                }
                if (ok) return pos;
            }
            pos += self.skip[hc];
        }
        return null;
    }

    pub fn count(self: *const Matcher, haystack: []const u8) usize {
        var n: usize = 0;
        var pos: usize = 0;
        while (self.find(haystack, pos)) |idx| {
            n += 1;
            pos = idx + self.pattern.len;
        }
        return n;
    }
};

pub const Result = struct {
    output: []u8,
    matches: usize,
};

// builds replaced output into caller-owned buffer, allocator picked by caller
pub fn replaceAll(allocator: std.mem.Allocator, haystack: []const u8, matcher: *const Matcher, replacement: []const u8) !Result {
    const pat_len = matcher.pattern.len;
    if (pat_len == 0) return .{ .output = try allocator.dupe(u8, haystack), .matches = 0 };

    const first = matcher.find(haystack, 0) orelse return .{ .output = try allocator.dupe(u8, haystack), .matches = 0 };

    // single pass: grow into a spare-capacity buffer, geometric doubling on overflow.
    // when the replacement is no longer than the pattern, the output can only
    // shrink or stay the same size no matter how many matches there are, so
    // sizing the buffer for one match is always enough — no realloc, ever.
    // when the replacement is longer, the output can grow without bound as
    // matches pile up, and a realloc big enough to hold the whole file is far
    // more expensive than the padding it was meant to avoid, so that case
    // keeps the original generous headroom instead of gambling on a guess.
    const one_match_size = haystack.len - pat_len + replacement.len;
    const initial_size = if (replacement.len <= pat_len)
        one_match_size + 64
    else
        haystack.len + (haystack.len >> 2) + replacement.len + 64;
    var out = try allocator.alloc(u8, initial_size);
    errdefer allocator.free(out);

    var src: usize = 0;
    var dst: usize = 0;
    var found: usize = 0;
    var next: ?usize = first;
    while (next) |idx| {
        const chunk = haystack[src..idx];
        const needed = dst + chunk.len + replacement.len;
        if (needed > out.len) {
            const new_cap = @max(needed, out.len + (out.len >> 1) + 64);
            out = try allocator.realloc(out, new_cap);
        }
        @memcpy(out[dst .. dst + chunk.len], chunk);
        dst += chunk.len;
        @memcpy(out[dst .. dst + replacement.len], replacement);
        dst += replacement.len;
        src = idx + pat_len;
        found += 1;
        next = matcher.find(haystack, src);
    }
    const tail = haystack[src..];
    if (dst + tail.len > out.len) out = try allocator.realloc(out, dst + tail.len);
    @memcpy(out[dst .. dst + tail.len], tail);
    dst += tail.len;

    return .{ .output = out[0..dst], .matches = found };
}
