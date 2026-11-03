# ResumeDataBlob

An experiment exploring, decoding, and (partially) mutating the opaque
resume-data blob produced by `URLSessionDownloadTask.cancel(byProducingResumeData:)`,
using the local [Firewalk](../Firewalk) server (`http://127.0.0.1:8080`) as a
network target.

Run with:

```sh
swift run ResumeDataBlob            # Parts 1-3, requires Firewalk running locally
swift run ResumeDataBlob --probes   # also Part 4 (needs the patched Firewalk)
swift package --disable-sandbox benchmark   # decode/encode strategy benchmarks (see below)
```

Artifacts from each run are written to `Output/` (git-ignored):
`resume-data.plist` (raw captured blob), `resume-data-schema.txt` (full
recursive schema dump), `resume-data-mutated.plist`, and the two resumed
downloads (`resumed-original.bin`, `resumed-redirected.bin`).

## Part 1 — Capturing resume data

`CancellingDownloadDelegate` starts a `URLSessionDownloadTask` against
Firewalk's `GET /download/:count` endpoint (count must be a multiple of 10,
≤10,000,000; the server streams the body in 10 chunks with a 1ms delay
between them), cancels the task partway through via
`cancel(byProducingResumeData:)`, and bridges the delegate callback to
`async`/`await`.

`URLSession` only produces resume data for a `GET` over http(s) whose
response is an `NSHTTPURLResponse` carrying an **`ETag` or `Last-Modified`**
(either one; verified by disassembly and by probing a server with
`?noLastModified`, `?etag`, `?noAcceptRanges`). `Accept-Ranges` is **not**
required (an earlier version of this README said it was). With neither
validator, `cancel(byProducingResumeData:)` hands back `nil`.

> Platform note: the disassembly (Binary Ninja, iOS 27.0.1 / 24A446 shared
> cache) is of iOS; all experiments ran on macOS 27.0.1. The macOS blob
> matched the iOS code paths in every respect tested.

## Part 2 — Reverse-engineering the schema

**The resume data blob is not a flat plist — it's a full `NSKeyedArchiver`
object graph**, serialized as a binary plist. Running
`PropertyListSerialization` directly on the raw bytes only reveals the
generic archiver envelope: `$archiver` ("NSKeyedArchiver"), `$version`,
`$top` (a single key pointing into `$objects`), and `$objects` (a flat array
of every archived object/class-info record, including `NS.keys`/`NS.objects`
pairs for dictionaries). None of the real resume-data keys are visible at
this level.

Unarchiving with `NSKeyedUnarchiver` reveals the actual dictionary, whose
schema (current as of macOS 27 / this machine's CFNetwork — **expected to
evolve across OS versions, which is the reason this tool exists**) is:

| Key | Type | Notes |
|---|---|---|
| `NSURLSessionDownloadURL` | `String` | The URL originally requested. |
| `NSURLSessionResumeBytesReceived` | `Int64` | Bytes already downloaded to the temp file. |
| `NSURLSessionResumeCurrentRequest` | `Data` | Nested `NSKeyedArchive` of an `NSURLRequest` — the *ranged* request URLSession will actually reissue on resume. |
| `NSURLSessionResumeOriginalRequest` | `Data` | Nested archive of the original, un-ranged `NSURLRequest`. |
| `NSURLSessionResumeInfoTempFileName` | `String` | e.g. `CFNetworkDownload_XXXXXX.tmp` — partial-download temp file name. |
| `NSURLSessionResumeInfoVersion` | `Int` | Format version; observed value `6`. Used to select the right schema — see "Versioning" below. |
| `NSURLSessionResumeResponse` | `Data` | Nested archive of the `NSHTTPURLResponse` received so far. |
| `NSURLSessionResumeServerDownloadDate` | `String` | Despite the name, the raw `Last-Modified` header **string**, not a `Date`. Present only if the response had `Last-Modified`. |

Optional keys found in the disassembly that `ResumeDataSchemaV6` does **not**
model (the first one was also observed on the wire):

