import SwiftUI

// MARK: - Colors
private let snapYellow = Color(red: 1.0, green: 0.988, blue: 0.0)
private let snapBlue = Color(red: 0.06, green: 0.68, blue: 1.0)
private let subGray = Color(red: 0.55, green: 0.55, blue: 0.57)
private let adPurple = Color(red: 0.60, green: 0.16, blue: 0.85)
private let adPink = Color(red: 0.93, green: 0.05, blue: 0.60)
private let avatarGray = Color(red: 0.93, green: 0.93, blue: 0.94)
private let meRed = Color(red: 0.92, green: 0.25, blue: 0.25)

@main
struct SnapChatMockApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

// MARK: - Root
struct RootView: View {
    @State private var activeChat: String?

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            listPage
                .opacity(activeChat == nil ? 1 : 0)
                .allowsHitTesting(activeChat == nil)
            if let chat = activeChat {
                ChatDetail(name: chat, onBack: {
                    activeChat = nil
                })
            }
        }
    }

    var listPage: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                HeaderBar()
                ChipsRow()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        adRow
                        linkRow("Hao") {
                            ChatRow(emoji: "😎", bg: Color(red: 0.85, green: 0.90, blue: 0.98), name: "Hao 👻", star: false) {
                                friendSub("You are now friends 🎉")
                            } trailing: {
                                SnapPill()
                            }
                        }
                        linkRow("Vlad Gusakov") {
                            ChatRow(emoji: "👨🏻", bg: Color(red: 0.80, green: 0.88, blue: 0.99), name: "Vlad Gusakov", star: true) {
                                newChatSub("1w")
                            } trailing: { cameraIcon }
                        }
                        linkRow("Edward Palmer") {
                            ChatRow(emoji: "👨🏾", bg: Color(red: 0.85, green: 0.93, blue: 1.0), name: "Edward Palmer", star: false) {
                                tapToChat
                            } trailing: { cameraIcon }
                        }
                        linkRow("Josh Kowarsky") {
                            ChatRow(emoji: "🧔", bg: Color(red: 0.78, green: 0.90, blue: 0.85), name: "Josh Kowarsky", star: true) {
                                receivedSub("2w")
                            } trailing: { cameraIcon }
                        }
                        linkRow("Team Snapchat") {
                            ChatRow(emoji: "👻", bg: snapYellow, name: "Team Snapchat", star: false) {
                                receivedSub("3w")
                            } trailing: { cameraIcon }
                        }
                        linkRow("Mack Hartley") {
                            ChatRow(emoji: "👨🏽", bg: Color(red: 0.94, green: 0.86, blue: 0.80), name: "Mack Hartley", star: true) {
                                tapToChat
                            } trailing: { cameraIcon }
                        }
                        linkRow("Vardges Avetisyan") {
                            ChatRow(emoji: "👨🏼", bg: Color(red: 0.87, green: 0.90, blue: 0.98), name: "Vardges Avetisyan", star: true) {
                                openedSub("3w")
                            } trailing: { cameraIcon }
                        }
                        linkRow("Peter B") {
                            ChatRow(emoji: "🧔🏻", bg: Color(red: 0.88, green: 0.84, blue: 0.78), name: "Peter B", star: true) {
                                receivedSub("9w")
                            } trailing: { cameraIcon }
                        }
                        linkRow("Sihao Lu") {
                            ChatRow(emoji: "🤓", bg: Color(red: 0.84, green: 0.88, blue: 0.96), name: "Sihao Lu", star: false) {
                                tapToChat
                            } trailing: { cameraIcon }
                        }
                        linkRow("Sofia Almeida") {
                            ChatRow(emoji: "👩🏻", bg: avatarGray, name: "Sofia Almeida", star: false) {
                                tapToChat
                            } trailing: { cameraIcon }
                        }
                    }
                    .padding(.bottom, 4)
                }
                BottomBar()
            }
            ComposeButton()
                .padding(.trailing, 14)
                .padding(.bottom, 78)
        }
    }

    func linkRow<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        Button {
            activeChat = name
        } label: {
            content().frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    var cameraIcon: some View {
        Image(systemName: "camera")
            .font(.system(size: 26, weight: .light))
            .foregroundColor(Color.black.opacity(0.8))
    }

    var tapToChat: some View {
        HStack(spacing: 6) {
            Image(systemName: "square").font(.system(size: 14)).foregroundColor(subGray)
            Text("Tap to chat").font(.system(size: 15)).foregroundColor(subGray)
        }
    }

    func friendSub(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "square").font(.system(size: 14)).foregroundColor(subGray)
            Text(text).font(.system(size: 15)).foregroundColor(subGray)
        }
    }

    func receivedSub(_ when: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left").font(.system(size: 14)).foregroundColor(snapBlue)
            Text("Received").font(.system(size: 15)).foregroundColor(subGray)
            Text("· \(when)").font(.system(size: 15)).foregroundColor(subGray)
        }
    }

    func newChatSub(_ when: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.fill").font(.system(size: 14)).foregroundColor(snapBlue)
            Text("New Chat").font(.system(size: 15, weight: .semibold)).foregroundColor(snapBlue)
            Text("· \(when)").font(.system(size: 15)).foregroundColor(subGray)
        }
    }

    func openedSub(_ when: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrowtriangle.right.fill").font(.system(size: 13)).foregroundColor(snapBlue)
            Text("Opened").font(.system(size: 15)).foregroundColor(subGray)
            Text("· \(when)").font(.system(size: 15)).foregroundColor(subGray)
        }
    }

    var adRow: some View {
        HStack(spacing: 14) {
            Avatar(emoji: "🍕", bg: Color(red: 1.0, green: 0.85, blue: 0.88))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text("Adrian QA123").font(.system(size: 17, weight: .semibold)).foregroundColor(.black)
                    StarBadge()
                    Text("· Ad").font(.system(size: 15)).foregroundColor(subGray)
                }
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4).fill(adPurple).frame(width: 15, height: 15)
                    Text("Website Headline").font(.system(size: 15, weight: .semibold)).foregroundColor(adPurple)
                    Text("EMPLOYEE TARGETING").font(.system(size: 12, weight: .semibold)).foregroundColor(adPink)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 22, weight: .light))
                .foregroundColor(.black)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - Header
