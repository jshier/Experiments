# Bytes API proposals from MQTT and MQTTSocketStream

Most valuable first. Each was prototyped as an extension in a scratch copy of MQTT
(a scratch copy of the package; prototypes in `prototypes/MQTT/`), used at its call sites, and
compared by per-function instruction counts in the release `MQTT.o` (`Tools/loops --target` builds it)
against the `modern` code. None were kept in the packages (reasons per item). Swift 6.4.2, M3 Ultra.
File:line references are to MQTT/Sources/MQTT as of this run.

## 1. Minimal (canonical) LEB128: `requiringMinimal:`

**Motivation.** MQTT's Variable Byte Integer must be in the fewest bytes [MQTT-1.5.5-1]. MQTT wraps
every LEB128 read in its own helper, and picks between helper and plain read with a ternary wherever
checked and unchecked paths share code:

- Basics.swift:330 `readMQTTVariableByteInteger()` (13 lines: `atomically`, byte count, recompute the
  minimal length, throw);
- Properties.swift:42 and :59
  `checked ? try reader.readMQTTVariableByteInteger() : try reader.read(LEB128.self, maxByteCount: 4)`;
- Properties.swift:298 the property list's length, then `read(byteCount:)`; Framing.swift:62 the
  remaining length.

**Proposed.**

```swift
extension BytesReader {
    /// LEB128 of at most `maxByteCount` bytes; if `requiringMinimal`, also throws `.invalidValue`
    /// (consuming nothing) for a padded encoding: more than one byte with a final 0x00.
    mutating func read(_: LEB128.Type, maxByteCount: Int = 10, requiringMinimal: Bool) throws(BytesError) -> UInt64
    mutating func read(bytesPrefixedBy _: LEB128.Type, maxByteCount: Int = 10, requiringMinimal: Bool) throws(BytesError) -> RawSpan
    mutating func read(sectionPrefixedBy _: LEB128.Type, maxByteCount: Int = 10, requiringMinimal: Bool) throws(BytesError) -> BytesReader
}
```

Inside Bytes the check is the decode loop's last byte being nonzero (or the only byte), which costs
nothing beyond the loop; outside, it has to recompute `LEB128.byteCount(of:)`.

**After.**

```swift
let identifier = try reader.read(LEB128.self, maxByteCount: 4, requiringMinimal: checked)      // Properties.swift:42
bytes = try reader.read(bytesPrefixedBy: LEB128.self, maxByteCount: 4, requiringMinimal: true) // Properties.swift:298
```

and `readMQTTVariableByteInteger` goes away.

**Evidence.** The scalar form (prototype: `atomically` + `LEB128.byteCount(of:)`, as MQTT does now) at
Properties.swift:42 and :59: **identical instruction counts** for every function. The prefixed form,
prototyped over Bytes' `read(bytesPrefixedBy: LEB128.self, maxByteCount:)` with the minimal check after
it: `MQTTProperties.init(reading:allowing:repeatable:)` 124 → 144 instructions (+20, for the
consume-nothing guarantee MQTT's two-step read doesn't make). Implemented inside Bytes, with the check
in the decode loop, it should be the existing prefixed read's cost. **Reverted**: the prefixed form isn't
free from outside, and the scalar form alone saves only the ternaries.

## 2. Sub-byte fields at a byte boundary are 3x the code of a `Byte` read (docs, or a fast path)

