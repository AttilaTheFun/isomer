// Wikipedia reader: a `.searchable` feed driven by the Wikipedia API, with an
// article detail page (full text fetched from the extracts API) and an in-app
// WebView for the live page. Compiles unchanged on every platform.

import SwiftUI
import Isomer
import Observation

struct Article: Identifiable, Hashable {
    let id: Int
    let order: Int
    let title: String
    let extract: String
    let thumbnail: String?
}

@Observable final class FeedModel {
    static let defaultQuery = "Space exploration"

    var articles: [Article] = []
    var isLoading = false

    /// The most recent query we asked for; used to drop stale responses that
    /// arrive out of order while the user is typing.
    private var lastRequested = ""

    func load(query: String) {
        let q = query.isEmpty ? FeedModel.defaultQuery : query
        lastRequested = q
        isLoading = true
        // Note the pipe in `prop=` is percent-encoded (%7C): Foundation's
        // URL(string:) rejects a raw "|", which would fail the fetch on Apple.
        let url = "https://en.wikipedia.org/w/api.php"
            + "?action=query&format=json&origin=*"
            + "&generator=search&gsrsearch=\(percentEncoded(q))&gsrlimit=20"
            + "&prop=pageimages%7Cextracts&piprop=thumbnail&pithumbsize=160"
            + "&exintro=1&explaintext=1&exsentences=2&redirects=1"
        Networking.fetch(url) { [weak self] text in
            guard let self, q == self.lastRequested else { return }
            self.isLoading = false
            self.articles = Self.parse(text)
        }
    }

    private static func parse(_ text: String?) -> [Article] {
        guard let text, let json = parseJSON(text),
              let pages = json["query"]["pages"].object else { return [] }
        var result: [Article] = []
        for (_, page) in pages {
            result.append(Article(
                id: page["pageid"].int ?? 0,
                order: page["index"].int ?? 0,
                title: page["title"].string ?? "Untitled",
                extract: page["extract"].string ?? "",
                thumbnail: page["thumbnail"]["source"].string
            ))
        }
        return result.sorted { $0.order < $1.order }
    }
}

/// Wikipedia feed screen, designed to drop into a shared NavigationStack (the
/// Apps tab) so it pushes article detail onto the same stack.
struct WikipediaScreen: View {
    @State private var model = FeedModel()
    @State private var query = ""

    var body: some View {
        feedContent
            .searchable(text: $query, prompt: "Search Wikipedia")
            .navigationTitle("Wikipedia")
            .onChange(of: query) { newValue in model.load(query: newValue) }
            .onAppear { if model.articles.isEmpty { model.load(query: "") } }
    }

    @ViewBuilder
    private var feedContent: some View {
        // Initial load (no query yet): a spinner. Otherwise always a List, so the
        // search field in its header stays put even when a search has no results.
        if model.articles.isEmpty && query.isEmpty && model.isLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading articles…")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        } else {
            List {
                ForEach(model.articles) { article in
                    NavigationLink {
                        ArticleView(article: article)
                    } label: {
                        ArticleRow(article: article)
                    }
                }
            }
        }
    }
}

struct ArticleRow: View {
    let article: Article

    /// Articles without a thumbnail (and thumbnails still loading) show a
    /// neutral adaptive gray in the same rounded square, with a glyph making
    /// the "no image" state explicit.
    private var thumbnailPlaceholder: some View {
        ZStack {
            Color(white: 0.5, opacity: 0.16)
            Text("🖼️")
                .font(.title3)
                .opacity(0.55)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let thumbnail = article.thumbnail {
                    AsyncImage(url: URL(string: thumbnail)) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        thumbnailPlaceholder
                    }
                } else {
                    thumbnailPlaceholder
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(article.extract)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }
}

struct Paragraph: Identifiable {
    let id: Int
    let text: String
}

/// Fetches an article's full plain-text body from the Wikipedia extracts API.
@Observable final class ArticleLoader {
    var paragraphs: [Paragraph] = []
    var loading = false
    private var loadedID: Int?

    func load(id: Int) {
        guard loadedID != id else { return }
        loadedID = id
        loading = true
        paragraphs = []
        let url = "https://en.wikipedia.org/w/api.php"
            + "?action=query&format=json&origin=*"
            + "&prop=extracts&explaintext=1&redirects=1&pageids=\(id)"
        Networking.fetch(url) { [weak self] text in
            guard let self else { return }
            self.loading = false
            self.paragraphs = Self.parse(text, id: id)
        }
    }

    private static func parse(_ text: String?, id: Int) -> [Paragraph] {
        guard let text, let json = parseJSON(text) else { return [] }
        let extract = json["query"]["pages"]["\(id)"]["extract"].string ?? ""
        var result: [Paragraph] = []
        for line in extract.split(separator: "\n") where !line.isEmpty {
            result.append(Paragraph(id: result.count, text: String(line)))
        }
        return result
    }
}

struct ArticleView: View {
    let article: Article
    @State private var loader = ArticleLoader()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if article.thumbnail != nil {
                    AsyncImage(url: URL(string: article.thumbnail ?? "")) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color(white: 0, opacity: 0.05)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .cornerRadius(12)
                }
                Text(article.title)
                    .font(.title)
                    .bold()
                    .foregroundColor(.primary)

                if loader.loading && loader.paragraphs.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading article…")
                            .font(.subheadline).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                } else if loader.paragraphs.isEmpty {
                    Text(article.extract.isEmpty ? "No summary available." : article.extract)
                        .font(.body).foregroundColor(.secondary)
                } else {
                    ForEach(loader.paragraphs) { paragraph in
                        Text(paragraph.text)
                            .font(.body)
                            .foregroundColor(.primary)
                    }
                }

                NavigationLink {
                    ArticleWebScreen(article: article)
                } label: {
                    Text("Open full page ›")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.accentColor)
                        .cornerRadius(10)
                }
                .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Article")
        .onAppear { loader.load(id: article.id) }
    }
}

/// The article's live page in an in-app web view (an iframe on the web, a
/// native WebView on Android, a WKWebView on Apple).
struct ArticleWebScreen: View {
    let article: Article

    var body: some View {
        WebView(url: URL(string:
            "https://en.wikipedia.org/wiki/\(percentEncoded(article.title))"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Web")
    }
}
