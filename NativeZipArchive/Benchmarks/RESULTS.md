# NativeZip performance log

Medians (p50) from `swift package --disable-sandbox benchmark`, M3 Ultra (32 cores), macOS 27.2, APFS.
Each step is saved as a named baseline in `.benchmarkBaselines/` and can be re-compared with
`../Tools/bench-table . --metric 'Time \(wall clock\)|Instructions|Malloc' <a> <b>`.
The 2026-11-19 section below compares this machine's numbers with an M1 Max's (baseline `m1max`).

## 2026-11-21 (later): AppleDouble merged, links' times, decomposed names: Archive Utility's output (baselines `v1-before` → `v1-after`)

Nunarchiver's output was compared with Archive Utility's, item by item (the corpus, the method, and the table by
archive are in Disk/RESULTS.md, same date). Three things in a ZIP's expansion differed, and each is now an
`ExtractionOptions` field:

| Option | Default | What |
|---|---|---|
| `mergesAppleDouble` | on | `._NAME` beside `NAME`, or `__MACOSX/…/._NAME`, isn't extracted: its extended attributes, Finder info, resource fork, and ACL are set on `NAME` (a file or a directory). As Archive Utility, `ditto -x -k`, and macOS's `unzip`. |
| `restoreLinkTimestamps` | off | Symbolic links get their archived times (Archive Utility's; Info-ZIP's `unzip` leaves them). |
| `decomposesNames` | off | Names are written in the file system's decomposed form (`fileSystemRepresentation`), as Archive Utility writes them, instead of the archive's bytes. |

The app sets all three; every ZIP in the comparison then matches Archive Utility in every item (names, types, modes,
times, link targets, contents, extended attributes and their values, ACLs).

**How AppleDouble entries are merged** (`AppleDouble.swift`, `ZipExtractor.readAppleDoubles`): in the planner, with
Disk's attachments, not in a walk afterwards. Before an archive's entries are planned, one scan of their names finds
candidates (a last component starting `._`, 26 bytes to 64 MB); an archive with none pays only that scan. With
candidates, a table of the archive's files and directories by name pairs each with its item; the entry is decoded
(the planner's decoder, as symbolic links are), parsed, and kept as an `XAT` blob and an `ACL` blob (Disk's
`AccessControlListBlob(text:)` for `com.apple.acl.text`). The item is then planned with `attachments: true` and the
blobs added to its token: Disk sets them in its deferred pass (files) and directory pass, in the file system lanes.
Merged entries are taken off the progress totals. Directory entries under `__MACOSX` aren't made.

What isn't merged stays a file: a `._` entry that doesn't parse as AppleDouble, one whose item isn't in the archive
(beside it or under `__MACOSX`), one for a symbolic link. A resource fork for a directory is left out (`setxattr`
refuses it with `EPERM`; the entry's other attributes are set). A `com.apple.quarantine` inside an AppleDouble entry is
left out when the extraction sets its own. Archive Utility refuses an archive with such entries outright ("Error 79");
`ditto -x -k` drops the unmatched ones.

**Benchmarks** (`v1-before` → `v1-after`, one run each, **under load**): the archives measured have no AppleDouble
entries, so this is the cost of the name scan and the new options' tests. Mallocs and system calls are the firm
numbers; instructions on these rows include the kernel's and move ±10% between runs of unchanged code.

| Benchmark | Mallocs | System calls | Instructions |
|---|---|---|---|
| Extract 20,000 small files | 1,004 → 1,005 | 120 K → 118 K | 23 G → 23 G |
| Extract 20,000 small files, quarantined | 1,006 → 1,006 | 140 K → 139 K | 27 G → 26 G |
| Extract 2,000 small files (1 worker) | 2,297 → 2,297 | 9,367 → 9,359 | 2,703 M → 2,609 M |
| Extract 2,000 small files (8 workers) | 2,435 → 2,435 | 13 K → 13 K | 2,886 M → 2,936 M |
| Extract 2,000 small files: Bytes | 2,659 → 2,659 | 13 K → 13 K | 2,812 M → 2,754 M |
| Extract 32 MB text: Bytes | 116 → 117 | 134 → 134 | 263 M → 262 M |
| Extract 32 MB random | 116 → 117 | 129 → 129 | 51 M → 50 M |
| Extract 8 archives of 64 MB text (one pool) | 371 → 367 | 1,734 → 1,749 | 4,173 M → 4,171 M |

Merging itself, outside the suite (`nunzip`, hyperfine, 5 runs, loaded machine): 2,000 small files, each with one
extended attribute, archived by `ditto -c -k --sequesterRsrc` (4,001 entries, 2,000 of them AppleDouble) against the
same files archived without (`--norsrc`):

| | Wall |
|---|---|
| `nunzip`, no AppleDouble entries | 57 ms |
| `nunzip`, 2,000 merged (decoded during planning, 2,000 `fsetxattr` in the deferred pass) | 84 ms |
| `ditto -x -k`, the same archive | 1,100 ms |

**Tests**: 50 tests in 11 suites (was 46 in 10). New, `AppleDoubleTests`: `ditto`'s four layouts (`--sequesterRsrc`
or not, `--keepParent` or not) of a tree with attributes on files and a directory, Finder info, a 70,000-byte resource
fork, and an ACL, extracted and compared with `ditto -x -k` item by item (every attribute's bytes, the ACL's text);
off, the entries are files; names that only look like AppleDouble, items that aren't there, a link's, and a fork for a
directory; links' times with the option and without. (The trees are listed with `readdir`: Foundation's enumerators
leave `._` files out, so a listing made with one can't show that none is left.)

## 2026-11-21: a quarantine option; the mapping and the handoff shared (baselines `cleanup-before` → `cleanup-after`)

Extraction, parse, locate, and verify rows with the `SyscallCounting` trait. **Times under load**; counts are the firm
numbers.

**New: `ExtractionOptions.quarantine` and `ZipExtractor.extract(…quarantine:…)`** (Disk's `Quarantine`, `nil` by
default as Info-ZIP's `unzip`). It goes to Disk's `DestinationOptions`: the writers set `com.apple.quarantine` on each
file while it's open, and the passes after them on links and directories, including the parents an archive doesn't
list (Disk makes those on the way to their files; it now quarantines them too: Disk/RESULTS.md). The destination
directory itself is left alone. One attribute for the whole extraction (every archive a `ZipExtractor` adds).
The Nunarchiver app passed nothing and walked the tree afterwards on one thread (+0.7 s on an 8,060-entry archive that
expanded in 0.65 s); it passes the archive's quarantine now and the walk is gone.

| Extract 20,000 small files (`cleanup-after`) | Instructions | `Disk syscalls` | Wall (loaded) |
|---|---|---|---|
| plain | 22 G | 81,000 | 510 ms | |
| quarantined | 26 G | 101,000 | 602 ms | |

`quarantinesWhatItExtracts` (an archive with and without directory entries, a read-only file, a symbolic link; through
`ZipArchive.extract` and through a `ZipExtractor` into a subdirectory): every item beneath the destination has the
attribute, the destination doesn't, and modes and contents are as without one.

**Moved out:**

| Was here | Now | Rows that would show a cost (`cleanup-before` → `cleanup-after`) |
|---|---|---|
| `MappedFile` (61 lines) | Disk's `MappedFile` (NativeAEA's `RawMapping` was the same; `stableBuffer` is `buffer`) | Parse central directory 4,293,000 → 4,293,000 instructions, 2,289 mallocs both; Locate 2,000 payloads 3.29 → 3.29 M, 0 mallocs; Verify 2,000 small files 268 → 268 M (Bytes), 252 → 251 M (zlib) |
| `ChunkHandoff` (137 lines on raw `UnsafeContinuation`s) | BytesAsync's `AsyncHandoff<ZipDecoder.Chunk>` | Extract 32 MB text: Bytes 263 → 263 M, 116 mallocs both (the overlapped path: a chunk per MiB through the handoff); 8 archives of 64 MB 4.17 → 4.17 G, 365 → 373 mallocs |
| `pathconf(_PC_CASE_SENSITIVE)` on the destination's path | `Destination.isCaseSensitive` | — |

