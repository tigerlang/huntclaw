const std = @import("std");
const search = @import("search.zig");
const Io = std.Io;
const Dir = std.Io.Dir;

const skip_dirs = [_][]const u8{ ".git", "node_modules", ".zig-cache", "zig-out", "target", ".svn", ".hg" };

fn shouldSkipDir(name: []const u8) bool {
    for (skip_dirs) |d| {
        if (std.mem.eql(u8, name, d)) return true;
    }
    return false;
}

fn extMatches(path: []const u8, exts: []const []const u8) bool {
    if (exts.len == 0) return true;
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    const ext = path[dot + 1 ..];
    for (exts) |e| {
        const want = if (e.len > 0 and e[0] == '.') e[1..] else e;
        if (std.mem.eql(u8, ext, want)) return true;
    }
    return false;
}

fn looksBinary(data: []const u8) bool {
    const n = @min(data.len, 8192);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (data[i] == 0) return true;
    }
    return false;
}

const max_file_size = 256 * 1024 * 1024;

pub fn process(
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    pattern: []const u8,
    replacement: []const u8,
    opts: *const search.Options,
    stats: *search.Stats,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    const cwd = Dir.cwd();
    const stat = cwd.statFile(io, path, .{}) catch |err| {
        try stderr.print("huntclaw: cannot access {s}: {t}\n", .{ path, err });
        return;
    };

    if (stat.kind == .directory) {
        try walkDir(gpa, io, path, pattern, replacement, opts, stats, stdout, stderr);
        return;
    }
    try processFile(gpa, io, path, pattern, replacement, opts, stats, stdout);
}

fn walkDir(
    gpa: std.mem.Allocator,
    io: Io,
    dir_path: []const u8,
    pattern: []const u8,
    replacement: []const u8,
    opts: *const search.Options,
    stats: *search.Stats,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    var dir = Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        try stderr.print("huntclaw: cannot open {s}: {t}\n", .{ dir_path, err });
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (shouldSkipDir(entry.name)) continue;
            const sub = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
            defer gpa.free(sub);
            try walkDir(gpa, io, sub, pattern, replacement, opts, stats, stdout, stderr);
        } else if (entry.kind == .file) {
            if (!extMatches(entry.name, opts.exts)) continue;
            const full = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
            defer gpa.free(full);
            try processFile(gpa, io, full, pattern, replacement, opts, stats, stdout);
        }
    }
}

fn processFile(
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    pattern: []const u8,
    replacement: []const u8,
    opts: *const search.Options,
    stats: *search.Stats,
    stdout: *Io.Writer,
) !void {
    const data = Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_size)) catch |err| {
        if (err == error.IsDir) return;
        try stdout.print("huntclaw: cannot read {s}: {t}\n", .{ path, err });
        return;
    };
    defer gpa.free(data);
    if (data.len == 0) return;

    stats.files_scanned += 1;
    if (looksBinary(data)) return;

    var matcher = search.Matcher.init(pattern, opts.ignore_case);

    if (opts.pattern_only) {
        const n = matcher.count(data);
        if (n > 0) {
            stats.matches += n;
            stats.files_matched += 1;
            if (!opts.quiet) try stdout.print("{s}: {d}\n", .{ path, n });
        }
        return;
    }

    const result = try search.replaceAll(gpa, data, &matcher, replacement);
    defer gpa.free(result.output);
    if (result.matches == 0) return;

    stats.matches += result.matches;
    stats.files_matched += 1;
    if (!opts.quiet) try stdout.print("{s}: {d} replaced\n", .{ path, result.matches });

    if (opts.dry_run) return;

    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = result.output });
}
