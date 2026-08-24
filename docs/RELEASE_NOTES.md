# Release Notes

## v0.7

- fix: n_threads-1 underflowed to a huge allocation when getCpuCount() returned 0
- feat: add -b/--backup, writes a .bak copy of each file right before it's replaced


## v0.1

- docs: README with build guide, benchmarks, usage
- perf: SIMD two-byte prefilter for match scanning
- cli: fix argument iteration on Windows (allocator-backed iterator)
- perf: parallelize directory walk across worker threads
- cli: argument parsing and sequential directory walk
- search: Boyer-Moore-Horspool matcher and single-pass replace
- init: project scaffold, zig 0.16 build config


## v0.2

- docs: refresh benchmark image with v0.2 numbers
- cli: add -v/--version flag, bump to 0.2, document new flags
- perf: reuse one file handle for read and write instead of reopening
- perf: read files with a single sized allocation instead of growable buffer
- cli: add -n-s-l/--no-skip-list flag to disable default dir skip list
- benchmark for manual testing
- docs: render benchmark table as image instead of markdown table
- docs: new download instruction for Zig


## v0.3

- docs: correct benchmark description to match sparse-search winner
- docs: refresh benchmark numbers after quiet-flag and SIMD-scan fixes
- fix: SIMD scan walks every candidate in a lane instead of restarting on the first false positive
- fix: -q/--quiet no longer suppresses the summary line


## v0.4

- fix: support -- to allow patterns and replacements that start with a dash
- docs: refresh main benchmark for v0.4, add v0.3 vs v0.4 comparison
- perf: size the replace buffer exactly when output can't grow past one match
- docs: document -l, --max-depth, and --stats-only flags
- feat: add --stats-only flag for JSON summary output
- feat: add --max-depth flag to limit directory recursion
- feat: add -l/--line flag for grep-style line number and match text output


## v0.5

- feat: read .huntclaw-rc for project skip-dirs, default flags, and excludes


## v0.6

- fix: glob matcher could hang on pathological * patterns, now linear time
- fix: dry-run per-file message said 'replaced' instead of 'would replace'
- feat: add init command to scaffold a .huntclaw-rc template

