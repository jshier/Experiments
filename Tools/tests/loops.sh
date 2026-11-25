#!/bin/bash
# Tools/loops on hand-written ARM64 functions whose loops are known: a cold block laid out after the return (one
# loop holding the call), two latches (one loop), a header at the function's first instruction, tail calls (no
# loops), a 128-bit loop, a `switch` through a jump table inside a loop, and a nested pair.
here="$(cd "$(dirname "$0")" && pwd)"
loops="$here/../loops"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-loops.XXXXXX")"
trap 'rm -rf "$work"' EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }

cat > "$work/cases.s" <<'EOF'
    .text
    .p2align 2

// One loop; its rare path (a call) is laid out after the return, as LLVM places cold blocks. The call is in the loop.
    .globl _cold_call2
_cold_call2:
    mov x1, #0
Lcc_head:
    ldr x2, [x0], #8
    cbz x2, Lcc_cold
Lcc_cont:
    add x1, x1, x2
    subs x3, x3, #1
    b.ne Lcc_head
    mov x0, x1
    ret
Lcc_cold:
    bl _external_helper
    b Lcc_cont

// One loop with two latches (`continue`): one loop holding the add and eor, not two nested ones.
    .globl _two_latches2
_two_latches2:
    mov x1, #0
Ltl_head:
    ldr x2, [x0], #8
    subs x3, x3, #1
    cbz x2, Ltl_head
    add x1, x1, x2
    eor x1, x1, x2
    b.ne Ltl_head
    mov x0, x1
    ret

// A loop whose header is the function's first instruction.
    .globl _entry_header
_entry_header:
    ldr x2, [x0], #8
    add x1, x1, x2
    subs x3, x3, #1
    b.ne _entry_header
    mov x0, x1
    ret

// A 128-bit loop: q loads, pmull (.1q arrangement), eor.16b.
    .globl _pmull_loop2
_pmull_loop2:
    movi v0.16b, #0
Lpm_head:
    ldr q1, [x0], #16
    pmull v2.1q, v0.1d, v1.1d
    pmull2 v3.1q, v0.2d, v1.2d
    eor v0.16b, v2.16b, v3.16b
    subs x1, x1, #1
    b.ne Lpm_head
    ret

// A loop with a tail call out of its middle: the tail call is no loop of its own.
    .globl _tail_exit
_tail_exit:
    mov x1, #0
Lte_head:
    ldr q1, [x0], #16
    add v0.16b, v0.16b, v1.16b
    cbz x2, Lte_out
    subs x3, x3, #1
    b.ne Lte_head
    ret
Lte_out:
    b _external_helper

// Nothing but tail calls.
    .globl _tail_only
_tail_only:
    cbz x0, Lto_other
    b _external_helper
Lto_other:
    b _other_helper

// A switch through a jump table inside a loop, laid out as LLVM does: the table's anchor (its lowest case) before the
// header, the cases after the `br`. Every case is in the loop.
    .globl _switch_loop
_switch_loop:
    mov x1, #0
    adrp x10, Ljt@PAGE
    add x10, x10, Ljt@PAGEOFF
    b Lsw_head
Lsw_case0:
    add x1, x1, #3
Lsw_latch:
    subs x8, x8, #1
    b.eq Lsw_done
Lsw_head:
    ldrb w12, [x9], #1
    cmp w12, #2
    b.hi Lsw_default
    adr x13, Lsw_case0
    ldrb w14, [x10, x12]
    add x13, x13, x14, lsl #2
    br x13
Lsw_case1:
    eor x1, x1, x2
    b Lsw_latch
Lsw_case2:
    mul x1, x1, x2
    b Lsw_latch
Lsw_default:
    add x1, x1, #1
    b Lsw_latch
Lsw_done:
    mov x0, x1
    ret

// Two nested loops.
    .globl _nested
_nested:
    mov x4, #0
Lne_outer:
    mov x5, #0
Lne_inner:
    add x4, x4, x5
    add x5, x5, #1
    cmp x5, x1
    b.lo Lne_inner
    subs x0, x0, #1
    b.ne Lne_outer
    mov x0, x4
    ret

// Irreducible: a cycle A <-> B entered at both A (fall-through) and B (the cbz). Neither dominates the other.
    .globl _irreducible
_irreducible:
    cbz x0, Lir_b
Lir_a:
    add x1, x1, #1
    subs x2, x2, #1
    b.eq Lir_done
Lir_b:
    eor x1, x1, x2
    subs x3, x3, #1
    b.ne Lir_a
Lir_done:
    mov x0, x1
    ret

// One-instruction loops: a cbnz to itself and `b .` (no relocation: they don't leave the function).
    .globl _spin
_spin:
    cbz x0, Lsp_forever
Lsp_wait:
    cbnz x1, Lsp_wait
    ret
Lsp_forever:
    b Lsp_forever

// Two loops, each with a switch through an adr-anchored byte table; loop 1's second case is laid out at the end,
// after loop 2's anchor, so placing cases by position would give it to loop 2.
    .globl _two_tables
_two_tables:
    adrp x10, Ljt1@PAGE
    add x10, x10, Ljt1@PAGEOFF
    adrp x11, Ljt2@PAGE
    add x11, x11, Ljt2@PAGEOFF
L1_head:
    ldrb w12, [x9], #1
    cmp w12, #1
    b.hi L1_latch
    adr x13, L1_case0
    ldrb w14, [x10, x12]
    add x13, x13, x14, lsl #2
    br x13
L1_case0:
    add x1, x1, #3
L1_latch:
    subs x8, x8, #1
    b.ne L1_head
L2_head:
    ldrb w12, [x9], #1
    cmp w12, #1
    b.hi L2_latch
    adr x13, L2_case0
    ldrb w14, [x11, x12]
    add x13, x13, x14, lsl #2
    br x13
L2_case0:
    add x2, x2, #5
L2_latch:
    subs x7, x7, #1
    b.ne L2_head
    ret
L1_case1:
    eor x1, x1, x2
    b L1_latch
L2_case1:
    mul x2, x2, x3
    b L2_latch

// Two loops, each with a switch through a 32-bit table relative to itself (no anchor; in an object its entries are
// relocations); the first loop's cases come last.
    .globl _two_wide_tables
_two_wide_tables:
    adrp x10, Lwjt1@PAGE
    add x10, x10, Lwjt1@PAGEOFF
    adrp x11, Lwjt2@PAGE
    add x11, x11, Lwjt2@PAGEOFF
