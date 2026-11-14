// An app whose SwiftUI runs elsewhere, drawn here by the tree renderer
// (docs/modes.md: a remote or web-view app's head on the iPhone and the Mac).
//
//   IsomerRemoteView(url: "ws://192.168.1.20:8090")
//
// The app runs built headless and serving itself (ISO_DRIVE_LISTEN), or in
// a page; this view sends it the size, scale, appearance and scene phase, and
// what the person does.

import IsomerTree
import SwiftUI

public struct IsomerRemoteView: View {
    @State private var session: IsomerRemoteSession
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    public init(url: String, token: String? = nil, environment: [String: String] = [:]) {
        _session = State(initialValue: IsomerRemoteSession(url: url, token: token, environment: environment))
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let tree = session.tree {
                    IsomerTreeView(root: tree) { id, value in
                        session.send(id: id, value: value)
                    }
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(session.status).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                session.onOpenURL = { url in openURL(url) }
                session.start(width: geometry.size.width, height: geometry.size.height,
                              displayScale: displayScale, dark: colorScheme == .dark)
            }
            .onChange(of: geometry.size) { _, size in
                session.resize(width: size.width, height: size.height)
            }
        }
        .preferredColorScheme(session.appDark.map { $0 ? .dark : .light })
        .onChange(of: colorScheme) { _, scheme in session.setDark(scheme == .dark) }
        .onChange(of: scenePhase) { _, phase in
            session.setScenePhase(active: phase == .active, background: phase == .background)
        }
        .onOpenURL { url in session.open(url) }
        .onDisappear { session.close() }
    }
}
