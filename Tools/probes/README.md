# Machine probes

`Tools/probe` measures what a Mac's cores and memory can do, and how Bytes' kernels run on it, the same way on any
Apple silicon Mac (M1 through M5; base, Pro, Max, Ultra), so two machines' results compare row by row. It grew out
of throwaway probes run on an M1 Max (2026-11-19) and repeated on the M3 Ultra (2026-11-20); the write-ups are in
`Bytes/Benchmarks/RESULTS.md` (sections "2026-11-19, M1 Max experiments" and "2026-11-20, M3 Ultra").

| File | What |
|---|---|
| `../probe` | the entry point: `machine`, `insn`, `mem`, `bytes`, `all`, `compare`, `steps` (`Tools/probe --help`) |
| `gen-insn.pl` | generates the instruction probe's C (one inline-asm loop per instruction and chain count) |
| `mem.c` | the memory probe: latency, one-thread bandwidth, bandwidth by thread count |
| `BytesProbe/` | a package depending on `../../../Bytes` (with swift-argument-parser): checksums, parallel DEFLATE lanes and segments |
| `compare.pl` | `Tools/probe compare`'s engine |
| `results/CHIP-DATE/` | reference result sets, one TSV per table |

The C probes are compiled with `xcrun clang -O2 -mcpu=apple-m1 -Wall` into `~/Scratch/tools-cache.noindex/`
(`EXPERIMENTS_TOOLS_CACHE`), named by a hash of the source, the flags, and the compiler, so they're compiled again
when any of those change. BytesProbe is built release in `BytesProbe/.build` (ignored by git).

## Running it on a Mac

Prerequisites: Xcode (selected with `xcode-select`; the probes use `xcrun clang` and `swift build`), a clone of this
repository, and for the `lanes` and `segments` tables the Silesia corpus (`Tools/corpus fetch`, 68 MB download).
BytesProbe needs the same Xcode as the rest of the repository (Swift tools 6.4, macOS 27), and its first build resolves
swift-argument-parser and Bytes' swift-syntax dependency (network, or SwiftPM's cache). Nothing else: no Homebrew
tools, no sudo, no attach prompts.

```sh
Tools/corpus fetch            # once per machine
Tools/probe all               # about 1.5 minutes on an M3 Ultra, plus 1-2 minutes to build BytesProbe the first time
```

`all` writes `machine.tsv`, `insn.tsv`, `insn-clock.tsv`, `mem-latency.tsv`, `mem-bandwidth.tsv`, `mem-threads.tsv`,
`checksums.tsv`, `lanes.tsv`, and `segments.tsv` into `~/Scratch/probes/CHIP-YYYY-MM-DD/` (for example
`M3-Ultra-2026-11-20`; `-2`, `-3`… when it exists), or `--save DIR`, and prints the directory. `--quick` takes about a
third of the time with noisier numbers; `--no-bytes` skips BytesProbe (no Swift build, no corpus). Each probe runs on
its own too, printing TSV to stdout: `Tools/probe insn --only tbl`, `Tools/probe mem latency`, `Tools/probe bytes
checksums`.

Measure on an idle machine: quit other apps, wait for Spotlight to finish indexing new files (the corpus, a fresh
clone), and on a laptop, plug it in and turn Low Power Mode off. `machine.tsv` records the power source, Low Power
Mode, and the load average at the start (`loadavg_1m`) and end (`loadavg_1m_end`), so a run on a busy machine can
be recognized afterwards. Under load the numbers move in ways that look like hardware (below).

### Comparing

```sh
Tools/probe compare Tools/probes/results/M3-Ultra-2026-11-20 ~/Scratch/probes/M1-Max-2026-11-21 | column -t -s $'\t'
Tools/probe compare --probe '^insn$' --metric '^(latency_cycles|per_cycle)$' A B C
Tools/probe compare --min-change 5 A B        # only rows that differ by 5% or more
```

Each row is matched by its key columns (the instruction; the working set; the thread count; file, level, direction,
and lanes) and every value column becomes one output line: probe, row, metric, a value per directory, and each later
directory's ratio to the first (`-` where a row is missing or a value isn't a number). Rows only one machine has (lane
counts above the smaller machine's cores, instructions it lacks) show `-` for the other. Spread columns are left out
unless `--spread`. Ratios are later/first whatever the unit: for times (ms, ns, cycles of latency) below 1 is faster,
for rates (GB/s, per cycle) above 1 is.

To add a machine's results to the repository, copy its directory into `results/` (named `CHIP-YYYY-MM-DD`, as `all`
names it), add a line to the list below, and compare it with the M3 Ultra's.

