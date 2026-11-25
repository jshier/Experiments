#!/bin/bash
# Tools/bn without a server (BN_MCP_URL at a closed port): exit 2 saying so, for `status` and for `loop-il` once its
# own work is done. loop-il reaches the server on an object with 64 KB of symbols after the match (nothing reading
# early: no exit 141 under pipefail) and on an Objective-C method's name (spaces, a leading "-"); bad usage exits 2.
here="$(cd "$(dirname "$0")" && pwd)"
bn="$here/../bn"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-bn.XXXXXX")"
trap '[[ -z "${fake:-}" ]] || kill "$fake" 2> /dev/null; rm -rf "$work"' EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }
command -v jq > /dev/null || { echo "skipped: no jq"; exit 0; }
export BN_MCP_URL=http://127.0.0.1:1/mcp

"$bn" status > /dev/null 2> "$work/err"
check "status, no server: exit 2" "$?" 2
check "status, no server: said" "$(grep -c 'no Binary Ninja MCP server at http://127.0.0.1:1/mcp' "$work/err")" 1

# early STEP COUNT ARGS...: bn ARGS TERMed at 0, STEP, 2 STEP, … ms (COUNT runs), each in a TMPDIR and a process group
# of its own. Prints "none", or the runs that left anything: files in the TMPDIR as bn exits (its replies' and loop-il's
# directories, Tools/loops' scratch), processes of the group a second later (a request, Tools/loops, a slice's copy).
# Nothing here depends on timing: a run leaves nothing whenever the TERM lands.
early() {
    local step="$1" count="$2" i ms files procs left=''
    shift 2
    for ((i = 0; i < count; i++)); do
        ms=$((i * step))
        rm -rf "$work/early"
        mkdir "$work/early"
        TMPDIR="$work/early" perl -e 'setpgrp(0, 0); exec @ARGV' "$bn" "$@" > /dev/null 2>&1 &
        tool=$!
        perl -MTime::HiRes=sleep -e 'sleep $ARGV[0] / 1000' "$ms"
        kill -TERM "$tool" 2> /dev/null
        wait "$tool"
        files="$(perl -e 'opendir my $d, shift or die; print scalar grep { !/^\.\.?$/ } readdir $d' "$work/early")"
        procs="$(perl -MTime::HiRes=sleep,time -e 'my $end = time + 1; my @p;
            while (1) { @p = grep { (split)[1] == $ARGV[0] } `ps -A -o pid=,pgid=`; last if !@p || time > $end; sleep 0.01 }
            print scalar @p' "$tool")"
        if [[ "$files $procs" != "0 0" ]]; then
            left="$left ${ms}ms:files=$files,processes=$procs"
            kill -KILL -- "-$tool" 2> /dev/null
        fi
    done
    rm -rf "$work/early"
    echo "${left:-none}"
}
# TERM in bn's first 30 ms, 1 ms apart (its replies' directory made once the traps are set).
check "status, TERM in the first 30 ms: nothing left" "$(early 1 30 status)" none

perl -e 'print "    .text\n    .p2align 2\n    .globl _aaa_first\n_aaa_first:\n    mov x1, #0\nLa:\n    subs x3, x3, #1\n    b.ne La\n    ret\n";
    printf "    .globl _zz_filler_%05d_padding_padding_padding\n_zz_filler_%05d_padding_padding_padding:\n    ret\n", $_, $_ for 0 .. 2999;
    print "    .globl \"-[Foo spin:]\"\n\"-[Foo spin:]\":\nLs:\n    subs x3, x3, #1\n    b.ne Ls\n    ret\n";' > "$work/wide.s"
