// The Pokédex mini-app: a list/search interface over https://pokeapi.co
// (URLSession), a detail page per Pokémon, and a "caught" record persisted to
// the app's files (FileManager). All of it is platform-agnostic: the same
// Foundation calls on every platform.

import SwiftUI
import Isomer
import Observation

// MARK: - Models

struct PokemonRef: Identifiable, Hashable {
    let id: Int
    let name: String

    /// Small sprite for list rows.
    var sprite: String {
        "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/\(id).png"
    }

    /// High-resolution artwork for the detail page.
    var artwork: String {
        "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/other/official-artwork/\(id).png"
    }
}

// MARK: - Persisted "caught" record (shared business logic)

/// Records which game versions each Pokémon has been caught in, persisted as a
/// JSON file in Application Support (`SandboxFiles`, over FileManager).
@Observable final class PokedexStore {
    private(set) var caught: [Int: Set<String>] = [:]
    init() {
        load()
    }

    func isCaught(_ id: Int, game: String) -> Bool {
        caught[id]?.contains(game) ?? false
    }

    func gameCount(_ id: Int) -> Int {
        caught[id]?.count ?? 0
    }

    var totalCaught: Int { caught.count }

    func toggle(_ id: Int, game: String) {
        var games = caught[id] ?? []
        if games.contains(game) {
            games.remove(game)
        } else {
            games.insert(game)
        }
        caught[id] = games.isEmpty ? nil : games
        save()
    }

    private func load() {
        guard let text = SandboxFiles.read("pokedex.json"),
              let object = parseJSON(text)?.object else { return }
        var result: [Int: Set<String>] = [:]
        for (key, value) in object {
            guard let id = Int(key), let array = value.array else { continue }
            result[id] = Set(array.compactMap { $0.string })
        }
        caught = result
    }

    private func save() {
        var object: [String: JSONValue] = [:]
        for (id, games) in caught {
            object["\(id)"] = .array(games.sorted().map { .string($0) })
        }
        SandboxFiles.write("pokedex.json", JSONValue.object(object).encoded())
    }
}

// MARK: - List + search

@Observable final class PokemonListModel {
    private(set) var all: [PokemonRef] = []
    private(set) var loading = false
    private var requested = false

    func loadIfNeeded() {
        guard !requested else { return }
        requested = true
        loading = true
        Networking.fetch("https://pokeapi.co/api/v2/pokemon?limit=1025") { [weak self] text in
            guard let self else { return }
            self.loading = false
            guard let text, let results = parseJSON(text)?["results"].array else { return }
            self.all = results.compactMap { entry in
                guard let name = entry["name"].string,
                      let url = entry["url"].string,
                      let id = pokemonID(fromURL: url) else { return nil }
                return PokemonRef(id: id, name: name)
            }
        }
    }

    /// Case-insensitive prefix/substring filter, capped so the list stays light.
    func filter(_ query: String) -> [PokemonRef] {
        let trimmed = query.lowercased()
        let matches = trimmed.isEmpty ? all : all.filter { $0.name.contains(trimmed) }
        return Array(matches.prefix(40))
    }
}

/// Pokédex list screen, designed to drop into a shared NavigationStack (the
/// Apps tab) so it pushes detail onto the same stack.
struct PokedexScreen: View {
    @State private var model = PokemonListModel()
    @State private var query = ""

    var body: some View {
        content
            .searchable(text: $query, prompt: "Search Pokémon")
            .navigationTitle("Pokédex")
            .onAppear { model.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if model.all.isEmpty && model.loading {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading Pokédex…").font(.subheadline).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.top, 80)
        } else {
            List {
                ForEach(model.filter(query)) { pokemon in
                    NavigationLink {
                        PokemonDetailView(pokemon: pokemon)
                    } label: {
                        PokemonRow(pokemon: pokemon)
                    }
                }
            }
        }
    }
}

struct PokemonRow: View {
    let pokemon: PokemonRef
    @Environment(PokedexStore.self) private var pokedex

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: pokemon.sprite)) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Color(white: 0, opacity: 0.05)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text(capitalizeName(pokemon.name))
                    .font(.headline).foregroundColor(.primary).lineLimit(1)
                Text("#\(String(format3(pokemon.id)))")
                    .font(.subheadline).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            if pokedex.gameCount(pokemon.id) > 0 {
                Text("✓ \(pokedex.gameCount(pokemon.id))")
                    .font(.footnote)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.green)
                    .cornerRadius(8)
            }
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Detail

@Observable final class PokemonDetailModel {
    var loading = false
    var types: [String] = []
    var games: [String] = []
    var heightM = 0.0
    var weightKg = 0.0
    private var loadedID: Int?

