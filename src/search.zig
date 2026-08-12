const std = @import("std");

pub const Options = struct {
    pattern_only: bool = false,
    ignore_case: bool = false,
    dry_run: bool = false,
    quiet: bool = false,
    exts: []const []const u8 = &.{},
};

pub const Stats = struct {
    matches: usize = 0,
    files_matched: usize = 0,
    files_scanned: usize = 0,
};

inline fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn eqCase(a: u8, b: u8, ci: bool) bool {
    return if (ci) lower(a) == lower(b) else a == b;
}

// Boyer-Moore-Horspool with a 256-entry skip table, unrolled last-byte check.
pub const Matcher = struct {
    pattern: []const u8,
    skip: [256]usize,
    ignore_case: bool,

    pub fn init(pattern: []const u8, ignore_case: bool) Matcher {
        var m = Matcher{ .pattern = pattern, .skip = undefined, .ignore_case = ignore_case };
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

    // returns index of next match at or after `from`, or null
    pub fn find(self: *const Matcher, haystack: []const u8, from: usize) ?usize {
        const n = self.pattern.len;
        if (n == 0 or n > haystack.len) return null;
        var pos = from;
        const last = n - 1;
        const last_c = if (self.ignore_case) lower(self.pattern[last]) else self.pattern[last];
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

    // single pass: grow into a spare-capacity buffer, geometric doubling on overflow
    var out = try allocator.alloc(u8, haystack.len + (haystack.len >> 2) + replacement.len + 64);
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
