// A P2PRC-shaped two-column split view for verifying the web renderer's
// COMPACT presentation (a phone-width browser): a List(selection:) sidebar
// with .navigation / .primaryAction bar items, a detail NavigationStack
// whose screen sets a title, a subtitle, a .principal pill and a trailing
// item, and a sheet over the split. Drive it headlessly at 390px (see
// docs/web_headless_verification.md): list → row → detail with Back +
// bar → Back → list; "+" selects programmatically; gear → sheet → Done.

import SwiftUI

@main
struct SplitProbeApp: App {
    var body: some Scene {
        WindowGroup { SplitProbeRoot() }
    }
}

struct Peer: Identifiable, Hashable {
    let id: Int
    let name: String
}

let peers = [Peer(id: 1, name: "Ada"), Peer(id: 2, name: "Grace"), Peer(id: 3, name: "Linus")]

struct SplitProbeRoot: View {
    @State private var selection: Int? = nil
    @State private var showSettings = false
    @State private var showInfo = false

    var body: some View {
        NavigationSplitView {
            List(peers, selection: $selection) { peer in
                // A chat app's inbox cell: avatar, name with the time opposite, a two-line preview.
                HStack(alignment: .top, spacing: 12) {
                    ZStack(alignment: .bottomTrailing) {
                        Circle().fill(Color.blue.opacity(0.4)).frame(width: 44, height: 44)
                            .overlay(Text(String(peer.name.prefix(1))).font(.headline))
                        Circle().fill(Color.green).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(peer.name + " Lovelace-Hopper-Torvalds").font(.headline).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("Yesterday").font(.subheadline).foregroundColor(.secondary)
                        }
                        Text("A rather long preview of the last message that certainly wraps onto a second line and then some more words beyond that")
                            .font(.subheadline).foregroundColor(.secondary).lineLimit(2)
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .listStyle(.plain)
            .navigationTitle("Peers \(selection.map(String.init) ?? "-")")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .primaryAction) {
                    // Programmatic selection (the way pairing completes).
                    Button { selection = 2 } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Pair")
                }
                ToolbarItem(placement: .primaryAction) {
                    // A Label in a toolbar shows its glyph, named by its title.
                    Button { showInfo = true } label: { Label("Info", systemImage: "info.circle") }
                }
            }
        } detail: {
            NavigationStack {
                if let selection, let peer = peers.first(where: { $0.id == selection }) {
                    ChatScreen(peer: peer)
                } else {
                    PairingScreen()
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            // A settings form (a chat app's shape): sections, a long single-line
            // value, a last row that must clear the bottom edge.
            NavigationStack {
                Form {
                    Section("Account") {
                        ForEach(0..<16, id: \.self) { index in Text("Row \(index)") }
                    }
                    Section {
                        Text("0x8f3a1c9e7b2d4f6a8c0e1b3d5f7a9c2e4b6d8f0a1c3e5b7d9f2a4c6e8b0d3f5a")
                            .lineLimit(1)
                    } header: { Text("Wallet") } footer: { Text("Your address on this device.") }
                    Section("Nodes") {
                        // A chat app's server rows: a wrapping address with a trailing tag.
                        ForEach(["https://relay-node-1-000000000000.us-central1.example.com", "https://relay-node-2-000000000000.us-central1.example.com"], id: \.self) { node in
                            HStack {
                                Text(node)
                                Spacer()
                                Text("relay").foregroundColor(.secondary)
                            }
                        }
                    }
                    Section {
                        Button("Log out", role: .destructive) {}
                    } footer: {
                        // The last footer: five lines that must stay inside the scroll.
                        Text("Nodes hold your messages for offline contacts, host the handshake when you pair, and offer STUN/TURN; \"relay\" means one offers TURN for networks that block direct connections. To run one, see the protocol's README for the container image and the two ports it needs.")
                    }
                }
                .navigationTitle("Settings")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showSettings = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showInfo) {
            // Another app's shape: a leading-aligned stack, no navigation bar.
            VStack(alignment: .leading, spacing: 12) {
                Text("Library").font(.title2).bold()
                Text("Signed in as ada@example.com").foregroundColor(.secondary)
                Button("Refresh now") {}
                Button("Log out", role: .destructive) {}
                Button("Close") { showInfo = false }
            }
            .padding()
        }
    }
}

/// A pairing screen: centered copy above a full-width prominent button.
struct PairingScreen: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "person.2.wave.2").font(.largeTitle)
            Text("Pair with a friend")
                .font(.title2).bold()
            Text("Scan their code or share yours. Messages travel peer to peer over the network you are both on, nothing passes through a server.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
            Button {} label: { Text("Share my code").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        // A chain: a 320pt-capped box centred in an infinite-width frame.
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }
}

struct ChatScreen: View {
    let peer: Peer
    @State private var draft = ""
    @State private var sent = 0
    // Foundation's URL from the model, straight into AsyncImage(url:).
    private let attachment = Attachment(urlString: "https://picsum.photos/id/237/200/200")

    var body: some View {
        VStack(spacing: 12) {
            Text("Chat with \(peer.name)")
            Text("sent \(sent)")
            AsyncImage(url: attachment.url) { image in image.resizable().scaledToFit() } placeholder: { Color.gray }
                .frame(width: 60, height: 60)
                .accessibilityLabel("attachment \(attachment.url.lastPathComponent) \(attachment.id.uuidString.count) \(attachment.timeLabel)")
            // P2PRC's phone composer: a plain growing field inside a pill,
            // with the send button overlaid at the field's bottom-right.
            ZStack(alignment: .bottomTrailing) {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .topLeading)
                    .padding(.leading, 14).padding(.trailing, 53).padding(.vertical, 10)
                    .onSubmit {
                        sent += 1
                        draft = ""
                    }
                    .submitLabel(.send)
                Button(action: { sent += 1 }) {
                    Image(systemName: "arrow.up")
                        .frame(width: 40, height: 30)
                        .background(Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 15))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 5).padding(.bottom, 5)
            }
            .background(RoundedRectangle(cornerRadius: 20).fill(Color.gray.opacity(0.15)))
            .background(RoundedRectangle(cornerRadius: 20).stroke(Color.gray.opacity(0.4), lineWidth: 1))
            .padding(.horizontal)
            Rectangle().fill(Color.gray.opacity(0.2)).frame(height: 60)
                .overlay(alignment: .bottomTrailing) { Text("corner").padding(6) }
            // An album: two flexible columns, square cells.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)], spacing: 3) {
                ForEach(0..<5, id: \.self) { index in
                    Rectangle().fill([Color.red, .orange, .yellow, .green, .blue][index].opacity(0.6))
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(peer.name)
        .navigationSubtitle("online")
        .toolbar {
            ToolbarItem(placement: .principal) {
                // A conversation's title: a 60pt avatar in the bar with the
                // name pill tucked 5pt behind its bottom, hanging below the bar.
                Button {} label: {
                    ZStack(alignment: .top) {
                        HStack(spacing: 4) {
                            Text(peer.name).font(.headline)
                            Image(systemName: "chevron.compact.forward").font(.caption)
                        }
                        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 5)
                        .background(Capsule().fill(Color.gray.opacity(0.18)))
                        .padding(.top, 60 - 5)
                        Circle().fill(Color.blue).frame(width: 60, height: 60)
                    }
                    .offset(y: (60 - 5 + 27 - 44) / 2)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {} label: { Label("Call", systemImage: "phone") }
            }
        }
    }
}
