#!/usr/bin/env python3
"""Builds the source trees the archive-coverage set's archives are made from (make-archives.sh runs it).

    make-tree.py main ROOT STAGE        the coverage tree: shapes, names, links, metadata, APFS-compressed files
    make-tree.py collisions ROOT        names that differ only by case (ROOT on a case-sensitive volume)

Everything is deterministic: the same names, contents, extended attributes, ACLs, modes, flags, and modification
times every run (from fixed seeds and a fixed epoch). What the system adds isn't: `com.apple.provenance` in a
provenance-tracked session, birth and change times, owners. STAGE is a scratch directory for the APFS-compressed
files (made by `aa extract -afsc`). ROOT and STAGE must be inside the repository's TestData/.
"""
import ctypes
import os
import random
import subprocess
import sys
import unicodedata


def in_testdata(path):
    """Exits unless `path` is inside the repository's TestData/ (three directories above this file's): the only
    place the generators write."""
    root = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), *[os.pardir] * 3, "TestData"))
    # The parent resolved, not the last component: a symbolic link is checked where it is, not where it points.
    resolved = os.path.join(os.path.realpath(os.path.dirname(os.path.abspath(path))), os.path.basename(path))
    if resolved == root or os.path.commonpath([root, resolved]) != root:
        sys.exit(f"refusing to write {path} ({resolved}): only paths inside {root} are allowed")
    return path


libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
libc.setxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]

WORDS = [b"alpha", b"bravo", b"charlie", b"delta", b"echo", b"foxtrot", b"golf", b"hotel", b"india", b"juliet",
         b"kilo", b"lima", b"mike", b"november", b"oscar", b"papa", b"quebec", b"romeo", b"sierra", b"tango"]

# Every item's modification time: 2020-09-13 plus a step per item, with nanoseconds.
EPOCH = 1_600_000_000


def text(rng, size):
    """Compressible text: words from a small vocabulary, lines of varied length."""
    parts, total = [], 0
    while total < size:
        word = WORDS[rng.randrange(len(WORDS))]
        part = word + (b"\n" if rng.randrange(9) == 0 else b" ")
        parts.append(part)
        total += len(part)
    return b"".join(parts)[:size]


def random_bytes(rng, size):
    """Incompressible bytes."""
    return rng.randbytes(size)


