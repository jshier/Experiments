#!/usr/bin/env python3
"""Makes the LZMA (zip method 14) test vectors for LZMADecoderTests. Run through make-lzma-vectors.sh.

Each vector is a zip method-14 payload (`NAME.lzma`): version bytes, the properties size (5, UInt16 LE),
the properties (the lc/lp/pb byte and the dictionary size, UInt32 LE), then a raw LZMA1 stream from
liblzma's LZMA1EXT encoder, with or without the end marker. Python's lzma module can't make streams
without the end marker, so liblzma is called through ctypes.

The uncompressed inputs aren't stored: they come from generators that LZMADecoderTests.swift repeats
(SplitMix64, the same word list), named with their sizes and seeds in `vectors.tsv`.

Usage: make-lzma-vectors.py LIBLZMA OUTPUT_DIR
       make-lzma-vectors.py LIBLZMA --payload INPUT OUTPUT [--dict SIZE] [--marker]  (one file, for measuring)
"""

import ctypes
import os
import struct
import sys

MASK = (1 << 64) - 1


class SplitMix64:
    def __init__(self, seed):
        self.state = seed

    def next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK
        return z ^ (z >> 31)


WORDS = [b"swift", b"byte", b"span", b"lzma", b"range", b"coder", b" ", b"\n", b"the", b"a",
         b"dictionary", b"match", b"literal", b"probability", b", ", b"."]


def text(n, rng):
    """Words picked at random: literals and short matches."""
    out = bytearray()
    while len(out) < n:
        out += WORDS[rng.next() % len(WORDS)]
    return bytes(out[:n])


def random_bytes(n, rng):
    """Incompressible: literals, and matched literals after the rare match."""
    return bytes(rng.next() & 0xFF for _ in range(n))