LW1_head:
    ldrb w12, [x9], #1
    cmp w12, #1
    b.hi LW1_latch
    ldrsw x13, [x10, x12, lsl #2]
    add x13, x10, x13
    br x13
LW1_latch:
    subs x8, x8, #1
    b.ne LW1_head
LW2_head:
    ldrb w12, [x9], #1
    cmp w12, #1
    b.hi LW2_latch
    ldrsw x13, [x11, x12, lsl #2]
    add x13, x11, x13
    br x13
LW2_case0:
    add x2, x2, #5
    b LW2_latch
LW2_case1:
    mul x2, x2, x3
LW2_latch:
    subs x7, x7, #1
    b.ne LW2_head
    ret
LW1_case0:
    add x1, x1, #3
    b LW1_latch
LW1_case1:
    eor x1, x1, x2
    b LW1_latch

// An irreducible cycle A <-> B inside a natural loop: two loops, the irreducible one at depth 1.
    .globl _irr_in_natural
_irr_in_natural:
Lin_outer:
    ldr x5, [x6], #8
    cbz x5, Lin_b
Lin_a:
    add x1, x1, #1
    subs x2, x2, #1
    b.eq Lin_latch
Lin_b:
    eor x1, x1, x2
    subs x3, x3, #1
    b.ne Lin_a
Lin_latch:
    subs x4, x4, #1
    b.ne Lin_outer
    ret

// An irreducible cycle inside an irreducible cycle: {A, B, C, D} entered at A and B; without them, {C, D} entered at
// C (from A) and D (from B).
    .globl _irr_in_irr
_irr_in_irr:
    cbz x0, Lii_b
Lii_a:
    add x1, x1, #1
    b Lii_c
Lii_b:
    add x1, x1, #2
    b Lii_d
Lii_c:
    eor x1, x1, x2
    subs x2, x2, #1
    b.eq Lii_b
Lii_d:
    eor x1, x1, x3
    subs x3, x3, #1
    b.eq Lii_out
    subs x4, x4, #1
    b.eq Lii_a
    b Lii_c
Lii_out:
    ret

// A refill block before a natural loop's header, entered from the loop and from before it (BZip2's shape): the natural
// loop, unchanged, and around it the cycle with the refill, as a natural+side-entry loop (not irreducible).
    .globl _refill
_refill:
    cmp x22, #0x2f
    b.gt Lrf_head
Lrf_refill:
    ldr x5, [x3], #8
    orr x22, x22, #0x38
Lrf_head:
    lsr x8, x5, #1
    sub x22, x22, #1
    cmp x22, #8
    b.le Lrf_refill
    subs x4, x4, #1
    b.ne Lrf_head
    ret

// A refill path of three blocks, entered from before the loop only at its first: the text names that block alone.
    .globl _refill2
_refill2:
    cmp x22, #0x2f
    b.gt Lr2_head
Lr2_refill:
    ldr x5, [x3], #8
    cbz x5, Lr2_skip
    orr x22, x22, #0x38
Lr2_skip:
    add x22, x22, #1
Lr2_head:
    lsr x8, x5, #1
    sub x22, x22, #1
    cmp x22, #8
    b.le Lr2_refill
    subs x4, x4, #1
    b.ne Lr2_head
    ret

// A table bounded by `cmp #2; b.hs` (2 entries); the byte after it, read as a third, would name the loop body below
// and make the loop look irreducible.
    .globl _hs_bound
_hs_bound:
    ldrb w13, [x0]
    cmp w13, #2
    b.hs Lhs_out
    adrp x14, Lhst@PAGE
    add x14, x14, Lhst@PAGEOFF
    adr x15, Lh0
    ldrb w16, [x14, x13]
    add x15, x15, x16, lsl #2
    br x15
Lh0:
    add x1, x1, #3
    ret
Lh1:
    eor x1, x1, x2
    ret
Lhl_head:
    ldr x2, [x3], #8
Lhl_body:
    add x1, x1, x2
    subs x4, x4, #1
    b.ne Lhl_head
    ret
Lhs_out:
    b Lhl_head

// An exhaustive switch (no bounds check) after a stale `cmp` of the same register, with a join point between: the cmp
// doesn't bound it; the index's width and the next table (Lpt, referred to by _position) do: four entries, the last
// naming the loop's body (a case entering the loop mid-body).
    .globl _stale
_stale:
    cmp w13, #3
    b.hi Lst_skip
    add x1, x1, #1
Lst_skip:
    ldrb w13, [x0]
    adrp x14, Ltab@PAGE
    add x14, x14, Ltab@PAGEOFF
    adr x15, Lc0
    ldrb w16, [x14, x13]
    add x15, x15, x16, lsl #2
    br x15
Lc0:
    add x1, x1, #3
    ret
Lc1:
    eor x1, x1, x2
    ret
Lloop_head:
    ldr x2, [x3], #8
Lloop_body:
    add x1, x1, x2
    subs x4, x4, #1
    b.ne Lloop_head
    ret
Lc2:
    mul x1, x1, x2
    b Lloop_head

// An exhaustive switch placed by position (its table's address comes from memory), a loop body laid out before its
// header: the body isn't taken for a case.
    .globl _position
_position:
    ldrb w13, [x0]
    ldr x14, [x5]
    adrp x6, Lpt@PAGE
    add x6, x6, Lpt@PAGEOFF
    adr x15, Lp0
    ldrb w16, [x14, x13]
    add x15, x15, x16, lsl #2
    br x15
Lp0:
    add x1, x1, #3
    ret
Lp_body:
    add x1, x1, x2
Lp_head:
    ldr x2, [x3], #8
    subs x4, x4, #1
    b.ne Lp_body
    ret
Lp1:
    mov x4, #8
    b Lp_head

// Two natural loops of equal size joined into one irreducible cycle (entered at Lth_h and Lth_s1): no fold (neither
// holds the other), an irreducible loop holding two natural ones, the same whatever Perl's hash order.
    .globl _two_hosts
_two_hosts:
    cbz x0, Lth_s1
Lth_h:
    ldr x5, [x6], #8
    cbz x5, Lth_s1
Lth_x:
    subs x2, x2, #1
    b.ne Lth_h
    ret
Lth_s1:
    add x1, x1, #1
    cbz x7, Lth_t
Lth_s2:
    subs x3, x3, #1
    b.ne Lth_s1
Lth_t:
    b Lth_h

// Three one-block natural loops in one irreducible cycle (entered at Lsb_a and Lsb_b): no fold.
    .globl _three_siblings
_three_siblings:
    cbz x0, Lsb_b
Lsb_a:
    subs x1, x1, #1
    b.ne Lsb_a
    cbz x5, Lsb_out
Lsb_b:
    subs x2, x2, #1
    b.ne Lsb_b
Lsb_c:
    subs x3, x3, #1
    b.ne Lsb_c
    b Lsb_a
Lsb_out:
    ret

// A table entry added into x8, then x8 overwritten by a pointer load: the br is a tail call, not a switch, and the loop
// after it (reached from nowhere: an extra root) is a natural loop with no warning.
    .globl _last_writer
_last_writer:
    ldrb w9, [x0, x1]
    add x8, x2, x9
    ldr x8, [x8]
    br x8
Llw_body:
    add x1, x1, x2
Llw_head:
    subs x4, x4, #1
    b.ne Llw_body
    ret

// A bounds check that a join point crosses (Ljn_skip is reached without it): the count can't come from it (2 entries);
// the table's extent (the next table) gives 3, the third naming the loop's body.
    .globl _join
_join:
    ldrb w13, [x0]
    cbz x5, Ljn_skip
    cmp w13, #1
    b.hi Ljn_out
Ljn_skip:
    adrp x14, Ljn_tab@PAGE
    add x14, x14, Ljn_tab@PAGEOFF
    adr x15, Ljn0
    ldrb w16, [x14, x13]
    add x15, x15, x16, lsl #2
    br x15
Ljn0:
    add x1, x1, #3
    ret
Ljn1:
    eor x1, x1, x2
    ret
Ljn_head:
    ldr x2, [x3], #8
Ljn_body:
    add x1, x1, x2
    subs x4, x4, #1
    b.ne Ljn_head
    ret
Ljn_out:
    b Ljn_head

// A bounds check for 3 entries over a table of 2 (lJTI9_0, up to the next symbol, lJTI9_1, whose byte would name the
// loop's body): the extent caps the count, with a warning.
    .globl _extent_cap
_extent_cap:
    ldrb w13, [x0]
    cmp w13, #2
    b.hi Lex_out
    adrp x14, lJTI9_0@PAGE
    add x14, x14, lJTI9_0@PAGEOFF
    adr x15, Lex0
    ldrb w16, [x14, x13]
    add x15, x15, x16, lsl #2
    br x15
Lex0:
    add x1, x1, #3
    ret
Lex1:
    eor x1, x1, x2
    ret
Lex_head:
    ldr x2, [x3], #8
Lex_body:
    add x1, x1, x2
    subs x4, x4, #1
    b.ne Lex_head
    ret
Lex_out:
    b Lex_head

// A switch on a 2-bit tag (`lsr` of a byte by 6) with no bounds check, as Swift's exhaustive switches are: the index's
// width bounds the table (4 entries at most), which ends before its fourth byte (0xff lands outside the function).
    .globl _tag_switch
_tag_switch:
    adrp x10, Ltag@PAGE
    add x10, x10, Ltag@PAGEOFF
Ltg_head:
    ldrb w9, [x0], #1
    lsr w9, w9, #6
    adr x13, Ltg0
    ldrb w14, [x10, x9]
    add x13, x13, x14, lsl #2
    br x13
Ltg0:
    add x1, x1, #3
    b Ltg_latch
Ltg1:
    eor x1, x1, x2
    b Ltg_latch
Ltg2:
    mul x1, x1, x2
Ltg_latch:
    subs x8, x8, #1
    b.ne Ltg_head
    ret

// A path that jumps straight to the table load (Ljl_load), past the bounds check: the check can't give the count (2
// entries; the extent gives 3).
    .globl _join_load
_join_load:
    ldrb w13, [x0]
    adrp x14, Ljl_tab@PAGE
    add x14, x14, Ljl_tab@PAGEOFF
    cbz x5, Ljl_load
    cmp w13, #1
    b.hi Ljl_out
Ljl_load:
    ldrb w16, [x14, x13]
    adr x15, Ljl0
    add x15, x15, x16, lsl #2
    br x15
Ljl0:
    add x1, x1, #3
    ret
Ljl1:
    eor x1, x1, x2
    ret
Ljl_head:
    ldr x2, [x3], #8
Ljl_body:
    add x1, x1, x2
    subs x4, x4, #1
    b.ne Ljl_head
    ret
Ljl_out:
    b Ljl_head

// A path that jumps to the bounds check's b.hi, past its cmp (with another compare's flags).
    .globl _join_bhi
_join_bhi:
    ldrb w13, [x0]
    cmp w13, #7
    cbz x5, Ljh_bhi
    cmp w13, #1
Ljh_bhi:
    b.hi Ljh_out
    adrp x14, Ljh_tab@PAGE
    add x14, x14, Ljh_tab@PAGEOFF
    adr x15, Ljh0
    ldrb w16, [x14, x13]
    add x15, x15, x16, lsl #2
    br x15
Ljh0:
    add x1, x1, #3
    ret
Ljh1:
    eor x1, x1, x2
    ret
Ljh_head:
    ldr x2, [x3], #8
Ljh_body:
    add x1, x1, x2
    subs x4, x4, #1
    b.ne Ljh_head
    ret
Ljh_out:
    b Ljh_head

// A bounded table one of whose entries lands outside the function: not read (placed by position, with a warning).
    .globl _outside
_outside:
    ldrb w13, [x0]
    cmp w13, #1
    b.hi Lou_out
    adrp x14, Lou_tab@PAGE
    add x14, x14, Lou_tab@PAGEOFF
    adr x15, Lou0
    ldrb w16, [x14, x13]
    add x15, x15, x16, lsl #2
    br x15
Lou0:
    add x1, x1, #3
    ret
Lou_out:
    ret

// A natural loop (Lsc_h) and side blocks that form a cycle of their own (P <-> Q, entered at both, so no natural loop):
// no fold; an irreducible loop holding the natural one.
    .globl _side_cycle
_side_cycle:
    cbz x0, Lsc_p
Lsc_h:
    ldr x5, [x6], #8
    cbz x5, Lsc_p
    cbnz x7, Lsc_q
    subs x4, x4, #1
    b.ne Lsc_h
    ret
Lsc_p:
    subs x2, x2, #1
    b.eq Lsc_h
Lsc_q:
    subs x3, x3, #1
    b.ne Lsc_p
    b Lsc_h

// A refill fold whose host (the outer loop, Lfn_head) holds an inner loop laid out before it (a lower header): the
// host is the largest loop, not the lowest header, so the fold holds.
    .globl _fold_nested
_fold_nested:
    cmp x22, #0x2f
    b.gt Lfn_head
Lfn_refill:
    ldr x5, [x3], #8
    b Lfn_head
Lfn_inner:
    sub x9, x9, #1
    cbnz x9, Lfn_inner
    b Lfn_cont
Lfn_head:
    lsr x8, x5, #1
    mov x9, #4
    b Lfn_inner
Lfn_cont:
    sub x22, x22, #1
    cmp x22, #8
    b.le Lfn_refill
    subs x4, x4, #1
    b.ne Lfn_head
    ret

    .section __TEXT,__const
lJTI9_0:
    .byte 0
    .byte (Lex1 - Lex0) >> 2
lJTI9_1:
    .byte (Lex_body - Lex0) >> 2
Ljl_tab:
    .byte 0
    .byte (Ljl1 - Ljl0) >> 2
    .byte (Ljl_body - Ljl0) >> 2
Ljh_tab:
    .byte 0
    .byte (Ljh1 - Ljh0) >> 2
    .byte (Ljh_body - Ljh0) >> 2
Lou_tab:
    .byte 0
    .byte 0xff
Ltag:
    .byte 0
    .byte (Ltg1 - Ltg0) >> 2
    .byte (Ltg2 - Ltg0) >> 2
    .byte 0xff
Ljn_tab:
    .byte 0
    .byte (Ljn1 - Ljn0) >> 2
    .byte (Ljn_body - Ljn0) >> 2
Lhst:
    .byte 0
    .byte (Lh1 - Lh0) >> 2
    .byte (Lhl_body - Lh0) >> 2
Ltab:
    .byte 0
    .byte (Lc1 - Lc0) >> 2
    .byte (Lc2 - Lc0) >> 2
    .byte (Lloop_body - Lc0) >> 2
Lpt:
    .byte 0
    .byte (Lp1 - Lp0) >> 2
Ljt:
    .byte 0
    .byte (Lsw_case1 - Lsw_case0) >> 2
    .byte (Lsw_case2 - Lsw_case0) >> 2
Ljt1:
    .byte 0
    .byte (L1_case1 - L1_case0) >> 2
Ljt2:
    .byte 0
    .byte (L2_case1 - L2_case0) >> 2
    .p2align 2
Lwjt1:
    .long LW1_case0 - Lwjt1
    .long LW1_case1 - Lwjt1
Lwjt2:
    .long LW2_case0 - Lwjt2
    .long LW2_case1 - Lwjt2
EOF
xcrun clang -c -arch arm64 -o "$work/cases.o" "$work/cases.s" || { echo "FAIL: couldn't assemble the cases"; exit 1; }

# Each function's --tsv, made once (every case's) and kept by name.
"$loops" "$work/cases.o" '^_' --tsv > "$work/all.tsv" 2> /dev/null
tsv() { perl -F'\t' -ane 'BEGIN { $want = shift } print if $F[0] eq $want' "$1" "$work/all.tsv"; }
count() { tsv "$1" | grep -c .; }
column() { tsv "$1" | cut -f "$2" | tr '\n' ' ' | sed 's/ $//'; }

check "cold call: one loop" "$(count _cold_call2)" 1
check "cold call: the call is in the loop" "$(column _cold_call2 8)" scalar+calls
check "cold call: two pieces" "$(column _cold_call2 11)" "4-14,20-24"
"$loops" "$work/cases.o" '^_cold_call2$' --forbid bl > /dev/null 2>&1
check "cold call: --forbid bl fails" "$?" 1
"$loops" "$work/cases.o" '^_cold_call2$' --body > "$work/body" 2> /dev/null
grep -q '… 0x18–0x1c: 2 instructions not in this loop' "$work/body"
check "cold call: --body marks the gap" "$?" 0

check "two latches: one loop" "$(count _two_latches2)" 1
"$loops" "$work/cases.o" '^_two_latches2$' --require eor > /dev/null 2>&1
check "two latches: --require eor passes" "$?" 0

check "header at the entry: one loop" "$(count _entry_header)" 1
check "header at the entry: starts at the function" "$(column _entry_header 3) $(column _entry_header 10)" "$(xcrun nm "$work/cases.o" | perl -ne 'print "$1 $1" if /^0*([0-9a-f]+?) T _entry_header$/')"

check "tail calls: none is a loop" "$(tsv _tail_only)" ""
"$loops" "$work/cases.o" '^_tail_only$' 2> /dev/null | grep -q 'no loops'
check "tail calls: 'no loops'" "$?" 0
check "tail exit: one loop of 5 instructions" "$(count _tail_exit) $(column _tail_exit 5)" "1 5"

check "128-bit loop: verdict" "$(column _pmull_loop2 8)" vector128

check "switch: one loop" "$(count _switch_loop)" 1
"$loops" "$work/cases.o" '^_switch_loop$' --require eor,mul,ldrb --forbid ret > /dev/null 2>&1
check "switch: every case in the loop" "$?" 0

check "nested: two loops" "$(count _nested)" 2
check "nested: depths" "$(column _nested 6)" "0 1"
check "nested: outer, innermost" "$(column _nested 7)" "outer innermost"

check "irreducible: one loop" "$(count _irreducible)" 1
check "irreducible: marked, two entries" "$(column _irreducible 12) $(column _irreducible 10 | tr -cd , | wc -c | tr -d ' ')" "irreducible 1"
"$loops" "$work/cases.o" '^_irreducible$' --require eor > /dev/null 2>&1
check "irreducible: --require sees it" "$?" 0
check "natural loops: marked natural" "$(column _nested 12)" "natural natural"

check "spin: two one-instruction loops" "$(column _spin 5)" "1 1"

check "two tables: two loops" "$(count _two_tables)" 2
check "two tables: each loop its own cases" "$(tsv _two_tables | perl -F'\t' -ane 'print $F[8] =~ /eor/ ? "eor" : "", $F[8] =~ /mul/ ? "mul" : "", " "')" "eor mul "
"$loops" "$work/cases.o" '^_two_tables$' > /dev/null 2> "$work/err"
check "two tables: read, no warning" "$(cat "$work/err")" ""
check "wide tables: two loops" "$(count _two_wide_tables)" 2
check "wide tables: each loop its own cases" "$(tsv _two_wide_tables | perl -F'\t' -ane 'print $F[8] =~ /eor/ ? "eor" : "", $F[8] =~ /mul/ ? "mul" : "", " "')" "eor mul "
"$loops" "$work/cases.o" '^_two_wide_tables$' > /dev/null 2> "$work/err"
check "wide tables: read, no warning" "$(cat "$work/err")" ""

check "irreducible in natural: depths and kinds" "$(column _irr_in_natural 6) / $(column _irr_in_natural 12)" "0 1 / natural irreducible"
check "irreducible in natural: the outer loop" "$(tsv _irr_in_natural | head -1 | cut -f3,4,5)" "$(printf '%s\t%s\t%s' "$(xcrun nm "$work/cases.o" | perl -ne 'print $1 if /^0*([0-9a-f]+?) T _irr_in_natural$/')" "$(xcrun nm "$work/cases.o" | perl -ne 'printf "%x", hex($1) + 0x24 if /^([0-9a-f]+) T _irr_in_natural$/')" 10)"
check "irreducible in irreducible: depths and kinds" "$(column _irr_in_irr 6) / $(column _irr_in_irr 12)" "0 1 / irreducible irreducible"
check "refill: the natural loop, and the cycle with its refill around it" "$(count _refill) $(column _refill 12) / $(column _refill 5) / $(column _refill 7)" "2 natural+side-entry natural / 8 6 / outer innermost"
check "refill of three blocks: entered only at its first, said" "$("$loops" "$work/cases.o" '^_refill2$' 2> /dev/null | grep -c '; also entered at 0x[0-9a-f]* (a side path')" 1
check "b.hs bound: one natural loop" "$(count _hs_bound) $(column _hs_bound 12) $(column _hs_bound 5)" "1 natural 4"
"$loops" "$work/cases.o" '^_hs_bound$' > /dev/null 2> "$work/err"
check "b.hs bound: read, no warning" "$(cat "$work/err")" ""
check "stale cmp: the table read to the next one, its last entry the loop's body: an irreducible loop" "$(count _stale) $(column _stale 12) $(column _stale 5)" "1 irreducible 4"
"$loops" "$work/cases.o" '^_stale$' > /dev/null 2> "$work/err"
check "stale cmp: bounded by the index's width instead, no warning" "$(cat "$work/err")" ""
check "by position: one natural loop" "$(count _position) $(column _position 12) $(column _position 5)" "1 natural 4"

check "two hosts: an irreducible loop holding two natural ones" "$(column _two_hosts 12) / $(column _two_hosts 6)" "irreducible natural natural / 0 1 1"
hashes=""
for seed in 1 2 3 4; do
    hashes="$hashes $(PERL_HASH_SEED=$seed "$loops" "$work/cases.o" '^_(two_hosts|three_siblings|irr_in_irr|refill|switch_loop)$' --tsv 2>&1 | shasum | cut -c1-12)"
done
check "the same output under four hash seeds" "$(echo "$hashes" | tr ' ' '\n' | grep -c . | tr -d ' ') $(echo "$hashes" | tr ' ' '\n' | grep . | sort -u | grep -c .)" "4 1"
check "three siblings: an irreducible loop holding three natural ones" "$(column _three_siblings 12) / $(column _three_siblings 6)" "irreducible natural natural natural / 0 1 1 1"
check "last writer: one natural loop" "$(count _last_writer) $(column _last_writer 12)" "1 natural"
"$loops" "$work/cases.o" '^_last_writer$' > /dev/null 2> "$work/err"
check "last writer: no table, no warning" "$(cat "$work/err")" ""
check "tag switch: one natural loop with every case" "$(count _tag_switch) $(column _tag_switch 12) $(tsv _tag_switch | cut -f9 | grep -c 'eor.*mul\|mul.*eor')" "1 natural 1"
"$loops" "$work/cases.o" '^_tag_switch$' > /dev/null 2> "$work/err"
check "tag switch: read, no warning" "$(cat "$work/err")" ""
check "a jump to the load: the table read to its extent, not the check's 2 entries (its third enters the loop)" "$(count _join_load) $(column _join_load 12) $(column _join_load 5)" "1 irreducible 4"
check "a jump to the b.hi: the table read to its extent, not the check's 2 entries" "$(count _join_bhi) $(column _join_bhi 12) $(column _join_bhi 5)" "1 irreducible 4"
"$loops" "$work/cases.o" '^_outside$' > /dev/null 2> "$work/err"
check "an entry outside the function: not read" "$(grep -c 'an entry lands outside the function' "$work/err")" 1
check "a side cycle: no fold" "$(column _side_cycle 12)" "irreducible natural"
check "a nested host: named for the outer loop" "$(column _fold_nested 12) / $(column _fold_nested 6) / $(tsv _fold_nested | perl -F'\t' -ane '$h[$.] = $F[9]; END { print $h[1] eq $h[2] ? "same header" : "other headers" }')" \
    "natural+side-entry natural natural / 0 1 2 / same header"
check "join point: the table read to its extent, not the check's 2 entries" "$(count _join) $(column _join 12) $(column _join 5)" "1 irreducible 4"
check "extent cap: one natural loop" "$(count _extent_cap) $(column _extent_cap 12) $(column _extent_cap 5)" "1 natural 4"
"$loops" "$work/cases.o" '^_extent_cap$' > /dev/null 2> "$work/err"
check "extent cap: warned" "$(grep -c 'its bounds check says 3 entries, its extent 2' "$work/err")" 1

"$loops" "$work/cases.o" '^_nested$' --require > /dev/null 2>&1
check "--require without a value" "$?" 2
LOOPS_JOBS=abc "$loops" "$work/cases.o" '^_nested$' > /dev/null 2>&1
check "LOOPS_JOBS=abc" "$?" 2

# A loop past 1 MiB (as in any large merged object).
printf '    .text\n    .p2align 2\n    .globl _pad\n_pad:\n    ret\n    .space 0x110000\n    .globl _far\n_far:\n    ldr x2, [x0], #8\n    tbz x2, #3, Lfar_skip\n    eor x1, x1, x2\nLfar_skip:\n    subs x3, x3, #1\n    b.ne _far\n    ret\n' > "$work/far.s"
xcrun clang -c -arch arm64 -o "$work/far.o" "$work/far.s" || { echo "FAIL: couldn't assemble far.s"; exit 1; }
check "far: one loop of 5 instructions" "$("$loops" "$work/far.o" '^_far$' --tsv 2> /dev/null | cut -f5)" 5

# A linked binary: addresses above 0x100000000, calls through stubs.
cat > "$work/linked.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
__attribute__((noinline)) long sum_print(const long *p, long n) {
    long s = 0;
    for (long i = 0; i < n; i++) {
        s += p[i];
        if (__builtin_expect(p[i] == 42, 0)) puts("forty-two");
    }
    return s;
}
__attribute__((noinline)) void scale(float *restrict out, const float *restrict in, long n) {
    for (long i = 0; i < n; i++) out[i] = in[i] * 3.0f + 1.0f;
}
int main(int argc, char **argv) {
    long a[64];
    float f[64], g[64];
    for (int i = 0; i < 64; i++) { a[i] = i * argc; g[i] = (float)i; }
    scale(f, g, 64);
    return (int)sum_print(a, argc * 16) + (int)f[3];
}
EOF
xcrun clang -O2 -o "$work/linked" "$work/linked.c" || { echo "FAIL: couldn't link linked.c"; exit 1; }
"$loops" "$work/linked" '^_(sum_print|scale)$' --tsv > "$work/linked.tsv" 2> "$work/err"
check "linked: no warnings" "$(cat "$work/err")" ""
check "linked: the call's loop" "$(perl -F'\t' -ane 'print "yes" if $F[0] eq "_sum_print" && $F[7] =~ /\+calls/' "$work/linked.tsv")" yes
check "linked: a vector loop" "$(perl -F'\t' -ane 'print "yes" if $F[0] eq "_scale" && $F[7] =~ /^vector128/' "$work/linked.tsv" | cut -c1-3)" yes

# One local name in two merged objects: each copy analyzed on its own.
printf 'static long helper(const long *p, long n) { long s = 0; for (long i = 0; i < n; i++) s ^= p[i] * 3; return s; }\n__attribute__((noinline)) long first(const long *p, long n) { return helper(p, n); }\n' > "$work/a.c"
printf 'static long helper(const long *p, long n) { long s = 1; for (long i = 0; i < n; i++) s += p[i] * 7; return s; }\n__attribute__((noinline)) long second(const long *p, long n) { return helper(p, n); }\n' > "$work/b.c"
xcrun clang -O1 -fno-inline -c -o "$work/a.o" "$work/a.c" || exit 1
xcrun clang -O1 -fno-inline -c -o "$work/b.o" "$work/b.c" || exit 1
xcrun ld -r -arch arm64 -o "$work/merged.o" "$work/a.o" "$work/b.o" 2> /dev/null || { echo "FAIL: ld -r"; exit 1; }
check "copies: each analyzed" "$("$loops" "$work/merged.o" '^_helper$' --tsv 2> /dev/null | cut -f1 | perl -pe 's/ at 0x[0-9a-f]+//')" "$(printf '_helper [copy 1 of 2,]\n_helper [copy 2 of 2,]')"

# Jump tables in merged objects: each object's table has the same local name (lJTI0_0), and relative tables' entries
# subtract a section-start symbol (ltmp1) with a copy per object.
switch_c() { # switch_c NAME: a loop over a ten-case switch whose cases all call
    printf 'int %s0(int), %s1(int), %s2(int), %s3(int), %s4(int), %s5(int), %s6(int), %s7(int), %s8(int), %s9(int);\n' "$1" "$1" "$1" "$1" "$1" "$1" "$1" "$1" "$1" "$1"
    printf 'int switch_%s(const unsigned char *p, int n) {\n    int x = 0;\n    for (int i = 0; i < n; i++) {\n        switch (p[i]) {\n' "$1"
    for k in 0 1 2 3 4 5 6 7 8 9; do printf '        case %s: x = %s%s(x); break;\n' "$k" "$1" "$k"; done
    printf '        default: x++;\n        }\n    }\n    return x;\n}\n'
}
switch_c fa > "$work/sa.c"
switch_c fb > "$work/sb.c"
xcrun clang -O2 -c -arch arm64 -o "$work/sa.o" "$work/sa.c" || exit 1
xcrun clang -O2 -c -arch arm64 -o "$work/sb.o" "$work/sb.c" || exit 1
xcrun ld -r -arch arm64 -o "$work/switches.o" "$work/sa.o" "$work/sb.o" 2> /dev/null || { echo "FAIL: ld -r"; exit 1; }
"$loops" "$work/switches.o" '^_switch_f[ab]$' --tsv > "$work/switches.tsv" 2> "$work/err"
check "merged byte tables: read, no warning" "$(cat "$work/err")" ""
check "merged byte tables: one natural loop each, with the calls" "$(cut -f1,7,8,12 "$work/switches.tsv" | tr '\t\n' ' /')" "_switch_fa innermost scalar+calls natural/_switch_fb innermost scalar+calls natural/"
for n in 1 2; do
    printf '    .text\n    .p2align 2\n    .globl _wide%s\n_wide%s:\n    adrp x10, Lwjt@PAGE\n    add x10, x10, Lwjt@PAGEOFF\nLhead:\n    ldrb w12, [x9], #1\n    cmp w12, #1\n    b.hi Llatch\n    ldrsw x13, [x10, x12, lsl #2]\n    add x13, x10, x13\n    br x13\nLcase0:\n    add x1, x1, #3\n    b Llatch\nLcase1:\n    eor x1, x1, x2\nLlatch:\n    subs x8, x8, #1\n    b.ne Lhead\n    ret\n    .section __TEXT,__const\n    .p2align 2\nLwjt:\n    .long Lcase0 - Lwjt\n    .long Lcase1 - Lwjt\n' "$n" "$n" > "$work/w$n.s"
    xcrun clang -c -arch arm64 -o "$work/w$n.o" "$work/w$n.s" || exit 1
done
xcrun ld -r -arch arm64 -o "$work/wide.o" "$work/w1.o" "$work/w2.o" 2> /dev/null || { echo "FAIL: ld -r"; exit 1; }
"$loops" "$work/wide.o" '^_wide[12]$' --tsv > "$work/wide.tsv" 2> "$work/err"
check "merged relative tables: read, no warning" "$(cat "$work/err")" ""
check "merged relative tables: every case in its loop" "$(cut -f1,5 "$work/wide.tsv" | tr '\t\n' ' /')" "_wide1 11/_wide2 11/"

# Two byte tables named lJTI0_0, one per merged object, of different shapes: each function reads its own object's
# (a byte table's entries are offsets from the function's own anchor, so the other object's can land in it too).
{
    printf 'int fb0(int), fb1(int), fb2(int), fb3(int, int, int), fb4(int), fb5(int), fb6(int, int, int, int), fb7(int), fb8(int), fb9(int);\n'
    printf 'int switch_fc(const unsigned char *p, int n) {\n    int x = 0;\n    for (int i = 0; i < n; i++) {\n        switch (p[i]) {\n'
    printf '        case 0: x = fb0(x); break;\n        case 1: x = fb1(x) * 3 + fb2(x + 1); break;\n        case 2: x = fb2(x); break;\n'
    printf '        case 3: x = fb3(x, i, n) ^ fb4(x); break;\n        case 4: x = fb4(x); break;\n        case 5: x = fb5(x) + fb7(x * 5); break;\n'
    printf '        case 6: x = fb6(x, i, n, x * 7); break;\n        case 7: x = fb7(x); break;\n        case 8: x = fb8(x) - fb9(x); break;\n        case 9: x = fb9(x); break;\n'
    printf '        default: x++;\n        }\n    }\n    return x;\n}\n'
} > "$work/sc.c"
xcrun clang -O2 -c -arch arm64 -o "$work/sc.o" "$work/sc.c" || exit 1
xcrun ld -r -arch arm64 -o "$work/switches2.o" "$work/sa.o" "$work/sc.o" 2> /dev/null || { echo "FAIL: ld -r"; exit 1; }
check "merged tables of two shapes: the loop as in its own object" \
    "$("$loops" "$work/switches2.o" '^_switch_fc$' --tsv 2>&1 | cut -f2,5-9,12)" "$("$loops" "$work/sc.o" '^_switch_fc$' --tsv 2>&1 | cut -f2,5-9,12)"

# Aliases (a global alias at a function's address; ltmp0 at the section's start), the matches listed for objdump and the
# whole file disassembled (LOOPS_LIST_MAX=0): the same output.
{
    printf '    .text\n    .p2align 2\n'
    for i in $(seq 0 69); do
        [[ $i == 0 || $i == 30 ]] && printf '    .globl _alias%s\n_alias%s:\n' "$i" "$i"
        printf '    .globl _f%s\n_f%s:\n    mov x1, #0\nLh%s:\n    ldr x2, [x0], #8\n    cbz x2, Lc%s\nLn%s:\n    add x1, x1, x2\n    subs x3, x3, #1\n    b.ne Lh%s\n    ret\nLc%s:\n    bl _ext%s\n    b Ln%s\n' "$i" "$i" "$i" "$i" "$i" "$i" "$i" "$i" "$i"
    done
} > "$work/many.s"
xcrun clang -c -arch arm64 -o "$work/many.o" "$work/many.s" || exit 1
shared() { perl -ne '$keep = /^_(f(\d+)|alias\d+)$/ ? (!defined $2 || $2 < 62) : $keep; print if $keep' "$1"; }
"$loops" "$work/many.o" '^_(f([0-5]?[0-9]|6[01])|alias(0|30))$' --body > "$work/p64" 2>&1
LOOPS_LIST_MAX=0 "$loops" "$work/many.o" '^_(f([0-5]?[0-9]|6[01])|alias(0|30))$' --body > "$work/p65" 2>&1
check "listed and whole (LOOPS_LIST_MAX=0): the same output" "$(shared "$work/p64" | shasum)" "$(shared "$work/p65" | shasum)"
check "listed: the aliases have their loops" "$(grep -A1 -E '^_alias(0|30)$' "$work/p64" | grep -c '^  loop 1')" 2
mkdir "$work/save-listed" "$work/save-whole"
LOOPS_SAVE="$work/save-listed" "$loops" "$work/many.o" '^_f1$' > /dev/null 2>&1
LOOPS_SAVE="$work/save-whole" LOOPS_LIST_MAX=0 "$loops" "$work/many.o" '^_f1$' > /dev/null 2>&1
check "LOOPS_LIST_MAX=0: the whole file disassembled, else the match alone" "$(grep -c '<_f2>:' "$work/save-whole/disassembly") $(grep -c '<_f2>:' "$work/save-listed/disassembly")" "1 0"

# Many functions (over 20,000 instructions, more than 64 matches): the whole-file disassembly and the parallel
# analysis give one process's output, stdout, stderr, and both merged, and a --require that fails in a late function
# fails the run.
perl -e 'print "    .text\n    .p2align 2\n";
    for my $i (0 .. 99) {
        my $op = $i == 77 ? "orr" : "eor";
        print "    .globl _g$i\n_g$i:\n    mov x1, #0\nLg$i:\n    ldr x2, [x0], #8\n    $op x1, x1, x2\n";
        print "    add x6, x6, #", $_ % 7 + 1, "\n" for 1 .. 200;
        print "    subs x3, x3, #1\n    b.ne Lg$i\n    ret\n";
    }' > "$work/big.s"
xcrun clang -c -arch arm64 -o "$work/big.o" "$work/big.s" || exit 1
for mode in one many; do
    jobs=1
    [[ $mode == many ]] && jobs=4
    LOOPS_JOBS=$jobs "$loops" "$work/big.o" '^_g' --require eor > "$work/$mode.out" 2> "$work/$mode.err"
    echo "$?" > "$work/$mode.status"
    LOOPS_JOBS=$jobs "$loops" "$work/big.o" '^_g' --require eor > "$work/$mode.both" 2>&1
done
check "parallel: 100 functions reported" "$(grep -c '^_g' "$work/many.out")" 100
check "parallel: stdout as one process's" "$(shasum < "$work/many.out")" "$(shasum < "$work/one.out")"
check "parallel: stderr as one process's" "$(shasum < "$work/many.err")" "$(shasum < "$work/one.err")"
check "parallel: both merged as one process's" "$(shasum < "$work/many.both")" "$(shasum < "$work/one.both")"
check "parallel: the late failure fails the run" "$(cat "$work/one.status") $(cat "$work/many.status") $(grep -c '^FAIL: _g77:' "$work/many.err")" "1 1 1"
# Workers that can't write their output (LOOPS_TMP missing) stop the run: exit 2, saying which.
xcrun nm -p -a "$work/big.o" > "$work/big.symbols"
perl -ne 'print "$1\t$1\n" if /^[0-9a-f]+ T (_g\d+)$/' "$work/big.symbols" > "$work/big.functions"
xcrun objdump -dr --no-show-raw-insn "$work/big.o" > "$work/big.dis"
LOOPS_FUNCTIONS="$work/big.functions" LOOPS_SYMBOLS="$work/big.symbols" LOOPS_JOBS=4 LOOPS_TMP="$work/missing" FORMAT=tsv \
    perl "$here/../lib/loops.pl" < "$work/big.dis" > /dev/null 2> "$work/err"
check "a failed worker: exit 2" "$?" 2
check "a failed worker: said" "$(grep -c 'worker 1 of 4 stopped' "$work/err")" 1

# TERM to lib/loops.pl while its workers run: they stop with it (their pids, read before the signal, all gone after).
perl -e 'print "    .text\n    .p2align 2\n";
    for my $i (0 .. 399) {
        print "    .globl _t$i\n_t$i:\n    mov x1, #0\nLt$i:\n    ldr x2, [x0], #8\n    eor x1, x1, x2\n";
        print "    add x6, x6, #", $_ % 7 + 1, "\n" for 1 .. 2000;
        print "    subs x3, x3, #1\n    b.ne Lt$i\n    ret\n";
    }' > "$work/huge.s"
xcrun clang -c -arch arm64 -o "$work/huge.o" "$work/huge.s" || exit 1
xcrun nm -p -a "$work/huge.o" > "$work/huge.symbols"
perl -ne 'print "$1\t$1\n" if /^[0-9a-f]+ T (_t\d+)$/' "$work/huge.symbols" > "$work/huge.functions"
xcrun objdump -dr --no-show-raw-insn "$work/huge.o" > "$work/huge.dis"
mkdir "$work/term"
LOOPS_FUNCTIONS="$work/huge.functions" LOOPS_SYMBOLS="$work/huge.symbols" LOOPS_JOBS=4 LOOPS_TMP="$work/term" FORMAT=tsv \
    perl "$here/../lib/loops.pl" < "$work/huge.dis" > /dev/null 2>&1 &
parent=$!
# The workers have started once their output files exist (at most 20 s).
perl -MTime::HiRes=sleep -e 'for (1 .. 400) { exit 0 if -e "$ARGV[0]/out.3"; sleep 0.05 } exit 1' "$work/term"
check "TERM: the workers started" "$?" 0
workers="$(pgrep -P "$parent" | tr '\n' ' ')"
kill -TERM "$parent"
wait "$parent"
check "TERM: lib/loops.pl exits 143" "$?" 143
check "TERM: 4 workers running before it, none after" "$(echo "$workers" | wc -w | tr -d ' ') $(for w in $workers; do kill -0 "$w" 2> /dev/null && echo "$w"; done | grep -c .)" "4 0"

# TERM to Tools/loops' own bash (as gtimeout and `kill PID` send it) while the workers run: the pipeline and the workers
# stop with it, exit 143, its scratch directory removed.
mkdir "$work/tt"
TMPDIR="$work/tt" "$loops" "$work/huge.o" '^_t' --tsv > "$work/tt.out" 2>&1 &
tool=$!
perl -MTime::HiRes=sleep -e 'for (1 .. 400) { exit 0 if glob("$ARGV[0]/experiments-tool.*/out.3"); sleep 0.05 } exit 1' "$work/tt"
check "TERM to the tool: the workers started" "$?" 0
tree="$(ps -A -o pid=,ppid= | perl -e 'my $root = shift; my %k; while (<STDIN>) { my ($p, $pp) = split; push @{$k{$pp}}, $p } my @t = ($root); my @all; while (@t) { my $p = shift @t; push @all, @{$k{$p} // []}; push @t, @{$k{$p} // []} } print "@all"' "$tool")"
t0="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
kill -TERM "$tool"
wait "$tool"
rc=$?
check "TERM to the tool: exit 143 within a second, nothing printed (the run cut short)" \
    "$rc $(perl -MTime::HiRes=time -e "print time - $t0 < 1 ? 'quick' : 'slow'") $(grep -c . "$work/tt.out")" "143 quick 0"
check "TERM to the tool: its processes (at least objdump's reader and 4 workers) all gone, scratch removed" \
    "$( (( $(echo "$tree" | wc -w) >= 5 )) && echo many) $(for p in $tree; do kill -0 "$p" 2> /dev/null && echo "$p"; done | grep -c .) $(perl -e 'opendir my $d, shift or die; print scalar grep { !/^\.\.?$/ } readdir $d' "$work/tt")" "many 0 0"

# TERM to the tool alone while it lists the functions (200,000 Swift symbols: nm, then the demangling, about a second):
# stopped there at once (bash would act on it only once a foreground command ended), exit 143, nothing printed.
perl -e 'print "    .text\n    .p2align 2\n"; printf "    .globl _\$s4main4f%06dyyF\n_\$s4main4f%06dyyF:\n    ret\n", $_, $_ for 0 .. 199999' > "$work/symbols60k.s"
xcrun clang -c -arch arm64 -o "$work/symbols60k.o" "$work/symbols60k.s" || exit 1
mkdir "$work/ti"
TMPDIR="$work/ti" "$loops" "$work/symbols60k.o" 'f000001' > "$work/ti.out" 2>&1 &
tool=$!
perl -MTime::HiRes=sleep -e 'for (1 .. 400) { exit 0 if glob("$ARGV[0]/experiments-tool.*/functions"); sleep 0.005 } exit 1' "$work/ti"
t0="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
kill -TERM "$tool"
wait "$tool"
rc=$?
check "TERM while listing the functions: exit 143 at once, nothing printed" \
    "$rc $(perl -MTime::HiRes=time -e "print time - $t0 < 0.25 ? 'quick' : 'slow'") $(grep -c . "$work/ti.out")" "143 quick 0"

# An object with 8 MB of __const and no jump table: the references child is never adopted, and is stopped when the
# analysis ends (it would otherwise run on, holding the tool's stdout, so a pipe's reader would see the end late).
printf '    .text\n    .p2align 2\n    .globl _f\n_f:\n    adrp x9, _data@PAGE\n    add x9, x9, _data@PAGEOFF\nLloop:\n    ldrb w10, [x9], #1\n    add x0, x0, x10\n    subs x1, x1, #1\n    b.ne Lloop\n    ret\n    .section __TEXT,__const\n    .globl _data\n_data:\n    .space 8388608, 0x5a\n' > "$work/big8.s"
xcrun clang -c -arch arm64 -o "$work/big8.o" "$work/big8.s" || exit 1
# Against one job (no references child at all): neither the tool's own time nor a pipe's end may wait for the child
# (a child left to finish its 8 MB adds about 0.8 s to both).
t0="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
LOOPS_JOBS=1 "$loops" "$work/big8.o" '^_f$' --tsv > /dev/null 2>&1
single="$(perl -MTime::HiRes=time -e "printf '%.3f', time - $t0")"
t0="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
"$loops" "$work/big8.o" '^_f$' --tsv > "$work/or.tsv" 2>&1
alone="$(perl -MTime::HiRes=time -e "printf '%.3f', time - $t0")"
t0="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
"$loops" "$work/big8.o" '^_f$' --tsv 2>&1 | perl -ne 1
piped="$(perl -MTime::HiRes=time -e "printf '%.3f', time - $t0")"
check "8 MB of __const, no table: the loop, the tool and a pipe's end as soon as with one job" \
    "$(cut -f12 "$work/or.tsv") $(perl -e 'print $ARGV[1] - $ARGV[0] < 0.3 && $ARGV[2] - $ARGV[0] < 0.3 ? "prompt" : "late ($ARGV[0] s with one job, $ARGV[1] s alone, $ARGV[2] s piped)"' "$single" "$alone" "$piped")" "natural prompt"

# TERM while --target builds a package: the build is stopped with the tool (nothing naming the package left right after),
# exit 143, the build's log and directory removed.
mkdir -p "$work/Pkg/Sources/Slow" "$work/tg"
printf '// swift-tools-version:6.0\nimport PackageDescription\nlet package = Package(name: "Pkg", targets: [.target(name: "Slow")])\n' > "$work/Pkg/Package.swift"
perl -e 'for my $i (1 .. 300) { print "public func f$i<T: BinaryInteger>(_ a: [T]) -> T { a.reduce(0) { \$0 &* 3 &+ \$1 } + T($i) }\n" }' > "$work/Pkg/Sources/Slow/Slow.swift"
pkg="$(cd "$work/Pkg" && pwd -P)"   # as the compiler names it (/private/var/…)
# building PKG: exit 0 once a compiler or swift-build naming PKG runs (within 30 s).
building() { perl -MTime::HiRes=sleep -e 'for (1 .. 600) { exit 0 if grep { /swift-(frontend|build)/ && index($_, $ARGV[0]) >= 0 } `ps -ww -A -o command=`; sleep 0.05 } exit 1' "$1"; }
# What the tool left in a TMPDIR (its directory, a build log): everything but SwiftPM's own lock files and temporary
# directories, which a plain `swift build` leaves there too.
own() { perl -e 'opendir my $d, shift or die; print scalar grep { !/^\.\.?$/ && !/^TemporaryDirectory\./ && !/\.lock$/ } readdir $d' "$1"; }

# A --target build while another build of the package runs (same TMPDIR, where SwiftPM keeps the lock between them): the
# tool's build waits for the other, then succeeds.
mkdir -p "$work/Waits/Sources/Slow" "$work/tg2"
cp "$work/Pkg/Package.swift" "$work/Waits/Package.swift"
perl -e 'for my $i (1 .. 2000) { print "public func f$i(_ a: [Int]) -> Int { a.reduce(0) { \$0 &* 3 &+ \$1 } &+ $i }\n" }' > "$work/Waits/Sources/Slow/Slow.swift"
waits="$(cd "$work/Waits" && pwd -P)"
TMPDIR="$work/tg2" swift build --package-path "$work/Waits" -c release --target Slow > "$work/first-build" 2>&1 &
first=$!
building "$waits"
started=$?
overlap="$(kill -0 "$first" 2> /dev/null && echo running || echo ended)"   # the other build, as the tool starts
TMPDIR="$work/tg2" "$loops" --target "$work/Waits" Slow '^f1\(' --tsv > /dev/null 2> "$work/err"
rc=$?
wait "$first"
check "--target while another build of the package runs: it waits, then succeeds (both builds do)" \
    "$started $overlap $rc $? $(own "$work/tg2")" "0 running 0 0 0"

# TERM while --target builds a package: the tool exits within seconds (not when the build ends), the build is stopped
# with it, its directory removed.
TMPDIR="$work/tg" "$loops" --target "$work/Pkg" Slow '^nothing$' > /dev/null 2>&1 &
tool=$!
building "$pkg"
started=$?
t0="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
kill -TERM "$tool"
wait "$tool"
rc=$?
check "TERM during a --target build: the build started" "$started" 0
check "TERM during a --target build: exit 143 within 5 s, the build stopped, its directory removed" \
    "$rc $(perl -MTime::HiRes=time -e "print time - $t0 < 5 ? 'quick' : 'slow'") $(pgrep -f "$pkg" | grep -c .) $(own "$work/tg")" "143 quick 0 0"

# TERM while a universal file's arm64 slice (2 GB of zeros, sparse) is copied out: exit 143 at once, the copy stopped.
huge="$(cd "$work" && pwd)/huge"   # as the tool names it (no double slash from TMPDIR)
perl -e 'open my $f, ">:raw", $ARGV[0] or die; print $f pack("NN", 0xcafebabe, 1), pack("NNNNN", 0x0100000c, 0, 16384, 2 << 30, 14);
    truncate $f, 16384 + (2 << 30) or die; close $f or die' "$huge"
# copies PATH WANT: polls (for up to 5 s for "started", 0.5 s for "gone": a killed process takes a moment to
# leave the list) until a slice copy of PATH is running ("started") or none is ("gone"); prints the last state seen.
copies() {
    perl -MTime::HiRes=sleep,time -e 'my ($path, $want) = @ARGV; my $state; my $end = time + ($want eq "gone" ? 0.5 : 5);
        while (1) {
            $state = (grep { index($_, $path) >= 0 && /my \(\$in, \$offset/ } `ps -ww -A -o command=`) ? "started" : "gone";
            last if $state eq $want || time > $end;
            sleep 0.01;
        }
        print $state' "$1" "$2"
}
"$loops" "$huge" '^_f$' > /dev/null 2>&1 &
tool=$!
started="$(copies "$huge" started)"
t0="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
kill -TERM "$tool"
wait "$tool"
rc=$?
check "TERM during a 2 GB slice's copy: exit 143 at once, the copy stopped" \
    "$started $rc $(perl -MTime::HiRes=time -e "print time - $t0 < 0.5 ? 'quick' : 'slow'") $(copies "$huge" gone)" "started 143 quick gone"
pkill -TERM -f "$huge" 2> /dev/null
rm -f "$huge"

LOOPS_JOBS=18446744073709551615 "$loops" "$work/cases.o" '^_nested$' > /dev/null 2>&1
check "LOOPS_JOBS past 64 bits" "$?" 2
LOOPS_JOBS=1000000 "$loops" "$work/cases.o" '^_nested$' > /dev/null 2>&1
check "LOOPS_JOBS of 7 digits" "$?" 2
LOOPS_JOBS=999999 "$loops" "$work/big.o" '^_g' --require eor > "$work/capped.out" 2> /dev/null
check "LOOPS_JOBS=999999: capped, the same output" "$(shasum < "$work/capped.out")" "$(shasum < "$work/one.out")"

# A universal binary is read for its arm64 slice, as the slice alone; an x86_64 file is refused.
xcrun clang -O2 -arch arm64 -arch x86_64 -o "$work/fat" "$work/linked.c" || { echo "FAIL: couldn't link a universal binary"; exit 1; }
xcrun lipo -thin arm64 -output "$work/thin" "$work/fat" || exit 1
xcrun lipo -thin x86_64 -output "$work/x86" "$work/fat" || exit 1
"$loops" "$work/fat" '^_(sum_print|scale)$' --tsv > "$work/fat.tsv" 2>&1
check "universal: exit 0" "$?" 0
check "universal: as its arm64 slice" "$(shasum < "$work/fat.tsv")" "$("$loops" "$work/thin" '^_(sum_print|scale)$' --tsv 2>&1 | shasum)"
check "universal: both functions' loops" "$(cut -f1 "$work/fat.tsv" | sort -u | tr '\n' ' ')" "_scale _sum_print "
"$loops" "$work/x86" '^_sum_print$' > /dev/null 2> "$work/err"
check "x86_64: refused" "$? $(grep -c "isn't arm64 code (x86_64)" "$work/err")" "2 1"
# arm64e, alone and in a universal file without arm64: read as arm64. A static library (ar archive) is refused.
xcrun clang -O2 -arch arm64e -o "$work/e" "$work/linked.c" || { echo "FAIL: couldn't link arm64e"; exit 1; }
xcrun clang -O2 -arch arm64e -arch x86_64 -o "$work/ex" "$work/linked.c" || { echo "FAIL: couldn't link arm64e and x86_64"; exit 1; }
check "arm64e: the loops" "$("$loops" "$work/e" '^_(sum_print|scale)$' --tsv 2> /dev/null | cut -f1 | sort -u | tr '\n' ' ')" "_scale _sum_print "
check "universal, arm64e and x86_64: as the arm64e slice" "$("$loops" "$work/ex" '^_(sum_print|scale)$' --tsv 2>&1 | shasum)" "$("$loops" "$work/e" '^_(sum_print|scale)$' --tsv 2>&1 | shasum)"
# A universal file of arm64e.x1 (subtype 0x8000000c, as macOS's system binaries hold) and x86_64: its arm64e.x1 slice.
cp "$work/e" "$work/x1"
perl -e 'open my $f, "+<:raw", $ARGV[0] or die; seek $f, 8, 0; print $f pack("V", 0x8000000c); close $f or die' "$work/x1"
xcrun lipo -thin x86_64 -output "$work/ex-x86" "$work/ex" || exit 1
xcrun lipo -create -output "$work/x1x" "$work/x1" "$work/ex-x86" || { echo "FAIL: lipo -create"; exit 1; }
check "universal, arm64e.x1 and x86_64: as the arm64e.x1 slice" "$("$loops" "$work/x1x" '^_(sum_print|scale)$' --tsv 2>&1 | shasum)" "$("$loops" "$work/e" '^_(sum_print|scale)$' --tsv 2>&1 | shasum)"
# A universal file whose arm64 slice has subtype 1 (V8, which lipo can't thin by name): copied out by the fat table.
cp "$work/thin" "$work/v8"
perl -e 'open my $f, "+<:raw", $ARGV[0] or die; seek $f, 8, 0; print $f pack("V", 1); close $f or die' "$work/v8"
xcrun lipo -create -output "$work/v8x" "$work/v8" "$work/ex-x86" || { echo "FAIL: lipo -create"; exit 1; }
check "universal, arm64 of subtype 1 and x86_64: as the slice" "$("$loops" "$work/v8x" '^_(sum_print|scale)$' --tsv 2>&1 | shasum)" "$("$loops" "$work/thin" '^_(sum_print|scale)$' --tsv 2>&1 | shasum)"
# A universal file cut one byte into its arm64 slice's end: the copy stops at the file's end and says so, exit 2 (within
# 10 s: a copy that kept reading would never end).
MACHO_PL="$here/../lib/macho.pl" perl -e 'my ($in, $out) = @ARGV; my ($slices) = `perl "$ENV{MACHO_PL}" "$in"` =~ /^slices=(.*)$/m or die;
    my ($offset, $size) = map { /^arm64\@(\d+)\@(\d+)$/ ? ($1, $2) : () } split /,/, $slices or die;
    open my $f, "<:raw", $in or die; local $/; my $bytes = <$f>; open my $o, ">:raw", $out or die;
    print $o substr($bytes, 0, $offset + $size - 1)' "$work/fat" "$work/fat-short"
"$loops" "$work/fat-short" . > /dev/null 2> "$work/err" &
tool=$!
finished=0
perl -MTime::HiRes=sleep -e 'for (1 .. 200) { exit 0 unless kill 0, $ARGV[0]; sleep 0.05 } exit 1' "$tool" || finished=$?
kill -TERM "$tool" 2> /dev/null
wait "$tool"
rc=$?
check "a universal file cut inside its arm64 slice: refused at once, said" "$finished $rc $(grep -c 'ends past the end of the file' "$work/err")" "0 2 1"
# A universal file of arm64 and arm64e: its arm64 slice, preferred.
xcrun clang -O2 -arch arm64 -arch arm64e -o "$work/a-ae" "$work/linked.c" || { echo "FAIL: couldn't link arm64 and arm64e"; exit 1; }
xcrun lipo -thin arm64 -output "$work/a-ae-thin" "$work/a-ae" || exit 1
check "universal, arm64 and arm64e: as the arm64 slice" "$("$loops" "$work/a-ae" '^_(sum_print|scale)$' --tsv 2>&1 | shasum)" "$("$loops" "$work/a-ae-thin" '^_(sum_print|scale)$' --tsv 2>&1 | shasum)"
# An ARM64 subtype nothing names (low byte 7): refused, not read as arm64e.x1.
cp "$work/e" "$work/sub7"
perl -e 'open my $f, "+<:raw", $ARGV[0] or die; seek $f, 8, 0; print $f pack("V", 7); close $f or die' "$work/sub7"
"$loops" "$work/sub7" . > /dev/null 2> "$work/err"
check "an unknown ARM64 subtype: refused" "$? $(grep -c "isn't arm64 code (arm64-subtype-7)" "$work/err")" "2 1"
# Load commands claimed shorter than their first command: read without Perl's warnings.
cp "$work/linked" "$work/short-cmds"
perl -e 'open my $f, "+<:raw", $ARGV[0] or die; seek $f, 20, 0; print $f pack("V", 30); close $f or die' "$work/short-cmds"
"$loops" "$work/short-cmds" . > /dev/null 2> "$work/err"
check "load commands cut short: no Perl warnings" "$(grep -c ' line [0-9]' "$work/err")" 0
xcrun ar rcs "$work/cases.a" "$work/cases.o" 2> /dev/null || { echo "FAIL: ar"; exit 1; }
"$loops" "$work/cases.a" '^_nested$' > /dev/null 2> "$work/err"
check "an archive: refused" "$? $(grep -c 'is a static library (an ar archive)' "$work/err")" "2 1"
# Damaged and unusual inputs, refused with a reason and no Perl warnings: a binary cut off in its load commands, a
# universal header cut off after its count, a dSYM's DWARF file.
head -c 600 "$work/linked" > "$work/cut"
"$loops" "$work/cut" . > /dev/null 2> "$work/err"
check "a truncated binary: refused, no Perl warnings" "$? $(grep -c 'is truncated' "$work/err") $(grep -c ' at .* line [0-9]' "$work/err")" "2 1 0"
printf '\xca\xfe\xba\xbe\x00\x00\x00\x02' > "$work/fat-cut"
"$loops" "$work/fat-cut" . > /dev/null 2> "$work/err"
check "a truncated universal header: refused" "$? $(grep -c 'is truncated' "$work/err") $(grep -c 'cpu-' "$work/err")" "2 1 0"
printf '\xca\xfe\xba\xbe\x00\x00' > "$work/fat-cut6"
"$loops" "$work/fat-cut6" . > /dev/null 2> "$work/err"
check "a universal header cut inside its count: refused as truncated" "$? $(grep -c 'is truncated' "$work/err")" "2 1"
xcrun clang -O2 -g -o "$work/withdebug" "$work/linked.c" || exit 1
xcrun dsymutil "$work/withdebug" -o "$work/withdebug.dSYM" 2> /dev/null || { echo "FAIL: dsymutil"; exit 1; }
"$loops" "$work/withdebug.dSYM/Contents/Resources/DWARF/withdebug" . > /dev/null 2> "$work/err"
check "a dSYM's DWARF file: refused" "$? $(grep -c "a dSYM's debug information, not code" "$work/err")" "2 1"
# __mh_execute_header is a text symbol at the start of __TEXT, before any code: no function.
"$loops" "$work/linked" '__mh_execute_header' > /dev/null 2> "$work/err"
check "__mh_execute_header: no function, no objdump warning" "$? $(grep -c 'objdump' "$work/err")" "1 0"

# A binary stripped of its local symbols (strip -x): a warning, as its static helper's code reads as its caller's.
printf '#include <stdio.h>\n__attribute__((noinline)) static int helper(int x) { printf("%%d\\n", x); return x * 3; }\n__attribute__((noinline)) int caller(int x) { return helper(x) + helper(x + 1); }\nint main(int argc, char **argv) { return caller(argc); }\n' > "$work/strip.c"
xcrun clang -O2 -o "$work/strip" "$work/strip.c" || exit 1
xcrun strip -x "$work/strip" || exit 1
"$loops" "$work/strip" '^_caller$' > /dev/null 2> "$work/err"
check "stripped: warned" "$(grep -c 'function starts in .* have no symbol (stripped?)' "$work/err")" 1

# Long names: 60 of them (20,000 bytes each, past ARG_MAX together) listed for objdump would fail with E2BIG; so would
# the 70 of the whole object.
perl -e 'print "    .text\n    .p2align 2\n";
    for my $i (0 .. 69) {
        my $name = sprintf "_long%02d_", $i; $name .= "x" x 20000;
        print "    .globl $name\n$name:\n    mov x1, #0\nLl$i:\n    ldr x2, [x0], #8\n    eor x1, x1, x2\n    subs x3, x3, #1\n    b.ne Ll$i\n    ret\n";
    }' > "$work/long.s"
xcrun clang -c -arch arm64 -o "$work/long.o" "$work/long.s" || exit 1
"$loops" "$work/long.o" '^_long[0-5]' --tsv > "$work/long.tsv" 2> "$work/err"
check "60 long names: every loop" "$? $(grep -c . "$work/long.tsv") $(head -c 200 "$work/err")" "0 60 "
"$loops" "$work/long.o" '^_long' --tsv > "$work/long.tsv" 2> "$work/err"
check "70 long names: every loop" "$? $(grep -c . "$work/long.tsv") $(head -c 200 "$work/err")" "0 70 "

# A large environment (800 KB) shares ARG_MAX with objdump's arguments: 60 names of 5,000 bytes (300 KB, under the
# default 512 KB) are disassembled from the whole file instead of listed; listed anyway (LOOPS_LIST_MAX), objdump fails
# with E2BIG, and the tool says so (exit 2) rather than reporting no loops.
perl -e 'print "    .text\n    .p2align 2\n";
    for my $i (0 .. 59) {
        my $name = sprintf "_mid%02d_", $i; $name .= "x" x 5000;
        print "    .globl $name\n$name:\n    mov x1, #0\nLm$i:\n    ldr x2, [x0], #8\n    eor x1, x1, x2\n    subs x3, x3, #1\n    b.ne Lm$i\n    ret\n";
    }' > "$work/mid.s"
xcrun clang -c -arch arm64 -o "$work/mid.o" "$work/mid.s" || exit 1
big="$(perl -e 'print "y" x 800000')"
BIG_ENVIRONMENT="$big" "$loops" "$work/mid.o" '^_mid' --tsv > "$work/mid.tsv" 2> "$work/err"
check "a 800 KB environment: every loop (the whole file disassembled)" "$? $(grep -c . "$work/mid.tsv")" "0 60"
BIG_ENVIRONMENT="$big" LOOPS_LIST_MAX=9999999 "$loops" "$work/mid.o" '^_mid' --require eor > "$work/mid.tsv" 2> "$work/err"
check "a 800 KB environment, the names listed anyway: objdump's failure said, exit 2, nothing reported" \
    "$? $(grep -c "disassembly ended early" "$work/err") $(grep -c . "$work/mid.tsv")" "2 1 0"
# The room's two allowances. 40,000 environment variables of 8 bytes (each also takes its NUL and an 8-byte pointer):
# 80 names of 5,000 bytes (400 KB) don't fit beside them, and are disassembled from the whole file.
perl -e 'print "    .text\n    .p2align 2\n";
    for my $i (0 .. 79) {
        my $name = sprintf "_wide%02d_", $i; $name .= "x" x 5000;
        print "    .globl $name\n$name:\n    mov x1, #0\nLw$i:\n    subs x3, x3, #1\n    b.ne Lw$i\n    ret\n";
    }' > "$work/wide80.s"
xcrun clang -c -arch arm64 -o "$work/wide80.o" "$work/wide80.s" || exit 1
many_variables() { perl -e 'my @env = map { sprintf "E%05d=1", $_ } 0 .. 39999; exec "env", @env, @ARGV' -- "$@"; }
many_variables "$loops" "$work/wide80.o" '^_wide' > "$work/out" 2> "$work/err"
check "40,000 small variables: room for their pointers too (no E2BIG)" "$? $(grep -c 'E2BIG\|Argument list too long\|ended early\|couldn.t disassemble' "$work/err")" "0 0"
# One variable leaving 100 bytes beyond 60 names of 5,000 bytes: within the 32 KB kept for what's added later (the
# tool's own variables, objdump's other arguments), so the names aren't listed.
size="$(perl -e '$e = 0; $e += length("$_=$ENV{$_}") + 9 for keys %ENV; print $ARGV[0] - $e - $ARGV[1] - 100 - length("BIG_ENVIRONMENT=") - 9' "$(getconf ARG_MAX)" "$(perl -e 'print 60 * (5008 + 1)')")"
big="$(perl -e 'print "y" x shift' "$size")"
BIG_ENVIRONMENT="$big" "$loops" "$work/mid.o" '^_mid' > "$work/out" 2> "$work/err"
check "a variable leaving 100 bytes: the margin kept (no E2BIG)" "$? $(grep -c 'E2BIG\|Argument list too long\|ended early\|couldn.t disassemble' "$work/err")" "0 0"

# Many symbols after the match (over 64 KB of nm output): nothing stops reading early (no exit 141 under pipefail).
perl -e 'print "    .text\n    .p2align 2\n    .globl _aaa_first\n_aaa_first:\n    mov x1, #0\nLa:\n    subs x3, x3, #1\n    b.ne La\n    ret\n";
    printf "    .globl _zz_filler_%05d_padding_padding_padding\n_zz_filler_%05d_padding_padding_padding:\n    ret\n", $_, $_ for 0 .. 2999;' > "$work/wide_nm.s"
xcrun clang -c -arch arm64 -o "$work/wide_nm.o" "$work/wide_nm.s" || exit 1
"$loops" "$work/wide_nm.o" '^_aaa_first$' --tsv > "$work/wide_nm.tsv" 2>&1
check "64 KB of symbols after the match: found, exit 0" "$? $(cut -f1,5 "$work/wide_nm.tsv" | tr '\t' ' ')" "0 _aaa_first 2"

# A name with spaces that starts with "-" (an Objective-C method), and a jump table whose symbol holds a space: the
# relocation's whole name is read.
cat > "$work/objc.s" <<'EOF'
    .text
    .p2align 2
    .globl "-[Foo spin:]"
"-[Foo spin:]":
    mov x1, #0
Lspin:
    ldr x2, [x0], #8
    eor x1, x1, x2
    subs x3, x3, #1
    b.ne Lspin
    ret
    .globl _space_table
_space_table:
    adrp x10, "_sp tab"@PAGE
    add x10, x10, "_sp tab"@PAGEOFF
Lst_head:
    ldrb w12, [x9], #1
    cmp w12, #1
    b.hi Lst_latch
    adr x11, Lst_c0
    ldrb w13, [x10, x12]
    add x11, x11, x13, lsl #2
    br x11
Lst_c0:
    add x1, x1, #3
    b Lst_latch
Lst_c1:
    eor x1, x1, x2
Lst_latch:
    subs x8, x8, #1
    b.ne Lst_head
    ret
    .section __TEXT,__const
    .globl "_sp tab"
"_sp tab":
    .byte 0
    .byte (Lst_c1 - Lst_c0) >> 2
EOF
xcrun clang -c -arch arm64 -o "$work/objc.o" "$work/objc.s" || exit 1
check "an Objective-C name: its loop" "$("$loops" "$work/objc.o" '^-\[Foo spin:\]$' --tsv 2>&1 | cut -f1,5 | tr '\t' ' ')" "-[Foo spin:] 4"
"$loops" "$work/objc.o" '^_space_table$' --tsv > "$work/space.tsv" 2> "$work/err"
check "a table's name with a space: read, no warning" "$(cat "$work/err")" ""
check "a table's name with a space: every case in the loop" "$(cut -f5,12 "$work/space.tsv" | tr '\t' ' ')" "12 natural"

# Tables bounded by their index's width (no bounds check): each index made another way. A block nothing reaches
# (`orr`) is named by the entries past the width, so a bound too wide takes it as a case; a table whose entries past
# the width leave the function (0x7f: 508 bytes on) can't be read without the width, and is placed by position.
width_case() { # width_case NAME INDEX-INSTRUCTIONS... : a loop over a table switch, its index made by the instructions
    local name="$1"; shift
    printf '    .globl _%s\n_%s:\n    adrp x10, l%s_tab@PAGE\n    add x10, x10, l%s_tab@PAGEOFF\nL%s_head:\n    ldr x9, [x0], #8\n' "$name" "$name" "$name" "$name" "$name"
    printf '    %s\n' "$@"
    printf '    adr x11, L%s_c0\n    ldrb w13, [x10, x12]\n    add x11, x11, x13, lsl #2\n    br x11\n' "$name"
    printf 'L%s_c0:\n    add x1, x1, #3\n    b L%s_latch\nL%s_c1:\n    eor x1, x1, x2\n    b L%s_latch\n' "$name" "$name" "$name" "$name"
    printf 'L%s_c2:\n    mul x1, x1, x2\n    b L%s_latch\nL%s_c3:\n    sub x1, x1, x2\n    b L%s_latch\n' "$name" "$name" "$name" "$name"
    printf 'L%s_dead:\n    orr x1, x1, x2\n    b L%s_latch\nL%s_latch:\n    subs x8, x8, #1\n    b.ne L%s_head\n    ret\n' "$name" "$name" "$name" "$name"
}
width_table() { # width_table NAME ENTRIES...: c0-c3 and dead name the cases, a number is a byte
    printf 'l%s_tab:\n' "$1"
    local name="$1" entry; shift
    for entry in "$@"; do
        case "$entry" in
            c0) printf '    .byte 0\n' ;;
            c*|dead) printf '    .byte (L%s_%s - L%s_c0) >> 2\n' "$name" "$entry" "$name" ;;
            *) printf '    .byte %s\n' "$entry" ;;
        esac
    done
}
{
    printf '    .text\n    .p2align 2\n'
    width_case wb_and 'and x12, x9, #3'
    width_case wb_ubfx 'ubfx x12, x9, #3, #2'
    width_case wb_wide 'and x12, x9, #0x1ffff'
    width_case wb_lsr 'ldr w11, [x0], #4' 'lsr w12, w11, #28'
    width_case wb_last 'ldrb w12, [x0], #1'
    # The index's source above a join point: another path brings any value.
    printf '    .globl _wb_join\n_wb_join:\n    adrp x10, lwb_join_tab@PAGE\n    add x10, x10, lwb_join_tab@PAGEOFF\n    cbz x5, Lwb_join_join\n'
    printf 'Lwb_join_head:\n    ldrb w11, [x0], #1\nLwb_join_join:\n    lsr w12, w11, #4\n    adr x11, Lwb_join_c0\n    ldrb w13, [x10, x12]\n'
    printf '    add x11, x11, x13, lsl #2\n    br x11\nLwb_join_c0:\n    add x1, x1, #3\n    b Lwb_join_latch\nLwb_join_c1:\n    eor x1, x1, x2\n'
    printf '    b Lwb_join_latch\nLwb_join_c2:\n    mul x1, x1, x2\nLwb_join_latch:\n    subs x8, x8, #1\n    b.ne Lwb_join_head\n    ret\n'
    width_case wb_mov 'and x11, x9, #3' 'mov x12, x11'
    # A switch on a call's result: the call writes x0, so the `and` before it doesn't bound the index.
    printf '    .globl _wb_call\n_wb_call:\n    stp x29, x30, [sp, #-16]!\n    adrp x20, lwb_call_tab@PAGE\n    add x20, x20, lwb_call_tab@PAGEOFF\n'
    printf 'Lwb_call_head:\n    and w0, w1, #1\n    bl _get_tag\n    adr x11, Lwb_call_c0\n    ldrb w13, [x20, x0]\n    add x11, x11, x13, lsl #2\n    br x11\n'
    printf 'Lwb_call_c0:\n    add x1, x1, #3\n    b Lwb_call_latch\nLwb_call_c1:\n    eor x1, x1, x2\n    b Lwb_call_latch\n'
    printf 'Lwb_call_c2:\n    mul x1, x1, x2\n    b Lwb_call_latch\nLwb_call_c3:\n    sub x1, x1, x2\nLwb_call_latch:\n    subs x8, x8, #1\n'
    printf '    b.ne Lwb_call_head\n    ldp x29, x30, [sp], #16\n    ret\n'
    printf '    .section __TEXT,__const\n'
    width_table wb_and c0 c1 c2 c3 dead dead
    width_table wb_ubfx c0 c1 c2 c3 dead dead dead dead
    width_table wb_wide c0 c1 c2 c3 0x7f 0x7f 0x7f 0x7f
    width_table wb_lsr c0 c1 c2 c3 0x7f 0x7f 0x7f 0x7f 0x7f 0x7f 0x7f 0x7f 0x7f 0x7f 0x7f 0x7f
    width_table wb_join c0 c1 c2 0x7f 0x7f 0x7f 0x7f 0x7f 0x7f 0x7f 0x7f 0x7f 0x7f 0x7f 0x7f 0x7f
    width_table wb_mov c0 c1 c2 c3 dead dead
    width_table wb_call c0 c1 c2 c3
    # The last table in __const: nothing after it bounds its extent.
    width_table wb_last c0 c1 c2 c3 0x7f 0x7f
} > "$work/width.s"
xcrun clang -c -arch arm64 -o "$work/width.o" "$work/width.s" || { echo "FAIL: couldn't assemble width.s"; exit 1; }
width_run() { # width_run NAME: "MIX-HAS-orr MIX-HAS-mul+sub WARNED"
    "$loops" "$work/width.o" "^_$1\$" --tsv > "$work/w.tsv" 2> "$work/err"
    printf '%s %s %s' "$(cut -f9 "$work/w.tsv" | grep -c 'orr')" "$(cut -f9 "$work/w.tsv" | grep 'mul' | grep -c 'sub')" "$(grep -c 'placed by position' "$work/err")"
}
check "width, and #3: 4 cases, not the dead block" "$(width_run wb_and)" "0 1 0"
check "width, ubfx #3, #2: 4 cases, not the dead block" "$(width_run wb_ubfx)" "0 1 0"
check "width, and of 17 bits: no bound, placed by position" "$(width_run wb_wide | cut -d' ' -f3)" 1
check "width, lsr w #28 of a 32-bit load: 16 entries, cut where they leave the function" "$(width_run wb_lsr)" "0 1 0"
check "width, the last table in __const: read, cut where its entries leave the function" "$(width_run wb_last)" "0 1 0"
check "width, a source above a join point: no bound, placed by position" "$(width_run wb_join | cut -d' ' -f3)" 1
check "width, mov of a 2-bit value: 4 cases, not the dead block" "$(width_run wb_mov)" "0 1 0"
check "width, a call's result: every case, by the extent" "$(width_run wb_call)" "0 1 0"

