import CryptoKit
import Darwin
import Foundation

// #917 S5a (plan C S5, E-1, E-2, E-3, E-7, QA #749 INFO-2): the kit store, first half. It STAGES a kit:
// a no-follow copy of the source into <configHome>/prosper/kits/<ext-id>/staged/<version>+<tree>, the tree
// hash check, the validator on the copy, the Markdown render in the copy, and kit.env. A kit is outside data
// and untrusted code: its files are copied and read as bytes, never executed, sourced or opened as anything
// else. No link is ever followed (lstat, O_NOFOLLOW, a dir opened O_NOFOLLOW before readdir). Every write and
// every remove stays under kits/<ext-id>/ (prosper/ and kits/ are only created when missing). Nothing is logged.
// S5b-1 (QA R917-s5a-q1): every walk of kit content (the source walk, the store's remove, the sweep) is
// directory-relative: a dir is held open O_DIRECTORY | O_NOFOLLOW and each child is reached with openat / fstatat
// (AT_SYMLINK_NOFOLLOW) / unlinkat on it, never by a joined path, so a dir swapped for a link part-way cannot redirect
// it. The swap into live goes through `incoming` and keeps the older previous as `retiring` (ruling r-917s5b1a);
// the sweep removes only the store's own stale temps.
// Shims, the runner placement and the effect runner are S5b-2's.

enum KitStoreError: Error, Equatable, Sendable {
    case badID, badVersion, badTree, badSlug
    /// a symbolic link where the store needs a dir or a file: refused, never followed ("" = the root)
    case link(String)
    case notADirectory(String)
    /// not a regular file, dir or link (a FIFO, socket, device), or an entry that changed under the copy
    case special(String)
    case setuid(String)
    case unreadableDir(String)
    case badName(String)
    case tooManyFiles, tooDeep, tooLarge
    /// a remove asked for a path that is not strictly inside kits/<ext-id>/
    case outsideStore
    /// kit.env exists but does not hold a recorded slug: never overwritten
    case kitEnvUnreadable
    case io(String, Int32)
}

/// The directory-stream seam (rider R917-s2a-q2): a row can make readdir fail part-way.
protocol KitDirStream: Sendable {
    /// fdopendir on a dup of `fd`, a dir already opened O_DIRECTORY | O_NOFOLLOW; `dir` only names it. nil when it fails.
    func open(_ dir: String, fd: Int32) -> (any KitDirHandle)?
}

protocol KitDirHandle: AnyObject {
    /// readdir: the next name's bytes, or nil and the errno it left (0 = the end of the list)
    func next() -> (name: [UInt8]?, error: Int32)
}

struct KitPOSIXDirStream: KitDirStream {
    func open(_ dir: String, fd: Int32) -> (any KitDirHandle)? {
        let own = dup(fd)
        guard own >= 0 else { return nil }
        guard let d = fdopendir(own) else { _ = close(own); return nil }
        rewinddir(d) // a dup shares the offset of `fd`
        return Handle(d)
    }

    final class Handle: KitDirHandle {
        let d: UnsafeMutablePointer<DIR>
        init(_ d: UnsafeMutablePointer<DIR>) { self.d = d }
        deinit { closedir(d) }
        func next() -> (name: [UInt8]?, error: Int32) {
            errno = 0
            guard let e = readdir(d) else { return (nil, errno) }
            return (withUnsafeBytes(of: e.pointee.d_name) { raw in Array(raw.prefix { $0 != 0 }) }, 0)
        }
    }
}