struct HeaderBar: View {
    var body: some View {
        HStack(spacing: 14) {
            Avatar(emoji: "👨‍🦰", bg: Color(red: 0.98, green: 0.87, blue: 0.82), size: 44)
            Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .medium)).foregroundColor(.black)
            Spacer()
            Text("Snapchat").font(.system(size: 22, weight: .bold)).foregroundColor(.black)
            Spacer()
            Image(systemName: "bell").font(.system(size: 22)).foregroundColor(.black)
            addButton
            Image(systemName: "ellipsis").font(.system(size: 20, weight: .bold)).foregroundColor(.black)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    var addButton: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Circle().fill(snapYellow).frame(width: 44, height: 44)
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 22))
                    .foregroundColor(.black)
            }
            ZStack {
                Circle().fill(Color(red: 1.0, green: 0.23, blue: 0.19)).frame(width: 19, height: 19)
                Text("5").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
            }
            .offset(x: 5, y: -4)
        }
    }
}

// MARK: - Chips
struct ChipsRow: View {
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                HStack(spacing: 5) {
                    Text("Unread").fixedSize()
                    ZStack {
                        Circle().fill(Color.black).frame(width: 19, height: 19)
                        Text("1").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                    }
                }
                HStack(spacing: 5) {
                    ZStack {
                        Circle().fill(LinearGradient(colors: [Color(red: 0.45, green: 0.35, blue: 0.95), Color(red: 0.30, green: 0.75, blue: 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 21, height: 21)
                        Text("✦").font(.system(size: 10)).foregroundColor(.white)
                    }
                    Text("My AI").fixedSize()
                }
                Text("Topics").fixedSize()
                Text("Near Me").fixedSize()
                HStack(spacing: 5) {
                    Text("Stories").fixedSize()
                    ZStack {
                        Circle().fill(subGray).frame(width: 19, height: 19)
                        Text("3").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                    }
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.black)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Row building blocks
struct Avatar: View {
    var emoji: String
    var bg: Color
    var size: CGFloat = 56
    var body: some View {
        ZStack {
            Circle().fill(bg).frame(width: size, height: size)
            Text(emoji).font(.system(size: size * 0.55))
        }
    }
}

struct StarBadge: View {
    var body: some View {
        ZStack {
            Circle().fill(snapYellow).frame(width: 19, height: 19)
            Circle().stroke(Color.black, lineWidth: 0.8).frame(width: 19, height: 19)
            Image(systemName: "star.fill").font(.system(size: 10)).foregroundColor(.black)
        }
    }
}

struct ChatRow<Sub: View, Trail: View>: View {
    var emoji: String
    var bg: Color
    var name: String
    var star: Bool = false
    @ViewBuilder var subtitle: Sub
    @ViewBuilder var trailing: Trail

    var body: some View {
        HStack(spacing: 14) {
            Avatar(emoji: emoji, bg: bg)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(name).font(.system(size: 17, weight: .semibold)).foregroundColor(.black)
                    if star { StarBadge() }
                }
                HStack(spacing: 6) { subtitle }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct SnapPill: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "camera").font(.system(size: 17, weight: .semibold))
            Text("Snap").font(.system(size: 17, weight: .bold))
        }
        .foregroundColor(.black)
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(Capsule().fill(snapYellow))
    }
}

// MARK: - Compose + bottom bar
struct ComposeButton: View {
    var body: some View {
        ZStack {
            Circle().fill(snapYellow).frame(width: 62, height: 62)
                .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
            ZStack {
                Image(systemName: "bubble.left").font(.system(size: 26, weight: .semibold))
                Image(systemName: "pencil").font(.system(size: 13, weight: .bold)).offset(x: 9, y: -8)
            }
            .foregroundColor(.black)
        }
    }
}

struct BottomBar: View {
    var body: some View {
        HStack {
            Image(systemName: "location").font(.system(size: 26)).foregroundColor(.black)
            Spacer()
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bubble.left.fill").font(.system(size: 26)).foregroundColor(.black)
                ZStack {
                    Circle().fill(Color(red: 1.0, green: 0.23, blue: 0.19)).frame(width: 17, height: 17)
                    Text("1").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                }
                .offset(x: 7, y: -6)
            }
            Spacer()
            Image(systemName: "camera").font(.system(size: 26)).foregroundColor(.black)
            Spacer()
            Image(systemName: "person.2").font(.system(size: 26)).foregroundColor(.black)
            Spacer()
            Image(systemName: "play").font(.system(size: 26)).foregroundColor(.black)
        }
        .padding(.horizontal, 36)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}

// MARK: - Chat detail page
struct ChatDetail: View {
    var name: String
    var onBack: () -> Void
    @State private var draft = ""
    @State private var messages = ["hi"]

    var body: some View {
        VStack(spacing: 0) {
            header
            banner
            messageArea
            inputBar
        }
    }

    var messageArea: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text("T O D A Y")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(subGray)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                ForEach(messages, id: \.self) { message in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Me").font(.system(size: 13, weight: .semibold)).foregroundColor(meRed)
                        HStack(alignment: .top, spacing: 8) {
                            Capsule().fill(meRed).frame(width: 3, height: 16).padding(.top, 1)
                            Text(message).font(.system(size: 16)).foregroundColor(.black)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    var header: some View {
        HStack(spacing: 12) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            ZStack {
                Circle().fill(Color(red: 0.93, green: 0.86, blue: 0.90)).frame(width: 36, height: 36)
                Image(systemName: "person.fill").font(.system(size: 17)).foregroundColor(Color(red: 0.55, green: 0.10, blue: 0.35))
            }
            Text(name).font(.system(size: 20, weight: .bold)).foregroundColor(.black)
            Spacer()
            Image(systemName: "play").font(.system(size: 22)).foregroundColor(.black)
            Image(systemName: "phone.fill").font(.system(size: 21)).foregroundColor(.black)
            Image(systemName: "video.fill").font(.system(size: 22)).foregroundColor(.black)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    var banner: some View {
        HStack(spacing: 6) {
            Image(systemName: "bell.slash").font(.system(size: 13)).foregroundColor(subGray)
            Text("Don't miss Chats from \(name)!")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.black)
            Text("Enable notifications")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(snapBlue)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(red: 0.93, green: 0.93, blue: 0.94))
    }

    var inputBar: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.black).frame(width: 44, height: 44)
                Image(systemName: "camera").font(.system(size: 19)).foregroundColor(.white)
            }
            HStack(spacing: 8) {
                Capsule().fill(meRed).frame(width: 2, height: 20)
                TextField("Send a chat", text: $draft)
                    .font(.system(size: 17))
                    .onSubmit {
                        if !draft.isEmpty {
                            messages.append(draft)
                            draft = ""
                        }
                    }
                Image(systemName: "waveform").font(.system(size: 17)).foregroundColor(.black)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 21).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 21).stroke(Color(red: 0.82, green: 0.82, blue: 0.84), lineWidth: 1))
            Text("🙋").font(.system(size: 24))
            Image(systemName: "rectangle.on.rectangle").font(.system(size: 21)).foregroundColor(.black)
            Image(systemName: "gamecontroller").font(.system(size: 21)).foregroundColor(.black)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}