# A 24-bit index (`lsr x12, x9, #40`): no width bound, the table read to its extent (the next symbol), no warning.
width_case wb_24 'lsr x12, x9, #40' > "$work/w24.s"
{
    printf '    .text\n    .p2align 2\n'
    cat "$work/w24.s"
    printf '    .section __TEXT,__const\n'
    width_table wb_24 c0 c1 c2 c3
    # An unreferenced label after it, its bytes naming the dead block: the label still ends the table.
    printf 'lother:\n    .byte (Lwb_24_dead - Lwb_24_c0) >> 2, (Lwb_24_dead - Lwb_24_c0) >> 2\n'
} > "$work/width24.s"
xcrun clang -c -arch arm64 -o "$work/width24.o" "$work/width24.s" || { echo "FAIL: couldn't assemble width24.s"; exit 1; }
"$loops" "$work/width24.o" '^_wb_24$' --tsv > "$work/w.tsv" 2> "$work/err"
check "width, a 24-bit index: read to the next symbol (unreferenced), every case, not the dead block, no warning" "$(cut -f9 "$work/w.tsv" | grep 'mul' | grep -c 'sub') $(cut -f9 "$work/w.tsv" | grep -c 'orr') $(cat "$work/err")" "1 0 "

# The last table in __const, nothing after it bounding it: it ends at its last entry naming a block only a table
# reaches. Here the three after its 3 cases name the preheader (reached from the entry) and the middle of case 1's
# inner loop (no block starts there): no case, no loop through the preheader, the inner loop entered once.
cat > "$work/tail.s" <<'EOF'
    .text
    .p2align 2
    .globl _wb_tail
