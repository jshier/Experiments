# NativeAEA performance log

M3 Ultra (24 performance and 8 efficiency cores), macOS 27.2, Swift 6.4.4, internal SSD, warm cache. Input: Xcode
27.3 beta 2 (`Xcode_27.3_beta_2.aea`, 2.17 GB; 10.46 GB of Apple Archive stream in 624 xz segments of 16 MiB; 167,541
entries). The format is in [FORMAT.md](FORMAT.md). Package benchmarks: baselines `aea-1` (Compression's decoder)
and `aea-2` (both decoders, the synthetic archive and Xcode's: `NATIVEAEA_ARCHIVE=…/Xcode_27.3_beta_2.aea`); the
synthetic archive is `Tools/test-data fetch nativeaea-synthetic`.

## 2026-11-18: a reader and extractor for Apple Encrypted Archives

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

- An LZBITMAP encoder in Swift: 27 CPU-s of Compression's encoder is the largest CPU cost after decoding (the format
  isn't documented).
- Writing files in an order that spreads the file system's work (the archive's order puts each directory's files
  together).
- Cold-cache runs (`purge` needs root).
