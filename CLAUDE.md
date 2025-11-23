# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`gitocd` is a high-performance CLI tool written in Zig that recursively scans filesystems to identify git repositories with uncommitted changes, untracked files, or unpushed commits. The tool is designed for speed and efficiency, inspired by modern CLI tools like ripgrep.

## Build and Development Commands

### Building
```bash
# Debug build
zig build

# Optimized release build (recommended for testing performance)
zig build -Doptimize=ReleaseFast

# The compiled binary will be in: ./zig-out/bin/gitocd
```

### Running
```bash
# Run directly with zig build
zig build run

# Run with arguments
zig build run -- --path ~/projects --all

# Run compiled binary
./zig-out/bin/gitocd
```

### Testing
```bash
# Run all unit tests
zig build test
```

## Code Architecture

### Module Structure

The codebase is organized into three main modules:

1. **main.zig** - Entry point and CLI interface
   - Argument parsing (manual implementation, no external CLI library)
   - Output formatting with ANSI color codes (Color enum)
   - StdoutWriter wrapper for buffered output
   - Repository status display and summary generation
   - **Parallel git status checking** using thread pool
   - Progress indicator for large scans (20+ repos)

2. **scanner.zig** - Filesystem traversal
   - `scanForRepos()` - Main entry point for finding git repositories
   - `scanDirectoryParallel()` - **Parallelized** recursive directory walker
   - Uses `std.Thread.Pool` for concurrent directory scanning
   - `RepoCollector` - Thread-safe repository list with mutex protection
   - Respects depth limits and ignore patterns
   - Stops recursion when `.git` directory is found (doesn't scan inside repos)
   - Silently skips directories with access errors
   - Each subdirectory spawns a parallel scan job

3. **git.zig** - Git status checking
   - `getRepoStatus()` - Returns comprehensive status (untracked, modified, unpushed)
   - `runGitCommand()` - Shell out to git CLI
   - Parses `git status --porcelain` output
   - Counts unpushed commits using `git rev-list --count @{u}..HEAD`
   - Gracefully handles repos without remotes

### Key Design Patterns

**Parallelization**: The tool uses `std.Thread.Pool` and `std.Thread.WaitGroup` for parallel execution:
- Directory scanning spawns workers for each subdirectory in parallel
- Git status checks run concurrently for all discovered repositories
- Both scanning and status checking don't block each other
- Uses mutex-protected shared state (`RepoCollector`, results list) for thread safety

**Resource Management**: All allocations use explicit `allocator.free()` or `defer` cleanup. Pay careful attention to errdefer blocks to prevent leaks on error paths. Thread pool workers must not leak memory - each worker cleans up its path allocation.

**Git Integration**: The tool shells out to git CLI commands rather than using libgit2. All git operations handle failure gracefully (repos without remotes, detached HEAD, etc.) by returning empty results rather than errors.

**Default Ignore Patterns**: The scanner automatically skips common build/cache directories:
- node_modules
- target
- .cache
- zig-cache
- zig-out

User-specified patterns are added via `--ignore` flag (comma-separated).

**Exit Codes**: The tool exits with status 1 if any dirty repositories are found, 0 if all are clean. This enables use in CI/automation scripts.

### Output Format

The tool categorizes repository issues by severity:
- **Yellow warning (⚠)** - Untracked files or unpushed commits
- **Red highlighting** - Modified files (highest priority)
- **Green checkmark (✓)** - Clean repos (only shown with --all flag)

Modified files are considered the most critical issue and are displayed in red.

## Important Zig Patterns Used

**ArrayList initialization**: Uses `.empty` syntax (Zig 0.15.2 API):
```zig
var repos: std.ArrayList(Repository) = .empty;
// Note: append() and deinit() require allocator parameter
try repos.append(allocator, item);
repos.deinit(allocator);
```

**Thread Pool Pattern**: For parallel execution:
```zig
var pool: std.Thread.Pool = undefined;
try pool.init(.{ .allocator = allocator });
defer pool.deinit();

var wg = std.Thread.WaitGroup{};
pool.spawnWg(&wg, workerFunction, .{args});
pool.waitAndWork(&wg); // Waits for all workers to complete
```

**Mutex-protected shared state**:
```zig
var mutex = std.Thread.Mutex{};
mutex.lock();
defer mutex.unlock();
// Critical section here
```

**String slicing**: Zig strings are `[]const u8`, sliced with `[start..end]` syntax.

**Process execution**: Uses `std.process.Child` with explicit pipe configuration for stdout/stderr.

**Error handling**: Most functions return error unions. Git command failures are caught and converted to empty strings to handle edge cases gracefully.

## Performance Characteristics

The tool is optimized for large-scale scanning (200+ repositories):
- **Parallel directory scanning**: Each subdirectory is scanned concurrently by the thread pool
- **Parallel git status checks**: All repository status checks run in parallel
- **Non-blocking**: Scanning and status checking happen concurrently
- **Progress feedback**: For scans with 20+ repos, progress updates appear every 10 repos checked

For maximum performance, always use the release build: `zig build -Doptimize=ReleaseFast`

## Testing Notes

Tests are basic smoke tests that verify scanner functionality and git status parsing. Git-related tests gracefully skip if not run in a git repository.

When writing new tests, follow the pattern of printing debug output and using `std.testing.allocator` for memory leak detection.

**Testing parallel code**: The parallel scanner uses thread pools which can make debugging harder. If you need to debug scanning issues, consider temporarily making the scan sequential for easier troubleshooting.

## Requirements

- Zig 0.15.2 (check build.zig.zon if it exists for exact version)
- Git CLI must be available in PATH
