// A small Hacker News client: a feed of the top stories, a detail page with the
// story's comments, and a tap-through to read the linked article in an in-app
// WebView. Uses the public Firebase HN API. Compiles unchanged on every platform.

import SwiftUI
import Isomer
import Observation

private let hnBase = "https://hacker-news.firebaseio.com/v0"
private let hnTopURL = "\(hnBase)/topstories.json"
private func hnItemURL(_ id: Int) -> String { "\(hnBase)/item/\(id).json" }

// MARK: - Models

struct HNStory: Identifiable, Hashable {
    let id: Int
    let title: String
    let by: String
    let score: Int
    let url: String?
    let commentCount: Int
    let kids: [Int]

    /// The article's domain, e.g. "github.com" — shown next to the title.
    var host: String? {
        guard let url else { return nil }
        // "https://www.github.com/x" -> ["https:", "www.github.com", "x"].
        let parts = url.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        var domain = String(parts[1])
        if domain.hasPrefix("www.") { domain = String(domain.dropFirst(4)) }
        return domain.isEmpty ? nil : domain
    }

    static func parse(_ text: String?) -> HNStory? {
        guard let text, let j = parseJSON(text),
              let id = j["id"].int, let title = j["title"].string else { return nil }
        return HNStory(
            id: id, title: title,
            by: j["by"].string ?? "",
            score: j["score"].int ?? 0,
            url: j["url"].string,
            commentCount: j["descendants"].int ?? 0,
            kids: j["kids"].array?.compactMap { $0.int } ?? [])
    }
}

@Observable final class HNFeedModel {
    private(set) var stories: [HNStory] = []
    private(set) var loading = false
    private var requested = false

    func loadIfNeeded() {
        guard !requested else { return }
        requested = true
        loading = true
        Networking.fetch(hnTopURL) { [weak self] text in
            guard let self else { return }
            guard let text, let ids = parseJSON(text)?.array?.prefix(30).compactMap({ $0.int }) else {
                self.loading = false
                return
            }
            self.fetchStories(Array(ids))
        }
    }

    private func fetchStories(_ ids: [Int]) {
        // Fetch each story; collect by position so the feed stays in rank order
        // as the (serialized) completions arrive.
        var byIndex: [Int: HNStory] = [:]
        var remaining = ids.count
        for (index, id) in ids.enumerated() {
            Networking.fetch(hnItemURL(id)) { [weak self] text in
                guard let self else { return }
                if let story = HNStory.parse(text) { byIndex[index] = story }
                remaining -= 1
                self.stories = (0 ..< ids.count).compactMap { byIndex[$0] }
                if remaining == 0 { self.loading = false }
            }
        }
    }
}

/// A comment node in the reply tree. A reference type so a node's `replies` can
/// be filled in as nested fetches complete and the whole tree re-publishes.
final class HNComment: Identifiable {
    let id: Int
    let by: String
    let text: String
    let kids: [Int]
    var replies: [HNComment] = []

    /// For `OutlineGroup(children:)`: nil when there are no loaded replies (a
    /// leaf, so no disclosure chevron is shown).
    var children: [HNComment]? { replies.isEmpty ? nil : replies }

    init(id: Int, by: String, text: String, kids: [Int]) {
        self.id = id
        self.by = by
        self.text = text
        self.kids = kids
    }

    static func parse(_ text: String?) -> HNComment? {
        guard let text, let j = parseJSON(text), let id = j["id"].int,
              let body = j["text"].string else { return nil }
        return HNComment(
            id: id, by: j["by"].string ?? "", text: htmlToPlainText(body),
            kids: j["kids"].array?.compactMap { $0.int } ?? [])
    }
}

@Observable final class HNCommentsModel {
    private(set) var comments: [HNComment] = []
    private(set) var loading = false
    private var loaded = false

    // Tree budget: how many replies to pull per comment, and how deep to recurse.
    private let topLimit = 12
    private let replyLimit = 4
    private let maxDepth = 2

    private var roots: [HNComment?] = []

    func load(kids: [Int]) {
        guard !loaded else { return }
        loaded = true
        let ids = Array(kids.prefix(topLimit))
        guard !ids.isEmpty else { return }
        loading = true
        roots = Array(repeating: nil, count: ids.count)
        var remaining = ids.count
        for (index, id) in ids.enumerated() {
            fetchComment(id, depth: 0) { [weak self] comment in
                guard let self else { return }
                self.roots[index] = comment
                remaining -= 1
                if remaining == 0 { self.loading = false }
                self.republish()
            }
        }
    }

    /// Re-derive the published tree from the ordered root slots (drops slots that
    /// failed to parse). Reassigning the array notifies observers.
    private func republish() {
        comments = roots.compactMap { $0 }
    }

    /// Fetch one comment and deliver it immediately (empty replies), then stream
    /// its bounded reply subtree in, re-publishing as nodes attach.
    private func fetchComment(_ id: Int, depth: Int, onReady: @escaping (HNComment?) -> Void) {
        Networking.fetch(hnItemURL(id)) { [weak self] text in
            guard let self else { return }
            guard let comment = HNComment.parse(text) else { onReady(nil); return }
            onReady(comment)
            let replyIDs = depth < self.maxDepth ? Array(comment.kids.prefix(self.replyLimit)) : []
            guard !replyIDs.isEmpty else { return }
            var slots: [HNComment?] = Array(repeating: nil, count: replyIDs.count)
            for (index, replyID) in replyIDs.enumerated() {
                self.fetchComment(replyID, depth: depth + 1) { reply in
                    slots[index] = reply
                    comment.replies = slots.compactMap { $0 }
                    self.republish()
                }
            }
        }
    }
}

