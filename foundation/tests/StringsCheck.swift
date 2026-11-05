import Foundation

// Bundle's strings tables: a bundle of .lproj folders made in /tmp, looked up
// with ISOMER_PREFERRED_LANGUAGES=fr-CA,en (the test's environment).
extension FoundationCheck {
    static func checkStrings() throws {
        let root = URL(fileURLWithPath: "/tmp/strings-check.bundle", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        for folder in ["en.lproj", "fr.lproj", "Base.lproj"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data("""
        /* Greeting */
        "greeting" = "Hello";
        "farewell" = "Goodbye";
        // Only in English
        "only.en" = "English only";
        """.utf8).write(to: root.appendingPathComponent("en.lproj/Localizable.strings"))
        var french = Data([0xff, 0xfe])
        french.append("\"greeting\" = \"Bonjour\\n\\\"toi\\\"\";\nfarewell = \"Au revoir\";\n\"accents\" = \"\\U00e9t\\u00e9\";\n"
            .data(using: .utf16LittleEndian)!)
        try french.write(to: root.appendingPathComponent("fr.lproj/Localizable.strings"))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(["title": "Titre"]).write(to: root.appendingPathComponent("fr.lproj/Menu.strings"))
        try Data("\"base.only\" = \"From Base\";".utf8).write(to: root.appendingPathComponent("Base.lproj/Localizable.strings"))

        guard let bundle = Bundle(path: root.path) else { return check("strings bundle", "nil", "a bundle") }
        check("localizations", bundle.localizations.joined(separator: ","), "en,fr")
        check("preferred localization", bundle.preferredLocalizations.joined(separator: ","), "fr")
        check("strings utf-16", bundle.localizedString(forKey: "greeting", value: nil, table: nil), "Bonjour\n\"toi\"")
        check("strings unquoted key", bundle.localizedString(forKey: "farewell", value: nil, table: nil), "Au revoir")
        check("strings escapes", bundle.localizedString(forKey: "accents", value: nil, table: nil), "été")
        check("strings development", bundle.localizedString(forKey: "only.en", value: nil, table: nil), "English only")
        check("strings base", bundle.localizedString(forKey: "base.only", value: nil, table: "Localizable"), "From Base")
        check("strings binary plist", bundle.localizedString(forKey: "title", value: nil, table: "Menu"), "Titre")
        check("strings value", bundle.localizedString(forKey: "missing", value: "Default", table: nil), "Default")
        check("strings key", bundle.localizedString(forKey: "missing", value: nil, table: nil), "missing")
        check("preferred fallback", Bundle.preferredLocalizations(from: ["de", "en"], forPreferences: ["ja-JP"]).joined(), "en")
        check("preferred region", Bundle.preferredLocalizations(from: ["pt", "pt-BR"], forPreferences: ["pt_BR"]).joined(), "pt-BR")
    }
}