| Key | When present |
|---|---|
| `NSURLSessionResumeEntityTag` | Response had an `ETag` (observed: an ETag-only server yields this key and no `ServerDownloadDate`). |
| `NSURLSessionResumeInfoLocalPath` | Task was created with an explicit download file path; on read it overrides the temp-dir + `TempFileName` lookup. |
| `NSURLSessionResumeExtractor` | Streaming-zip downloads; `BytesReceived` is then omitted. |
| `PublishingURL` | Background-publishing downloads; passed through on resume. |

`BytesReceived` is the temp file's on-disk size, written only when there is
no extractor. `InfoVersion` is the literal `6` on iOS 27.0.1 and macOS 27.0.1.
### Gotcha #1 — inconsistent root keys

Both the top-level resume-data archive and the two nested *request* archives
store their root object under the **literal string** key
`"NSKeyedArchiveRootObjectKey"` — not under the *value* of the Foundation
constant `NSKeyedArchiveRootObjectKey`, which is `"root"`. The nested
*response* archive, however, uses `"root"`. Both must be tried when
decoding; see `ResumeDataArchiveRootKey.candidates`. (Disassembly:
CFNetwork writes/reads the top level and the nested requests via a
`NSKeyedArchiveRootObjectKey` string literal, and the response with
`archivedDataWithRootObject:` (default `"root"`), which agrees with the
empirical finding. The literal's value itself was not read from the binary.)

### Gotcha #2 — `decodeObject(of:forKey:)` silently returns `nil`

`NSKeyedUnarchiver`'s class-restricted API,
`decodeObject(of:forKey:)`/`decodeTopLevelObject(of:forKey:)`, returns `nil`
**without setting an error** if `requiresSecureCoding == false`. The
unrestricted `decodeObject(forKey:)` decodes the exact same archive
successfully in that mode. To use the safer, class-restricted API you must
set `unarchiver.requiresSecureCoding = true` — otherwise it will look like
decoding failed for no reason.

### Versioning

`NSURLSessionResumeInfoVersion` may change as CFNetwork evolves. **Note:** the
OS itself never reads it — the consumer (`_downloadTaskWithTaskForClass:`)
ignores the value, and resuming with it set to 99 or removed works
identically. Version dispatch here is purely this tool's own design:

- `ResumeDataSchemaVersion` is a protocol mapping one version's dictionary
  keys to and from `ResumeDataEnvelope`.
- `ResumeDataSchemaV6` is the only implementation today (the schema
  documented above).
- `ResumeDataSchema.versions` registers all known versions;
  `ResumeDataSchema.resolve(_:)` picks the schema matching a blob's version,
  falling back to `ResumeDataSchema.current` for unrecognized ones.

To support a new OS version whose blobs report a different
`NSURLSessionResumeInfoVersion`, add a new `ResumeDataSchemaVersion`-conforming
type and register it in `ResumeDataSchema.versions` — no other decode/encode
code needs to change. Older versions can be supported the same way.

### Decoding strategies compared

`ResumeDataCodec` implements three ways to go from raw resume-data bytes to
a `ResumeDataEnvelope`, all cross-checked for equality against real captured
data and all dispatched through the versioned schema above:

- **`decodeDirect`** — unarchive to `[String: Any]` (bridging the whole
  `NSDictionary`), then hand the dictionary to the matching schema.
- **`decodePerKey`** — same, but the schema reads each field straight off
  the unarchived `NSDictionary` via `object(forKey:)`, without ever bridging
  the whole dictionary to a Swift `[String: Any]`.
- **`decodeCodable`** — unarchive, re-serialize as a flat plist, and decode
  with `PropertyListDecoder` against `ResumeDataEnvelope: Codable`. Fixed to
  `ResumeDataSchemaV6`'s key names (not version-dispatched); kept only as a
  baseline for how much the extra round trip costs.

And two ways to go back from a `ResumeDataEnvelope` to bytes usable by
`URLSession.downloadTask(withResumeData:)`:

- **`encodeDirect`** — resolve the schema matching `envelope.infoVersion`
  (or `ResumeDataSchema.current` if unset), build its dictionary form, and
  archive it with `NSKeyedArchiver`.
- **`encodeCodable`** — encode with `PropertyListEncoder`, reparse the
  result, then archive with `NSKeyedArchiver`. Fixed to `ResumeDataSchemaV6`;
  baseline only.


## Part 3 — Mutating resume data to redirect a download

Unarchive the blob, decode the Current/Original requests, point their URLs
(and `NSURLSessionDownloadURL`) at another path on the same server, drop
`NSURLSessionResumeInfoTempFileName`, re-archive and call
`downloadTask(withResumeData:)`.

Result against Firewalk: a blob captured for `/download/10000000` (~3MB
received) and redirected to `/download/2000000` completed with exactly
2,000,000 bytes, while an unmodified control resume (using its own freshly
captured blob) completed with 10,000,000.

**The mechanism is not what an earlier version of this README claimed.** It
said URLSession "didn't care" about the stale `BytesReceived`/`Response`. In
fact the mutation drops `NSURLSessionResumeInfoTempFileName`, so URLSession
can't reopen the partial file and silently **restarts from byte 0** (server
log: `GET /download/2000000`, no `Range`). The original experiment reached
the same outcome by accident: its control resume ran first and consumed the
temp file. With the temp file left intact the redirect does **not** work:
URLSession sends `Range: bytes=<BytesReceived>-` (3,000,000) to the new,
shorter resource; the server answers 416 and the "download" completes with
0 bytes and status 416 — no error is raised (Part 4 probe).