def runs(n, rng):
    """Long runs: distance-1 matches of the longest length."""
    return bytes((i // 1000) % 3 for i in range(n))


def records(n, rng):
    """Little-endian UInt32s that mostly count up by 7: what lp and pb are for."""
    out = bytearray()
    i = 0
    while len(out) < n:
        out += struct.pack("<I", (i * 7 + (rng.next() & 3)) & 0xFFFFFFFF)
        i += 1
    return bytes(out[:n])


def sentences(n, rng):
    """32 sentences of words, repeated at random, with some random bytes: long matches at all distances."""
    table = []
    for _ in range(32):
        sentence = bytearray()
        for _ in range(5 + rng.next() % 11):
            sentence += WORDS[rng.next() % len(WORDS)]
        table.append(bytes(sentence))
    out = bytearray()
    while len(out) < n:
        if rng.next() % 512 == 0:
            out += random_bytes(1 + rng.next() % 64, rng)
        else:
            out += table[rng.next() % len(table)]
    return bytes(out[:n])


GENERATORS = {"text": text, "random": random_bytes, "runs": runs, "records": records, "sentences": sentences}

# name, generator, size, seed, lc, lp, pb, dictionary size, end marker, preset
VECTORS = [
    ("empty-marker", "text", 0, 1, 3, 0, 2, 1 << 16, True, 6),
    ("empty-nomarker", "text", 0, 1, 3, 0, 2, 1 << 16, False, 6),
    ("one-marker", "text", 1, 2, 3, 0, 2, 1 << 16, True, 6),
    ("one-nomarker", "text", 1, 2, 3, 0, 2, 1 << 16, False, 6),
    ("text-marker", "text", 200_000, 3, 3, 0, 2, 1 << 20, True, 6),
    ("text-nomarker", "text", 200_000, 3, 3, 0, 2, 1 << 20, False, 6),
    ("text-fast", "text", 100_000, 4, 3, 0, 2, 1 << 20, False, 1),
    ("random", "random", 16_384, 5, 3, 0, 2, 1 << 16, True, 6),
    ("runs", "runs", 100_000, 6, 3, 0, 2, 1 << 16, False, 9),
    ("records-lc0-lp0-pb0", "records", 65_536, 7, 0, 0, 0, 1 << 16, True, 6),
    ("records-lc4-lp0-pb4", "records", 65_536, 8, 4, 0, 4, 1 << 16, False, 6),
    ("records-lc0-lp4-pb0", "records", 65_536, 9, 0, 4, 0, 1 << 16, True, 6),
    ("records-lc1-lp3-pb1", "records", 65_536, 10, 1, 3, 1, 1 << 16, False, 6),
    ("records-lc2-lp2-pb3", "records", 65_536, 11, 2, 2, 3, 1 << 16, True, 6),
    ("records-lc0-lp2-pb2", "records", 65_536, 12, 0, 2, 2, 1 << 16, False, 6),
    # Larger than the dictionary: the window wraps, and matches reach across the wrap.
    ("sentences-3m-dict64k", "sentences", 3 << 20, 13, 3, 0, 2, 1 << 16, False, 6),
    ("sentences-1m-dict4k", "sentences", 1 << 20, 14, 3, 0, 2, 4096, True, 6),
    ("sentences-1m-lc1-lp1-pb1", "sentences", 1 << 20, 15, 1, 1, 1, 1 << 20, True, 9),
]


class Options(ctypes.Structure):
    """lzma_options_lzma (lzma/lzma12.h)."""
    _fields_ = [
        ("dict_size", ctypes.c_uint32), ("preset_dict", ctypes.c_void_p), ("preset_dict_size", ctypes.c_uint32),
        ("lc", ctypes.c_uint32), ("lp", ctypes.c_uint32), ("pb", ctypes.c_uint32), ("mode", ctypes.c_int),
        ("nice_len", ctypes.c_uint32), ("mf", ctypes.c_int), ("depth", ctypes.c_uint32),
        ("ext_flags", ctypes.c_uint32), ("ext_size_low", ctypes.c_uint32), ("ext_size_high", ctypes.c_uint32),
        ("reserved_int4", ctypes.c_uint32), ("reserved_int5", ctypes.c_uint32), ("reserved_int6", ctypes.c_uint32),
        ("reserved_int7", ctypes.c_uint32), ("reserved_int8", ctypes.c_uint32),
        ("reserved_enum1", ctypes.c_int), ("reserved_enum2", ctypes.c_int), ("reserved_enum3", ctypes.c_int),
        ("reserved_enum4", ctypes.c_int), ("reserved_ptr1", ctypes.c_void_p), ("reserved_ptr2", ctypes.c_void_p),
    ]


class Filter(ctypes.Structure):
    """lzma_filter (lzma/filter.h)."""
    _fields_ = [("id", ctypes.c_uint64), ("options", ctypes.c_void_p)]


LZMA_FILTER_LZMA1EXT = 0x4000000000000002
LZMA_VLI_UNKNOWN = MASK
LZMA_LZMA1EXT_ALLOW_EOPM = 1


def filters(options):
    chain = (Filter * 2)()
    chain[0].id = LZMA_FILTER_LZMA1EXT
    chain[0].options = ctypes.cast(ctypes.pointer(options), ctypes.c_void_p)
    chain[1].id = LZMA_VLI_UNKNOWN
    return chain


def compress(lib, data, lc, lp, pb, dict_size, marker, preset):
    options = Options()
    if lib.lzma_lzma_preset(ctypes.byref(options), preset):
        sys.exit(f"preset {preset} unsupported")
    options.lc, options.lp, options.pb, options.dict_size = lc, lp, pb, dict_size
    options.ext_flags = LZMA_LZMA1EXT_ALLOW_EOPM if marker else 0
    size = len(data) + len(data) // 2 + 1024
    out = ctypes.create_string_buffer(size)
    out_pos = ctypes.c_size_t(0)
    status = lib.lzma_raw_buffer_encode(filters(options), None, data, ctypes.c_size_t(len(data)), out,
                                        ctypes.byref(out_pos), ctypes.c_size_t(size))
    if status != 0:
        sys.exit(f"lzma_raw_buffer_encode: {status}")
    stream = out.raw[:out_pos.value]

    # Check it with liblzma's decoder, told whether to expect the marker.
    options.ext_size_low, options.ext_size_high = len(data) & 0xFFFFFFFF, len(data) >> 32
    decoded = ctypes.create_string_buffer(len(data) + 1)
    in_pos, decoded_pos = ctypes.c_size_t(0), ctypes.c_size_t(0)
    status = lib.lzma_raw_buffer_decode(filters(options), None, stream, ctypes.byref(in_pos),
                                        ctypes.c_size_t(len(stream)), decoded, ctypes.byref(decoded_pos),
                                        ctypes.c_size_t(len(data) + 1))
    if status != 0 or decoded.raw[:decoded_pos.value] != data or in_pos.value != len(stream):
        sys.exit(f"liblzma didn't decode its own stream: {status}")

    header = bytes([9, 20]) + struct.pack("<H", 5)  # The LZMA SDK version 7-Zip writes, then the size.
    header += bytes([(pb * 5 + lp) * 9 + lc]) + struct.pack("<I", dict_size)
    return header + stream


def in_testdata(path):
    """Exits unless `path` is inside the repository's TestData/ (five directories above this file): the
    only place the generators write."""
    root = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), *[os.pardir] * 5, "TestData"))
    resolved = os.path.realpath(path)
    if resolved == root or os.path.commonpath([root, resolved]) != root:
        sys.exit(f"refusing to write {path} ({resolved}): only paths inside {root} are allowed")
    return path


def main():
    lib = ctypes.CDLL(sys.argv[1])
    lib.lzma_lzma_preset.restype = ctypes.c_uint8
    if sys.argv[2] == "--payload":
        source, destination = sys.argv[3], in_testdata(sys.argv[4])
        dict_size = int(sys.argv[sys.argv.index("--dict") + 1]) if "--dict" in sys.argv else 8 << 20
        with open(source, "rb") as f:
            data = f.read()
        payload = compress(lib, data, 3, 0, 2, dict_size, "--marker" in sys.argv, 6)
        with open(destination, "wb") as f:
            f.write(payload)
        print(f"{source}: {len(data)} -> {len(payload)} bytes")
        return

    directory = in_testdata(sys.argv[2])
    manifest = ["# name\tgenerator\tsize\tseed\tlc\tlp\tpb\tdictionary\tmarker"]
    for name, generator, size, seed, lc, lp, pb, dict_size, marker, preset in VECTORS:
        data = GENERATORS[generator](size, SplitMix64(seed))
        payload = compress(lib, data, lc, lp, pb, dict_size, marker, preset)
        with open(os.path.join(directory, name + ".lzma"), "wb") as f:
            f.write(payload)
        manifest.append(f"{name}\t{generator}\t{size}\t{seed}\t{lc}\t{lp}\t{pb}\t{dict_size}\t{int(marker)}")
        print(f"{name}: {size} -> {len(payload)} bytes")
    with open(os.path.join(directory, "vectors.tsv"), "w") as f:
        f.write("\n".join(manifest) + "\n")


main()
