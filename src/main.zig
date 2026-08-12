const std = @import("std");
const search = @import("search.zig");
const walk = @import("walk.zig");

const version = "0.3";

const usage =
    \\huntclaw - fast find-and-replace
    \\
    \\Usage:
    \\  huntclaw <pattern> <replacement> [path...] [options]
    \\  huntclaw -p <pattern> [path...]            (search only, no replace)
    \\
    \\Options:
    \\  -p, --pattern-only    only find matches, do not replace
    \\  -i, --ignore-case     case-insensitive match
    \\  -n, --dry-run         show what would change without writing
    \\  -e, --ext <ext>       only process files with this extension (repeatable)
    \\  -q, --quiet           suppress per-file output
    \\  -n-s-l, --no-skip-list  do not skip .git, node_modules, and other default dirs
    \\  -v, --version         print version and exit
    \\  -h, --help            show this help
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_w.interface;
    var stderr_buf: [4096]u8 = undefined;
    var stderr_w = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_w.interface;
    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    var arg_it = try init.minimal.args.iterateAllocator(gpa);
    defer arg_it.deinit();
    var args = std.ArrayList([:0]const u8).empty;
    defer args.deinit(gpa);
    while (arg_it.next()) |a| try args.append(gpa, a);

    var opts = search.Options{};
    var pattern: ?[]const u8 = null;
    var replacement: ?[]const u8 = null;
    var paths = std.ArrayList([]const u8).empty;
    defer paths.deinit(gpa);
    var exts = std.ArrayList([]const u8).empty;
    defer exts.deinit(gpa);

    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const a = args.items[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try stdout.writeAll(usage);
            return 0;
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--version")) {
            try stdout.print("huntclaw {s}\n", .{version});
            return 0;
        } else if (std.mem.eql(u8, a, "-p") or std.mem.eql(u8, a, "--pattern-only")) {
            opts.pattern_only = true;
        } else if (std.mem.eql(u8, a, "-i") or std.mem.eql(u8, a, "--ignore-case")) {
            opts.ignore_case = true;
        } else if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, a, "-q") or std.mem.eql(u8, a, "--quiet")) {
            opts.quiet = true;
        } else if (std.mem.eql(u8, a, "-n-s-l") or std.mem.eql(u8, a, "--no-skip-list")) {
            opts.no_skip_list = true;
        } else if (std.mem.eql(u8, a, "-e") or std.mem.eql(u8, a, "--ext")) {
            i += 1;
            if (i >= args.items.len) return fail(stderr, "missing value for -e/--ext");
            try exts.append(gpa, args.items[i]);
        } else if (std.mem.startsWith(u8, a, "-") and a.len > 1) {
            return fail(stderr, "unknown option");
        } else if (pattern == null) {
            pattern = a;
        } else if (replacement == null and !opts.pattern_only) {
            replacement = a;
        } else {
            try paths.append(gpa, a);
        }
    }

    if (pattern == null) {
        try stderr.writeAll(usage);
        return 1;
    }
    if (!opts.pattern_only and replacement == null) {
        return fail(stderr, "missing replacement argument (use -p for search-only mode)");
    }

    if (paths.items.len == 0) try paths.append(gpa, ".");
    opts.exts = exts.items;

    var stats = search.Stats{};
    for (paths.items) |p| {
        try walk.process(gpa, io, p, pattern.?, replacement orelse "", &opts, &stats, stdout, stderr);
    }

    const m = stats.matches.load(.monotonic);
    const fm = stats.files_matched.load(.monotonic);
    const fs = stats.files_scanned.load(.monotonic);
    if (opts.pattern_only) {
        try stdout.print("{d} matches in {d} files ({d} scanned)\n", .{ m, fm, fs });
    } else if (opts.dry_run) {
        try stdout.print("{d} matches in {d} files would be replaced ({d} scanned)\n", .{ m, fm, fs });
    } else {
        try stdout.print("{d} matches replaced in {d} files ({d} scanned)\n", .{ m, fm, fs });
    }

    return 0;
}

fn fail(stderr: *std.Io.Writer, msg: []const u8) u8 {
    stderr.print("huntclaw: {s}\n", .{msg}) catch {};
    stderr.flush() catch {};
    return 1;
}