## What each probe measures, and how

### `machine`

`key<TAB>value`: the date; `machdep.cpu.brand_string` and `hw.model`; `hw.ncpu` and, for each performance level
(`hw.nperflevels`; P cores are level 0), its name, core count, L1D, L1I, and L2 size and cores per L2; memory, line
size (128 bytes on every Apple silicon chip so far), page size; the `hw.optional.arm.FEAT_*` flags the probes care
about (AES, PMULL, SHA256, SHA512, SHA3, CRC32, DotProd, FHM, FP16, I8MM, BF16, SME, SME2); macOS, Xcode, clang, and
Swift versions; power source and Low Power Mode; the load average; the probes' git revision.

### `insn`: instruction latency and throughput

Each measurement is a loop entirely in inline asm (48 instructions, then `subs`/`b.ne`), run on one thread with
`QOS_CLASS_USER_INTERACTIVE` so the scheduler puts it on a P core:

- **Latency** (`latency_cycles`): one dependent chain, every instruction reading the previous one's result.
- **Throughput** (`per_cycle`): independent chains, as many instructions a cycle as the core issues. A chain issues
  at most once per latency, so **C chains can show at most C / latency per cycle**: 8 chains cap a 3-cycle instruction
  at 2.67, whatever the core can do. That is how the M1 Max probe's "2.7 a cycle" for `udot`, `pmull`, `aese`, and the
  vector multiplies came about; the M3 Ultra issues all of them at 4 a cycle with 16 chains. Reaching a core's rate
  needs latency × issue width chains (12 for a 3-cycle instruction on four pipes), so the probe runs 8, 16, and 24
  (v8-v31; 24 general registers for scalar instructions) and reports the best as `per_cycle`, the fewest chains within
  3% of it as `best_chains`, and every count's rate (`per_cycle_8chains` is the column comparable with older 8-chain
  data). More chains aren't always faster: on the M3 Ultra, three-source instructions (`eor3`, `bcax`, `tbx` with one
  register) drop from 4 to about 2.8 a cycle at 24 chains, which is why the best count is taken rather than the most.
- **Cycles** come from a dependent chain of scalar `add`s (1 cycle each), timed next to each instruction (best of 3)
  and before and after each run (best of 7; `insn-clock.tsv`). Each instruction's cycles use its own calibration,
  because the clock moves during a run: a P cluster's frequency depends on how many of its cores are busy, and on the
  M3 Ultra under load it read 3.58 to 4.06 GHz between instructions. Before measuring, the probe spins for 400 ms so
  the core reaches full clock: the first throwaway probe's calibration read 3.90 GHz cold and 4.05 warm, which is why
  its latencies read 1.93 where they are 2.00.
- **Three runs**, each a sweep over every instruction, each measurement the best of 3; the table has the medians and
  the spread (`(max − min) / median`, in %) of latency and of the best throughput. A spread above 5% means the core
  was shared or its clock moved: rerun on an idle machine. stderr warns when a run's clock read more than 5% below the
  median.
- Instructions: vector `add`, `eor`, `eor3`, `bcax`, `shl`, `zip1`, `uzp1`, `ext`, `rev32`; `tbl` with 1-4 table
  registers; `tbx` with 1, 2, 4 registers chained through the destination (`tbx 4 regs`: the destination-to-destination
  latency, 2 cycles) and with 2 and 4 chained through the index (`via index`: the full latency); `usra`, `mul.4s`,
  `umull`, `udot`, `pmull`, `pmull2`, `aese`, `aesmc`, the `aese`+`aesmc` pair (counted once per pair: fused cores show
  a short pair latency), `fmla.4s`, `sha256h`, `sha512h`, `ummla.4s` (I8MM), `bfdot.4s` (BF16), and scalar `crc32x`
  and `mul`. `Tools/probe insn --only NAME` measures a subset.
- **Portability**: compiled for `-mcpu=apple-m1` (the floor); I8MM and BF16 instructions are enabled per loop with
  `.arch_extension`. Each instruction beyond the base names its `hw.optional.arm.FEAT_*` sysctl, and when that isn't 1
  the row is `-` with a note on stderr; a SIGILL handler turns a wrong sysctl into a skipped row, so the probe never
  dies on an older chip. SME isn't measured (it needs streaming mode, a different kind of probe); `machine` reports it.
