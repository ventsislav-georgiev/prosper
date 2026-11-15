import CryptoKit
import Darwin
import Foundation

// #1108 P3a (design #1105 D11 steps 1-4, D12 Deleted): the editor's save. A person's file is their data:
// encode back to the file's own bytes, write only the resolved target and its sibling temp, refuse a
// concurrent write, keep mode, xattrs, ACL, owner, group, creation date and links; refuse a read-only file.
// No state and no actor isolation: every value here is a plain Sendable value, so the caller may run it off
// the main actor. Nothing calls it yet.

enum TextFileWriter {
    typealias Fingerprint = [UInt8]
    /// The seam over the one stat of the resolved target: 0 or an errno, and the stat.
    typealias Stat = (String) -> (Int32, stat)

    enum Step: Equatable { case resolve, stat, read, open, temp, copyAttributes, replace, truncate, write, fsync }
    enum Failure: Error, Equatable {
        /// Invalid UTF-8 or UTF-16: read-only (D1), never saved.
        case lossy
        /// A folder, a pipe, a device or a link where the resolved file should be.
        case notRegular
        /// The bytes on disk are not the ones last read or saved (D12): nothing was written. Or, in place, the path
        /// names another file after the write: the bytes went to the file that was compared, moved off the path meanwhile.
        case changedOnDisk
        /// The file at the path is not the one stat saw (a swap before the open): nothing was written.
        case swapped
        /// Locked (Finder's Locked: the user or system immutable flag): nothing was written (R1108-r3-b).
        case locked
        /// The link now names another file than the load opened, or a missing one (R1108-q3): nothing was written or created.
        case retargeted
        /// Nothing was changed.
        case failed(Step, Int32)
        /// The in-place write failed after the truncate: the file may be incomplete.
        case incomplete(Step, Int32)
    }

    /// D11 step 1, the inverse of TextViewerDocument.decode. The tree keeps line endings in the text at load,
    /// so the buffer already holds them: nothing is converted here.
    static func encode(_ text: String, encoding: TextViewerDocument.Encoding) -> [UInt8]? {
        switch encoding {
        case .utf8: return Array(text.utf8)
        case .utf8BOM: return Lines.bom + Array(text.utf8)
        case .utf16LE, .utf16BE:
            // decode only takes UTF-16 with its BOM, so the BOM always goes back.
            let little = encoding == .utf16LE
            var out: [UInt8] = little ? [0xFF, 0xFE] : [0xFE, 0xFF]
            for u in text.utf16 {
                let hi = UInt8(truncatingIfNeeded: u >> 8), lo = UInt8(truncatingIfNeeded: u)
                out += little ? [lo, hi] : [hi, lo]
            }
            return out
        case .lossy: return nil
        }
    }

    static func digest(_ bytes: [UInt8]) -> Fingerprint { Array(SHA256.hash(data: bytes)) }

    /// The last path component followed through symlinks (the link stays a link). A missing or dangling
    /// end is returned as is: the Deleted case. Directory components are left to the kernel.
    static func resolve(_ path: String) -> Result<String, Failure> {
        // Absolute only (R1108-r3-1): a relative path is read against the process's folder and its folder part is the root.
        // An absolute path stays absolute through every link below. A file URL's path is absolute: a belt.
        guard path.hasPrefix("/") else { return .failure(.failed(.resolve, EINVAL)) }
        var path = path
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        for _ in 0..<32 {
            let n = readlink(path, &buf, Int(PATH_MAX))
            if n < 0 { return errno == EINVAL || errno == ENOENT ? .success(path) : .failure(.failed(.resolve, errno)) }
            let target = buf[0..<n].map { UInt8(bitPattern: $0) }
            // Strict (R1108-q4): a target that is not UTF-8 would name another, missing file, and a save would create it.
            let dest = String(decoding: target, as: UTF8.self)
            guard dest.utf8.elementsEqual(target) else { return .failure(.failed(.resolve, EILSEQ)) }
            path = dest.hasPrefix("/") ? dest : (path as NSString).deletingLastPathComponent + "/" + dest
        }
        return .failure(.failed(.resolve, ELOOP))
    }

