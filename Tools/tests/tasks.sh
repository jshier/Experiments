#!/bin/bash
# Tools/tasks (Instruments; no prompt once attaching is approved): each pool thread keeps its id, so tasks that hop
# show several threads and thread switches; --keep replaces an earlier recording; an interrupted tool leaves no
# xctrace or program behind. About 40 s (a Swift build and two short recordings).
set -u
tool="$(cd "$(dirname "$0")/.." && pwd)/tasks"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-tasks.XXXXXX")"
cleanup() {
    pkill -KILL -f "$work/hops-debuggable" 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }

cat > "$work/hops.swift" <<'EOF'
// N tasks, each calling an actor M times with a sleep between: every call and wake-up can land on another thread.
actor Counter {
    var value = 0
    func bump() -> Int { value += 1; return value }
}

@main
struct Hops {
    static func main() async {
        let counter = Counter()
        let args = CommandLine.arguments
        let tasks = args.count > 1 ? Int(args[1]) ?? 4 : 4
        let calls = args.count > 2 ? Int(args[2]) ?? 20 : 20
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<tasks {
                group.addTask {
                    var last = 0
                    for _ in 0..<calls {
                        last = await counter.bump()
                        try? await Task.sleep(for: .milliseconds(1))
                    }
                    return last
                }
            }
            var total = 0
            for await value in group { total += value }
            print(total)
        }
    }
}
EOF
xcrun swiftc -O -parse-as-library -module-name Hops -o "$work/hops" "$work/hops.swift" || exit 1
mkdir -p "$work/old.trace"
touch "$work/old.trace/form.template"

out="$("$tool" --keep "$work/old.trace" -- "$work/hops" 4 20 2> "$work/err")"
rc=$?
[[ $rc == 0 ]] || { echo "the tool's stderr:"; cat "$work/err"; }
check "exit status" "$rc" 0
check "--keep replaced the earlier recording" "$([[ -d "$work/old.trace/Trace1.run" ]] && echo yes || echo no)" yes
workers="$(echo "$out" | sed -n '/^== tasks/,/^== threads/p' | grep -E '^closure #1 in static Hops.main\(\) \([0-9]+\)' | cut -f4,5)"
check "four worker tasks" "$(echo "$workers" | grep -c .)" 4
check "each ran on more than one thread" "$(echo "$workers" | perl -ane '$ok++ if $F[0] > 1; END { print $ok + 0 }')" 4
check "and switched threads" "$(echo "$workers" | perl -ane '$ok++ if $F[1] > 1; END { print $ok + 0 }')" 4
threads="$(echo "$out" | sed -n '/^== threads/,/^== totals/p' | grep -c ' (0x[0-9a-f]*)'$'\t')"
check "several threads, each with its id" "$(( threads > 1 ))" 1

"$tool" --timeout 120 -- "$work/hops" 2 100000 > /dev/null 2>&1 &
recorder=$!
for ((i = 0; i < 40; i++)); do
    pgrep -f "^$work/hops-debuggable 2 100000" > /dev/null && break # the program itself, not xctrace's command line
    sleep 0.5
done
# TERM: a job started with & from a script has INT ignored. with_timeout stops the recording's tree, then the tool
# ends by the signal.
kill -TERM "$recorder"
wait "$recorder"
check "interrupted by TERM: exit 143" "$?" 143
sleep 1
pgrep -f "$work/hops-debuggable" > /dev/null
check "interrupted: the program was stopped" "$?" 1
check "interrupted: no xctrace left for it" "$(pgrep -fl xctrace | grep -c "$work")" 0

for limit in 5x 08s 0 9999999999h; do
    "$tool" --time-limit "$limit" -- "$work/hops" > /dev/null 2>&1
    check "--time-limit $limit exits 2" "$?" 2
done

# A program with no Swift concurrency leaves an empty table: exit 2 with the reason, not empty tables and 0.
printf 'int main(void) { return 0; }\n' > "$work/plain.c"
xcrun clang -o "$work/plain" "$work/plain.c" || exit 1
"$tool" -- "$work/plain" > "$work/out" 2> "$work/err"
check "no task states: exit 2" "$?" 2
check "no task states: nothing on stdout" "$(wc -c < "$work/out" | tr -d ' ')" 0
check "no task states: says why" "$(grep -c 'no Swift task states' "$work/err")" 1
