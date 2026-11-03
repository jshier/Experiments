#!/usr/bin/env python3
"""Condense `swift package benchmark baseline compare A B` output into one p50 row per benchmark.

Usage: swift package --disable-sandbox benchmark baseline compare A B --no-progress | python3 -I Benchmarks/summarize.py
"""
import re
import sys

ansi = re.compile(r"\x1b\[[0-9;]*m")
wanted = {
    "Time (wall clock)": "wall",
    "Time (total CPU)": "cpu",
    "Instructions": "instr",
    "Malloc (total)": "malloc",
}
rows = {}  # benchmark -> {metric: (unit, a, b)}
benchmark = metric = unit = None
values = []

for raw in sys.stdin:
    line = ansi.sub("", raw).rstrip("\n")
    if m := re.match(r"^(.+?) metrics\s*$", line):
        benchmark = m.group(1).strip()
        continue
    if m := re.match(r"^│\s*(.+?)\s*\*?\s*│\s*p0\s*│", line):
        title = m.group(1).strip()
        metric = next((key for key in wanted if title.startswith(key)), None)
        rest = title[len(metric):].strip() if metric else ""
        unit = rest[1:-1] if rest.startswith("(") and rest.endswith(")") else ""
        values = []
        continue
    if metric and (m := re.match(r"^│\s*(\S+)\s*│(.*)$", line)):
        cells = [c.strip() for c in m.group(2).split("│")]
        if len(cells) >= 3 and m.group(1) not in ("Δ", "Improvement"):
            values.append(cells[2])  # p50
            if len(values) == 2:
                rows.setdefault(benchmark, {})[wanted[metric]] = (unit, *values)
                metric = None

def fmt(entry):
    if not entry:
        return "-"
    unit, a, b = entry
    try:
        change = (float(b) - float(a)) / float(a) * 100 if float(a) else 0
        return f"{a} → {b} {unit} ({change:+.0f}%)"
    except ValueError:
        return f"{a} → {b} {unit}"

print(f"{'Benchmark':<48} {'Wall clock p50':<30} {'Instructions p50':<30} {'Mallocs p50':<26} {'CPU p50'}")
for name in sorted(rows):
    r = rows[name]
    print(f"{name:<48} {fmt(r.get('wall')):<30} {fmt(r.get('instr')):<30} {fmt(r.get('malloc')):<26} {fmt(r.get('cpu'))}")
