const std = @import("std");

pub const Repository = struct {
    path: []const u8,
};

pub const ScanOptions = struct {
    max_depth: ?usize = null,
    ignore_patterns: []const []const u8 = &.{},
};

pub fn scanForRepos(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    options: ScanOptions,
) !std.ArrayList(Repository) {
    var repos: std.ArrayList(Repository) = .empty;
    errdefer {
        for (repos.items) |repo| {
            allocator.free(repo.path);
        }
        repos.deinit(allocator);
    }

    try scanDirectory(allocator, &repos, root_path, 0, options);
    return repos;
}

fn scanDirectory(
    allocator: std.mem.Allocator,
    repos: *std.ArrayList(Repository),
    dir_path: []const u8,
    current_depth: usize,
    options: ScanOptions,
) !void {
    // Check depth limit
    if (options.max_depth) |max| {
        if (current_depth >= max) return;
    }

    // Check if this directory should be ignored
    const basename = std.fs.path.basename(dir_path);
    for (options.ignore_patterns) |pattern| {
        if (std.mem.eql(u8, basename, pattern)) {
            return;
        }
    }

    // Try to open the directory
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        // Silently skip directories we can't open (permissions, etc.)
        if (err == error.AccessDenied) return;
        return err;
    };
    defer dir.close();

    // Check if this directory is a git repository
    const has_git = blk: {
        dir.access(".git", .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (has_git) {
        // This is a git repository, add it to the list
        const repo_path = try allocator.dupe(u8, dir_path);
        errdefer allocator.free(repo_path);

        try repos.append(allocator, .{ .path = repo_path });

        // Don't recurse into git repositories
        return;
    }

    // Iterate through directory entries
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        // Skip hidden directories (except .git which we check above)
        if (entry.name[0] == '.') continue;

        // Build full path
        const sub_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(sub_path);

        // Recursively scan subdirectory
        try scanDirectory(allocator, repos, sub_path, current_depth + 1, options);
    }
}

test "scanner basic functionality" {
    const allocator = std.testing.allocator;

    const options = ScanOptions{
        .max_depth = 3,
        .ignore_patterns = &.{"node_modules"},
    };

    var repos = try scanForRepos(allocator, ".", options);
    defer {
        for (repos.items) |repo| {
            allocator.free(repo.path);
        }
        repos.deinit();
    }

    // We should find at least the current directory if it's a git repo
    // This is just a basic test to ensure the scanner doesn't crash
    std.debug.print("Found {d} repositories\n", .{repos.items.len});
}
