import Foundation
import DataContracts

/// Bounded ZIP32 stored-entry profile, not a general archive extractor. Only the two
/// names in our backup format are accepted. Nothing is materialized as an archive path.
/// Layout follows PKWARE APPNOTE 6.3.10 (local header, central directory, EOCD).
enum ResearchZIP {
    static let maximumArchive = 2_147_483_648
    static let maximumFile = 1_073_741_824
    static let names = ["manifest.json", "research-state.json"]
    static func crc(_ data: Data) -> UInt32 {
        var result: UInt32 = 0xffff_ffff
        for byte in data { result ^= UInt32(byte); for _ in 0..<8 { result = (result >> 1) ^ ((result & 1) == 1 ? 0xedb8_8320 : 0) } }
        return result ^ 0xffff_ffff
    }
    static func encode(_ files: [String: Data]) throws -> Data {
        guard Set(files.keys) == Set(names) else { throw SnapshotError.unsafeArchive }
        var result = Data(), central = Data()
        for name in names {
            let content = files[name]!, path = Data(name.utf8)
            guard content.count <= maximumFile, result.count + content.count + 1024 <= maximumArchive else { throw SnapshotError.resourceLimit }
            let offset = result.count, checksum = crc(content)
            result.put(0x04034b50,4); result.put(20,2); result.put(0,2); result.put(0,2)
            result.put(0,2); result.put(33,2); result.put(UInt64(checksum),4)
            result.put(UInt64(content.count),4); result.put(UInt64(content.count),4)
            result.put(UInt64(path.count),2); result.put(0,2); result.append(path); result.append(content)
            central.put(0x02014b50,4); central.put(0x0314,2); central.put(20,2); central.put(0,2); central.put(0,2)
            central.put(0,2); central.put(33,2); central.put(UInt64(checksum),4)
            central.put(UInt64(content.count),4); central.put(UInt64(content.count),4)
            central.put(UInt64(path.count),2); central.put(0,2); central.put(0,2); central.put(0,2); central.put(0,2)
            central.put(UInt64(0o100644) << 16,4); central.put(UInt64(offset),4); central.append(path)
        }
        let offset = result.count; result.append(central)
        result.put(0x06054b50,4); result.put(0,2); result.put(0,2); result.put(2,2); result.put(2,2)
        result.put(UInt64(central.count),4); result.put(UInt64(offset),4); result.put(0,2)
        return result
    }
    static func decode(_ bytes: Data) throws -> [String: Data] {
        guard bytes.count <= maximumArchive else { throw SnapshotError.resourceLimit }
        guard bytes.count >= 22 else { throw SnapshotError.unsafeArchive }
        func u(_ start: Int, _ count: Int) throws -> Int {
            guard start >= 0, start <= bytes.count, count <= bytes.count - start else { throw SnapshotError.unsafeArchive }
            return (0..<count).reduce(0) { $0 | Int(bytes[start+$1]) << (8*$1) }
        }
        let end = bytes.count - 22
        guard (try u(end,4)) == 0x06054b50, (try u(end+4,2)) == 0, (try u(end+6,2)) == 0,
              (try u(end+8,2)) == 2, (try u(end+10,2)) == 2, (try u(end+20,2)) == 0 else { throw SnapshotError.unsafeArchive }
        let centralStart = (try u(end+16,4)), centralSize = (try u(end+12,4))
        guard centralStart <= end, centralSize == end-centralStart else { throw SnapshotError.unsafeArchive }
        var cursor = centralStart, localCursor = 0, files: [String:Data] = [:]
        for _ in 0..<2 {
            guard (try u(cursor,4)) == 0x02014b50, (try u(cursor+6,2)) <= 20,
                  (try u(cursor+8,2)) == 0, (try u(cursor+10,2)) == 0,
                  (try u(cursor+30,2)) == 0, (try u(cursor+32,2)) == 0, (try u(cursor+34,2)) == 0 else { throw SnapshotError.unsupportedFormat }
            let packed = (try u(cursor+20,4)), size = (try u(cursor+24,4)), length = (try u(cursor+28,2))
            let offset = (try u(cursor+42,4)), checksum = (try u(cursor+16,4)), attributes = (try u(cursor+38,4))
            let type = (attributes >> 16) & 0xf000
            guard (type == 0 || type == 0x8000), attributes & 0x10 == 0,
                  offset == localCursor, size == packed, size <= maximumFile,
                  length > 0, length <= 64, cursor+46+length <= end else { throw SnapshotError.unsafeArchive }
            guard let name = String(data:bytes.subdata(in:cursor+46..<cursor+46+length),encoding:.utf8),
                  names.contains(name), files[name] == nil else { throw SnapshotError.unsafeArchive }
            guard (try u(offset,4)) == 0x04034b50, (try u(offset+4,2)) <= 20,
                  (try u(offset+6,2)) == 0, (try u(offset+8,2)) == 0, (try u(offset+14,4)) == checksum,
                  (try u(offset+18,4)) == packed, (try u(offset+22,4)) == size,
                  (try u(offset+26,2)) == length, (try u(offset+28,2)) == 0,
                  offset+30+length <= centralStart,
                  bytes.subdata(in:offset+30..<offset+30+length) == Data(name.utf8) else { throw SnapshotError.unsafeArchive }
            let start = offset+30+length
            guard size <= centralStart-start else { throw SnapshotError.unsafeArchive }
            let content = bytes.subdata(in:start..<start+size)
            guard Int(crc(content)) == checksum else { throw SnapshotError.hashMismatch }
            files[name] = content; localCursor = start+size; cursor += 46+length
        }
        guard cursor == end, localCursor == centralStart, Set(files.keys) == Set(names) else { throw SnapshotError.unsafeArchive }
        return files
    }
}
private extension Data {
    mutating func put(_ value: UInt64, _ count: Int) { for i in 0..<count { append(UInt8(truncatingIfNeeded:value >> (8*i))) } }
}
