const std = @import("std");
const scanner = @import("scanner.zig");
const git = @import("git.zig");

// Simple writer wrapper that provides print functionality
const StdoutWriter = struct {
    file: std.fs.File,
    buffer: [4096]u8,
    pos: usize,

    fn init() StdoutWriter {
        return .{
            .file = std.fs.File.stdout(),
            .buffer = undefined,
            .pos = 0,
        };
    }

    fn print(self: *const StdoutWriter, comptime fmt: []const u8, args: anytype) !void {
        var buf: [4096]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, fmt, args);
        _ = try self.file.write(text);
    }
};

const Color = enum {
    reset,
    red,
    green,
    yellow,

    fn code(self: Color) []const u8 {
        return switch (self) {
            .reset => "\x1b[0m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
        };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var writer = StdoutWriter.init();

    // Parse arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.skip();

    var scan_path: []const u8 = ".";
    var show_all = false;
    var max_depth: ?usize = null;
    var ignore_patterns_str: []const u8 = "";

    // Simple argument parsing
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp(writer);
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try writer.print("gitocd 0.1.0\n", .{});
            return;
        } else if (std.mem.eql(u8, arg, "--all") or std.mem.eql(u8, arg, "-a")) {
            show_all = true;
        } else if (std.mem.eql(u8, arg, "--path") or std.mem.eql(u8, arg, "-p")) {
            if (args.next()) |path| {
                scan_path = path;
            } else {
                try writer.print("Error: --path requires an argument\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--depth") or std.mem.eql(u8, arg, "-d")) {
            if (args.next()) |depth_str| {
                max_depth = std.fmt.parseInt(usize, depth_str, 10) catch {
                    try writer.print("Error: invalid depth value: {s}\n", .{depth_str});
                    std.process.exit(1);
                };
            } else {
                try writer.print("Error: --depth requires an argument\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--ignore") or std.mem.eql(u8, arg, "-i")) {
            if (args.next()) |patterns| {
                ignore_patterns_str = patterns;
            } else {
                try writer.print("Error: --ignore requires an argument\n", .{});
                std.process.exit(1);
            }
        } else {
            try writer.print("Error: unknown argument: {s}\n", .{arg});
            try writer.print("Run 'gitocd --help' for usage information\n", .{});
            std.process.exit(1);
        }
    }

    // Parse ignore patterns
    var ignore_list: std.ArrayList([]const u8) = .empty;
    defer ignore_list.deinit(allocator);

    // Add default ignore patterns
    try ignore_list.append(allocator, "node_modules");
    try ignore_list.append(allocator, "target");
    try ignore_list.append(allocator, ".cache");
    try ignore_list.append(allocator, "zig-cache");
    try ignore_list.append(allocator, "zig-out");

    // Add user-specified patterns
    if (ignore_patterns_str.len > 0) {
        var iter = std.mem.splitScalar(u8, ignore_patterns_str, ',');
        while (iter.next()) |pattern| {
            const trimmed = std.mem.trim(u8, pattern, " \t");
            if (trimmed.len > 0) {
                try ignore_list.append(allocator, trimmed);
            }
        }
    }

    // Create scanner options
    const opts = scanner.ScanOptions{
        .max_depth = max_depth,
        .ignore_patterns = ignore_list.items,
    };

    // Scan for repositories
    var repos = try scanner.scanForRepos(allocator, scan_path, opts);
    defer {
        for (repos.items) |repo| {
            allocator.free(repo.path);
        }
        repos.deinit(allocator);
    }

    if (repos.items.len == 0) {
        try writer.print("No git repositories found.\n", .{});
        return;
    }

    try writer.print("\nFound {d} git repositories:\n\n", .{repos.items.len});

    // Check status of each repository
    var clean_count: usize = 0;
    var dirty_count: usize = 0;
    var has_errors = false;

    for (repos.items) |repo| {
        const status = try git.getRepoStatus(allocator, repo.path);
        defer status.deinit(allocator);

        const is_clean = status.untracked_files.len == 0 and
            status.modified_files.len == 0 and
            status.unpushed_commits == 0;

        if (is_clean) {
            clean_count += 1;
            if (show_all) {
                try writer.print("{s}✓ {s}{s}\n", .{ Color.green.code(), repo.path, Color.reset.code() });
                try writer.print("  Clean\n\n", .{});
            }
        } else {
            dirty_count += 1;
            has_errors = true;

            try writer.print("{s}⚠ {s}{s}\n", .{ Color.yellow.code(), repo.path, Color.reset.code() });

            if (status.untracked_files.len > 0) {
                try writer.print("  Untracked files: {d}\n", .{status.untracked_files.len});
                for (status.untracked_files[0..@min(3, status.untracked_files.len)]) |file| {
                    try writer.print("    - {s}\n", .{file});
                }
                if (status.untracked_files.len > 3) {
                    try writer.print("    ... and {d} more\n", .{status.untracked_files.len - 3});
                }
            }

            if (status.modified_files.len > 0) {
                try writer.print("{s}  Modified files: {d}{s}\n", .{ Color.red.code(), status.modified_files.len, Color.reset.code() });
                for (status.modified_files[0..@min(3, status.modified_files.len)]) |file| {
                    try writer.print("{s}    - {s}{s}\n", .{ Color.red.code(), file, Color.reset.code() });
                }
                if (status.modified_files.len > 3) {
                    try writer.print("    ... and {d} more\n", .{status.modified_files.len - 3});
                }
            }

            if (status.unpushed_commits > 0) {
                try writer.print("{s}  Unpushed commits: {d}{s}\n", .{ Color.yellow.code(), status.unpushed_commits, Color.reset.code() });
            }

            try writer.print("\n", .{});
        }
    }

    // Print summary
    try writer.print("─────────────────────────────────────\n", .{});
    try writer.print("Summary:\n", .{});
    try writer.print("{s}  Clean: {d}{s}\n", .{ Color.green.code(), clean_count, Color.reset.code() });
    if (dirty_count > 0) {
        try writer.print("{s}  Dirty: {d}{s}\n", .{ Color.red.code(), dirty_count, Color.reset.code() });
    } else {
        try writer.print("  Dirty: 0\n", .{});
    }
    try writer.print("  Total: {d}\n", .{repos.items.len});

    // Exit with error code if there are dirty repos
    if (has_errors) {
        std.process.exit(1);
    }
}

fn printHelp(writer: anytype) !void {
    try writer.print(
        \\gitocd - Git Repository Status Scanner
        \\
        \\USAGE:
        \\    gitocd [OPTIONS]
        \\
        \\OPTIONS:
        \\    -h, --help              Show this help message
        \\    -v, --version           Show version information
        \\    -a, --all               Show all repositories (including clean ones)
        \\    -p, --path <PATH>       Directory to scan (default: current directory)
        \\    -d, --depth <N>         Maximum recursion depth
        \\    -i, --ignore <PATTERNS> Comma-separated patterns to skip
        \\
        \\EXAMPLES:
        \\    gitocd                       # Scan current directory
        \\    gitocd --all                 # Show all repos including clean
        \\    gitocd --path ~/projects     # Scan specific directory
        \\    gitocd --depth 3             # Limit recursion depth
        \\    gitocd --ignore ".git,dist"  # Ignore additional patterns
        \\
        \\EXIT CODES:
        \\    0    All repositories are clean
        \\    1    One or more repositories have uncommitted or unpushed changes
        \\
    , .{});
}