class Tree:
    def __init__(self, root):
        self.root = in_testdata(root)
        os.makedirs(self.root, exist_ok=True)

    def path(self, relative):
        return in_testdata(os.path.join(self.root, relative))

    def directory(self, relative):
        os.makedirs(self.path(relative), exist_ok=True)

    def file(self, relative, data):
        path = self.path(relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)

    def symlink(self, relative, target):
        path = self.path(relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        os.symlink(target, path)

    def hardlink(self, relative, existing):
        path = self.path(relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        os.link(self.path(existing), path, follow_symlinks=False)

    def xattr(self, relative, name, value):
        # Python's os.setxattr is Linux's only: Darwin's, not following a link (XATTR_NOFOLLOW).
        path = os.fsencode(self.path(relative))
        if libc.setxattr(path, name.encode(), value, len(value), 0, 1) != 0:
            sys.exit(f"setxattr {relative} {name}: {os.strerror(ctypes.get_errno())}")

    def acl(self, relative, entry):
        subprocess.run(["/bin/chmod", "-h", "+a", entry, self.path(relative)], check=True)

    def mode(self, relative, mode):
        os.chmod(self.path(relative), mode, follow_symlinks=False)

    def flags(self, relative, flags):
        os.chflags(self.path(relative), flags, follow_symlinks=False)

    def set_times(self):
        """Every item's modification and access time, deepest first (a directory's after its contents'), in the order
        of the sorted relative paths' bytes."""
        items = []
        for directory, names, files in os.walk(self.root):
            for name in names + files:
                items.append(os.path.relpath(os.path.join(directory, name), self.root))
        items.sort(key=os.fsencode)
        times = {item: EPOCH + index * 37 for index, item in enumerate(items)}
        for index, item in sorted(enumerate(items), key=lambda pair: -pair[1].count(os.sep)):
            ns = times[item] * 1_000_000_000 + (index * 7_919_000 + 123) % 1_000_000_000
            os.utime(self.path(item), ns=(ns, ns), follow_symlinks=False)
        # The root too: `aa archive -d` archives an entry for it, and `ditto --keepParent` a directory.
        os.utime(self.root, ns=(EPOCH * 1_000_000_000,) * 2)


def compressed_files(tree, stage, rng):
    """APFS-compressed (`decmpfs`) files, one directory per codec, made by `aa extract -afsc CODEC -afsc-all` from a
    staging archive: small files kept in the `decmpfs` attribute, larger ones in the resource fork, and an
    incompressible one each codec leaves plain."""
    stage = in_testdata(stage)
    for codec in ["zlib", "lzvn", "lzfse", "lzbitmap"]:
        source = in_testdata(os.path.join(stage, codec))
        os.makedirs(source)
        for name, data in [
            ("inline.txt", text(rng, 1_500)),
            ("fork.txt", text(rng, 150_000)),
            ("multi-chunk.txt", text(rng, 700_000)),
            ("incompressible.bin", random_bytes(rng, 100_000)),
        ]:
            with open(in_testdata(os.path.join(source, name)), "wb") as f:
                f.write(data)
        archive = in_testdata(os.path.join(stage, codec + ".aar"))
        subprocess.run(["/usr/bin/aa", "archive", "-a", "raw", "-d", source, "-o", archive], check=True)
        tree.directory("compressed/" + codec)  # `aa extract -d` needs it there.
        subprocess.run(["/usr/bin/aa", "extract", "-i", archive, "-d", tree.path("compressed/" + codec),
                        "-afsc", codec, "-afsc-all"], check=True)
        for name, expected in [("inline.txt", True), ("fork.txt", True), ("multi-chunk.txt", True),
                               ("incompressible.bin", False)]:
            flags = os.lstat(tree.path(f"compressed/{codec}/{name}")).st_flags
            if bool(flags & 0x20) != expected:  # UF_COMPRESSED
                sys.exit(f"compressed/{codec}/{name}: UF_COMPRESSED is {bool(flags & 0x20)}, expected {expected}")


def main_tree(root, stage):
    tree = Tree(root)
    rng = random.Random(20261124)

    # Many small files: 2,000 in 40 directories, 0–3,000 bytes, a fifth of them incompressible.
    for d in range(40):
        for f in range(50):
            size = rng.choice([0, 1, 2, 17, 100, 511, 512, 513, 1_000, 2_000, 3_000, rng.randrange(3_000)])
            data = random_bytes(rng, size) if rng.randrange(5) == 0 else text(rng, size)
            tree.file(f"small/d{d:02}/f{f:03}.txt", data)

    # A few large files: text over a 4 MiB block, incompressible bytes, zeros.
    tree.file("large/text.txt", text(rng, 5_000_000 + 4_321))
    tree.file("large/random.bin", random_bytes(rng, 2_000_000 + 1_234))
    tree.file("large/zeros.bin", bytes(1_048_577))

    # A deep tree: 24 levels.
    deep = "/".join(f"level-{n:02}" for n in range(1, 25))
    tree.file(f"deep/{deep}/leaf.txt", text(rng, 300))
    tree.file("deep/level-01/level-02/middle.txt", text(rng, 300))

    # Long names: 255 bytes (NAME_MAX), in ASCII and in 3-byte UTF-8, and a relative path of about 800 bytes.
    tree.file("long-names/" + "n" * 251 + ".txt", b"longest ASCII name\n")
    tree.file("long-names/" + "語" * 85, b"longest UTF-8 name\n")
    long_path = "/".join([c * 250 for c in "abc"]) + "/" + "d" * 40 + ".txt"
    tree.file("long-names/" + long_path, b"a long path\n")

    # Empty files and directories.
    tree.file("empty/zero-a", b"")
    tree.file("empty/zero-b.txt", b"")
    tree.directory("empty/dir")
    tree.directory("empty/nested/inner")

    # Names in NFC and NFD (in separate directories: APFS treats the two forms as one name), and other scripts.
    for form in ["NFC", "NFD"]:
        directory = f"unicode/{form.lower()}"
        for name in ["café.txt", "Ångström", "한글.txt", "ﬁle-ligature", "ẹ́-stacked"]:
            tree.file(f"{directory}/{unicodedata.normalize(form, name)}", f"{form} {name}\n".encode())
        tree.file(f"{directory}/{unicodedata.normalize(form, 'répertoire')}/inside.txt", f"{form} dir\n".encode())
    tree.file("unicode/emoji-🦊.txt", "fox\n".encode())
    tree.file("unicode/spaces and 'quotes'.txt", b"spaces\n")
    tree.file("unicode/-leading-dash", b"dash\n")

    # Symbolic links: relative, absolute, dangling, to a directory, to a link, to the parent.
    tree.symlink("links/relative", "../small/d00/f000.txt")
    tree.symlink("links/absolute", "/usr/bin/true")
    tree.symlink("links/dangling", "nowhere/missing.txt")
    tree.symlink("links/to-directory", "../deep/level-01")
    tree.symlink("links/to-link", "relative")
    tree.symlink("links/parent", "..")
    tree.symlink("links/unicode-target", unicodedata.normalize("NFD", "../unicode/nfd/café.txt"))

    # Hard links: four names of one file across directories, and a pair; one of a file with attributes.
    tree.file("hard/original.txt", text(rng, 70_000))
    tree.hardlink("hard/second.txt", "hard/original.txt")
    tree.hardlink("small/d01/third-name.txt", "hard/original.txt")
    tree.hardlink("deep/level-01/fourth-name.txt", "hard/original.txt")
    tree.file("hard/pair-a", text(rng, 500))
    tree.hardlink("hard/sub/pair-b", "hard/pair-a")
    tree.file("hard/with-attributes", text(rng, 2_000))
    tree.hardlink("hard/with-attributes-link", "hard/with-attributes")

    # APFS-compressed files.
    compressed_files(tree, stage, rng)

    # Metadata: extended attributes (empty, small, large, Finder info, a resource fork), on a directory and a link.
    tree.file("metadata/attributes.txt", text(rng, 4_000))
    tree.xattr("metadata/attributes.txt", "com.example.empty", b"")
    tree.xattr("metadata/attributes.txt", "com.example.small", b"small value")
    tree.xattr("metadata/attributes.txt", "com.example.binary", random_bytes(rng, 4_096))
    tree.xattr("metadata/attributes.txt", "com.example.large", random_bytes(rng, 200_000))
    tree.xattr("metadata/attributes.txt", "com.apple.FinderInfo", b"TEXTttxt" + bytes(24))
    tree.file("metadata/resource-fork.txt", text(rng, 1_000))
    tree.xattr("metadata/resource-fork.txt", "com.apple.ResourceFork", random_bytes(rng, 100_000))
    tree.file("metadata/fork-only", b"")
    tree.xattr("metadata/fork-only", "com.apple.ResourceFork", text(rng, 3_000))
    tree.directory("metadata/directory-with-attributes")
    tree.file("metadata/directory-with-attributes/inside.txt", b"inside\n")
    tree.xattr("metadata/directory-with-attributes", "com.example.directory", b"on a directory")
    tree.symlink("metadata/link-with-attributes", "attributes.txt")
    tree.xattr("metadata/link-with-attributes", "com.example.link", b"on the link itself")
    tree.xattr("hard/with-attributes", "com.example.shared", b"one inode, two names")

    # Modes: read-only files and directories, private, executable, setuid, setgid, sticky, group-writable.
    tree.file("modes/read-only.txt", b"read only\n")
    tree.file("modes/private.txt", b"private\n")
    tree.file("modes/executable.sh", b"#!/bin/sh\necho hi\n")
    tree.file("modes/setuid.sh", b"#!/bin/sh\n")
    tree.file("modes/setgid.sh", b"#!/bin/sh\n")
    tree.file("modes/group-writable.txt", b"group\n")
    tree.file("modes/owner-read-only", b"owner reads, nobody writes\n")
    tree.file("modes/read-only-directory/inside.txt", b"inside a read-only directory\n")
    tree.file("modes/private-directory/inside.txt", b"inside a private directory\n")
    tree.directory("modes/sticky-directory")
    tree.file("modes/hidden.txt", b"hidden by a flag\n")
    tree.file("modes/no-dump.txt", b"no dump\n")

    # ACLs (allow entries and one deny that doesn't stop deletion), on a file and a directory, with inheritance flags.
    tree.file("acl/file.txt", b"acl\n")
    tree.directory("acl/directory")
    tree.file("acl/directory/inside.txt", b"inside\n")
    tree.acl("acl/file.txt", "group:staff allow read,write,append")
    tree.acl("acl/file.txt", "everyone deny chown")
    tree.acl("acl/directory", "everyone allow list,search,add_file,file_inherit,directory_inherit")

    # Flags that don't stop deletion.
    tree.flags("modes/hidden.txt", 0x8000)  # UF_HIDDEN
    tree.flags("modes/no-dump.txt", 0x1)  # UF_NODUMP

    for path, mode in [
        ("modes/read-only.txt", 0o444), ("modes/private.txt", 0o600), ("modes/executable.sh", 0o755),
        ("modes/setuid.sh", 0o4755), ("modes/setgid.sh", 0o2755), ("modes/group-writable.txt", 0o664),
        ("modes/owner-read-only", 0o400),("modes/read-only-directory/inside.txt", 0o444),
        ("modes/read-only-directory", 0o555), ("modes/private-directory", 0o700),
        ("modes/sticky-directory", 0o1777),
    ]:
        tree.mode(path, mode)

    tree.set_times()


def collisions_tree(root):
    """Names a case-insensitive volume treats as one: two files, two directories (their contents merge), a file and a
    directory, a link and a file."""
    tree = Tree(root)
    tree.file("README.txt", b"upper\n")
    tree.file("readme.txt", b"lower\n")
    tree.file("Docs/a.txt", b"in Docs\n")
    tree.file("docs/b.txt", b"in docs\n")
    tree.file("Name", b"a file\n")
    tree.file("name/inside.txt", b"in a directory\n")
    tree.symlink("Link", "README.txt")
    tree.file("link", b"a file named like a link\n")
    tree.set_times()


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "main":
        main_tree(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 3 and sys.argv[1] == "collisions":
        collisions_tree(sys.argv[2])
    else:
        sys.exit(__doc__)
