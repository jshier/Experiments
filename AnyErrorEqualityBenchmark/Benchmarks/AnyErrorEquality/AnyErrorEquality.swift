import Benchmark

// MARK: - Error types under test

//
// These mirror the fixtures used to validate Alamofire's `AFError` equality
// behavior: a mix of `Equatable`/non-`Equatable`, struct/enum/class error
// types, used to exercise every branch of the "prefer `Equatable`, fall back
// to `AnyObject` identity, otherwise `false`" algorithm.

/// A trivial `Error` which also conforms to `Equatable`. Used to prove that the comparison
/// prefers exact `Equatable` comparison, when it's available, over the coarser fallbacks used for non-`Equatable`
/// errors.
private struct EquatableTestError: Error, Equatable {
    let code: Int
}

private enum EquatableEnumError: Error, Equatable {
    case first(Int)
    case second(String)
}

/// A second `Equatable` `Error` type, structurally identical to `EquatableTestError` but nominally distinct. Used to
/// prove that two wrapped errors are never considered equal unless they share the same concrete, dynamic type, even
/// when their stored properties match.
private struct OtherEquatableTestError: Error, Equatable {
    let code: Int
}

/// A trivial `Error` which does *not* conform to `Equatable`. When wrapped, comparisons between two
/// separately constructed instances of this type are always `false`, since there's no reliable signal (no
/// `Equatable` conformance, and no reference identity, since this is a `struct`) to compare on.
private struct NonEquatableTestError: Error {
    let message: String
}

/// A non-`Equatable` `Error` enum with multiple cases. Like `NonEquatableTestError`, comparisons between two
/// separately constructed instances of this type are always `false`, regardless of case or associated value.
private enum NonEquatableTestErrorEnum: Error {
    case first(Int)
    case second(Int)
}

/// A non-`Equatable`, class-based `Error`. Since it's a reference type, comparisons between two instances of this
/// type fall back to reference identity (`===`): the exact same instance always compares equal to itself, but two
/// separate instances are considered unequal even when their stored properties match.
private final class NonEquatableClassError: Error {
    let code: Int

    init(code: Int) {
        self.code = code
    }
}

// MARK: - Candidate A: Existential opening (`as? any Equatable`)

//
// The idiomatic, modern mechanism for attempting an `Equatable` comparison of two values whose static type is only
// known to be `Error`. Downcasting to the `any Equatable` existential succeeds if and only if the value's *dynamic*
// type conforms to `Equatable`. A small generic helper then performs the exact-type check and the `==` call
// together, since two existential `any Equatable` values can't be compared directly (their underlying concrete
// types might differ).

private extension Equatable {
    /// Compares `self` to `other`, returning `false` unless `other` is the same concrete type as `self`.
    @inline(__always)
    func isEqual(toAny other: Any) -> Bool {
        guard let other = other as? Self else { return false }
        return self == other
    }
}

@inline(__always)
private func isEqualDirect(_ lhs: Error?, _ rhs: Error?) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none):
        return true
    case let (.some(l), .some(r)):
        if let l = l as? any Equatable {
            return l.isEqual(toAny: r)
        }
        return (l as AnyObject) === (r as AnyObject)
    default:
        return false
    }
}

// MARK: - Candidate B: `type(of:)`-guarded existential opening

//
// Two values of different dynamic type can never compare `==` under `Equatable` (the `as? Self` cast fails) and can
// never be the same object under `AnyObject` identity (a single object can't have two dynamic types). A cheap
// metatype pointer comparison lets us reject the (likely common) "different concrete error type" case before ever
// touching the `Equatable` conformance/witness-table machinery or performing the `AnyObject` bridge cast.

@inline(__always)
private func isEqualTypeGuarded(_ lhs: Error?, _ rhs: Error?) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none):
        return true
    case let (.some(l), .some(r)):
        guard type(of: l) == type(of: r) else { return false }
        if let l = l as? any Equatable {
            return l.isEqual(toAny: r)
        }
        return (l as AnyObject) === (r as AnyObject)
    default:
        return false
    }
}

@inline(__always)
private func isEqualPartialTypeCast(_ lhs: Error?, _ rhs: Error?) -> Bool {
    @inline(__always)
    func _isEqualError<E: Error>(_ lhs: E, _ rhs: any Error) -> Bool {
        guard let rhs = rhs as? E else { return false }
        guard let lhs = lhs as? (any Equatable) else {
            return (lhs as AnyObject) === (rhs as AnyObject)
        }
        return _isEqualEquatable(lhs, rhs)
    }

    @inline(__always)
    func _isEqualEquatable<E: Equatable>(_ lhs: E, _ rhs: Any) -> Bool {
        guard let rhs = rhs as? E else {
            assertionFailure("Impossible; we already checked that the rhs has the same type as the lhs")
            return false
        }
        return lhs == rhs
    }

    switch (lhs, rhs) {
    case (.none, .none):
        return true
    case let (.some(l), .some(r)):
        guard type(of: l) == type(of: r) else { return false }
        return _isEqualError(l, r)
    default:
        return false
    }
}