/// A directory held open: every child is reached relative to it (openat, fstatat AT_SYMLINK_NOFOLLOW, unlinkat,
/// renameatx_np), never by a joined path. A child name is one path component: "", ".", "..", "/" or NUL refused.
protocol KitDir: AnyObject {
    /// a label for errors and the stream seam; never used to reach a child
    var path: String { get }
    /// every name but "." and "..", sorted; nil when readdir fails part-way
    func names() -> [String]?
    func kind(_ name: String) -> KitFileKind
    /// the child's mtime (no follow); nil when it cannot be read
    func modified(_ name: String) -> Date?
    /// the child dir opened O_DIRECTORY | O_NOFOLLOW: a link is refused (.link), never followed
    func dir(_ name: String) throws -> any KitDir
    /// a regular file's bytes, opened O_NOFOLLOW | O_NONBLOCK; nil for anything else or for more than `limit` bytes
    func read(_ name: String, limit: Int) -> Data?
    /// unlinkat, AT_REMOVEDIR when `dir`: a link is removed itself, never followed
    func remove(_ name: String, dir: Bool) throws
    /// renameatx_np: RENAME_SWAP when `swap`, else RENAME_EXCL (never replaces what is at `newName`)
    func rename(_ name: String, to other: any KitDir, _ newName: String, swap: Bool) throws
}

final class KitPOSIXDir: KitDir {
    let fd: Int32
    let path: String
    let stream: any KitDirStream

    private init(fd: Int32, path: String, stream: any KitDirStream) {
        self.fd = fd
        self.path = path
        self.stream = stream
    }

    deinit { _ = close(fd) }

    static func isName(_ n: String) -> Bool { !n.isEmpty && n != "." && n != ".." && !n.contains("/") && !n.contains("\0") }

    /// `name` relative to `parent` (AT_FDCWD: an absolute path, O_NOFOLLOW on its last component only)
    static func open(_ name: String, at parent: Int32, label: String, stream: any KitDirStream) throws -> KitPOSIXDir {
        let fd = openat(parent, name, KitStore.dirFlags)
        guard fd >= 0 else {
            let e = errno
            var st = stat() // O_DIRECTORY may answer ENOTDIR for a link: lstat says which
            let isLink = fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0 && st.st_mode & S_IFMT == S_IFLNK
            throw e == ELOOP || isLink ? KitStoreError.link(label) : e == ENOTDIR ? KitStoreError.notADirectory(label) : KitStoreError.io("open", e)
        }
        return KitPOSIXDir(fd: fd, path: label, stream: stream)
    }

    private func lstatAt(_ name: String) -> stat? {
        var st = stat()
        guard Self.isName(name), fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return st
    }

    func names() -> [String]? { KitStore.listNames(fd: fd, path, stream) }

    func kind(_ name: String) -> KitFileKind { lstatAt(name).map(KitPOSIXFS.kind(of:)) ?? .missing }

    func modified(_ name: String) -> Date? {
        lstatAt(name).map { Date(timeIntervalSince1970: TimeInterval($0.st_mtimespec.tv_sec) + TimeInterval($0.st_mtimespec.tv_nsec) / 1e9) }
    }

    func dir(_ name: String) throws -> any KitDir {
        guard Self.isName(name) else { throw KitStoreError.badName(path) }
        return try Self.open(name, at: fd, label: path + "/" + name, stream: stream)
    }

    func read(_ name: String, limit: Int) -> Data? {
        guard limit >= 0, Self.isName(name) else { return nil }
        let f = openat(fd, name, O_RDONLY | O_NONBLOCK | KitStore.noFollow)
        guard f >= 0 else { return nil }
        defer { _ = close(f) }
        return KitPOSIXFS.readAll(f, limit: limit)
    }

    func remove(_ name: String, dir: Bool) throws {
        guard Self.isName(name) else { throw KitStoreError.badName(path) }
        guard unlinkat(fd, name, dir ? AT_REMOVEDIR : 0) == 0 else { throw KitStoreError.io("remove", errno) }
    }

    func rename(_ name: String, to other: any KitDir, _ newName: String, swap: Bool) throws {
        guard Self.isName(name), Self.isName(newName) else { throw KitStoreError.badName(path) }
        guard let to = other as? KitPOSIXDir else { throw KitStoreError.io("rename", EXDEV) }
        let flag = UInt32(swap ? RENAME_SWAP : RENAME_EXCL)
        guard renameatx_np(fd, name, to.fd, newName, flag) == 0 else { throw KitStoreError.io("rename", errno) }
    }
}

