import Bytes

// The packed flag bytes, declared once by name: each packet reads and writes them through these, not bit
// numbers. Computed `static var`s, so each use inlines to the shift and mask written by hand.

/// CONNECT's connect flags [MQTT-3.1.2.3], from the most significant bit: user name, password, will retain,
/// will QoS (2 bits), will, clean start, and a reserved bit.
@usableFromInline
enum ConnectFlags {
    @inlinable static var userName: BitFlag { BitFlag(bit: 7) }
    @inlinable static var password: BitFlag { BitFlag(bit: 6) }
    @inlinable static var willRetain: BitFlag { BitFlag(bit: 5) }
    @inlinable static var willQoS: BitField<MQTTQoS> { BitField(bits: 3...4) }
    @inlinable static var will: BitFlag { BitFlag(bit: 2) }
    @inlinable static var cleanStart: BitFlag { BitFlag(bit: 1) }
    @inlinable static var reserved: BitFlag { BitFlag(bit: 0) }
}

/// CONNACK's acknowledge flags [MQTT-3.2.2.1]: 7 reserved bits, then Session Present.
@usableFromInline
enum ConnectAcknowledgeFlags {
    @inlinable static var reserved: BitField<Int> { BitField(bits: 1...7) }
    @inlinable static var sessionPresent: BitFlag { BitFlag(bit: 0) }
}

/// PUBLISH's fixed-header flags [MQTT-3.3.1]: DUP, QoS (2 bits), RETAIN.
@usableFromInline
enum PublishFlags {
    @inlinable static var duplicate: BitFlag { BitFlag(bit: 3) }
    @inlinable static var qos: BitField<MQTTQoS> { BitField(bits: 1...2) }
    @inlinable static var retain: BitFlag { BitFlag(bit: 0) }
}

/// A subscription's options byte [MQTT-3.8.3.1], from the most significant bit: 2 reserved bits, retain
/// handling, retain as published, no local, and maximum QoS.
@usableFromInline
enum SubscriptionOptionFlags {
    @inlinable static var reserved: BitField<Int> { BitField(bits: 6...7) }
    @inlinable static var retainHandling: BitField<MQTTRetainHandling> { BitField(bits: 4...5) }
    @inlinable static var retainAsPublished: BitFlag { BitFlag(bit: 3) }
    @inlinable static var noLocal: BitFlag { BitFlag(bit: 2) }
    @inlinable static var maximumQoS: BitField<MQTTQoS> { BitField(bits: 0...1) }
}