// MARK: - Candidate C: `ObjectIdentifier`-guarded existential opening

//
// A variant of the type-of guard that wraps each metatype in an `ObjectIdentifier` before comparing. Measures
// whether the extra indirection changes anything relative to comparing the metatypes directly.

@inline(__always)
private func isEqualObjectIdentifierGuarded(_ lhs: Error?, _ rhs: Error?) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none):
        return true
    case let (.some(l), .some(r)):
        guard ObjectIdentifier(type(of: l)) == ObjectIdentifier(type(of: r)) else { return false }
        if let l = l as? any Equatable {
            return l.isEqual(toAny: r)
        }
        return (l as AnyObject) === (r as AnyObject)
    default:
        return false
    }
}

// MARK: - Candidate D: type-erased `AnyEquatable` box

//
// A reusable, `Equatable`-conforming type-erasing wrapper (the shape Alamofire itself has historically used
// internally for boxed equatable comparisons), built independently for each side of the comparison and then compared
// via its own `==`. Useful when the erased value needs to be stored (e.g. as a dictionary key, or held across
// multiple comparisons), but each box allocates a closure capturing its value, so building one per comparison is
// expected to cost more than the direct approach above.

private struct AnyEquatableBox: Equatable {
    private let value: Any
    private let equals: (Any) -> Bool

    init<T: Equatable>(_ value: T) {
        self.value = value
        equals = { ($0 as? T).map { value == $0 } ?? false }
    }

    static func ==(lhs: AnyEquatableBox, rhs: AnyEquatableBox) -> Bool {
        guard type(of: lhs.value) == type(of: rhs.value) else { return false }
        return lhs.equals(rhs.value)
    }
}

@inline(__always)
private func makeAnyEquatableBox<T: Equatable>(_ value: T) -> AnyEquatableBox {
    AnyEquatableBox(value)
}

@inline(__always)
private func makeAnyEquatableBox(fromErasedEquatable value: Any) -> AnyEquatableBox? {
    guard let equatable = value as? any Equatable else { return nil }
    return makeAnyEquatableBox(equatable)
}

@inline(__always)
private func isEqualAnyEquatableBox(_ lhs: Error?, _ rhs: Error?) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none):
        return true
    case let (.some(l), .some(r)):
        if let lBox = makeAnyEquatableBox(fromErasedEquatable: l) {
            guard let rBox = makeAnyEquatableBox(fromErasedEquatable: r) else { return false }
            return lBox == rBox
        }
        return (l as AnyObject) === (r as AnyObject)
    default:
        return false
    }
}

// MARK: - Candidate E: `type(of:)`-guarded `AnyEquatable` box

//
// Same box-based approach as Candidate D, but with the same metatype fast-path guard as Candidate B, so a second
// box (and its capturing closure) is never allocated when the two errors don't even share a concrete type.

@inline(__always)
private func isEqualTypeGuardedAnyEquatableBox(_ lhs: Error?, _ rhs: Error?) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none):
        return true
    case let (.some(l), .some(r)):
        guard type(of: l) == type(of: r) else { return false }
        if let lBox = makeAnyEquatableBox(fromErasedEquatable: l) {
            guard let rBox = makeAnyEquatableBox(fromErasedEquatable: r) else { return false }
            return lBox == rBox
        }
        return (l as AnyObject) === (r as AnyObject)
    default:
        return false
    }
}

// MARK: - Candidates

//
// Excluded on purpose: a `String(reflecting:)`/`Mirror`-based "structural" comparison. It happens to pass a few of
// the test cases below by coincidence (synthesized descriptions embed stored property values), but it is not a
// correct implementation of the requested semantics: it would report two `NonEquatableTestError`s with matching
// `message`s as equal, violating the "no reliable signal, so always `false`" contract for non-`Equatable` value
// types. Since it fails the correctness matrix outright, it's not a real candidate and isn't benchmarked.

private let candidates: [(name: String, fn: @Sendable (Error?, Error?) -> Bool)] = [
    ("Direct (`as? any Equatable`)", isEqualDirect),
    ("Type-guarded", isEqualTypeGuarded),
    ("Partial type-cast", isEqualPartialTypeCast),
    ("ObjectIdentifier-guarded", isEqualObjectIdentifierGuarded),
    ("AnyEquatable box", isEqualAnyEquatableBox),
    ("Type-guarded AnyEquatable box", isEqualTypeGuardedAnyEquatableBox),
]

// MARK: - Correctness matrix

//
// Every branch of the intended algorithm, exercised against every candidate before any benchmark runs, so a broken
// candidate fails loudly instead of quietly reporting bogus "fastest" numbers.

private let sameClassInstance = NonEquatableClassError(code: 42)

