import Builtin

// Thin wrappers over compiler builtins, for hints the standard library doesn't expose publicly.
// Each one is checked against the generated assembly and the benchmarks; see Benchmarks/RESULTS.md.

/// Tells the optimizer `condition` is almost always true (branch weight), keeping the slow path out of line.
@usableFromInline @_transparent
func likely(_ condition: Bool) -> Bool {
    Bool(Builtin.int_expect_Int1(condition._value, true._value))
}

/// Tells the optimizer `condition` is almost always false.
@usableFromInline @_transparent
func unlikely(_ condition: Bool) -> Bool {
    Bool(Builtin.int_expect_Int1(condition._value, false._value))
}

/// Tells the optimizer `condition` holds, so it can drop checks and masks that would only matter otherwise.
/// Unchecked: if `condition` is false, behavior is undefined. Use only for invariants the type maintains.
@unsafe @usableFromInline @_transparent
func assume(_ condition: Bool) {
    _ = Builtin.assume_Int1(condition._value)
}
