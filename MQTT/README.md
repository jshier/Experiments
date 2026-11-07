# MQTT

An MQTT 5.0 packet parser and encoder built on [`Bytes`](../Bytes). Packets are views of the bytes they came
from: parsing copies and allocates nothing, and encoding writes straight into memory you provide. On an M3
Ultra a core parses 15 M PUBLISH packets a second (1.9 GB/s) and all cores 344 M (43 GB/s), 5.5–11x the
conventional `[UInt8]`-and-`String` approach; see `Benchmarks/RESULTS.md`.

```swift
import Bytes
import MQTT

// Parse packets as bytes arrive; a partial packet is left for later.
var reader = Bytes(received.span)
while let packet = try MQTTPacket.read(from: &reader, maximumPacketSize: 1 << 20) {
    switch packet {
    case .publish(let publish):
        deliver(String(copying: publish.topic), [UInt8](copying: publish.payload)) // copy what you keep
        publish.properties.forEach { property in
            if case .messageExpiryInterval(let seconds) = property { expire(after: seconds) }
        }
    case .pingRequest:
        try send(.pingResponse)
    default:
        break
    }
}
received.removeFirst(reader.byteOffset)

// Encode into a buffer sized exactly.
let packet = MQTTPacket.publish(MQTTPublish(
    qos: .atLeastOnce, topic: "sensors/kitchen".utf8Span, packetIdentifier: 7, payload: reading.span.bytes
))
let bytes = try [UInt8](capacity: packet.encodedByteCount) { output in
    try output.withBytesWriter { (writer) throws(BytesError) in try packet.write(to: &writer) }
}
```

## What it checks

- **Parsing** throws `MQTTError` for every rule MQTT 5.0 puts on a receiver: fixed-header flags,
  minimal Variable Byte Integers, the properties each packet may carry (once, except User Property and
  Subscription Identifier) and their values, UTF-8 without U+0000, topic names and filters, packet
  identifiers, and each packet type's reason codes. The error's `kind` is malformed packet, protocol
  error, packet too large, or unsupported protocol version, and `reasonCode` is the code to disconnect
  with. A throw consumes nothing.
- **Encoding** checks the same rules first (`MQTTPacket.validate()` gives the reason) and writes nothing
  for a packet the parser would reject.
- **Not checked**: wildcard placement in topic filters (a server answers 0x8F in its SUBACK) and session
  state, such as topic aliases, receive maximum, and packet identifiers in flight.

## Types

`MQTTPacket` is an enum of the 15 packet types:
- `MQTTConnect` (with `MQTTWill`) and `MQTTConnectAcknowledgement`;
- `MQTTPublish` and `MQTTPublishResponse` (PUBACK, PUBREC, PUBREL, PUBCOMP);
- `MQTTSubscribe` and `MQTTSubscribeAcknowledgement` (also UNSUBACK);
- `MQTTUnsubscribe`;
- `MQTTDisconnect` and `MQTTAuthenticate`;
- PINGREQ and PINGRESP.

Every type is `~Escapable`. `UTF8Span` strings and `RawSpan` payloads borrow the input or, when encoding,
your values. Lists (`MQTTProperties`, `MQTTSubscriptions`, `MQTTTopicFilters`) are checked once and decoded
on each `forEach`, without allocating. Build one for encoding by writing its entries with a `BytesWriter`,
then view it with `init(validating:)`.

## Caveats

- Requires the 2027 OS releases, Swift 6.4, and the experimental `Lifetimes` feature (as `Bytes` does).
- Swift Testing's `#expect`/`#require` and `Optional.map` need `Escapable` values. Read what you check into
  plain values first, as the tests do.
- It's the packet layer only: no networking, session state, or topic matching.