/// The store's only way to the disk. Paths are absolute.
protocol KitFS: Sendable {
    /// the dir opened O_DIRECTORY | O_NOFOLLOW (its last component): the start of every directory-relative walk
    func openDir(_ path: String) throws -> any KitDir
    /// lstat: a link is `.symlink`, never followed
    func kind(_ path: String) -> KitFileKind
    /// every name but "." and "..", sorted; nil when the dir cannot be opened (a link included) or readdir fails
    func names(_ dir: String) -> [String]?
    /// a regular file's bytes, opened O_NOFOLLOW | O_NONBLOCK; nil for anything else or for more than `limit` bytes
    func read(_ path: String, limit: Int) -> Data?
    /// mkdir 0700 when missing; then the dir is opened O_NOFOLLOW (a link or a file in its place is refused)
    /// and, when `narrow`, set to exactly 0700
    func ensureDir(_ path: String, narrow: Bool) throws
    /// a NEW file (O_CREAT | O_EXCL | O_NOFOLLOW) with exactly `mode`
    func create(_ path: String, _ data: Data, mode: mode_t) throws
    func rename(_ from: String, _ to: String) throws
    var writer: any ManagedConfigFileWriter { get }
}

struct KitPOSIXFS: KitFS {
    var stream: any KitDirStream = KitPOSIXDirStream()
    var writer: any ManagedConfigFileWriter = ManagedConfigPOSIXWriter()
    /// write(2); a seam so a row can make it return 0 (R917-s5a-n1)
    var writeBytes: @Sendable (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }

    func openDir(_ path: String) throws -> any KitDir { try KitPOSIXDir.open(path, at: AT_FDCWD, label: path, stream: stream) }

    func kind(_ path: String) -> KitFileKind {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .missing }
        return Self.kind(of: st)
    }

    static func kind(of st: stat) -> KitFileKind {
        switch st.st_mode & S_IFMT {
        case S_IFREG: return .file(mode: UInt16(st.st_mode & 0o7777), size: Int64(st.st_size))
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        default: return .other
        }
    }

    func names(_ dir: String) -> [String]? { KitStore.listNames(dir, stream) }

    func read(_ path: String, limit: Int) -> Data? {
        guard limit >= 0 else { return nil }
        let fd = open(path, O_RDONLY | O_NONBLOCK | KitStore.noFollow)
        guard fd >= 0 else { return nil }
        defer { _ = close(fd) }
        return Self.readAll(fd, limit: limit)
    }

    /// fstat must say a regular file of at most `limit` bytes; growth past it while reading is nil too.
    static func readAll(_ fd: Int32, limit: Int) -> Data? {
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= Int64(limit) else { return nil }
        var out = Data()
        let chunk = 1 << 16
        var buf = [UInt8](repeating: 0, count: chunk)
        while true {
            let n = Darwin.read(fd, &buf, chunk)
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { return out }
            guard n <= limit - out.count else { return nil } // the file grew after fstat
            out.append(contentsOf: buf[0..<n])
        }
    }

    func ensureDir(_ path: String, narrow: Bool) throws {
        if mkdir(path, KitStore.dirMode) != 0, errno != EEXIST { throw KitStoreError.io("mkdir", errno) }
        let fd = open(path, O_RDONLY | O_DIRECTORY | KitStore.noFollow)
        guard fd >= 0 else {
            let e = errno
            throw e == ELOOP ? KitStoreError.link(path) : e == ENOTDIR ? KitStoreError.notADirectory(path) : KitStoreError.io("open", e)
        }
        defer { _ = close(fd) }
        if narrow, fchmod(fd, KitStore.dirMode) != 0 { throw KitStoreError.io("chmod", errno) }
    }

    func create(_ path: String, _ data: Data, mode: mode_t) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | KitStore.noFollow, mode)
        guard fd >= 0 else { throw KitStoreError.io("create", errno) }
        defer { _ = close(fd) }
        guard fchmod(fd, mode) == 0 else { throw KitStoreError.io("chmod", errno) }
        var off = 0
        while off < data.count {
            let n = data.withUnsafeBytes { writeBytes(fd, $0.baseAddress! + off, data.count - off) }
            if n < 0 { if errno == EINTR { continue }; throw KitStoreError.io("write", errno) }
            if n == 0 { throw KitStoreError.io("write", EIO) } // no progress: a failure, never a loop
            off += n
        }
    }

    func rename(_ from: String, _ to: String) throws {
        guard Darwin.rename(from, to) == 0 else { throw KitStoreError.io("rename", errno) }
    }
}