## Part 4 — Probes (`swift run ResumeDataBlob --probes`)

Each probe captures a fresh blob, mutates one thing, and resumes it, logging
the `Range`/`If-Range` the server saw. Results (Firewalk, macOS 27.0.1):

| Mutation | Outcome |
|---|---|
| none (control) | `Range: bytes=3000000-`, `If-Range: <Last-Modified string>`; 206; 10,000,000 bytes |
| `BytesReceived` = 1,000,000 (smaller than file) | resumes at 1,000,000; **12,000,000-byte corrupt file** (appended to the 3MB already on disk) |
| `BytesReceived` = 9,999,999 | resumes there; truncated ~3,000,001-byte file |
| `BytesReceived` removed | `Range: bytes=0-`; **13,000,000-byte corrupt file** |
| `InfoVersion` 99 / removed | identical to control |
| `TempFileName` missing / removed | silent restart: 200, full body, no `didResumeAtOffset` |
| `CurrentRequest` removed | works (Original used) |
| Current+Original removed | works (`DownloadURL` used) |
| `ServerDownloadDate` changed/removed, `EntityTag` added, `Response` removed | works; only the `If-Range` value sent changes |
| Redirect, temp file intact | `Range: bytes=3000000-` to 2MB resource → 416, 0 bytes, no error |
| Range `bytes=5-9` on the *Current* request | ignored (overwritten); normal `bytes=3000000-` |
| Range `bytes=5-9` on the *Original* request | rewritten to `bytes=3000005-9` (offset added to start, an inverted range); Firewalk ignores the invalid header and replies 200 with the full body; URLSession reports `didResumeAtOffset 0`, discards the partial data, and completes with a clean 10,000,000-byte file |

Stock Firewalk crashed on the last row (negative buffer size for
`start > end`). `../Firewalk/Sources/Download.swift` is patched: inverted
ranges are ignored per RFC 9110 (200), out-of-range starts return 416,
`Range`/`If-Range`/`If-Match` are logged, and `?etag=1`, `?noLastModified=1`,
`?noAcceptRanges=1` toggle headers. Note that URLSession handles a 200 reply
to a ranged resume correctly (truncates and restarts), unlike a 206 with a
mismatched offset.

## Corrections to the earlier reverse engineering

