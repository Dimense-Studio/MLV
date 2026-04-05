import Foundation

actor DebianNetbootFetcher {
    static let shared = DebianNetbootFetcher()
    private var cached: (URL, URL)?

    func fetch(to cacheDir: URL) async -> (URL, URL)? {
        if let cached { return cached }
        let fm = FileManager.default
        let kernelURL = cacheDir.appendingPathComponent("netboot-linux")
        let initrdURL = cacheDir.appendingPathComponent("netboot-initrd.gz")
        let base = "https://deb.debian.org/debian/dists/testing/main/installer-amd64/current/images/netboot/debian-installer/amd64"
        guard
            download("\(base)/linux", to: kernelURL),
            download("\(base)/initrd.gz", to: initrdURL)
        else { return nil }
        cached = (kernelURL, initrdURL)
        return cached
    }

    private func download(_ url: String, to dest: URL) -> Bool {
        guard let u = URL(string: url), let data = try? Data(contentsOf: u) else { return false }
        try? data.write(to: dest)
        return true
    }
}