/// <configHome>/prosper/kits/<ext-id>/ and what is in it (plan C S5). S5a fills staged/, tmp/ and kit.env;
/// bin, fired and state are created here and filled by later steps. live and previous are never created empty:
/// they come into being only by the swap's rename of a staged copy (so a first apply finds no live).
struct KitStoreLayout: Equatable, Sendable {
    var prosper: String
    var kits: String
    var root: String
    var live: String
    var staged: String
    var previous: String
    var bin: String
    var fired: String
    var tmp: String
    var state: String
    var kitEnv: String
    var piecesJSON: String
    var dirs: [String] { [staged, bin, fired, tmp, state] }
}

/// A staged copy: keyed by version AND the announced tree (rider R917-s4b-a).
struct KitStaged: Equatable, Sendable {
    var version: String
    var tree: String
    var path: String
    var source: String
}

struct KitStore: Sendable {
    static let dirMode: mode_t = 0o700
    static let envMode: mode_t = 0o600
    static let noFollow = O_NOFOLLOW
    static let dirFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW
    /// plan A7: the managed-config rule's age (ManagedConfig.staleTempAge), against an injected clock
    static let staleTempAge: TimeInterval = 60
    /// E-7: the caller picks; spec 4.9 for the Marketplace
    static let marketByteCap = 256 << 10
    static let localByteCap = 16 << 20

    let layout: KitStoreLayout
    let fs: any KitFS

    init(configHome: URL, extID: String, fs: any KitFS = KitPOSIXFS()) throws {
        layout = try Self.layout(configHome: configHome, extID: extID)
        self.fs = fs
    }

    static func layout(configHome: URL, extID: String) throws -> KitStoreLayout {
        // the extension id rule of KitValidator.validate: a path component, never "." or "..", no leading "-"
        guard ManagedConfigPaths.isValidID(extID), !extID.allSatisfy({ $0 == "." }), !extID.hasPrefix("-") else {
            throw KitStoreError.badID
        }
        let prosper = configHome.standardizedFileURL.path + "/prosper"
        let root = prosper + "/kits/" + extID
        return KitStoreLayout(prosper: prosper, kits: prosper + "/kits", root: root, live: root + "/live", staged: root + "/staged",
                              previous: root + "/previous", bin: root + "/bin", fired: root + "/fired", tmp: root + "/tmp",
                              state: root + "/state", kitEnv: root + "/kit.env", piecesJSON: root + "/pieces.json")
    }

    /// A version is a path component: 1 to 64 of [A-Za-z0-9._-], starting with a letter or digit ("+" never: it keys the tree).
    static func isValidVersion(_ v: String) -> Bool {
        let ok = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".utf8)
        guard let first = v.utf8.first, v.utf8.count <= 64, v.utf8.allSatisfy({ ok.contains($0) }) else { return false }
        return first != UInt8(ascii: ".") && first != UInt8(ascii: "-")
    }

    static func isTree(_ t: String) -> Bool { t.utf8.count == 64 && t.utf8.allSatisfy { Set("0123456789abcdef".utf8).contains($0) } }

    static func stagedName(_ version: String, _ tree: String) -> String { version + "+" + tree }

    func stagedPath(_ version: String, _ tree: String) -> String { layout.staged + "/" + Self.stagedName(version, tree) }

