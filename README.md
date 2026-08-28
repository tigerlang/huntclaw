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

Measured on this machine (Linux x86_64) with ripgrep 15.1.0, GNU grep 3.11,
GNU sed 4.9, and sd 0.7.6 — warmed up (5 runs discarded), best-of-25 timing
for search and best-of-10/15 for replace (replace runs are fewer because
each one re-copies the dataset first). Search numbers count total
occurrences, not matching lines, and every tool is asked to produce the
same, minimal amount of output: `rg --count-matches --null-data` and `grep
-c` instead of `-o | wc -l`, which used to force ripgrep to print every
match through a second process — that was comparing output volume, not
search speed. All numbers below came straight out of `huntclaw_bench.py`,
unedited.

**Search** (ms, min of 25 runs):

| Scenario | huntclaw | ripgrep | GNU grep |
|---|---|---|---|
| large (42MB, 413076 occurrences) | 20.96 | 17.43 | 26.45 |
| manyfiles (4200 files) | 17.22 | 34.02 | 19.35 |
| sparse (23MB, 50 occurrences) | 6.79 | 4.77 | 2.76 |
| dense (12MB, 1150000 occurrences) | 12.25 | 17.33 | 6.06 |

**Replace** (ms, min of 10–15 runs):

| Scenario | huntclaw | sd | GNU sed |
|---|---|---|---|
| large (42MB, 413076 occurrences) | 56.68 | 64.56 | 188.02 |
| manyfiles (4200 files, find\|xargs for sd/sed) | 37.00 | 877.69 | 844.02 |
| dense (12MB, 1150000 occurrences) | 20.65 | 35.51 | 156.97 |

No single tool wins everywhere. ripgrep's single-byte memchr scan has less
work to do than huntclaw's two-byte prefilter when a pattern is rare
(sparse), and GNU grep is competitive on search generally — it has no
regex-engine overhead to pay for a literal pattern either. huntclaw's edge
shows up once matches get dense, files get large, or — most consistently —
once a replace actually has to happen: no other tool here reads and
rewrites a file in one pass the way huntclaw does, and the manyfiles
replace numbers show it (sd and xargs/sed both pay per-process startup
cost 4200 times over).

Full methodology and raw numbers are reproducible: generate the datasets
described in the table, run each tool with warmup, take the minimum of
several runs. Run `huntclaw_bench.py` yourself to check these numbers on
your own machine — pass `RIPGREP_BIN`/`GREP_BIN`/`HUNTCLAW_BIN` env vars if
those binaries aren't on your PATH under their usual names.

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
huntclaw -p -l "unwrap()" src/            # show line number and match text
huntclaw -p --max-depth 1 TODO .          # only scan the top-level directory
huntclaw -p --stats-only TODO . | jq      # JSON summary for scripting
huntclaw -b foo bar .                     # back up each file to .bak before replacing
huntclaw init                             # scaffold a .huntclaw-rc template
```

Options:

| Flag | Meaning |
|---|---|
| `-p, --pattern-only` | search only, don't replace |
| `-i, --ignore-case` | case-insensitive match |
| `-n, --dry-run` | report what would change, write nothing |
| `-e, --ext <ext>` | restrict to files with this extension (repeatable) |
| `-q, --quiet` | suppress per-file lines, keep the summary |
| `-b, --backup` | write a `.bak` copy of each file before replacing |
| `-n-s-l, --no-skip-list` | do not skip `.git`, `node_modules`, and other default dirs |
| `-l, --line` | show line number and matching line text (search mode) |
| `--max-depth <N>` | limit directory recursion depth (0 = given dirs only) |
| `--stats-only` | print only a JSON summary, no per-file output |
| `-ex, --exclude <glob>` | exclude files/dirs matching this glob (repeatable) |
| `-v, --version` | print version and exit |
| `-h, --help` | show usage |
| `init` | create a `.huntclaw-rc` template in the current directory |

huntclaw skips binary files automatically and ignores `.git`, `node_modules`,
`.zig-cache`, `zig-out`, `target`, `.svn`, `.hg` when walking directories
unless `-n-s-l`/`--no-skip-list` is set. Matching is literal substring
matching, not regex — that's part of why it's fast.

## How it's fast

- Boyer-Moore-Horspool skip table for the base scan, so mismatches skip
  multiple bytes instead of one.
- A two-byte SIMD prefilter (first + last byte of the pattern, compared
  across a full vector width at once) narrows candidates before the scalar
  verification step runs — this is the same class of trick memchr-based
  tools use, sized to the pattern instead of a single byte. Every candidate
  found inside one vector is checked before moving to the next, so a run of
  false positives doesn't force a rescan.
- Single-pass replace: output is built directly with a growable buffer
  instead of scanning once to count matches and again to build the result.
- Files are read with one stat and one sized allocation instead of a
  growable buffer that reallocates as it fills.
- Read and write share the same open file handle when a file is modified,
  instead of closing and reopening the path to write the result back.
- Directory walks over many files are split across worker threads once the
  file count crosses a small threshold, so multi-core machines scale
  close to linearly on large trees.
- Atomic counters for stats instead of a lock, since increments happen far
  more often than the summary is read.
