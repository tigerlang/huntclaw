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
const parallel_threshold = 8;

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

    if (stat.kind != .directory) {
        try processFile(gpa, io, path, pattern, replacement, opts, stats, stdout);
        return;
    }

    var files = std.ArrayList([]const u8).empty;
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }
    try collect(gpa, io, path, opts, &files, stderr);

    if (files.items.len < parallel_threshold) {
        for (files.items) |f| try processFile(gpa, io, f, pattern, replacement, opts, stats, stdout);
        return;
    }

    try processParallel(gpa, io, files.items, pattern, replacement, opts, stats, stdout);
}

fn collect(
    gpa: std.mem.Allocator,
    io: Io,
    dir_path: []const u8,
    opts: *const search.Options,
    files: *std.ArrayList([]const u8),
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
            try collect(gpa, io, sub, opts, files, stderr);
        } else if (entry.kind == .file) {
            if (!extMatches(entry.name, opts.exts)) continue;
            const full = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
            try files.append(gpa, full);
        }
    }
}

const Worker = struct {
    gpa: std.mem.Allocator,
    io: Io,
    files: []const []const u8,
    next: std.atomic.Value(usize),
    pattern: []const u8,
    replacement: []const u8,
    opts: *const search.Options,
    stats: *search.Stats,
    out_mutex: *Io.Mutex,
    stdout: *Io.Writer,

    fn run(self: *Worker) void {
        var line_buf: [4096]u8 = undefined;
        while (true) {
            const idx = self.next.fetchAdd(1, .monotonic);
            if (idx >= self.files.len) break;
            processFileBuffered(self.gpa, self.io, self.files[idx], self.pattern, self.replacement, self.opts, self.stats, &line_buf, self.out_mutex, self.stdout);
        }
    }
};

fn processParallel(
    gpa: std.mem.Allocator,
    io: Io,
    files: []const []const u8,
    pattern: []const u8,
    replacement: []const u8,
    opts: *const search.Options,
    stats: *search.Stats,
    stdout: *Io.Writer,
) !void {
    const cpu_count = std.Thread.getCpuCount() catch 4;
    const n_threads = @min(cpu_count, files.len);

    var out_mutex = Io.Mutex.init;
    var worker = Worker{
        .gpa = gpa,
        .io = io,
        .files = files,
        .next = std.atomic.Value(usize).init(0),
        .pattern = pattern,
        .replacement = replacement,
        .opts = opts,
        .stats = stats,
        .out_mutex = &out_mutex,
        .stdout = stdout,
    };

    const threads = try gpa.alloc(std.Thread, n_threads - 1);
    defer gpa.free(threads);

    for (threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    }
    worker.run();
    for (threads) |t| t.join();
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
    var dummy_mutex = Io.Mutex.init;
    var line_buf: [4096]u8 = undefined;
    processFileBuffered(gpa, io, path, pattern, replacement, opts, stats, &line_buf, &dummy_mutex, stdout);
}

fn processFileBuffered(
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    pattern: []const u8,
    replacement: []const u8,
    opts: *const search.Options,
    stats: *search.Stats,
    line_buf: []u8,
    out_mutex: *Io.Mutex,
    stdout: *Io.Writer,
) void {
    const data = Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_size)) catch |err| {
        if (err == error.IsDir) return;
        out_mutex.lockUncancelable(io);
        defer out_mutex.unlock(io);
        stdout.print("huntclaw: cannot read {s}: {t}\n", .{ path, err }) catch {};
        return;
    };
    defer gpa.free(data);
    if (data.len == 0) return;

    stats.incFilesScanned();
    if (looksBinary(data)) return;

    var matcher = search.Matcher.init(pattern, opts.ignore_case);

    if (opts.pattern_only) {
        const n = matcher.count(data);
        if (n > 0) {
            stats.addMatches(n);
            stats.incFilesMatched();
            if (!opts.quiet) {
                const msg = std.fmt.bufPrint(line_buf, "{s}: {d}\n", .{ path, n }) catch return;
                out_mutex.lockUncancelable(io);
                defer out_mutex.unlock(io);
                stdout.writeAll(msg) catch {};
            }
        }
        return;
    }

    const result = search.replaceAll(gpa, data, &matcher, replacement) catch return;
    defer gpa.free(result.output);
    if (result.matches == 0) return;

    stats.addMatches(result.matches);
    stats.incFilesMatched();
    if (!opts.quiet) {
        const msg = std.fmt.bufPrint(line_buf, "{s}: {d} replaced\n", .{ path, result.matches }) catch null;
        out_mutex.lockUncancelable(io);
        if (msg) |m| stdout.writeAll(m) catch {};
        out_mutex.unlock(io);
    }

    if (opts.dry_run) return;

    Dir.cwd().writeFile(io, .{ .sub_path = path, .data = result.output }) catch {};
}
