import Darwin

/// Removes a directory tree through descriptors, never following a link: each directory opened with `O_NOFOLLOW`
/// relative to its parent, its entries unlinked relative to it. Read-only directories and locking flags (what
/// extracted trees have) are cleared on the way.
public enum TreeRemoval {
    /// Removes `path` (a file, link, or directory tree) and everything in it. Errors are ignored: what can be removed
    /// is.
    public static func remove(_ path: String) {
        let parent = AT_FDCWD
        path.withCString { name in
            // Unsafe: `withCString`'s pointer to `removeEntry`. Safe: NUL-terminated and valid inside this closure,
            // which `removeEntry` (and its recursion) returns within; nothing keeps the pointer.
            _ = unsafe removeEntry(parent, name)
        }
    }

    /// Removes `name` in the directory `parent`.
    static func remove(name: [UInt8], in parent: Int32) {
        // Unsafe: `CString.with`'s pointer to `removeEntry`. Safe: its NUL-terminated copy of `name`, valid inside the
        // body, which `removeEntry` returns within; nothing keeps the pointer.
        _ = unsafe CString.with(name.span.bytes) { unsafe removeEntry(parent, $0) }
    }

    /// Clears the flags of `name` in `parent` (the item itself, a link not followed).
    private static func clearFlags(_ parent: Int32, _ name: UnsafePointer<CChar>) {
        // Unsafe: `name` to `openat`. Safe: the caller's NUL-terminated string, valid for this call, read during it.
        let descriptor = unsafe openat(parent, name, O_RDONLY | O_SYMLINK | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        _ = fchflags(descriptor, 0)
        close(descriptor)
    }

    private static func removeEntry(_ parent: Int32, _ name: UnsafePointer<CChar>) -> Bool {
        // `name` is the caller's NUL-terminated string, valid until this returns (a `withCString` or `CString.with`
        // body, or a `readdir` entry's name, which `removeContents` holds while no other `readdir` runs on its stream).
        // Unsafe: `name` to `unlinkat`. Safe: NUL-terminated and valid as above; read only during the call.
        if unsafe unlinkat(parent, name, 0) == 0 { return true }
        if errno == EPERM || errno == EACCES {
            // Locking flags, or a read-only parent (fixed by the caller's chmod below).
            // Unsafe (the next two): `name` to `clearFlags` and `unlinkat` again. Safe: as above; neither keeps it.
            unsafe clearFlags(parent, name)
            if unsafe unlinkat(parent, name, 0) == 0 { return true }
        }
        // Unsafe: `name` to `openat`. Safe: NUL-terminated and valid as above; read only during the call.
        let directory = unsafe openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory < 0 {
            // Maybe unreadable: make it the owner's, then try again.
            // Unsafe (the next two): `name` to `fchmodat` and `openat`. Safe: as above; read only during the calls.
            _ = unsafe fchmodat(parent, name, 0o700, AT_SYMLINK_NOFOLLOW)
            let retry = unsafe openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard retry >= 0 else { return false }
            // Unsafe: `name` to `removeContents`. Safe: valid as above; it reads the name (to remove the emptied
            // directory) before it returns, and its own `readdir` calls are on the new directory's stream, not the
            // one `name` may point into.
            return unsafe removeContents(retry, parent, name)
        }
        // Unsafe: `name` to `removeContents`. Safe: as for the retry above.
        return unsafe removeContents(directory, parent, name)
    }

    /// Empties the open directory `directory` (`name` in `parent`), closes it, and removes it.
    private static func removeContents(_ directory: Int32, _ parent: Int32, _ name: UnsafePointer<CChar>) -> Bool {
        _ = fchflags(directory, 0)
        _ = fchmod(directory, 0o700)
        // `fdopendir` takes the descriptor; `closedir` closes it.
        // Unsafe: `fdopendir` returns a stream pointer. Safe: checked for `nil`; used only in this function, which
        // closes it once (`closedir` below) on every path after this guard.
        guard let stream = unsafe fdopendir(directory) else {
            close(directory)
            return false
        }
        // Removing entries while reading the directory can skip some: read it again until a pass removes nothing.
        while true {
            var removed = 0
            // Unsafe: `readdir` on the stream, returning a pointer to an entry. Safe: the open stream from `fdopendir`;
            // the entry is the stream's, valid until the next `readdir`, `rewinddir`, or `closedir` on it, and used
            // only in this iteration's body.
            while let entry = unsafe readdir(stream) {
                // Unsafe: a pointer to the entry's `d_name`, through `entry.pointee`. Safe: the entry is valid for this
                // iteration (above), and the pointer is used only inside the closure. (`d_name` is declared as 1,024
                // bytes; the stream's record holds the name and its NUL, which is all that's read through `child`.)
                let done: Bool = unsafe withUnsafePointer(to: entry.pointee.d_name) { tuple in
                    // Unsafe: rebinds the tuple of `CChar`s to its first `CChar`. Safe: a homogeneous tuple of `CChar`
                    // is laid out as an array of them; `d_name` is NUL-terminated within it, valid inside this closure.
                    let child = unsafe UnsafeRawPointer(tuple).assumingMemoryBound(to: CChar.self)
                    // Unsafe: `child` to both `strcmp`s. Safe: NUL-terminated (above); each reads no further than
                    // its NUL and keeps nothing.
                    if unsafe strcmp(child, ".") == 0 || strcmp(child, "..") == 0 { return false }
                    // Unsafe: `child` to `removeEntry`. Safe: valid until this closure returns; `removeEntry`'s own
                    // `readdir` calls (a subdirectory) are on another stream, so this entry isn't overwritten.
                    return unsafe removeEntry(directory, child)
                }
                if done { removed += 1 }
            }
            if removed == 0 { break }
            // Unsafe: `rewinddir` on the stream. Safe: still open; no entry of it is held here.
            unsafe rewinddir(stream)
        }
        // Unsafe: `closedir` on the stream. Safe: open until now, closed exactly once, and not used after.
        unsafe closedir(stream)
        // `name` is the caller's NUL-terminated string, valid until this returns (`removeEntry`'s contract).
        // Unsafe (the next three): `name` to `unlinkat`, `clearFlags`, and `unlinkat`. Safe: read only during each call.
        if unsafe unlinkat(parent, name, AT_REMOVEDIR) == 0 { return true }
        unsafe clearFlags(parent, name)
        return unsafe unlinkat(parent, name, AT_REMOVEDIR) == 0
    }
}
