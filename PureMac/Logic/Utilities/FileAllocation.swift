import Darwin
import Foundation

/// File identity and allocated bytes for tree-size scans.
///
/// APFS reports a full clone as a separate inode with its own allocated-block
/// count. On systems/filesystems that expose clone mapping, use the clone ID
/// as the identity so a scan of a tree counts a group of full clones once.
/// Partial clones cannot be apportioned precisely by the filesystem API.
enum FileAllocation {
    enum Identity: Hashable {
        case inode(device: UInt64, inode: UInt64)
        case apfsClone(device: UInt64, cloneID: UInt64)
    }

    struct Metadata {
        let identity: Identity
        let allocatedBytes: Int64
        let isDataless: Bool
        let isFullClone: Bool
    }

    static func metadata(at url: URL) -> Metadata? {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            return metadata(atPath: path)
        }
    }

    static func metadata(atPath path: UnsafePointer<CChar>) -> Metadata? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }

        let device = UInt64(info.st_dev)
        let inode = UInt64(info.st_ino)
        let cloneID = info.st_mode & S_IFMT == S_IFREG ? fullCloneID(atPath: path) : nil
        let identity: Identity
        if let cloneID {
            identity = .apfsClone(device: device, cloneID: cloneID)
        } else {
            identity = .inode(device: device, inode: inode)
        }

        return Metadata(
            identity: identity,
            allocatedBytes: max(0, Int64(info.st_blocks)) * 512,
            isDataless: info.st_flags & UInt32(SF_DATALESS) != 0,
            isFullClone: cloneID != nil
        )
    }

    private static func fullCloneID(atPath path: UnsafePointer<CChar>) -> UInt64? {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS)

        // The attribute list is packed after its four-byte length field.
        // Requesting clone ID then extended flags yields 4 + 8 + 8 bytes.
        var buffer = [UInt8](repeating: 0, count: 20)
        let result = buffer.withUnsafeMutableBytes { bytes in
            getattrlist(
                path,
                &attributes,
                bytes.baseAddress,
                bytes.count,
                UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)
            )
        }
        guard result == 0 else { return nil }
        let returnedLength = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        guard returnedLength >= UInt32(buffer.count) else { return nil }
        let cloneID = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
        let flags = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt64.self) }
        guard cloneID != 0,
              flags & UInt64(EF_SHARES_ALL_BLOCKS) != 0 else {
            return nil
        }
        return cloneID
    }
}