    /// kits/<ext-id> and its dirs, mode 0700: a wider one is narrowed, a link or a file in a dir's place is refused.
    /// prosper/ and kits/ are created when missing, never re-moded (a link there is refused all the same).
    func ensureLayout() throws {
        try fs.ensureDir(layout.prosper, narrow: false)
        try fs.ensureDir(layout.kits, narrow: false)
        try fs.ensureDir(layout.root, narrow: true)
        for d in layout.dirs { try fs.ensureDir(d, narrow: true) }
    }

    /// readdir through the stream seam; a read error part-way is nil, never a short list.
    static func listNames(_ dir: String, _ stream: any KitDirStream) -> [String]? {
        let fd = Darwin.open(dir, dirFlags)
        guard fd >= 0 else { return nil }
        defer { _ = close(fd) }
        return listNames(fd: fd, dir, stream)
    }

    static func listNames(fd: Int32, _ dir: String, _ stream: any KitDirStream) -> [String]? {
        guard let h = stream.open(dir, fd: fd) else { return nil }
        var out: [String] = []
        while out.count <= KitValidator.maxEntries { // one past the bound is enough for the walk to refuse
            let (bytes, error) = h.next()
            guard let bytes else { if error != 0 { return nil }; break }
            let name = KitPOSIXFileReader.name(bytes)
            if name != ".", name != ".." { out.append(name) }
        }
        return out.sorted()
    }

    /// One entry of a walk: `mode` nil for a dir; a file's mode is normalized (see `copyMode`).
    struct Entry: Equatable {
        var rel: String
        var mode: mode_t?
        var data: Data
    }

    /// A copied file keeps the owner bits only: 0700 when the source has ANY x bit (so the validator still sees an
    /// executable), else 0600. setuid / setgid are refused before this.
    static func copyMode(_ mode: UInt16) -> mode_t { mode & 0o111 != 0 ? 0o700 : 0o600 }

    /// The no-follow walk the copy, the hash and the render share. The validator's bounds apply DURING the walk
    /// (4096 entries, a dir 16 deep refused, KitValidator.swift:267-275), and so does the byte cap: a huge tree stops early.
    func walk(_ root: String, byteCap: Int) throws -> [Entry] {
        guard byteCap >= 0 else { throw KitStoreError.tooLarge }
        switch fs.kind(root) {
        case .directory: break
        case .symlink: throw KitStoreError.link("")
        default: throw KitStoreError.notADirectory("")
        }
        guard let rootDir = try? fs.openDir(root) else { throw KitStoreError.unreadableDir("") }
        var out: [Entry] = []
        // a child dir is opened (relative to its parent's descriptor) only when it is popped: few descriptors open at once
        var stack: [(rel: String, depth: Int, parent: (any KitDir)?, name: String)] = [("", 0, nil, "")]
        var count = 0
        var bytes = 0
        while let top = stack.popLast() {
            let (rel, depth) = (top.rel, top.depth)
            let here: any KitDir
            if let parent = top.parent {
                do { here = try parent.dir(top.name) } catch KitStoreError.link(_) { throw KitStoreError.link(rel) } catch { throw KitStoreError.unreadableDir(rel) }
            } else {
                here = rootDir
            }
            guard let names = here.names() else { throw KitStoreError.unreadableDir(rel) }
            for name in names {
                count += 1
                guard count <= KitValidator.maxEntries else { throw KitStoreError.tooManyFiles }
                guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else { throw KitStoreError.badName(rel) }
                let r = rel.isEmpty ? name : rel + "/" + name
                switch here.kind(name) {
                case .directory:
                    guard depth + 1 < KitValidator.maxDepth else { throw KitStoreError.tooDeep }
                    out.append(Entry(rel: r, mode: nil, data: Data()))
                    stack.append((r, depth + 1, here, name))
                case .file(let mode, let size):
                    guard mode & 0o6000 == 0 else { throw KitStoreError.setuid(r) }
                    let room = byteCap - bytes
                    guard size <= Int64(room) else { throw KitStoreError.tooLarge }
                    guard let data = here.read(name, limit: room) else { throw KitStoreError.special(r) }
                    bytes += data.count
                    out.append(Entry(rel: r, mode: Self.copyMode(mode), data: data))
                case .symlink: throw KitStoreError.link(r)
                case .missing, .other: throw KitStoreError.special(r)
                }
            }
        }
        return out
    }

