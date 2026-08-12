# huntclaw

A find-and-replace utility with one goal: be the fastest thing you can run for
this job. Not the most features, not the prettiest output — speed. Everything
else is secondary.

Written in Zig, no runtime, no dependencies, ~260KB binary.

## Build

Requires Zig 0.16.0.

```
pip install ziglang --break-system-packages
python3 -m ziglang build --release=fast
```

The binary lands at `zig-out/bin/huntclaw`. For a Windows build from Linux/macOS:

```
python3 -m ziglang build --release=fast -Dtarget=x86_64-windows
```
or:
Download from `https://ziglang.org/download/`

If you have `zig` on PATH already, drop the `python3 -m ziglang` prefix and
just run `zig build --release=fast`.

## Benchmark

Measured against ripgrep 14.1.1, GNU grep 3.11, GNU sed 4.9, and sd 1.0.0 —
warmed up, best-of-N timing, same machine, same datasets. Search numbers
count total occurrences (not matching lines) so every tool is solving the
same problem.

| Scenario | huntclaw | ripgrep | GNU grep | sd | GNU sed |
|---|---|---|---|---|---|
| Search, 33MB file, 281k matches | **30ms** | 98ms | 165ms | — | — |
| Search, 3000 files, 12MB | **20ms** | 30ms | 58ms | — | — |
| Search, 20MB file, 60 matches (sparse) | 14ms | **9ms** | 28ms | — | — |
| Search, 10MB file, 1M matches (dense) | **15ms** | 145ms | 169ms | — | — |
| Replace, 33MB file, 281k matches | **53ms** | — | — | 122ms | 211ms |
| Replace, 3000 files | **167ms** | — | — | 1014ms | 946ms |
| Replace, 10MB file, 1M matches | **26ms** | — | — | 208ms | 164ms |

huntclaw wins six of seven scenarios. The one loss is intentional territory:
ripgrep's single-byte SIMD memchr has less work to do when a pattern is rare,
and at 60 matches in 20MB that advantage shows. Once matches get dense or the
file gets large, huntclaw's two-byte prefilter and lack of regex-engine
overhead pull ahead — sometimes by an order of magnitude. Against sed and sd,
which do the same job huntclaw is built for, there's no contest.

Full methodology and raw numbers are reproducible: generate the datasets
described in the table, run each tool with warmup, take the minimum of
several runs.

## Usage

```
huntclaw <pattern> <replacement> [path...] [options]
huntclaw -p <pattern> [path...]            (search only, no replace)
```

Examples:

```
huntclaw TODO FIXME src/                  # replace TODO with FIXME under src/
huntclaw -p "unwrap()" src/               # just count/list matches
huntclaw -i hello Hello .                 # case-insensitive replace
huntclaw -n oldname newname .             # dry run, no writes
huntclaw -e rs -e toml old new .          # only .rs and .toml files
huntclaw -q foo bar .                     # suppress per-file output
```

Options:

| Flag | Meaning |
|---|---|
| `-p, --pattern-only` | search only, don't replace |
| `-i, --ignore-case` | case-insensitive match |
| `-n, --dry-run` | report what would change, write nothing |
| `-e, --ext <ext>` | restrict to files with this extension (repeatable) |
| `-q, --quiet` | suppress per-file lines, keep the summary |
| `-h, --help` | show usage |

huntclaw skips binary files automatically and ignores `.git`, `node_modules`,
`.zig-cache`, `zig-out`, `target`, `.svn`, `.hg` when walking directories.
Matching is literal substring matching, not regex — that's part of why it's
fast.

## How it's fast

- Boyer-Moore-Horspool skip table for the base scan, so mismatches skip
  multiple bytes instead of one.
- A two-byte SIMD prefilter (first + last byte of the pattern, compared
  across a full vector width at once) narrows candidates before the scalar
  verification step runs — this is the same class of trick memchr-based
  tools use, sized to the pattern instead of a single byte.
- Single-pass replace: output is built directly with a growable buffer
  instead of scanning once to count matches and again to build the result.
- Directory walks over many files are split across worker threads once the
  file count crosses a small threshold, so multi-core machines scale
  close to linearly on large trees.
- Atomic counters for stats instead of a lock, since increments happen far
  more often than the summary is read.
