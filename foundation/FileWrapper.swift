// FileWrapper (Apple's Foundation and corelibs have it; swift-foundation
// does not): a file, a directory of them, or a symbolic link, held in
// memory, read from and written to the file system. What SwiftUI's
// FileDocument hands over. A Swift class, as Isomer's other Foundation
// classes are (Apple's is an NSObject).

import FoundationEssentials

open class FileWrapper: @unchecked Sendable {
    public struct ReadingOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static var immediate: ReadingOptions { ReadingOptions(rawValue: 1 << 0) }
        public static var withoutMapping: ReadingOptions { ReadingOptions(rawValue: 1 << 1) }
    }

    public struct WritingOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static var atomic: WritingOptions { WritingOptions(rawValue: 1 << 0) }
        public static var withNameUpdating: WritingOptions { WritingOptions(rawValue: 1 << 1) }
    }

    private enum Kind {
        case file(Data)
        case directory([String: FileWrapper])
        case link(URL)
    }

    private var kind: Kind
    open var preferredFilename: String?
    open var filename: String?
    open var fileAttributes: [String: Any] = [:]

    public init(regularFileWithContents contents: Data) {
        kind = .file(contents)
    }

    public init(directoryWithFileWrappers childrenByPreferredName: [String: FileWrapper]) {
        for (name, child) in childrenByPreferredName where child.preferredFilename == nil { child.preferredFilename = name }
        kind = .directory(childrenByPreferredName)
    }

    public init(symbolicLinkWithDestinationURL url: URL) {
        kind = .link(url)
    }

    /// What is at `url` now: a file's contents, or a directory's files read
    /// the same way, all at once.
    public init(url: URL, options: ReadingOptions = []) throws {
        let manager = FileManager.default
        let path = url.path
        guard let type = manager.itemType(atPath: path) else { throw CocoaError(.fileReadNoSuchFile) }
        if let destination = try? manager.destinationOfSymbolicLink(atPath: path) {
            kind = .link(URL(fileURLWithPath: destination))
        } else if type == .typeDirectory {
            var children: [String: FileWrapper] = [:]
            for name in try manager.contentsOfDirectory(atPath: path) {
                children[name] = try FileWrapper(url: url.appendingPathComponent(name), options: options)
            }
            kind = .directory(children)
        } else {
            kind = .file(try Data(contentsOf: url))
        }
        filename = url.lastPathComponent
        preferredFilename = url.lastPathComponent
    }

    open var isRegularFile: Bool { if case .file = kind { true } else { false } }
    open var isDirectory: Bool { if case .directory = kind { true } else { false } }
    open var isSymbolicLink: Bool { if case .link = kind { true } else { false } }

    open var regularFileContents: Data? { if case .file(let data) = kind { data } else { nil } }
    open var fileWrappers: [String: FileWrapper]? { if case .directory(let children) = kind { children } else { nil } }
    open var symbolicLinkDestinationURL: URL? { if case .link(let url) = kind { url } else { nil } }

    /// Adds a child to a directory, under its preferred name (made unique
    /// with a number if taken): the name it is under.
    @discardableResult
    open func addFileWrapper(_ child: FileWrapper) -> String {
        guard case .directory(var children) = kind else { return "" }
        let wanted = child.preferredFilename ?? "Untitled"
        var name = wanted
        var number = 2
        while children[name] != nil {
            name = "\(number) " + wanted
            number += 1
        }
        children[name] = child
        kind = .directory(children)
        return name
    }

    @discardableResult
    open func addRegularFile(withContents data: Data, preferredFilename fileName: String) -> String {
        let child = FileWrapper(regularFileWithContents: data)
        child.preferredFilename = fileName
        return addFileWrapper(child)
    }

    open func removeFileWrapper(_ child: FileWrapper) {
        guard case .directory(var children) = kind, let key = keyForChildFileWrapper(child) else { return }
        children[key] = nil
        kind = .directory(children)
    }

    open func keyForChildFileWrapper(_ child: FileWrapper) -> String? {
        fileWrappers?.first { $0.value === child }?.key
    }

    /// Writes it at `url`: a file's contents, a directory and its files, or
    /// a link.
    open func write(to url: URL, options: WritingOptions = [], originalContentsURL: URL?) throws {
        let manager = FileManager.default
        switch kind {
        case .file(let data):
            #if os(WASI)
            // WASI has no temporary files to write atomically through.
            try data.write(to: url)
            #else
            try data.write(to: url, options: options.contains(.atomic) ? .atomic : [])
            #endif
        case .directory(let children):
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            for (name, child) in children {
                try child.write(to: url.appendingPathComponent(name), options: options, originalContentsURL: nil)
            }
        case .link(let destination):
            try manager.createSymbolicLink(atPath: url.path, withDestinationPath: destination.path)
        }
        if options.contains(.withNameUpdating) { filename = url.lastPathComponent }
    }
}