_wb_tail:
    adrp x10, lwb_tail_tab@PAGE
    add x10, x10, lwb_tail_tab@PAGEOFF
    b Lt_pre
Lt_c0:
    add x1, x1, #3
    b Lt_latch
Lt_pre:
    mov x8, #100
Lt_head:
    ldrb w12, [x0], #1
    adr x11, Lt_c0
    ldrb w13, [x10, x12]
    add x11, x11, x13, lsl #2
    br x11
Lt_c1:
    mov x5, #4
Lt_in:
    eor x1, x1, x2
    add x1, x1, #1
    subs x5, x5, #1
    b.ne Lt_in
    b Lt_latch
Lt_c2:
    mul x1, x1, x2
Lt_latch:
    subs x8, x8, #1
    b.ne Lt_head
    ret
    .section __TEXT,__const
lwb_tail_tab:
    .byte 0
    .byte (Lt_c1 - Lt_c0) >> 2
    .byte (Lt_c2 - Lt_c0) >> 2
    .byte (Lt_pre - Lt_c0) >> 2
    .byte (Lt_pre - Lt_c0) >> 2
    .byte (Lt_in + 4 - Lt_c0) >> 2
EOF
xcrun clang -c -arch arm64 -o "$work/tail.o" "$work/tail.s" || { echo "FAIL: couldn't assemble tail.s"; exit 1; }
"$loops" "$work/tail.o" '^_wb_tail$' --tsv > "$work/w.tsv" 2> "$work/err"
check "width, nothing bounding the table: its cases, not the entries after them" "$(cut -f5,12 "$work/w.tsv" | tr '\t\n' ' /') $(cat "$work/err")" "16 natural/4 natural/ "