1. **Part 3's explanation was wrong** (see above): the redirect worked because
   the temp file was gone, not because stale fields were harmless.
2. **Stripping `Range`/`If-Range` from the stored requests is unnecessary.**
   On resume URLSession rebuilds `Range` from the Original request's `Range`
   plus `BytesReceived`, and overwrites `If-Range` from the ETag /
   Last-Modified.
3. **Producer prerequisites were overstated**: `Accept-Ranges` isn't required,
   and the validator is `ETag` **or** `Last-Modified`, not specifically the latter.
4. **The schema was incomplete**: `EntityTag`, `InfoLocalPath`, `Extractor`,
   `PublishingURL` exist and `ResumeDataSchemaV6` ignores them (the encode
   path would drop them when round-tripping such a blob).
5. **"Versioned schema" is not an OS mechanism** — the version is write-only.
6. **"An `NSKeyedArchiver` graph" holds only for the classic loader.** With the
   Network.framework loader (`NWURLSessionDownloadTask`), the blob is
   `archivedData(NWURLSessionDownloadResumeInfo)` whose **first 8 bytes are
   XOR-scrambled with `"TedLasso"`** (so it doesn't start with `bplist00`);
   WebKit-networking mode additionally wraps it in
   `{data, NSURLSessionResumeInfoLocalPath}`. These parsers can't read that
   format. (Its producer has the same preconditions plus: no `Content-Encoding`
   other than `identity`, and the original `Range` must not be multi-range.)
   The experiment's sessions all produced the classic format.
7. Firewalk "doesn't support validators" was a server limitation (now
   partly addressed); its Range handling also crashed for out-of-range starts.

## Internal behavior relevant to using the blob

From `-[__NSURLSessionLocal _downloadTaskWithTaskForClass:]` (`0x18cdf4ffc`),
`_expandResumeData:` (`0x18ce81c70`), `_requestFromResumeDataDictionary:`
(`0x18ce81e1c`) and `createResumeInformation:` (`0x18ce59504`):

- **Parsing.** Data is read as a plist; if it has `$archiver` it is unarchived
  securely (allow-list: NSDictionary/Array/String/Number/Data/URL/NSURLRequest,
  plus extractor classes) with the top-level root key; if unarchiving fails it
  falls back to using the plain plist dictionary — a *flat plist with the right
  keys works too*. Unarchive failures use set-error policy, not exceptions.
- **Request selection:** `CurrentRequest` → `OriginalRequest` →
  `DownloadURL` (rebuilt as GET, `reloadIgnoringLocalCacheData`, 60s). The
  task is created from that request, then `originalRequest` is reset to the
  stored Original. So editing `DownloadURL` alone only matters if both
  request archives are missing/undecodable.
- **Range construction (intentional, verified in `_downloadTaskWithTaskForClass:`).**
  N = `BytesReceived`, trusted verbatim and never compared with the temp
  file's real size. The code reads `Range` from the *Original* request and
  writes the result to the Current-request copy. Purpose: the app's original
  `Range` describes the slice it wants, and N bytes of that slice are already
  on disk, so the resume requests only the remainder of the *same* slice
  rather than replacing it with an open-ended range:

  | Original `Range` | Resume `Range` |
  |---|---|
  | none, or not `bytes=…` | `bytes=N-` |
  | `bytes=a-` | `bytes=(N+a)-` |
  | `bytes=a-b` | `bytes=(N+a)-b` |
  | `bytes=-n` (last n bytes) | `bytes=-(n-N)` |
  | any other shape (e.g. multi-range, more than one `-`) | header left as-is, log "Unsupported Range header value, restarting", temp file truncated to empty |

  No clamping is done, so an inconsistent N yields nonsense such as
  `bytes=3000005-9` (measured, Part 4). (An earlier draft of this README
  called only the `a-b` row out; the table is from the full decompile and
  the `a-b`, no-Range cases are also confirmed on the wire.) `If-Range`
  (header string length 8, "If-Range") = ETag, else Last-Modified string,
  always overwritten, even with nil.
- **Temp file.** Located as `InfoLocalPath`, else
  `NSTemporaryDirectory()`/`explicitDownloadDirectory` + the stored *basename*,
  opened with `open(path, O_WRONLY|O_APPEND)` — no `O_CREAT`. Missing file (or
  a changed container/temp directory, common across app reinstalls) logs
  "cannot create download file from resume data" and falls back to a fresh
  download from the stored request: **silent restart, no error**. The data is
  therefore only meaningful on the device/container that produced it, and a
  resume consumes the partial file (a blob can't be resumed twice).
- **Response.** Restored if decodable; failure is only logged.
- **Server contract is only partly enforced client-side.** A 200 reply to a
  ranged resume is handled as a restart (measured: partial data discarded,
  clean full file; `didResumeAtOffset` reported 0). A 416 is delivered as the
  final result with a 0-byte file and no error, and a 206 whose offset
  disagrees with the file is appended blindly. Check `response.statusCode`
  in the delegate callbacks.
- **"Corrupt resume data" exception.** `downloadTask(withResumeData:)` raises
  `NSInvalidArgumentException` only if no request can be derived at all (and
  the app links a new-enough SDK); no realistic mutation triggered it. Nil/empty
  data and a request-less call raise "Cannot create download task without
  request or resume data"; an invalidated session logs and returns nil.
- **Producing.** `cancel(byProducingResumeData:)` yields data only while the
  task `state <= 2` (running/suspended/canceling); otherwise the handler gets
  `nil`. If a handler is already pending, calls are chained.
- **Implications for the reverse-engineered APIs.** `encodeDirect` /
  `ArchivedRequestCodec` produce blobs URLSession accepts, but editing
  `BytesReceived` without editing the temp file corrupts the output, and
  editing the URL requires also removing/invalidating the temp file to get a
  restart (or truncating it and setting `BytesReceived` to 0 to get a clean
  fresh download). Don't rely on `InfoVersion` edits.
- **Not verified:** the iOS-only NW-loader and daemon (`nsurlsessiond`)
  consumers were disassembled but not run; the `a-`, `-n` and
  unsupported-shape Range rows were read from disassembly only (not run); benchmark numbers were not re-run.

## Benchmarks

`Benchmarks/ResumeDataBlobBenchmarks` uses
[`ordo-one/benchmark`](https://github.com/ordo-one/benchmark) to compare all
five codec strategies above for wall-clock time, instruction count, malloc
count, and peak resident memory delta, over one real resume-data blob
captured from Firewalk. Run with:

```sh
swift package --disable-sandbox benchmark
```

`--disable-sandbox` is required because the fixture blob is captured by making
a real network request to Firewalk, and SwiftPM's plugin sandbox blocks
networking by default (without it the run fails fast with an "Operation not
permitted" / `NSPOSIXErrorDomain` error from the fixture capture).

Representative results on Apple Silicon (medians; see `swift package
benchmark` output for full percentile tables):

| Benchmark | Time (μs) | Instructions (K) | Mallocs |
|---|---|---|---|
| Decode.PerKey | 14 | 198 | 58 |
| Decode.Direct | 15 | 220 | 59 |
| Decode.Codable | 28 | 408 | 106 |
| Encode.Direct | 23 | 373 | 90 |
| Encode.Codable | 45 | 662 | 146 |

Takeaway: skipping `PropertyListDecoder`/`PropertyListEncoder` roughly halves
both time and allocation count for both decoding and encoding, and reading
fields directly off the unarchived `NSDictionary` (`decodePerKey`) is
marginally cheaper still than bridging it to `[String: Any]` first
(`decodeDirect`).

## Package layout

- `Sources/ResumeDataBlobKit` — all logic (public library target).
- `Sources/ResumeDataBlob` — thin `@main` executable driving Parts 1–3.
- `Benchmarks/ResumeDataBlobBenchmarks` — the benchmark suite above.
