import Foundation
import Virtualization

class VMStorageManager {
    static let shared = VMStorageManager()
    
    private let isoCacheName = "mlv-iso-cache"
    
    func getVMRootDirectory(for id: UUID) -> URL {
        let containerDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return containerDir.appendingPathComponent("mlv-\(id.uuidString)", isDirectory: true)
    }
    
    func ensureVMDirectoryExists(for id: UUID) throws -> URL {
        let dir = getVMRootDirectory(for: id)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    func createSparseDisk(at url: URL, sizeGiB: Int) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let fileHandle = try FileHandle(forWritingTo: url)
            try fileHandle.truncate(atOffset: UInt64(sizeGiB) * 1024 * 1024 * 1024)
            try fileHandle.close()
        }
    }
    
    func getISOCacheDirectory() throws -> URL {
        let containerDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let cacheDir = containerDir.appendingPathComponent(isoCacheName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: cacheDir.path) {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
        return cacheDir
    }
    
    func cleanupVMDirectory(for id: UUID) {
        let dir = getVMRootDirectory(for: id)
        try? FileManager.default.removeItem(at: dir)
    }
}
