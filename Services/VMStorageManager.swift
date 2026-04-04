import Foundation
import Virtualization
import Darwin

class VMStorageManager {
    static let shared = VMStorageManager()
    
    private let isoCacheName = "mlv-iso-cache"
    private let sharedFolderName = "shared"
    
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

    func ensureVMSharedDirectoryExists(for id: UUID) throws -> URL {
        let vmDir = try ensureVMDirectoryExists(for: id)
        let sharedDir = vmDir.appendingPathComponent(sharedFolderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: sharedDir.path) {
            try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        }
        return sharedDir
    }
    
    func createSparseDisk(at url: URL, sizeGiB: Int, preallocate: Bool = false) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        
        let fd = open(url.path, O_RDWR)
        if fd == -1 {
            throw CocoaError(.fileWriteNoPermission)
        }
        defer { close(fd) }
        
        let targetSize = off_t(UInt64(sizeGiB) * 1024 * 1024 * 1024)
        let currentSize = lseek(fd, 0, SEEK_END)
        if currentSize < 0 {
            throw CocoaError(.fileReadUnknown)
        }
        
        if currentSize != targetSize {
            if ftruncate(fd, targetSize) != 0 {
                throw CocoaError(.fileWriteUnknown)
            }
            
            if preallocate, targetSize > 0, currentSize < targetSize {
                var store = fstore_t(
                    fst_flags: UInt32(F_ALLOCATECONTIG),
                    fst_posmode: Int32(F_PEOFPOSMODE),
                    fst_offset: 0,
                    fst_length: targetSize,
                    fst_bytesalloc: 0
                )
                if fcntl(fd, F_PREALLOCATE, &store) == -1 {
                    store.fst_flags = UInt32(F_ALLOCATEALL)
                    _ = fcntl(fd, F_PREALLOCATE, &store)
                }
            }
        }
        
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }
    
    func getISOCacheDirectory() throws -> URL {
        let containerDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        var cacheDir = containerDir.appendingPathComponent(isoCacheName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: cacheDir.path) {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? cacheDir.setResourceValues(values)
        return cacheDir
    }
    
    func cleanupVMDirectory(for id: UUID) {
        let dir = getVMRootDirectory(for: id)
        try? FileManager.default.removeItem(at: dir)
    }
}
