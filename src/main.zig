const std = @import("std");
const search = @import("search.zig");
const walk = @import("walk.zig");
const rcfile = @import("rcfile.zig");

const version = "0.8";

const usage =
    \\huntclaw - fast find-and-replace
    \\
    \\Usage:
    \\  huntclaw <pattern> <replacement> [path...] [options]
    \\  huntclaw -p <pattern> [path...]            (search only, no replace)
    \\  huntclaw init                              (create a .huntclaw-rc template)
    \\
    \\Options:
    \\  -p, --pattern-only    only find matches, do not replace
    \\  -i, --ignore-case     case-insensitive match
    \\  -n, --dry-run         show what would change without writing
    \\  -e, --ext <ext>       only process files with this extension (repeatable)
    \\  -q, --quiet           suppress per-file output
    \\  -b, --backup          write a .bak copy of each file before replacing
    \\  -n-s-l, --no-skip-list  do not skip .git, node_modules, and other default dirs
    \\  -l, --line            show line number and matching line text (search mode)
    \\  --max-depth <N>       limit directory recursion depth (0 = given dirs only)
    \\  --stats-only          print only a JSON summary, no per-file output
    \\  -ex, --exclude <glob> exclude files/dirs matching this glob (repeatable)
    \\  -v, --version         print version and exit
    \\  -h, --help            show this help
    \\  --                    treat everything after this as pattern/replacement/paths
    \\
    \\Reads .huntclaw-rc from the current directory if present.
    \\See docs/huntclaw-rc.txt for its format.
    \\
    \\Exit codes:
    \\  0   at least one match found (or replaced), no errors
    \\  1   ran fine, but found zero matches
    \\  2   invalid arguments, or one or more files/dirs could not be processed
    \\
;

fn initRc(io: std.Io, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const template =
        \\# skip: adds a directory name to the default skip list
        \\# skip: fixtures
        \\
        \\# flag: injects a CLI flag on every run, same syntax as the command line
        \\# flag: -i
        \\
        \\[excludes]
        \\# gitignore-style patterns below this line, one per line
        \\# *.min.js
        \\# vendor/
        \\
    ;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ".huntclaw-rc", .data = template, .flags = .{ .exclusive = true } }) catch |err| {
        if (err == error.PathAlreadyExists) {
            try stderr.print("huntclaw: .huntclaw-rc already exists\n", .{});
            return 1;
        }
        return err;
    };
    try stdout.print("created .huntclaw-rc\n", .{});
    return 0;
}

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
    var raw_args = std.ArrayList([:0]const u8).empty;
    defer raw_args.deinit(gpa);
    while (arg_it.next()) |a| try raw_args.append(gpa, a);

    if (raw_args.items.len > 1 and std.mem.eql(u8, raw_args.items[1], "init")) {
        return initRc(io, stdout, stderr);
    }

    var rc = rcfile.load(gpa, io, std.Io.Dir.cwd()) catch null;
    defer if (rc) |*r| r.deinit(gpa);

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(gpa);
    try args.append(gpa, raw_args.items[0]);
    if (rc) |r| for (r.flags.items) |f| try args.append(gpa, f);
    for (raw_args.items[1..]) |a| try args.append(gpa, a);

    var opts = search.Options{};
    var pattern: ?[]const u8 = null;
    var replacement: ?[]const u8 = null;
    var paths = std.ArrayList([]const u8).empty;
    defer paths.deinit(gpa);
    var exts = std.ArrayList([]const u8).empty;
    defer exts.deinit(gpa);
    var excludes = std.ArrayList([]const u8).empty;
    defer excludes.deinit(gpa);
    if (rc) |r| {
        opts.extra_skip_dirs = r.skip_dirs.items;
        try excludes.appendSlice(gpa, r.excludes.items);
    }

    var i: usize = 1;
    var positional_only = false;
    while (i < args.items.len) : (i += 1) {
        const a = args.items[i];
        if (positional_only) {
            if (pattern == null) {
                pattern = a;
            } else if (replacement == null and !opts.pattern_only) {
                replacement = a;
            } else {
                try paths.append(gpa, a);
            }
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            positional_only = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
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
        } else if (std.mem.eql(u8, a, "-b") or std.mem.eql(u8, a, "--backup")) {
            opts.backup = true;
        } else if (std.mem.eql(u8, a, "-n-s-l") or std.mem.eql(u8, a, "--no-skip-list")) {
            opts.no_skip_list = true;
        } else if (std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--line")) {
            opts.show_lines = true;
        } else if (std.mem.eql(u8, a, "--max-depth")) {
            i += 1;
            if (i >= args.items.len) return fail(stderr, "missing value for --max-depth");
            opts.max_depth = std.fmt.parseInt(usize, args.items[i], 10) catch {
                return fail(stderr, "--max-depth expects a non-negative integer");
            };
        } else if (std.mem.eql(u8, a, "--stats-only")) {
            opts.stats_json = true;
            opts.quiet = true;
        } else if (std.mem.eql(u8, a, "-ex") or std.mem.eql(u8, a, "--exclude")) {
            i += 1;
            if (i >= args.items.len) return fail(stderr, "missing value for -ex/--exclude");
            try excludes.append(gpa, args.items[i]);
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
    opts.excludes = excludes.items;

    var stats = search.Stats{};
    var seen_paths = std.StringHashMap(void).init(gpa);
    defer seen_paths.deinit();
    for (paths.items) |p| {
        const gop = try seen_paths.getOrPut(p);
        if (gop.found_existing) continue;
        try walk.process(gpa, io, p, pattern.?, replacement orelse "", &opts, &stats, stdout, stderr);
    }

    const m = stats.matches.load(.monotonic);
    const fm = stats.files_matched.load(.monotonic);
    const fs = stats.files_scanned.load(.monotonic);
    const errs = stats.errors.load(.monotonic);
    const mode: []const u8 = if (opts.pattern_only) "search" else if (opts.dry_run) "dry_run" else "replace";

    if (opts.stats_json) {
        try stdout.print(
            "{{\"mode\":\"{s}\",\"matches\":{d},\"files_matched\":{d},\"files_scanned\":{d},\"errors\":{d}}}\n",
            .{ mode, m, fm, fs, errs },
        );
    } else if (opts.pattern_only) {
        try stdout.print("{d} matches in {d} files ({d} scanned)\n", .{ m, fm, fs });
    } else if (opts.dry_run) {
        try stdout.print("{d} matches in {d} files would be replaced ({d} scanned)\n", .{ m, fm, fs });
    } else {
        try stdout.print("{d} matches replaced in {d} files ({d} scanned)\n", .{ m, fm, fs });
    }

    if (errs > 0) return 2;
    if (m == 0) return 1;
    return 0;
}

fn fail(stderr: *std.Io.Writer, msg: []const u8) u8 {
    stderr.print("huntclaw: {s}\n", .{msg}) catch {};
    stderr.flush() catch {};
    return 2;
}
