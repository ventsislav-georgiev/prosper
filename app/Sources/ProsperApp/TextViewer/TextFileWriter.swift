import CryptoKit
import Darwin
import Foundation

// #1108 P3a (design #1105 D11 steps 1-4, D12 Deleted): the editor's save. A person's file is their data:
// encode back to the file's own bytes, write only the resolved target and its sibling temp, refuse a
// concurrent write, keep mode, xattrs, ACL, owner and links. No state and no actor isolation: every
// value here is a plain Sendable value, so the caller may run it off the main actor. Nothing calls it yet.

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
        /// The bytes on disk are not the ones last read or saved (D12): nothing was written.
        case changedOnDisk
        /// The file at the path is not the one stat saw (a swap before the open): nothing was written.
        case swapped
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
        var path = path
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        for _ in 0..<32 {
            let n = readlink(path, &buf, Int(PATH_MAX))
            if n < 0 { return errno == EINVAL || errno == ENOENT ? .success(path) : .failure(.failed(.resolve, errno)) }
            let dest = String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            path = dest.hasPrefix("/") ? dest : (path as NSString).deletingLastPathComponent + "/" + dest
        }
        return .failure(.failed(.resolve, ELOOP))
    }

    /// D11 steps 2-4. `expected` is the fingerprint of the bytes last read or saved; `overwrite` skips only
    /// that comparison (D12's "Overwrite the newer file on disk?"). The stat seam defaults to lstat: the
    /// resolved end is not a link, so a link that appears there is seen as one and refused, never followed.
    /// A good save answers the fingerprint of the bytes written.
    static func save(_ text: String, encoding: TextViewerDocument.Encoding, to url: URL, expected: Fingerprint,
                     overwrite: Bool = false, writer: any ManagedConfigFileWriter = ManagedConfigPOSIXWriter(),
                     stat statAt: Stat = { p in var s = stat(); return (lstat(p, &s) == 0 ? 0 : errno, s) }) -> Result<Fingerprint, Failure> {
        guard let bytes = encode(text, encoding: encoding) else { return .failure(.lossy) }
        let path: String
        switch resolve(url.path) {
        case .success(let p): path = p
        case .failure(let f): return .failure(f)
        }
        let (code, st) = statAt(path)
        if code == ENOENT { return create(bytes, at: path) }
        guard code == 0 else { return .failure(.failed(.stat, code)) }
        guard st.st_mode & S_IFMT == S_IFREG else { return .failure(.notRegular) }

        if st.st_uid == geteuid() && st.st_nlink == 1 {
            // Atomic: a temp with the final mode, the xattrs and ACL copied onto it, the comparison, the rename.
            let target = URL(fileURLWithPath: path)
            let temp: URL
            do { temp = try writer.writeTemp(bytes, besides: target, mode: st.st_mode & 0o7777) } catch { return .failure(.failed(.temp, errnoOf(error))) }
            let failure: Failure
            if copyfile(path, temp.path, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL | COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST)) != 0 {
                failure = .failed(.copyAttributes, errno)
            } else if !overwrite, let changed = compare(path, expected) {
                failure = changed
            } else {
                do { try writer.replace(target, with: temp); return .success(digest(bytes)) } catch { failure = .failed(.replace, errnoOf(error)) }
            }
            _ = unlink(temp.path)
            return .failure(failure)
        }

        // In place (another owner, or hard links): keeps the owner, the inode and the links; not atomic.
        if !overwrite, let changed = compare(path, expected) { return .failure(changed) }
        // No O_TRUNC at the open: a file swapped in after the stat must not be emptied before the check.
        let fd = open(path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .failure(.failed(.open, errno)) }
        defer { close(fd) }
        var now = stat()
        guard fstat(fd, &now) == 0 else { return .failure(.failed(.open, errno)) }
        guard now.st_dev == st.st_dev, now.st_ino == st.st_ino else { return .failure(.swapped) }
        guard ftruncate(fd, 0) == 0 else { return .failure(.incomplete(.truncate, errno)) }
        if let f = writeAll(fd, bytes) { return .failure(f) }
        return .success(digest(bytes))
    }

    /// D12 Deleted: written anew with 0o666 minus the umask. O_EXCL: a file that appeared meanwhile is a
    /// concurrent write, never overwritten.
    private static func create(_ bytes: [UInt8], at path: String) -> Result<Fingerprint, Failure> {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard fd >= 0 else { return .failure(errno == EEXIST ? .changedOnDisk : .failed(.open, errno)) }
        defer { close(fd) }
        if let f = writeAll(fd, bytes) { return .failure(f) }
        return .success(digest(bytes))
    }

    /// The file's current bytes against `expected`, read by TextViewerDocument.load's rule (non-blocking,
    /// regular files only, at most maxBytes): nil when they match.
    private static func compare(_ path: String, _ expected: Fingerprint) -> Failure? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? .changedOnDisk : .failed(.read, errno) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .failed(.read, errno) }
        guard st.st_mode & S_IFMT == S_IFREG else { return .notRegular }
        // Past the viewer's limit it cannot be what was read or saved.
        guard st.st_size >= 0, st.st_size <= Int64(TextViewerDocument.maxBytes) else { return .changedOnDisk }
        guard let data = TextViewerDocument.readAll(fd, size: Int(st.st_size)) else { return .failed(.read, errno) }
        return digest([UInt8](data)) == expected ? nil : .changedOnDisk
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
