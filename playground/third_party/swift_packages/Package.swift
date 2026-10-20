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
        // AgentUI v0.31 (its tag's commit: SwiftPM takes no two-part tags).
        .package(
            url: "https://github.com/AttilaTheFun/agent_ui.git",
            revision: "7d6854f3b1320547e98e4e86f422448bd94ea30f"
        ),
        // OpenRouterKit (the OpenRouter client, agent loop and coding
        // tools), the library behind the openrouter CLI; shared with
        // Visor. The Playground's own OpenRouter loop is to move onto it.
        .package(
            url: "https://github.com/AttilaTheFun/open_router_cli.git",
            revision: "080cbe2746312ef9d2c3593e15105780877b399a"
        ),
    ]
)
