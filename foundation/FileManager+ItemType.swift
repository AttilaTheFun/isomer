// What is at a path, for Isomer's own code: Apple's way to ask is
// fileExists(atPath:isDirectory:) with an Objective-C ObjCBool, which
// Isomer's Foundation leaves out.

import FoundationEssentials

extension FileManager {
    /// The type of the item at `path`, symbolic links followed (as
    /// fileExists(atPath:isDirectory:) follows them), or nil when there is
    /// none.
    func itemType(atPath path: String) -> FileAttributeType? {
        var current = path
        for _ in 0..<8 {
            guard let type = (try? attributesOfItem(atPath: current))?[.type] as? FileAttributeType else { return nil }
            guard type == .typeSymbolicLink, let target = try? destinationOfSymbolicLink(atPath: current) else { return type }
            current = target.hasPrefix("/") ? target
                : URL(fileURLWithPath: current).deletingLastPathComponent().appendingPathComponent(target).path
        }
        return nil
    }
}