# Unbounded, and every entry names a block the entry reaches (the loop's header): no case read; placed by position, said.
cat > "$work/none.s" <<'EOF'
    .text
    .p2align 2
    .globl _wb_none
_wb_none:
    adrp x10, lwb_none_tab@PAGE
    add x10, x10, lwb_none_tab@PAGEOFF
Ln_head:
    ldrb w12, [x0], #1
    adr x11, Ln_head
    ldrb w13, [x10, x12]
    add x11, x11, x13, lsl #2
    br x11
Ln_c1:
    eor x1, x1, x2
    b Ln_head
    .section __TEXT,__const
lwb_none_tab:
    .byte 0
    .byte 0
EOF
xcrun clang -c -arch arm64 -o "$work/none.o" "$work/none.s" || { echo "FAIL: couldn't assemble none.s"; exit 1; }
"$loops" "$work/none.o" '^_wb_none$' > /dev/null 2> "$work/err"
check "width, unbounded, no entry naming a block only a table reaches: placed by position, said" \
    "$(grep -c 'nothing bounds it, and no entry names a block only a table reaches); its cases are placed by position' "$work/err")" 1

# Linked, a width-bounded table followed by the next table (here a 2, naming the preheader): the code's reference to
# that table (in _main) ends this one, so no loop through the preheader.
cat > "$work/garbage.s" <<'EOF'
    .text
    .p2align 2
    .globl _garbage
