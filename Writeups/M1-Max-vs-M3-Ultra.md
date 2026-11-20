# M1 Max against M3 Ultra: every performance difference we measured

2026-11-19. The Bytes experiments moved to a new machine, an Apple M1 Max. Every benchmark suite of every package that
uses Bytes was run again there with the same compiler (Xcode 27.3, Swift 6.4.4) and compared with the M3 Ultra's latest
saved baselines. Per-package tables are in each project's `RESULTS.md` (a section dated 2026-11-19); the hardware
experiments are in `Bytes/Benchmarks/RESULTS.md` and `Bytes/OPTIMIZATION.md` (Part III, "The second machine: M1 Max against M3 Ultra").

## The short version

1. **One core is 1.3x slower, and the clock explains almost all of it.** Geometric mean of time (M1 Max over M3 Ultra)
   across 773 Bytes benchmarks with identical instruction counts: **1.31**. The clock ratio is 1.25 (4.05 against 3.23 GHz),
   so the M3 does about 4% more per clock. Every package lands at 1.27–1.34.
2. **Many cores are a different story: the M3 Ultra has 3x the performance cores** (24 P + 8 E against 8 P + 2 E). Parallel
   work follows the lane count: 2.4x apart for the parallel codecs, 3.1x for NativeAEA's threaded extraction, 1.9x for
   memory-bound reads on all cores (bandwidth ratio 2.05).
3. **Nothing in the code needed to change for the M1 Max, with one exception we found.** `udot` (dot product) was unused: an
   Adler-32 that uses it is 2x faster on the M1 Max (29.8 → 58.0 GB/s), now in Bytes. The two efficiency cores make the
   parallel encoder 10–13% faster and the parallel decoder 20–35% slower.
4. **Be careful with timing on a fresh machine.** Spotlight and photo analysis were indexing the new files during the first
   runs. One row came out 2.2x too slow. Re-runs on the idle machine agreed with the first runs to 1% overall.

## The machines

| | M3 Ultra | M1 Max |
|---|---|---|
| Cores | 24 P + 8 E (32 logical) | 8 P + 2 E (10 logical) |
| P-core clock | ~4.05 GHz | ~3.23 GHz |
| Memory | 256 GB LPDDR5-6400, 1,024-bit, 819 GB/s | 64 GB LPDDR5-6400, 512-bit, 400 GB/s |
| P-cluster L2 | 16 MB (6 cores) | 12 MB |
| ISA used by these packages | NEON, AES, PMULL, SHA-1/2/3/512, CRC32, DotProd | the same; the M1 lacks I8MM and BF16, which nothing here uses |
| OS | macOS 27.2 | macOS 27.2.1 |

## How the comparison was made

- The M1 Max numbers: each package's whole suite, `baseline update m1max` (Bytes: also `m1max-portable` and
  `m1max-portable-no-c`, on the benchmarks the M3's portable baselines had), one package at a time.
- The M3 Ultra numbers: the newest full baselines already in the repository (`d2-final`, `d2-zip2`, `aea-2`, `trk-final`,
  `trk-final-portable*`), recorded on 2026-11-17 and 18. They are slightly older than HEAD, so each comparison checks the
  **Instructions** metric: where it matches, the time ratio is the hardware's. It matched for 771 of 773 Bytes benchmarks
  (the two others are system libraries) and in the other packages except where the tables list differences.
- Where benchmarks name the lane count of the chip (`24 lanes`, `32 cores`), they don't pair by name. Those are compared by
  hand: 24 lanes on the M3 against 8 on the M1 Max.
- Caveat on every M1 Max number: the first runs overlapped background indexing. The re-run (`m1max-2`) of Base64, MQTT,
  NativeZip, NativeAEA and BinaryParsingComparison, and of a 200-benchmark subset of Bytes (the portable list), agreed
  with the first to 0.988–1.000 (geometric mean). The Bytes parallel rows and the SocketStream transfers were not re-run.
- Nothing here was measured on the M3 Ultra again. The M1 experiments say what the M1 Max does; any M3 effect of a change
  is inferred, and marked so.

## Per package

| Package | Pairs | M1 Max / M3 Ultra (geomean) | Notes |
|---|---|---|---|
| Bytes (optimized) | 773 | **1.31** | Back-references 1.47, Write 1.41, Brotli 1.35, Inflate/Deflate 1.33, Zstd 1.24, crypto 1.14–1.39 |
| Bytes (portable, 200) | 200 | 1.33 | the three builds stay within 1.4% of each other on both chips |
| Bytes (portable, no C, 200) | 200 | 1.34 | |
| Base64 | 81 | 1.27 | encode 1.25, decode 1.28; short inputs 1.32; the scalar table only 1.15 |
| MQTT | 10 (single core) | 1.34 | PUBLISH encode 1.60–1.68 at identical instructions; the views' lead over conventional code (9–12x) holds on both |
| NativeZipArchive | 40 | 1.33 | single-threaded 1.30; extraction 1.28; CRC-32 over 32 MB 1.08 (re-run) |
| NativeAEA | 8 | 1.93 | single-threaded rows 1.20, threaded rows (list, extract) 3.1 |
| BinaryParsingComparison | 49 | 1.30 | Bytes's lead over swift-binary-parsing holds; one flip (LZ4 swift-help) not investigated |
| SocketStream | 8 in-memory | 1.32 | transfers: compute-bound ones follow the clock; plain loopback is faster on the M1 Max than the M3's older recorded numbers (different code: indicative only) |