    /// Copies `source` into staged/<version>+<tree> through tmp/ and ONE rename at the end. A refused or failed copy
    /// leaves no staged dir; its tmp dir is removed by the store's own remove. `tree` is the ANNOUNCED tree: `verify`
    /// checks the copy against it. A copy already staged under the same version and tree is replaced.
    func stageCopy(from source: String, version: String, tree: String, byteCap: Int) throws -> KitStaged {
        guard Self.isValidVersion(version) else { throw KitStoreError.badVersion }
        guard Self.isTree(tree) else { throw KitStoreError.badTree }
        let entries = try walk(source, byteCap: byteCap)
        try ensureLayout()
        let tmp = layout.tmp + "/" + UUID().uuidString
        try fs.ensureDir(tmp, narrow: true)
        do {
            // a dir's entry precedes its children's (the walk lists a dir before it lists the dir's names)
            for e in entries {
                if let mode = e.mode { try fs.create(tmp + "/" + e.rel, e.data, mode: mode) } else { try fs.ensureDir(tmp + "/" + e.rel, narrow: true) }
            }
            let dest = stagedPath(version, tree)
            if fs.kind(dest) != .missing { try removeTree(dest) }
            try fs.rename(tmp, dest)
            return KitStaged(version: version, tree: tree, path: dest, source: source)
        } catch {
            try? removeTree(tmp)
            throw error
        }
    }

