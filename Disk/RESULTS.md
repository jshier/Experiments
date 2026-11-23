# Disk: measurements and decisions

M3 Ultra (24 performance and 8 efficiency cores), macOS 27.2, Swift 6.4.4 (Xcode 27.3), internal SSD, warm cache.
**Every time below was taken under load** (other agents building and benchmarking: load average 3–6), so times are
indicative; instruction, call, and allocation counts are the firm numbers. Baselines (slimmed) in
`.benchmarkBaselines/DiskBenchmarks/`: `syscalls` (the whole suite with the `SyscallCounting` trait: the `Disk syscalls`
column), `disk-1` (the whole suite without it), `ab-1`/`ab-2` (two interleaved rounds of the option comparisons). `disk-1` ran after `syscalls`, under lighter load: its
small-file rows read 10–30% faster (20,000 files: 460 against 573 ms), the same code but for the counter.

```sh
swift package --disable-sandbox benchmark                                                    # times, mallocs
swift package --traits SyscallCounting --scratch-path .build-syscalls --disable-sandbox benchmark   # + Disk syscalls
Tools/bench-table Disk --metric 'wall|Disk syscalls|Malloc' syscalls disk-1
```

## 2026-11-23: explicit descriptor lifetimes, mappings that can't fault, quarantine on any volume, composed errors (M1 Max)

The survey's first four bugs (Writeups/Library-Survey-2026-11-23.md), fixed in Disk and its clients.