**Motivation.** MQTT read and wrote its flag bytes field by field, as the spec draws them (CONNECT's
7 fields, the subscription options' 5, CONNACK's 2, the fixed header's 2 nibbles). A byte-aligned
`read(Bit.self)`/`read(Crumb.self)`/`read(Nibble.self)` takes the general bit path (bit offset, bit order,
two-byte window), and so does each sub-byte write. Reading one `Byte` and using the field subscripts,
or packing a `Byte` and writing it once, is much smaller. This change was made in MQTT this run.

| Function | Field by field | One `Byte` |
|---|---|---|
| `MQTTSubscriptionOptions.write(to:)` | 273 | 83 |
| `MQTTSubscriptionOptions.init(reading:)` | 278 | 176 |
| `MQTTConnect.writeBody(to:)` | 567 | 339 |
| `MQTTConnect.init(reading:)` | 930 | 774 |
| `MQTTFrame.read(from:maximumPacketSize:)` | 457 | 398 |

Benchmarks: encode PUBLISH −7.9% instructions, mixed-stream parse −15.6%, frames −4.7%.

**Proposed.** At least a README/docc note under Performance ("fields that fill a byte: read the `Byte`
and take it apart with `[bit:]`/`[Bits<n>.self, at:]`; pack before writing"), next to the existing
"Pack bits before writing them" lesson, which covers only loops. Possibly: a fast path in
`read(Bits<n>)` for a byte-aligned cursor where `n` divides 8 (load the byte once). That may not be
cheaper than the general path once inlined, so measure it in Bytes first. A packed reader for
several fields (`let (a, b, c) = try reader.read(Bit.self, Crumb.self, Nibble.self)`) needs parameter
packs over value generics; not prototyped.

## 3. A non-throwing rewind: `mark` / `rewind(to:)`

**Motivation.** Five places save the offset and later `try! seek(toByteOffset: start)` to undo a read,
where `atomically` can't be used because a closure can't return a lifetime-dependent value (a frame, a
packet):

- Framing.swift:56, :64, :77, :82 (`MQTTFrame.read`: incomplete, too large, or reserved type/flags);
- Packet.swift:64, :69 (`MQTTPacket.read`: the packet failed to parse);
- Packets.swift:58, :62 (classifying a rejected topic name).

`seek` throws for an offset past the end, which a position the cursor was at can't be, hence the `try!`.

**Proposed.**

```swift
extension BytesReader {
    struct Mark { /* byte and bit offset */ }
    var mark: Mark { get }
    /// Moves back to `mark`, a position this cursor was at. Precondition: not ahead of the cursor.
    mutating func rewind(to mark: Mark)
}
```

**After.**

```swift
let start = reader.mark
// …
reader.rewind(to: start)
```

**Evidence.** Prototype (`Mark` wraps the byte offset; `rewind` calls `seek`) at all four Framing.swift
sites: **identical instruction counts** in `MQTTFrame.read`, `MQTTPacket.read`, and every other
function. Inside Bytes, `rewind` needs no bounds check, and a bit-level mark would restore the bit
offset too. **Reverted**: a wrapper over `seek` in MQTT would only hide the `try!`.

## 4. The write side of `init?(rawBits:)`: `Bits(rawBitsOf:)`

**Motivation.** Packing a raw-value enum into a field is
`Crumb(truncatingIfNeeded: qos.rawValue)`, five times: Basics.swift:252, :255; Packets.swift:205, :348
(`Crumb(qos.rawValue)`, which traps); Framing.swift:122 (`Nibble(truncatingIfNeeded: type.rawValue)`).
Reading already has `MQTTQoS(rawBits: flags[Crumb.self, at: 1])`.

**Proposed.**

```swift
extension Bits {
    /// `value`'s raw value as a field. Doesn't fit: debug builds trap, release builds keep the low bits
    /// (as `BytesWriter.write(_:as:)` does).
    init<R: RawRepresentable>(rawBitsOf value: R) where R.RawValue: BinaryInteger
}
```

**After.** `options[Crumb.self, at: 0] = Crumb(rawBitsOf: maximumQoS)`;
`Byte(highHalf: Nibble(rawBitsOf: type), lowHalf: flags)`.

**Evidence.** All five sites: **identical instruction counts** for every writing function. **Reverted**
rather than kept as an internal helper: an MQTT-internal `init(rawBitsOf:)` would become ambiguous with
Bytes' own if it's added.

## 5. Byte-value sets from a list of members (needs compile-time construction)

**Motivation.** `ReasonCodeSet` (Basics.swift:183–196) and `PropertySet` (Properties.swift:126–150)
are hand-computed 64-bit masks, with the members repeated in a comment above each, such as
`Self(low: 0x1_0001, high: 0x283_0089)` for "0x00, 0x10, 0x80, 0x83, 0x87, 0x90, 0x91, 0x97, 0x99".
A wrong bit is a silent protocol bug. A `ByteSet` could also back a `ByteLanes.matching(_: ByteSet)`
lane test (`tbl` on a 32-byte bitmap) for scans with many forbidden bytes.

**Proposed.** `struct ByteSet { init(_ members: InlineArray<n, UInt8>); func contains(_: UInt8) -> Bool }`,
written as `ByteSet([0x00, 0x10, 0x80, 0x83, 0x87, 0x90, 0x91, 0x97, 0x99])`, **but only if construction
happens at compile time**: a macro (`#byteSet(0x00, 0x10, 0x80...0x83)`, ranges too) that expands to
the literal words, or an initializer the constant evaluator can fold.

**Evidence that plain Swift doesn't fold it (Swift 6.4.2).** All seven `ReasonCodeSet`s rewritten with
the prototype:

- `InlineArray<4, UInt64>` storage, indexed by `byte >> 6`: the getter runs the members loop at run time
  (30 iterations for DISCONNECT) on every use. `MQTTDisconnect.validate()` 7 → 58 instructions,
  `MQTTPacket.init(parsing:)` 388 → 464.
- Four scalar words: still a run-time loop (not unrolled at 30 members): `MQTTDisconnect.init(reading:)`
  158 → 218.
- `static let` constants: `swift_once` on each use, and +14 to +146 instructions per function.

**Reverted.** Worth it only as a macro; the masks stay.

## 6. `RawSpan.hasPrefix(_: some ByteGroup)`

**Motivation.** Basics.swift:404–405, the `$share/` test, builds a reader to peek:
`let reader = BytesReader(filter.span); return (try? reader.peek(Byte7.self)) == 0x24_73_68_61_72_65_2F`.

**Proposed.** `extension RawSpan { func hasPrefix<T: ByteGroup>(_ prefix: T) -> Bool }` (and on
`UTF8Span`), `false` when shorter.

**After.** `filter.span.bytes.hasPrefix(0x24_73_68_61_72_65_2F as Byte7) // "$share/"`

**Evidence.** **Identical instruction counts** (`Text.isShared`, `MQTTSubscriptions.init(validating:)`).
**Reverted**: one call site.