_garbage:
    adrp x10, lJTI0_0@PAGE
    add x10, x10, lJTI0_0@PAGEOFF
    b Lpre
Lcase0:
    add x1, x1, #3
    b Llatch
Lpre:
    mov x8, #100
Lhead:
    ldrb w9, [x0], #1
    adr x13, Lcase0
    ldrb w14, [x10, x9]
    add x13, x13, x14, lsl #2
    br x13
Lcase1:
    eor x1, x1, x2
    b Llatch
Lcase2:
    mul x1, x1, x2
Llatch:
    subs x8, x8, #1
    b.ne Lhead
    mov x0, x1
    ret
    .globl _main
_main:
    stp x29, x30, [sp, #-16]!
    bl _garbage
    adrp x8, lJTI0_1@PAGE
    add x8, x8, lJTI0_1@PAGEOFF
    ldrb w9, [x8]
    add w0, w0, w9
    ldp x29, x30, [sp], #16
    ret
    .section __TEXT,__const
lJTI0_0:
    .byte 0
    .byte (Lcase1 - Lcase0) >> 2
    .byte (Lcase2 - Lcase0) >> 2
lJTI0_1:
    .byte 2
    .byte 2
    .byte 2
    .space 300, 0x7f
EOF
xcrun clang -arch arm64 -o "$work/garbage" "$work/garbage.s" || { echo "FAIL: couldn't link garbage.s"; exit 1; }
check "linked, the next table after a width-bounded one: one natural loop, every case" \
    "$("$loops" "$work/garbage" '^_garbage$' --tsv 2>&1 | cut -f5,12 | tr '\t' ' ')" "12 natural"

# Linked, the next table names a block inside a case's inner loop (Lskip, reached only through tables): the code's
# reference to that table (in _main) ends this one, so the inner loop keeps one entry.
cat > "$work/phantom.s" <<'EOF'
    .text
    .p2align 2
    .globl _phantom
_phantom:
    adrp x10, lJTI0_0@PAGE
    add x10, x10, lJTI0_0@PAGEOFF
    mov x8, #100
Lhead:
    ldrb w9, [x0], #1
    adr x13, Lcase0
    ldrb w14, [x10, x9]
    add x13, x13, x14, lsl #2
    br x13
Lcase0:
    add x1, x1, #3
    b Llatch
Lcase1:
    mov x5, #4
Linner:
    eor x1, x1, x2
    cbz x2, Lskip
    add x1, x1, #1
Lskip:
    subs x5, x5, #1
    b.ne Linner
    b Llatch
Lcase2:
    mul x1, x1, x2
Llatch:
    subs x8, x8, #1
    b.ne Lhead
    mov x0, x1
    ret
    .globl _main
_main:
    stp x29, x30, [sp, #-16]!
    bl _phantom
    adrp x8, lJTI0_1@PAGE
    add x8, x8, lJTI0_1@PAGEOFF
    ldrb w9, [x8]
    add w0, w0, w9
    ldp x29, x30, [sp], #16
    ret
    .section __TEXT,__const
lJTI0_0:
    .byte 0
    .byte (Lcase1 - Lcase0) >> 2
    .byte (Lcase2 - Lcase0) >> 2
lJTI0_1:
    .byte (Lskip - Lcase0) >> 2
    .byte 1
    .byte 1
    .space 300, 0x7f
EOF
xcrun clang -arch arm64 -o "$work/phantom" "$work/phantom.s" || { echo "FAIL: couldn't link phantom.s"; exit 1; }
check "linked, the next table bounding a width-bounded one: two natural loops" \
    "$("$loops" "$work/phantom" '^_phantom$' --tsv 2>&1 | cut -f5,12 | tr '\t\n' ' /')" "17 natural/5 natural/"
# The same, the next table referred to only by a q-register load (`ldr q0, [x8, #off]`: the offset scaled by 16).
perl -pe 's/^    add x8, x8, lJTI0_1\@PAGEOFF\n/    ldr q0, [x8, lJTI0_1\@PAGEOFF]\n/; s/^    ldrb w9, \[x8\]\n//; s/^lJTI0_1:\n/    .p2align 4\nlJTI0_1:\n/' "$work/phantom.s" > "$work/phantom-q.s"
xcrun clang -arch arm64 -o "$work/phantom-q" "$work/phantom-q.s" || { echo "FAIL: couldn't link phantom-q.s"; exit 1; }
check "linked, the next table referred to by a q load: two natural loops" \
    "$("$loops" "$work/phantom-q" '^_phantom$' --tsv 2>&1 | cut -f5,12 | tr '\t\n' ' /')" "17 natural/5 natural/"
# In an object, the tables as assembler-local labels (no symbols: relocations name the section's start, ltmp1, plus an
# addend), and a symbol after them: the first table starts at a symbol (ltmp1) that isn't its own, so the next
# table's relocation, not the next symbol, ends it.
{ perl -pe 's/lJTI0_0/Lph_0/g; s/lJTI0_1/Lph_1/g' "$work/phantom.s"; printf 'lJTI9_9:\n    .byte 0\n'; } > "$work/phantom-l.s"
xcrun clang -c -arch arm64 -o "$work/phantom-l.o" "$work/phantom-l.s" || { echo "FAIL: couldn't assemble phantom-l.s"; exit 1; }
check "object, local labels, the next table's relocation and addend ending this one: two natural loops" \
    "$("$loops" "$work/phantom-l.o" '^_phantom$' --tsv 2>&1 | cut -f5,12 | tr '\t\n' ' /')" "17 natural/5 natural/"

# A merged object whose parts each name their __const start ltmp1: B's reference to its ltmp1 + 0x14 is B's alone, and
# doesn't cut A's second table (at A's ltmp1 + 0x10, 16 entries) to 4.
cat > "$work/cca.s" <<'EOF'
    .text
    .p2align 2
    .globl _fa0
_fa0:
    and w8, w0, #0x3
    adrp x9, Ltab0@PAGE
    add x9, x9, Ltab0@PAGEOFF
    adr x10, La0
    ldrb w11, [x9, x8]
    add x10, x10, x11, lsl #2
    br x10
La0:
    mov x0, #1
    ret
    mov x0, #2
    ret
    mov x0, #3
    ret
    mov x0, #4
    ret
    .globl _fa
    .p2align 2
_fa:
    mov x2, #0
Lhead:
    ldr w8, [x0], #4
    and w8, w8, #0xf
    adrp x9, Ltab@PAGE
    add x9, x9, Ltab@PAGEOFF
    adr x10, Lc0
    ldrb w11, [x9, x8]
    add x10, x10, x11, lsl #2
    br x10
EOF
for k in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if [[ $k == 12 ]]; then printf 'Lc%s:\n    add x2, x2, #%s\n    b Lhead\n' "$k" "$k"; else printf 'Lc%s:\n    add x2, x2, #%s\n    ret\n' "$k" "$k"; fi
done >> "$work/cca.s"
printf '    .section __TEXT,__const\nLtab0:\n    .byte 0, 2, 4, 6\n    .space 12\nLtab:\n    .byte 0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30\n' >> "$work/cca.s"
printf '    .text\n    .p2align 2\n    .globl _fb\n_fb:\n    adrp x8, Lk@PAGE\n    ldr w0, [x8, Lk@PAGEOFF]\n    ret\n    .section __TEXT,__const\nLpad:\n    .space 0x14\nLk:\n    .long 0x12345678\n' > "$work/ccb.s"
xcrun clang -c -arch arm64 -o "$work/cca.o" "$work/cca.s" || { echo "FAIL: couldn't assemble cca.s"; exit 1; }
xcrun clang -c -arch arm64 -o "$work/ccb.o" "$work/ccb.s" || { echo "FAIL: couldn't assemble ccb.s"; exit 1; }
xcrun ld -r -arch arm64 -o "$work/ccm.o" "$work/cca.o" "$work/ccb.o" 2> /dev/null || { echo "FAIL: ld -r"; exit 1; }
check "merged, another part's reference to its own ltmp1 + 0x14: the table not cut (16 cases, the loop)" \
    "$(LOOPS_TABLES=1 "$loops" "$work/ccm.o" '^_fa$' --tsv 2>&1 | perl -ne 'print "$1 " if /^table: .*, (\d+) cases:/; print "loop " if /^_fa\tloop1\t/')" "16 loop "

"$loops" "$work/cases.o" 'no_such_function' > /dev/null 2>&1
check "no matching function" "$?" 1
