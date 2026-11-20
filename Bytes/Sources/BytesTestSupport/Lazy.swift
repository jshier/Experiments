/// A value made on first use: a benchmark's fixtures, made by its `setup` in the process that runs it.
///
/// package-benchmark runs each benchmark in a process of its own, and every process runs the whole registration
/// closure first: anything made while registering is made once per benchmark in the target. Register `Lazy`
/// values, and read them in `setup` and the measured closure.
///
/// Unchecked `Sendable`: made on first use by the one benchmark a process runs, from one thread at a time.
public final class Lazy<Value>: @unchecked Sendable {
    private var make: (() -> Value)?
    private var made: Value?

    /// A value `make` makes when it's first read.
    ///
    /// - Parameter make: Makes the value, once.
    public init(_ make: @escaping () -> Value) {
        self.make = make
    }

    /// The value, made on the first read.
    public var value: Value {
        if let made { return made }
        let value = make!()
        made = value
        make = nil
        return value
    }
}
