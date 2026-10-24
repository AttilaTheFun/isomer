// Images: symbols, the app's own images, sizing, and images from the network.

import Foundation
import SwiftUI

extension StoryCatalog {
    static let images = StoryArea(id: "images", title: "Images", symbol: "photo", stories: [
        Story(
            "images.symbols", "Symbols",
            summary: "SF Symbols by name. They size with the font, like text, and take a color. Off Apple's platforms Isomer draws the symbols it carries; a name it lacks draws nothing."
        ) { SymbolsStory() },
        Story(
            "images.assets", "App images",
            summary: "An image the app ships, by name: an asset catalog's on Apple's platforms, the app's assets elsewhere. Resizable, it fits or fills the frame it is given."
        ) { AppImagesStory() },
        Story(
            "images.async", "AsyncImage",
            summary: "An image loaded from a URL, with a placeholder until it arrives."
        ) { AsyncImageStory() },
    ])
}

// story: images.symbols
struct SymbolsStory: View {
    private let names = ["star.fill", "heart.fill", "bolt.fill", "cloud.sun.fill", "gearshape", "trash", "paperplane", "magnifyingglass"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                ForEach(names, id: \.self) { name in
                    Image(systemName: name)
                }
            }
            .font(.title2)
            HStack(spacing: 16) {
                Image(systemName: "star.fill").foregroundStyle(.yellow)
                Image(systemName: "heart.fill").foregroundStyle(.red)
                Image(systemName: "bolt.fill").foregroundStyle(.orange)
                Image(systemName: "leaf.fill").foregroundStyle(.green)
            }
            .font(.largeTitle)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "folder").font(.caption)
                Image(systemName: "folder").font(.body)
                Image(systemName: "folder").font(.title)
                Image(systemName: "folder").font(.system(size: 44))
            }
        }
    }
}
// end story

// story: images.assets
struct AppImagesStory: View {
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image("iso-logo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
            Image("iso-logo")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 96, height: 60)
                .clipped()
            Image("iso-logo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .padding(8)
                .background(Color.blue.opacity(0.15))
                .clipShape(Circle())
        }
    }
}
// end story

// story: images.async
struct AsyncImageStory: View {
    private let url = URL(string: "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/25.png")

    var body: some View {
        HStack(spacing: 20) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                ProgressView()
            }
            .frame(width: 120, height: 120)
            AsyncImage(url: url)
                .frame(width: 96, height: 96)
        }
    }
}
// end story
