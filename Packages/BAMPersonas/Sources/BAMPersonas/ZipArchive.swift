import Foundation

/// Minimal ZIP writer/reader (STORE method only — no compression).
///
/// Sufficient for Pack Format v1 (open zip+JSON). Avoids third-party deps and
/// shelling out to `zip`/`ditto` so unit tests stay hermetic.
enum ZipArchive: Sendable {
    /// Creates a zip file at `destination` containing every file under `sourceDirectory`.
    /// Paths inside the archive are relative to `sourceDirectory` using `/` separators.
    static func createZip(ofContentsOf sourceDirectory: URL, to destination: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceDirectory.path, isDirectory: &isDir), isDir.boolValue else {
            throw BAMZipError.sourceNotDirectory(sourceDirectory.path)
        }

        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }

        let entries = try collectFiles(under: sourceDirectory)
        var localChunks: [Data] = []
        var centralChunks: [Data] = []
        var offset: UInt32 = 0

        for entry in entries {
            let fileData = try Data(contentsOf: entry.absoluteURL)
            let nameData = Data(entry.relativePath.utf8)
            let crc = crc32(fileData)
            let size = UInt32(fileData.count)

            var local = Data()
            local.append(contentsOf: u32(0x0403_4b50)) // local file header sig
            local.append(contentsOf: u16(20)) // version needed
            local.append(contentsOf: u16(0)) // flags
            local.append(contentsOf: u16(0)) // compression = store
            local.append(contentsOf: u16(0)) // mod time
            local.append(contentsOf: u16(0)) // mod date
            local.append(contentsOf: u32(crc))
            local.append(contentsOf: u32(size))
            local.append(contentsOf: u32(size))
            local.append(contentsOf: u16(UInt16(nameData.count)))
            local.append(contentsOf: u16(0)) // extra len
            local.append(nameData)
            local.append(fileData)

            var central = Data()
            central.append(contentsOf: u32(0x0201_4b50)) // central dir sig
            central.append(contentsOf: u16(20)) // version made by
            central.append(contentsOf: u16(20)) // version needed
            central.append(contentsOf: u16(0)) // flags
            central.append(contentsOf: u16(0)) // compression
            central.append(contentsOf: u16(0)) // mod time
            central.append(contentsOf: u16(0)) // mod date
            central.append(contentsOf: u32(crc))
            central.append(contentsOf: u32(size))
            central.append(contentsOf: u32(size))
            central.append(contentsOf: u16(UInt16(nameData.count)))
            central.append(contentsOf: u16(0)) // extra
            central.append(contentsOf: u16(0)) // comment
            central.append(contentsOf: u16(0)) // disk start
            central.append(contentsOf: u16(0)) // int attrs
            central.append(contentsOf: u32(0)) // ext attrs
            central.append(contentsOf: u32(offset))
            central.append(nameData)

            localChunks.append(local)
            centralChunks.append(central)
            offset += UInt32(local.count)
        }

        var zip = Data()
        for c in localChunks { zip.append(c) }
        let centralStart = UInt32(zip.count)
        for c in centralChunks { zip.append(c) }
        let centralSize = UInt32(zip.count) - centralStart
        let count = UInt16(entries.count)

        // End of central directory
        zip.append(contentsOf: u32(0x0605_4b50))
        zip.append(contentsOf: u16(0)) // disk
        zip.append(contentsOf: u16(0)) // disk with CD
        zip.append(contentsOf: u16(count))
        zip.append(contentsOf: u16(count))
        zip.append(contentsOf: u32(centralSize))
        zip.append(contentsOf: u32(centralStart))
        zip.append(contentsOf: u16(0)) // comment len

        try zip.write(to: destination, options: .atomic)
    }

    /// Extracts a STORE-method zip into `destinationDirectory` (created if needed).
    static func extractZip(at zipURL: URL, to destinationDirectory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let data = try Data(contentsOf: zipURL)
        var offset = 0

        while offset + 4 <= data.count {
            let sig = readU32(data, offset)
            if sig == 0x0201_4b50 || sig == 0x0605_4b50 {
                break // central directory / EOCD
            }
            guard sig == 0x0403_4b50 else {
                throw BAMZipError.invalidZip("Bad local header signature at \(offset)")
            }
            guard offset + 30 <= data.count else {
                throw BAMZipError.invalidZip("Truncated local header")
            }
            let compression = readU16(data, offset + 8)
            let compSize = Int(readU32(data, offset + 18))
            let nameLen = Int(readU16(data, offset + 26))
            let extraLen = Int(readU16(data, offset + 28))
            let nameStart = offset + 30
            let nameEnd = nameStart + nameLen
            guard nameEnd + extraLen + compSize <= data.count else {
                throw BAMZipError.invalidZip("Truncated file entry")
            }
            guard compression == 0 else {
                throw BAMZipError.invalidZip("Only STORE (method 0) is supported; got \(compression)")
            }
            let nameData = data.subdata(in: nameStart..<nameEnd)
            guard let relative = String(data: nameData, encoding: .utf8), !relative.isEmpty else {
                throw BAMZipError.invalidZip("Invalid entry name")
            }
            // Path jail: reject absolute / traversal.
            if relative.hasPrefix("/") || relative.contains("..") {
                throw BAMZipError.invalidZip("Unsafe path in archive: \(relative)")
            }
            let fileStart = nameEnd + extraLen
            let fileEnd = fileStart + compSize
            let fileBytes = data.subdata(in: fileStart..<fileEnd)
            let outURL = destinationDirectory.appendingPathComponent(relative)
            try fm.createDirectory(
                at: outURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileBytes.write(to: outURL, options: .atomic)
            offset = fileEnd
        }
    }

    // MARK: - Helpers

    private struct FileEntry {
        var relativePath: String
        var absoluteURL: URL
    }

    private static func collectFiles(under root: URL) throws -> [FileEntry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var result: [FileEntry] = []
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { continue }
            var rel = String(path.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
            guard !rel.isEmpty else { continue }
            result.append(FileEntry(relativePath: rel, absoluteURL: url))
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private static func u16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]
    }

    private static func u32(_ v: UInt32) -> [UInt8] {
        [
            UInt8(v & 0xff),
            UInt8((v >> 8) & 0xff),
            UInt8((v >> 16) & 0xff),
            UInt8((v >> 24) & 0xff),
        ]
    }

    private static func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    /// IEEE CRC-32 (ZIP).
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xff)
            crc = (crc >> 8) ^ crcTable[idx]
        }
        return crc ^ 0xffff_ffff
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                if c & 1 != 0 {
                    c = 0xedb8_8320 ^ (c >> 1)
                } else {
                    c = c >> 1
                }
            }
            return c
        }
    }()
}

enum BAMZipError: Error, Equatable, LocalizedError {
    case sourceNotDirectory(String)
    case invalidZip(String)

    var errorDescription: String? {
        switch self {
        case .sourceNotDirectory(let p): return "Not a directory: \(p)"
        case .invalidZip(let m): return "Invalid zip: \(m)"
        }
    }
}
