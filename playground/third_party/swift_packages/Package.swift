// swift-tools-version: 5.9
// The SwiftPM manifest rules_swift_package_manager consumes for the
// Playground: AgentUI provides the agent chat page (AgentView), the same
// SwiftUI source the iOS Playground builds against Apple's SwiftUI and the web
// and Android Playgrounds against Isomer's.
import PackageDescription

let package = Package(
    name: "isomer_playground_swift_packages",
    platforms: [.macOS("15.0")],
    dependencies: [
        // AgentUI 0.36.1 (SwiftTerm at its 1.99.0 release, so a package
        // pinned by version can depend on it).
        .package(
            url: "https://github.com/AttilaTheFun/agent_ui.git",
            exact: "0.36.1"
        ),
        // OpenRouterKit (the OpenRouter client, agent loop and coding
        // tools), the library behind the openrouter CLI; shared with
        // Visor. The Playground's own OpenRouter loop is to move onto it.
        .package(
            url: "https://github.com/AttilaTheFun/open_router_cli.git",
            exact: "0.4.0"
        ),
    ]
)