xcrun clang -c -arch arm64 -o "$work/wide.o" "$work/wide.s" || { echo "FAIL: couldn't assemble wide.s"; exit 1; }
check "the object has 64 KB of symbols after the match" "$(xcrun nm -p "$work/wide.o" | perl -ne '$after += length if $seen; $seen = 1 if / _aaa_first$/; END { print $after > 65536 ? "yes" : "no" }')" yes
"$bn" loop-il "$work/wide.o" '^_aaa_first$' > /dev/null 2> "$work/err"
check "loop-il, 64 KB of symbols after the match: reaches the server (exit 2)" "$? $(grep -c 'no Binary Ninja MCP server' "$work/err")" "2 1"
"$bn" loop-il "$work/wide.o" '^_zz_filler' > /dev/null 2> "$work/err"
check "loop-il, 3,000 matches: the first's (no loops), exit 1" "$? $(grep -c '^FAIL: no loops in _zz_filler_00000_' "$work/err")" "1 1"
"$bn" loop-il "$work/wide.o" '^-\[Foo spin:\]$' > /dev/null 2> "$work/err"
check "loop-il, an Objective-C method: found, reaches the server (exit 2)" "$? $(grep -c 'no Binary Ninja MCP server' "$work/err")" "2 1"

"$bn" loop-il "$work/wide.o" '^_aaa_first$' --level > /dev/null 2>&1
check "--level without a value" "$?" 2
"$bn" loop-il "$work/wide.o" '^_aaa_first$' --level xyz > /dev/null 2>&1
check "--level xyz" "$?" 2
"$bn" loop-il "$work/missing.o" '^_aaa_first$' > /dev/null 2>&1
check "no such file" "$?" 2
"$bn" loop-il "$work/wide.o" 'no_such_function' > /dev/null 2>&1
check "no matching function" "$?" 1
# Tools/loops failing (here on a bad LOOPS_JOBS): its status and message, not "no function matching".
LOOPS_JOBS=abc "$bn" loop-il "$work/wide.o" '^_aaa_first$' > /dev/null 2> "$work/err"
check "Tools/loops failing: its exit 2 and its message" "$? $(grep -c 'LOOPS_JOBS must be' "$work/err") $(grep -c 'no function matching' "$work/err")" "2 1 0"

# TERM while loop-il copies a universal file's arm64 slice (2 GB of zeros, sparse): the copy is stopped with the tool.
huge="$(cd "$work" && pwd)/huge"   # as bn names it (no double slash from TMPDIR)
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
"$bn" loop-il "$huge" '^_f$' > /dev/null 2>&1 &
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

# A server that answers the handshake, then nothing (a dialog open in the app): each request ends at its time limit,
# exit 2, said.
cat > "$work/stall.pl" <<'EOS'
use IO::Socket::INET;
my $server = IO::Socket::INET->new(Listen => 16, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1) or die "listen: $!";
$| = 1;
print "$$ ", $server->sockport, "\n";
$SIG{ALRM} = $SIG{TERM} = sub { exit 0 };
alarm 20;
my @held;
while (my $c = $server->accept) {
    my ($head, $body) = ('', '');
    while (my $line = <$c>) { $head .= $line; last if $line =~ /^\r?\n$/ }
    my ($length) = $head =~ /content-length:\s*(\d+)/i;
    read $c, $body, $length // 0;
    if ($body =~ /"method":"initialize"/) {
        my $reply = '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"stall","version":"1"}}}';
        print $c "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nMcp-Session-Id: stall1\r\nContent-Length: " . length($reply) . "\r\nConnection: close\r\n\r\n$reply";
        close $c;
    } elsif ($body =~ /notifications\/initialized/) {
        print $c "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        close $c;
    } else {
        push @held, $c;
    }
}
EOS
exec 3< <(perl "$work/stall.pl")
read -r server port <&3
t0="$(perl -MTime::HiRes=time -e 'printf "%.1f", time')"
BN_MCP_URL="http://127.0.0.1:$port/mcp" BN_LIMIT=2 "$bn" call bn_open_item_list > /dev/null 2> "$work/err"
rc=$?
check "a stalled server: exit 2 at the time limit, said" "$rc $(perl -MTime::HiRes=time -e "print time - $t0 < 6 ? 'quick' : 'slow'") $(grep -c "didn't answer within 2 s" "$work/err")" "2 quick 1"
kill "$server" 2> /dev/null
BN_LIMIT=abc "$bn" status > /dev/null 2>&1
check "BN_LIMIT=abc" "$?" 2