- The operands' values don't matter to these instructions' timing; the tables (v1-v4) and constants are fixed.

### `mem`: latency and bandwidth

- **Latency** (`mem-latency.tsv`): a pointer chase through one pointer per 128-byte line (the line size), lines
  visited in a random cycle so no prefetcher can follow, warmed by walking the whole cycle twice (capped at 2 million
  steps), then timed for about 150 ms, best of 3. Working sets 16 KB to 512 MB, and 1 GB on Macs with 16 GB of memory
  or more (never more than 1/16 of memory). The large sets include TLB misses (16 KB pages), as a real random access
  does. `latency_cycles` multiplies by the clock measured right after each row. Expect plateaus at L1D (about 4 cycles
  on M1 and M3), L2, the system-level cache, and DRAM; the L2 and SLC sizes show where they step (`machine.tsv` has the
  L1D and L2 sizes).
- **One-thread bandwidth** (`mem-bandwidth.tsv`): reads with 128-bit loads into four `eor` accumulators (64 bytes an
  iteration), writes with 128-bit stores, each about 4 GB moved per measurement (1 GB quick), best of 3, 32 KB to
  256 MB.
- **Threads** (`mem-threads.tsv`): N threads each read their own buffer 4 times, started together; GB/s is all the
  bytes over the wall time, best of 3. N comes from `Tools/probe steps`: 1, 2, 3, 4, 6, 8, 10, 12, 16, … up to
  `hw.ncpu`, plus half the P cores, the P cores, one more than the P cores, and each level's total, so every chip gets
  its own boundaries. Each thread's buffer is 256 MB, halved until all of them fit in 1/8 of memory (an 8 GB M1 with
  8 cores: 128 MB each); `per_thread_MB` records it, and compare it before comparing rows. Above the P-core count
  threads run on E cores.

### `bytes`: Bytes' kernels (BytesProbe)

Built from the repository's `Bytes/` (whatever is checked out: compare results from the same Bytes revision, or say
which). Fixed parameters, so rows compare across machines:

- **Checksums** (`checksums.tsv`): `CRC32.checksum` and `Adler32.checksum` over random bytes, 64 B to 128 MB, each size
  repeated to about 512 MB a timing, best of 9, one thread. Bound by `udot` latency (Adler-32) and `pmull` folding
  (CRC-32) in cache, by memory beyond.
- **Lanes** (`lanes.tsv`): `ParallelDeflateEncoder` and `ParallelDeflateDecoder`, Silesia's dickens and mozilla,
  levels 1 and 6, 256 KB chunks, raw format, at the `steps` lane counts. Encoding: one warm-up, then the median of 7.
  Decoding: a stream encoded once with independent chunks (so the decoder can split it), checked to round-trip, then
  the median of 9. ms per call.
- **Segments** (`segments.tsv`): the decoder's `lastSegmentCount` and time (median of 5) at **every** lane count from 1
  to `hw.ncpu`, for mozilla, dickens, samba, x-ray, and ooffice at levels 1 and 6. A segment count of 1 at more than
  one lane would mean the decoder fell back to decoding sequentially. Before 2026-11-20 it did whenever one of its
  `4 × lanes` split points was a false `00 00 FF FF` marker: mozilla level 1 at 11, 22, 25, and 28–32 lanes (the
  first probe, at 8, 16, 20, 24–28, and 32, found only 25, 28, and 32). Now a false marker fails only its own segment,
  which is decoded again in place, and the reference set (`results/M3-Ultra-2026-11-20/`) has no such row: every
  file's count is at or a little under `4 × lanes` (mozilla level 1: 98 segments at 25 lanes, 124 at 32), and some
  stop growing (dickens and x-ray at 96, ooffice at about 72, samba from 9 lanes up below `4 × lanes`). The split
  points depend only on the lane count, so these counts are the same on any machine. Probe every count, not just
  round ones.
- **E cores in lane counts**: lanes beyond the P cores land on E cores. The encoder takes chunks from a queue, so
  slow cores cost nothing at the end and it gains (M1 Max 8 → 10 lanes: 10-13%; M3 Ultra 24 → 32: 14%); a decoder that
  splits work evenly waits for its slowest segment. The P-core count and one more are always in `steps` for this.

## Pitfalls met so far

- **Too few chains** read as low throughput (above). Check `best_chains`: if it is the largest count, the core may do
  more than the probe shows.