`Disk syscalls` are identical in every row, and mallocs identical in all but three (8 workers −1, verify with zlib −2,
the 8-archive row +8 of 365: the runtime's own, which varied the same way between earlier runs of one build).
`ZipDecoder.swift` 902 → 768 lines.

**Left here, and why:** `WorkQueue` and `forEachConcurrently` (verification's, typed to a per-worker `ZipDecoder`: one
user); `SourceState.waitUntilWritten` (a bitmap and a checked continuation for an archive that names one path twice:
rare by design); the umask for entries without a mode (ZIP's rule: archived modes exact, defaults less the umask;
Disk's policy is one or the other); making the destination path absolute (one line of caller policy); `ByteReader`
(the benchmarks' reference parser).

**Same output.** `nunzip` built before and after, on two archives of this repository's Bytes sources (231 items; one
with directory entries, one without, links stored as links) and six fixtures (`duplicates`, `symlink`, `unsafe-paths`,
`unicode-path`, `dos-backslash`, `zstd`): every item's type, mode, flags, size, link target, contents, and extended
attributes identical; exit codes the same (1 for `unsafe-paths.zip`, 0 for the rest).

`swift test`: 46 pass (debug); `BULK_TESTS=1 swift test -c release -Xswiftc -enable-testing`: 46 pass. A build
from scratch with tests has no warnings.

## 2026-11-20 (follow-ups): Disk's fixes, workarounds removed (baselines `fu-before` → `fu-sized` → `fu-after`)

Disk made what this package worked around (Disk/RESULTS.md, "follow-ups"). Extraction rows with the `SyscallCounting`
trait (`--filter 'Extract.*'`); `fu-before` from a copy of the tree before these changes, `fu-sized` with every Disk change
and NativeZip's sizing of Disk still in place, `fu-after` with only its writer cap left (below). **Times under load**;
counts are the firm numbers.

**What went** (`ZipContentSource.swift` 325 → 298 lines, `ZipArchive+Extraction.swift` 598 → 576):

- **The tag-to-error table** (`SourceState.record`, `error(tag:)`, and `error(described:)`, which matched the stopping
  failure by its description): `DiskError.source` carries the error now, so failures read `failure.error.sourceError`
  and the extraction throws it as it is. `nunzip` exits as before: 81 for an unsupported method (`ppmd.zip`), 82 with
  no password and with a wrong one (ZipCrypto and AES), 2 for a damaged entry, 0 otherwise (old and new binaries, same
  archives).
- **The check before the last write**, with its extra decode into the other buffer to see the stream's end first: Disk
  finishes a file only after the source returns, so `writeInline` decodes, writes, and checks after the loop, and
  `writeStored` no longer has a separate whole-entry branch. `failsSmallEntriesAfterTheirLastWrite` (stored and
  deflated, the central directory's CRC-32 changed) checks the file is removed and the error is `crcMismatch`, thrown
  and in the failures.
- **Sizing Disk's setup**: the internal `extract(…files:)` overload that set the queue to the file count and one
  large-file slot. Disk now makes writers' scratch, the job ring's pages, and large-file slots only when used. What
  still pays is a cap of one writer per file in `ZipArchive.extract` (3 lines): an idle writer costs its task.

  | Extract 32 MB random (one file) | Instructions | Mallocs | Process syscalls |
  |---|---|---|---|
  | `fu-before` (writers, queue, slots sized) | 51 M | 129 | 131 |
  | `fu-sized` (Disk lazy, sizing kept) | 50 M | 124 | 131 |
  | Disk lazy, nothing sized (24 writers) | 51 M | 263 | 156 |
  | Disk lazy, writers capped at the file count | 51 M | 124 | 131 |
  | `fu-after` (the same, and Disk's buffers made only when used) | 51 M | 116 | 131 |

  So queue and slot sizing no longer pay; 23 idle writers cost about 140 mallocs and 25 process syscalls.
- `record.expected` (the progress totals kept here to call `setExpected`): `ExtractionProgress.addExpected` adds each
  archive's totals and takes skipped entries off.

**Rows** (`fu-before` → `fu-after`):

| Benchmark | Instructions | Mallocs | Process syscalls | `Disk syscalls` |
|---|---|---|---|---|
| Extract 20,000 small files | 23 → 23 G | 21,000 → **1,004** | 123 K → 119 K | 81 K → 81 K |
| Extract 2,000 small files: Bytes | 2,963 → 2,850 M | 4,951 → 2,659 | 14 K → 13 K | 9,294 → 9,294 |
| Extract 2,000 small files (1 worker) | 3,324 → 2,714 M | 4,311 → 2,297 | 9,407 → 9,367 | 9,294 → 9,294 |
| Extract 32 MB text: Bytes | 263 → 262 M | 129 → 116 | 134 → 134 | 49 → 49 |
| Extract 8 archives of 64 MB text (one pool) | 4,180 → 4,173 M | 627 → **360** | 2,071 → 1,716 | 538 → 538 |

- **One allocation per file fewer** (2,000 fewer in every 2,000-file row, 20,000 in the 20,000-file one): the old
  `ZipContentSource.write` boxed itself once per call. `nunzip` on the 2,000-file archive allocated 1,999 boxes of
  `ZipContentSource` (`Tools/runtime-count --who swift_allocObject=x0`; on the new binary that tally crashed lldb), and on
  the 20,000-file archive made 81,922 `swift_allocObject`s before and 61,901 after (−20,021), `malloc` 625 both.
- The 8-archive row (`ZipExtractor`, which can't know the files in advance) lost 270 mallocs and 350 process syscalls of
  Disk's setup: the +248 mallocs the migration cost it are gone.
- Small-file rows' instructions moved −4 to −18%, within these rows' known spread between runs (±10–20%); not claimed.

`swift test`: 45 pass (debug); `BULK_TESTS=1 swift test -c release -Xswiftc -enable-testing`: 45 pass.

## 2026-11-20: writing through Disk (baselines `mig-before` → `mig-after`; A/B `ab-old-4…6` / `ab-same-4…6`, `prog-1…3`)

Extraction now writes through the `Disk` package (`../Disk`, extracted from NativeAEA and this package). **Every time
here was taken under load** (other agents building and benchmarking, load average 9–32): instructions, mallocs, and
call counts are the firm numbers; times are indicative, and the unchanged `Floor` rows moved −14.5% and +1.2% between
the two baselines.

**What moved.** `ZipExtractor` keeps planning (overwrite questions, freshen and update, claims, junk paths,
lowercasing, events) and drives Disk's `Planner`; Disk's writers call a `ContentSource` (`ZipContentSource.swift`):
- Names are cleaned by `EntryPath.sanitize` (Info-ZIP's rules) and checked by `EntryPath(validating:)`; parents not in
  the archive are the planner's implicit directories; freshen and update ask `Destination.existingItem(at:)`.
- Every entry is made relative to the destination's descriptor with `O_NOFOLLOW_ANY | O_RESOLVE_BENEATH`; an existing
  item planning decided to replace is unlinked by Disk (`.replace`), never written through.
- A job names its entry (`ArchiveJob` + index); each writer decodes with its own decoders (by `writerIndex`). Stored
  entries are written from the mapping, whole or in 8 MiB pieces, each checksummed just before it's written; compressed
  ones a 1 MB chunk at a time (`ZipDecoder.beginEntry`/`nextChunk`/`endEntry`, a pull interface replacing
  `decodePipelined`), from 4 MB decoding in a child task while the writer writes the other buffer. The size and CRC-32
  are checked before a file's last bytes are written (Disk closes a file written whole as it writes it); a streamed file
  that fails is removed by Disk.
- A later entry at a path an earlier file holds waits (in its writer) until the earlier one is written, then replaces it:
  archive order, without the old "after the pool" pass. Symbolic links are recorded with Disk at the end of planning
  (so a later entry can still cancel one); Disk makes them after the files, then directories' metadata, deepest first.
- Deleted (Disk owns them): `JobQueue`/`Waiters`, `DirectoryCache`, `FileDescriptor.apply`, `FileJob`/`LinkJob`/
  `DirectoryJob`, `WorkerDecoders`, `FailureLog`, the passes' `forEachConcurrently`, `relativePath`/`isClean`,
  `copyStored`, `contentsPipelined`, `decodePipelined`.

**API.** `ZipExtractor.extract(into:maxConcurrency:stopOnFirstError:progress:_:)` takes the destination, and
`add(_:entries:into:options:)` (now `async`) a subdirectory inside it: Disk extracts into one destination, opened once.
`ExtractionOptions.maxConcurrency` is optional (default: Disk's, one writer per performance core with a quarter of them
in file system calls); `ExtractionOptions.progress` and `extract(…progress:)` take Disk's `ExtractionProgress`, its
totals set from the central directory before anything is written (skipped entries come off them again). File system
failures are `DiskError`s; a decoder's failure keeps its `ZipError`.

**Sizing Disk for one archive.** Disk makes every writer's scratch, 128 large-file slots, and a 16,384-job ring when an
extraction starts. For one 32 MB entry with 24 writers that was 1,029 mallocs against 264, 478 process syscalls against
140, and 59 M instructions against 51 M (`Extract 32 MB random`). `ZipArchive.extract` now uses no more writers than
files, a queue no longer than the files (64 to 16,384), and one large-file slot (nothing is planned in pieces): 129
mallocs, 131 syscalls, 50 M instructions. `ZipExtractor` can't know the counts in advance (24 writers, 16,384 jobs):
the 8-archive row keeps +12 M instructions (+0.3%) and +248 mallocs of setup.

| Benchmark (p50) | Instructions | Mallocs | Process syscalls | Time (under load) |
|---|---|---|---|---|
| Extract 20,000 small files | 24 → 23 G | 103 K → 21 K | 82 K → 123 K | 598 → 534 ms |
| Extract 8 archives of 64 MB text (one pool) | 4,169 → 4,182 M (+0.3%) | 371 → 619 | 1,636 → 2,047 | 71 → 71 ms |
| Extract 2,000 small files: Bytes | 3,106 → 2,804 M | 15 K → 4.9 K | 9,495 → 14 K | 94 → 66 ms |
| Extract 2,000 small files (1 worker) | 2,661 → 2,691 M | 15 K → 4.3 K | 9,339 → 9,375 | 212 → 179 ms |
| Extract 2,000 small files (8 workers) | 2,953 → 2,854 M | 15 K → 4.5 K | 9,463 → 13 K | 85 → 70 ms |
| Extract 32 MB text: Bytes / zlib / Zstd | 263 / 241 / 402 → 262 / 240 / 401 M | 263 → 129 | 145 → 134 | 14 / 15 / 21 → 14 / 15 / 20 ms |
| Extract 32 MB random (stored) | 51 → 50 M | 264 → 129 | 140 → 131 | 3.9 → 3.8 ms |
| Inflate + CRC, Verify (controls) | ±0.7% | — | — | — |

Single small-file rows move ±10–20% in instructions between runs here (the kernel's share), so they were also
compared **interleaved with an identical harness** (git HEAD's library against this one, three rounds each, p0):
1 worker 2,771 / 2,918 / 2,790 M old against 2,675 / 2,707 / 2,661 M new (−3 to −7% every round); 20,000 files
23 / 23 / 24 G against 23 / 24 / 23 G; 2,000 files on all writers 2,814 / 2,923 / 2,941 against 2,889 / 2,964 /
2,928 M (−0.4 to +2.7%). (An earlier interleaved run, `ab-old-1…3` against `ab-new-1…3`, used this package's own
benchmark file for the new side and read +2–8%: the harnesses differed, not the libraries.)

**End to end** (`nunzip`, hyperfine, old and new binaries alternated for three rounds, minimum / median; load 5–15):

| Job | Old | New | Instructions (median) |
|---|---|---|---|
| 20,000 files of 1–8 KB (step15: 542 ms) | 542 / 548, 555 / 592, 545 / 557 ms | **514 / 537, 515 / 528, 502 / 515 ms** | 20.5 → 20.1–20.3 G |
| 8 archives of one 64 MB text file (step15: 73 ms) | 66 / 113, 66 / 67, 65 / 68 ms | 66 / 111, 67 / 70, 65 / 69 ms | 4,232 → 4,244 M |

`nunzip --jobs 1`, `8`, `24` on the 20,000 files (`/usr/bin/time -l`, three rounds): 19.5–20.0 → 19.1–19.4 G, 20.9–21.4
→ 20.6–21.1 G, 20.9–21.4 → 20.8–21.0 G instructions. The 8-archive job is the one that isn't faster: equal minimums,
medians 1–3 ms higher in two rounds, the +12 M instructions of Disk's setup for 24 writers on the calling task.
Neither a wider file system limit (8, 24) nor 8 writers changed it (68–69 ms minimums, then bimodal under load). A
smaller queue would cost more than it saves: Disk resumes a waiting planner on every pop, a wake-up per file once full.

**System calls per file.** With Disk's `SyscallCounting` trait (`swift package --traits SyscallCounting --scratch-path
.build-syscalls --disable-sandbox benchmark`, baseline `mig-syscalls`), Disk makes **4 calls per file** (`openat`,
`pwrite`, `fsetattrlist`, `close`) plus 2–5 per directory: 9,294 for 2,000 files and 321 directories, 81,000 for
20,000 files and 201 directories, 48–49 for one 32 MB file (`pwrite`s of 1 MB chunks or 8 MiB pieces), 538 for the
8 archives. The old writer made the same four (`open`, `write`, `fsetattrlist`, `close`, and `mkdir` per directory).
The process's count (package-benchmark's `.syscalls`) rose by about 2 per file with all writers (82 K → 123 K for
20,000 files) and not at all with one (9,339 → 9,375): thread parking and waking around Disk's file system limit
(24 writers, 6 in calls at once, where the old pool ran 8 small-file workers with no limit), not file system work.

**Progress** (`prog-1…3`, interleaved rounds, p0): `Extract 32 MB text: Bytes` 262 M with and without in every round
(one relaxed add per 1 MB chunk); 2,000 files, 1 worker, 2,548 / 2,539 / 2,554 M without against 2,559 / 2,520 /
2,626 M with; 20,000 files 22–23 G both. Nothing measurable: one relaxed add per file against about 1.2 M
instructions of kernel work.

**Same trees.** `InfoZIPComparisonTests` extracts an archive `/usr/bin/zip` makes (nested and read-only directories,
setuid and private modes, links, a 5 MB compressible file, a 9 MB stored one) with `/usr/bin/unzip` and NativeZip, with
no flags, `-K`, `-LL`, and `-X`, and compares every item's type, mode, size, contents, modification time, and link
target. By hand, `nunzip` before and after gave the same trees and exit codes as each other on 22 cases (the rich
archive with `-j -D -K -L -LL -X -n -f -u -C`, the format fixtures, encrypted ones with `-P`), and the same output and
exit codes for unsupported methods (81), wrong and missing passwords (82), several archives by wildcard, and existing
files without a terminal. Where both differ from Info-ZIP's `unzip` they did before: `-j` with a link (unzip fails),
`-n`/`-f`/`-u` restoring directory times, Unicode names (unzip folds `café` to `cafe`), MS-DOS hosts' modes, bzip2
(this `unzip` lacks it), and the warning exit code for prepended data.

## 2026-11-19: M1 Max against M3 Ultra (baselines `d2-zip2` → `m1max`)

> Later the same day the benchmark file was reworked for runtime: the three `Open + extract …` benchmarks were removed
> (each `Extract …` sample already opens the archive; they differed by ~0.2 ms of parsing, which `Parse central
> directory` measures; `Extract 2,000 small files: Bytes` is the equivalent row), CRC-32 inputs are made once in setup,
> and iteration counts changed. The rows below are from the old settings.

Every package's benchmarks were re-run on a new machine, an M1 Max. Same macOS (27.2 / 27.2.1) and
compiler (Swift 6.4.4, Xcode 27.3); what differs is the hardware:

| | M3 Ultra (`d2-zip2`, 2026-11-18) | M1 Max (`m1max`) |
|---|---|---|
| Cores | 24 P + 8 E (`activeProcessorCount` 32) | 8 P + 2 E (10) |
| P-core clock | ~4.05 GHz | ~3.23 GHz (1.25x lower) |
| Memory | 256 GB, 819 GB/s | 64 GB, 400 GB/s |
| P-cluster L2 | not measured | 12 MB |

Method: one full run, `swift package --disable-sandbox benchmark baseline update m1max --no-progress`, nothing else
benchmarking. `corespotlightd` used about one core during the Bytes runs on this machine (indexing new files; it
couldn't be stopped), so treat the parallel rows with extra care. The `d2-zip2` baseline was taken at a slightly
earlier commit than HEAD, so Instructions is the check that both machines ran the same code. Times are the
framework's p50, many rounded to 1 ms (an 18 ms row is ±3%): small ratios below mean little. Ratios are M1 Max time
over M3 Ultra time (above 1 = slower; the clock alone is 1.25). Output goes to `NSTemporaryDirectory()` on each
machine's internal SSD (different SSDs; not measured separately).

### Headline

Geometric mean of the time ratio over the 40 timed benchmarks: **1.34**. By kind:

| Kind | n | Geomean | Range |
|---|---|---|---|
| Single-threaded decode, CRC (in cache), parse, locate | 21 | **1.30** | 1.17–1.50 |
| Extraction and file-system floors (default, 1–8 workers, 32 MB entries) | 15 | 1.28 | 1.08–1.66 |
| CRC-32 over 32 MB (idle re-run `m1max-2`; the first run was disturbed, see below) | 2 | 1.19 | 1.08–1.32 |
| Parallel verify | 2 | 1.74 | 1.72–1.76 |

Same-code check: 21 of 40 benchmarks have identical instruction counts (as the baselines report them), 8 more
differ by less than 2%, and 11 differ by more (listed below). The 29 within 2% have a geomean of 1.34; the 11 have 1.36,
so they are not far from the rest, but their ratio is not a hardware ratio alone.

### Main benchmarks

| Benchmark | M3 Ultra | M1 Max | Ratio | Instructions (M3 → M1 Max) |
|---|---|---|---|---|
| Parse central directory (2,000 entries) | 189 µs | 253 µs | 1.34 | 4.30 M → 4.28 M |
| Locate 2,000 payloads | 188 µs | 244 µs | 1.30 | 3.29 M → 3.29 M |
| Inflate + CRC 32 MB text (Bytes / zlib) | 13 / 13 ms | 17 / 18 ms | 1.31 / 1.38 | 240 M / 218 M, identical |
| Inflate + CRC 32 MB raster (Bytes / zlib) | 9.3 / 11 ms | 12 / 13 ms | 1.29 / 1.18 | 138 M / 91 M, identical |
| Inflate + CRC 2,000 small files (Bytes / zlib) | 14 / 16 ms | 18 / 20 ms | 1.29 / 1.25 | 232 M / 214 M, identical |
| Zstd + CRC 32 MB text / raster | 18 / 10 ms | 27 / 13 ms | 1.50 / 1.30 | 379 M / 141 M, identical |
| Stored + CRC 32 MB random (Bytes / zlib) | 2.1 / 2.5 ms | 3.1 / 3.6 ms | 1.46 / 1.46 | 29 M / 31 M, identical |
| CRC-32 64 B (Bytes / zlib) | 2.8 / 6.4 ms | 3.3 / 7.5 ms | 1.19 / 1.17 | 46 M / 59 M, identical |
| CRC-32 1 KB (Bytes / zlib) | 0.54 / 1.4 ms | 0.67 / 1.7 ms | 1.25 / 1.18 | 14 M / 16 M, identical |
| CRC-32 256 KB, in cache (Bytes / zlib) | 0.45 / 0.80 ms | 0.56 / 1.1 ms | 1.25 / 1.34 | 11 M / 13 M, identical |
| CRC-32 32 MB (Bytes / zlib), re-run `m1max-2` | 0.57 / 0.84 ms | 0.62 / 1.1 ms | **1.08 / 1.32** (first run: 2.38 / 1.72, disturbed) | 10 M / 13 M, identical |
| Extract 32 MB text (Bytes / zlib / Zstd) | 14 / 15 / 20 ms | 17 / 18 / 27 ms | 1.21 / 1.20 / 1.35 | 263 M / 241 M / 402 M, −0.4% / −0.4% / 0 |
| Extract 32 MB random | 3.8 ms | 4.9 ms | 1.28 | 51 M, identical |
| Extract 2,000 small files, default workers (Bytes / zlib) | 71 / 73 ms | 83 / 83 ms | 1.17 / 1.14 | 2,871 M → 3,345 M (+16.5%); 2,888 M → 3,211 M (+11.2%) |
| Open + extract 2,000 small files | 72 ms | 79 ms | 1.10 | 2,888 M → 3,202 M (+10.9%) |
| Floor: create + write 2,000 files | 133 ms | 201 ms | 1.51 | 1,832 M → 2,456 M (+34.1%) |
| Floor: via `openat` | 123 ms | 171 ms | 1.39 | 1,753 M → 2,008 M (+14.5%) |
| Verify 2,000 small files (parallel) (Bytes / zlib) | 2.7 / 2.7 ms | 4.6 / 4.8 ms | 1.72 / 1.76 | 274 M → 261 M (−4.7%); 256 M → 243 M (−5.1%) |

### Instruction counts that differ by more than 2% (11)

All are file-system or parallel rows. Not one of the decode, CRC, parse, or locate rows differs.

| Benchmark | M3 → M1 Max |
|---|---|
| Extract 2,000 small files (1 worker) | 2,672 M → 3,116 M (+16.6%) |
| Extract 2,000 small files (2 workers) | 2,707 M → 2,955 M (+9.2%) |
| Extract 2,000 small files (4 workers) | 2,712 M → 3,349 M (+23.5%) |
| Extract 2,000 small files (8 workers) | 2,936 M → 3,257 M (+10.9%) |
| Extract 2,000 small files: Bytes | 2,871 M → 3,345 M (+16.5%) |
| Extract 2,000 small files: zlib | 2,888 M → 3,211 M (+11.2%) |
| Open + extract 2,000 small files | 2,888 M → 3,202 M (+10.9%) |
| Floor: create + write 2,000 files (no decoding) | 1,832 M → 2,456 M (+34.1%) |
| Floor: create + write 2,000 files via openat | 1,753 M → 2,008 M (+14.5%) |
| Verify 2,000 small files (parallel): Bytes | 274 M → 261 M (−4.7%) |
| Verify 2,000 small files (parallel): zlib | 256 M → 243 M (−5.1%) |

What the names and code say, no more: the nine rows that create 2,000 small files all cost more instructions on
the M1 Max, including the two "Floor" rows, which are one thread opening, writing, and closing 2,000 files with no
decoding. So the extra instructions are in the file-creation path, not the codecs (whose rows are identical), and not
in worker contention (the Floor rows and the 1-worker row have none: +34.1%, +14.5%, +16.6%). The Floor loop's
~1 M instructions a file (1,832 M over 2,000 files) is far more than the user-side code, so the metric evidently
counts the kernel's side of the system calls (inference). Why the kernel runs more instructions on the M1 Max (a
different SSD and its driver path, or APFS behaving differently at this speed) and why 4 workers is the largest
(+23.5%) were not investigated. The two Verify rows go the other way (fewer instructions on the M1 Max) and also
differ in mallocs (below): they spread over `activeProcessorCount` workers, 32 on the M3 Ultra and 10 on the M1 Max,
which is consistent with per-worker setup, not investigated. Wall-clock ratios for these 11 are not hardware-only.

Mallocs: identical except in the rows that start a worker per core: the 32 MB extracts go 271–275 → 131–135 (−51%),
and Verify 449 / 545 → 125 / 155 (−72%). Those rows use the default `maxConcurrency`, the processor count, so they
start 32 workers on the M3 Ultra and 10 on the M1 Max (fact from `ZipArchive+Extraction.swift`); that per-worker
allocation scales with it is the consistent reading, not checked.

### Observations

Measured:

- **Single-threaded work is a uniform 1.17–1.50 slower, geomean 1.30**: decoding (Bytes and zlib), CRC in cache,
  parsing, locating. 1.25 is the clock, so about 4% more per clock on the M3 Ultra. Within the group the spread is
  larger than rounding for a few rows: Stored + CRC 1.46 (both backends), Zstd text 1.50, parse with the original
  `ByteReader` 1.44. Interpretation, not checked: these touch more memory per instruction than the rest.
- **CRC-32 over 32 MB: 1.08 (Bytes), 1.32 (zlib) in the idle re-run `m1max-2`.** The first run (`m1max`) measured
  2.38 and 1.72 (1,354 and 1,445 µs) while `corespotlightd` and `mediaanalysisd` were using the machine; memory-bound
  work is the most sensitive to that. Re-run on an idle machine Bytes took 616 µs (53 GB/s; the M3 Ultra
  569 µs, 59 GB/s), and a standalone probe of `CRC32.checksum` on 32 MB measured 58 GB/s, 4–8 MB 62 GB/s: the
  PMULL fold is not memory-bound on one M1 Max core at this size. (An earlier reading of this row as a one-core
  memory bandwidth gap was wrong.) Every other row reproduced within 1% (geomean 0.988 over 40 rows, 5 rows beyond
  ±10%: the file-creation floors, +15% to +29%, and open + extract +10%).
- **Small-file extraction scales differently with workers** (extract 2,000 small files, ms):

  | Workers | 1 | 2 | 4 | 8 |
  |---|---|---|---|---|
  | M3 Ultra | 192 | 104 | 64 | 75 |
  | M1 Max | 255 | 138 | 106 | 81 |
  | Ratio | 1.33 | 1.33 | 1.66 | 1.08 |
  | Speedup over 1 worker (M3 / M1 Max) | | 1.85 / 1.85 | 3.00 / 2.41 | 2.56 / 3.15 |

  On the M3 Ultra the fastest is 4 workers and 8 is 17% slower (the APFS contention step2 and AGENTS.md describe).
  On the M1 Max 8 is fastest and 4 is still 31% slower than 8, so no peak shows up by 8; the default
  (`fileCreationWidth` 8) is the best of the four on this machine too. At 8 the two machines are 1.08 apart: the M3
  Ultra is at its contended end, the M1 Max isn't there yet. With instruction counts differing in all four rows, treat
  the 4-worker point (1.66) with the most care.
- **The single-thread file-creation floor has one of the highest ratios** (above the 1.30 decode group): Floor create + write
  1.51 (+34% instructions), `openat` 1.39, against 1.10–1.17 for whole extractions at the default workers (8 on
  both). So the M1 Max loses more on one thread's system calls than on the full pool, where, as measured, the
  M3 Ultra is the one contending. Floor times are 66 µs a file on the M3 Ultra, 100 µs on the M1 Max.
- **Parallel verify 1.72–1.76** (decode of 2,000 small files over `activeProcessorCount` workers: 32 and 10). The
  serial equivalent (Inflate + CRC 2,000 small files, Bytes) takes 14 and 18 ms: the parallel run is 5.3x faster than
  it on 32 workers and 3.9x on 10 (rounded inputs, ±10%). The ratio sits between the per-core ratio (1.3) and the
  core ratio (24 P / 8 P = 3.0). Interpretation: with 2.7 to 4.6 ms of wall time a fixed task-start and join cost
  matters; not measured.
- **Large entries**: Extract 32 MB text and random are 1.20–1.35 and Open + extract the same: one big entry is a
  pipelined decode and write and tracks the single-core ratio.

Not done: no per-machine syscall counts (`Tools/runtime-count`, System Call Trace) to explain the instruction
differences; no run with `maxConcurrency` pinned to the same value on both machines for Verify and the 32 MB extracts;
the 1 ms rounding of the larger rows limits every ratio above to about ±5%.

## baseline — the code before any performance work

`OutputFilter` (Compression.framework) decoding with a new 1 MB buffer + `Data` per chunk, `FileManager`
for attributes and existence checks, `mkdir` for every path component of every file, all serial.

| Benchmark | Wall | Instructions | Mallocs |
|---|---|---|---|
| Parse central directory (2,000 entries) | 287 µs | 6.1 M | 2,290 |
| Inflate + CRC 32 MB text | 33 ms | 359 M | 48 |
| Stored + CRC 32 MB random | 5.5 ms | 62 M | 41 |
| Inflate + CRC 2,000 small files | 48 ms | 470 M | 18 K |
| Extract 2,000 small files | 306 ms | 4,012 M | 129 K |
| Extract 32 MB text | 37 ms | 382 M | 146 |
| Extract 32 MB random | 8.4 ms | 84 M | 139 |

## step1 — zlib decoder, zero-allocation decoding, cheaper filesystem work, parallel workers

- `ZipDecoder`: reusable zlib `inflate` state (`inflateReset` per entry) and a single 1 MB output buffer,
  handing out `RawSpan`s. zlib inflate measured 2.3x faster than Compression's (`Backend:` benchmark: 30 ms
  vs ~13 ms for the same 32 MB payload).
- Output callback takes `RawSpan` instead of `Data`; stored entries are passed straight from the mapped archive.
- `DirectoryCache` (one `mkdir` per directory per extraction), `fchmod`/`futimens` on the open descriptor
  instead of `FileManager.setAttributes`, `FilePath.stat` only when the overwrite policy needs it.
- Files extracted by a pool of child tasks (`withThrowingDiscardingTaskGroup` + atomic work queue,
  largest first), one decoder per worker.

| Benchmark | Wall | Instructions | Mallocs |
|---|---|---|---|
| Parse central directory (2,000 entries) | 295 µs (+3%) | 6.1 M | 2,290 |
| Inflate + CRC 32 MB text | 14 ms (−58%) | 218 M (−39%) | 1 |
| Stored + CRC 32 MB random | 2.6 ms (−52%) | 31 M (−50%) | 0 |
| Inflate + CRC 2,000 small files | 15 ms (−69%) | 217 M (−54%) | 0 |
| Extract 2,000 small files (32 workers) | 333 ms (**+9%**) | 5,490 M (+37%) | 14 K (−89%) |
| Extract 2,000 small files (1 worker) | 230 ms (−25%) | 3,020 M (−25%) | 14 K (−89%) |
| Extract 32 MB text | 17 ms (−54%) | 239 M (−37%) | 44 |
| Extract 32 MB random | 5.7 ms (−32%) | 51 M (−39%) | 44 |

Finding: parallel small-file extraction used 1.75 s of CPU for 333 ms of wall time — 32 workers creating
files in the same directories contend in the kernel. Serial is faster. Next: find the right width.

### Width experiment (2,000 small files, step1 code)

| Workers | 1 | 2 | 4 | 8 | 32 |
|---|---|---|---|---|---|
| Wall | 215 ms | 152 ms | 113 ms | 106 ms | 311 ms |
| CPU | 215 ms | 263 ms | 327 ms | 490 ms | 1,637 ms |

Floor (`Floor: create + write 2,000 files`, raw `open`/`write`/`close`, no decoding, 1 thread): 167 ms,
~1 M kernel instructions per file. Claiming contiguous archive-order batches (so workers stay in
different directories) changed nothing (8 workers: 110 ms), so the contention is filesystem-wide,
not per directory; reverted.

## step2 — cap file-creation width at 8 (plus one worker per ≥ 1 MB entry beyond that)

| Benchmark | Wall | Instructions | CPU |
|---|---|---|---|
| Extract 2,000 small files | 102 ms (−69% vs step1, **−67% vs baseline**) | 3,253 M | 483 ms |
| Extract 2,000 small files (1 worker) | 250 ms (noise: ±10% run to run) | 2,991 M | 250 ms |
| Verify 2,000 small files (parallel, 32 workers) | 4.8 ms (vs 15 ms serial) | 288 M | 25 ms |

Everything else unchanged within noise.

## step3 — own `mmap` (`MappedFile`) and pipelined writes for large deflated entries

- `MappedFile` replaces `Data(contentsOf:options: .alwaysMapped)`: a `Sendable` class owning the mapping,
  exposing `bytes: RawSpan` (`@_lifetime(borrow self)`) and a stable pointer for async decode loops.
- `ZipDecoder.inflatePipelined`: two 1 MB buffers; chunk N is written in a child task
  (`withThrowingTaskGroup`) while chunk N+1 inflates. Used for deflated entries ≥ 4 MB.

| Benchmark | step2 | step3 |
|---|---|---|
| Extract 32 MB text | 17 ms | 15 ms (−12%) |
| Extract 32 MB random | 6.2 ms | 4.3 ms (−31%, from the mapping change) |

## step4 — no per-entry allocations; `sending` instead of `@unchecked Sendable`

- A local func passed as a closure boxed its captured `crc`/`written` vars on the heap: 2 mallocs per
  entry. Closure literals keep them on the stack.
- The pipelined `Chunk` is no longer `@unchecked Sendable`; it's sent to exactly one child task, with
  the single opt-out (`nonisolated(unsafe) let`) at the send site, since it points into the decoder's buffer.

| Benchmark | step3 | step4 |
|---|---|---|
| Inflate + CRC 2,000 small files | 4,001 mallocs | **1** (the harness's own) |
| Inflate + CRC 32 MB text | 3 mallocs | 1 |
| Stored + CRC 32 MB random | 3 mallocs | 1 |

Times unchanged (allocation was never the bottleneck there; now it's provably absent).

### Experiments that didn't pay off

- `openat` relative to cached directory descriptors (skip absolute-path resolution): floor 142 → 133 ms
  (−6%). Path lookup isn't where the time goes; file creation is. Not adopted.
- `@inlinable` on the public entry points (`contents(of:using:_:)`, `contents(of:_:)`, `isEncrypted`):
  removing it changed instructions by < 0.3% and wall time within noise, because each call does a whole
  entry's work. Kept (no cost), but not pushed deeper: that would expose zlib/parsing internals as
  `@usableFromInline` for no measured gain.

## Benchmark summary: baseline → step4

| Benchmark | baseline | step4 | Change |
|---|---|---|---|
| Extract 2,000 small files | 306 ms | 105 ms | −66% |
| Extract 32 MB text | 37 ms | 15 ms | −59% |
| Extract 32 MB random | 8.4 ms | 4.3 ms | −49% |
| Inflate + CRC 32 MB text | 33 ms | 14 ms | −58% |
| Inflate + CRC 2,000 small files | 48 ms / 18 K mallocs | 15 ms / 0 per entry | −69% |
| Stored + CRC 32 MB random | 5.5 ms | 2.7 ms | −50% |
| Extract 2,000 small files: mallocs | 129 K | 14 K | −89% |

## End-to-end CLI comparison (hyperfine, 5 runs, warm cache)

Same archives as the first comparison: SDK headers (3,460 files → 7.4 MB), 188 MB text (→ 30 MB),
200 MB random (stored). `nunzip` before = the pre-optimization release build.

| Job | unzip | ditto | nunzip before | nunzip now | now vs before | now vs unzip |
|---|---|---|---|---|---|---|
| Extract headers.zip | 564 ms | 771 ms | 492 ms | **150 ms** | 3.3x | 3.8x |
| Extract text.zip | 802 ms | 119 ms | 200 ms | **106 ms** | 1.9x | 7.6x |
| Extract random.zip | 763 ms | 45 ms | 69 ms | **39 ms** | 1.8x | 19.7x |
| Test headers.zip (`-t`) | 158 ms | — | 83 ms | **15 ms** | 5.4x | 10.2x |
| Test text.zip (`-t`) | 770 ms | — | 184 ms | **99 ms** | 1.9x | 7.8x |
| Test random.zip (`-t`) | 739 ms | — | 46 ms | **28 ms** | 1.6x | 26.1x |

`nunzip` is now faster than `ditto` on all three (it was 1.6x slower on the large files).

## step5: parsing with the Bytes package (`../Bytes`)

`ByteReader` replaced by `Bytes` for the central directory, EOCD/ZIP64 records, and local headers:
fixed-size headers are read as sub-cursors (one bounds check per record instead of one per field),
signatures are `Byte4` literals, and the EOCD search uses `lastByteOffset(of:)` (16-byte SIMD). The
original parser is kept in `ZipArchive+ByteReaderParsing.swift`, behind `@_spi(Benchmarking)`, so the two
run side by side; the benchmark setup checks they produce identical entries and payload ranges for every
fixture. Baselines: `pre-bytes` (fresh run of step4 code) and `bytes`.

| Benchmark (same run) | ByteReader | Bytes | Change |
|---|---|---|---|
| Parse central directory (2,000 entries, includes `String` names and `Date`s) | 279 µs, 5,861 K instr | 238 µs, 4,960 K instr | −15% |
| Locate 2,000 payloads (local headers) | 207 µs, 3,592 K instr | 202 µs, 3,396 K instr | −5% instr |

Decoding, CRC, and verification are unchanged (they don't parse). Extraction moved within its usual
run-to-run noise (±20%: the two `Floor:` benchmarks, which don't parse at all, moved −9% and −12% between
the same two runs); the ~50 µs saved per archive open is far below that. CLI regression archives behave as
before (Info-ZIP-identical trees; slip, absolute path, bad CRC, truncated, and non-zip inputs rejected).

## step6: DEFLATE decoding with Bytes (`Inflater`), against zlib

`Inflater` (Sources/NativeZip/Inflater.swift) is a DEFLATE decoder written with `Bytes`: block headers are
`Bit`/`Crumb`/`Bits<5>`/`Nibble` fields read from a `BitBuffer`, stored-block lengths are `Byte2`s with
`expect` for NLEN, Huffman tables are built by `HuffmanTable.build` with DEFLATE-specific packed entries,
and matches are `BytesWriter.copy(fromDistance:count:allowingOverrun:)`. `ZipDecoder(backend:)` picks it
(the default) or zlib, which stays for comparison (`nunzip --zlib`, `ExtractionOptions.backend`). Baseline
`bytes-inflate`.

| Benchmark (same run, p50) | Bytes | zlib |
|---|---|---|
| Inflate + CRC 32 MB text | 13 ms, 0 mallocs | 14 ms, 1 malloc |
| Inflate + CRC 2,000 small files | 14 ms, 0 mallocs | 15 ms, 1 malloc |
| Verify 2,000 small files (parallel) | 4.70 ms (a later run: 4.72) | 5.01 ms (a later run: 4.71) |
| Extract 32 MB text | 15 ms | 15 ms |
| Extract 2,000 small files | within noise (127–161 ms, both) | |

By stream shape (`swift test -c release --filter PerfProbe`): literal-heavy data ties, default-level text
and fixed-code blocks are ~4% faster, long runs (distance-1 matches) 3.5x faster, stored blocks equal.
CLI (hyperfine, Bytes vs zlib): 320 MB text 148 vs 144 ms serial, 23.1 vs 22.5 ms parallel (noise);
20,000 small files 172 vs 176 ms serial, 51.9 vs 53.2 ms parallel.

Correctness: round trips of zlib output at every level and strategy, a 20,000-case mutation differential
against zlib (same output or both reject), and malformed streams.

### How it got from 2x slower to faster

The first version was 2x slower than zlib. In order of payoff:

1. **Inlining.** `@inline(__always)` is a hint, and the inliner refused it for the match copy ("not
   profitable", cost 263 against benefit 45); the call took the writer by address, which put it in memory for
   the whole loop. Splitting the decoder into small functions with their own local `BitBuffer` and
   `BytesWriter`, and marking the hot `Bytes` APIs `@inline(always)` (SE-0496, guaranteed), kept both in
   registers. `BitBuffer.init` had to be always-inlined too, so a literal bit order folds to a constant.
2. **Register-only refill.** The slow refill (near the end) took the fields `inout`, which kept them in
   memory on the fast path too; it now takes and returns values. Shift counts use `truncatingIfNeeded`,
   removing sign checks.
3. **libdeflate's table builder**: table building was 11% of small-file time. Codes are visited in
   canonical order with the bit-reversed code incremented directly, only the first `2^length` root entries
   are written, and they're doubled with `memcpy` at each longer length. Now `HuffmanTable.build` in Bytes.
4. **Shortening the critical path.** The next symbol's entry is looked up before the current one is used;
   the root lookup happens before the refill (11 bits are always buffered) and only the subtable step after
   it; after a length code, the distance is decoded from the bits already buffered while the refill and the
   match copy proceed. `totalBits` is masked to 6 bits in the entry so ARM's `lsr` takes the raw entry.
5. **Overrun copies.** Matches copy 16 bytes at a time (8 for distances under 16) and may write up to 32
   bytes past their end, kept free by the loop condition; distance 1 is a `memset`.

Tried and reverted: 8-byte steps for all distances, unrolled byte copies, exact copies for distances
under 32, decoding literal pairs from a combined table (small files 14 → 23 ms: building it costs more than
it saves on short blocks), an adaptive literal-run loop, and gathering literals into a word store.

## step7: safe constructs (baselines `pre-safety` → `safe-final`, `bytes` → `safe-parse`)

- **Inflater tables** moved from a raw allocation to a `[UInt32]` read through `Span`s. Every lookup is
  bounds-checked; `decodeSymbols` states the tables' sizes once (`precondition`), after which the masked
  root lookups' checks fold. Instruction counts identical (small files 238 → 239 M, 32 MB text 249 → 249 M).
- **Output** reaches the inflater as a `MutableRawSpan` rather than a buffer pointer. `ZipDecoder` creates it
  from its own buffers, which stay raw allocations: the pipelined path sends chunks of them to child tasks.
- **The code-length table and the table builder** are `Bytes`' `HuffmanTable`, now safe throughout.
- **`BitBuffer`'s refill load** stays unchecked: checked, DEFLATE took 10% more instructions.
- **Zip fields with Bytes' bit-field APIs**: the DOS date and time (`date[Bits<7>.self, at: 9]` …), the Unix
  mode (`attributes[bits: 16..<32]`), the directory attribute (`[bit: 4]`), and the host OS
  (`versionMadeBy[Byte.self, at: 8]`); saturation tests compare against `UInt16.max`/`UInt32.max`. Parsing
  the central directory is 1% fewer instructions (4,907 vs 4,960 K). `ZipEntry.isEncrypted` keeps its mask:
  it's public and inlinable, and `Bytes` is imported `internal`.
- **Remaining `unsafe`** has comments saying why: `mmap`/`munmap` (`MappedFile`), zlib's and
  Compression's C APIs, `symlink`/`mkdir`/`futimens`/`fnmatch`, System's buffer-pointer `writeAll`,
  `Data`'s buffer-pointer append, and the pipelined decoder's cross-task chunks.

## step8: native CRC-32 for the Bytes backend (baseline `native-crc`)

Entry verification uses each backend's own CRC: `Bytes`' `CRC32` with the `Bytes` decoder, zlib's
`crc32_z` with zlib's, so each backend is measured whole (`ZipDecoder.crc32(_:_:backend:)`, static so it
can run inside `inflate`'s callbacks). Stored entries follow the decoder's backend too. Direct
comparisons are `CRC-32 <size>: Bytes / zlib` and `Stored + CRC 32 MB random: Bytes / zlib`.

| Benchmark (p50) | Bytes | zlib |
|---|---|---|
| CRC-32 32 MB | 532 µs (63 GB/s) | 888 µs (38 GB/s) |
| CRC-32 256 KB, in cache (×128) | 460 µs | 833 µs |
| CRC-32 1 KB (×32 K) | 665 µs | 1,279 µs |
| CRC-32 64 B (×512 K) | 3,084 µs | 6,963 µs |
| Stored + CRC 32 MB random | 2.56 ms, 29 M instructions | 2.92 ms, 31 M |
| Inflate + CRC 32 MB text | 12.9 ms | 13.6 ms |
| Inflate + CRC 2,000 small files | 13.9 ms | 14.6 ms |

CRC is about 4% of inflating time, so the decode benchmarks move by less than their noise (instructions
−1%). How `CRC32` works is in Bytes' RESULTS.md.

## step9 (2026-11-09): current Bytes API, verified free (baselines `pre-modern` → `modern`)

Wall-clock times in `pre-modern` and the reruns below were taken while five agents shared the machine.
`modern` was re-run alone afterwards: against `native-crc`, instruction and allocation counts identical,
wall times a median change of 0.0% (at most +7%). Instruction counts, allocation counts, and codegen are
the evidence here. `pre-modern` is the step8 code rebuilt against today's Bytes (compute benchmarks only);
`modern` is the full suite.

**Changes kept**, each checked by disassembling the whole NativeZip object (release, `Tools/loops
--target`) before and after, with addresses and label numbers normalized. With all of them the object is
identical to step8's except for two `try!` line numbers in `Inflater.init`:

- Fixed-size records and the extra-field area are `readSection(byteCount:)` instead of
  `BytesReader(try reader.read(byteCount:))` (EOCD, central directory, directory entry, extra fields,
  local header).
- A stored block's NLEN is checked with `ByteGroup`'s `~`: `try stored.expect(~length)` on the `Byte2`.
- `HuffmanEntry`'s fields are Bytes bit-field subscripts (`raw[bits: 0..<6]`, `raw[Nibble.self, at: 8]`,
  `raw[bits: 16..<32]`), and its kind is the `Kind` enum through `init?(rawBits:)`
  (`Kind(rawBits: raw[Bits<3>.self, at: 12]) ?? .invalid`), so the decode loop switches on `.literal`,
  `.lengthOrDistance`, `.endOfBlock` instead of comparing raw values. Same code: the conversion folds.
- Two strict-memory-safety warnings in release builds fixed (`unsafe` on `UnsafeRawBufferPointer.isEmpty`
  in `ZipDecoder`).

**Tried and reverted:**

- Extra fields with `read(sectionPrefixedBy: Byte2.self, .littleEndian)` under `try?` (a field longer than
  what's left ends the list): central-directory parsing +0.7% instructions (4,891 K → 4,927 K); the
  explicit length check plus `readSection` measured 4,895 K. (Cause not isolated: `read(bytesPrefixedBy:)`
  checks the length twice, and `try?` builds an `Optional<BytesReader>`.)
- `HuffmanEntry.extra` as `bits[bits: codeLength..<totalBits]`: the range's checks can't fold with runtime
  bounds, so `decodeSymbols` grew from 995 to 1,026 lines with two more traps and more spills. Kept the mask
  and shift (an unchecked extract is proposed to Bytes).

| Benchmark (p50) | native-crc | pre-modern | modern |
|---|---|---|---|
| Inflate + CRC 32 MB text: Bytes / zlib, instructions | 247 M / 218 M | 247 M / 218 M | 247 M / 218 M |
| Inflate + CRC 2,000 small files: Bytes / zlib, instructions | 238 M / 214 M | 238 M / 214 M | 238 M / 214 M |
| Inflate + CRC, mallocs: Bytes / zlib | 0 / 1 | 0 / 1 | 0 / 1 |
| Verify 2,000 small files (parallel): Bytes / zlib, instructions | 315 M / 292 M | 315 M / 292 M | 315 M / 292 M |
| Stored + CRC 32 MB random: Bytes / zlib, instructions | 29 M / 31 M | 29 M / 31 M | 29 M / 31 M |
| CRC-32 64 B (×512 K): Bytes / zlib, instructions | — | 51 M / 61 M | 51 M / 61 M |
| CRC-32 32 MB: Bytes / zlib, instructions | — | 10 M / 13 M | 10 M / 13 M |
| Parse central directory (2,000 entries), instructions | 4,907 K (`safe-parse`) | 4,891 K | 4,911 K |
| Locate 2,000 payloads, instructions | 3,394 K (`safe-parse`) | 3,373 K | 3,373 K |
| Extract 32 MB text: Bytes / zlib, instructions | 271 M / 241 M | — | 271 M / 241 M |

The parse rows differ by 0.4% between runs of byte-identical code: they include `String`, `Date`, and
2,289 allocations per iteration, whose instruction counts vary. Times under load (for the record only):
inflating 32 MB of text 15 ms for both backends, CRC-32 Bytes 1.6–2.3x faster than zlib as in step8.

**Static checks of the decoder.** `decodeSymbols` keeps the bit buffer and writer in registers: its only
stack accesses are the prologue and spills around the cold calls. Those calls are: `BitBuffer._refillSlowly` (within 8 bytes
of the input's end), `memset` (distance-1 matches), and 13 throw sites, each calling
`_stdlib_isOSVersionAtLeastOrVariantVersionAtLeast` before `swift_willThrowTypedImpl` (typed throws'
back-deployment check, even with a macOS 27 deployment target; code size only). No retain, release,
allocation, or outlined copy in any Inflater function (`Tools/calls --callee
'swift_retain|swift_release|swift_allocObject|outlined'`).

**Where decode time goes** (`Tools/profile`, `nunzip -t` of a 2 GB text file, Bytes backend, leaf frames
with inlining): the match copy (`BytesWriter.copy`) 21%, literal stores (`BytesWriter.write`) 21%, the
entry-kind dispatch 18% (attributed to `Kind.init(rawValue:)`, now the source line of the compare), the
rest of `decodeSymbols` 16%, the refill (its load 8.5%, the rest 4.6%), masks 5.8%, CRC-32 2.1%, subtable
lookups 1.7%, table building < 1%. zlib's `inflate_fast` isn't symbolicated (system library).

**What bounds it** (`Tools/counters`, `nunzip -t` of 512 MB of text, worker thread):

| | cycles | useful | discarded | processing (back end) | delivery (front end) |
|---|---|---|---|---|---|
| Bytes | 1.70 G | 49% | 20% | 28% (92% of it executing, 1.4% memory misses) | 2.5% |
| zlib | 1.74 G | 41% | 31% | 21% | 7.3% (56% of it fetch bandwidth) |

The Bytes decoder runs 13% more instructions than zlib in 2.5% fewer cycles: it loses less to
mispredicted branches and front-end stalls. What remains is execution-bound (dependent shifts, loads, and
stores of the decode chain), not memory-bound, and the 20% discarded is the data-dependent branch on each
entry's kind, which Huffman decoding can't avoid.

Extraction of 2,000 small files varied ±15% in instructions and ±25% in time across three runs (kernel
contention; the decoder is under 10% of it), so its Bytes-vs-zlib differences in this run are noise.

## step10 (2026-11-09): short-distance matches as runs (baselines `fu3-old-*` → `fu3-new-*`)

Bytes' `copy(fromDistance:count:allowingOverrun:)` copied matches fewer than 8 bytes back a byte at a time,
each byte waiting on the one stored just before it. It now repeats the last `distance` bytes with 16-byte
stores (one load, a pattern built with two multiplies), out of line so the decode loop doesn't carry it
(see `../Bytes/Benchmarks/RESULTS.md`). No NativeZip source changed.

The text fixtures barely have such matches, so the benchmarks gained one that does: **32 MB of pixel runs**
(`Fixtures.raster`: runs of 1–40 identical 2- to 7-byte pixels, the width changing every 4 KB; `zip`
codes each run as one pixel of literals and a match one pixel back). Fixtures are now version 2 (a new
cache directory, regenerated on first use). Interleaved runs of the tree before and after, two rounds:

| Benchmark | Instructions | Time (round 1 / round 2) |
|---|---|---|
| Inflate + CRC 32 MB raster: Bytes | 227 → 141 M (−38%) | 18 → 10.0 / 18 → 9.2 ms (−49%) |
| Inflate + CRC 32 MB raster: zlib | unchanged | 9.8 ms |
| Inflate + CRC 32 MB text: Bytes | +0.0% | 13 ms, unchanged |
| Inflate + CRC 2,000 small files: Bytes | +0.1% | 14–15 ms, unchanged |

On pixel runs the Bytes decoder was 1.8x zlib's time; now it's level with it. The first version inlined the
short-distance path into `decodeSymbols`: the loop grew from 743 to 853 instructions, and text and small
files took 12–14% more instructions. Out of line (with distance 1 back as the inline `memset` it was), the loop is 722 and they're unchanged.

## step11 (2026-11-09): cursors created at their offsets (baselines `pos-old-*` → `pos-new-*`)

`BytesReader(archive, atByteOffset: entry.localHeaderOffset)` instead of a reader and `seek(toByteOffset:
Int(clamping: …))` (5 sites: central directory, EOCD, ZIP64 locator and record, local header; the
`UInt64` offsets go in as they are), and in the inflater `BitBuffer(input, atBitPosition:bitOrder:)` and
`BytesWriter(&output, atByteOffset:)` instead of a reader, `seek(toBitPosition:)`, `BitBuffer(reader)`,
`BytesWriter(output._mutatingExtracting(...))`, and `skip(byteCount:)`.

Whole functions: `decodeSymbols` 789 → 769 instructions, `readBlockHeader` 296 → 265 (shorter throw paths). The Bytes
writer initializer had to be `@inline(__always)`: as an out-of-line call it grew `decodeSymbols` to 891.

| Benchmark | Instructions | Time (rounds 1 / 2) |
|---|---|---|
| Inflate + CRC 32 MB raster: Bytes | 141.1 → 139.4 M (−1.2%) | −1.2% / −1.3% (9.1 ms; zlib 9.9) |
| Inflate + CRC 32 MB text, 2,000 small files: Bytes | −0.0% | unchanged |
| Locate 2,000 payloads | −0.3% | −0.5% / −2.1% |
| Parse central directory (2,000 entries) | −0.0% | −2.5% / −1.3% |

## step12 (2026-11-09): extra fields with `readSectionIfComplete` (baselines `bcd-old-*` → `bcd-new-*`)

The extra-field loop's `size` read, `guard size <= extra.remainingByteCount`, and `readSection(byteCount:)`
became `guard var field = extra.readSectionIfComplete(prefixedBy: Byte2.self, .littleEndian) else { break }`.
It's simpler, but not faster here: parsing the central directory took +0.2% instructions (4.9004 → 4.9096 M,
about 5 per entry) and +1.7% time in both rounds, though the same call measured 14% cheaper than the
hand-written form in Bytes' own benchmark. `readCentralDirectoryEntry` shrank from 488 to 466 instructions.
Bytes' inlined `write(_: RawSpan)` reaches the stored-block copy (`Inflater.decode` 227 → 268
instructions); the inflate benchmarks are unchanged (±0.5%).

## step13 (2026-11-10): Bytes' conveniences (baselines `conv-old-*` → `conv-new-*`)

- `Inflater`: the extra bits with the unchecked `bits.bits(from: codeLength, upTo: totalBits)`, the root
  lookup with `bits.bits(from: 0, upTo: rootBits)`, `BFINAL` with `bits.read(Bool.self)`.
  `decodeSymbols` is the same 769 instructions as before.
  - Not the subtable index: `bits.bits(from: rootBits, upTo: rootBits &+ codeLength)` masks before
    shifting, which needs the sum, and grew `decodeSymbols` by 5 instructions. It keeps the shift-then-mask
    expression, with a comment.
- `ZipArchive`: the extended timestamp with `readSigned(Byte4.self, .littleEndian, as: Int32.self)`.
- `ZipDecoder`: `CRC32.checksum(bytes, continuing:)` (`crc32` 21 → 14 instructions), and
  `output.append(copying: chunk)` for the inflated output.
- Kept: `readSectionIfComplete` for extra fields (it tolerates a truncated last field, as zip readers must;
  Bytes' new `forEachRecord` throws on one), and the strings in `ZipError` (no `located(_:)`).

| Benchmark | Instructions | Time (rounds 1 / 2) |
|---|---|---|
| Parse central directory (2,000 entries) | 4.8938 → 4.8929 M (−0.02%) | −1.5% / −0.8% |
| Locate 2,000 payloads | −0.3% | +0.1% / +0.3% |
| Inflate + CRC (2,000 small files, 32 MB text, 32 MB raster), Bytes | within ±0.03% | −0.7 to −6% |
| The same with zlib, and the original `ByteReader` rows (controls) | within ±0.3% | −0.6 to −6%, +3.8% |

No change in instructions, as the codegen check predicted; the time differences are the same size in the
controls.

## step14 (2026-11-17): named fields, macro records, `Data` from spans (baselines `trk-t0` → `trk-final`, Swift 6.4.4)

- **The Huffman entry's fields by name** (`HuffmanEntry.totalBitsField` and so on, Bytes' `BitField`): the decode
  loop went from 246 to 236 instructions (fewer moves), and inflate + CRC runs −2.8% (32 MB text, 247 → 240 M
  instructions) and −2.5% (2,000 small files, 238 → 232 M).
- **The central directory header as a `@BinaryRecord`** (`ZipRecords.swift`, with `DOSDate`/`DOSTime` and the
  extended timestamp's flags as `@BitFields`), read in one call: 4,887 → 4,907 K instructions (+0.4%), the same
  move as "Locate 2,000 payloads", whose code didn't change (layout). Name decoding dominates this parse.
- `LittleEndianBytesReader` throughout, `read(byteCount:)` taking the `UInt64` sizes directly (no `Int(clamping:)`),
  and `contents(of:)` appending chunks with Bytes' new `Data.append(_: RawSpan)` (BytesFoundation): unchanged.

## step15 (2026-11-17): arbitrary archives, unzip's options, one pool for every archive (baselines `nz-before` → `nz-after3`)

`nunzip` now reads what other tools write, takes Info-ZIP unzip's options, and extracts any number of archives
with one pool of workers that starts writing while the archives are still being planned.

**Formats** (`TestData/nativezip-formats`, made by `Tests/NativeZipTests/Fixtures/formats/make-fixtures.sh`
through `Tools/test-data fetch` with Python's `zipfile`, Info-ZIP `zip`, and `bsdtar`; every entry's CRC-32 comes
from the tool that wrote it):

- Methods: stored, deflated, **Deflate64** (`Inflater` in a second mode: a 64 KB window, length symbol 285 with 16
  extra bits, distance codes 30 and 31; its own `@inline(never)` copy of the symbol loop, which refills between the
  length and the distance), **bzip2** (the SDK's libbz2, `CBZip2` system-library target), **LZMA** (a decoder in
  Swift, `LZMADecoder.swift`, no `unsafe`, ~115 MB/s on text, level with `xz -d`), **xz** (Compression's
  `COMPRESSION_LZMA` stream). zstd (93), PPMd (98), and the 1980s methods (shrink, reduce, implode) are reported as
  unsupported (exit 81).
- Encryption: traditional PKWARE ("ZipCrypto", checked against the CRC's or, with a data descriptor, the time's high
  byte) and **WinZip AES** 128/192/256, AE-1 and AE-2 (CommonCrypto: PBKDF2-HMAC-SHA1, AES-ECB over little-endian
  counter blocks, the HMAC checked before anything is decrypted). Payloads are decrypted whole into a buffer the
  decoder owns (freed after entries over 64 MB). PKWARE's strong encryption is unsupported.
- Archives with data before them (self-extractors, `cat stub a.zip`): offsets are corrected by where the directory
  really is (`leadingByteCount`, Info-ZIP's "extra bytes at beginning" warning), also for ZIP64 records.
- Central directories holding more entries than their 16-bit count (wrapped past 65,535 without ZIP64 records).
- Names: Info-ZIP's Unicode path field (0x7075, used when its CRC matches the header's name), backslashes from
  MS-DOS/NTFS/VFAT hosts, macOS hosts' (19) Unix modes. Timestamps from the NTFS (0x000A) and old Info-ZIP Unix
  (0x5855) fields when there's no extended timestamp; UID/GID (0x7875, 0x5855) for `-X`.

**Extraction** (`ZipExtractor`):

- Unsafe names are made safe as Info-ZIP does instead of failing the whole extraction: a leading `/` and `..`
  components are removed, with its warnings.
- Entries that land on one item (the same name twice, or names a case-insensitive volume folds together) follow
  the overwrite policy against the earlier entry: the later replaces it (`-o`), or is skipped (`-n`), or the user is
  asked. Before, both were written concurrently.
- A failing entry no longer stops the others; failures are reported at the end with Info-ZIP's exit codes (2, 81
  unsupported, 82 password). Unreadable entries (unsupported method or encryption, no password) fail during planning,
  before they're announced.
- Setuid, setgid, and sticky bits are cleared unless `-K` (Info-ZIP's default; they were applied before).

**Options**: `-l -v -t -p -c -z -T`, `-f -u`, `-o -n`, `-j -C -L/-LL -D/-DD -X -K -q/-qq`, `-P` (or a prompt,
three tries, checked against the first encrypted entry), `-x`, `-d`; the archive may be a quoted wildcard, and
`.zip`/`.ZIP` are tried; `--jobs N`; `--zlib`. Several archives get Info-ZIP's per-archive headers and summary.

### Parallelism

`ZipExtractor.extract(maxConcurrency:stopOnFirstError:_:)` starts the workers, then runs the planning closure
(open archives, select entries, prompt, create directories, resolve collisions, report events). Each planned file
is queued at once: large ones (1 MB or more) largest first, small ones in order. Eight workers take anything; the
rest (up to `--jobs`, default all cores) take only large files, which keeps the measured width rule (8 for file
creation, one per large entry beyond that) without knowing the counts in advance. A file replacing one that's
already being written waits until the pool is done. Symbolic links follow every file, then directory metadata,
deepest level first, each level in parallel.

What was measured on the way (hyperfine, warm cache, output in a `.noindex` directory so Spotlight doesn't index
it, M3 Ultra, macOS 27.2.1):

- **Pool width** for small files (20,000 files of 1–8 KB): 4 workers 708 ms, 8 728 ms, 12 891 ms, 16 1,386 ms,
  24 2,192 ms; CPU time 2.3, 4.1, 6.1, 9.2, 12.9 s. For 2,000 files of 256 KB: 152, 115, 115, 129, 151 ms. File
  creation still caps out at about 8; kept.
- **Where small-file time goes** (Time Profiler, worker threads): `open` 45%, `write` 19%, `close` 13%, `futimens`
  11%, `fchmod` 7%, decoding about 2%. The times and mode now go in one `fsetattrlist` call: −6% CPU, wall within
  noise. Skipping timestamps entirely (`-DD`) saves 3%.
- **One large stored file** (1 GB): checksumming it whole and then writing it whole read it from memory twice
  (253 ms). In 8 MB pieces, each checksummed and then written while in cache: 180 ms. Writing the pieces in
  parallel gained nothing (1, 4, and 24 writers: 178–180 ms; the kernel serializes writes to one file), and copying
  into a shared mapping of the destination was slower (4 threads 246 ms, 24 threads 571 ms). Pieces, sequential.
- **Planning was serial and ahead of every write**: 60–73 ms for 20,000 entries. `FileJob` as a class (copies of the
  struct, which holds resilient `Date?`s, went through value witnesses), collision keys from the short relative
  path, and the directory cache remembering the last directory: 46–57 ms. Then overlapping it with the writes
  (above) took the rest off the wall clock.
- The CRC-32 of pipelined entries (compressed, 4 MB or more) moved from the decoding task to the writing task.

| Job | unzip | ditto | nunzip before | nunzip now | change |
|---|---|---|---|---|---|
| SDK headers (3,700 items) | 520 ms | 700 ms | 156 ms | **130 ms** | −17% |
| 20,000 files of 1–8 KB | 2,170 ms | 3,416 ms | 656 ms | **542 ms** | −17% |
| 2,000 files of 256 KB | 2,485 ms | 686 ms | 125 ms | **112 ms** | −10% |
| 512 MB of text, one entry | 2,282 ms | 324 ms | 272 ms | **259 ms** | −5% |
| 1 GB stored, one entry | 3,990 ms | 174 ms | 254 ms | **209 ms** | −18% |
| 16 archives, 1,000 files each | 3,973 ms | — | 953 ms (in turn) | **731 ms** | −23% |
| 8 archives, one 64 MB text file each | 2,285 ms | — | 339 ms (in turn) | **73 ms** | 4.6x |

(Means of 5–7 runs; run-to-run noise ±2–20 ms, more with the machine's load average of 3–4 at the time. "Before"
handled one archive per run, so several archives ran in a shell loop.) Trees match Info-ZIP's byte for byte,
with the same permissions and modification times.

What stays serial: one DEFLATE stream decodes on one core (the 512 MB entry: ~2 GB/s), and planning (now overlapped).
Splitting a single DEFLATE stream across cores (finding block boundaries and resolving back-references across
chunks, as rapidgzip does) is the next step for archives of one huge entry.

**Package benchmarks** (instructions; decoding unchanged):

| Benchmark | nz-before | nz-after3 | change |
|---|---|---|---|
| Inflate + CRC 32 MB text / raster (Bytes, zlib) | — | — | ±0.0% |
| Inflate + CRC 2,000 small files: Bytes | 232 M | 233 M | +0.4% (dispatch by method per entry) |
| Verify 2,000 small files (parallel) | 309 M | 315 M | +1.9% |
| Stored + CRC, Locate 2,000 payloads | — | — | ±0.0% |
| Parse central directory (2,000 entries) | 4,887 K | 6,038 K | +24% |
| Parse central directory: original ByteReader | 5,857 K | 6,390 K | +9% |

Parsing costs about 575 instructions more per entry for the larger `ZipEntry` (encryption, owner, host, DOS time;
the shared `makeEntry` is inlined into both parsers, hence the reference parser's rise too) and the new extra fields.
Reading Info-ZIP's 4-byte UID/GID directly, not byte by byte, took back 300 per entry (6,644 → 6,038 K). That's
0.6 ms to open a 2,000-entry archive.

## step16 (2026-11-18): parsing cost recovered, native encryption, streamed decryption, Zstandard (baselines `d2-start` → `d2-zip3`, Swift 6.4.4)

- **Parsing:** `ZipEntry` stores the DOS time as a `Double` (NaN for none) and the permission bits as a `UInt16`;
  `modificationDate` and `posixPermissions` are computed. The time conversion is out of line; `makeEntry` builds
  file types from octal constants. 6,062 → 4,297 K instructions for 2,000 entries (−29%), 342 → 189 µs.
- **Encryption in Swift, no CommonCrypto:** ZipCrypto (`TraditionalCipher`), WinZip AES (`WinZipAES`: PBKDF2-SHA1,
  HMAC-SHA1, AES-CTR with WinZip's little-endian counter) on BytesCrypto's AES (ARM's `aese`/`aesmc` through a C
  header, constant-time bitsliced S-box otherwise), SHA-1, HMAC, and PBKDF2. PBKDF2 runs 2.6x CommonCrypto's speed;
  AES-CTR equals it (`../Bytes/Benchmarks/RESULTS.md`).
- **Streamed decryption:** encrypted entries decrypt in pieces into a 256 KB staging buffer as the decompressor takes
  input (DEFLATE through BytesCompression's streaming decoder, bzip2, xz, Zstandard), or straight into the output
  buffer (stored): no entry is held whole in memory. AES checks the whole payload's MAC before any output. (Deflate64
  and LZMA, whose decoders read their whole input, still decrypt into one buffer.) The staging buffer and streaming
  decoder are made on the first encrypted entry: workers that never see one don't allocate them.
- **Zstandard (method 93):** BytesCompression's `ZstdDecoder` (1.12–1.45x libzstd 1.5.7's speed on Silesia; see
  `../Bytes/Benchmarks/RESULTS.md`). Entries up to 1 MB decode in one call straight into the output buffer (no window,
  no copy); larger or encrypted ones stream through the decoder's window. Tests: `zstd.zip`, a 5 MB entry, and the
  same ZipCrypto-encrypted (made by `make-fixtures.py`, which now writes ZipCrypto itself); `ppmd.zip` (method 98) is
  the unsupported method now.
- **Extraction:** `relativePath` has a fast path for clean names; claimed names hash ASCII case-folded without making
  strings (`ClaimKey`); a file's parent directory isn't re-created for consecutive files; the job queue and chunk
  hand-off use unsafe continuations behind a `Mutex`, one consumer task per entry instead of one per chunk.

Instructions and mallocs (exact); times are one run while other builds ran (±10%):

| Benchmark | d2-start | d2-zip3 | Change |
|---|---|---|---|
| Parse central directory (2,000 entries), instructions | 6,062 K | 4,297 K | −29% |
| Parse central directory, time | 342 µs | 189 µs | −45% |
| Locate 2,000 payloads, instructions | 3,377 K | 3,293 K | −2.5% |
| Verify 2,000 small files (parallel), instructions | 314 M | 266 M | −15% |
| Verify 2,000 small files (parallel), time | 6.0 ms | 2.7 ms | −56% |
| Extract 2,000 small files, mallocs | 38 K | 15 K | −61% (19 → 7.5 per file) |
| Open + extract 2,000 small files, instructions | 3,035 M | 2,907 M | −4.2% |
| Extract 32 MB text, mallocs | 400 | 267 | −33% (setup only) |
| Inflate + CRC (any), mallocs per iteration | 0 | 0 | — |

Zstandard against DEFLATE on the same 32 MB (the `zstd` command at level 3; DEFLATE from `/usr/bin/zip`, level 6):

| 32 MB | Inflate + CRC (Bytes) | Inflate + CRC (zlib) | Zstd + CRC |
|---|---|---|---|
| Text, instructions / time | 240 M / 13 ms | 218 M / 13 ms | 379 M / 18 ms |
| Raster, instructions / time | 138 M / 9.3 ms | 91 M / 11 ms | 141 M / 10 ms |

The synthetic text (30 words in random order) inflates unusually cheaply, 7.5 instructions a byte; zstd's 11.8 is in
line with its Silesia figures (dickens L3: 13.4, against libzstd's 14.9). Not measured here: zstd against DEFLATE on
real corpora; these fixtures may favor DEFLATE. `Zstd + CRC`'s 3 mallocs are the decoder's tables, window, and
input stash, made on the first zstd entry inside each measured sample (the benchmark creates its `ZipDecoder` there);
a probe decoding the entry 2 and 4 times in one process counted the same allocations (`Tools/runtime-count`).

## step17 (2026-11-22): every method in Swift (baselines `zipnative-old-{1,2}` → `zipnative-new-{1,2}`, M1 Max)

Every compression method now decodes with BytesCompression; the library and `nunzip` no longer link zlib, Compression,
or libbz2. Gone: NativeZip's own `Inflater` (DEFLATE and Deflate64) and `LZMADecoder`, the CBZip2 system-library
target, the zlib backend (`ZipDecoder.Backend`, `--zlib`, `backend:` parameters), and whole-payload decryption.

- DEFLATE and Deflate64: `DeflateDecoder(variant:)` and its new `decompress(_:into:historyCount:)`, which decodes
  straight into ZipDecoder's two buffers after the history copied to their front (as `Inflater` did).
- bzip2 (method 12): `BZip2Decoder.decompress(_:into:)`, streaming, output resumable mid-block (was libbz2).
- LZMA (14): `LZMADecoder` (raw LZMA1, streaming, 20 bytes of input at most to progress); NativeZip parses the 4-byte
  zip header and the properties. With the end-marker flag the decoder gets no size (the marker is required) and the
  output is capped at the entry's size.
- xz (95): `XZDecoder`, streaming (was Compression's `COMPRESSION_LZMA` stream).
- Encrypted entries of every method now stream through the 256 KB staging buffer (Deflate64 and LZMA used to be
  decrypted whole first): every decoder takes input split anywhere.
- The `zlib` benchmark rows now measure zlib's `inflate` and `crc32_z` directly (the backend is gone); the zlib
  extraction rows were dropped. New rows: `Inflate + CRC 32 MB text` and `Extract 32 MB text` for bzip2, LZMA, xz,
  and Deflate64 (the Deflate64 fixture is `text.zip`'s DEFLATE stream marked method 9: it has no 258-byte match, so it
  decodes the same either way).

Measured on the M1 Max (not comparable with the M3 Ultra rows above), HEAD's code with the new benchmark rows against
the new code, interleaved (old-1, new-1, old-2, new-2) on an otherwise idle machine. Instructions are exact; times are
p50 wall clock, the two rounds averaged.

| Benchmark | Instructions old → new | Change | Time old → new | Change |
|---|---|---|---|---|
| Inflate + CRC 32 MB text: bzip2 | 2,540 M → 1,534 M | −39.6% | 465 → 111 ms | −76% |
| Inflate + CRC 32 MB text: LZMA | 1,481 M → 1,334 M | −9.9% | 178 → 146 ms | −18% |
| Inflate + CRC 32 MB text: xz | 1,257 M → 1,352 M | +7.6% | 207 → 148 ms | −29% |
| Inflate + CRC 32 MB text: Deflate64 | 240 M → 237 M | −1.2% | 19 → 19 ms | 0 |
| Inflate + CRC 32 MB text: Bytes (DEFLATE) | 240 M → 236 M | −1.7% | 17 → 17 ms | 0 |
| Inflate + CRC 32 MB raster: Bytes | 138 M → 136 M | −1.4% | 12 → 11.5 ms | −4% |
| Inflate + CRC 2,000 small files: Bytes | 232 M → 232 M | 0 | 18.5 → 19 ms | (noise) |
| Extract 32 MB text: bzip2 | 2,568 M → 1,563 M | −39.1% | 476 → 114 ms | −76% |
| Extract 32 MB text: LZMA | 1,510 M → 1,364 M | −9.7% | 181 → 154 ms | −16% |
| Extract 32 MB text: xz | 1,287 M → 1,381 M | +7.3% | 212 → 153 ms | −28% |
| Extract 32 MB text: Deflate64 | 273 M → 268 M | −2.2% | 22 → 21 ms (2nd round) | −5% |
| Extract 8 archives of 64 MB text (one pool) | 4,383 M → 4,292 M | −2.1% | 164 → 133 ms | (±20%: parallel) |
| Zstd, stored, verify rows | unchanged | 0 | unchanged | — |

xz runs more instructions than Compression's liblzma and is still 29% faster (fewer mispredictions: Bytes' range
decoder takes bits from the borrow, see Bytes' RESULTS.md 2026-11-18). The cost is memory: LZMA and xz decode through a
sliding window of the dictionary plus as much room (an 8 MiB dictionary: a 16 MiB window, grown by doubling), so peak
resident memory for the one-entry rows went 26 → 58 MB (xz) and 35 → 52 MB (LZMA); bzip2 20 → 24 MB, DEFLATE
unchanged. Per writer, so an extraction of many large xz entries holds about 16 MiB per writer decoding one; a smaller
room trades memory for an extra copy of the dictionary per room's worth of output.