    func load(id: Int) {
        guard loadedID != id else { return }
        loadedID = id
        loading = true
        Networking.fetch("https://pokeapi.co/api/v2/pokemon/\(id)") { [weak self] text in
            guard let self else { return }
            self.loading = false
            guard let text, let json = parseJSON(text) else { return }
            self.types = (json["types"].array ?? []).compactMap { $0["type"]["name"].string }
            self.heightM = (json["height"].double ?? 0) / 10
            self.weightKg = (json["weight"].double ?? 0) / 10
            var seen = Set<String>()
            var games: [String] = []
            for entry in json["game_indices"].array ?? [] {
                guard let version = entry["version"]["name"].string, !seen.contains(version) else { continue }
                seen.insert(version)
                games.append(version)
            }
            self.games = games
        }
    }
}

struct PokemonDetailView: View {
    let pokemon: PokemonRef
    @State private var model = PokemonDetailModel()
    @Environment(PokedexStore.self) private var pokedex

    var body: some View {
        List {
            // Hero section: artwork, name, types, and size, as one grouped block.
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    AsyncImage(url: URL(string: pokemon.artwork)) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Color(white: 0, opacity: 0.04)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .background(Color(white: 0, opacity: 0.04))
                    .cornerRadius(16)

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(capitalizeName(pokemon.name)).font(.title).bold()
                        Text("#\(String(format3(pokemon.id)))").font(.title3).foregroundColor(.secondary)
                    }

                    if !model.types.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(model.types, id: \.self) { type in
                                Text(capitalizeName(type))
                                    .font(.subheadline).foregroundColor(.white)
                                    .padding(.horizontal, 12).padding(.vertical, 5)
                                    .background(typeColor(type))
                                    .cornerRadius(12)
                            }
                        }
                    }

                    if model.heightM > 0 || model.weightKg > 0 {
                        HStack(spacing: 28) {
                            stat("Height", "\(model.heightM) m")
                            stat("Weight", "\(model.weightKg) kg")
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            // "Caught in" — a proper list section, one selectable row per game.
            Section("Caught in \(pokedex.gameCount(pokemon.id)) game\(pokedex.gameCount(pokemon.id) == 1 ? "" : "s")") {
                if model.loading && model.games.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading games…").font(.subheadline).foregroundColor(.secondary)
                    }
                } else if model.games.isEmpty {
                    Text("No game appearances found.")
                        .font(.subheadline).foregroundColor(.secondary)
                } else {
                    ForEach(model.games, id: \.self) { game in
                        GameRow(game: game, pokemonID: pokemon.id)
                    }
                }
            }
        }
        .navigationTitle(capitalizeName(pokemon.name))
        .onAppear { model.load(id: pokemon.id) }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Text(value).font(.headline)
        }
    }
}

struct GameRow: View {
    let game: String
    let pokemonID: Int
    @Environment(PokedexStore.self) private var pokedex

    var body: some View {
        let caught = pokedex.isCaught(pokemonID, game: game)
        Button {
            pokedex.toggle(pokemonID, game: game)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(caught ? Color.green : Color(white: 0, opacity: 0.12))
                        .frame(width: 24, height: 24)
                    if caught {
                        Text("✓").font(.footnote).foregroundColor(.white)
                    }
                }
                Text(prettyGame(game)).foregroundColor(.primary)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Helpers

func pokemonID(fromURL url: String) -> Int? {
    url.split(separator: "/").filter { !$0.isEmpty }.last.flatMap { Int($0) }
}

func capitalizeName(_ name: String) -> String {
    name.split(separator: "-").map { part -> String in
        guard let first = part.first else { return "" }
        return String(first).uppercased() + part.dropFirst()
    }.joined(separator: " ")
}

func prettyGame(_ game: String) -> String {
    capitalizeName(game)
}

/// Zero-pads a Pokédex number to three digits without Foundation formatting.
func format3(_ id: Int) -> String {
    let s = String(id)
    return String(repeating: "0", count: max(0, 3 - s.count)) + s
}

func typeColor(_ type: String) -> Color {
    switch type {
    case "fire": return .orange
    case "water": return .blue
    case "grass": return .green
    case "electric": return .yellow
    case "psychic": return .pink
    case "ice": return .teal
    case "dragon": return .purple
    case "dark": return Color(white: 0.25)
    case "fairy": return .pink
    case "poison": return .purple
    case "ground", "rock": return .brown
    case "fighting": return .red
    default: return Color(white: 0.45)
    }
}
