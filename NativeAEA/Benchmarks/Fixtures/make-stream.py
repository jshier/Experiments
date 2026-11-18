"""Writes an Apple Archive stream laid out like Xcode's: the same fields per entry (TYP1 PAT_P UID1 GID1 MOD2,
DATA|DATB FLG1 AFT1 for files, LNKP for links), every file marked for APFS compression (AFT 14, FLG 0x20), and
sizes drawn from Xcode 27.3 beta 2's distribution (54% under 4 KiB, 38% under 64 KiB, 7% under 1 MiB, the rest
larger, though smaller than Xcode's largest). Contents are deterministic: text (compressible), binary-like (partly), and random (not).

Usage: python3 -I make-stream.py OUTPUT.aar   (OUTPUT must be inside the repository's TestData/)
"""
import os
import random
import struct
import sys


def in_testdata(path):
    """Exits unless `path` is inside the repository's TestData/ (four directories above this file)."""
    root = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), *[os.pardir] * 3, "TestData"))
    resolved = os.path.realpath(path)
    if resolved == root or os.path.commonpath([root, resolved]) != root:
        sys.exit(f"refusing to write {path} ({resolved}): only paths inside {root} are allowed")
    return path


out = in_testdata(sys.argv[1])
rng = random.Random(27_3_2)
WORDS = [w.encode() for w in "struct class func let var import return guard if else switch case public internal".split()]


def entry(fields, blobs=b""):
    header = b"AA01" + struct.pack("<H", 6 + len(fields)) + fields
    return header + blobs


def common(kind, path, mode):
    p = path.encode()
    return b"TYP1" + kind + b"PATP" + struct.pack("<H", len(p)) + p + b"UID1\x00GID1\x00MOD2" + struct.pack("<H", mode)


def contents(size):
    kind = rng.random()
    if kind < 0.5:  # Text: headers, sources, plists.
        words = []
        total = 0
        while total < size:
            word = rng.choice(WORDS)
            words.append(word)
            total += len(word) + 1
        return b" ".join(words)[:size]
    if kind < 0.95:  # Binary-like: low-entropy runs (a small alphabet, like instruction encodings) and zero padding.
        alphabet = rng.randbytes(24)
        parts = []
        total = 0
        while total < size:
            run = rng.randrange(64, 4096)
            parts.append(bytes(rng.choices(alphabet, k=run)) if rng.random() < 0.7 else bytes(run))
            total += run
        return b"".join(parts)[:size]
    return rng.randbytes(size)  # Already compressed: images, archives.


def size():
    bucket = rng.random()
    if bucket < 0.54:
        return rng.randrange(0, 4096)
    if bucket < 0.92:
        return rng.randrange(4096, 65536)
    if bucket < 0.99:
        return rng.randrange(65536, 1 << 20)
    if bucket < 0.999:
        return rng.randrange(1 << 20, 6 << 20)
    return rng.randrange(16 << 20, 24 << 20)


with open(out, "wb") as stream:
    stream.write(entry(common(b"D", "Synthetic.app", 0o755)))
    files = 0
    for framework in range(60):
        base = f"Synthetic.app/Contents/Frameworks/F{framework}.framework"
        for directory in ["", "/Versions", "/Versions/A", "/Versions/A/Resources", "/Versions/A/Headers"]:
            if framework == 0 and directory == "":
                stream.write(entry(common(b"D", "Synthetic.app/Contents", 0o755)))
                stream.write(entry(common(b"D", "Synthetic.app/Contents/Frameworks", 0o755)))
            stream.write(entry(common(b"D", base + directory, 0o755)))
        stream.write(entry(common(b"L", base + "/Resources", 0o755) + b"LNKP" + struct.pack("<H", 26) + b"Versions/Current/Resources"))
        for index in range(500):
            folder = "Headers" if index % 2 else "Resources"
            data = contents(size())
            dat = b"DATA" + struct.pack("<H", len(data)) if len(data) < 65536 else b"DATB" + struct.pack("<I", len(data))
            fields = common(b"F", f"{base}/Versions/A/{folder}/file{index}", 0o644 if index % 7 else 0o755) + dat + b"FLG1\x20AFT1\x0e"
            stream.write(entry(fields, data))
            files += 1
print(f"{files} files", file=sys.stderr)
