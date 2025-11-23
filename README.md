# gitocd

A blazing-fast CLI tool written in Zig that recursively scans your filesystem to find git repositories that need attention.

> ⚠️ **Disclaimer**: This project was vibecoded as a learning exercise for Zig and parallel programming. While it works, the code was written quickly and may contain bugs or non-idiomatic patterns. Use at your own peril! Contributions and improvements welcome.

## What It Does

`gitocd` scans directories (starting from the current working directory by default) and reports on git repositories that aren't clean:

- **Untracked files** - New files not yet added to git
- **Modified files** - Changed files not yet committed (red-level warnings)
- **Unpushed commits** - Local commits that haven't been pushed to remote

Built for speed with optimizations inspired by ripgrep and other modern CLI tools.

## Installation

```bash
# Build from source
zig build -Doptimize=ReleaseFast

# Run directly
zig build run
```

## Usage

```bash
# Scan current directory and subdirectories
gitocd

# Scan a specific path
gitocd --path ~/projects

# Show all repositories (including clean ones)
gitocd --all

# Limit recursion depth
gitocd --depth 3

# Ignore specific patterns
gitocd --ignore "node_modules,target,.cache"
```

## Options

- `--path, -p <PATH>` - Directory to scan (default: current directory)
- `--all, -a` - Show all git repositories, not just dirty ones
- `--depth, -d <N>` - Maximum recursion depth
- `--ignore <PATTERNS>` - Comma-separated patterns to skip

## Exit Codes

- `0` - All repositories are clean
- `1` - One or more repositories have uncommitted or unpushed changes

## Requirements

- Zig 0.15.2
- Git (for repository detection and status checking)

## License

MIT