// MARK: - Feed

struct HackerNewsScreen: View {
    @State private var model = HNFeedModel()

    var body: some View {
        content
            .navigationTitle("Hacker News")
            .onAppear { model.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if model.stories.isEmpty && model.loading {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading top stories…").font(.subheadline).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.top, 80)
        } else {
            List {
                ForEach(model.stories.indices, id: \.self) { index in
                    let story = model.stories[index]
                    NavigationLink {
                        HNStoryDetailView(story: story)
                    } label: {
                        HNStoryRow(rank: index + 1, story: story)
                    }
                }
            }
        }
    }
}

struct HNStoryRow: View {
    let rank: Int
    let story: HNStory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(rank)")
                .font(.headline).foregroundColor(.secondary)
                .frame(width: 26, alignment: .trailing)
            VStack(alignment: .leading, spacing: 5) {
                Text(story.title)
                    .font(.headline).foregroundColor(.primary).lineLimit(2)
                HStack(spacing: 12) {
                    if let host = story.host {
                        Text(host).font(.caption).foregroundColor(.accentColor).lineLimit(1)
                    }
                    Text("▲ \(story.score)").font(.caption).foregroundColor(.secondary)
                    Text("\(story.commentCount) comments").font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Detail (comments + read article)

struct HNStoryDetailView: View {
    let story: HNStory
    @State private var model = HNCommentsModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(story.title).font(.title2).bold().foregroundColor(.primary)
                HStack(spacing: 14) {
                    Text("▲ \(story.score)").font(.subheadline).foregroundColor(.secondary)
                    Text("by \(story.by)").font(.subheadline).foregroundColor(.secondary)
                }

                if let url = story.url {
                    NavigationLink {
                        HNWebScreen(url: url, title: story.host ?? "Article")
                    } label: {
                        Text("Read article ›")
                            .font(.headline).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color.accentColor).cornerRadius(10)
                    }
                }

                Text("\(story.commentCount) Comments").font(.headline).padding(.top, 4)

                if model.loading && model.comments.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading comments…").font(.subheadline).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                } else if model.comments.isEmpty {
                    Text("No comments yet.").font(.subheadline).foregroundColor(.secondary)
                } else {
                    // A reply tree: each comment with loaded replies is an
                    // expandable disclosure row, nesting deeper threads.
                    OutlineGroup(model.comments, id: \.id, children: \.children) { comment in
                        HNCommentView(comment: comment)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .navigationTitle("Story")
        .onAppear { model.load(kids: story.kids) }
    }
}

struct HNCommentView: View {
    let comment: HNComment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(comment.by).font(.caption).bold().foregroundColor(.accentColor)
            Text(comment.text).font(.subheadline).foregroundColor(.primary)
        }
        .padding(.vertical, 6)
    }
}

/// The linked article in an in-app web view.
struct HNWebScreen: View {
    let url: String
    let title: String

    var body: some View {
        WebView(url: URL(string: url))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
            .toolbar {
                Button {
                    Bridge.openURL(url)
                } label: {
                    Text("Open")
                }
            }
    }
}

// MARK: - Minimal HTML → plain text (HN comment bodies are HTML)

func htmlToPlainText(_ html: String) -> String {
    var out = ""
    var i = html.startIndex
    while i < html.endIndex {
        let ch = html[i]
        if ch == "<" {
            // Read the tag name; <p> becomes a paragraph break.
            var j = html.index(after: i)
            var tag = ""
            while j < html.endIndex, html[j] != ">" {
                tag.append(html[j]); j = html.index(after: j)
            }
            if tag.lowercased().hasPrefix("p") { out += "\n\n" }
            i = j < html.endIndex ? html.index(after: j) : j
        } else if ch == "&" {
            var j = html.index(after: i)
            var entity = ""
            while j < html.endIndex, html[j] != ";", entity.count < 10 {
                entity.append(html[j]); j = html.index(after: j)
            }
            if j < html.endIndex, html[j] == ";" {
                out += decodeHTMLEntity(entity)
                i = html.index(after: j)
            } else {
                out.append(ch); i = html.index(after: i)
            }
        } else {
            out.append(ch); i = html.index(after: i)
        }
    }
    return out
}

private func decodeHTMLEntity(_ e: String) -> String {
    switch e {
    case "amp": return "&"
    case "lt": return "<"
    case "gt": return ">"
    case "quot": return "\""
    case "apos", "#x27", "#39": return "'"
    case "#x2F", "#47": return "/"
    case "nbsp": return " "
    default:
        if e.hasPrefix("#x"), let code = UInt32(e.dropFirst(2), radix: 16),
           let scalar = Unicode.Scalar(code) {
            return String(Character(scalar))
        }
        if e.hasPrefix("#"), let code = UInt32(e.dropFirst()), let scalar = Unicode.Scalar(code) {
            return String(Character(scalar))
        }
        return "&\(e);"
    }
}
