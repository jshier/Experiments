# The Apple Encrypted Archive format, as Xcode ships in it

Apple doesn't publish the `.aea` layout. This is what NativeAEA reads, worked out from Xcode 27.3 beta 2's archive,
SDK headers (`AppleArchive/AEADefs.h`, `AADefs.h`), and other readers (blacktop/ipsw, aea-tools). Every structure and
derivation below was checked against Apple's own tools: `aea decrypt` and `aea id` on Xcode's archive, and archives
`aea encrypt` and `aa archive` made in the tests (every segment compression, checksum, and segment size).

There are three layers: the **container** (`AEA1`: signature, keys, MACs, compressed segments), the **Apple Archive
stream** inside it (`AA01` entries), and how Apple's extractor **writes files** (APFS compression).

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
key, 2 symmetric + signed, 3 ECDHE, 4 ECDHE + signed, 5 scrypt password. NativeAEA reads profile 0.

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
`aea encrypt`'s default segment is 1 MiB.

**Segments** are compressed independently. A segment whose stored size equals its raw size is stored as is.
Otherwise:

- `x`: a complete `.xz` stream, one block, the LZMA2 filter alone (dictionary 8 MiB in Xcode's), check type None.
- `z`: zlib, with the RFC 1950 wrapper and Adler-32 (not raw DEFLATE, which is what Compression's `COMPRESSION_ZLIB`
  decodes).
- `4`: raw LZ4 blocks (Compression's `COMPRESSION_LZ4_RAW`, not its `bv41` frames).
- `e`, `b`, `m`: LZFSE, LZBITMAP, and LZRAVEN streams as Compression writes them (`COMPRESSION_LZRAVEN`, buffer
  API only, macOS 27).
- `f`: LZVN. `aea encrypt` can't make it and Compression's public API has no LZVN decoder; NativeAEA reports it as
  unsupported.

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

On encrypted profiles the same derivations produce 80 bytes (MAC key, AES-256 key, CTR IV) and the main key's input is
the symmetric key or an ECDH secret; on profile 0 the key material is stored in the clear, so anyone can derive every
key. That's fine: the MACs only chain everything to the prologue, and the signature authenticates the prologue.

Every MAC is `HMAC-SHA256(key, associated data | data | u64 size of the associated data)`:

| What | Key | Associated data | Data | Stored in |
|---|---|---|---|---|
| Root header | root header key | first cluster header's MAC, auth data | root header | prologue |
| Cluster header | cluster header key | next cluster header's MAC, segment MACs | segment infos | previous header (the prologue for cluster 0) |
| Segment | segment key | — | stored (compressed) bytes | its cluster header |
| Padding | padding key | (plain HMAC, no size) | padding | last cluster's next-header slot |

**The signature** is ECDSA P-256 with SHA-256 over the whole prologue with the signature field zeroed, DER-encoded,
zero-padded to 128 bytes. The public key is the leaf certificate's (or one given with `aea -sign-pub`). **The archive
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
| `T` / `S` | time: u64 seconds and u32 nanoseconds / u64 seconds |
| `F` `G` `H` `I` `J` | CRC-32 (4), SHA-1 (20), SHA-256 (32), SHA-384 (48), SHA-512 (64) |
| `A` `B` `C` | blob with a u16, u32, or u64 size: the bytes follow the header |

Keys (`AADefs.h`): `TYP` type (`F` file, `D` directory, `L` link, …), `PAT` path, `LNK` link target, `UID`, `GID`,
`MOD` (the header says the low 12 bits of `st_mode`; Xcode's carry the whole of it, type bits included: 0x81ED for
a 0755 file, 0x41ED for a directory), `FLG` (`st_flags`), `MTM`/`CTM`/`BTM` times, `DAT` contents, `XAT` extended attributes, `ACL`,
`SIZ`, `SH2` …, `HLC`/`CLC`/`SLC` hard-link, clone, and same-data cluster ids. `aa archive` writes `TYP1 PATP UID2 GID1
MOD2 FLG1 CTMT MTMT [DATA|DATB]` per entry, and a first entry with an empty path (the destination itself).

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

Apple's choices, measured on Xcode (and matched by NativeAEA file for file):

- **Inline** (type 13) when the attribute, header included, is at most **3,584 bytes**: 88,006 files.
- **Resource fork** (type 14) otherwise: 37,881 files, 9.45 GB raw in 3.12 GB.
- **Plain** when the fork would be **93% or more** of the raw size (the highest ratio it compressed was 0.9293; the
  lowest it left plain, 0.9304): 318 files, 0.72 GB (packages, asset catalogs, PNGs). Inline files never fall back.
- Permissions from `MOD` on files, directories, and links (18 links have 0644); files and directories are 3.9 GB on
  disk in all.

`aa extract` also copies the source archive's quarantine attribute onto every item; NativeAEA doesn't.
