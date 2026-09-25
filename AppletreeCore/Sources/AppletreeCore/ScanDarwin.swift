import Darwin
import Foundation

struct BulkEntry {
    var name: String
    var objectType: UInt32
    var flags: UInt32
    var modified: Int64
    var fileID: UInt64
    var fsid: UInt64
    var hasFSID: Bool
    var error: Int32
    var allocated: Int64
    var length: Int64
    var hasSize: Bool
}

private let objectFile: UInt32 = 1
private let objectDirectory: UInt32 = 2
private let objectSymlink: UInt32 = 5

func nodeKind(of objectType: UInt32) -> NodeKind {
    switch objectType {
    case objectDirectory: .directory
    case objectFile: .file
    case objectSymlink: .symlink
    default: .other
    }
}

enum DirectoryList {
    case entries([BulkEntry])
    case unreadable(String)
}

func listDirectory(_ path: String) -> DirectoryList {
    let fd = path.withCString { open($0, O_RDONLY) }
    if fd < 0 {
        return .unreadable(String(cString: strerror(errno)))
    }
    defer { close(fd) }

    let common = attrBit(ATTR_CMN_RETURNED_ATTRS)
        | attrBit(ATTR_CMN_NAME)
        | attrBit(ATTR_CMN_FSID)
        | attrBit(ATTR_CMN_OBJTYPE)
        | attrBit(ATTR_CMN_MODTIME)
        | attrBit(ATTR_CMN_FLAGS)
        | attrBit(ATTR_CMN_FILEID)
        | attrBit(ATTR_CMN_ERROR)
    let file = attrBit(ATTR_FILE_ALLOCSIZE) | attrBit(ATTR_FILE_DATALENGTH)
    var attributes = attrlist(
        bitmapcount: u_short(ATTR_BIT_MAP_COUNT),
        reserved: 0,
        commonattr: common,
        volattr: 0,
        dirattr: 0,
        fileattr: file,
        forkattr: 0
    )

    let capacity = 512 * 1024
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
    defer { buffer.deallocate() }

    var entries: [BulkEntry] = []
    while true {
        let count = getattrlistbulk(fd, &attributes, buffer, capacity, 0)
        if count < 0 {
            return .unreadable(String(cString: strerror(errno)))
        }
        if count == 0 { break }
        entries.append(contentsOf: parseBulk(buffer: buffer, capacity: capacity, count: Int(count)))
    }
    return .entries(entries)
}

/// `getattrlistbulk` packs each attribute on a 4-byte boundary and omits any
/// attribute whose bit is clear in `ATTR_CMN_RETURNED_ATTRS`. 64-bit fields are
/// not 8-byte aligned; reading them as aligned loads parses the wrong bytes.
func parseBulk(buffer: UnsafeRawPointer, capacity: Int, count: Int) -> [BulkEntry] {
    var entries: [BulkEntry] = []
    entries.reserveCapacity(count)
    var cursor = 0
    for _ in 0..<count {
        if cursor + 4 > capacity { break }
        let length = Int(readU32(buffer, cursor))
        if length < 4 || cursor + length > capacity { break }
        if let entry = parseRecord(buffer.advanced(by: cursor), length: length) {
            entries.append(entry)
        }
        cursor += length
    }
    return entries
}

