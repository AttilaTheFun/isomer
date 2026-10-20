// The shader translator's lexer: Metal Shading Language source to tokens.
// Comments are skipped, preprocessor lines are kept as one token each (the
// parser handles #include and simple object-like #defines), and `[[` / `]]`
// are left as single brackets for the parser to pair (`a[b[c]]` is not an
// attribute).

public struct MSLSourceLocation: Hashable, Sendable, CustomStringConvertible {
    public var line: Int
    public var column: Int
    public var description: String { "\(line):\(column)" }
}

public enum MSLTokenKind: Equatable, Sendable {
    case identifier(String)
    case integer(String)
    case float(String)
    case punctuation(String)
    case preprocessor(String)
    case end
}

public struct MSLToken: Equatable, Sendable {
    public var kind: MSLTokenKind
    public var location: MSLSourceLocation

    var identifier: String? {
        if case .identifier(let name) = kind { return name }
        return nil
    }

    func isPunctuation(_ text: String) -> Bool {
        if case .punctuation(let p) = kind { return p == text }
        return false
    }

    func isIdentifier(_ text: String) -> Bool {
        if case .identifier(let name) = kind { return name == text }
        return false
    }
}

/// An error in the shader source or something the translator does not
/// handle, with where it was found.
public struct MSLTranslationError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public var location: MSLSourceLocation?

    public init(_ message: String, at location: MSLSourceLocation? = nil) {
        self.message = message
        self.location = location
    }

    public var description: String {
        if let location { return "\(location): \(message)" }
        return message
    }
}

struct MSLLexer {
    private let scalars: [Unicode.Scalar]
    private var index = 0
    private var line = 1
    private var column = 1

    init(_ source: String) {
        scalars = Array(source.unicodeScalars)
    }

    private static let punctuators: [String] = [
        "<<=", ">>=", "...",
        "::", "->", "++", "--", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=",
        "==", "!=", "<=", ">=", "&&", "||", "<<", ">>",
        "{", "}", "(", ")", "[", "]", ";", ",", ".", "<", ">", "=", "+", "-", "*", "/", "%",
        "!", "~", "&", "|", "^", "?", ":", "#",
    ]

    mutating func tokenize() throws -> [MSLToken] {
        var tokens: [MSLToken] = []
        var atLineStart = true
        while true {
            skipSpaceAndComments(atLineStart: &atLineStart)
            let location = MSLSourceLocation(line: line, column: column)
            guard index < scalars.count else {
                tokens.append(MSLToken(kind: .end, location: location))
                return tokens
            }
            let c = scalars[index]
            if c == "#" && atLineStart {
                tokens.append(MSLToken(kind: .preprocessor(readLine()), location: location))
                atLineStart = true
                continue
            }
            atLineStart = false
            if isIdentifierStart(c) {
                var name = ""
                while index < scalars.count, isIdentifierPart(scalars[index]) {
                    name.unicodeScalars.append(advance())
                }
                tokens.append(MSLToken(kind: .identifier(name), location: location))
                continue
            }
            if isDigit(c) || (c == "." && index + 1 < scalars.count && isDigit(scalars[index + 1])) {
                tokens.append(MSLToken(kind: readNumber(), location: location))
                continue
            }
            var matched: String?
            for p in MSLLexer.punctuators where matches(p) {
                matched = p
                break
            }
            guard let punctuation = matched else {
                throw MSLTranslationError("unexpected character '\(Character(c))'", at: location)
            }
            for _ in punctuation.unicodeScalars { _ = advance() }
            tokens.append(MSLToken(kind: .punctuation(punctuation), location: location))
        }
    }

    // MARK: Helpers

    private mutating func advance() -> Unicode.Scalar {
        let c = scalars[index]
        index += 1
        if c == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }
        return c
    }

    private func matches(_ text: String) -> Bool {
        var i = index
        for s in text.unicodeScalars {
            guard i < scalars.count, scalars[i] == s else { return false }
            i += 1
        }
        return true
    }

    private mutating func skipSpaceAndComments(atLineStart: inout Bool) {
        while index < scalars.count {
            let c = scalars[index]
            if c == "\n" {
                atLineStart = true
                _ = advance()
            } else if c == " " || c == "\t" || c == "\r" {
                _ = advance()
            } else if c == "\\" && index + 1 < scalars.count && scalars[index + 1] == "\n" {
                _ = advance()
                _ = advance()
            } else if matches("//") {
                while index < scalars.count && scalars[index] != "\n" { _ = advance() }
            } else if matches("/*") {
                _ = advance()
                _ = advance()
                while index < scalars.count && !matches("*/") { _ = advance() }
                if index < scalars.count {
                    _ = advance()
                    _ = advance()
                }
            } else {
                return
            }
        }
    }

    /// A preprocessor line, continuations joined, comments dropped.
    private mutating func readLine() -> String {
        var text = ""
        while index < scalars.count {
            if scalars[index] == "\\" && index + 1 < scalars.count && scalars[index + 1] == "\n" {
                _ = advance()
                _ = advance()
                text += " "
                continue
            }
            if scalars[index] == "\n" { break }
            if matches("//") {
                while index < scalars.count && scalars[index] != "\n" { _ = advance() }
                break
            }
            text.unicodeScalars.append(advance())
        }
        return text
    }

    private mutating func readNumber() -> MSLTokenKind {
        var text = ""
        var isFloat = false
        if matches("0x") || matches("0X") {
            text.unicodeScalars.append(advance())
            text.unicodeScalars.append(advance())
            while index < scalars.count, isHexDigit(scalars[index]) { text.unicodeScalars.append(advance()) }
        } else {
            while index < scalars.count, isDigit(scalars[index]) { text.unicodeScalars.append(advance()) }
            if index < scalars.count, scalars[index] == "." {
                isFloat = true
                text.unicodeScalars.append(advance())
                while index < scalars.count, isDigit(scalars[index]) { text.unicodeScalars.append(advance()) }
            }
            if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
                isFloat = true
                text.unicodeScalars.append(advance())
                if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" {
                    text.unicodeScalars.append(advance())
                }
                while index < scalars.count, isDigit(scalars[index]) { text.unicodeScalars.append(advance()) }
            }
        }
        // Suffixes: f, h (float), u, l (integer).
        while index < scalars.count, "fFhHuUlL".unicodeScalars.contains(scalars[index]) {
            let suffix = advance()
            if "fFhH".unicodeScalars.contains(suffix) { isFloat = true }
            text.unicodeScalars.append(suffix)
        }
        return isFloat ? .float(text) : .integer(text)
    }

    private func isIdentifierStart(_ c: Unicode.Scalar) -> Bool {
        c == "_" || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
    }

    private func isIdentifierPart(_ c: Unicode.Scalar) -> Bool {
        isIdentifierStart(c) || isDigit(c)
    }

    private func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }

    private func isHexDigit(_ c: Unicode.Scalar) -> Bool {
        isDigit(c) || (c >= "a" && c <= "f") || (c >= "A" && c <= "F")
    }
}
