const std = @import("std");

pub const RepoStatus = struct {
    untracked_files: [][]const u8,
    modified_files: [][]const u8,
    unpushed_commits: usize,

    pub fn deinit(self: RepoStatus, allocator: std.mem.Allocator) void {
        for (self.untracked_files) |file| {
            allocator.free(file);
        }
        allocator.free(self.untracked_files);

        for (self.modified_files) |file| {
            allocator.free(file);
        }
        allocator.free(self.modified_files);
    }
};

pub fn getRepoStatus(allocator: std.mem.Allocator, repo_path: []const u8) !RepoStatus {
    var untracked: std.ArrayList([]const u8) = .empty;
    defer untracked.deinit(allocator);

    var modified: std.ArrayList([]const u8) = .empty;
    defer modified.deinit(allocator);

    // Get working tree status
    const status_output = try runGitCommand(allocator, repo_path, &.{ "status", "--porcelain" });
    defer allocator.free(status_output);

    // Parse status output
    var lines = std.mem.splitScalar(u8, status_output, '\n');
    while (lines.next()) |line| {
        if (line.len < 4) continue;

        const status_code = line[0..2];
        const file_path = std.mem.trim(u8, line[3..], " \t");

        if (file_path.len == 0) continue;

        // Check status codes
        // ?? = untracked
        // M, A, D, R, C = modified/added/deleted/renamed/copied in index or working tree
        if (std.mem.eql(u8, status_code, "??")) {
            try untracked.append(allocator, try allocator.dupe(u8, file_path));
        } else if (status_code[0] != ' ' or status_code[1] != ' ') {
            // Any other non-space status means the file is modified
            try modified.append(allocator, try allocator.dupe(u8, file_path));
        }
    }

    // Count unpushed commits
    const unpushed = try countUnpushedCommits(allocator, repo_path);

    return RepoStatus{
        .untracked_files = try untracked.toOwnedSlice(allocator),
        .modified_files = try modified.toOwnedSlice(allocator),
        .unpushed_commits = unpushed,
    };
}

fn countUnpushedCommits(allocator: std.mem.Allocator, repo_path: []const u8) !usize {
    // First, check if there's a remote tracking branch
    const branch_output = try runGitCommand(allocator, repo_path, &.{
        "rev-parse",
        "--abbrev-ref",
        "--symbolic-full-name",
        "@{u}",
    });
    defer allocator.free(branch_output);

    // If there's no upstream branch, return 0
    if (branch_output.len == 0 or std.mem.indexOf(u8, branch_output, "no upstream") != null) {
        return 0;
    }

    // Count commits ahead of upstream
    const count_output = try runGitCommand(allocator, repo_path, &.{
        "rev-list",
        "--count",
        "@{u}..HEAD",
    });
    defer allocator.free(count_output);

    const trimmed = std.mem.trim(u8, count_output, " \t\n\r");
    return std.fmt.parseInt(usize, trimmed, 10) catch 0;
}

fn runGitCommand(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    args: []const []const u8,
) ![]const u8 {
    // Build full command with git
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "git");
    try argv.appendSlice(allocator, args);

    // Run the command
    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Read output
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max
    errdefer allocator.free(stdout);

    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024); // 1MB max
    defer allocator.free(stderr);

    const term = try child.wait();

    // If the command failed, return empty string (repo might not have remote, etc.)
    if (term != .Exited or term.Exited != 0) {
        allocator.free(stdout);
        return try allocator.dupe(u8, "");
    }

    return stdout;
}

test "git status parsing" {
    const allocator = std.testing.allocator;

    // This test will only work if run in a git repository
    const status = getRepoStatus(allocator, ".") catch |err| {
        std.debug.print("Skipping git test (not in a repo): {}\n", .{err});
        return;
    };
    defer status.deinit(allocator);

    std.debug.print("Untracked: {d}, Modified: {d}, Unpushed: {d}\n", .{
        status.untracked_files.len,
        status.modified_files.len,
        status.unpushed_commits,
    });
}