private let correctnessMatrix: [(name: String, lhs: Error?, rhs: Error?, expected: Bool)] = [
    ("equatable struct, equal",
     EquatableTestError(code: 1), EquatableTestError(code: 1), true),
    ("equatable struct, unequal value",
     EquatableTestError(code: 1), EquatableTestError(code: 2), false),
    ("equatable struct, same value, different nominal type",
     EquatableTestError(code: 1), OtherEquatableTestError(code: 1), false),
    ("equatable enum, equal (.first)",
     EquatableEnumError.first(1), EquatableEnumError.first(1), true),
    ("equatable enum, unequal associated value (.first)",
     EquatableEnumError.first(1), EquatableEnumError.first(2), false),
    ("equatable enum, equal (.second)",
     EquatableEnumError.second("a"), EquatableEnumError.second("a"), true),
    ("equatable enum, different case",
     EquatableEnumError.first(1), EquatableEnumError.second("a"), false),
    ("non-equatable struct, matching content",
     NonEquatableTestError(message: "x"), NonEquatableTestError(message: "x"), false),
    ("non-equatable enum, matching case and value",
     NonEquatableTestErrorEnum.first(1), NonEquatableTestErrorEnum.first(1), false),
    ("non-equatable enum, different case",
     NonEquatableTestErrorEnum.first(1), NonEquatableTestErrorEnum.second(1), false),
    ("non-equatable class, same instance",
     sameClassInstance, sameClassInstance, true),
    ("non-equatable class, different instances, matching content",
     NonEquatableClassError(code: 42), NonEquatableClassError(code: 42), false),
    ("equatable struct vs non-equatable class",
     EquatableTestError(code: 1), NonEquatableClassError(code: 1), false),
    ("non-equatable class vs non-equatable struct",
     NonEquatableClassError(code: 1), NonEquatableTestError(message: "x"), false),
    ("nil vs nil",
     nil, nil, true),
    ("nil vs some",
     nil, EquatableTestError(code: 1), false),
    ("some vs nil",
     EquatableTestError(code: 1), nil, false),
]

private func verifyCandidatesAgree() {
    for candidate in candidates {
        for testCase in correctnessMatrix {
            let actual = candidate.fn(testCase.lhs, testCase.rhs)
            precondition(actual == testCase.expected,
                         "\(candidate.name) failed case '\(testCase.name)': expected \(testCase.expected), got \(actual)")
        }
    }
}

// MARK: - Benchmark workloads

//
// Beyond the blended, realistic mix of comparisons, isolate the scenarios most likely to differ between candidates:
// repeated same-type `Equatable` comparisons (favors the unguarded direct approach, since the guard is pure
// overhead when types always match), repeated different-type comparisons (favors the guarded approaches, since they
// skip the `Equatable`/box machinery entirely), and class reference-identity comparisons (exercises the `AnyObject`
// fallback path exclusively).

private let mixedWorkload: [(Error?, Error?)] = correctnessMatrix.map { ($0.lhs, $0.rhs) }

private let sameTypeEquatableWorkload: [(Error?, Error?)] = [
    (EquatableTestError(code: 1), EquatableTestError(code: 1)),
    (EquatableTestError(code: 1), EquatableTestError(code: 2)),
    (EquatableEnumError.first(1), EquatableEnumError.first(1)),
    (EquatableEnumError.second("a"), EquatableEnumError.second("b")),
    (EquatableEnumError.first(1), EquatableEnumError.second("a")),
]

private let differentTypeWorkload: [(Error?, Error?)] = [
    (EquatableTestError(code: 1), OtherEquatableTestError(code: 1)),
    (EquatableTestError(code: 1), NonEquatableClassError(code: 1)),
    (NonEquatableClassError(code: 1), NonEquatableTestError(message: "x")),
    (NonEquatableTestError(message: "x"), NonEquatableTestErrorEnum.first(1)),
]

private let classIdentityWorkload: [(Error?, Error?)] = [
    (sameClassInstance, sameClassInstance),
    (NonEquatableClassError(code: 42), NonEquatableClassError(code: 42)),
]

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = {
    verifyCandidatesAgree()

    let config = Benchmark.Configuration(
        metrics: [.cpuTotal, .wallClock, .mallocCountTotal, .throughput],
        scalingFactor: .kilo,
        maxDuration: .seconds(3),
        maxIterations: 1_000_000,
        thresholds: [.throughput: .relaxed, .wallClock: .relaxed]
    )

    func register(_ scenarioName: String, _ workload: [(Error?, Error?)]) {
        for candidate in candidates {
            Benchmark("\(scenarioName) — \(candidate.name)", configuration: config) { benchmark in
                for _ in benchmark.scaledIterations {
                    for pair in workload {
                        blackHole(candidate.fn(pair.0, pair.1))
                    }
                }
            }
        }
    }

    register("Mixed", mixedWorkload)
    register("Same-type Equatable", sameTypeEquatableWorkload)
    register("Different-type", differentTypeWorkload)
    register("Class identity", classIdentityWorkload)
}