# loop-il against a fake server whose Binary Ninja knows only _spin_other (as with an object's function at offset 0,
# where Binary Ninja makes none): ^_spin$ fails, never taking the similar name; ^_spin_other$ is found. The item opened
# is closed either way.
cat > "$work/fake.pl" <<'EOS'
use IO::Socket::INET;
use JSON::PP;
my ($log, $rows_file, $names_file, $stall_file) = @ARGV;   # extra search rows, "NAME ADDRESS" for bn_function_info, stall
# ($stall_file: the search never answered; $stall_file-info: an address's bn_function_info never answered; $stall_file-none:
# addresses, one a line, where Binary Ninja has no function; $stall_file-active: bn_binary_view_get_active never answered;
# $stall_file-open-error: the open answered with a tool error)
my $server = IO::Socket::INET->new(Listen => 16, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1) or die "listen: $!";
$| = 1;
print "$$ ", $server->sockport, "\n";
$SIG{ALRM} = $SIG{TERM} = sub { exit 0 };
alarm 300;
open my $l, '>>', $log or die;
$l->autoflush(1);
my @held;
my $row = "| 0x40001c | aarch64 | _spin_other | mac-aarch64 | 0x40001c | 0x40003b | int64_t() | 3 | true | false |";
$row .= "\n| 0x400040 | aarch64 | _dup | mac-aarch64 | 0x400040 | 0x40004b | int64_t() | 1 | true | false |";
$row .= "\n| 0x400050 | aarch64 | _dup | mac-aarch64 | 0x400050 | 0x40005b | int64_t() | 1 | true | false |";
my %text = (
    bn_binary_view_get_active => '{"binaryView":{"handle":"view_1"}}',
    bn_open_item_open => '{"openItem":{"handle":"item_1"}}',
    bn_function_search => "---\ncount: 1\n---\n\n| function | arch | name | platform | lowestAddress | highestAddress | definition | basicBlockCount | exported | autoDiscovered |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n$row\n",
    bn_function_il => "---\nnextOffset: null\n---\n0x400020  x2 = [x0].q\n",
);
while (my $c = $server->accept) {
    my ($head, $body) = ('', '');
    while (my $line = <$c>) { $head .= $line; last if $line =~ /^\r?\n$/ }
    my ($length) = $head =~ /content-length:\s*(\d+)/i;
    read $c, $body, $length // 0;
    my $request = decode_json($body);
    my $extra = do { local $/; open my $x, '<', $rows_file or undef; $x ? <$x> : '' };
    my %named = do { open my $x, '<', $names_file or undef; $x ? map { split } <$x> : () };
    my $reply;
    if (($request->{method} // '') eq 'initialize') {
        $reply = '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"fake","version":"1"}}}';
    } elsif (($request->{method} // '') eq 'tools/call') {
        my ($name, $args) = ($request->{params}{name}, $request->{params}{arguments});
        print $l "$name ", encode_json($args), "\n";
        if ($name eq 'bn_function_search' && -e $stall_file) { push @held, $c; next }   # never answered
        if ($name eq 'bn_binary_view_get_active' && -e "$stall_file-active") { push @held, $c; next }
        sleep 3 if $name eq 'bn_open_item_open' && -e "$stall_file-slow-open";
        if ($name eq 'bn_function_info' && ($args->{function} // '') =~ /^0x/ && -e "$stall_file-info") { push @held, $c; next }
        my %none = do { open my $x, '<', "$stall_file-none" or undef; $x ? map { chomp; ($_ => 1) } <$x> : () };
        my $function = $args->{function} // '';
        $function = $named{$function} if exists $named{$function};
        my $error = $name eq 'bn_function_info' && ($function !~ /^0x/ || $none{$function});   # any other address is one
        if ($name eq 'bn_open_item_open' && -e "$stall_file-open-error") {
            $reply = encode_json({ jsonrpc => '2.0', id => $request->{id}, result => { content => [{ type => 'text', text => 'Failed to open: unsupported file' }], isError => JSON::PP::true } });
        } else {
            my $text = $error ? 'Invalid address expression: No symbol named' : $name eq 'bn_function_info' ? "---\nfunction: \"$function\"\n---\n"
                : $name eq 'bn_function_search' ? "$text{$name}$extra" : $text{$name} // '{}';
            $reply = encode_json({ jsonrpc => '2.0', id => $request->{id}, result => { content => [{ type => 'text', text => $text }], isError => $error ? JSON::PP::true : JSON::PP::false } });
        }
    }
    if (defined $reply) {
        print $c "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nMcp-Session-Id: fake1\r\nContent-Length: " . length($reply) . "\r\nConnection: close\r\n\r\n$reply";
    } else {
        print $c "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    }
    close $c;
}
EOS
printf '    .text\n    .p2align 2\n    .globl _spin\n_spin:\nLs:\n    subs x3, x3, #1\n    b.ne Ls\n    ret\n    .globl _spin_other\n_spin_other:\nLo:\n    eor x1, x1, x2\n    subs x3, x3, #2\n    b.ne Lo\n    ret\n    .globl _dup\n_dup:\nLd:\n    subs x3, x3, #1\n    b.ne Ld\n    ret\n    .subsections_via_symbols\n' > "$work/sub.s"
xcrun clang -c -arch arm64 -o "$work/sub.o" "$work/sub.s" || { echo "FAIL: couldn't assemble sub.s"; exit 1; }
exec 4< <(perl "$work/fake.pl" "$work/requests" "$work/rows" "$work/names" "$work/stall")
read -r fake port <&4
# loop-il TERMed in its first 120 ms, 2 ms apart (its scratch directory, Tools/loops, the requests, the open): nothing left,
# and every item opened closed again.
: > "$work/requests"
check "loop-il, TERM in the first 120 ms: nothing left" "$(BN_MCP_URL="http://127.0.0.1:$port/mcp" early 2 61 loop-il "$work/sub.o" '^_spin_other$')" none
check "loop-il, TERM in the first 120 ms: every item opened closed" \
    "$(grep -c '^bn_open_item_open ' "$work/requests") opened" "$(grep -c '^bn_open_item_close ' "$work/requests") opened"
BN_MCP_URL="http://127.0.0.1:$port/mcp" "$bn" loop-il "$work/sub.o" '^_spin$' > /dev/null 2> "$work/err"
check "a similar name only: fails, said (the name once)" "$? $(grep -c '^FAIL: Binary Ninja has no function named exactly _spin$' "$work/err")" "1 1"
BN_MCP_URL="http://127.0.0.1:$port/mcp" "$bn" loop-il "$work/sub.o" '^_spin_other$' > "$work/out" 2> "$work/err"
check "the exact name: found" "$? $(grep -c '^function _spin_other at 0x40001c (objdump 0x' "$work/out")" "0 1"
check "the exact name: searched once (its mangled and demangled names are the same)" "$(grep -c '^bn_function_search .*_spin_other' "$work/requests")" 1
BN_MCP_URL="http://127.0.0.1:$port/mcp" "$bn" loop-il "$work/sub.o" '^_dup$' > /dev/null 2> "$work/err"
check "two functions of the exact name: fails, said" "$? $(grep -c '^FAIL: Binary Ninja has several functions named _dup' "$work/err")" "1 1"
check "the item opened, closed every time" "$(grep -c '^bn_open_item_open ' "$work/requests") $(grep -c '^bn_open_item_close .*"openItem":"item_1"' "$work/requests")" "3 3"
# A universal object: an object still (no fallback to objdump's address, which this server would accept).
printf 'long spin(const long *p, long n) { long s = 0; for (long i = 0; i < n; i++) s ^= p[i] * 3; return s; }\n' > "$work/spin.c"
xcrun clang -O1 -c -arch arm64 -arch x86_64 -o "$work/spin-fat.o" "$work/spin.c" || { echo "FAIL: couldn't compile spin.c"; exit 1; }
BN_MCP_URL="http://127.0.0.1:$port/mcp" "$bn" loop-il "$work/spin-fat.o" '^_spin$' > /dev/null 2> "$work/err"
check "a universal object: no address fallback, fails" "$? $(grep -c '^FAIL: Binary Ninja has no function named exactly _spin' "$work/err")" "1 1"
# A linked binary with two static functions named _spin (one per object): Tools/loops analyzes the first; Binary Ninja
# resolves the name to the second (as it may), and its search lists both. loop-il takes objdump's address, the first.
printf '    .text\n    .p2align 2\n    .globl _one\n_one:\n    b _spin\n_spin:\nL1:\n    eor x1, x1, x2\n    subs x3, x3, #1\n    b.ne L1\n    ret\n' > "$work/s1.s"
printf '    .text\n    .p2align 2\n    .globl _two\n_two:\n    b _spin\n_spin:\nL2:\n    orr x1, x1, x2\n    subs x3, x3, #1\n    b.ne L2\n    ret\n' > "$work/s2.s"
printf '    .text\n    .p2align 2\n    .globl _main\n_main:\n    bl _one\n    bl _two\n    ret\n' > "$work/sm.s"
xcrun clang -c -arch arm64 -o "$work/s1.o" "$work/s1.s" || exit 1
xcrun clang -c -arch arm64 -o "$work/s2.o" "$work/s2.s" || exit 1
xcrun clang -arch arm64 -o "$work/dup" "$work/s1.o" "$work/s2.o" "$work/sm.s" || { echo "FAIL: couldn't link dup"; exit 1; }
copies="$(xcrun nm -p "$work/dup" | perl -ne 'printf "0x%x\n", hex $1 if /^([0-9a-f]+) t _spin$/' | sort)"
first="$(echo "$copies" | head -1)"
second="$(echo "$copies" | tail -1)"
printf '_spin %s\n' "$second" > "$work/names"
printf '| %s | aarch64 | _spin | mac-aarch64 | %s | %s | int64_t() | 1 | false | false |\n' "$first" "$first" "$first" "$second" "$second" "$second" > "$work/rows"
BN_MCP_URL="http://127.0.0.1:$port/mcp" "$bn" loop-il "$work/dup" '^_spin$' > "$work/out" 2> "$work/err"
check "linked, two functions named _spin, the name resolving to the second: objdump's first" \
    "$? $(grep -c "^function _spin at $first (objdump $first)" "$work/out")" "0 1"
# The same binary, Binary Ninja having no function at objdump's first _spin (it names the second only): the name decides.
printf '_spin %s\n' "$second" > "$work/names"
printf '| %s | aarch64 | _spin | mac-aarch64 | %s | %s | int64_t() | 1 | false | false |\n' "$second" "$second" "$second" > "$work/rows"
echo "$first" > "$work/stall-none"
BN_MCP_URL="http://127.0.0.1:$port/mcp" "$bn" loop-il "$work/dup" '^_spin$' > "$work/out" 2> "$work/err"
check "linked, no function at objdump's address: the name's" "$? $(grep -c "^function _spin at $second (objdump $first)" "$work/out")" "0 1"
rm -f "$work/stall-none"
# A stall on the address lookup: exit 2 with its message, never "several functions".
touch "$work/stall-info"
BN_MCP_URL="http://127.0.0.1:$port/mcp" BN_LIMIT=2 "$bn" loop-il "$work/dup" '^_spin$' > /dev/null 2> "$work/err"
check "a stall on the address lookup: exit 2, said" "$? $(grep -c "didn't answer within 2 s" "$work/err") $(grep -c 'several' "$work/err")" "2 1 0"
rm -f "$work/stall-info" "$work/names" "$work/rows"

# A server that stops answering the search: exit 2 with its message, not "no function"; one search when the mangled and
# demangled names are the same.
: > "$work/requests"
touch "$work/stall"
BN_MCP_URL="http://127.0.0.1:$port/mcp" BN_LIMIT=2 "$bn" loop-il "$work/sub.o" '^_spin_other$' > /dev/null 2> "$work/err"
check "a stall during the lookup: exit 2, said, one search" \
    "$? $(grep -c "didn't answer within 2 s" "$work/err") $(grep -c '^bn_function_search ' "$work/requests")" "2 1 1"
rm -f "$work/stall"

# TERM while loop-il waits on Binary Ninja (here a stalled search): the item it opened is closed all the same, exit 143.
: > "$work/requests"
touch "$work/stall"
BN_MCP_URL="http://127.0.0.1:$port/mcp" BN_LIMIT=30 "$bn" loop-il "$work/sub.o" '^_spin_other$' > /dev/null 2>&1 &
tool=$!
perl -MTime::HiRes=sleep -e 'for (1 .. 300) { open my $f, "<", $ARGV[0] or exit 1; exit 0 if grep { /^bn_function_search / } <$f>; sleep 0.01 } exit 1' "$work/requests"
t0="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
kill -TERM "$tool"
wait "$tool"
rc=$?
check "TERM during a request (30 s limit): exit 143 at once, the item closed" \
    "$rc $(perl -MTime::HiRes=time -e "print time - $t0 < 3 ? 'quick' : 'slow'") $(grep -c '^bn_open_item_close .*"openItem":"item_1"' "$work/requests")" "143 quick 1"
rm -f "$work/stall"

# A signal while the open is in flight (the server answers it after 3 s): the cleanup waits for its reply and closes the
# item. To bn alone, and to its whole process group (what gtimeout, `kill -- -PGID`, and a closing terminal send), which
# reaches the open's curl too.
touch "$work/stall-slow-open"
for how in TERM group-TERM group-HUP; do
    : > "$work/requests"
    BN_MCP_URL="http://127.0.0.1:$port/mcp" perl -e 'setpgrp(0, 0); exec @ARGV' "$bn" loop-il "$work/sub.o" '^_spin_other$' > /dev/null 2>&1 &
    tool=$!
    perl -MTime::HiRes=sleep -e 'for (1 .. 300) { open my $f, "<", $ARGV[0] or exit 1; exit 0 if grep { /^bn_open_item_open / } <$f>; sleep 0.01 } exit 1' "$work/requests"
    case "$how" in
        TERM) kill -TERM "$tool"; want=143 ;;
        group-TERM) kill -TERM -- "-$tool"; want=143 ;;
        group-HUP) kill -HUP -- "-$tool"; want=129 ;;
    esac
    wait "$tool"
    rc=$?
    check "$how during the open: exit $want, the item closed once the open answers" "$rc $(grep -c '^bn_open_item_close .*"openItem":"item_1"' "$work/requests")" "$want 1"
done
if command -v gtimeout > /dev/null; then
    : > "$work/requests"
    BN_MCP_URL="http://127.0.0.1:$port/mcp" gtimeout 1 "$bn" loop-il "$work/sub.o" '^_spin_other$' > /dev/null 2>&1
    rc=$?
    check "gtimeout 1, the open taking 3 s: exit 124, the item closed" "$rc $(grep -c '^bn_open_item_close .*"openItem":"item_1"' "$work/requests")" "124 1"
else
    echo "skipped: gtimeout 1 during the open (no gtimeout: brew install coreutils)"
fi

# The open (3 s) past its time limit (BN_LIMIT=2): exit 2, said (its item stays open: the reply naming it never comes).
: > "$work/requests"
BN_MCP_URL="http://127.0.0.1:$port/mcp" BN_LIMIT=2 "$bn" loop-il "$work/sub.o" '^_spin_other$' > /dev/null 2> "$work/err"
check "the open past its time limit: exit 2, said" "$? $(grep -c "didn't answer within 2 s" "$work/err")" "2 1"
rm -f "$work/stall-slow-open"
perl -MTime::HiRes=sleep -e 'sleep 1.5'   # the server still holding the open (it answers one request at a time)

# The view lookup before the open never answered: exit 2, said.
touch "$work/stall-active"
: > "$work/requests"
BN_MCP_URL="http://127.0.0.1:$port/mcp" BN_LIMIT=2 "$bn" loop-il "$work/sub.o" '^_spin_other$' > /dev/null 2> "$work/err"
check "the view lookup stalled: exit 2, said, nothing opened" \
    "$? $(grep -c "didn't answer within 2 s" "$work/err") $(grep -c '^bn_open_item_open ' "$work/requests")" "2 1 0"
# The same with stderr closed, and with stderr a pipe whose reader has gone: the message is lost, the status isn't.
BN_MCP_URL="http://127.0.0.1:$port/mcp" BN_LIMIT=1 "$bn" loop-il "$work/sub.o" '^_spin_other$' > /dev/null 2>&-
closed=$?
BN_MCP_URL="http://127.0.0.1:$port/mcp" BN_LIMIT=1 perl -e 'pipe my $r, my $w or die; close $r; open STDERR, ">&", $w or die; exec @ARGV or die' \
    "$bn" loop-il "$work/sub.o" '^_spin_other$' > /dev/null
check "the view lookup stalled, stderr closed or its reader gone: exit 2 both" "$closed $?" "2 2"
rm -f "$work/stall-active"

# The open refused (a tool error): Binary Ninja's reason said, then that it didn't open, exit 2; nothing to close.
touch "$work/stall-open-error"
: > "$work/requests"
BN_MCP_URL="http://127.0.0.1:$port/mcp" "$bn" loop-il "$work/sub.o" '^_spin_other$' > /dev/null 2> "$work/err"
check "the open refused: exit 2, the reason and the failure said, nothing closed" \
    "$? $(grep -c '^Failed to open: unsupported file$' "$work/err") $(grep -c "didn't open" "$work/err") $(grep -c '^bn_open_item_close ' "$work/requests")" "2 1 1 0"
rm -f "$work/stall-open-error"

# TERM after the open's request has ended, while bn reads its reply (a jq that takes 1 s on the reply file): the open is
# still the one kept (BN_SPARE), so the cleanup takes the handle from the reply and closes the item.
mkdir "$work/shim"
printf '#!/bin/bash\nfor a in "$@"; do [[ "$a" != */response ]] || sleep 1; done\nexec %s "$@"\n' "$(command -v jq)" > "$work/shim/jq"
chmod +x "$work/shim/jq"
: > "$work/requests"
BN_MCP_URL="http://127.0.0.1:$port/mcp" PATH="$work/shim:$PATH" "$bn" loop-il "$work/sub.o" '^_spin_other$' > /dev/null 2>&1 &
tool=$!
perl -MTime::HiRes=sleep -e 'for (1 .. 300) { open my $f, "<", $ARGV[0] or exit 1; exit 0 if grep { /^bn_open_item_open / } <$f>; sleep 0.01 } exit 1' "$work/requests"
perl -MTime::HiRes=sleep -e 'sleep 0.4'
kill -TERM "$tool"
wait "$tool"
rc=$?
check "TERM while the open's reply is read: exit 143, the item closed" "$rc $(grep -c '^bn_open_item_close .*"openItem":"item_1"' "$work/requests")" "143 1"
kill "$fake" 2> /dev/null