    /// Hex SHA-256 of a tree. Entries sorted by the UTF-8 bytes of their relative path; each entry adds
    ///   1 byte tag ("d" dir, "f" file) | 2 bytes mode, big-endian (0700 for a dir, `copyMode` for a file) |
    ///   8 bytes path length, big-endian | path bytes | 8 bytes content length, big-endian | content bytes (none for a dir).
    /// Every variable field is length-prefixed, so two different trees cannot meet by concatenation.
    /// The root itself is not an entry. A link, special file or bound hit throws, as in the copy.
    func treeHash(of dir: String, byteCap: Int = KitStore.localByteCap) throws -> String {
        let entries = try walk(dir, byteCap: byteCap).sorted { $0.rel.utf8.lexicographicallyPrecedes($1.rel.utf8) }
        var h = SHA256()
        for e in entries {
            h.update(data: [e.mode == nil ? UInt8(ascii: "d") : UInt8(ascii: "f")])
            var m = UInt16(e.mode ?? Self.dirMode).bigEndian
            withUnsafeBytes(of: &m) { h.update(bufferPointer: $0) }
            Self.frame(Data(e.rel.utf8), into: &h)
            Self.frame(e.data, into: &h)
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func frame(_ d: Data, into h: inout SHA256) {
        var n = UInt64(d.count).bigEndian
        withUnsafeBytes(of: &n) { h.update(bufferPointer: $0) }
        h.update(data: d)
    }

    /// nil when the copy hashes to the announced tree; else the machine's answer (rider R917-s4b-b).
    /// Run it before `render`: the render changes the Markdown bytes.
    func verify(_ s: KitStaged) -> KitUpdateEvent? {
        guard let h = try? treeHash(of: s.path), h == s.tree else { return .validationRefused(s.version, tree: s.tree) }
        return nil
    }

    /// QA #749 INFO-2: the validator sees the staged COPY only, never the source.
    func validate(_ s: KitStaged, manifest: ExtensionManifest, source: KitInstallSource, otherKitSlugs: Set<String>,
                  reader: any KitFileReader = KitPOSIXFileReader()) -> KitValidation {
        KitValidator.validate(kitDir: URL(fileURLWithPath: s.path, isDirectory: true), manifest: manifest, source: source,
                              otherKitSlugs: otherKitSlugs, reader: reader)
    }

    /// spec 4.2 / 4.12 test 2: `*.md` in the staged copy rendered in place through the atomic writer, mode kept;
    /// every other file is never rewritten.
    func render(_ s: KitStaged, _ c: KitRenderContext) throws {
        for e in try walk(s.path, byteCap: Self.localByteCap) where e.mode != nil && KitRender.isRendered(e.rel) {
            let out = KitRender.renderFile(e.rel, e.data, c)
            guard out != e.data, let mode = e.mode else { continue }
            let target = URL(fileURLWithPath: s.path + "/" + e.rel)
            try fs.writer.replace(target, with: fs.writer.writeTemp(Array(out), besides: target, mode: mode))
        }
    }

    /// Rider R917-s4b-a: the drop names the tree it means; a drop for a tree that is not staged removes nothing.
    func dropStaged(version: String, tree: String) throws {
        guard Self.isValidVersion(version), Self.isTree(tree) else { return }
        try removeTree(stagedPath(version, tree))
    }

    /// E-2: the slug recorded at first apply. A later call returns the recorded one and writes nothing.
    func recordSlug(_ slug: String) throws -> String {
        guard ManagedConfigPaths.isValidSlug(slug), !slug.hasPrefix("-") else { throw KitStoreError.badSlug }
        if let old = recordedSlug() { return old }
        guard fs.kind(layout.kitEnv) == .missing else { throw KitStoreError.kitEnvUnreadable }
        try ensureLayout()
        let target = URL(fileURLWithPath: layout.kitEnv)
        try fs.writer.replace(target, with: fs.writer.writeTemp(Array("KIT_SLUG='\(slug)'\n".utf8), besides: target, mode: Self.envMode))
        return slug
    }

    /// The slug kit.env records; nil when there is none or it is not a valid slug. Parsed as text, never sourced.
    func recordedSlug() -> String? {
        guard let d = fs.read(layout.kitEnv, limit: 4096), let text = String(data: d, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("KIT_SLUG='") && line.hasSuffix("'") && line.count > 11 {
            let slug = String(line.dropFirst(10).dropLast())
            return ManagedConfigPaths.isValidSlug(slug) && !slug.hasPrefix("-") ? slug : nil
        }
        return nil
    }

    /// The store's only remove: strictly inside kits/<ext-id>/, never a glob; a link is unlinked, never followed.
    /// Directory-relative from kits/<ext-id> opened O_NOFOLLOW: a link in place of a dir on the way is refused.
    func removeTree(_ path: String) throws {
        let head = layout.root + "/"
        let parts: [Substring] = path.hasPrefix(head) ? path.dropFirst(head.count).split(separator: "/", omittingEmptySubsequences: false) : []
        guard let last = parts.last, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw KitStoreError.outsideStore }
        guard fs.kind(layout.root) != .missing else { return }
        var parent = try fs.openDir(layout.root)
        for p in parts.dropLast() {
            guard parent.kind(String(p)) != .missing else { return }
            parent = try parent.dir(String(p))
        }
        try removeEntry(parent, String(last))
    }

    /// Removes `name` in `parent` and everything below it, each step relative to the descriptor of the dir it is in.
    private func removeEntry(_ parent: any KitDir, _ name: String) throws {
        var stack: [(parent: any KitDir, name: String, listed: (any KitDir)?)] = [(parent, name, nil)]
        while let top = stack.popLast() {
            if top.listed != nil { try top.parent.remove(top.name, dir: true); continue }
            switch top.parent.kind(top.name) {
            case .missing: continue
            case .directory:
                let d = try top.parent.dir(top.name)
                guard let names = d.names() else { throw KitStoreError.unreadableDir(d.path) }
                stack.append((top.parent, top.name, d))
                for n in names where KitPOSIXDir.isName(n) { stack.append((d, n, nil)) }
            default: try top.parent.remove(top.name, dir: false)
            }
        }
    }

    private static func requireDir(_ dir: any KitDir, _ name: String, label: String) throws {
        switch dir.kind(name) {
        case .directory: return
        case .symlink: throw KitStoreError.link(label)
        default: throw KitStoreError.notADirectory(label)
        }
    }

    /// The swap into live (plan C S5; ruling r-917s5b1a): the staged copy goes to kits/<ext-id>/incoming (a fixed name that
    /// is no version key), then incoming and live trade places in ONE renameatx_np(RENAME_SWAP), so live is never missing
    /// and the old live never sits under a staged <version>+<tree> name; it then becomes previous. An existing previous
    /// becomes `retiring` (the machine's retiring, KitUpdate .swapped) until dropRetiring or restoreRetiring. On the first
    /// apply (no live yet) incoming -> live never replaces anything (RENAME_EXCL). A stale incoming or retiring is removed
    /// first by the store's own remove, by its literal name. Every step is relative to kits/<ext-id> opened O_NOFOLLOW.
    func swap(version: String, tree: String) throws {
        guard Self.isValidVersion(version) else { throw KitStoreError.badVersion }
        guard Self.isTree(tree) else { throw KitStoreError.badTree }
        try ensureLayout()
        let root = try fs.openDir(layout.root)
        let staged = try root.dir("staged")
        let name = Self.stagedName(version, tree)
        try Self.requireDir(staged, name, label: stagedPath(version, tree))
        let live = root.kind("live")
        switch live {
        case .missing, .directory: break
        case .symlink: throw KitStoreError.link(layout.live)
        default: throw KitStoreError.notADirectory(layout.live)
        }
        try removeEntry(root, "incoming")
        try removeEntry(root, "retiring") // always: the machine's retiring after this swap is the current previous or none
        try staged.rename(name, to: root, "incoming", swap: false)
        guard live == .directory else { return try root.rename("incoming", to: root, "live", swap: false) }
        if root.kind("previous") != .missing {
            try root.rename("previous", to: root, "retiring", swap: false)
        }
        try root.rename("incoming", to: root, "live", swap: true)
        try root.rename("incoming", to: root, "previous", swap: false) // the old live, now at incoming
    }

    /// The machine's dropPrevious after wiringApplied: the retiring copy goes. None there: nothing to do.
    func dropRetiring() throws {
        try removeTree(layout.root + "/retiring")
    }

    /// The disk half of a failed apply AFTER swapBack (live = the old live, previous = the failed new): the failed new is
    /// removed and retiring, when there is one, becomes previous again (none: no previous).
    func restoreRetiring() throws {
        let root = try fs.openDir(layout.root)
        try removeEntry(root, "previous")
        guard root.kind("retiring") != .missing else { return }
        try Self.requireDir(root, "retiring", label: layout.root + "/retiring")
        try root.rename("retiring", to: root, "previous", swap: false)
    }

    /// The rollback: live and previous trade places in ONE renameatx_np(RENAME_SWAP); both must be real dirs.
    func swapBack() throws {
        let root = try fs.openDir(layout.root)
        try Self.requireDir(root, "live", label: layout.live)
        try Self.requireDir(root, "previous", label: layout.previous)
        try root.rename("previous", to: root, "live", swap: true)
    }

    /// Plan A7 for the store's own temps: in kits/<ext-id>/tmp only, an entry named as stageCopy names its temp (a
    /// UUID string), a dir or a regular file (fstatat no-follow: a link is kept, never followed), older than
    /// `staleTempAge` by the injected clock `now`. Returns the names removed.
    @discardableResult
    func sweepStaleTemps(now: Date) throws -> [String] {
        guard fs.kind(layout.root) != .missing else { return [] }
        let root = try fs.openDir(layout.root)
        guard root.kind("tmp") != .missing else { return [] }
        let tmp = try root.dir("tmp")
        guard let names = tmp.names() else { throw KitStoreError.unreadableDir(tmp.path) }
        var removed: [String] = []
        for n in names where UUID(uuidString: n)?.uuidString == n {
            switch tmp.kind(n) {
            case .directory, .file: break
            default: continue
            }
            guard let m = tmp.modified(n), now.timeIntervalSince(m) > Self.staleTempAge else { continue }
            try removeEntry(tmp, n)
            removed.append(n)
        }
        return removed
    }
}
