import Foundation
import MachO

/// Reads the `LC_UUID` build identifiers of 64-bit Mach-O executables, thin or universal.
enum MachOImage {
    private static let thinMagic: UInt32 = 0xFEED_FACF
    private static let fatMagic: UInt32 = 0xCAFE_BABE
    private static let fatMagic64: UInt32 = 0xCAFE_BABF
    private static let uuidCommand: UInt32 = 0x1B
    private static let headerSize = 32
    private static let maximumCommandsSize = 16 << 20
    private static let maximumArchitectures = 32

    /// The build identifier of the running process's main executable.
    static func runningUUID() -> UUID? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        let raw = UnsafeRawPointer(header)
        guard raw.loadUnaligned(as: UInt32.self) == thinMagic else { return nil }
        let count = raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
        let size = raw.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
        guard Int(size) <= maximumCommandsSize else { return nil }
        return uuid(in: UnsafeRawBufferPointer(start: raw + headerSize, count: Int(size)), commands: count)
    }

    /// The build identifiers of every architecture in the executable open as `handle`.
    static func uuids(of handle: FileHandle) -> [UUID] {
        guard let head = read(handle, at: 0, count: 8), head.count == 8 else { return [] }
        let magic = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        if magic == thinMagic { return slice(handle, at: 0).map { [$0] } ?? [] }
        let bigMagic = UInt32(bigEndian: magic)
        guard bigMagic == fatMagic || bigMagic == fatMagic64 else { return [] }
        let count = Int(UInt32(bigEndian: head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }))
        guard count > 0, count <= maximumArchitectures else { return [] }
        let entrySize = bigMagic == fatMagic64 ? 32 : 20
        guard let table = read(handle, at: 8, count: count * entrySize), table.count == count * entrySize else { return [] }
        let offsets: [UInt64] = table.withUnsafeBytes { bytes in
            (0..<count).map { index in
                let base = index * entrySize + 8
                if bigMagic == fatMagic64 {
                    return UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: base, as: UInt64.self))
                }
                return UInt64(UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: base, as: UInt32.self)))
            }
        }
        return offsets.compactMap { slice(handle, at: $0) }
    }

    private static func slice(_ handle: FileHandle, at offset: UInt64) -> UUID? {
        guard let header = read(handle, at: offset, count: headerSize), header.count == headerSize else { return nil }
        let (magic, count, size) = header.withUnsafeBytes { bytes in
            (
                bytes.loadUnaligned(as: UInt32.self),
                bytes.loadUnaligned(fromByteOffset: 16, as: UInt32.self),
                bytes.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
            )
        }
        guard magic == thinMagic, Int(size) <= maximumCommandsSize,
            let commands = read(handle, at: offset + UInt64(headerSize), count: Int(size)), commands.count == Int(size)
        else { return nil }
        return commands.withUnsafeBytes { uuid(in: $0, commands: count) }
    }

    private static func uuid(in commands: UnsafeRawBufferPointer, commands count: UInt32) -> UUID? {
        var offset = 0
        for _ in 0..<count {
            guard offset + 8 <= commands.count else { return nil }
            let command = commands.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            let length = Int(commands.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
            guard length >= 8, offset + length <= commands.count else { return nil }
            if command == uuidCommand {
                guard length >= 24 else { return nil }
                let bytes = Array(commands[(offset + 8)..<(offset + 24)])
                return UUID(uuid: (
                    bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
            }
            offset += length
        }
        return nil
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) -> Data? {
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        return try? handle.read(upToCount: count)
    }
}