## Where the two chips differ beyond the clock

- **Stores.** One-core raw SIMD stores: 113 GB/s on the M3, 62 on the M1 Max (1.81x); `Write` rows 1.2–2.1 (the largest
  spread in the suite). Reads are 78 against 61 GB/s (1.28, the clock).
- **Short copies.** Back-references at distances 1–7 (equal instructions): 1.6–1.85x. A guess is partial-width loads that
  can't forward from recent stores; not probed.
- **Mid-size inputs.** 1.06x at 1 KB, about 1.5x for 100–400 KB inputs, 1.3x for multi-MB: working sets that live in L2 on
  the M1 Max (17–18 cycles) cost more there. Not isolated.
- **Where the M1 Max keeps up.** Hash functions (SHA-1/256, HMAC, PBKDF2: 1.14–1.21, below the clock ratio), CRC-32 with
  the hardware instructions (1.15 at 256 KB, 1.08 at 32 MB), the scalar-table Base64 (1.02–1.10 at some sizes), and
  small-input Zstd (0.97–1.04): latency-bound code that doesn't use the M3's clock.
- **Many-core memory.** Ten cores read 126 GB/s on the M1 Max (two cores already reach 115); the M3's 32 cores read about
  237 GB/s in Bytes' bandwidth benchmark. One P core alone gets 61 GB/s on the M1 Max.
- **Parallel scaling.** Parallel inflate with 8 lanes is 5.6x faster than sequential on both machines. 8 lanes of the
  parallel codecs at 8 lanes on both chips: 1.2–1.65x apart (geomean 1.31); the full chips: 24 against 8 lanes, 2.4x.
- **File-system work.** Extracting 2,000 small files: fastest with 4 workers on the M3 (64 ms), with 8 on the M1 Max (81 ms;
  4 workers: 106 ms). NativeAEA writers add 4% over decoding on the M3 and 20% on the M1 Max.
- **Allocation counts** that depend on the machine's worker count differ (NativeZip's 32 MB extracts 271–275 → 131–135
  mallocs, Verify 449/545 → 125/155; Dispatch rows 13 → 7): per-worker allocations, consistent with 32 against 10 workers.

## What the M1 Max can do (measured on one P core)

| Instruction | Latency (cycles) | Per cycle |
|---|---|---|
| `add`, `eor`, `eor3`, `bcax`, `zip`, `uzp`, `ext`, `rev32`, `tbl` with 1–2 registers | 2 | 4 |
| `udot`, `pmull`, `aese`, `mul`, `usra` | 3 | 2.7 |
| `tbl` with 3 / 4 registers | 4 | 1.9 / 1.3 |
| `tbx` with 4 registers | 8 | 1.0 |
| `fmla.4s` | 4 | 2.0 |
| `sha256h`, `sha512h` | 5, 3 | 0.5 |

Cycles are scaled from a calibration that read 2.82 GHz (±15%). Memory: L1 3 cycles, L2 17–18 cycles, system-level cache
35–52 ns, DRAM about 122 ns; one core reads 61 GB/s, ten cores 126.

## M1 Max-specific optimizations explored

| Idea | Result |
|---|---|
| **Adler-32 with `udot`** (FEAT_DotProd) | **Kept.** 29.8 → 58.0 GB/s (1 MB), −47% time, −51% instructions; 64 B inputs −12% time; zero mallocs; tests for the chunk boundaries. Matches libdeflate (64 GB/s). Bound by `udot` throughput. Gain on the M3 likely, unmeasured. |
| Lanes = all cores for the encoder (the E cores) | **Measured, not applied.** +10–13% for the parallel DEFLATE encoder with 10 lanes against 8. |
| More lanes than cores for the decoder | **Measured, not applied.** 16 lanes: 4–12% faster than 8; 9–10 lanes: 20–35% slower (a static segment lands on an E core). |
| Software prefetch for the CRC-32 fold | No gain (±1%; a distance of 8 KB lost 7–50%). The fold already runs at the memory rate (58–62 GB/s). |
| Two-stream CRC, buffer alignment | No change. |
| AES kernels | Nothing to find: AES-128-CTR is at about 90% of the `aese` bound. |
| `eor3`, PMULL folding | Already used. |
| Short back-reference copies; stores; Base64's `tbl`/`tbx` window | Candidates, not tried: see `Bytes/Benchmarks/RESULTS.md`. |

The M1 and M3 have the same instruction-set features for these kernels, so an M1-only instruction was not on the table
(no I8MM, BF16, SVE or SME on either chip that the code could use). What differs is the microarchitecture and the core
layout, and the two things that paid were an instruction nobody had used yet and the efficiency cores.

## Other things found

- `Tools/toolchain install` failed under Bash 3.2 (`$url…`: a non-ASCII character after a variable name); fixed with
  `${url}…`. The PR toolchain (pr-91981, build 2511) installed from its URL, still live.
- The Bytes test target doesn't compile with the `Portable` trait or `--disable-default-traits`
  (`AESGCMTests`: `AESGCM.reduce`, `reduceInVectors` are not in those builds); unrelated to this work.
- Homebrew's `libdeflate`, `brotli` and `yq` were installed (Bytes' manifest names the first two; the Tools need `yq`).
- `Tools/.toolchain.swp` appeared in the working tree (a vim swap file, not made by this work).
- The benchmark runs: Bytes' full optimized suite takes about two hours on the M1 Max; the other packages 1–7 minutes each.
