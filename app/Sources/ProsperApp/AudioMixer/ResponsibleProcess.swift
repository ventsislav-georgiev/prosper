// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Darwin

/// Maps helper processes to the app responsible for them and gives processes
/// a human name. Shared by the resource breakdown and the volume mixer, so
/// helper processes roll up into their app with its proper icon.
enum ResponsibleProcess {
    /// Default icon size for a mixer row.
    static let defaultIconPointSize: CGFloat = 32

    /// Rough bitmap footprint of one cached icon at @2x, used as the cache cost.
    private static func estimatedBitmapCost(pointSize: CGFloat) -> Int {
        Int(pointSize * 2) * Int(pointSize * 2) * 4
    }

    /// A copy sized to `pointSize`. NSImage picks the closest representation
    /// when it draws, so this is enough to keep app icons crisp without
    /// rasterizing them ourselves.
    private static func resized(_ image: NSImage, pointSize: CGFloat) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: pointSize, height: pointSize)
        return copy
    }

    // NSCache is documented as thread-safe, so the shared instance needs no
    // actor of its own.
    nonisolated(unsafe) private static let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 80
        cache.totalCostLimit = estimatedBitmapCost(pointSize: 32) * 80
        return cache
    }()

    /// `responsibility_get_pid_responsible_for_pid`, exported by libsystem and
    /// used by the system for the same grouping; resolved at runtime so a
    /// missing symbol degrades to per-process rows instead of breaking.
    private static let resolve: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */,
                                 "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    static func owner(of pid: pid_t) -> pid_t {
        guard let resolve else { return pid }
        let owner = resolve(pid)
        return owner > 0 ? owner : pid
    }

    /// The regular app to bill the process to, following the parent chain
    /// when the responsibility API dead-ends on a helper that answers for
    /// itself (browser audio helpers, issue #256). Nil when no ancestor is
    /// a regular app — daemons and login items stay unlisted.
    static func regularAppOwner(of pid: pid_t) -> NSRunningApplication? {
        MixerRoutingSupport.owningRegularAppPid(
            responsiblePid: owner(of: pid),
            isRegularApp: { NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular },
            parentPid: parent(of:)
        ).flatMap(NSRunningApplication.init(processIdentifier:))
    }

    private static func parent(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
        return pid_t(info.pbi_ppid)
    }

    /// Prefers the app's localized name; system processes fall back to their
    /// kernel-reported name (e.g. "WindowServer"), then to the caller's hint.
    static func displayName(pid: pid_t, fallback: String) -> String {
        if let app = NSRunningApplication(processIdentifier: pid),
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        var buffer = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            let name = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                              as: UTF8.self)
            if !name.isEmpty { return name }
        }
        return fallback.trimmingCharacters(in: .whitespaces)
    }

    /// The icon is cached per requested point size, so callers that draw it
    /// larger (the mixer rows) must ask for that size or the upscale looks
    /// blurry.
    static func icon(for pid: pid_t,
                     pointSize: CGFloat = defaultIconPointSize) -> NSImage {
        let key = "\(pid)@\(Int(pointSize))" as NSString
        let cost = estimatedBitmapCost(pointSize: pointSize)
        if let cached = iconCache.object(forKey: key) { return cached }
        let source = NSRunningApplication(processIdentifier: pid)?.icon
            ?? NSWorkspace.shared.icon(for: .unixExecutable)
        let image = resized(source, pointSize: pointSize)
        iconCache.setObject(image, forKey: key, cost: cost)
        return image
    }

    static func clearIconCache() {
        iconCache.removeAllObjects()
    }
}