**Descriptors closed on purpose, and checked in every test** (ARCHITECTURE.md §8). `Destination.init` closed its
descriptor when the quarantine failed, and `deinit` closed the same number again: if another thread had opened a file in
between and got that number, `deinit` closed *its* file. The fix isn't the one line: descriptors are now owned
(`OwnedDescriptor`, noncopyable, `consuming close()`) or shared (`DescriptorSlot`, an atomic exchange to -1 on close), and
every owner has an explicit `close()` at the end of its use: `Destination` (or `publish`/`publishUnwrapped`/`discard`),
`InputFile`, `OutputFile` (whose `close()` throws `close`'s error), NativeAEA's archives, the extraction's own
destinations (closed as soon as Disk's last pass returns). `deinit` only audits: `DescriptorAudit` counts a descriptor
still open, per task, and Bytes' `LifetimeChecks` trait fails any test that drops one or leaves a file open under its
temporary directories. On in every suite of Disk, NativeZip, and NativeAEA (72 + 51 + 67 tests) from the start; it found
the tests' own unclosed destinations and archives (about 130 sites, closed), no library leak, and one false positive (a
shared fixture's directory charged to whichever test made it first: made outside the record now).

Debug builds inject failures into Disk's calls (`SyscallFaults`, task-local) and record every open and close:
`LifetimeTests` fails `fsetxattr`, `pwrite`, `fsetattrlist`, `mkdirat`, `openat`, `linkat`, `symlinkat`, `fchflags`, and
`unlinkat` in turn during an extraction and checks no descriptor is closed twice, left open, or closed late; run against
the old `Destination.init`, the quarantine test fails all three checks. Release builds compile none of it.

Cost, from the release object (per-function instruction counts against HEAD): taking a writer's `OwnedDescriptor?` is a
load, a tag test, and a store; `FileOutput.writeWhole`, `openStream`, and `finishWhole` grew 13–17 instructions, no calls
(the descriptor's kind is a one-byte enum: as a `StaticString` it made the optional 32 bytes). Against the tens of
thousands of kernel instructions each file's `open`/`write`/`close` costs, nothing measurable.

**A mapped archive truncated under the reader** (C probes on disk images, macOS 27.2):

| Volume | Pages past the new end, after `ftruncate` |
|---|---|
| APFS (cached, and cold through a fresh clone) | the original bytes, no signal |
| HFS+ | the original bytes, no signal |
| FAT (MS-DOS), exFAT | `SIGBUS` on 675 of 676 pages |

So NativeZip could crash on an archive on a USB stick or SD card that something truncated while it extracted.
`MappedFile(path:)` now maps the file on APFS and HFS+ and a private copy elsewhere (`fcopyfile` into an unlinked
temporary file; `source: .file`/`.copy` force either). Cost of the copy, 256 MB from an exFAT image: cold, 82 ms to copy
and 12 ms to touch, against 137 ms of page faults on the file itself (bulk reads beat faults); cached, 131 against 12.
A clone was the first idea and is wrong twice: FAT has none, and a clone's page cache is its own (a cached gigabyte read
through a fresh clone: 1,524 against 46 ms). `MappingBulkTests` truncates a file on an exFAT image under the mapping
and reads every byte back. Removing the media under a mapping of the file itself presumably still faults (not tested).

**Quarantine on a volume without extended attributes.** `ENOTSUP`/`EOPNOTSUPP` from the quarantine's `setxattr` failed
the item (the destination itself, with `quarantinesDestination`). Now the item is made, counted in
`Destination.unquarantinedItems` (shared with reopened destinations, so an app reads its staging directory's count) and
`ExtractionReport.unquarantinedItems`; any other error still fails it. Tested by fault injection: 7 counted for 3 files,
a link, and 2 directories (one quarantined twice: made as a parent, then listed); `EIO` fails each.

**Errors composed, not flattened.** `DiskError.source(any Error)` (and `init(wrapping:)`, `unwrapped`,
`isCancellation(_:)`, `CancellationReporting`) are gone. `ContentSource` declares its `Failure` (default `Never`);
`write(_:to:)` throws `EntryError<Failure>` (`.disk(DiskError)` or `.source(Failure)`); `EntryFailure`,
`ExtractionReport`, and `ExtractionError<PlanFailure, SourceFailure>` (`.disk`, `.source`, `.plan`) carry it. A planner
call after a source's failure stopped the extraction throws `DiskError.stopped` (the plan's closure can't carry the
source's type); the extraction's error is the source's own. NativeAEA's source can't fail (`Never`); NativeZip's fails
with `ZipError`.

Tests: 72 in 17 suites (~15 s), plus `MappingBulkTests` (an exFAT image, ~4 s) in the bulk set.

## 2026-11-22, late: access by usage, typed timings, one allocation for counters (baselines `pass2-old-{1,2}` → `pass2-new-{1,2}`, M1 Max)

HEAD (425420e) against the working tree, the whole suite, two interleaved rounds on an otherwise idle machine (37 GB
free: the 98%-full volume of the evening's run is gone).

- **Access follows usage** (AGENTS.md's rule). Public symbols listed from the symbol graph, each name looked for in
  NativeAEA's, NativeZip's, and the app's sources, then every client built: 26 symbols to `package` (`FileWriter` and its
  `StoredForm`, `MemorySource`, `TreeRemoval`, `Destination`'s creation methods, `DiskError.sourceError`, the decmpfs
  policy's rules, `ExtractionReport`'s queue and file counts), 12 to `internal`, and `Destination.setExtendedAttributes`
  removed (no caller). Six types a name search marked unused stayed public, because clients use them without naming them:
  the three option policies (`settings.permissions = .exact`), `MappedFile.Access`, `EntryFailure`, and
  `EntryPath.Sanitized` (what `sanitize` returns; NativeZip calls it).
- **`Extraction.run(into:source:settings:_:)`** (was `options:`: the type is `ExtractionSettings`).
- **Typed timing keys:** `ExtractionReport.phaseSeconds` is `[ExtractionPhase: Double]` (`.planning`, `.hardLinks`,
  `.specialFiles`, `.symbolicLinks`, `.deferred`, `.directories`) and `writerSeconds` is `[WriterWork: Double]`; they
  were keyed by strings.
- **Counters in one allocation:** the writers' timings (11 kinds) and the `SyscallCounting` trait's counters are a
  `RelaxedCounters` (BytesAsync) instead of an array of `RelaxedCounter` objects.

| Rows | Old → new, both rounds |
|---|---|
| Mallocs, every extraction row | −11 per run (single writer 83 → 72, 20,000 files 145 → 134, one 32 KB file 116 → 105, Xcode-like 238 → 227): the 11 counter objects and their array |
| Instructions, small files and workers | within the table's resolution (rows at 21–23 G read ±4.5%, one step of two digits, both ways) |
| Instructions, `Compressed: 2,000 x 1–64 KB` | plain −2.5 / −2.6%, the codecs −0.8 to +2.0% |
| Times | within ±5% both ways but `Extended attributes` (+11 / +4%) and `Workers: 24 writers, width 16` (+3.4 / +3.1%), neither in code this changed |
| 1 GB single files and probes | as before: the kernel's state (probes, unchanged code, −3 to +27%) |

## 2026-11-22, evening: bridges without allocations (baseline `alloc-new-1`; NativeAEA's RESULTS.md has the trace)

A compressed large file's piece whose first chunk starts in earlier pieces (a bridge) cost two arrays: `Bridge.parts`
in the queued job and `bridgeBases` (the bridged pieces' addresses) in the writer. Now `Bridge` holds its first part
inline and an array only from the second, which only pieces smaller than a chunk make (NativeAEA's segment-sized pieces
never do), and the writer gathers the head chunk from the bridged pieces where it compresses it, reading each address
as it goes. `WriteJob` grows 256 → 328 bytes, the 16,384-slot ring 4.0 → 5.1 MiB (uninitialized: touched as it
cycles). `writesLargeFilesInPieces` covers bridges of up to six pieces (12,000-byte pieces).

| Benchmark | `unify-new-1`, `-2` → `alloc-new-1` |
|---|---|
| Single writer, Workers (20,000 files), Xcode-like LZBITMAP rows | instructions and mallocs unchanged (Xcode-like's own ±20 mallocs) |
| Large file: 1 GB, LZBITMAP | 38 G, unchanged; mallocs 116 → 123 |
| Large file: 1 GB, one write / 8 MiB writes | mallocs 100–110 → 108–117; instructions +11–13% (kernel: the volume was 98% full, NativeAEA's RESULTS.md) |

The large-file rows' 7 more mallocs look per writer, not per piece: the same count in rows of 128 pieces and of one
write, and NativeAEA's trace shows the writer tasks' allocator slabs (taken as an async stack first deepens) going 14 →
21 in `Writer.run` and 0 → 8 in `writePiece`, consistent with larger frames holding larger jobs. Not traced in these
rows themselves.

## 2026-11-22, later: the cleanups (baselines `unify-old-{1,2}` → `unify-new-{1,2}`, M1 Max)

HEAD (5f28068) against the cleanups, the whole suite, two interleaved rounds on an otherwise idle machine. In Disk:
`Destination.reopened(with:)` (clients extract into the caller's `Destination`); `ExtractionProgress.read(entryWeight:)`
(the entry-weighted fraction, never going back, moved from the app); `DiskError(wrapping:)`, `unwrapped`,
`isCancellation`, `CancellationReporting`, `.endOfFile`, `.tooLarge`; `MappedFile(path:)` throws `DiskError`, and
`InputFile.map(range:)`; counted `pread`/`read` for the `SyscallCounting` trait; the ACL parse on a
`LittleEndianBytesReader`; `JobQueue`'s clock and counter from BytesAsync (`MonotonicClock`, `RelaxedCounter`);
`DiskTestSupport` (a product: `readTree` with `readdir`, `SystemAttributes.ignoredByDefault`).

Nothing Disk does changed by more than the rows' spread:
- **Small files** (single writer and every worker/width combination, 2,000 and 20,000 files, the probes): instructions
  within 0 to −1.5% where the table resolves them. Rows at 21–23 G show ±4.5%: one step of the table's two digits (22 G
  against 23 G), in both directions across rows. Times within ±5%, both directions. `Single writer: 2,000 small files`
  read −3.3% and −3.7% (2.11 → 2.03–2.04 G, kernel included).
- **Mallocs:** unchanged but for `Workers: Xcode-like, LZBITMAP` (503 → 487, 491 → 511: the multi-writer row's own
  ±20).
- **1 GB single files** (`Large file: 1 GB, one write`, `8 MiB writes`, and the `Probe: 1 GB file` rows): instructions
  −8 to +27% and times 0.3x–2.4x in either direction, **in the probes too, which are raw `pwrite`/DispatchIO calls in
  the benchmark itself, unchanged between the trees**. These rows measure the kernel's state (page cache and APFS
  allocation after a gigabyte written per sample, the new side always running after the old), not Disk's code. Judge
  them only within one process.

## 2026-11-22: `InputFile`, the read side (NativeAEA's RESULTS.md has the measurements)

`InputFile` (`InputFile.swift`) is the read side beside `MappedFile` and `OutputFile`: `init(_: FilePath)` (read-only,
`O_CLOEXEC`), `count` from `fstat`, `read(at:into:)` filling a `MutableRawSpan` or appending to an `OutputRawSpan` (a
`pread` loop, EINTR retried, a short read at the end `.endOfFile`), `read(at:count:) -> [UInt8]` (size checked before
allocating), `map(access:)`, and `contents(of:maximumCount:)` for small files (`read(2)` to the end, so FIFOs and
`/dev/stdin` work; `.tooLarge` past the cap). `Sys.pread` and `Sys.read` are counted under `SyscallCounting`, and
`MappedFile(path:)` opens through the counted wrappers. NativeAEA now reads every file through it; its instructions and
data-path `pread`s are unchanged (2 `lseek`s and 2 `open`s fewer per archive).

## 2026-11-21 (later): publishing as Archive Utility does, measured against it (baselines `v1-before` → `v1-after`)

Nunarchiver's last round: its output compared with Archive Utility's, item by item, and what differed fixed here and
in NativeZip and NativeAEA. The app's own publishing code (a `chmod`, a `setxattr`, a `renameatx_np` loop) moved into
`Destination`.

### The comparison

Each archive copied into a directory of its own under `~/Scratch`, the copy given a download's quarantine
(`0081;673e3000;Safari;…`), expanded there by Archive Utility (`open -W -a "Archive Utility"`, macOS 27.2) and by
Nunarchiver's Release build; both trees through one manifest tool (path, type, mode, flags, owner and group, size,
modification time to the nanosecond, hard-link group, link target, SHA-256 of the contents, every extended attribute
with its size and SHA-256 read raw (`XATTR_SHOWCOMPRESSION`; the quarantine's value itself), and the ACL as text), then
`diff`. Times later than the corpus (set by the expansion itself) compare as NOW. The source tree has nested, empty,
0700, and 0555 directories; 0444, setuid, and hidden-flag files; relative, absolute, directory, and dangling links, one
with its own old time; extended attributes on files and a directory; Finder info; a 5,000-byte resource fork; an ACL;
a decomposable name (`Ünïcode dir/naïve file.txt`); old times on files, directories, and the root.

| Archive | Made by | Items | Before this round | Now |
|---|---|---|---|---|
| `ditto-keepparent.zip` | `ditto -c -k --sequesterRsrc --keepParent` | 24 | `__MACOSX` extracted beside `Tree`, so both in a folder; no attributes, fork, or ACL; link times; name form | identical |
| `ditto-contents.zip` | `ditto -c -k --sequesterRsrc` (several top-level items) | 24 | `__MACOSX` extracted; folder 0755; the rest as above | identical |
| `ditto-inline.zip` | `ditto -c -k --keepParent` (`._` files beside their items) | 24 | `._` files extracted; the rest as above | identical |
| `infozip.zip` | `zip -r -y` | 24 | link times; name form | identical |
| `infozip-nodirs.zip` | `zip -r -y -D` (no directory entries) | 23 | link times; name form | identical |
| `single-file.zip` | `zip` of one file | 1 | identical | identical |
| `multi.zip`, `multi-nodirs.zip` | `zip -r` of several items, with and without directory entries | 7 | folder 0755 (Archive Utility: 0700) | identical |
| `tree.aar` | `aa archive` of one directory | 24 | identical | identical |
| `tree-contents.aar` | `aa archive -d Tree` (an entry for the root) | 24 | folder's time (Archive Utility: the root entry's mode and time) | identical |
| `single.aar`, `multi.aar` | `aa archive -include-path` | 1, 5 | `multi`: folder 0755 | identical |
| `Xcode_27.3_beta_2.aea` | Apple (profile 0, certificate chain) | 167,541 | identical | identical |
| `Xcode_27.3_beta.xip` | Apple | 167,521 | 1,877 directory times | 28,191 directory times differ, on purpose (below) |

Run three times in one directory, both make `hello.txt`, `hello 2.txt`, `hello 3.txt` and `multi`, `multi 2`, `multi 3`.
Both leave the archive in place.

What Archive Utility does, as measured:

- **One top-level item** is moved out under its own name; **several** (or a `__MACOSX` beside one that isn't merged
  away) go in a folder named after the archive without its extension. Taken names get ` 2`, ` 3` before the extension.
- **The folder is 0700**, with the time it was made, unless the archive has an entry for its root (`aa archive -d
  DIR`): then it has that entry's mode and time (0755 and 2024 here). The owner and group are the user's (`501:20` in
  every row: nothing differed).
- **Everything gets the archive's quarantine, unchanged** (flags `0081` stay `0081`): files, directories, links, and
  the folder. Except a `.xip`: nothing in it is quarantined. For Xcode's `.aea`, the app's directories keep the
  extraction's time (as `aa extract` leaves them) and the quarantine is on everything.
- **AppleDouble entries are merged** into their items, from `__MACOSX/…/._NAME` or `._NAME` beside it: extended
  attributes (on directories too), Finder info, the resource fork, and the ACL (`com.apple.acl.text`). Neither
  `__MACOSX` nor a `._` file is left.
- **Symbolic links get their archived time** (a link `touch -h`ed to 2019 keeps it); modes are 0755.
- **ZIP names are written decomposed** (`Ü` as `U` + U+0308), whatever the archive's bytes; Apple Archive names as
  stored. APFS finds either, but `readdir` returns what was written.
- **Setuid is dropped** from a ZIP's files (4755 → 0755); 0444 files and 0555 and 0700 directories keep their modes; a
  ZIP's files have no flags. A parent directory the archive doesn't list is 0755 with the extraction's time.
- **A `.xip`'s directory times** are set before the files are written, so only directories holding nothing but
  directories keep them: 1,877 of Xcode's 30,068 (1,876 of the 1,886 holding only subdirectories; 1 of the 28,182
  holding a file or a link). `xip --expand` restores none. **Nunarchiver restores all 30,068** (a NativeAEA option):
  the 28,191 where Archive Utility has the extraction's time are the one deliberate difference.

What Archive Utility couldn't expand (each a dialog on the user's screen; none rerun):

| Archive | Archive Utility | Nunarchiver |
|---|---|---|
| `signed.aea`: `aea encrypt -profile 0 -sign-priv KEY`, no certificate chain in the auth data | "Unable to expand … (Error 22 - Invalid argument.)" Its log: `AEAAuthInfo.init found 0 entries in auth data`, `Main key derivation failed`. It takes the signer from the auth data only (Xcode's archive, which has Apple's chain, expands). | Asks for the signer's public key (PEM, hex, or base64), verifies with it, expands. |
| `edge.zip`, `edge2.zip`: `._` files that aren't AppleDouble, AppleDouble files with no item, one for a symbolic link, one beside and one under `__MACOSX` for the same file, a plain file under `__MACOSX`, a resource fork for a directory | "Error 79" (`EFTYPE`); its log: `Couldn't read the header of the entry`. Which entry wasn't narrowed down (every probe is a dialog). The second archive has no non-AppleDouble `._` file, so that alone isn't the cause; the fork for a directory, which `setxattr` refuses with `EPERM`, is the likeliest. | Expands: what parses and has its item is merged (a fork for a directory left out); anything else named `._` is extracted as the file it is, under `__MACOSX` too. (`ditto -x -k` drops the unmatched ones and warns; this macOS's `unzip` extracts them all as files.) |

Not compared, because Archive Utility wasn't run on archives it might refuse: encrypted ZIPs (ZipCrypto, WinZip AES),
and `.aea` archives with a symmetric key or a password. Nunarchiver asks for the password or key (tested against
archives `zip -P` and `aea encrypt` make).

### `Destination.publishUnwrapped(as:)`

Archive Utility's rule, on a staging destination: exactly one item is renamed out beside the staging directory
(`renameatx_np`, `RENAME_EXCL`, from the destination's descriptor to its parent's; `NAME 2.ext` when taken; a read-only
directory lent its owner's write bit for the rename, since its `..` changes) and the staging directory removed;
anything else is `publish(as:uniquing:)`. The folder keeps the staging directory's 0700 and gets the quarantine from
the options when the staging directory is made (`quarantinesDestination`), so the app sets nothing itself.

A plan's entry for the root (`planner.directory` with the empty path) now sets the destination's mode: the planner
assumed the destination had the mode `mkdir` gave that entry, which a staging directory (0700) doesn't. NativeAEA
plans that entry only when asked (`restoresDestinationMetadata`); NativeZip never has one.

`AccessControlListBlob(text:)` turns an ACL's text form (what AppleDouble carries) into the blob the planner takes,
through `acl_from_text`, so NativeZip can attach it like any other.

### Benchmarks (`v1-before` → `v1-after`, one run each, **under load**)

No path the benchmarks measure changed (the new code runs once per extraction, or only for a root entry or an ACL in
text). Mallocs and system calls, the firm numbers, are equal; instructions on file system rows include the kernel's
and moved both ways, as rows nothing here touches did (a probe that maps and copies 1 GB read +51%).

| Benchmark | Mallocs | System calls | Instructions |
|---|---|---|---|
| Queue: 20,000 small files, 1,024 jobs | equal | equal | 22 G → 21 G |
| Compressed: 2,000 × 1–64 KB: plain | 267 → 267 | 11 K → 11 K | 2,301 M → 2,196 M |
| Compressed: 2,000 × 1–64 KB: LZBITMAP | 339 → 339 | 14 K → 14 K | 5,134 M → 4,966 M |
| Compressed: 2,000 × 1–64 KB: LZVN | 339 → 340 | 14 K → 14 K | 7,759 M → 7,483 M |
| Extended attributes: 2,000 files × 3 | 4,323 → 4,319 | 24 K → 23 K | 3,718 M → 3,647 M |
| Hard links: 2,000 files + 2,000 links | 308 → 308 | 14 K → 13 K | 15 G → 14 G |
| Large file: 1 GB, LZBITMAP | 200 → 197 | 1,052 → 1,067 | 37 G → 37 G |
| FileWriter-1000-small-files | 0 → 0 | | 1,326 M → 1,229 M |

### Tests

`swift test`: 52 tests in 12 suites (was 46 in 11). New, `PublishTests`: a single item moved out and uniquely named
(mode and quarantine kept); a read-only directory moved out and its mode restored; several items as a 0700,
quarantined folder, uniquely named; nothing as an empty folder, and a plain destination refused; a root entry setting
the folder's mode and time; an ACL from its text on a file and a directory.

## 2026-11-21: the last cleanup: primitives to Bytes, single files in, unlisted parents quarantined (baselines `cleanup-before` → `cleanup-moved` → `cleanup-after`)

The whole suite but the probes and the `Workers` sweeps, with the `SyscallCounting` trait (`./bench syscalls baseline
update NAME --skip 'Probe.*' --skip 'Workers.*'`). `cleanup-moved` is the primitives' move alone; `cleanup-after` the
final code. **Times were taken under load** (other builds and tests running; `cleanup-moved` ran while NativeAEA was
being built and tested, which shows in its context switches); mallocs and `Disk syscalls` are the firm numbers, and
instructions on file-system rows include the kernel's, which move with contention.

### 1. The waiting primitives and `RawStorage` moved to BytesAsync and Bytes

`Continuation`/`suspend`, `WaiterQueue`, and `RawStorage` were here and, word for word, in NativeAEA; `AsyncLimiter`,
`AsyncIndexPool`, and `AsyncLatch` were here only, and general. All are in BytesAsync now (`RawStorage` in Bytes),
public and inlinable, and Disk imports them (`Buffers.swift`, 507 lines, became `JobQueue.swift`, 276: the path
reference for errors, the write queue, the clock, one `Counter`). The write queue stays: its ring of path bytes and
its low-water wake are this scheduler's, where BytesAsync's `AsyncQueue` (NativeAEA's block queue) hands each element
to a waiting consumer and wakes a producer per pop.

| Row (`cleanup-before` → `cleanup-moved` → `cleanup-after`) | Mallocs | `Disk syscalls` | Planner waits | Instructions |
|---|---|---|---|---|
| One file: 32 KB | 189 → 192 → 189 | 13 → 13 → 13 | 0 | 2.71 → 2.70 → 2.64 M |
| One file: 32 KB, LZBITMAP | 192 → 193 → 192 | 13 → 13 → 13 | 0 | 3.87 → 3.95 → 3.84 M |
| Small files: 2,000 x 1-8 KB | 267 → 267 → 268 | 8,029 all | 0 | 2.07 → 2.02 → 2.03 G |
| Single writer: 2,000 small files | 83 → 83 → 83 | 8,029 all | 0 | 1.92 → 1.97 → 1.92 G |
| Small files: 20,000 x 1-8 KB | 274 → 274 → 273 | 80,000 all | 1 → 1 → 1 | 21 → 21 → 21 G |
| Small files: 20,000, quarantined | 709 → 709 → 709 | 100,000 all | 1 → 1 → 1 | 25 → 25 → 25 G |
| Queue: 20,000 small files, 64 jobs | 274 → 274 → 273 | 80,000 all | 599 → 602 → 599 | 21 → 21 → 20 G |
| Compressed: 2,000 x 1-64 KB: plain | 267 → 267 → 267 | 8,029 all | 0 | 2.23 → 2.60 → 2.10 G |
| Compressed: 2,000 x 1-64 KB: LZBITMAP | 340 → 340 → 339 | 9,793 all | 0 | 5.26 → 5.12 → 4.89 G |
| Extended attributes: 2,000 files x 3 | 4,319 → 4,319 → 4,323 | 20,000 all | 0 | 3.65 → 3.77 → 3.64 G |
| Large file: 1 GB, LZBITMAP (pieces, turns) | 196 → 196 → 196 | 1,038 all | 0 | 37 → 37 → 37 G |
| Xcode-like: 5,000 files, LZBITMAP | 503 → 510 → 502 | 23,000 all | 0 | 28 → 28 → 28 G |
| `FileWriter`, 1,000 small files | 0 → 0 → 0 | 5,000 all | - | 1.30 → 1.36 → 1.24 G |

(Every other row agrees: mallocs within ±2, calls identical. The instruction columns' spread, −7% to +17% on the
small-file rows, is the kernel's share under different loads: `cleanup-moved`, taken during another package's build,
is the high one in most rows, and `cleanup-after`, the same code plus section 3, the low one.)

No row's mallocs or calls moved, so nothing became an unspecialized generic call: `Tools/calls --target Disk Disk '.*'
--callee 'BytesAsync|WaiterQueue|AsyncLimiter|swift_getGenericMetadata' --sum` finds the specialized copies in Disk's
own object (`specialized WaiterQueue.append(_:)`, `AsyncLimiter.acquire()`, …) and, new, only `RawStorage`'s metadata
accessor (at each buffer's allocation: once per writer) and its out-of-line `advise` (the `madvise` call). The
one-file row, which is all setup and waits, reads 2.71 → 2.70 → 2.64 M instructions. On Xcode's archives through `nunarchiver` (the binary
before the pass against the one after, back to back): the `.xip` 1,328.06 → 1,328.76 G instructions with the same
522,413 calls, the `.aea` (quarantined) 991.6 → 987.3 G with the same 780,239, and every item of both trees identical
(NativeAEA/RESULTS.md).

**Not moved:** `RawSpan.withUnsafeBytesAsync` (two lines in `Writer.swift`). BytesAsync's `withLentBytes` is the same
thing, but called with a closure that names its error type it's ambiguous with Bytes' synchronous method of that
name.

### 2. Single files: `MappedFile` and `OutputFile` (`Files.swift`)

NativeZip's `MappedFile` and NativeAEA's `RawMapping` were one type twice; NativeAEA's decryption to a file opened its
output and looped over `pwrite` as `FileIO.writeFully` does here. Both are Disk's now: `MappedFile(path:access:)` or
`MappedFile(descriptor, count:access:)` (`bytes`, a span borrowing it; `buffer(_:)`, a checked range at a stable
address; `.sequential` for `MADV_SEQUENTIAL`), and `OutputFile(path, replacing:)` with `write(_:at:)`. Measured where
they're used: NativeZip's parse and locate rows are identical to the instruction (4,293,000 and within 0.1% of
3,285,000), NativeAEA's decryption of Xcode's `.aea` 490.09 → 490.11 G with identical 10.46 GB outputs.
`Destination.isCaseSensitive` replaces NativeZip's `pathconf` on the path.

### 3. Unlisted parents get the quarantine; listed directories get their mode whoever made them

Two things an archive that doesn't list its directories first (ZIP) showed, both found by `quarantinesUnlistedParents`:

- A parent made on the way to a file (`a/b/` for `a/b/c.txt`, with no entry of its own) got no quarantine, where
  everything else extracted did. It now gets one `setxattr` in the directory pass (`DirectoryFix.quarantineOnly`),
  and nothing else: its mode stays what `mkdir` gave it. Without a quarantine nothing is recorded or called
  (`leavesUnlistedParentsAloneWithoutOne`; every row above has the same calls).
- A directory entry that came after something had made the directory, or for a directory already on disk, was
  assumed to have the mode its own `mkdir` would have given it, so `0750` stayed `0755`. Such a directory's mode is
  now set at the end whatever it has (`setsMode`). One made by its own entry is unchanged: Xcode's 30,000 directories
  make the same calls as before.

This is what let NativeZip take a `Quarantine` in its options and the Nunarchiver app drop its walk of the tree
afterwards (NativeZipArchive/Benchmarks/RESULTS.md).

### 4. Smaller things

- **A safety comment at every `unsafe` expression** (the first pass had one per function for many): 12 files, about
  230 comments, each saying what the operation is and why it's sound there. Comment-only: the build before and after
  typechecks alike. Writing them turned up one trap, fixed: an empty write to a file being gathered in the staging
  buffer force-unwrapped a `nil` base address.
- `LargeFileToken.entry` and `isCompressed` are stored properties (they wrapped two internal ones); `Sys.fchmod`,
  `Sys.fchown`, and the unused `fcntl` kind are gone; three classes around an `Atomic<Int>` are one `Counter`.
- Noted, not changed: `Planner.hardLink(_:to:)` and `addExtendedAttributes(_:to:)` trust that a token came from this
  planner (a token from another extraction's planner would index the wrong arena); tokens can't be made outside Disk,
  but nothing ties one to its planner. `TreeRemoval` calls the kernel directly, outside `Sys` (it isn't extraction,
  and isn't counted).

### Tests

`swift test`: 46 tests in 11 suites (debug, ~20 s); new: `QuarantineTests` (2), `FilesTests` (3: mapping, the output
file, case sensitivity). `BULK_TESTS=1 swift test -c release -Xswiftc -enable-testing`: all pass, 2.5 s. A build from
scratch with tests has no warnings.

## 2026-11-20 (follow-ups): what migrating NativeAEA and NativeZip asked for (baselines `fu-before` → `fu-after`)

Both baselines are the whole suite but the probes, with the `SyscallCounting` trait (`./bench syscalls baseline update
fu-… --skip 'Probe.*'`). `fu-before` ran from a copy of the tree taken before these changes, with two additions also
made to it: the benchmarks' new rows (`One file`, `Queue`) and metrics (`.contextSwitches`, and `Planner waits`, a new
`ExtractionReport.plannerWaits`). **Times were taken under load** (load average 4–15, other agents building); counts are
the firm numbers. `Tools/bench-table Disk --metric 'Instructions|Malloc|Syscalls|Disk syscalls|Planner|Context' fu-before fu-after`.

### 1. Bridged pieces' bytes in the progress

A compressed large file's piece in which no 64 KiB chunk ends has no job: the planner bridges it into the job of the
piece that completes the chunk, and its bytes were never counted. The job now carries them (`WriteJob.bridgedBytes`),
and the writer counts them with its own piece's, when they're written. `writesLargeFilesInPieces` checks that progress
reaches exactly the file's size and `fractionCompleted` 1 with 12,000-byte pieces (most of them bridged), 100 KB and
1 MiB. NativeAEA's workaround (leaving those bytes out of its exact total) is gone.

### 2. `LargeFileToken.entry` and `isCompressed`, public

NativeAEA read both with `Mirror` (a large file's blobs and hard links need its `EntryToken`); gone.

### 3. `fchflags` for flags alone

`AttributeList.apply(_:)` calls `fchflags` when `ATTR_CMN_FLAGS` is all the list holds, and `fsetattrlist` otherwise.
`fchflags(UF_COMPRESSED)` sets the modification time to now, which only matters when times are set too, and then
they're in the same `fsetattrlist` (kept, as before). Files deferred for attachments get only `UF_COMPRESSED` from the
writer (now `fchflags`) and their times from the pass after the writers: `DestinationTests.flagsAloneThenTimes` checks
the time sticks, inline and fork. Disk's own rows set times on every file, so no row changes its calls. On Xcode
(NativeAEA's numbers, `nunarchiver` old and new binaries interleaved, an interposer counting calls):

| Xcode | Calls (old → new) | Instructions (old → new) |
|---|---|---|
| `.aea` (27.3 beta 2, no times) | 125,890 `fsetattrlist` → 112,922 `fchflags` + 12,968 `fsetattrlist` (those that change the mode); 620,272 calls either way | 955.1–961.2 G → 944.2–953.2 G (7 rounds; medians 958.9 and 946.9: **−12 G, −1.3%**); the final binary 945.5 G. Before the migration: 949–951 G |
| `.xip` (27.2 RC, times) | identical (522,413) | 1,326.0 → 1,327.0 G (one round); the final binary 1,328.4 G |

### 4. Nothing made that isn't used

- **Writers' scratch** (output, table, chunk, staging buffers, encoders) is made on a writer's first job, each buffer
  the first time it's used (a writer of plain whole files makes none); the path buffers are one allocation for all
  writers.
- **The job ring** is allocated uninitialized (slots initialized by `push`, moved out by `pop`): initializing 16,384
  slots was the 8 M instructions.
- **Large-file slots** are made when the planner first takes one (`LargeFileTable`).

| Row (24 writers unless named) | Instructions | Mallocs | Process syscalls |
|---|---|---|---|
| One file: 32 KB | 11 M → **2.7 M** | 963 → **193** | 532 → **44** |
| One file: 32 KB, LZBITMAP | 11 M → 4.0 M | 964 → 198 | 450 → 56 |
| Large file: 1 GB, one write | 532 → 524 M | 963 → 190 | 396 → 37 |
| Large file: 1 GB, 8 MiB writes | 555 → 545 M | 954 → 180 | 528 → 165 |
| Small files: 2,000 x 1-8 KB | 2,088 → 2,074 M | 1,042 → **267** | 12 K → 11 K |
| Single writer: 2,000 small files | 1,922 → 1,913 M | 604 → **83** | 8,067 → 8,059 |
| Compressed: 2,000 x 1-64 KB: LZBITMAP | 5,100 → 5,234 M | 1,066 → 339 | 14 K → 14 K |
| Xcode-like: 5,000 files, LZBITMAP | 28 → 28 G | 1,187 → 506 | 34 K → 34 K |

`Disk syscalls` didn't change in any row. The one-file extraction's wall time went from 510 to about 190 µs (CPU
1,112 → 285 µs). What's left for a one-file extraction with 24 writers is mostly the 23 idle writer tasks (about 6
mallocs and 1 process syscall each: NativeZip/Benchmarks/RESULTS.md measured a writer cap both ways). (The LZBITMAP
row's +2.6% instructions isn't the change: interleaved, below, 5.18–5.34 G old against 5.19–5.30 G new.)

**First, only the core was lazy** (every buffer made on a writer's first job), and the 2,000-file row read slower:
interleaved against the old tree (`ab2-…`, 3 rounds) 57/56/53 ms against 49/48/48 ms, CPU 300–319 against 276–277 ms,
instructions equal; against the same code making its core in `Writer.init` (`ab3-…`), 71/64/54 against 55/52/53 ms.
24 writers each allocating 2.3 MB (4 page-aligned buffers, `mmap`s) at their first job, all at once, at the start of a
48 ms extraction. With each buffer made when first used, a writer of plain files makes none, and three rounds against
the old tree (`ab4-…`, scratch baselines) read:

| Round 1 / 2 / 3 (old → new) | Wall (ms) | CPU (ms) | Instructions | Mallocs |
|---|---|---|---|---|
| Small files: 2,000 x 1-8 KB | 54 → 55, 46 → 53, 53 → 51 | 270 → 284, 268 → 288, 288 → 277 | 2,069 → 2,048, 2,058 → 2,047, 2,064 → 2,035 M | 1,042 → 267 |
| Compressed: 2,000 x 1-64 KB: LZBITMAP | 123 → 129, 118 → 135, 118 → 126 | 717 → 726, 701 → 759, 705 → 751 | 5,344 → 5,297, 5,209 → 5,218, 5,184 → 5,188 M | 1,066 → 339 |
| One file: 32 KB | 0.49 → 0.19, 0.51 → 0.19, 0.58 → 0.18 | 1.0 → 0.24, 1.1 → 0.28, 1.4 → 0.24 | 10–11 → 2.6–2.7 M | 964 → 189–193 |

The plain row is now within its spread. The LZBITMAP row read 2–14% slower in all three rounds at equal instructions,
under load (average about 10): its writers make their 1.1 MB output buffer at their first compressed file now, as they
made it at their start before; not explained, and to be checked on an idle machine.

### 5. The planner woken at a low-water mark

A planner waiting for room in the queue was resumed by every pop: once full, a wake-up per file. Now it's resumed when
the queue is down to half its jobs and half its path bytes (an empty queue always is), and refills it in one run.

| 20,000 small files (`fu-before` → `fu-after`) | Planner waits | Context switches | Process syscalls | Instructions |
|---|---|---|---|---|
| 24 writers (default queue, 16,384 jobs) | 1,990 → **1** | 42 K → 46 K | 114 K → 110 K | 21 G → 21 G |
| 1 writer (`Single writer: 20,000 small files`) | 3,451 → **1** | 4,103 → **96** | 87 K → 80 K | 20 → 19 G |
| 2 writers, width 2 | 3,211 → 1 | 4,027 → 1,570 | 87 K → 81 K | 20 → 20 G |
| 24 writers, 1,024-job queue | 13,000 → 36 | 46 K → 45 K | 117 K → 111 K | 21 → 21 G |
| 24 writers, 64-job queue | 8,935 → 598 | 27 K → 43 K | 91 K → 111 K | 21 → 21 G |

The planner's wake-ups are gone, and with few writers (where they were a large share of the process's switches) so are
its context switches: 1 writer 4,103 → 96, and 7,000 fewer process syscalls. With 24 writers the switches are the
writers' (waiting for a permit and for jobs), and don't move. The 64-job row's `fu-before` (27 K switches, 2.36 s of
CPU against 2.9 s for the others) didn't reproduce: two interleaved rounds of the new code with the old wake on every
pop (a copy of the tree, scratch baselines `lw-pop-N` against `lw-half-N`) read

| 20,000 small files, round 1 / round 2 | Every pop | Low-water mark |
|---|---|---|
| 64 jobs: planner waits | 14,000 / 14,000 | 600 / 599 |
| 64 jobs: context switches | 43 K / 44 K | 38 K / 42 K |
| 64 jobs: CPU (s) | 2.89 / 2.88 | 2.79 / 2.86 |
| 1,024 jobs: context switches | 45 K / 42 K | 42 K / 40 K |
| default queue: context switches | 39 K / 40 K | 37 K / 45 K |

so a small queue now costs the same as the default one: callers can use smaller queues (less memory held by queued
jobs' contents) without a wake-up per file.

### 6. The source's own error

`DiskError.source` carries `any Error` (was a `String`), with `sourceError` to read it; `DiskError` stays `Equatable`
(sources' errors compare as their type does, else by description). A generic failure type on `ContentSource` was
considered and not done: `FileOutput.write` throws `DiskError` inside the source, so the source's failure type would
have to wrap Disk's, and `EntryFailure`, `ExtractionReport`, and `ExtractionError` would all become generic over it.
NativeZip's tag-to-error table and its matching of the stopping failure by description are gone.

### 7. Failing a file after its last write

A file written whole was finished (attributes, `close`) inside the source's last `output.write`, so a source couldn't
fail it after writing it. Now `complete()` finishes it after `write(_:to:)` returns; the permit its write took is held
until then (the same calls in one permit as before). A source that throws after its last write gets the file removed:
`ExtractionTests.failsFilesAfterTheirLastWrite` (whole, gathered, streamed, batched, empty; plain and LZBITMAP; a width
of 1, so a permit kept would stop every later file). Cost: none measured (`Disk syscalls` identical in every row,
instructions within the rows' spread). NativeZip's check-before-the-last-write (a decode into the other buffer to see
the stream's end first) is gone.

### 8. Small items

- `ExtractionProgress.addExpected(entries:bytes:)` adds to the totals (negative counts take skipped entries off):
  NativeZip's extractor, an archive at a time.
- `ExtractionOptions` is now **`ExtractionSettings`** (NativeZip has a public `ExtractionOptions`, and both modules are
  imported together); every user changed, Nunarchiver's ZIP adapter included (its `NativeZip.` qualifier went).
- Not done: ordering a later entry at the same path "after this entry" in Disk. NativeZip's writer-side wait
  (`SourceState.waitUntilWritten`) works, is rare (an archive naming one path twice), and moving it into Disk means a
  per-job dependency in the queue and the writers: not trivial.

### Tests

`swift test`: 41 tests (debug, ~17 s); new: `flagsAloneThenTimes`, `failsFilesAfterTheirLastWrite` (2 cases), and the
progress checks in `writesLargeFilesInPieces`, the source's error in `recordsFailuresAndGoesOn` and
`stopsAtTheFirstFailure`. `BULK_TESTS=1 swift test -c release -Xswiftc -enable-testing`: all pass (the stress test's
64-job queue and 4 KiB path ring now run at the low-water mark), 2.9 s.

## 2026-11-20: the package

### Kernel semantics checked first (C probes, scratch)

| Question | Answer (macOS 27.2) | Used for |
|---|---|---|
| A resolve-beneath flag for `openat`? | **Yes**: `O_RESOLVE_BENEATH` (`openat`), `AT_RESOLVE_BENEATH` (`linkat`, `unlinkat`, `fstatat`, `fchmodat`, `fchownat`, `utimensat`), `FSOPT_RESOLVE_BENEATH` (`setattrlistat`), `RENAME_RESOLVE_BENEATH`, `CLONE_RESOLVE_BENEATH`. A path through an absolute link out fails `ENOTCAPABLE`; through a link inside, it resolves (so it's paired with `O_NOFOLLOW_ANY`, which fails `ELOOP`) | Every path-taking call |
| `openat(O_CREAT \| O_DIRECTORY)` to make a directory and get its descriptor in one call? | No: `EINVAL` | Directories stay `mkdirat` (+ `openat` with `.descriptors`) |
| Does `mkdirat(root, "a/b")` follow a link `a`? | **Yes** (no flags) | Parents are made or checked (`fstatat(AT_SYMLINK_NOFOLLOW_ANY)`) before anything is made in them |
| `linkat(…, AT_SYMLINK_NOFOLLOW_ANY)` through a link in either path? | `ELOOP` both ways | Hard links: one call, safe |
| One `fsetattrlist` with `ATTR_CMN_MODTIME \| ATTR_CMN_ACCESSMASK \| ATTR_CMN_FLAGS`, flags `UF_COMPRESSED`? | Works: the file reads back decompressed, the mtime given **sticks** (separately, `fchflags(UF_COMPRESSED)` set it to now) | One call finishes every entry |
| … with `UF_IMMUTABLE` in the same call? | Works, times set | No separate "locking flags last" call |
| zlib `decmpfs` type 3 (inline)? | Reads back | `.zlibInline` |
| zlib type 4 (Resource Manager fork layout)? | `open` fails `EINVAL` with the layout tried (header, cmpf map, LE offset/size pairs) | zlib is inline only; bigger files stay plain |
| `O_UNIQUE`/`AT_UNIQUE` (new: fail on a vnode with several links)? | Exists | Not needed: hard links are only to files the plan wrote |

### Calls per entry (`Disk syscalls`, exact, from the `syscalls` baseline)

| Entry | Calls | Which |
|---|---|---|
| Plain file with times (and mode) | **4** | `openat`, `pwrite`, `fsetattrlist`, `close` (2,000 files: 8,029 = 4 × 2,000 + 20 directories + 9) |
| Plain file, no metadata to change | 3 | `fsetattrlist` skipped when nothing differs from what `open` made |
| APFS-compressed, inline | 4–5 | `openat`, `fsetxattr` (decmpfs), `fsetattrlist`, `close` |
| APFS-compressed, fork | 5–6 | `openat`, `fsetxattr` fork (one per 16 chunks), `fsetxattr` header, `fsetattrlist`, `close` (2,000 files of 1–64 KB, LZBITMAP: 9,793) |
| + quarantine | +1 | `fsetxattr` (20,000 files: 100,000 calls) |
| File with 3 extended attributes | 10 | writer: `openat`, `pwrite`, `close`; after: `openat`, 3 × `fsetxattr`, `fstat`, `fsetattrlist`, `close` |
| Hard link | 1 | `linkat` |
| Xcode-like tree (5,000 files, dirs, links, 500 hard links, LZBITMAP) | 4.6 per entry | 23,000 |
| `FileWriter`, replacing an existing file | 5 | `openat` (`EEXIST`), `unlinkat`, `openat`, `pwrite`, `close` |

**Against NativeAEA's writer** (compressed file: `open`, fork, header, [quarantine], `fchflags`, `fsetattrlist`,
[`fchmod`], `close` = 6–8) and **NativeZip's** (`open`, `write`, `fsetattrlist` with mode and times, `close` = 4, plus
`mkdir` per directory, `fchown` when asked): one call fewer per compressed file, two with `fchmod`.

The raw-call probe (single thread, 2,000 files, mode + flags + times): `fchmod` + `fchflags` + `fsetattrlist` 173 ms
(p0), 12,000 process syscalls, 2.48 G instructions; **one `fsetattrlist` 159 ms (−8%), 8,005 syscalls, 2.14 G (−14%)**.

package-benchmark's `.syscalls` on macOS is the process's total of Unix and Mach calls (`proc_pidinfo`): 113,000 for
20,000 small files against Disk's 80,000 (the rest: waits, the allocator, the runtime). Disk's counter is the one that
shows a regression per entry.

### Writers and the file-system width (`syscalls` baseline, p50 of 3, under load)

20,000 files of 1–8 KB (NativeZip's measurement), 24 writers:

| Width | 1 | 2 | 4 | **6** | 8 | 12 | 16 |
|---|---|---|---|---|---|---|---|
| Wall (ms) | 1,491 | 848 | 526 | **499** | 522 | 618 | 612 |
| CPU (s) | 1.55 | 1.76 | 2.07 | 2.83 | 3.57 | 4.62 | 5.47 |

Writers at width min(6, writers): 1: 1,555 ms; 2: 890; 4: 479; 8: 520; 16: 485; 24: 499; 32: 493. Small files need no
more than 4 writers in the kernel; more writers than the width only help when there's CPU work (below).

Xcode-like tree (5,000 files, 510 MB, LZBITMAP: compression is the CPU work), 24 writers:

| Width | 2 | 4 | **6** | 8 | 12 |
|---|---|---|---|---|---|
| Wall (ms) | 518 | 372 | **337** | 362 | 375 |
| CPU (s) | 2.24 | 2.59 | 2.95 | 3.53 | 4.19 |

Both agree with NativeAEA on Xcode (width 4: 11.2 s, 6: 9.9 s, 8: 10.5 s, 12: 11.3 s) and NativeZip (4–8 best, 12+
slower). **Chosen:** writers = performance cores (24 here), width = performance cores / 4, from 2 to 6 (6 here)
(`DiskDefaults`). Past the peak, CPU time grows faster than wall time falls: contention in APFS.

### Options, interleaved (`ab-1`, `ab-2`: wall ms, round 1 / round 2, 20,000 small files)

| Variant | Wall | Instructions |
|---|---|---|
| Default (paths, `O_RESOLVE_BENEATH`) | 508 / 486 | 21 G / 21 G |
| `directoryResolution: .descriptors` | 512 / 479 | 21 G / 21 G |
| Without `O_RESOLVE_BENEATH` | 489 / 489 | 21 G / 21 G |
| Quarantined (+1 `fsetxattr` a file) | 568 / 576 | 24 G / 25 G |

- **`O_RESOLVE_BENEATH` is free** within noise: on by default.
- **Directory descriptors cost nothing measurable here** (200 directories); NativeAEA measured +3% on Xcode's 30,000
  (an `open` per directory on the planner's path). Default stays `.paths`; `.descriptors` closes the window in which
  another process could swap a checked directory for a link between the check and a later `mkdirat` (ARCHITECTURE.md
  §2), at that cost.
- **The quarantine costs 13–17%** (NativeAEA: 15% on Xcode): one more call per entry. On only when the source has one.

### Progress (`ExtractionProgress`)

One relaxed add per file (entries and bytes from one slot per worker, each on its own 128-byte line). Single writer,
2,000 small files (`ab-1`/`ab-2`): **without 1.912 G / 1.966 G instructions, 144 / 133 ms; with 1.939 G / 1.907 G,
134 / 137 ms** — no difference beyond the run-to-run spread (±3% of ~960,000 instructions a file, almost all the
kernel's). 24 writers: 2.076 / 2.055 G without, 2.060 / 2.052 G with.

### Allocations

- `FileWriter`, 1,000 files rewritten per iteration: **0 mallocs** (threshold `Thresholds/…FileWriter-1000-small-files…`
  at 0, checked).
- The scheduler, one writer: 604 mallocs for 2,000 files, 610 for 20,000: **0.0003 per file** (the setup: the context,
  queue rings, writer scratch, task group). 24 writers: 1,042 / 1,049. Extended attributes: 5,095 for 2,000 files (the
  passes' per-lane copies of the deferred list, and `acl_*` for ACLs only).

### macOS APIs for large files (probes: one 1 GB file from memory, p0 / p50 of 3)

| Method | Wall (ms) | Instructions | Process syscalls |
|---|---|---|---|
| One `pwrite` | 118 / 156 | 520 M | 5 |
| 8 MiB `pwrite`s | 124 / 156 | 538 M | 132 |
| 8 MiB, `F_PREALLOCATE` | 128 / 156 | 526 M | 133 |
| 8 MiB, `F_NOCACHE` | 145 / 156 | **332 M** | 133 |
| DispatchIO (`DispatchData` borrowing the buffer, 8 MiB) | 122 / 156 | 551 M | 1,194 (1,702 mallocs) |
| `mmap` + copy | 210 / 280 | 3,032 M | 7 |

All bound by the same rate (about 6.9 GB/s at p50, into the page cache). **Chosen:** `pwrite` (whole, or as the source
streams it). `F_NOCACHE` saves 38% of the CPU at no gain in time but leaves the file out of the cache (a client opening
it next pays): not adopted; `F_PREALLOCATE`, DispatchIO (allocations, more calls), and mapping (2x slower: NativeZip
found the same) not adopted. Through Disk: one write 156 ms (13 calls), 8 MiB writes streamed 166 ms (139 calls).
`F_SETSIZE` needs root and doesn't zero; `F_PUNCHHOLE`/`F_BARRIERFSYNC` don't apply (no holes; extraction needs no
`fsync`: `F_BARRIERFSYNC` is a barrier for durability ordering, not speed).

**Identical files:** `clonefileat` from the first, 2,000 × 32 KB: 190 ms against 151 ms written (+26%). NativeAEA found
the same on Xcode (23,000 clones a second against 44,000 creates). Not adopted.

**A large compressed file written whole is compressed by one writer:** 1 GB of LZBITMAP 2.6 s (16,384 chunks at about
400 MB/s). Pieces (`beginLargeFile`) compress in parallel across writers; a client with a large file in memory should
plan it in pieces (NativeAEA's large files already are). Splitting a whole file inside the writer is the next step.

### APFS compression (2,000 files of 1–64 KB, p50)

| Policy | Wall (ms) | Instructions | Disk syscalls |
|---|---|---|---|
| plain | 92 | 2.5 G | 8,029 |
| LZBITMAP (`aa`) | 125 | 5.2 G | 9,793 |
| LZFSE | 111 | 7.5 G | 9,705 |
| LZVN (`xip`) | 122 | 7.7 G | 9,788 |
| zlib inline | 104 | 8.9 G | 8,029 |

Xcode-like, 5,000 files: plain 239 ms, LZBITMAP 350 ms, LZVN 440 ms.

**Byte for byte:** `DecmpfsTests.compressesAsAaExtractDoes` writes 60-odd files (20 B to 300 KB, text and random, short
last chunks) with `aa extract` and with Disk: every LZBITMAP file's stored `com.apple.decmpfs` and resource fork equal
`aa`'s, LZFSE's form and contents equal. `followsXipExpandsRules` checks `xip --expand`'s rules one by one (16 KiB,
PNG, the 4/5 block rule at its boundary, raw short tails behind 0x06); the encoders and rules are NativeAEA's, which
matched every file of Xcode 27.2's xip. Streamed files (several writes, bigger than the staging buffer) store the same
bytes as whole ones.

### Path checks

`EntryPath` checks with a vector screen (`ByteLanes`: 16 pairs a test) and falls back to an exact scan for anything
suspicious; `PathTests.screenAgreesWithTheExactCheck` places every unsafe pattern at every offset of paths of 1–48
bytes. (NativeAEA's scalar check was 91 ns per entry; per-entry instructions here are dominated by the kernel's ~1 M.)

### Tests

`swift test`: 39 tests in 9 suites (debug, ~18 s); `BULK_TESTS=1 swift test -c release -Xswiftc -enable-testing` adds
`ExtractionBulkTests` (3,000 files × 5 writer/width combinations with a 64-job queue and a 4 KiB path ring): 2.5 s in
all.
