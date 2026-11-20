# Expanding Xcode's `.xip` natively: implementation and performance

`nunarchiver` (formerly `unaea`) now expands Xcode's `.xip` downloads as well as `.aea` archives. It writes exactly what
Apple's `xip --expand` writes, byte for byte down to the stored APFS compression, 4.8x faster than Apple's tool and
2.2x faster than [unxip](https://github.com/saagarjha/unxip). It also verifies everything `xip` doesn't: the RSA
signature and its chain to Apple Root CA, the table of contents, and both members' SHA-1s.

Every format and protocol involved is implemented in Swift on Bytes; C libraries appear only in tests and benchmarks,
as references. The format is described in [FORMAT.md](FORMAT.md) §4, and the raw measurements are in
[RESULTS.md](RESULTS.md) (2026-11-19, xip).

Setup: M3 Ultra (24 performance and 8 efficiency cores), macOS 27.2, Swift 6.4.4, internal SSD, warm cache, idle
machine. Rounds are interleaved; each run writes into a fresh `*.noindex` directory.

## Results

Xcode 27.2 RC (`Xcode_27.2_Release_Candidate.xip`: 2.05 GB in, 10.35 GB out, 167,193 items), three rounds:

| Tool | Wall (median) | vs nunarchiver | User | System | Cores busy | Peak memory | Output |
|---|---|---|---|---|---|---|---|
| `xip --expand` (Apple) | 47.79 s | 4.82x | 148 s | 38 s | 3.9 | 1.44 GB | LZVN forks, 3.67 GiB |
| `unxip` | 21.59 s | 2.18x | 126 s | 73 s | 9.2 | 5.05 GB | LZFSE forks, 3.38 GiB, no file times |
| `unxip -c` | 18.67 s | 2.33x (vs plain) | 58 s | 67 s | 6.7 | 4.02 GB | plain, 9.08 GiB |
| **`nunarchiver -d`** | **9.92 s** | 1 | 111 s | 36 s | 14.9 | 1.45 GB | **identical to Apple's** |
| `nunarchiver --disk-compression lzfse` | 9.31 s | 2.32x faster than unxip | 91 s | 37 s | 13.7 | 1.46 GB | LZFSE forks, Apple's choice of files, 3.48 GiB |
| `nunarchiver --disk-compression none` | 8.03 s | 2.33x faster than `unxip -c` | 46 s | 34 s | 9.9 | 1.43 GB | plain |
| `nunarchiver` (verify + list) | 2.08 s | | 46 s | 0.7 s | 22.6 | 0.95 GB | nothing written |

The other two xips agree. On 27.1 RC, Apple took 47.3 s, unxip 21.3–21.5 s, and nunarchiver 9.85–10.11 s. On
27.3 beta, Apple took 47.5–47.6 s, unxip 21.3–21.6 s, and nunarchiver 9.97–10.05 s. Every round of every tool fell
within ±2% of its median.

## What a `.xip` is

A xip is a XAR archive. A 28-byte big-endian header is followed by a zlib-compressed XML table of contents (TOC) and
then a heap. The heap holds:
- the TOC's SHA-1;
- a 256-byte RSA signature;
- `Content`, 2 GB of pbzx: 16 MiB blocks, each an xz stream;
- `Metadata`, a 303-byte bzip2 property list.

Decoded, `Content` is a cpio (odc) archive of Xcode.app. FORMAT.md §4 has the details.

## What was built

All of it is in Swift, in Bytes (reusable) or NativeAEA (the xip itself).

| Piece | Where | New for the xip? |
|---|---|---|
| XAR header and TOC: zlib inflated with Bytes' DEFLATE, then a small XML scanner | `NativeAEA/XAR.swift` | new |
| TOC checksum, and `Content`'s and `Metadata`'s SHA-1s (BytesCrypto `SHA1`) | `XIP.swift` | new use |
| RSA PKCS #1 v1.5 verification, 1024–4096-bit keys, SHA-1/256/384/512 | `BytesCrypto/RSA.swift` | new |
| X.509 `isSigned(by:)` for RSA issuers; chain policies (`.archive` for AEA's ECDSA, `.softwareUpdate` for xip's RSA, with the Software Update EKU and the pinned Apple Root CA) | `BytesCrypto`, `AEASignature.swift` | new |
| bzip2 decoding (`Metadata`) | `BytesCompression/BZip2Decoder.swift` | new |
| pbzx blocks: the `pbz` block layout from the AEA work, with xz blocks (Bytes' LZMA2 and `.xz` decoder) | `BlockStream.swift` | reused |
| cpio odc walker, which feeds the same `ArchiveSink` extractor as Apple Archives | `CpioWalker.swift` | new |
| LZVN encoding byte for byte as Compression's (`decmpfs` type 8) | `BytesCompression/LZVNEncoder.swift` | reworked |
| `xip --expand`'s storage rules and metadata order | `DiskCompression.swift`, `Writer.swift` | new rules |

C appears only in tests and benchmarks: libbz2 (a system library), the lzfse reference (in `Tools/test-data`), and
Compression and Security as the references being compared against.

### The pipeline

1. **Open.** Read the header, inflate and parse the TOC, and check its SHA-1. Then verify the RSA signature over that
   checksum, and the certificate chain at the TOC's `creation-time` (the signature covers that time). Decode
   `Metadata` and check its two SHA-1s. All of this takes under 10 ms (`--info`).
2. **Decode `Content`.** 32 threads decode the 617 xz blocks with positioned reads into a pool of 16 MiB buffers,
   one per decoding and writing thread plus 8. A separate thread computes `Content`'s SHA-1 with 4 MiB positioned
   reads, so verification costs no wall time.
3. **Walk.** One thread walks the cpio stream in place. Each entry's contents are pointers into decoded blocks and are
   never copied. A header and name that cross a block boundary are copied into the next buffer's carry region, as
   with Apple Archive headers. Each file becomes a job holding a reference to its blocks, released once the file is
   written.
4. **Write.** 24 writer threads compress outside a semaphore that admits 6 threads into file system calls at once.
   Writes are `open`, data or `fsetxattr` for the fork, then `com.apple.decmpfs`, `fchflags(UF_COMPRESSED)`, and times
   and mode in one `fsetattrlist`. The order matters: setting `UF_COMPRESSED` resets the modification time.
5. **Finish.** Hard links (later names of a file) are made after the writers, on 6 threads, with `linkat(…,
   AT_SYMLINK_NOFOLLOW_ANY)` so no path through a symbolic link is followed. Then symbolic links, then directory
   metadata.

Concurrency uses plain threads, `DispatchSemaphore`, and the lock-protected job queues from the AEA work. Swift
concurrency's pool was measured as an alternative in the AEA work (`--scheduler tasks`) and tied with threads. Nothing
allocates per entry or per block:
- buffers and encoders are made once per thread;
- Bytes' decoders and encoders run with zero-malloc benchmark thresholds (LZMA, bzip2, LZVN, RSA verification).

Vector instructions are used where the work allows:
- SHA-1 runs on ARM's SHA instructions (`sha1c`/`sha1p`/`sha1m`), through `CBytesCrypto`.
- The LZVN encoder handles a hash bucket's stale-entry checks and distances as `SIMD4` lanes.

Serial chains get independent work instead. The bzip2 decoder's inverse BWT runs 24 interleaved walks, and xz, a
range coder, gets its parallelism from the 617 blocks.

## Matching Apple's output

`xip --expand` documents none of its rules. They were found by expanding Xcode 27.2 with both tools and comparing every
item: `stat`, `xattr`, contents, and a hash of each file's stored `com.apple.decmpfs` attribute and resource fork. Each
candidate rule was then fitted against all 126,027 files.

- **Which files are compressed.** Files over 16,384 bytes that aren't PNGs, and whose LZVN fork saves at least a fifth
  of the 4 KiB blocks: `ceil(fork/4096) × 5 ≤ ceil(size/4096) × 4`. Measured as a byte ratio, the cutoff couldn't be
  separated: ratios from 0.787 to 0.864 went both ways. Counted in blocks, every file fits.
- **What's in a chunk.** Compression's LZVN (algorithm 0x900) is the open lzvn reference with a different hash
  (`((v & 0xFFFFFF) × 0x9E3779B1) >> 18`) and the reference's room checks. This was read from `libcompression` with
  Binary Ninja, and checked with a patched C reference on every corpus file and capacity. Bytes' encoder now takes
  that parse by default. Before the change, 26,171 forks differed.
- **How much room each chunk gets.** `xip` gives each chunk exactly its own size. LZVN needs 1–10 bytes of room beyond
  its stream, so a short last chunk that shrinks by less than that is stored raw (`0x06` + bytes). That rule
  accounted for the last 42 differing files. `aa extract` instead gives every LZBITMAP chunk 64 KiB of room.
- **Times.** Files keep their cpio modification time. Directories and symbolic links keep the time of extraction, in
  both tools.

Result: every file is identical to Apple's in metadata, contents, storage decision, and stored bytes. Only the
directories' and links' extraction times differ.

## Why it's faster

**Against Apple.** `xip --expand` keeps about 3.9 cores busy on average and takes 47.8 s; its user time (148 s) is
higher than nunarchiver's (111 s) for the same output. nunarchiver keeps about 15 cores busy, and its system time
(36 s) is no higher than Apple's (38 s). The speedup comes from parallelism:
- decoding runs on every core, ahead of the writers;
- compression runs on 24 writer threads, outside the file system limit;
- the file system gets as many threads as APFS handles well (6), and no more.

**Against unxip.** unxip is well parallelized (9.2 cores), but differs in four ways that each cost time or memory:
- **No limit on concurrent file system calls.** Its system time is 73 s against nunarchiver's 36 s. The AEA work
  measured APFS creation contending beyond about 8 threads, and the width sweep below shows the same for the xip.
- **Whole files as arrays.** unxip copies each file into `[UInt8]` buffers, and peaks at 5.05 GB against 1.45 GB.
  nunarchiver writes from the decoded blocks in place.
- **Compression's LZMA and LZFSE.** Bytes' xz decoder takes 16% less time than Compression's on this content
  (`--decoder system`: 2.50 against 2.10 s for verify + list, 55.6 against 46.7 s of user time). Bytes' LZFSE encoder
  is Compression's byte for byte.
- **More files compressed.** unxip compresses every file over 4 KiB whose LZFSE is smaller: 50,073 files against
  Apple's 27,035. Its output is 3.38 GiB, smaller, but it took longer to write and doesn't match Apple's.

Compared like for like, with the same codec (LZFSE) or with no compression, nunarchiver is 2.3x faster either way,
while also verifying the signature and checksums and setting file times, which unxip doesn't.

## Where the time goes now, and what didn't help

From `nunarchiver -v` (9.87 s):
- **Walk: 6.58 s.** 5.36 s of it is spent waiting for decoded blocks. The blocks aren't slow to decode (decoding alone
  takes 2.1 s); they're held by writers until their files are written. The writers are the bound, at the file
  system's best width.
- **Later hard-link names: 2.59 s**, 26,062 `linkat`s on 6 threads. APFS spends about 280 µs of kernel CPU on every
  link, measured alone, so this is the largest serial phase.
- **Last writers and symbolic links:** 0.42 s and 0.28 s.
- **Writer time, summed over threads:** 33.8 s waiting for admission to the file system, 14.9 s compressing, 9.2 s in
  `open`, 3.9 s writing data, 3.3 s writing forks, 3.1 s setting times and flags, and 1.6 s in `close`.

Measured alternatives, all no better:

| Change | Xcode 27.2 wall | Notes |
|---|---|---|
| File system width 4 | 11.2 s | Writers starve |
| **Width 6 (default)** | **9.8–10.1 s** | |
| Width 8 | 10.45 s | APFS contention |
| Width 12 | 11.2–11.4 s | |
| 32 or 64 extra decoded blocks | 9.8–10.0 s | Shorter walk wait, same total |
| `--hard-link-threads 4` (links during the writes) | 10.9–11.2 s | +11% time, +30% system time |
| Compression's xz decoder | +0.4 s (in list mode) | |

What's left is APFS itself: file creation, its per-link cost, and compressed-file metadata. With compression off,
nunarchiver takes 8.0 s, so encoding Apple's LZVN forks adds 1.9 s of wall time on top of the file system work.

## The building blocks' own numbers (Bytes)

| Component | Against | Result |
|---|---|---|
| RSA-2048 verify | Security.framework | 13 against 19 µs (1.5x), 0 mallocs against 14 |
| bzip2 decode (Silesia, `-9`) | libbz2 1.0.8 | 3.3–4.7x faster on the published table, 0 mallocs after its 7.8 MB workspace |
| LZVN encode (Compression's parse, byte for byte) | Compression 0x900 | 1.07–1.76x faster |
| xz decode (the xip's 617 blocks, 32 threads) | Compression's LZMA | 16% less wall and user time |

Details are in Bytes' `Benchmarks/RESULTS-rsa.md`, `RESULTS-bzip2.md`, and `RESULTS-lz4-lzfse.md`.

## Verification and tests

**Default checks.** `nunarchiver` verifies:
- the TOC's SHA-1;
- the RSA signature;
- the chain: Software Update ← Apple Software Update Certification Authority ← Apple Root CA, pinned by SHA-256, each
  certificate valid at the archive's creation time, the leaf restricted to Apple's software-update signing usage;
- `Metadata`'s archived and extracted SHA-1s;
- `Content`'s SHA-1.

`--no-verify` skips the signature and `Content`'s SHA-1; the TOC's and `Metadata`'s checksums are always checked.
`--untrusted-chain` checks the signature without evaluating the chain.

**Tests** (`XIPTests`, part of NativeAEA's 37 passing tests):
- Synthetic xips are written in Swift: XAR with a zlib TOC, pbzx of xz blocks at three block sizes, a bzip2
  `Metadata`. They're signed with `openssl pkeyutl` under a generated three-certificate chain.
- `xip --expand` expands the same archives, and the outputs are compared item by item, including stored bytes.
- Bad signatures are rejected:
  - an unsigned xip;
  - a signature that doesn't verify;
  - a chain ending at another root, or at an untrusted one;
  - a certificate not yet valid at the archive's creation time;
  - a leaf without Apple's software-update usage.
- Damaged archives are rejected: a wrong header, the TOC checksum, `Metadata` as stored, `Content` (its SHA-1), and cpio streams with a bad
  header or no trailer.
- When the real Xcode xips are present, their signatures and chains are verified.

The Xcode 27.2 comparison above was run by hand (`compare-xip.sh` in the session's scratch), on the release build.
