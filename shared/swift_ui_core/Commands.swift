// `Commands`: a menu bar's commands (`CommandMenu`, `CommandGroup`), which
// a scene takes with `.commands { }`, as Apple's. Isomer's hosts draw no
// menu bar of the app's (a Mac app built against Apple's SwiftUI has the
// system's): a scene's commands are taken and kept nowhere, so one source
// declares them for the Mac and builds everywhere. A Button's
// `.keyboardShortcut` inside one is taken as a view's anywhere else.

/// A menu bar's commands: Apple's protocol, made of commands (`body`) down
/// to `CommandMenu`, `CommandGroup` and `EmptyCommands`.
@MainActor @preconcurrency
public protocol Commands {
    associatedtype Body: Commands
    @CommandsBuilder var body: Body { get }
}

extension Never: Commands {}

extension Commands where Body == Never {
    /// Commands made of no other commands. (Apple's keep theirs out of
    /// their interface; this one declaration stands for all of Isomer's.)
    public var body: Never { fatalError("primitive commands") }
}

/// No commands (an empty `.commands { }`).
public struct EmptyCommands: Commands {
    public init() {}
    public typealias Body = Never
}

/// Several commands as one (a `CommandsBuilder` block's).
struct TupleCommands: Commands {
    typealias Body = Never
}

extension _ConditionalContent: Commands where TrueContent: Commands, FalseContent: Commands {}

extension Optional: Commands where Wrapped: Commands {}

/// Builds a scene's commands from the statements of a closure.
@resultBuilder
public struct CommandsBuilder {
    public static func buildExpression<Content>(_ content: Content) -> Content where Content: Commands {
        content
    }

    public static func buildBlock() -> EmptyCommands {
        EmptyCommands()
    }

    public static func buildBlock<C>(_ content: C) -> C where C: Commands {
        content
    }

    @_disfavoredOverload
    public static func buildBlock<each Content: Commands>(_ content: repeat each Content) -> some Commands {
        TupleCommands()
    }

    public static func buildIf<C>(_ content: C?) -> C? where C: Commands {
        content
    }

    public static func buildEither<T, F>(first: T) -> _ConditionalContent<T, F> where T: Commands, F: Commands {
        _ConditionalContent(storage: .trueContent(first))
    }

    public static func buildEither<T, F>(second: F) -> _ConditionalContent<T, F> where T: Commands, F: Commands {
        _ConditionalContent(storage: .falseContent(second))
    }
}

/// A menu of the app's own in the menu bar, its items the views given.
public struct CommandMenu<Content>: Commands where Content: View {
    let name: String
    let content: Content

    public typealias Body = Never

    public init(_ nameKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.name = Text(nameKey).content
        self.content = content()
    }

    public init(_ name: Text, @ViewBuilder content: () -> Content) {
        self.name = name.content
        self.content = content()
    }

    @_disfavoredOverload
    public init<S>(_ name: S, @ViewBuilder content: () -> Content) where S: StringProtocol {
        self.name = String(name)
        self.content = content()
    }
}

/// Where in the menu bar's standard menus a `CommandGroup` goes.
public struct CommandGroupPlacement: Sendable {
    let name: String

    public static let appInfo = CommandGroupPlacement(name: "appInfo")
    public static let appSettings = CommandGroupPlacement(name: "appSettings")
    public static let systemServices = CommandGroupPlacement(name: "systemServices")
    public static let appVisibility = CommandGroupPlacement(name: "appVisibility")
    public static let appTermination = CommandGroupPlacement(name: "appTermination")
    public static let newItem = CommandGroupPlacement(name: "newItem")
    public static let saveItem = CommandGroupPlacement(name: "saveItem")
    public static let importExport = CommandGroupPlacement(name: "importExport")
    public static let printItem = CommandGroupPlacement(name: "printItem")
    public static let undoRedo = CommandGroupPlacement(name: "undoRedo")
    public static let pasteboard = CommandGroupPlacement(name: "pasteboard")
    public static let textEditing = CommandGroupPlacement(name: "textEditing")
    public static let textFormatting = CommandGroupPlacement(name: "textFormatting")
    public static let toolbar = CommandGroupPlacement(name: "toolbar")
    public static let sidebar = CommandGroupPlacement(name: "sidebar")
    public static let windowSize = CommandGroupPlacement(name: "windowSize")
    public static let windowArrangement = CommandGroupPlacement(name: "windowArrangement")
    public static let help = CommandGroupPlacement(name: "help")
}

/// Items added to one of the standard menus, before, after or in place of
/// one of its groups.
public struct CommandGroup<Content>: Commands where Content: View {
    let placement: CommandGroupPlacement
    let content: Content

    public typealias Body = Never

    public init(before group: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {
        placement = group
        content = addition()
    }

    public init(after group: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {
        placement = group
        content = addition()
    }

    public init(replacing group: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {
        placement = group
        content = addition()
    }
}

extension Scene {
    /// The scene's menu bar commands: taken, and drawn nowhere on Isomer's
    /// hosts (see above).
    public nonisolated func commands<Content>(@CommandsBuilder content: () -> Content) -> some Scene where Content: Commands {
        self
    }

    /// The standard menus' commands removed: Isomer's hosts draw none.
    public nonisolated func commandsRemoved() -> some Scene { self }

    /// The standard menus' commands replaced by these: taken, and drawn
    /// nowhere on Isomer's hosts.
    public nonisolated func commandsReplaced<Content>(@CommandsBuilder content: () -> Content) -> some Scene where Content: Commands {
        self
    }

    /// How the scene's windows may be resized. The desktop hosts' windows
    /// keep a size the app's content allows (a `.frame(minWidth:…)` holds
    /// the window there); the phones' and the web's take the screen's.
    public nonisolated func windowResizability(_ resizability: WindowResizability) -> some Scene { self }
}

/// How a scene's windows may be resized (`windowResizability(_:)`).
public struct WindowResizability: Sendable {
    let name: String

    /// The platform's choice for the scene.
    public static var automatic: WindowResizability { WindowResizability(name: "automatic") }
    /// Between the content's minimum and maximum sizes.
    public static var contentSize: WindowResizability { WindowResizability(name: "contentSize") }
    /// No smaller than the content's minimum size.
    public static var contentMinSize: WindowResizability { WindowResizability(name: "contentMinSize") }
}