    /// D11 steps 2-4. `expected` is the fingerprint of the bytes last read or saved; `overwrite` skips only
    /// that comparison (D12's "Overwrite the newer file on disk?"). The stat seam defaults to lstat: the
    /// resolved end is not a link, so a link that appears there is seen as one and refused, never followed.
    /// A good save answers the fingerprint of the bytes written. `beforeCompare` is a test seam: called once in the in-place
    /// branch, on the opened and checked descriptor, right before the comparison. `beforeRead` is a test seam too: called once
    /// inside the comparison (either branch), between its fstat and its read. `identity` is what the load opened (nil: not
    /// checked): only its path is compared with the one resolved now; it is never opened, created or removed.
    /// `copyAttributes` (file, temp, copyfile flags), `setFlags` (temp, flags) and `syncFolder` (folder) are seams over the copy
    /// step, the temp's flags and the folder fsync: 0 or an errno. `beforeReplace` and `beforeTruncate` are test seams called right
    /// before the second check of the atomic and the in-place branch. `now` (seconds since 1970) dates the stale temp sweep.
    static func save(_ text: String, encoding: TextViewerDocument.Encoding, to url: URL, expected: Fingerprint,
                     overwrite: Bool = false, identity: TextViewerDocument.Identity? = nil,
                     writer: any ManagedConfigFileWriter = ManagedConfigPOSIXWriter(),
                     stat statAt: Stat = { p in var s = stat(); return (lstat(p, &s) == 0 ? 0 : errno, s) },
                     copyAttributes: (String, String, copyfile_flags_t) -> Int32 = TextFileWriter.copyAttributes,
                     setFlags: (String, UInt32) -> Int32 = TextFileWriter.setFlags,
                     syncFolder: (String) -> Int32 = TextFileWriter.syncFolder,
                     beforeCompare: () -> Void = {}, beforeRead: () -> Void = {},
                     beforeReplace: () -> Void = {}, beforeTruncate: () -> Void = {},
                     now clock: TimeInterval = Date().timeIntervalSince1970) -> Result<Fingerprint, Failure> {
        guard let bytes = encode(text, encoding: encoding) else { return .failure(.lossy) }
        let path: String
        switch resolve(url.path) {
        case .success(let p): path = p
        case .failure(let f): return .failure(f)
        }
        // R1108-q3: a link retargeted since the load (at another file or a missing name) is never written or created, even with
        // overwrite. The same path with another inode (replaced there) stays the byte comparison's question.
        if let identity, identity.path != path { return .failure(.retargeted) }
        let (code, st) = statAt(path)
        if code == ENOENT { return create(bytes, at: path, syncFolder) }
        guard code == 0 else { return .failure(.failed(.stat, code)) }
        guard st.st_mode & S_IFMT == S_IFREG else { return .failure(.notRegular) }
        // Locked: its own answer, before any temp (the rename would fail with EPERM after the temp was written).
        guard st.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) == 0 else { return .failure(.locked) }
        // Marked read-only by its owner: never written, by either branch (a rename would replace it anyway).
        guard st.st_mode & S_IWUSR != 0 else { return .failure(.failed(.open, EACCES)) }
        // Nor a file an access list denies writing (R1108-r3-b): the rename needs only the folder, so the kernel is asked
        // about the file itself, with the effective ids; the resolved end is not a link, NOFOLLOW is a belt.
        guard faccessat(AT_FDCWD, path, W_OK, AT_EACCESS | AT_SYMLINK_NOFOLLOW) == 0 else { return .failure(.failed(.open, errno)) }

