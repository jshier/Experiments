# The Apple Encrypted Archive format, as Xcode ships in it

Apple doesn't publish the `.aea` layout. This is what NativeAEA reads, worked out from Xcode 27.3 beta 2's archive,
SDK headers (`AppleArchive/AEADefs.h`, `AADefs.h`), and other readers (blacktop/ipsw, aea-tools). Every structure and
derivation below was checked against Apple's own tools: `aea decrypt` and `aea id` on Xcode's archive, and archives
`aea encrypt` and `aa archive` made in the tests (every segment compression, checksum, and segment size).

There are three layers: the **container** (`AEA1`: signature, keys, MACs, compressed segments), the **Apple Archive
stream** inside it (`AA01` entries), and how Apple's extractor **writes files** (APFS compression). Section 4 covers Xcode's
other download, the `.xip` (a signed XAR archive of a cpio stream in pbzx blocks), and what `xip --expand` writes.

## 1. The container

Integers are little-endian.

```
prologue
  0      4   magic "AEA1"
  4      3   profile (u24)                                    Xcode: 0
  7      1   scrypt strength (profile 5 only)
  8      4   auth data size A (u32)                           Xcode: 3,802
  12     A   auth data
  ...  128   signature (profile 0; 160 for 2 and 4; none otherwise)
  ...   32   key material (profile 0; 65 for 3 and 4: an ephemeral public key; none otherwise)
  ...   32   salt
  ...   32   root header HMAC
  ...   48   root header (encrypted on every profile but 0)
  ...   32   first cluster header's HMAC
clusters, until the root header's raw size is reached
  per segment (segments per cluster of them):  raw size u32 | stored size u32 | checksum (0, 8, or 32 bytes)
  32   next cluster header's HMAC
  per segment: 32-byte HMAC
  the segments' stored bytes, in order
padding (to the container size)
```

Profile 0's prologue is 316 bytes plus the auth data: Xcode's is 4,118 (`0x1016`), and its first segment's data
starts after an 18,464-byte cluster header.

