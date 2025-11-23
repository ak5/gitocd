const std = @import("std");

pub const Repository = struct {
    path: []const u8,
};

pub const ScanOptions = struct {
    max_depth: ?usize = null,
    ignore_patterns: []const []const u8 = &.{},
};

// Thread-safe repository collector
const RepoCollector = struct {
    repos: std.ArrayList(Repository),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) RepoCollector {
        return .{
            .repos = .empty,
            .mutex = .{},
            .allocator = allocator,
        };
    }

    fn addRepo(self: *RepoCollector, path: []const u8) !void {
        const repo_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(repo_path);

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.repos.append(self.allocator, .{ .path = repo_path });
    }

    fn deinit(self: *RepoCollector) void {
        for (self.repos.items) |repo| {
            self.allocator.free(repo.path);
        }
        self.repos.deinit(self.allocator);
    }

    fn toOwnedList(self: *RepoCollector) std.ArrayList(Repository) {
        return self.repos;
    }
};

// Context for parallel scanning
const ScanContext = struct {
    allocator: std.mem.Allocator,
    collector: *RepoCollector,
    options: ScanOptions,
    pool: *std.Thread.Pool,
};

const ScanJob = struct {
    context: *ScanContext,
    path: []const u8,
    depth: usize,
};

pub fn scanForRepos(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    options: ScanOptions,
) !std.ArrayList(Repository) {
    var collector = RepoCollector.init(allocator);
    errdefer collector.deinit();

    // Create thread pool
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator });
    defer pool.deinit();

    var context = ScanContext{
        .allocator = allocator,
        .collector = &collector,
        .options = options,
        .pool = &pool,
    };

    // Start initial scan
    try scanDirectoryParallel(&context, root_path, 0);

    return collector.toOwnedList();
}

fn scanDirectoryParallel(
    context: *ScanContext,
    dir_path: []const u8,
    current_depth: usize,
) !void {
    // Check depth limit
    if (context.options.max_depth) |max| {
        if (current_depth >= max) return;
    }

    // Check if this directory should be ignored
    const basename = std.fs.path.basename(dir_path);
    for (context.options.ignore_patterns) |pattern| {
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
        try context.collector.addRepo(dir_path);
        // Don't recurse into git repositories
        return;
    }

    // Collect subdirectories to scan in parallel
    var subdirs: std.ArrayList([]const u8) = .empty;
    defer subdirs.deinit(context.allocator);

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        // Skip hidden directories (except .git which we check above)
        if (entry.name[0] == '.') continue;

        // Build full path
        const sub_path = try std.fs.path.join(context.allocator, &.{ dir_path, entry.name });
        try subdirs.append(context.allocator, sub_path);
    }

    // Spawn parallel tasks for each subdirectory
    // Note: Workers take ownership of the paths and will free them
    var wg = std.Thread.WaitGroup{};
    for (subdirs.items) |sub_path| {
        context.pool.spawnWg(&wg, scanWorker, .{ context, sub_path, current_depth + 1 });
    }
    context.pool.waitAndWork(&wg);
}

fn scanWorker(context: *ScanContext, dir_path: []const u8, depth: usize) void {
    defer context.allocator.free(dir_path);
    scanDirectoryParallel(context, dir_path, depth) catch {
        // Silently ignore errors in parallel workers
    };
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
    std.debug.print("Found {d} repositories (parallel scan)\n", .{repos.items.len});
}
