// Helpers the Bytes ports of swift-binary-parsing's examples share. (The reads they once prototyped here, NUL-terminated
// UTF-8 and integers of a run-time width, are Bytes API now: `read(utf8TerminatedBy:)`, `read(_:byteCount:)`.)

extension FixedWidthInteger {
    /// The value rounded up to a multiple of 4, wrapping: PCAPNG's padding.
    @inline(__always)
    var roundedUpToMultipleOf4: Self { (self &+ 3) & ~3 }
}
