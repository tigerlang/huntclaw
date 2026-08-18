const std = @import("std");

pub const Rc = struct {
    skip_dirs: std.ArrayList([]const u8) = .empty,
    flags: std.ArrayList([]const u8) = .empty,
    excludes: std.ArrayList([]const u8) = .empty,
    buf: []u8,

    pub fn deinit(self: *Rc, gpa: std.mem.Allocator) void {
        self.skip_dirs.deinit(gpa);
        self.flags.deinit(gpa);
        self.excludes.deinit(gpa);
        gpa.free(self.buf);
    }
};

pub fn load(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !?Rc {
    const data = dir.readFileAlloc(io, ".huntclaw-rc", gpa, .limited(1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };

    var rc = Rc{ .buf = data };
    var in_excludes = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.eql(u8, line, "[excludes]")) {
            in_excludes = true;
            continue;
        }
        if (in_excludes) {
            try rc.excludes.append(gpa, line);
            continue;
        }
        if (std.mem.startsWith(u8, line, "skip:")) {
            try rc.skip_dirs.append(gpa, std.mem.trim(u8, line[5..], " \t"));
        } else if (std.mem.startsWith(u8, line, "flag:")) {
            var it = std.mem.tokenizeScalar(u8, line[5..], ' ');
            while (it.next()) |tok| try rc.flags.append(gpa, tok);
        }
    }
    return rc;
}

// gitignore-style: * matches within a segment, ** matches across segments,
// trailing / anchors to directory names, leading / anchors to path start
pub fn matches(pattern: []const u8, path: []const u8) bool {
    var pat = pattern;
    var dir_only = false;
    if (std.mem.endsWith(u8, pat, "/")) {
        dir_only = true;
        pat = pat[0 .. pat.len - 1];
    }
    const anchored = std.mem.startsWith(u8, pat, "/");
    if (anchored) pat = pat[1..];

    if (anchored) return globMatch(pat, path) or (dir_only and dirPrefix(pat, path));

    var it = std.mem.splitScalar(u8, path, '/');
    var offset: usize = 0;
    while (it.next()) |_| {
        const sub = path[offset..];
        if (globMatch(pat, sub) or (dir_only and dirPrefix(pat, sub))) return true;
        offset += (it.index orelse path.len) - offset;
        if (it.index == null) break;
    }
    return false;
}

fn dirPrefix(pat: []const u8, path: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return false;
    return globMatch(pat, path[0..slash]);
}

fn globMatch(pat: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, pat, name)) return true;
    if (std.mem.indexOf(u8, pat, "**") != null) return globStar(pat, name);
    return segmentGlob(pat, name);
}

fn globStar(pat: []const u8, name: []const u8) bool {
    const idx = std.mem.indexOf(u8, pat, "**") orelse return segmentGlob(pat, name);
    const prefix = pat[0..idx];
    const suffix = pat[idx + 2 ..];
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    const rest = name[prefix.len..];
    if (suffix.len == 0) return true;
    const trimmed_suffix = if (suffix.len > 0 and suffix[0] == '/') suffix[1..] else suffix;
    var i: usize = 0;
    while (i <= rest.len) : (i += 1) {
        if (segmentGlob(trimmed_suffix, rest[i..])) return true;
    }
    return false;
}

fn segmentGlob(pat: []const u8, name: []const u8) bool {
    if (pat.len == 0) return name.len == 0;
    if (pat[0] == '*') return segmentGlob(pat[1..], name) or (name.len > 0 and segmentGlob(pat, name[1..]));
    if (pat[0] == '?') return name.len > 0 and segmentGlob(pat[1..], name[1..]);
    if (name.len == 0) return false;
    if (pat[0] != name[0]) return false;
    return segmentGlob(pat[1..], name[1..]);
}

pub fn anyMatch(patterns: []const []const u8, path: []const u8) bool {
    for (patterns) |p| {
        if (matches(p, path)) return true;
    }
    return false;
}
