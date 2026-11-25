#!/usr/bin/env python3
"""Writes a manifest of the tree under ROOT: what an extraction made, item by item, without the bytes.

    manifest.py ROOT OUTPUT [--now-after SECONDS] [--ignore NAME]...

One JSON object: `ignoredAttributes` (left out of every item), `nowAfter`, and `items`, sorted by the paths' bytes. Each
item has `path` (relative to ROOT, as the directory lists it: NFC and NFD stay as they are), `type` (directory, file,
symbolicLink, fifo, other), `mode` (octal, setuid/setgid/sticky included), `flags` (st_flags), `mtime` ("SECONDS.NNNNNNNNN",
or "now" for a time at or after `--now-after`: one the extraction set), and as they apply `size` and `sha256` (files),
`target` (links), `xattrs` (name: size and SHA-256 of the value, not following links; APFS compression's own
attributes are hidden, as listxattr hides them), `acl` (acl_to_text's text, for items with an extended ACL), and `links`
(every path of a file with more than one name in the tree, sorted).

DiskTestSupport's `TreeManifest` reads this format and makes the same from a tree in Swift (the tests compare an
extraction with the manifest made at generation time). OUTPUT must be inside the repository's TestData/; ROOT is only
read.
"""
import ctypes
import hashlib
import json
import os
import stat
import sys


def in_testdata(path):
    """Exits unless `path` is inside the repository's TestData/ (three directories above this file's)."""
    root = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), *[os.pardir] * 3, "TestData"))
    resolved = os.path.join(os.path.realpath(os.path.dirname(os.path.abspath(path))), os.path.basename(path))
    if resolved == root or os.path.commonpath([root, resolved]) != root:
        sys.exit(f"refusing to write {path} ({resolved}): only paths inside {root} are allowed")
    return path


libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
libc.acl_get_link_np.restype = ctypes.c_void_p
libc.acl_get_link_np.argtypes = [ctypes.c_char_p, ctypes.c_int]
libc.acl_to_text.restype = ctypes.c_void_p
libc.acl_to_text.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
libc.acl_free.argtypes = [ctypes.c_void_p]
ACL_TYPE_EXTENDED = 0x00000100
# Python's os.listxattr and os.getxattr are Linux's only: Darwin's, not following a link (XATTR_NOFOLLOW).
libc.listxattr.restype = ctypes.c_ssize_t
libc.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
libc.getxattr.restype = ctypes.c_ssize_t
libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
XATTR_NOFOLLOW = 1


def attribute_names(path):
    size = libc.listxattr(path, None, 0, XATTR_NOFOLLOW)
    if size <= 0:
        return []
    buffer = ctypes.create_string_buffer(size)
    size = libc.listxattr(path, buffer, size, XATTR_NOFOLLOW)
    if size < 0:
        sys.exit(f"listxattr {path!r}: {os.strerror(ctypes.get_errno())}")
    return [name.decode() for name in buffer.raw[:size].split(b"\0") if name]


def attribute(path, name):
    size = libc.getxattr(path, name.encode(), None, 0, 0, XATTR_NOFOLLOW)
    if size < 0:
        sys.exit(f"getxattr {path!r} {name}: {os.strerror(ctypes.get_errno())}")
    buffer = ctypes.create_string_buffer(max(size, 1))
    size = libc.getxattr(path, name.encode(), buffer, size, 0, XATTR_NOFOLLOW)
    if size < 0:
        sys.exit(f"getxattr {path!r} {name}: {os.strerror(ctypes.get_errno())}")
    return buffer.raw[:size]


def acl_text(path):
    acl = libc.acl_get_link_np(os.fsencode(path), ACL_TYPE_EXTENDED)
    if not acl:
        return None
    try:
        text = libc.acl_to_text(acl, None)
        if not text:
            return None
        try:
            return ctypes.string_at(text).decode()
        finally:
            libc.acl_free(text)
    finally:
        libc.acl_free(acl)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def kind(mode):
    if stat.S_ISDIR(mode):
        return "directory"
    if stat.S_ISREG(mode):
        return "file"
    if stat.S_ISLNK(mode):
        return "symbolicLink"
    if stat.S_ISFIFO(mode):
        return "fifo"
    return "other"


def manifest(root, now_after, ignored):
    root_bytes = os.fsencode(root)
    paths = []
    for directory, names, files in os.walk(root_bytes):
        for name in names + files:
            paths.append(os.path.relpath(os.path.join(directory, name), root_bytes))
    paths.sort()
    items, inodes = [], {}
    for relative in paths:
        path = os.path.join(root_bytes, relative)
        info = os.lstat(path)
        item = {"path": os.fsdecode(relative), "type": kind(info.st_mode), "mode": f"{stat.S_IMODE(info.st_mode):04o}",
                "flags": info.st_flags}
        mtime = info.st_mtime_ns
        item["mtime"] = "now" if now_after is not None and mtime >= now_after * 1_000_000_000 else \
            f"{mtime // 1_000_000_000}.{mtime % 1_000_000_000:09d}"
        if item["type"] == "file":
            item["size"] = info.st_size
            item["sha256"] = sha256_file(path)
            inodes.setdefault(info.st_ino, []).append(item)
        if item["type"] == "symbolicLink":
            item["target"] = os.fsdecode(os.readlink(path))
        attributes = {}
        for name in attribute_names(path):
            if name in ignored:
                continue
            value = attribute(path, name)
            attributes[name] = {"size": len(value), "sha256": hashlib.sha256(value).hexdigest()}
        if attributes:
            item["xattrs"] = dict(sorted(attributes.items()))
        if (text := acl_text(path)) is not None:
            item["acl"] = text
        items.append(item)
    for group in inodes.values():
        if len(group) > 1:
            names = sorted((item["path"] for item in group), key=os.fsencode)
            for item in group:
                item["links"] = names
    return {"ignoredAttributes": sorted(ignored), "nowAfter": now_after, "items": items}


def main(arguments):
    if len(arguments) < 2:
        sys.exit(__doc__)
    root, output = arguments[0], in_testdata(arguments[1])
    now_after, ignored = None, {"com.apple.provenance", "com.apple.quarantine"}
    rest = arguments[2:]
    while rest:
        if rest[0] == "--now-after" and len(rest) > 1:
            now_after = int(rest[1])
        elif rest[0] == "--ignore" and len(rest) > 1:
            ignored.add(rest[1])
        else:
            sys.exit(__doc__)
        rest = rest[2:]
    with open(output, "w", encoding="utf-8") as f:
        json.dump(manifest(root, now_after, ignored), f, ensure_ascii=False, indent=1)
        f.write("\n")


if __name__ == "__main__":
    main(sys.argv[1:])
