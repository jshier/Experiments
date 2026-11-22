#!/usr/bin/env python3
"""Builds the small zip fixtures for NativeZip's format tests. Run make-fixtures.sh, which calls this.

Every entry records a CRC-32 computed here (or by zip), so checking it tests the decoders against data that
doesn't come from them. The 300 KB text sample is also written to the work directory (argv[2]) for the
shell script.
"""
import io
import lzma
import os
import struct
import sys
import zipfile
import zlib


def in_testdata(path):
    """Exits unless `path` is inside the repository's TestData/ (five directories above this file): the
    only place the generators write."""
    root = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), *[os.pardir] * 5, "TestData"))
    resolved = os.path.realpath(path)
    if resolved == root or os.path.commonpath([root, resolved]) != root:
        sys.exit(f"refusing to write {path} ({resolved}): only paths inside {root} are allowed")
    return path


out = in_testdata(sys.argv[1])
work = in_testdata(sys.argv[2])


def text(size, seed):
    words = [b"alpha", b"bravo", b"charlie", b"delta", b"echo", b"foxtrot", b"golf", b"hotel", b"india"]
    state = seed
    parts = []
    total = 0
    while total < size:
        state = (state * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF
        word = words[state >> 60 if (state >> 60) < len(words) else 0]
        parts.append(word + (b"\n" if state & 0x700 == 0 else b" "))
        total += len(parts[-1])
    return b"".join(parts)[:size]


def zip_with(path, method, entries, **kwargs):
    with zipfile.ZipFile(path, "w", compression=method, **kwargs) as z:
        for name, data in entries:
            z.writestr(name, data)


# --- Compression methods Python can write ---------------------------------------------------------------
sample = text(300_000, 1)
open(os.path.join(work, "sample.txt"), "wb").write(sample)
zip_with(os.path.join(out, "bzip2.zip"), zipfile.ZIP_BZIP2, [("sample.txt", sample)])
zip_with(os.path.join(out, "lzma.zip"), zipfile.ZIP_LZMA, [("sample.txt", sample)])
zip_with(os.path.join(out, "zstd.zip"), zipfile.ZIP_ZSTANDARD, [("sample.txt", sample)])
# Over the 4 MB pipelining threshold, yet a small file: the sample repeated.
zip_with(os.path.join(out, "bzip2-large.zip"), zipfile.ZIP_BZIP2, [("large.txt", sample[:20_000] * 300)])


# --- Methods written by patching a stored entry's headers -----------------------------------------------
def patched(path, name, payload, data, method, flags=0):
    """A one-entry archive whose payload is `payload`, recorded as `method` decompressing to `data`, with `flags`
    ORed into its general-purpose flags."""
    zip_with(path, zipfile.ZIP_STORED, [(name, payload)])
    raw = bytearray(open(path, "rb").read())
    crc = zlib.crc32(data)
    # Local header: flags at 6, method at 8, CRC at 14, uncompressed size at 22.
    assert raw[0:4] == b"PK\x03\x04"
    struct.pack_into("<H", raw, 6, struct.unpack_from("<H", raw, 6)[0] | flags)
    struct.pack_into("<H", raw, 8, method)
    struct.pack_into("<I", raw, 14, crc)
    struct.pack_into("<I", raw, 22, len(data))
    # Central header: flags at 8, method at 10, CRC at 16, uncompressed size at 24.
    central = raw.rfind(b"PK\x01\x02")
    struct.pack_into("<H", raw, central + 8, struct.unpack_from("<H", raw, central + 8)[0] | flags)
    struct.pack_into("<H", raw, central + 10, method)
    struct.pack_into("<I", raw, central + 16, crc)
    struct.pack_into("<I", raw, central + 24, len(data))
    open(path, "wb").write(raw)


def zipcrypto(payload, password, check):
    """`payload` encrypted with the traditional PKWARE cipher (APPNOTE 6.1), after its 12-byte header ending in
    `check` (the CRC's high byte). The header's random bytes are fixed, so the fixture is reproducible."""
    def crc(value, byte):
        return zlib.crc32(bytes([byte]), value ^ 0xFFFFFFFF) ^ 0xFFFFFFFF

    keys = [0x12345678, 0x23456789, 0x34567890]

    def update(byte):
        keys[0] = crc(keys[0], byte)
        keys[1] = ((keys[1] + (keys[0] & 0xFF)) * 134775813 + 1) & 0xFFFFFFFF
        keys[2] = crc(keys[2], keys[1] >> 24)

    for byte in password:
        update(byte)
    out = bytearray()
    for byte in bytes(range(11)) + bytes([check]) + payload:
        t = (keys[2] | 2) & 0xFFFF
        out.append(byte ^ (((t * (t ^ 1)) >> 8) & 0xFF))
        update(byte)
    return bytes(out)


patched(os.path.join(out, "xz.zip"), "sample.txt", lzma.compress(sample, format=lzma.FORMAT_XZ), sample, 95)

# Zstandard over several of the decoder's 1 MB chunks (streamed through its window), and the same encrypted with
# the traditional cipher (decrypted in pieces as the decoder takes them).
from compression import zstd

large = text(5_000_000, 3)
zip_with(os.path.join(out, "zstd-large.zip"), zipfile.ZIP_ZSTANDARD, [("large.txt", large)])
patched(os.path.join(out, "zstd-zipcrypto.zip"), "large.txt",
        zipcrypto(zstd.compress(large), b"secret", zlib.crc32(large) >> 24), large, 93, flags=1)


def payload_of(method, data):
    """The payload and general-purpose flags `zipfile` writes for `data` compressed with `method` (for LZMA, its
    zip header and properties before the stream, and flag bit 1: the stream ends with an end marker)."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=method) as z:
        z.writestr("entry", data)
    raw = buffer.getvalue()
    assert raw[0:4] == b"PK\x03\x04"
    flags, = struct.unpack_from("<H", raw, 6)
    size, = struct.unpack_from("<I", raw, 18)
    name_length, extra_length = struct.unpack_from("<HH", raw, 26)
    start = 30 + name_length + extra_length
    return raw[start:start + size], flags & 0x6


def encrypted(path, name, method, payload, data, flags=0):
    """A one-entry archive of `payload` (decompressing to `data` with `method`), encrypted with the traditional cipher
    and the password "secret"."""
    patched(path, name, zipcrypto(payload, b"secret", zlib.crc32(data) >> 24), data, method, flags=1 | flags)


# The other methods over several of the decoder's 1 MB chunks, plain and with the traditional cipher (a decoder that
# streams its input then takes it in pieces, as it's decrypted). All of them hold `medium`, the first 3.3 MB of
# `large`: over 3 MiB, and no more, because the debug-built decoders take about a second for each 3 MB.
medium = large[:3_300_000]
zip_with(os.path.join(out, "lzma-large.zip"), zipfile.ZIP_LZMA, [("large.txt", medium)])
patched(os.path.join(out, "xz-large.zip"), "large.txt", lzma.compress(medium, format=lzma.FORMAT_XZ), medium, 95)
encrypted(os.path.join(out, "bzip2-zipcrypto.zip"), "large.txt", 12, payload_of(zipfile.ZIP_BZIP2, medium)[0], medium)
lzma_payload, lzma_flags = payload_of(zipfile.ZIP_LZMA, medium)
encrypted(os.path.join(out, "lzma-zipcrypto.zip"), "large.txt", 14, lzma_payload, medium, flags=lzma_flags)
encrypted(os.path.join(out, "xz-zipcrypto.zip"), "large.txt", 95, lzma.compress(medium, format=lzma.FORMAT_XZ), medium)

# Deflate64 with dynamic Huffman codes: zlib's raw DEFLATE, recorded as method 9. The two read a stream the same way
# except for length symbol 285 (258 in DEFLATE; 3 plus 16 extra bits in Deflate64) and distance codes 30 and 31
# (which DEFLATE never uses), so a stream with no match of length 258 is the same stream in both. `medium` has none:
# 258 repeated bytes would be about 40 repeated words of its random sequence. A stream that had one would decode to
# something else as Deflate64 and fail its CRC-32 (computed here, from `medium`), never pass by mistake.
deflater = zlib.compressobj(9, zlib.DEFLATED, -15)
deflate64_dynamic = deflater.compress(medium) + deflater.flush()
patched(os.path.join(out, "deflate64-dynamic.zip"), "large.txt", deflate64_dynamic, medium, 9)
encrypted(os.path.join(out, "deflate64-zipcrypto.zip"), "large.txt", 9, deflate64_dynamic, medium)

# A method NativeZip doesn't read: PPMd (98), its payload not a real stream.
patched(os.path.join(out, "ppmd.zip"), "sample.txt", b"\x07" * 64, sample, 98)


class BitWriter:
    """LSB-first bits, as DEFLATE writes them."""

    def __init__(self):
        self.out = bytearray()
        self.bits = 0
        self.count = 0

    def write(self, value, count):
        self.bits |= value << self.count
        self.count += count
        while self.count >= 8:
            self.out.append(self.bits & 0xFF)
            self.bits >>= 8
            self.count -= 8

    def code(self, code, length):
        # Huffman codes go most significant bit first.
        self.write(int(format(code, f"0{length}b")[::-1], 2), length)

    def finish(self):
        if self.count:
            self.out.append(self.bits & 0xFF)
        return bytes(self.out)


def fixed_literal(w, symbol):
    if symbol < 144:
        w.code(0x30 + symbol, 8)
    elif symbol < 256:
        w.code(0x190 + symbol - 144, 9)
    elif symbol < 280:
        w.code(symbol - 256, 7)
    else:
        w.code(0xC0 + symbol - 280, 8)


def deflate64_fixed(operations):
    """A one-block fixed-Huffman Deflate64 stream: operations are bytes (literals) or (length, distance)."""
    w = BitWriter()
    w.write(1, 1)  # final
    w.write(1, 2)  # fixed Huffman
    output = bytearray()
    distance_bases = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
                      2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577, 32769, 49153]
    distance_extra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
                      14, 14]
    length_bases = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131,
                    163, 195, 227, 3]
    length_extra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 16]
    for op in operations:
        if isinstance(op, (bytes, bytearray)):
            for byte in op:
                fixed_literal(w, byte)
                output.append(byte)
            continue
        length, distance = op
        # Deflate64's symbol 285 covers 3...65538 with 16 extra bits; use it for anything over 258.
        if length > 258:
            index = 28
        else:
            index = max(i for i in range(28) if length_bases[i] <= length)
        fixed_literal(w, 257 + index)
        w.write(length - length_bases[index], length_extra[index])
        dindex = max(i for i in range(32) if distance_bases[i] <= distance)
        w.code(dindex, 5)
        w.write(distance - distance_bases[dindex], distance_extra[dindex])
        start = len(output) - distance
        if length <= distance:
            output += output[start:start + length]
        else:  # Overlapping: a byte at a time.
            for _ in range(length):
                output.append(output[-distance])
    fixed_literal(w, 256)
    return w.finish(), bytes(output)


seed = text(70_000, 2)
operations = [
    seed,
    (30_000, 40_000),  # distance code 30 (32,769...49,152), length via symbol 285
    (1_000, 65_536),  # the farthest distance: code 31, all 14 extra bits set
    (65_538, 1),  # the longest match, a byte run
    (65_538, 100_000 - 64_000),
]
# Enough long matches to cross several of the decoder's 1 MB chunks.
operations += [(65_538, 65_536)] * 40
stream, data = deflate64_fixed(operations)
patched(os.path.join(out, "deflate64.zip"), "deflate64.bin", stream, data, 9)

# About 4.5 MB of fixed-Huffman Deflate64 in many shapes: short literal runs between matches of every length
# (to 65,538) at every distance (to 65,536), so matches and their history cross the decoder's 1 MB chunks
# anywhere. Seeded: the same stream every time.
import random

rng = random.Random(9)
operations = [text(70_000, 4)]
total = 70_000
while total < 4_500_000:
    operations.append(text(rng.randint(1, 120), rng.getrandbits(32)))
    total += len(operations[-1])
    distance = min(total, rng.choice([rng.randint(1, 300), rng.randint(32_769, 65_536), rng.randint(1, 65_536)]))
    length = rng.randint(3, 300) if rng.random() < 0.7 else rng.randint(259, 30_000)
    if rng.random() < 0.02:
        length = 65_538
    operations.append((length, distance))
    total += length
stream, data = deflate64_fixed(operations)
patched(os.path.join(out, "deflate64-large.zip"), "deflate64.bin", stream, data, 9)

# --- Names ------------------------------------------------------------------------------------------------
# Info-ZIP's Unicode path field: an ASCII header name, the real UTF-8 name in field 0x7075.
info = zipfile.ZipInfo("cafe.txt")
utf8 = "café.txt".encode()
info.extra = struct.pack("<HHBI", 0x7075, 5 + len(utf8), 1, zlib.crc32(b"cafe.txt")) + utf8
with zipfile.ZipFile(os.path.join(out, "unicode-path.zip"), "w") as z:
    z.writestr(info, b"unicode path\n")

# Backslashes from an MS-DOS host.
info = zipfile.ZipInfo("dir\\sub\\dos.txt")
info.create_system = 0
with zipfile.ZipFile(os.path.join(out, "dos-backslash.zip"), "w") as z:
    z.writestr(info, b"dos\n")

# Unsafe names: absolute, and with "..".
with zipfile.ZipFile(os.path.join(out, "unsafe-paths.zip"), "w") as z:
    z.writestr("/abs/root.txt", b"absolute\n")
    z.writestr("../../escape.txt", b"escape\n")
    z.writestr("a/../../b/inner.txt", b"inner\n")
    z.writestr("ok.txt", b"fine\n")

# One name twice, and two names a case-insensitive volume treats as one.
import warnings

with warnings.catch_warnings():
    warnings.simplefilter("ignore")
    with zipfile.ZipFile(os.path.join(out, "duplicates.zip"), "w") as z:
        z.writestr("same.txt", b"first\n")
        z.writestr("same.txt", b"second\n")
        z.writestr("Case.txt", b"upper\n")
        z.writestr("case.txt", b"lower\n")