        // A new sibling takes the folder's group ("/." stats the folder itself, not a link to it); no chown, so a
        // file of another group is written in place, as for another owner.
        let folderPath = (path as NSString).deletingLastPathComponent
        let (folderCode, folder) = statAt(folderPath + "/.")
        // R1108-r7-a: only the flags the owner sets stay atomic (hidden and no-dump set on the temp below; the kernel carries
        // UF_TRACKED and the document id over the rename itself). Any other flag (system, compressed, dataless, unknown): in place.
        let ownerFlags = UInt32(UF_NODUMP | UF_HIDDEN | UF_TRACKED)
        atomic: if st.st_uid == geteuid() && st.st_nlink == 1 && st.st_flags & ~ownerFlags == 0 && folderCode == 0 && folder.st_gid == st.st_gid {
            // Atomic: a temp with the final mode, the xattrs and ACL copied onto it, the comparison, the rename.
            let target = URL(fileURLWithPath: path)
            let temp: URL
            // 0o1777: the setuid and setgid bits are never set again on new contents.
            do { temp = try writer.writeTemp(bytes, besides: target, mode: st.st_mode & 0o1777) } catch {
                // A folder the person cannot write (EROFS through the seam only: faccessat above refuses a read-only volume):
                // the file itself is writable, so in place, with that branch's checks. No other errno falls back.
                let e = errnoOf(error)
                if e == EACCES || e == EROFS { break atomic }
                return .failure(.failed(.temp, e))
            }
            // Belt: a temp that did not get the file's group after all (an odd file system) is dropped: in place instead.
            var made = stat()
            guard lstat(temp.path, &made) == 0, made.st_gid == st.st_gid else { _ = unlink(temp.path); break atomic }
            // The rename brings the temp's creation date: carry the file's. A failure here does not fail the save.
            var crtime = st.st_birthtimespec
            var crAttr = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: attrgroup_t(ATTR_CMN_CRTIME), volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
            _ = setattrlist(temp.path, &crAttr, &crtime, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW))
            let failure: Failure
            var seen = stat()
            let all = copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL | COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST)
            var copied = copyAttributes(path, temp.path, all)
            // R1108-r7-b: a volume without access lists (exFAT, FAT, some SMB) refuses the ACL step: once more with the xattrs
            // alone, only when the file has no access list that this would drop.
            if copied == ENOTSUP || copied == EOPNOTSUPP, !hasAccessList(path) {
                copied = copyAttributes(path, temp.path, all & ~copyfile_flags_t(COPYFILE_ACL))
            }
            if copied != 0 {
                failure = .failed(.copyAttributes, copied)
            } else if !overwrite, let changed = compare(path, expected, beforeRead, &seen) {
                failure = changed
            } else {
                sweepStaleTemps(in: folderPath, of: (path as NSString).lastPathComponent, keep: temp.lastPathComponent, now: clock, statAt)
                // Right before the rename. Never UF_TRACKED: a tracked temp would give the file a new document id. A failure drops
                // the flags and stays atomic, as saves before round 7 did: the bytes matter more than a hint.
                let carry = st.st_flags & UInt32(UF_NODUMP | UF_HIDDEN)
                if carry != 0 { _ = setFlags(temp.path, carry) }
                beforeReplace()
                // Round 7c: the comparison's second half (so none with overwrite): the path still names the file it read, unchanged.
                // Left open: a write between this lstat and rename(2); closing it needs a lock other programs do not honour.
                let again = overwrite ? nil : statAt(path)
                if let again, again.0 != 0 || !unchanged(again.1, seen) {
                    failure = .changedOnDisk
                } else {
                    do {
                        try writer.replace(target, with: temp)
                        // R1108-q2, after the rename only. Not a failed save: the bytes are written and named; the result has no
                        // warning slot. The default writer's replace fsyncs the folder too: twice is cheap, and a writer passed in may not.
                        _ = syncFolder(folderPath)
                        return .success(digest(bytes))
                    } catch { failure = .failed(.replace, errnoOf(error)) }
                }
            }
            _ = unlink(temp.path)
            // A volume that cannot hold the xattrs, or the access list the file has: in place keeps them.
            // Only these two: on ENOSPC and the like in place could truncate and then fail.
            if copied == ENOTSUP || copied == EOPNOTSUPP { break atomic }
            return .failure(failure)
        }

        // In place (another owner or group, hard links, a flag the owner cannot set, a folder the person cannot write, a volume
        // without the xattrs or the access list the file has):
        // keeps the owner, the group, the inode, its flags and the links; not atomic.
        // ONE descriptor (R1108-q1): the identity, the comparison, the truncate and the write all see the opened file.
        // No O_TRUNC at the open: a file swapped in after the stat must not be emptied before the check.
        let fd = open(path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { let e = errno; return .failure(e == ENOENT && !overwrite ? .changedOnDisk : .failed(.open, e)) }
        defer { close(fd) }
        var now = stat()
        guard fstat(fd, &now) == 0 else { return .failure(.failed(.open, errno)) }
        // The same inode as the regular file stat saw: so the type too.
        guard now.st_dev == st.st_dev, now.st_ino == st.st_ino else { return .failure(.swapped) }
        beforeCompare()
        var seen = stat()
        if !overwrite, let changed = compare(fd, expected, beforeRead, &seen) { return .failure(changed) }
        sweepStaleTemps(in: folderPath, of: (path as NSString).lastPathComponent, keep: nil, now: clock, statAt)
        // The comparison read to the end: back to the start, or the write would leave a hole of zeros.
        guard lseek(fd, 0, SEEK_SET) == 0 else { return .failure(.failed(.write, errno)) }
        beforeTruncate()
        // Round 7c: the comparison's second half (so none with overwrite): nothing appended or written since its read.
        // Left open: a write between this fstat and ftruncate(2); closing it needs a lock other programs do not honour.
        if !overwrite {
            var again = stat()
            guard fstat(fd, &again) == 0, unchanged(again, seen) else { return .failure(.changedOnDisk) }
        }
        guard ftruncate(fd, 0) == 0 else { return .failure(.incomplete(.truncate, errno)) }
        if let f = writeAll(fd, bytes) { return .failure(f) }
        // Moved off the path meanwhile: the bytes went to the file compared, but the path names another: D12's
        // "changed on disk", never "saved".
        var after = stat()
        guard lstat(path, &after) == 0, after.st_dev == now.st_dev, after.st_ino == now.st_ino else { return .failure(.changedOnDisk) }
        return .success(digest(bytes))
    }

    /// D12 Deleted: written anew with 0o666 minus the umask. O_EXCL: a file that appeared meanwhile is a
    /// concurrent write, never overwritten.
    private static func create(_ bytes: [UInt8], at path: String, _ syncFolder: (String) -> Int32) -> Result<Fingerprint, Failure> {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard fd >= 0 else { return .failure(errno == EEXIST ? .changedOnDisk : .failed(.open, errno)) }
        defer { close(fd) }
        if let f = writeAll(fd, bytes) { return .failure(f) }
        // R1108-q2: the new name survives a power loss. A failure is not a failed save (see the atomic branch).
        _ = syncFolder((path as NSString).deletingLastPathComponent)
        return .success(digest(bytes))
    }

    /// The copy step's default: copyfile from the file onto the temp with `flags` (save passes the no-follow ones). 0 or an errno.
    static func copyAttributes(_ file: String, _ temp: String, _ flags: copyfile_flags_t) -> Int32 {
        guard copyfile(file, temp, nil, flags) != 0 else { return 0 }
        return errno != 0 ? errno : EIO
    }

    /// The temp's flags default: the one lchflags of this file, on the product's own sibling temp, masked to hidden and no-dump
    /// (a belt: never a system flag, never UF_TRACKED). 0 or an errno.
    static func setFlags(_ temp: String, _ flags: UInt32) -> Int32 {
        lchflags(temp, flags & UInt32(UF_NODUMP | UF_HIDDEN)) == 0 ? 0 : errno
    }

    /// A read only: false when the file surely has no extended access list (none, or a volume that holds none).
    private static func hasAccessList(_ path: String) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return errno != ENOENT && errno != ENOTSUP && errno != EOPNOTSUPP }
        acl_free(UnsafeMutableRawPointer(acl))
        return true
    }

    /// The folder fsync's default: opened read-only as a folder, fsync'd, closed. 0 or an errno.
    static func syncFolder(_ folder: String) -> Int32 {
        let fd = open(folder, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        return fsync(fd) == 0 ? 0 : errno
    }

    /// The file's current bytes against `expected`, read by TextViewerDocument.load's rule (non-blocking,
    /// regular files only, at most maxBytes): nil when they match.
    /// `seen` gets the comparison's fstat for the second check.
    private static func compare(_ path: String, _ expected: Fingerprint, _ beforeRead: () -> Void, _ seen: inout stat) -> Failure? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? .changedOnDisk : .failed(.read, errno) }
        defer { close(fd) }
        return compare(fd, expected, beforeRead, &seen)
    }

    /// The same on an open descriptor at offset 0 (the in-place branch's own).
    private static func compare(_ fd: Int32, _ expected: Fingerprint, _ beforeRead: () -> Void, _ seen: inout stat) -> Failure? {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .failed(.read, errno) }
        seen = st
        guard st.st_mode & S_IFMT == S_IFREG else { return .notRegular }
        // Past the viewer's limit it cannot be what was read or saved.
        guard st.st_size >= 0, st.st_size <= Int64(TextViewerDocument.maxBytes) else { return .changedOnDisk }
        beforeRead()
        guard let data = TextViewerDocument.readAll(fd, size: Int(st.st_size)) else { return .failed(.read, errno) }
        // Grown since the fstat (R1108-r4-a, a log another program appends to): a byte past the size read is not compared,
        // and the truncate or the rename would drop it.
        var more: UInt8 = 0
        var n: Int
        repeat { n = read(fd, &more, 1) } while n < 0 && errno == EINTR
        if n < 0 { return .failed(.read, errno) }
        if n > 0 { return .changedOnDisk }
        return digest([UInt8](data)) == expected ? nil : .changedOnDisk
    }

    /// The second check: the same file (device, inode) with the same size, mtime and ctime as the comparison's fstat.
    private static func unchanged(_ now: stat, _ seen: stat) -> Bool {
        now.st_dev == seen.st_dev && now.st_ino == seen.st_ino && now.st_size == seen.st_size
            && now.st_mtimespec.tv_sec == seen.st_mtimespec.tv_sec && now.st_mtimespec.tv_nsec == seen.st_mtimespec.tv_nsec
            && now.st_ctimespec.tv_sec == seen.st_ctimespec.tv_sec && now.st_ctimespec.tv_nsec == seen.st_ctimespec.tv_nsec
    }

    /// ManagedConfig.staleTempAge's value: a save's own temp lives from writeTemp to the rename, well under a second locally.
    static let staleTempAge: TimeInterval = 60
    /// A huge folder costs at most this many readdir entries per save.
    static let sweepLimit = 10000

    /// Round 7c: removes `.<name>.prosper-<UUID>` temps a save that died left in the target's own folder (never another folder,
    /// never recursive): a regular file of ours (lstat through the seam, never followed), one link, its mtime more than
    /// staleTempAge before `now`. `keep` is this save's own temp. Never fails a save. readdir, not FileManager (it hides "._x").
    private static func sweepStaleTemps(in folder: String, of name: String, keep: String?, now: TimeInterval, _ statAt: Stat) {
        guard let d = opendir(folder) else { return }
        defer { closedir(d) }
        let prefix = "." + name + ".prosper-"
        var read = 0
        while read < sweepLimit, let e = readdir(d) {
            read += 1
            let raw = withUnsafeBytes(of: e.pointee.d_name) { Array($0.prefix(Int(e.pointee.d_namlen))) }
            // A name that is not UTF-8 never matches (decoding would name another file). readdir never yields a "/" in a name.
            let entry = String(decoding: raw, as: UTF8.self)
            guard entry.utf8.elementsEqual(raw), entry != keep,
                  raw.starts(with: prefix.utf8), raw.count == prefix.utf8.count + 36,
                  UUID(uuidString: String(decoding: raw.suffix(36), as: UTF8.self)) != nil else { continue }
            let full = folder + "/" + entry
            let (code, st) = statAt(full)
            guard code == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == geteuid(), st.st_nlink == 1 else { continue }
            let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
            guard now - mtime > staleTempAge else { continue }
            _ = unlink(full)
        }
    }

    /// A write loop (EINTR retried) and fsync; a failure here leaves the file incomplete.
    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Failure? {
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + off, bytes.count - off) }
            if n < 0 { if errno == EINTR { continue }; return .incomplete(.write, errno) }
            if n == 0 { return .incomplete(.write, EIO) }
            off += n
        }
        return fsync(fd) == 0 ? nil : .incomplete(.fsync, errno)
    }

    private static func errnoOf(_ error: Error) -> Int32 { (error as? ManagedConfigPOSIXWriter.WriteError)?.code ?? EIO }
}