- **A cold or shared core** reads a low clock and turns every cycle count wrong by the same factor. The per-instruction
  calibration absorbs a moving clock; large spreads still mean a busy machine.
- **4-register `tbl`/`tbx` throughput is erratic under load**: on the busy M3 Ultra it read anywhere from 0.9 to 1.33
  a cycle between back-to-back runs at the same chain count, against 1.34-1.39 on the idle machine. Judge those rows
  only from an idle run.
- **Shared resources**: the memory and lanes tables move with other processes' memory traffic (the busy M3 Ultra's
  16 MB latency read 26-35 ns against 15 idle; every one-core GB/s row read about 0.89 of idle, the clock's ratio); the instruction table barely does once the clock is calibrated.
- **The machine's own background work** after moving to it (Spotlight and `mediaanalysisd` indexing new files) made
  one row read 2.2x slow on the M1 Max: run something unchanged first, or wait (AGENTS.md, "A second machine").

## Result sets

| Directory | Machine | Notes |
|---|---|---|
| `results/M3-Ultra-2026-11-20/` | M3 Ultra (24 P + 8 E), 256 GB, macOS 27.2.1, Xcode 27.3 | `Tools/probe all` on the idle machine (load 3.1 at the start), right after Bytes' full benchmark run `m3-final`. Bytes as of that run: the 128-byte-step `udot` Adler-32 and the parallel DEFLATE decoder that no longer falls back (no one-segment rows at any lane count). `tbl 4 regs` read 1.08 a cycle here, 1.33–1.39 in two other idle runs the same day: it is bimodal, so rerun `insn --only tbl` before reading much into it. |

### The M1 Max (historical, not a result set)

The M1 Max (8 P + 2 E, 64 GB, 3.23 GHz) was probed on 2026-11-19 with an earlier throwaway probe: 8 chains only, and a
calibration that read 2.82 GHz, so its cycles were rescaled by assuming a vector `add` takes 2 cycles and issues 4 a
cycle (±15%). Its numbers, from `Bytes/Benchmarks/RESULTS.md`, are listed here for reference only; they aren't in
`results/` because they don't come from this probe, and `compare` can't use them:

| Instruction | Latency (cycles) | Per cycle (8 chains) |
|---|---|---|
| `add`, `eor`, `eor3`, `bcax`, `shl`, `zip1`, `uzp1`, `ext`, `rev32`; `tbl` 1-2 registers | 2 | 4 |
| `tbl` 3 / 4 registers | 4 | 1.9 / 1.3 |
| `tbx` 4 registers | 8 | 1.0 |
| `usra`, `mul.4s`, `umull`, `udot`, `pmull`, `pmull2` | 3 | 2.7 (the 8-chain cap) |
| `aese` / `aesmc`; the pair | 3 / 2; 6 per pair | 2.7 / 4; 2.6 pairs |
| `fmla.4s` | 4 | 2.0 (the 8-chain cap) |
| `sha256h`, `sha512h` | 5, 3 | 0.5 |

Memory latency: 0.93-1.2 ns (16-128 KB), 5.3-5.6 ns (256 KB-2 MB), 6.3 / 8.5 ns (4 / 8 MB), 35 / 52 ns (16 / 32 MB),
100 ns (64 MB), 121-124 ns (128-256 MB). Read bandwidth (256 MB per thread): 61 GB/s on one thread; 115, 114, 113, 102,
115, 126 GB/s on 2, 3, 4, 6, 8, 10. One-thread stores 62 GB/s. CRC-32 58-62 GB/s (256 KB-128 MB); Adler-32 (`udot`)
8.2 / 56.0 / 57.2 / 58.0 / 55.7 GB/s at 64 B / 1 KB / 16 KB / 1 MB / 8 MB. Parallel DEFLATE at 1-16 lanes: the table in
RESULTS.md's 2026-11-19 section.

**To make the M1 Max's result set**, on the M1 Max: pull the repository, `Tools/corpus fetch`, then `Tools/probe all`
on the idle machine, plugged in (it's a laptop: Low Power Mode off). Copy `~/Scratch/probes/M1-Max-YYYY-MM-DD/` to
`Tools/probes/results/`, add it to the table above, and compare:

```sh
Tools/probe compare Tools/probes/results/M3-Ultra-2026-11-20 Tools/probes/results/M1-Max-YYYY-MM-DD | column -t -s $'\t'
```

The 16- and 24-chain columns will give the M1 Max's real rates for the 3-cycle instructions and `fmla`, which the
2026-11-19 probe couldn't see.
