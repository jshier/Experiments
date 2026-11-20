# NativeAEA performance log

M3 Ultra (24 performance and 8 efficiency cores), macOS 27.2, Swift 6.4.4, internal SSD, warm cache. Input: Xcode
27.3 beta 2 (`Xcode_27.3_beta_2.aea`, 2.17 GB; 10.46 GB of Apple Archive stream in 624 xz segments of 16 MiB; 167,541
entries). The format is in [FORMAT.md](FORMAT.md). Package benchmarks: baselines `aea-1` (Compression's decoder)
and `aea-2` (both decoders, the synthetic archive and Xcode's: `NATIVEAEA_ARCHIVE=…/Xcode_27.3_beta_2.aea`); the
synthetic archive is `Tools/test-data fetch nativeaea-synthetic`. The 2026-11-19 section compares these numbers with an
M1 Max's (baseline `m1max`).

## 2026-11-19: M1 Max against M3 Ultra (baselines `aea-2` → `m1max`, synthetic archive only)

> Read against the later sections: both baselines measured the pipeline on its own threads (commit 918278e), before the
> structured-concurrency rewrite and the memory pass below, and with the benchmark settings of that time. The benchmark
> file has since been reworked for runtime (2026-11-19): `Parse 170 headers: synthetic segment 0` is now `Parse
> headers: synthetic segment 0` (same work), and the extraction benchmarks extract each sample into its own directory
> with removal moved to teardown, so their times aren't comparable with `m1max` without a new run on that machine.

Every package's benchmarks were re-run on a new machine. Same macOS (27.2 / 27.2.1) and compiler (Swift 6.4.4,
Xcode 27.3); the hardware differs:

| | M3 Ultra (`aea-2`, 2026-11-18) | M1 Max (`m1max`) |
|---|---|---|
| Cores | 24 P + 8 E (`activeProcessorCount` 32) | 8 P + 2 E (10) |
| P-core clock | ~4.05 GHz | ~3.23 GHz (1.25x lower) |
| Memory | 256 GB, 819 GB/s | 64 GB, 400 GB/s |
| P-cluster L2 | not measured | 12 MB |

Method: one full run, `swift package --disable-sandbox benchmark baseline update m1max --no-progress`, nothing else
benchmarking, fixture `TestData/nativeaea-synthetic` (3.15 GB, 30,363 entries). `corespotlightd` used about one core
during the Bytes runs on this machine (it was indexing new files and couldn't be stopped), so treat the threaded rows
with extra care. Extractions go to `NSTemporaryDirectory()/NativeAEABenchmarks.noindex` on each machine's internal SSD
(different SSDs, not measured separately). The baseline has no Xcode rows (evidently run **without `NATIVEAEA_ARCHIVE`**), so the Xcode rows
(the table in 2026-11-18) have no M1 Max counterpart; only the 8 synthetic-archive timed benchmarks pair. The List and
Extract rows are the median of at most 5 and 3 iterations. Ratios are M1 Max time over M3 Ultra time (above 1 =
slower; the clock alone is 1.25).

### Thread counts

The benchmarks use `AEAReadOptions` and `AEAExtractionOptions` defaults (fact from the sources):

| Setting | Default | M3 Ultra | M1 Max |
|---|---|---|---|
| `decodeThreads` | `activeProcessorCount` | 32 | 10 |
| `extraBuffers` | 8 | 8 | 8 |
| `writerThreads` | 24 | 24 | 24 |
| `fileSystemWidth` (writers in file system calls) | 6 | 6 | 6 |

So decoding scales with the machine, but writers (24, including compression with `archived`) and file system width (6)
do not: on the M1 Max, 10 decoders and 24 writers share 10 logical CPUs. Nothing was tuned for the M1 Max.

### Headline

Geometric mean of the time ratio over the 8 paired benchmarks: **1.93**. It is two groups:

| Kind | n | Geomean | Rows |
|---|---|---|---|
| Single-threaded (decode one segment, open and verify, parse headers) | 4 | **1.20** | 1.36, 1.24, 1.13, 1.08 |
| Threaded (list, extract) | 4 | **3.10** | 3.01, 2.70, 3.28, 3.47 |

Same-code check: instruction counts exist only for the single-threaded rows (the threaded benchmarks record time,
CPU, and memory, not instructions or mallocs: the malloc interposer traps on thread exit). Both decode rows are
identical (1,132 M and 929 M), parse headers is identical (63 K), open and verify is −2.7% (3.29 M → 3.20 M), under 3%;
mallocs are identical (0, 0, 287). The M3 baseline was taken at a slightly earlier commit than HEAD, and for the
threaded rows no counter confirms the code is the same.

### Benchmarks

| Benchmark | M3 Ultra | M1 Max | Ratio | Instructions |
|---|---|---|---|---|
| Decode segment 0, Bytes decoder | 90 ms | 122 ms | 1.36 | 1,132 M, identical |
| Decode segment 0, Compression's decoder | 107 ms | 133 ms | 1.24 | 929 M, identical |
| Parse 170 headers (segment 0) | 3.50 µs | 3.79 µs | 1.08 | 63 K, identical |
| Open and verify | 218 µs | 246 µs | 1.13 | 3.29 M → 3.20 M (−2.7%) |
| List (decode, verify, parse), Bytes | 1.211 s | 3.645 s | 3.01 | not recorded |
| List, Compression | 1.460 s | 3.947 s | 2.70 | not recorded |
| Extract, `archived` (APFS-compressed) | 1.860 s | 6.094 s | 3.28 | not recorded |
| Extract, `none` | 1.261 s | 4.370 s | 3.47 | not recorded |

### Observations

Measured:

- **One thread: 1.08–1.36, geomean 1.20**, a little under the 1.30–1.34 geomeans of the Bytes, MQTT, and NativeZip
  suites. Two of the four are µs-scale rows (parse 3.5 µs, open and verify 218 µs), where a few hundred ns of
  timer or cache effect is ±8%. The segment decodes are the substantial ones: the Bytes
  decoder (the Swift LZMA2) is 1.36, Compression's 1.24, with identical instructions on both machines, so the Swift
  decoder loses more than the clock (1.25) going to the M1 Max and Compression's loses about the clock. Not
  investigated (the LZMA decoder is branch- and latency-bound; a different core's branch prediction and load-to-use
  latency could account for it).
- **Threaded rows 2.70–3.47**, geomean 3.10: about 2.6x the single-thread geomean. The P-core ratio is 3.0
  (24 against 8) and the P-core cycles ratio 3.76 (24 × 4.05 against 8 × 3.23 GHz). One-thread ratios of 1.2–1.36 times
  3.0 would be 3.6–4.1; list measures 2.7–3.0 and extract 3.3–3.5. Interpretation: perfect scaling on both machines
  would put the ratio near 3.6–4.1; list stays well below it (the M3 Ultra's 32 threads don't all pay off, or the
  M1 Max's 10 do better than that), and extract comes closer. The E cores and the read side (memory, one archive
  mapping) are not accounted for.
- **Extraction is the worse ratio**: archived 3.28 and none 3.47, against list 3.01 and 2.70. Extract minus list
  (difference of medians of separate benchmarks, Bytes decoder):

  | | M3 Ultra | M1 Max | Ratio |
  |---|---|---|---|
  | `none` minus list | 0.050 s | 0.725 s | 14x |
  | `archived` minus list | 0.649 s | 2.449 s | 3.8x |
  | `archived` minus `none` (compression) | 0.599 s | 1.724 s | 2.9x |

  Writing the files adds 4% to decoding alone on the M3 Ultra (1.261 against 1.211 s) and 20% on the M1 Max (4.370
  against 3.645 s). The compression of disk blocks (`archived` minus `none`) costs 2.9x as much on the M1 Max, about
  the P-core ratio, as CPU-bound work spread over the writers would. The 0.725 s `none` figure is what an extraction
  needs beyond decoding on the M1 Max.

  Interpretation, not measured: on the M3 Ultra the writers and six file system slots hide behind the decoders on
  idle cores; on the M1 Max, 10 decoders and 24 writers on 10 logical CPUs compete, and the walker thread with them.
  Per-thread running time (`Tools/tasks`) would say; it wasn't run. Whether `fileSystemWidth` 6 suits this SSD is open
  too: AGENTS.md has APFS peaking near 4 threads on the M3 Ultra, and it was not swept on the M1 Max.
- **Entries a second** (30,363 entries over the extract time, rough, directories included): `none` 24 K on the M3
  Ultra, 6.9 K on the M1 Max; `archived` 16 K and 5.0 K. Both are below the 46,000 small files a second AGENTS.md
  measured for APFS creation on the M3 Ultra, consistent with decoding 3.15 GB of LZMA2 being the larger cost on this
  archive on both machines (not separated here).

Not done: the Xcode archive (`NATIVEAEA_ARCHIVE=…`) on the M1 Max; CPU-total and peak-memory columns for the threaded
rows (they are in the baselines, but the comparison tool was run for time, instructions and mallocs only);
`decodeThreads`, `writerThreads` and `fileSystemWidth` sweeps for 10 cores; `Tools/tasks` and `Tools/counters` runs.

The command-line tool `unaea` is now `nunarchiver` (it also expands `.xip` files); entries before 2026-11-19 (xip) keep
the old name.

## 2026-11-19 (concurrency): structured Swift concurrency, and 190–270 MB less memory

The pipeline's threads, `NSCondition`s, `DispatchGroup`s, `DispatchSemaphore`s, `concurrentPerform` loops, and
`Task.detached` are gone: each operation is one task tree (the walker in the calling task; decoders, the block
producer, writers, link tasks, and the xip content check as child tasks) with one cancellation handler. `extract`,
`forEachEntry`, `decrypt`, and the new `verify` are `@concurrent async throws(AEAError)`; cancelling the caller
throws `AEAError.cancelled` with every pool buffer released. The waits (a free buffer, a job, room in the queue, a
file system permit, a large-file slot, a fork's turn, a decoded chunk) are `Mutex` state plus a continuation, taken
synchronously when nothing has to wait. ARCHITECTURE.md describes it.

Old (threads) against new, interleaved on an idle machine, 3 rounds, medians (`/usr/bin/time -l`):

| | Wall (s) | User (s) | Sys (s) | Instructions (G) | Peak footprint (MB) |
|---|---|---|---|---|---|
| xip, verify | 2.11 → 2.11 | 46.4 → 46.5 | 0.7 → 0.7 | 428.5 → 427.7 | 950 → 815 |
| xip, extract | 10.30 → 10.01 | 109.9 → 110.4 | 37.7 → 36.1 | 1373.6 → 1373.7 | 1449 → 1213 |
| aea, verify | 2.67 → 2.74 | 55.9 → 55.8 | 0.6 → 0.6 | 484.8 → 484.8 | 1095 → 1077 |
| aea, extract | 9.39 → 9.64 | 82.8 → 82.8 | 45.0 → 43.9 | 1021.1 → 1023.2 | 1627 → 1359 |

(xip: Xcode 27.2 RC; aea: Xcode 27.3 beta 2.) The aea extraction's wall time was 0.08–0.25 s higher in each round
with CPU time equal or lower; the xip's 0.2–0.5 s lower. The xip extracted by both: 126,027 files with identical
contents (MD5 of each), 11,204 links with identical targets, and the same mode, size, flags, and times; the block
counts `stat` reports differ on a few hundred files between any two runs, old against old too.

What mattered:

- **`nonisolated(nonsending)` on every internal async function.** Without it the walker made about 4
  `swift_task_switch` checks per entry (1,001-file archive: 21,374 for an extraction, 1,481 with it, about one per
  real suspension: a writer waiting for one of the 6 file system permits).
- **`UnsafeContinuation` in release builds** (checked in debug): a checked continuation allocates per wait, and a
  writer waits about once per file.
- **32 CPU-bound decoder tasks didn't starve the walker.** Yielding after each segment, or decoders at a lower
  priority than the walker, measured no different (xip extraction 10.1–11.1 s across all variants): no task
  executor on Dispatch was needed. The CLI runs its work in a child task at `.userInitiated` (the async main task is
  at 21, the old threads were user-initiated).
- **Decoding segment 0 inline to look for `pbz` cost 0.15 s on every `.aea`** (the other 31 decoders idle
  meanwhile): the decoders start at once, and the consumer's `prepare()` looks at segment 0 when it's published.

Memory and allocations (peak footprint in the table above):

- **Read buffers give their pages back**: each decoder's 16 MiB read buffer stayed resident up to the largest
  stored segment it had seen. `madvise(MADV_FREE_REUSABLE)` past a 2 MiB floor after each segment: xip extraction
  1398 → 1228 MB, aea 1597 → 1363 MB, system time unchanged (floors of 0 and 1 MiB saved 15–35 MB more for +0.1 s of
  system time in listings; 4 and 8 MiB saved less).
- **Stored AEA segments are read straight into the pool buffer**, MACed and decrypted there. With an `.aea` holding
  a `pbz` stream, the upstream pool starts at `decoders + extra + 2` buffers (writers never hold them) and grows
  only if the stream turns out plain: a 1.1 GB pbz-in-AEA archive of stored segments, extraction 2892 → 2003 MB.
- **Encoders and decoders made on first use** (a writer's three `decmpfs` encoders were 1.9 MB zeroed, a decoder's
  inflate window 160 KiB whatever the archive's codec): about −35 MB.
- **Opening**: HKDF's extract and HMAC key setup once for all segment keys, tables reserved once: 2.31 M → 1.92 M
  instructions, 63 → 30 mallocs (189 segments). Header parsing with `do throws(BytesError)`: 66 K → 63 K
  instructions per 170 headers, no `swift_allocError`.
- **Per-entry allocations**: verifying without `-l` built 1–2 strings per entry (176,000 mallocs → 3,000 with
  `verify`); a `[UInt8]` path per directory (aea extraction 34,781 mallocs → 4,712, in the walker's arena now).
- Smaller: the early-link queue only when it's used (8.7 MB), `WriteJob` 456 → 312 bytes (the ring 7.5 → 5.1 MB),
  small buffers without 16 KiB alignment, the directory table only with `relativeToParents`.

Not done: `Paths.check` and `Cpio.octal` vectorized (91 and 32 ns per entry, 20 ms of a 10 s extraction together).
Not measured: `--hard-link-threads` at Xcode's scale (tests only; its retry for a file not yet created still
sleeps 200 µs, with `Task.sleep`), decrypting the real `.aea` to a file, `--fetch-key`.

## 2026-11-19 (xip): Xcode's `.xip`, expanded as `xip --expand` expands it, 4.8x faster

`nunarchiver` reads Xcode's `.xip` downloads (format: FORMAT.md §4; the implementation and the comparison with Apple's
tool and unxip: [XIP-REPORT.md](XIP-REPORT.md)). Input: `Xcode_27.2_Release_Candidate.xip` (2.05 GB; 10.35 GB of cpio
in 617 xz blocks of 16 MiB; 167,193 items, 126,027 files, 32,009 hard-linked names), checked on 27.1 RC and 27.3 beta.

**Output identical to Apple's.** Every item of 27.2 compared with `xip --expand`'s: metadata of every file (mode,
flags, size, modification time), extended attribute names, contents, the storage decisions (27,035 files in LZVN forks,
98,992 plain), and the stored `decmpfs` bytes of every fork. Only directories' and links' times differ (both tools
leave them at the time of extraction). Two rules had to be found from the data:
- **Which files:** over 16 KiB, not PNGs, and the fork saves a fifth of the 4 KiB blocks (FORMAT.md §4).
- **The room:** `xip` gives each LZVN chunk only its own size. With 64 KiB of room (as for `aa`'s LZBITMAP), 42 files'
  short last chunks (20–1,564 bytes) compressed where Apple's are raw: LZVN needs 1–10 bytes beyond its stream. With the
  chunk's own size, all 154,171 chunks match (153,662 compressed, 509 raw). Before Bytes' LZVN encoder took
  Compression's parse, 26,171 forks differed.

### Timing (idle machine, `bench-xip.sh` in the session's scratch, interleaved rounds, warm cache)

Xcode 27.2, three rounds (min / median / max):

| Run | Wall | User | System | Peak memory |
|---|---|---|---|---|
| `xip --expand` (Apple) | 47.34 / 47.79 / 48.40 s | 148 s | 38 s | 1.44 GB |
| `unxip` (LZFSE forks) | 21.31 / 21.59 / 21.89 s | 126 s | 73 s | 5.05 GB |
| `unxip -c` (plain files) | 18.41 / 18.67 / 18.85 s | 58 s | 67 s | 4.02 GB |
| `nunarchiver -d` (as Apple: LZVN) | **9.91 / 9.92 / 10.05 s** | 111 s | 36 s | 1.45 GB |
| `--hard-link-threads 4` | 10.92 / 11.10 / 11.23 s | 110 s | 48 s | 1.46 GB |
| `--disk-compression lzfse` (unxip's codec) | 9.20 / 9.31 / 9.44 s | 91 s | 37 s | 1.46 GB |
| `--disk-compression none` | 7.87 / 8.03 / 8.03 s | 46 s | 34 s | 1.43 GB |
| verify + list (no `-d`) | 2.07 / 2.08 / 2.11 s | 46 s | 0.7 s | 0.95 GB |

27.1 RC and 27.3 beta, two rounds each: Apple 47.3 / 47.3 and 47.5 / 47.6 s; unxip 21.5 / 21.3 and 21.3 / 21.6 s;
`nunarchiver -d` 9.85 / 10.11 and 9.97 / 10.05 s; verify + list 2.13 / 2.16 and 2.17 / 2.13 s.

- **Against Apple: 4.8x** (9.9 against 47.8 s), with the same output, and verifying what `xip` doesn't check (the RSA
  signature and its chain to Apple Root CA, the TOC, `Content`'s and `Metadata`'s SHA-1s).
- **Against unxip: 2.2x** as Apple stores the files, **2.3x** with unxip's own LZFSE (9.31 against 21.59 s) and 2.3x
  plain (8.03 against 18.67 s), in less than a third of its memory (1.45 against 5.05 GB) and half its system time.
  unxip checks nothing, leaves every file at the extraction time, and compresses every file over 4 KiB whose LZFSE
  is smaller (50,073 files, 3.38 GiB on disk, against Apple's 27,035 in 3.67 GiB; `--disk-compression lzfse` keeps
  Apple's choice of files: 3.48 GiB).
- **Bytes' xz decoder against Compression's** (`--decoder system`), verify + list, three rounds: 2.09–2.14 s
  against 2.48–2.53 s (−16% wall, 46.7 against 55.6 s of user time).
- **Where the time goes** (`-v`, 9.87 s): the walk takes 6.58 s, 5.36 s of it waiting for decoded blocks, which the
  writers hold until their files are written; then the 26,062 later hard-link names, 2.59 s on 6 threads
  (about 280 µs of kernel time each); then the last writers (0.42 s) and symbolic links (0.28 s). The writers'
  summed time: 33.8 s waiting for admission to the file system, 9.2 s in `open`, 14.9 s compressing (outside the
  admission limit), 3.9 s writing data, 3.3 s forks, 3.1 s times and flags, 1.6 s `close`.
- **The AEA defaults are the xip's best too** (two rounds each): file-system width 4: 11.2 s, **6: 9.8–10.1 s**, 8:
  10.45 s, 12: 11.2–11.4 s; extra decoded blocks 8 (default), 32, or 64: the same (9.8–10.0 s).
- **Hard links during the writes** (`--hard-link-threads 4`): 11% slower with 30% more system time; links are made
  after the writers by default.

## 2026-11-19: APFS compression with BytesCompression's LZBITMAP encoder, byte for byte as `aa extract`

Disk compression (`decmpfs` types 13 and 14) now uses `LZBitmapEncoder`, whose output and failures are Compression's
exactly (Bytes' RESULTS-lzbitmap.md); LZFSE (types 11 and 12, which Xcode doesn't use) uses `LZFSEEncoder`, the open
lzfse reference's streams, which differ from Compression's in a few block boundaries (so such files decode the same but
may not be stored byte for byte as `aa` stores them; a test checks form and contents against `aa`). Checked
on Xcode by extracting it with `unaea` and `aa extract` and comparing every item: metadata, extended attribute names,
contents, storage form, and now also each file's stored `com.apple.decmpfs` attribute and resource fork bytes.

That comparison found a difference the earlier one (storage form only) couldn't: Compression's LZBITMAP output depends
on the destination capacity it's given, not just whether it fits. Its compressed path needs working room beyond its
result, so with little room it fails or stores, and with less room than 64 KiB, some full chunks came out larger
(64,688 bytes against 64,561). `unaea` gave each chunk exactly its own size, as the old Compression-based code did:
- **1,604 files differed** in stored bytes (same forms and contents). Of these, 1,554 were small inline files stored
  raw (0xFF) that `aa` compresses: a 321-byte plist needs 337 bytes of room to compress to 277. The other 50 were the
  short last chunks of fork files.
- **`aa`'s rule, found from the data:** every chunk gets 64 KiB of room, whatever its size. Tried first: the encoder's
  own `maximumCompressedSize` (+47 bytes: 26 differed); a whole chunk past each chunk (37 differed: too much room
  compresses full chunks `aa` stores); the inline attribute's 3,584 bytes for one-chunk files (every one of the
  115,930 matched, as does 64 KiB, so the simpler rule won).
- **Now every one of Xcode's 167,542 items matches `aa extract` byte for byte**, compressed bytes included.

### The timing pass (idle machine, three interleaved rounds, `bench-xcode2.sh` in the session's scratch)

| Run (Xcode 27.3 beta 2) | Wall (min / median / max) | User | System | Peak memory |
|---|---|---|---|---|
| `unaea -d` (quarantine copied, as `aa`) | 8.82 / 8.93 / 10.40 s | 83 s | 41 s | 1.69 GB |
| `--no-quarantine` | 7.70 / 7.93 / 8.32 s | 83 s | 35 s | 1.66 GB |
| `--no-quarantine`, Compression's LZBITMAP encoder (an A build) | 7.75 / 8.05 / 8.33 s | 86 s | 36 s | 1.69 GB |
| `--no-quarantine --scheduler tasks` | 7.74 / 7.93 / 8.25 s | 83 s | 36 s | 1.67 GB |
| `--disk-compression none` (plain files) | 5.34 / 5.35 / 5.36 s | 55 s | 24 s | 1.63 GB |
| verify + list (`unaea`, no `-d`) | 2.66 / 2.67 / 2.74 s | 56 s | 0.6 s | 1.14 GB |
| verify + list, `--scheduler tasks` | 2.67 / 2.68 / 2.68 s | 56 s | 0.6 s | 1.15 GB |
| `aea decrypt -o /dev/null` (Apple) | 3.60 / 3.62 / 3.64 s | 64 s | 0.5 s | 1.09 GB |
| `aa extract` (Apple, once) | 46.7 s | 136 s | 340 s | 1.32 GB |

- **Bytes' LZBITMAP encoder against Compression's:** the writers' summed compression time fell from 10.5–11.0 s to
  9.4–10.1 s (−8%), and user time by 3.3 s; wall time is the same within noise, because extraction is bound by the
  file system (writers' summed time: 94 s waiting for admission to it, 14 s in `open`, 11 s setting attributes, 6 s
  writing forks, against 10 s compressing).
- **Swift concurrency's pool against threads for the segment decoders:** no difference, in extraction (7.93 s
  against 7.93 s median) or verification (2.68 against 2.67 s). Decoding is 24 independent CPU-bound LZMA jobs
  feeding one walker through a buffer pool: either scheduler keeps every core busy, and the walker's wait for
  segments (2.4 s) is the same. Threads stay the default (no executor hops in the per-segment handoff); tasks
  remain an option for callers already in async code.
- **Against Apple:** extraction 5.2x faster than `aa extract` with its quarantine behavior (5.9x without), with 8x
  less system time; verify + list 1.36x faster than `aea decrypt` alone.
- **Unchanged from the last pass**, within noise: the default (9.09–9.35 s then), no quarantine (7.91–8.01 s), plain
  files (5.4 s), verify + list (2.77 s). The security fixes (links made relative to an opened parent, path-based
  quarantine for directories) cost nothing measurable.

## 2026-11-18 (later): every profile, Apple Archive files, and `aa extract`'s metadata, on Bytes alone

### What changed

- **All six profiles**, checked against archives `aea encrypt` makes for each at test time:
  - 1 and 2: a symmetric key.
  - 3 and 4: ECDH with the recipient's private key.
  - 5: a password, through scrypt.
  - 0, 2 and 4 are signed; on 2 and 4 the signature is encrypted.

  The key schedule is in FORMAT.md. Segments are MACed as stored, then decrypted in the decoding thread's read
  buffer (straight into the output when stored uncompressed) with AES-CTR as CommonCrypto counts: only the IV's last
  8 bytes, which needed a new counter layout in BytesCrypto.
- **IPSW disk images:** the four `.dmg.aea` files of an iPhone18,1 27.0.1 IPSW (profile 1, LZFSE segments) decrypt
  to the same bytes as `aea decrypt`. The key comes three ways:
  - from `--key`;
  - from the auth data's WKMS request, opened with HPKE using a PEM private key (`--fcs-key`);
  - downloaded from the URL in the auth data (`--fetch-key`).
- **`unaea -o FILE`** decrypts to a file, whatever the contents, with `--range-offset` and `--range-size` (only the
  segments a range needs are read).
- **Apple Archive files and `pbz` streams:** `aa archive`'s default output, with blocks of every algorithm (`e x z
  4 b m`), decodes in parallel, on its own (`AppleArchiveFile`) or inside an AEA container. The walker takes any
  chunk source (`ChunkSource`): AEA segments, `pbz` blocks from a file or from upstream segments (copied into
  staging buffers, since blocks cross segments), or slices of a plain file.
- **What `aa extract` restores:**
  - extended attributes, on files, directories and links;
  - ACLs (through `acl_*`, which allocates: only entries with one get there);
  - hard links (the first member is written, the rest linked);
  - FIFOs; devices with root, otherwise skipped and counted;
  - the archive file's quarantine attribute, on every item, and on the destination for a plain `.aar` but not an
    `.aea`, as `aa` does.

  Entries with metadata are finished after the writers: owner-writable until then, then attributes, ACL, mode, times
  and flags.
- **Storage decided on the whole file:** a file across segments always compresses its pieces into the fork. If the
  whole fork doesn't pay, it's read back, decoded with BytesCompression and written plain. Xcode now matches `aa
  extract` file for file (88,006 inline, 37,881 fork, 318 plain), including the `Assets.car` that differed. A
  64 KiB chunk can now span any number of small segments, up to the seven a bridge holds.
- **Only Bytes:** segments and blocks decode with BytesCompression (LZMA, zlib, LZFSE, LZ4, LZBITMAP, LZRAVEN), and
  every check uses BytesCrypto:
  - signatures (P-256);
  - certificate chains (X.509 parsing, P-256 and P-384 ECDSA, validity, CA flags; Apple Root CA - G3 pinned by
    fingerprint, or roots the caller gives);
  - ECDH, HPKE and scrypt.

  The library imports neither CryptoKit nor Security. Compression is left for writing APFS-compressed files (its
  LZBITMAP encoder: no encoders yet) and for `--decoder system`, kept for comparison. (Since 2026-11-19, above, the
  files are written with BytesCompression's encoders too: Compression remains only for `--decoder system`.)

### Results (Xcode, warm cache, interleaved, two rounds, `/usr/bin/time -l`)

| Command | Wall (s) | User (s) | System (s) | Peak footprint |
|---|---|---|---|---|
| `aa extract` (Apple; copies the quarantine) | 46.89 | 136.9 | 344.9 | 1.32 GB |
| `unaea -d` (copies the quarantine, as `aa`) | **9.35, 9.09** | 86.1 | 42.8 | 1.67 GB |
| … `--no-quarantine` | 8.01, 7.91 | 85.9 | 35.3 | 1.66 GB |
| … 16 decoders, 2 spare buffers | 8.75, 8.25 | 85.1 | 35.2 | 1.05 GB |
| … 16 decoders, 16 writers, no spares, mapped | 8.62, 8.38 | 84.1 | 34.0 | **0.60 GB** |
| … `--spread-directories` | 13.44, 12.49 | 84.5 | 23.4 | 1.65 GB |
| … `--disk-compression none` | 5.40, 5.48 | 55.5 | 23.9 | 1.56 GB |
| `aea decrypt -o /dev/null` (Apple) | 3.62, 3.62 | 63.5 | 0.5 | 1.09 GB |
| `unaea` (verify and list) | **2.77, 2.78** | 55.7 | 0.6 | 1.14 GB |
| … with Compression's LZMA decoder | 3.30, 3.28 | 65.5 | 0.6 | 1.14 GB |

- **5.1x `aa extract`** with the same output. Every check against `aa extract` passes:
  - contents: 0 differences in 10.43 GB, read through the kernel;
  - mode, flags, size and link target of all 167,542 items: identical;
  - storage, file for file: identical;
  - extended attributes (the quarantine) on all 167,541 items: identical.
- **The quarantine costs 1.2 s (15%):** one more attribute per item, 167,541 of them. It's on by default because
  `aa` does it.
- **Unchanged otherwise:** without it, 7.9–8.0 s against 7.75–7.92 before this work. The whole-file decision, the
  metadata passes and the chunk-source walker cost nothing measurable.
- **Spreading file system calls across directories was 60% slower:** lanes of one writer each, chosen by the
  parent's path. Xcode's directories are uneven, so most writers waited on a few lanes. Kept as
  `--spread-directories`, off. One directory or many didn't matter in the microbenchmark either.
- **Memory:** 16 decoders and 2 spare buffers use 1.05 GB at +4–9%; the lean set uses 0.60 GB at +5–8%. Defaults
  are unchanged.

IPSW root file system image (`043-68786-664.dmg.aea`: 8.99 GB, 10.38 GB decrypted, LZFSE segments of 1 MiB),
interleaved, second and third runs (the first, cold, took 4.6 s):

| Command | Wall (s) | User (s) | Peak footprint |
|---|---|---|---|
| `aea decrypt -o` (Apple) | 1.63, 1.55 | 14.0 | 76 MB |
| `unaea -o` (Bytes' LZFSE) | 1.57 | 14.0 | 103 MB |
| `unaea -o` (Compression's LZFSE) | 1.73, 1.60 | 14.6 | 103 MB |

The same speed as Apple's: both write 10.4 GB at about 6.7 GB/s, the disk's rate. The outputs are byte-identical.

### Correctness checks

26 tests (`swift test`), several of them parameterized:
- every profile against `aea encrypt`;
- wrong keys;
- ranges;
- `pbz` with every algorithm, inside and outside AEA;
- corrupt blocks fail cleanly: no hang with 8 threads waiting on buffers or staging;
- metadata item by item against `aa extract`, including a 50 KB extended attribute across segments, ACLs, three
  names of one file, and an attribute on a link;
- FIFOs, sockets and devices;
- storage decisions against `aa extract` on files whose start and whole disagree, at 16 KiB, 64 KiB and 1 MiB
  segments;
- Xcode's certificate chain against Security's verdict, and damaged signatures, names and keys rejected.

### Notes

- **`pbz` blocks carry no checksums:** damage to a stored block can't be detected, by `aa` either.
- **`--fetch-key` waited for the first time on macOS's network prompt for Apple's domain:** URLSession hung until
  the user approved it, while curl went through.
- **LZVN segments (`f`) stayed unsupported here:** nothing seemed to make them to check against. (Later the same
  day: libAppleArchive writes them given algorithm 0x900; `f` segments and `pbzf` blocks are supported and tested,
  see FORMAT.md.)

## 2026-11-18: a reader and extractor for Apple Encrypted Archives

(The first version, kept as it was measured. Superseded since by the sections above: signatures and chains with
BytesCrypto instead of CryptoKit and Security, files written with BytesCompression's encoders, storage decided on the
whole file, and every file matching `aa extract`.)

### Results

Interleaved runs (two rounds, each command in turn, under the shared benchmark lock; `/usr/bin/time -l`):

| Command | Wall (s) | User (s) | System (s) | Peak footprint |
|---|---|---|---|---|
| `aa extract -i Xcode.aea -d out -sign-pub key` (Apple) | 47.06, 47.33 | 137.4 | 347.0 | 1.26 GB |
| `unaea Xcode.aea -d out` (APFS-compressed, as Apple's) | **7.92, 7.75** | 84.8 | 35.1 | 1.54 GB |
| … with Compression's LZMA decoder | 8.16, 7.89 | 94.9 | 34.9 | 1.54 GB |
| … lean: 16 decoders, 16 writers, no spare buffers, mapped input | 8.50, 8.36 | 82.4 | 33.8 | **0.57 GB** |
| `unaea Xcode.aea -d out --disk-compression none` | 5.62, 5.46 | 55.6 | 24.1 | 1.51 GB |
| `aea decrypt -i Xcode.aea -o /dev/null -sign-pub key` (Apple; decode and verify only) | 3.62, 3.58 | 63.5 | 0.5 | 1.04 GB |
| `unaea Xcode.aea` (decode, verify, and parse every entry) | **2.81, 2.70** | 55.7 | 0.6 | 1.09 GB |
| … with Compression's decoder | 3.23, 3.32 | 65.4 | 0.6 | 1.08 GB |

- **6.0x Apple's extractor**, with the same result: every file's bytes (10.43 GB, read back through the kernel's
  decompression), every mode, flag, size, and link target equal to `aa extract`'s; the same storage decisions (88,006
  inline, 37,882 resource fork, 317 plain against Apple's 37,881 and 318: the one file differs because it spans
  segments, see below); 4,049,280 KB on disk against Apple's 4,049,568.
- `aa extract` spends 347 s in the kernel (lock contention: it writes from 32 threads); unaea 35 s.
- Verifying the archive (signature, every MAC, every SHA-256) and parsing all of it: 1.3x `aea decrypt`, which
  doesn't parse. Opening and checking the prologue, the certificate chain, and the three cluster headers: 1.2 ms.

Package benchmarks (`aea-2`, p50):

| Benchmark | Bytes decoder | Compression |
|---|---|---|
| Decode Xcode's segment 0 (16 MiB, headers and text: the slowest) | 150 ms, 1,670 M instructions | 186 ms, 1,318 M |
| Decode the synthetic archive's segment 0 | 90 ms | 107 ms |
| List Xcode (decode, verify, parse) | 2.69 s, 56 CPU-s | 3.23 s, 66 CPU-s |
| Extract Xcode, compressed / plain | 8.49 s / 5.69 s | |
| Extract synthetic (3.15 GB, 30,363 entries), compressed / plain | 1.86 s / 1.26 s | |
| Parse Xcode segment 0's 308 headers | 106 K instructions, 5.9 µs (19 ns a header) | |
| Open and verify Xcode's archive | 1.2 ms, 7.9 M instructions, 287 mallocs (synthetic) | |

The segment decoder allocates nothing (0 mallocs per segment, both decoders). The threaded benchmarks don't count
mallocs: package-benchmark's interposer traps when a thread exits (`count_free` → `_tlv_get_addr` → `calloc` in
`_pthread_tsd_cleanup`), so they measure time and memory only.

### The pipeline

1. **Open**: positioned reads of the prologue (4 KB) and each cluster header (18 KB); the signature (CryptoKit's
   P-256), the certificate chain (Security's trust evaluation), and the root and cluster header MACs (BytesCrypto's
   HKDF and HMAC) checked; a table of segments with their checksums, MACs, and keys.
2. **Decode**: a thread per core takes a free buffer from a fixed pool, then the next segment (in that order, so the
   segment the walker waits for always has one), reads it (`pread` into its own buffer, or from a mapping), checks
   its MAC, decodes it (BytesCompression's `LZMA2Decoder`), checks its SHA-256, and publishes it.
3. **Walk**: one thread takes segments in order and parses headers. A header across a segment's end is made
   contiguous by copying its first bytes (at most 64 KiB) into a carry region before the next segment's bytes; file
   contents are never copied. It checks every path (no `..`, empty components, NUL, or absolute paths), creates
   directories, and queues files as jobs pointing into the buffers, each holding a reference to them.
4. **Write**: writer threads compress (LZBITMAP, 64 KiB chunks, Compression's encoder) outside a semaphore, then make
   the file inside it, at most 6 at once: `open`, the resource fork (`fsetxattr` at a position), the `decmpfs`
   attribute, `fchflags`, `close`. A file across segments is written in pieces as they arrive.
5. **Finish**: symbolic links last (so nothing is written through one), then directories' modes, times, and flags.

Nothing is allocated per file or per segment: buffers, read buffers, writer scratch, Compression's scratch, and the
LZMA model are made once. Each file is created with `O_NOFOLLOW_ANY` and `O_EXCL`.

### How it got here (Xcode, compressed output, warm cache)

| Step | Wall (s) |
|---|---|
| First correct extraction: 12 writers doing everything | 11.36 |
| Compression outside a file system semaphore (24 writers, 6–8 inside) | 9.0–9.4 |
| Pieces of large files compressed in parallel, in place; 128 large-file slots | 8.5 |
| BytesCompression's LZMA decoder | 7.75–7.92 |

**The file system is the limit.** Writers spent 33 s in file system calls in total (`open` 11–20 s, the `decmpfs`
attribute 10–18 s, resource forks 6–10 s, `fchflags` 4–6 s; sums across threads, from the extractor's own timers),
against 11 s compressing. More writers in the kernel made everything slower:

| Writers in the file system | 8 | 16 | 24 | 32 |
|---|---|---|---|---|
| Xcode, plain files (s) | 5.78 | 7.28 | 8.34 | 9.45 |
| Xcode, compressed, writers compressing too (s) | 11.2 | 10.5 | 14.0 | 16.8 |

A microbenchmark (create a file, write or set the `decmpfs` attribute and flag, close; 60,000 files) showed APFS
peaking at 4 threads, the same in one directory or one per thread, so the contention is in the file system, not
the directory:

| Threads | 1 | 4 | 8 | 16 |
|---|---|---|---|---|
| Files a second, one directory | 14,282 | 45,998 | 36,690 | 32,571 |
| One directory per thread | 20,381 | 49,818 | 36,466 | 15,407 |
| With the `decmpfs` attribute and flag, one directory | 15,068 | 44,451 | 39,000 | 32,527 |

So compression (about 27 CPU-s of LZBITMAP at 385 MB/s a core) runs on 24 writers and the calls on at most 6.
Paths 12 components deep cost about 20% (35,464 files a second at 4 threads against 42,921).

**Large files waited on each other.** With 4 slots for files across segments, the walker waited 6.0 s of 9.0 s for
one: a file's pieces compressed one after another (each needs the fork offset where the last ended), each holding
its 16 MiB buffer. Now a piece compresses as soon as it arrives, chunk by chunk, moving each chunk's output back
over its own consumed input in the segment buffer (no other job reads those bytes, and a piece's output stays behind
its unread input; if it would catch up, the rest is compressed after its turn); its turn is only the writes. With
128 slots the wait is gone (8.5 s from 9.0).

**Decoding**: BytesCompression's new `LZMA2Decoder` (Bytes' RESULTS.md, 2026-11-18) is 1.14–1.24x Compression's
per core on Xcode's segments. Decoding all 624 segments takes 56 CPU-s instead of 66, and the verified listing 2.7 s
instead of 3.3. Extraction gains less (file system bound), but the CPU freed helps the compressors and the kernel.

**Memory**: 1.54 GB by default, mostly the pool (decoders + writers + 8 spares, 16 MiB each). Decoding 2.5x faster
than the file system can write needs only about 16 decoders: 16 decoders, 16 writers, no spares, and a mapping
instead of read buffers is 571 MB at +7% time. (Mapped input showed 3.0 GB of resident memory, file pages the kernel
can drop, but a 970 MB footprint against 1.42 GB with positioned reads.)

### Matching Apple's output

- Apple's `aa extract` writes files as `decmpfs` type 13 when the attribute is at most 3,584 bytes, type 14
  otherwise, and plain when the fork would be at least 93% of the raw size. Files within one segment decide on the
  whole file (when a fork doesn't pay, it's removed and the bytes written plain: they're still in the buffer). A file
  across segments decides on its first megabyte, before any piece overwrites its input: one of Xcode's files
  (an `Assets.car` whose first megabyte compresses) differs from Apple's choice.
- Read-only files (0444) are created owner-writable and get their mode at the end: setting an extended attribute
  checks the file's mode, not the descriptor (`EACCES` otherwise).
- Links get their archived mode (18 of Xcode's are 0644) with `fchmodat(AT_SYMLINK_NOFOLLOW)`.

### What didn't work

- **Creating entries relative to their parent's descriptor** (`openat(parent, name)`, every directory kept open):
  3% slower, interleaved (8.28–8.40 s against 7.98–8.17 s). The name cache makes path lookups cheap, and opening
  each directory is one more call on the walker. Kept as `relativeToParents`, off.
- **More writers in the file system** (above), and fewer decoders without fewer buffers: decoders then fall behind
  (12 decoders: 9.7 s).
- **`clonefile` for duplicate files**: Xcode has 67,065 duplicates (59,140 distinct contents in 126,205 files, 0.87
  GB). Cloning keeps `decmpfs` and `UF_COMPRESSED`, but ran at 23,000 clones a second on 4 threads against 44,000
  files created, so it would save only the duplicates' compression (about 2 CPU-s). Not done.
- **LZFSE for the disk**: Xcode asks for LZBITMAP, which encodes at 381–391 MB/s a core here against LZFSE's 166–185
  (LZ4: 1,026–1,284, but no `decmpfs` type).

### Correctness checks

- 15 tests (`swift test`): archives Apple's `aea` and `aa` make at test time (every segment compression and checksum,
  16 KiB to 4 MiB segments, a certificate chain in the auth data), against trees with every kind of entry and size;
  Xcode-style streams the tests write (`AFT`), checked for `decmpfs` types; tampering (signature, cluster header,
  segment), truncation, another key, unsafe paths, a link planted before a file, overwriting.
- Xcode: every file compared with `aa extract`'s output through the kernel (0 differences in 10.43 GB), and `stat`
  of every entry (mode, size, link target) identical.

### Ideas not tried

- An LZBITMAP encoder in Swift: 27 CPU-s of Compression's encoder is the largest CPU cost after decoding. The format
  is now described in Bytes' RESULTS-lzbitmap.md; encoders were deliberately left for later.
- Writing files in an order that spreads the file system's work: tried later the same day (`--spread-directories`),
  60% slower; see the section above.
- Cold-cache runs (`purge` needs root).