private func parseRecord(_ record: UnsafeRawPointer, length: Int) -> BulkEntry? {
    var offset = 4
    guard offset + 20 <= length else { return nil }
    let common = readU32(record, &offset)
    _ = readU32(record, &offset)
    _ = readU32(record, &offset)
    let file = readU32(record, &offset)
    _ = readU32(record, &offset)

    var name = ""
    if common & attrBit(ATTR_CMN_NAME) != 0 {
        let refStart = align4(offset)
        guard refStart + 8 <= length else { return nil }
        let dataOffset = Int(readI32(record, &offset))
        let byteLength = Int(readU32(record, &offset))
        let stringAt = refStart + dataOffset
        if byteLength > 1, stringAt >= 0, stringAt + byteLength <= length {
            let bytes = Data(bytes: record.advanced(by: stringAt), count: byteLength - 1)
            name = String(decoding: bytes, as: UTF8.self)
        }
    }
    if name.isEmpty || name == "." || name == ".." { return nil }

    var fsid: UInt64 = 0
    var hasFSID = false
    if common & attrBit(ATTR_CMN_FSID) != 0 {
        guard align4(offset) + 8 <= length else { return nil }
        fsid = readU64(record, &offset)
        hasFSID = true
    }
    var objectType: UInt32 = 0
    if common & attrBit(ATTR_CMN_OBJTYPE) != 0 {
        guard align4(offset) + 4 <= length else { return nil }
        objectType = readU32(record, &offset)
    }
    var modified: Int64 = 0
    if common & attrBit(ATTR_CMN_MODTIME) != 0 {
        guard align4(offset) + 16 <= length else { return nil }
        modified = readI64(record, &offset)
        offset += 8
    }
    var flags: UInt32 = 0
    if common & attrBit(ATTR_CMN_FLAGS) != 0 {
        guard align4(offset) + 4 <= length else { return nil }
        flags = readU32(record, &offset)
    }
    var fileID: UInt64 = 0
    if common & attrBit(ATTR_CMN_FILEID) != 0 {
        guard align4(offset) + 8 <= length else { return nil }
        fileID = readU64(record, &offset)
    }
    var error: Int32 = 0
    if common & attrBit(ATTR_CMN_ERROR) != 0 {
        guard align4(offset) + 4 <= length else { return nil }
        error = readI32(record, &offset)
    }
    var allocated: Int64 = 0
    var dataLength: Int64 = 0
    var hasSize = false
    if file & attrBit(ATTR_FILE_ALLOCSIZE) != 0 {
        guard align4(offset) + 8 <= length else { return nil }
        allocated = readI64(record, &offset)
        hasSize = true
    }
    if file & attrBit(ATTR_FILE_DATALENGTH) != 0 {
        guard align4(offset) + 8 <= length else { return nil }
        dataLength = readI64(record, &offset)
        hasSize = true
    }
    return BulkEntry(
        name: name,
        objectType: objectType,
        flags: flags,
        modified: modified,
        fileID: fileID,
        fsid: fsid,
        hasFSID: hasFSID,
        error: error,
        allocated: allocated,
        length: dataLength,
        hasSize: hasSize
    )
}

func attrBit(_ value: Int32) -> UInt32 { UInt32(bitPattern: value) }
func attrBit(_ value: UInt32) -> UInt32 { value }

private func align4(_ offset: Int) -> Int { (offset + 3) & ~3 }

private func readU32(_ base: UnsafeRawPointer, _ offset: Int) -> UInt32 {
    var value: UInt32 = 0
    memcpy(&value, base.advanced(by: offset), 4)
    return value
}

private func readU32(_ base: UnsafeRawPointer, _ offset: inout Int) -> UInt32 {
    offset = align4(offset)
    let value = readU32(base, offset)
    offset += 4
    return value
}

private func readI32(_ base: UnsafeRawPointer, _ offset: inout Int) -> Int32 {
    Int32(bitPattern: readU32(base, &offset))
}

private func readU64(_ base: UnsafeRawPointer, _ offset: inout Int) -> UInt64 {
    offset = align4(offset)
    var value: UInt64 = 0
    memcpy(&value, base.advanced(by: offset), 8)
    offset += 8
    return value
}

private func readI64(_ base: UnsafeRawPointer, _ offset: inout Int) -> Int64 {
    Int64(bitPattern: readU64(base, &offset))
}

func hiddenFlag() -> UInt32 { UInt32(bitPattern: UF_HIDDEN) }
func datalessFlag() -> UInt32 { UInt32(bitPattern: SF_DATALESS) }
