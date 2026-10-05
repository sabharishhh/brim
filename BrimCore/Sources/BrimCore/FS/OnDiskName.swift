import Darwin
import Foundation

/// The name a file has on disk, which on a case-insensitive volume need not
/// be the name it was asked for by.
///
/// Brim found ChatGPT's `Caches/Codex` by asking for `Caches/codex`, the
/// volume said yes, and the row and the plan carried a spelling that is not
/// on the disk. Two sources asking with different spellings is also how one
/// file turned into two rows.
public enum OnDiskName {
    /// The URL with its last component spelled as stored. Links are not
    /// followed, and anything that cannot be read comes back unchanged.
    public static func spelled(_ url: URL) -> URL {
        guard let stored = name(atPath: url.path), stored != url.lastPathComponent else { return url }
        return url.deletingLastPathComponent().appendingPathComponent(stored)
    }

    static func name(atPath path: String) -> String? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_NAME)
        var buffer = [UInt8](repeating: 0, count: 4 + MemoryLayout<attrreference_t>.size + Int(NAME_MAX) * 3 + 1)
        let status = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &request, raw.baseAddress, raw.count, UInt32(FSOPT_NOFOLLOW))
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> String? in
            let reference = raw.loadUnaligned(fromByteOffset: 4, as: attrreference_t.self)
            let start = 4 + Int(reference.attr_dataoffset)
            let length = Int(reference.attr_length)
            guard length > 1, start >= 4, start + length <= raw.count else { return nil }
            return String(decoding: raw[start ..< start + length - 1], as: UTF8.self)
        }
    }
}
