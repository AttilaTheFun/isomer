// Colours a story's Swift as the Playground's editor does: keywords, types,
// strings (their interpolations left plain), comments, numbers, and
// attributes and directives (`@State`, `#if`), in Xcode's palettes, the
// dark one in dark appearance. The Playground's lexer
// (playground/apple/playground_ios_application/CodeEditor.swift) in plain
// Swift, so it runs on every platform: the result is an AttributedString
// for one Text.

import Foundation
import SwiftUI

enum SwiftHighlighter {
    enum Token { case keyword, type, string, comment, number, attribute, plain }

    static let keywords: Set<String> = [
        "import", "struct", "class", "enum", "protocol", "extension", "func", "var", "let",
        "if", "else", "for", "in", "while", "repeat", "return", "switch", "case", "default",
        "break", "continue", "guard", "defer", "do", "try", "catch", "throw", "throws",
        "rethrows", "async", "await", "some", "any", "where", "is", "as", "self", "Self",
        "super", "init", "deinit", "static", "private", "fileprivate", "internal", "public",
        "open", "final", "override", "mutating", "nonmutating", "lazy", "weak", "unowned",
        "inout", "indirect", "typealias", "associatedtype", "subscript", "operator",
        "true", "false", "nil", "get", "set", "willSet", "didSet", "actor", "macro",
        "package", "consuming", "borrowing", "fallthrough", "convenience", "required",
    ]

    /// A token's colour: Xcode's default themes.
    static func color(_ token: Token, dark: Bool) -> Color {
        switch (token, dark) {
        case (.keyword, true): return Color(red: 0.99, green: 0.37, blue: 0.64)
        case (.keyword, false): return Color(red: 0.61, green: 0.14, blue: 0.58)
        case (.type, true): return Color(red: 0.36, green: 0.85, blue: 1.00)
        case (.type, false): return Color(red: 0.04, green: 0.31, blue: 0.47)
        case (.string, true): return Color(red: 0.99, green: 0.42, blue: 0.36)
        case (.string, false): return Color(red: 0.77, green: 0.10, blue: 0.09)
        case (.comment, true): return Color(red: 0.42, green: 0.47, blue: 0.53)
        case (.comment, false): return Color(red: 0.36, green: 0.42, blue: 0.47)
        case (.number, true): return Color(red: 0.82, green: 0.75, blue: 0.41)
        case (.number, false): return Color(red: 0.11, green: 0.00, blue: 0.81)
        case (.attribute, true): return Color(red: 0.75, green: 0.52, blue: 0.33)
        case (.attribute, false): return Color(red: 0.39, green: 0.22, blue: 0.13)
        case (.plain, _): return .primary
        }
    }

    /// `source` as coloured runs.
    static func highlight(_ source: String, dark: Bool) -> AttributedString {
        let scalars = Array(source.unicodeScalars)
        var result = AttributedString()
        func at(_ k: Int) -> Unicode.Scalar { k < scalars.count ? scalars[k] : "\0" }
        func isIdentStart(_ c: Unicode.Scalar) -> Bool { c == "_" || ("a"..."z").contains(c) || ("A"..."Z").contains(c) }
        func isIdent(_ c: Unicode.Scalar) -> Bool { isIdentStart(c) || ("0"..."9").contains(c) }
        func isDigit(_ c: Unicode.Scalar) -> Bool { ("0"..."9").contains(c) }
        func append(_ from: Int, _ to: Int, _ token: Token) {
            guard to > from else { return }
            var text = String.UnicodeScalarView()
            text.append(contentsOf: scalars[from..<to])
            var run = AttributedString(String(text))
            run.foregroundColor = color(token, dark: dark)
            result.append(run)
        }
        var i = 0
        var plainStart = 0
        func token(_ from: Int, _ to: Int, _ kind: Token) {
            append(plainStart, from, .plain)
            append(from, to, kind)
            plainStart = to
        }
        while i < scalars.count {
            let c = at(i)
            // Comments: to the line's end, or /* … */ (nesting).
            if c == "/", at(i + 1) == "/" {
                var j = i
                while j < scalars.count, at(j) != "\n" { j += 1 }
                token(i, j, .comment); i = j; continue
            }
            if c == "/", at(i + 1) == "*" {
                var j = i + 2, depth = 1
                while j < scalars.count, depth > 0 {
                    if at(j) == "/", at(j + 1) == "*" { depth += 1; j += 2; continue }
                    if at(j) == "*", at(j + 1) == "/" { depth -= 1; j += 2; continue }
                    j += 1
                }
                token(i, j, .comment); i = j; continue
            }
            // Strings: "…" and """…""", with \( … ) interpolation left plain.
            if c == "\"" {
                let triple = at(i + 1) == "\"" && at(i + 2) == "\""
                var j = i + (triple ? 3 : 1)
                var segmentStart = i
                while j < scalars.count {
                    if at(j) == "\\" {
                        if at(j + 1) == "(" {
                            token(segmentStart, j, .string)
                            var k = j + 2, depth = 1
                            while k < scalars.count, depth > 0 {
                                if at(k) == "(" { depth += 1 } else if at(k) == ")" { depth -= 1 }
                                k += 1
                            }
                            // The interpolation's inside, coloured as code.
                            let inner = String(String.UnicodeScalarView(scalars[(j + 2)..<max(j + 2, k - 1)]))
                            append(plainStart, j + 2, .plain)
                            result.append(highlight(inner, dark: dark))
                            plainStart = max(j + 2, k - 1)
                            j = k; segmentStart = k; continue
                        }
                        j += 2; continue
                    }
                    if triple {
                        if at(j) == "\"", at(j + 1) == "\"", at(j + 2) == "\"" { j += 3; break }
                    } else if at(j) == "\"" || at(j) == "\n" {
                        j += at(j) == "\"" ? 1 : 0; break
                    }
                    j += 1
                }
                token(segmentStart, min(j, scalars.count), .string); i = j; continue
            }
            // Attributes and directives: @State, #if, #Preview.
            if c == "@" || c == "#", isIdentStart(at(i + 1)) {
                var j = i + 1
                while isIdent(at(j)) { j += 1 }
                token(i, j, .attribute); i = j; continue
            }
            // Numbers.
            if isDigit(c), i == 0 || !isIdent(at(i - 1)) {
                var j = i
                while isIdent(at(j)) || (at(j) == "." && isDigit(at(j + 1))) { j += 1 }
                token(i, j, .number); i = j; continue
            }
            // Identifiers: keywords, or Capitalized → a type.
            if isIdentStart(c) {
                var j = i
                while isIdent(at(j)) { j += 1 }
                let word = String(String.UnicodeScalarView(scalars[i..<j]))
                // An argument label is no keyword (`in:` in `Stepper(…, in: 0 ... 9)`).
                let isLabel = at(j) == ":" && word != "default"
                if keywords.contains(word), !isLabel {
                    token(i, j, .keyword)
                } else if ("A"..."Z").contains(c) {
                    token(i, j, .type)
                }
                i = j; continue
            }
            i += 1
        }
        append(plainStart, scalars.count, .plain)
        return result
    }
}