**Profiles** (`AEAProfiles`): 0 `hkdf_sha256_hmac__none__ecdsa_p256` (signed, not encrypted: Xcode), 1 symmetric
key (iOS IPSWs' disk images), 2 symmetric + signed, 3 ECDHE, 4 ECDHE + signed, 5 scrypt password. NativeAEA reads
all six (keys below).

**Auth data** is a key-value list: entries of `size u32 (including itself) | key, NUL-terminated | value`. Xcode's
has one, `com.apple.ias.signature.certificate-chain`: three PEM certificates, leaf first (an Apple-issued leaf,
"Apple Platform Signing ECC CA 1 - G1", "Apple Root CA - G3"). The key-value form is a convention, not a rule: signed
Shortcuts carry a binary plist instead (per The Apple Wiki), which NativeAEA reads only with a key given
(`-sign-pub`). NativeAEA rejects an entry shorter than 5 bytes (size and the key's NUL); Apple's parser rejects sizes
under 4.

**Root header** (48 bytes, plain on profile 0):

| Offset | Size | Field | Xcode |
|---|---|---|---|
| 0 | 8 | raw size: the Apple Archive stream's | 10,464,202,071 |
| 8 | 8 | container size: the file's | 2,174,613,438 |
| 16 | 4 | segment size (raw) | 16 MiB |
| 20 | 4 | segments per cluster | 256 |
| 24 | 1 | compression: `-` none, `4` LZ4, `b` LZBITMAP, `e` LZFSE, `f` LZVN, `m` LZRAVEN (macOS 27), `x` LZMA, `z` zlib | `x` |
| 25 | 1 | checksum: 0 none, 1 Murmur64, 2 SHA-256 | 2 |
| 26 | 22 | reserved | 0 |

Xcode's 624 segments are in three clusters (256, 256, 112). The cluster count follows from the **raw** size,
ceil(raw size / (segment size × segments per cluster)), not the container size: Xcode's container (2.17 GB) would
give one cluster of 4 GiB. A last cluster's header still has room for every segment; the unused entries are zero.
`aea encrypt`'s default segment is 1 MiB, and its largest 256 MiB: `aea encrypt -b 512m`, `1g`, and `2g` all write
268,435,456. The field has room for 2³² − 1, but NativeAEA refuses a segment size over 256 MiB (`invalidHeader`)
where the root header is parsed, because every buffer pool is sized in segments (a 1.3 MB archive declaring 2³¹ − 1
took 2.16 GB to list before the check).

**Segments** are compressed independently. A segment whose stored size equals its raw size is stored as is.
Otherwise:

- `x`: a complete `.xz` stream, one block, the LZMA2 filter alone (dictionary 8 MiB in Xcode's), check type None.
- `z`: zlib, with the RFC 1950 wrapper and Adler-32 (not raw DEFLATE, which is what Compression's `COMPRESSION_ZLIB`
  decodes).
- `4`: raw LZ4 blocks (Compression's `COMPRESSION_LZ4_RAW`, not its `bv41` frames).
- `e`, `b`, `m`: LZFSE, LZBITMAP, and LZRAVEN streams as Compression writes them (`COMPRESSION_LZRAVEN`, buffer
  API only, macOS 27). LZRAVEN is undocumented; Bytes' `LZRAVEN-FORMAT.md` describes it (read from libcompression).
- `f`: LZVN, a raw stream ending with LZVN's end-of-stream opcode. The `aea` and `aa` tools don't offer it, but
  libAppleArchive writes it given libcompression's private LZVN constant, 0x900 (`AEA_CONTEXT_FIELD_COMPRESSION_ALGORITHM`
  in C; `ArchiveCompression(rawValue: 0x900)` in Swift): `f` segments in AEA, `pbzf` blocks in Apple Archive streams.
  NativeAEA's tests make both that way.

`aea encrypt -b` makes segments of at least 16 KiB.

**Checksums** cover each segment's raw bytes: SHA-256, or MurmurHash64A with seed `0xE2236FDC26A5F6D2` (8 bytes,
little-endian; the seed from ipsw's reader, checked against `aea encrypt -checksum murmur64`).

### Keys and MACs

All derivations are HKDF-SHA256 (RFC 5869). Info strings are ASCII with no terminator; indices are 32-bit
little-endian.

```
main key (profile 0)  HKDF(ikm: key material (32), salt: salt (32),
                           info: "AEA_AMK" | profile word (4 bytes: profile | scrypt << 24) | signing public key (X9.63, 65))
root header key       HKDF(main key, no salt, "AEA_RHEK")             first 32 bytes: the MAC key
cluster key i         HKDF(main key, no salt, "AEA_CK" | i)
cluster header key    HKDF(cluster key, no salt, "AEA_CHEK")          first 32: the MAC key
segment key j         HKDF(cluster key, no salt, "AEA_SK" | j)        j counts within the cluster; first 32: MAC key
padding key           HKDF(main key, no salt, "AEA_PAK")
```

On profile 0 the key material is stored in the clear, so anyone can derive every key. That's fine: the MACs only chain
everything to the prologue, and the signature authenticates the prologue.

**Encrypted profiles** (1–5) derive the same keys at 80 bytes: HMAC key (32) | AES-256 key (32) | IV (16). The root
header, each cluster header's segment infos, and each segment are MACed as stored (ciphertext) and then decrypted
with AES-256 in counter mode. The counter is the IV's last 8 bytes, big-endian, wrapping without a carry into the
first 8. That's CommonCrypto's `kCCModeOptionCTR_BE`, checked against CommonCrypto. A segment stored uncompressed
decrypts straight to its raw bytes. The main key's inputs per profile:

```
input key material                  salt                     info after "AEA_AMK" | profile word
0  key material (prologue, 32)      prologue salt            signing public key
1  symmetric key (32)               prologue salt            —
2  symmetric key                    prologue salt            signing public key
3  ECDH(recipient private, ephemeral public in the prologue: x-coordinate, 32)
                                    prologue salt            ephemeral public | recipient public
4  as 3                             prologue salt            ephemeral public | recipient public | signing public
5  scrypt(password, salt: E[0..<32], N: 0x4000 << (2 × strength), r: 8, p: 1, 32 bytes)
                                    E[32..<64]               —
   where E = HKDF(prologue salt, no salt, "AEA_SCRYPT", 64)
```

Public keys are X9.63 (65 bytes); the decrypting side computes the recipient's from its private key. **Signatures on
profiles 2 and 4** are encrypted: the 160-byte field is `AES-CTR(SEK, DER signature padded to 128) | MAC(SEK, those
128 bytes)` (no associated data), with `SEK = HKDF(HKDF(main key, -, "AEA_SEK", 32), -, "AEA_SEK2", 80)`. The signature
covers the prologue as stored (root header encrypted) with all 160 bytes zeroed. A wrong key fails at the root
header's MAC (or the signature's).

These derivations come from two open-source readers that agree (kinnay/AEA's FORMAT.md and aea.py,
mrowlinson/applearchive-cleanroom). NativeAEA checks them against archives `aea encrypt` makes for profiles 1–5 at
test time. iOS IPSWs' root file system images (`.dmg.aea`) are profile 1. Their auth data carries
`com.apple.wkms.fcs-response`: an HPKE-sealed copy of the key, opened with a private key from the URL in
`com.apple.wkms.fcs-key-url`.

Every MAC is `HMAC-SHA256(key, associated data | data | u64 size of the associated data)`:

| What | Key | Associated data | Data | Stored in |
|---|---|---|---|---|
| Root header | root header key | first cluster header's MAC, auth data | root header | prologue |
| Cluster header | cluster header key | next cluster header's MAC, segment MACs | segment infos | previous header (the prologue for cluster 0) |
| Segment | segment key | — | stored (compressed) bytes | its cluster header |
| Padding | padding key | (plain HMAC, no size) | padding | last cluster's next-header slot |

**The signature** (profile 0) is ECDSA P-256 with SHA-256 over the whole prologue with the signature field zeroed,
DER-encoded, zero-padded to 128 bytes. The public key is the leaf certificate's (or one given with `aea -sign-pub`). **The archive
identifier** `aea id` prints is SHA-256 of the prologue as stored.

So one signature check authenticates everything: signature → prologue → root header (MAC) → first cluster header
(MAC) → its segments (MACs) and the next cluster header (MAC) → … → padding.

## 2. The Apple Archive stream

The segments, decompressed and concatenated, are an `aa` stream: entries back to back, no index, no alignment.
Headers and file contents cross segment boundaries freely.

```
"AA01" (older: "YAA1") | header size u16 (the whole header) | fields | blobs (in field order)
```

A field is a 3-letter key and a 1-character subtype that gives the value's size:

| Subtype | Value |
|---|---|
| `*` | flag: no value |
| `1` `2` `4` `8` | unsigned integer of that many bytes |
| `P` | string: u16 size, then the bytes (no terminator) |
| `T` / `S` | time: u64 seconds and u32 nanoseconds (below 10⁹: NativeAEA refuses more where the header is parsed, as `setattrlist` would) / u64 seconds |
| `F` `G` `H` `I` `J` | CRC-32 (4), SHA-1 (20), SHA-256 (32), SHA-384 (48), SHA-512 (64) |
| `A` `B` `C` | blob with a u16, u32, or u64 size: the bytes follow the header |

Keys (`AADefs.h`): `TYP` type (`F` file, `D` directory, `L` link, …), `PAT` path, `LNK` link target, `UID`, `GID`,
`MOD` (the header says the low 12 bits of `st_mode`; Xcode's carry the whole of it, type bits included: 0x81ED for
a 0755 file, 0x41ED for a directory), `FLG` (`st_flags`), `MTM`/`CTM`/`BTM` times, `DAT` contents, `XAT` extended attributes, `ACL`,
`SIZ`, `SH2` …, `HLC`/`CLC`/`SLC` hard-link, clone, and same-data cluster ids, `DEV` a device's `st_rdev`. `aa archive`
writes `TYP1 PATP UID2 GID1 MOD2 FLG1 CTMT MTMT [DATA|DATB] [XATA] [ACLA] [HLC1]` per entry, and a first entry with an
empty path (the destination itself).

The metadata blobs (`AAEntryXATBlob.h`, `AAEntryACLBlob.h`, checked against `aa archive` output):

```
XAT   entries of: size u32 (the entry's, itself included) | name, NUL-terminated | value (the rest)
ACL   entries of: size u32 (22 + the qualifier's) | type ('A' allow, 'D' deny) | flags u64 | permissions u64
                  | qualifier type ('U' user name, 'G' group name, 'I' UUID text, 'S' SID text) | qualifier
```

ACL flags and permissions are macOS's `acl_flag_t` and `acl_perm_t` bits: `list,add_file` is 6, inheritance
`file_inherit,directory_inherit,limit_inherit` is 0xE0. The header warns they might not match other SDKs. A
hard-link cluster's members each carry the contents (`DAT`). `aa extract` writes the first and links the rest.

**Compressed streams** (`aa archive`'s default output, and what `aa archive -a ALGORITHM` writes) wrap the stream in
independently compressed blocks:

```
"pbz" | algorithm (u8) | block size (u64, big-endian)
per block: raw size (u64 BE) | stored size (u64 BE) | stored bytes     (sizes equal: stored as is)
```

The algorithm letters are AEA's: `e` LZFSE, `x` an xz stream, `z` zlib (RFC 1950), `b` LZBITMAP, `m` LZRAVEN, `f` LZVN, and `4`
LZ4 as Compression's `bv41` frames (not raw blocks as in AEA segments). An AEA container may hold such a stream
(`aea encrypt -i archive.aar`); NativeAEA detects the magic in the first segment. Blocks carry no checksums: a damaged
compressed block fails to decode, but damage to a stored block can't be detected (by `aa` either), unless the entries
carry hashes (`SH2` and the like) or the stream is in an AEA container.

**Xcode's stream** is 167,541 entries, directories before their contents: 30,082 directories (`TYP1 PATP UID1 GID1
MOD2`), 126,205 files (`… DATA|DATB FLG1 AFT1`, all with `FLG1` = 0x20 and `AFT1` = 14), and 11,254 links (`… LNKP`).
There are no times, no extended attributes, no hard links, and no checksums per file: the segments' SHA-256s cover
everything. The first 16 MiB segment holds 308 headers.

**`AFT`** isn't in Apple's headers or written by `aa`. It is the file's on-disk compression, as a `decmpfs` type (14:
LZBITMAP in the resource fork), and `FLG` carries `UF_COMPRESSED`.

## 3. Writing files as Apple's extractor does

`aa extract` re-compresses every `AFT` file with APFS transparent compression (`decmpfs`), as `ditto
--hfsCompression` does. A compressed file has an empty data fork, the `UF_COMPRESSED` flag, and a
`com.apple.decmpfs` extended attribute:

```
"fpmc" (the magic 'cmpf', little-endian) | type u32 | uncompressed size u64 | inline data
```

Types come in pairs: 13 (LZBITMAP data inline in the attribute) and 14 (LZBITMAP in the resource fork); likewise 11
and 12 for LZFSE. A type 14 resource fork is a table of chunk count + 1 u32 offsets from the fork's start, then the
chunks: each 64 KiB of the file compressed on its own (Compression's LZBITMAP stream, `ZBM\t…`). A chunk, or
inline data, that doesn't compress is stored as `0xFF` and the raw bytes.

The encoder's room matters, not just its algorithm: Compression's LZBITMAP output depends on the destination size it
gets (its compressed path needs working room beyond its result: a 321-byte file compresses to 277 bytes with 337 of
room and fails with 321). `aa extract` gives every chunk **64 KiB of room**, a file's short last chunk and small files
included, and stores a chunk raw unless the result is smaller. With that rule NativeAEA's LZBITMAP encoder (Compression's
bytes exactly) stores every one of Xcode's files byte for byte as `aa` does, `decmpfs` attribute and fork included.

Apple's choices, measured on Xcode (and matched by NativeAEA file for file):

- **Inline** (type 13) when the attribute, header included, is at most **3,584 bytes**: 88,006 files.
- **Resource fork** (type 14) otherwise: 37,881 files, 9.45 GB raw in 3.12 GB.
- **Plain** when the fork would be **93% or more** of the raw size (the highest ratio it compressed was 0.9293; the
  lowest it left plain, 0.9304): 318 files, 0.72 GB (packages, asset catalogs, PNGs). Inline files never fall back.
  The ratio is the whole file's: a file whose first MiB compresses and whose whole doesn't is plain, and the other
  way around (checked with `aa extract` on streams made to differ).
- Permissions from `MOD` on files, directories, and links (18 links have 0644); files and directories are 3.9 GB on
  disk in all.

`aa extract` also copies the source archive's `com.apple.quarantine` attribute onto every item, links included, and
onto the destination directory itself for a plain `.aar` (not for an `.aea`). It restores `XAT` attributes on files, directories, and links, and `ACL`s. NativeAEA
does all of this by default (`--no-quarantine` skips the quarantine).

## 4. Xcode's `.xip`

Xcode's other download (`Xcode_27.2_Release_Candidate.xip`, and 27.1 RC and 27.3 beta, all read the same way) is a
signed XAR archive of two members. Worked out from those three files, `xar`'s TOC dump, and `xip --expand`'s output,
compared item by item with NativeAEA's.

### The XAR container

```
"xar!" | header size u16 (28) | version u16 (1) | TOC compressed size u64 | TOC size u64 | checksum algorithm u32 (1: SHA-1)
TOC: zlib (RFC 1950) XML, then the heap
heap: TOC checksum (SHA-1 of the compressed TOC: offset 0, 20 bytes) | signature (offset 20, 256 bytes) | members
```

All big-endian. The TOC (27.2's: 3,945 bytes compressed, 6,997 as XML) gives:

- `checksum` (`style="sha1"`) and `signature` (`style="RSA"`) places in the heap, and the signer's chain, leaf first, as
  base64 `X509Certificate`s: **Software Update** (RSA 2048, extended key usage 1.2.840.113635.100.4.1, Apple's software
  update signing, valid 2019–2029) ← **Apple Software Update Certification Authority** ← **Apple Root CA** (SHA-256
  `b0b1730e…f024`, the 2006 root).
- `creation-time` (UTC, no zone: `2026-10-16T17:24:05`).
- Per member: `name`, `data/offset` (from the heap), `length` (stored), `size` (decoded), `encoding`, and SHA-1s of the
  stored and decoded bytes (`archived-checksum`, `extracted-checksum`). Ownership, times, inode numbers of the
  originals: unused.

The **signature** is RSA PKCS #1 v1.5 of the TOC checksum itself: the 20 bytes go in SHA-1's `DigestInfo` as the
digest (the TOC isn't hashed again). Since the TOC holds the members' checksums, the signature covers everything.
`xip --expand` checks none of it ("validation not attempted"); `pkgutil --check-signature` checks the chain.

### `Content` and `Metadata`

- **`Content`** (2.05 GB in 27.2) is stored (`application/octet-stream`, length = size) at heap offset 276, right after
  the signature. It's a **pbzx** stream: the `pbz` block layout of §2 with algorithm `x`, 16 MiB blocks, each an xz
  stream (a block whose sizes are equal would be stored raw).
- **`Metadata`** (303 bytes, `application/x-bzip2`) is a property list: `FileSystemCompressionFormat` `10.10` (the APFS
  compression to use: LZVN, which came with OS X 10.10), `UncompressedSize` (the cpio stream's size, 10,347,643,285
  bytes for 27.2), `Version` 1, `xbs_sortcpio` true.

Decoded, `Content` is a **cpio** archive in the POSIX "odc" format (`070707`): per entry a 76-byte header of octal
ASCII fields (`dev ino mode uid gid nlink rdev` of 6 digits, `mtime` of 11, `namesize` 6, `filesize` 11), the
NUL-terminated name (`./Xcode.app/…`, `.` for the root), then the contents, no padding; a symbolic link's contents are
its target. `TRAILER!!!` ends it. Hard links are entries sharing `dev` and `ino`, each carrying the contents (27.2:
32,009 hard-linked names, 26,062 of them later names of 5,947 files). The order (`xbs_sortcpio`) puts each directory
before its entries.

### What `xip --expand` writes

Measured on 27.2's 167,193 items, 126,027 of them regular files (Apple's expansion against NativeAEA's, compared with
`stat`, `xattr`, and the stored `decmpfs` bytes: identical, but for the times of directories and links):

- **Times:** regular files get their cpio `mtime`; directories and symbolic links are left at the extraction's time.
  No extended attributes, no quarantine; owner is the extracting user, mode from the cpio (`& 07777`).
- **Compression:** `decmpfs` type **8** (LZVN in the resource fork; never type 7, inline) for exactly the files
  - larger than **16,384 bytes** (every smaller file is plain, however well it compresses),
  - that **aren't PNGs** (the 8-byte PNG signature: all 146 PNGs over 16 KiB are plain),
  - whose fork **saves at least a fifth of the 4 KiB blocks**: `ceil(fork / 4096) × 5 ≤ ceil(size / 4096) × 4` (by
    bytes, ratios from 0.787 to 0.864 went both ways; by blocks, all 27,035 files over 16 KiB fit).
- **The fork:** a table of chunk count + 1 u32 offsets, then 64 KiB chunks, each Compression's LZVN
  (`COMPRESSION_LZVN`, 0x900) of the chunk, or `0x06` and the raw bytes when that's no smaller or fails. The encoder
  gets the **chunk's own size** as room (`aa extract` gives LZBITMAP a whole chunk's, §3). LZVN's stream doesn't
  depend on the room, but the encoder needs 1–10 bytes beyond it, so a chunk that shrinks by less fails and is stored
  raw: in 27.2, the short last chunks (20–1,564 bytes) of 42 files. Every full chunk that compresses comes out the
  same with any room (153,662 of 154,171; the other 509 are stored raw either way).
- **Order of calls:** `fchflags(UF_COMPRESSED)` sets the file's modification time to now, so the times are set after
  the flag (NativeAEA's writer: owner, mode, flags, times, then any locking flags).

NativeAEA reads the TOC (inflated with Bytes' DEFLATE, parsed by a small XML scanner), checks the TOC checksum and
the signature and chain (Bytes' RSA and X.509, pinned to Apple Root CA, at the archive's `creation-time`), decodes the
pbzx blocks in parallel with Bytes' xz decoder, hashes `Content` with SHA-1 on a thread of its own while it's decoded,
and walks the cpio stream into the same extractor as Apple Archives (`CpioWalker`), so files are written with the
rules above.
