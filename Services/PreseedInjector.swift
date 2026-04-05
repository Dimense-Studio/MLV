import Foundation

struct PreseedInjector {
    static func inject(preseed: String, into initrd: URL, cacheDir: URL) async throws -> URL {
        let fm = FileManager.default
        let work = cacheDir.appendingPathComponent("initrd-work-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let initrdCopy = work.appendingPathComponent("initrd.gz")
        if fm.fileExists(atPath: initrdCopy.path) { try fm.removeItem(at: initrdCopy) }
        try fm.copyItem(at: initrd, to: initrdCopy)

        let gunzip = Process()
        gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        gunzip.arguments = [initrdCopy.path]
        try gunzip.run()
        gunzip.waitUntilExit()

        let cpioPath = initrdCopy.deletingPathExtension().path
        let preseedPath = work.appendingPathComponent("preseed.cfg")
        try preseed.write(to: preseedPath, atomically: true, encoding: .utf8)

        // Append preseed.cfg into cpio archive
        let cpio = Process()
        cpio.executableURL = URL(fileURLWithPath: "/usr/bin/bash")
        cpio.arguments = ["-c", "cd \"\(work.path)\" && echo preseed.cfg | cpio -o -H newc -A -F \"\(cpioPath)\""]
        try cpio.run()
        cpio.waitUntilExit()

        // Gzip back
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-f", cpioPath]
        try gzip.run()
        gzip.waitUntilExit()

        let patched = cacheDir.appendingPathComponent("initrd-preseed.gz")
        if fm.fileExists(atPath: patched.path) { try fm.removeItem(at: patched) }
        try fm.copyItem(at: initrdCopy, to: patched)
        try? fm.removeItem(at: work)
        return patched
    }
}
