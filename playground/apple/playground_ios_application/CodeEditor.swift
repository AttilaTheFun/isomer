// A code editor for the Playground: a UITextView with the code-unfriendly
// keyboard behaviors turned off (smart quotes/dashes, autocorrect, auto-
// capitalization), a "coding keyboard" accessory row of the characters
// programmers reach for, and Swift syntax highlighting (a small built-in
// lexer over NSAttributedString — no third-party package; see
// docs/playground.md for the RSPM alternatives).

import SwiftUI

#if os(iOS)
import UIKit

struct CodeEditor: UIViewRepresentable {
    @Binding var text: String
    /// File name for the syntax check's diagnostics.
    var fileName: String = "Untitled.swift"

    func makeUIView(context: Context) -> EditorContainer {
        let container = EditorContainer()
        let view = container.textView
        context.coordinator.container = container
        context.coordinator.fileName = fileName
        view.delegate = context.coordinator
        view.font = SwiftHighlighter.font
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        view.alwaysBounceVertical = true
        // Code, not prose: no smart punctuation (straight quotes!), no
        // autocorrect/capitalization, ASCII-capable keyboard.
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.keyboardType = .asciiCapable
        view.inputAccessoryView = CodingKeyboard.make(for: view)
        view.attributedText = SwiftHighlighter.highlight(text)
        context.coordinator.scheduleCheck(view)
        return container
    }

    func updateUIView(_ container: EditorContainer, context: Context) {
        context.coordinator.fileName = fileName
        let view = container.textView
        guard view.text != text else { return }
        let selection = view.selectedRange
        view.attributedText = SwiftHighlighter.highlight(text)
        view.selectedRange = NSRange(
            location: min(selection.location, (text as NSString).length), length: 0)
        context.coordinator.diagnostics = []
        container.setMessage(nil)
        context.coordinator.scheduleCheck(view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditor
        weak var container: EditorContainer?
        var fileName = "Untitled.swift"
        var diagnostics: [SyntaxDiagnostic] = []
        private var rehighlight: DispatchWorkItem?
        private var check: DispatchWorkItem?
        private var checkGeneration = 0

        init(_ parent: CodeEditor) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
            // Re-color shortly after typing settles; keeps keystrokes cheap
            // and the caret stable (the attributed swap preserves selection).
            rehighlight?.cancel()
            let work = DispatchWorkItem { [weak view, weak self] in
                guard let view, let self else { return }
                self.recolor(view)
            }
            rehighlight = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            scheduleCheck(view)
        }

        /// Syntax check half a second after typing stops (the parse-only
        /// frontend pass, off the main thread); squiggles the error lines.
        func scheduleCheck(_ view: UITextView) {
            check?.cancel()
            checkGeneration += 1
            let generation = checkGeneration
            let source = view.text ?? ""
            let name = fileName
            let work = DispatchWorkItem { [weak self, weak view] in
                DispatchQueue.global(qos: .userInitiated).async {
                    let found = ToolchainCompiler.syntaxCheck(source: source, fileName: name)
                        .filter { $0.severity == "error" }
                    DispatchQueue.main.async {
                        guard let self, let view, generation == self.checkGeneration,
                              view.text == source else { return }
                        self.diagnostics = found
                        self.recolor(view)
                        self.container?.setMessage(found.first.map { "Line \($0.line): \($0.message)" }
                            .map { found.count > 1 ? "\($0)  (+\(found.count - 1) more)" : $0 })
                    }
                }
            }
            check = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }

        private func recolor(_ view: UITextView) {
            let selection = view.selectedRange
            let colored = NSMutableAttributedString(attributedString: SwiftHighlighter.highlight(view.text))
            let ns = view.text as NSString
            for diagnostic in diagnostics {
                // Underline from the diagnostic's column to the end of its line.
                var lineStart = 0
                var current = 1
                while current < diagnostic.line, lineStart < ns.length {
                    let range = ns.lineRange(for: NSRange(location: lineStart, length: 0))
                    lineStart = NSMaxRange(range)
                    current += 1
                }
                guard lineStart <= ns.length else { continue }
                let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
                var start = lineStart + max(diagnostic.column - 1, 0)
                var end = NSMaxRange(lineRange)
                if end > 0, ns.character(at: end - 1) == 10 { end -= 1 }
                if start >= end { start = lineStart }
                guard end > start else { continue }
                colored.addAttributes([
                    .underlineStyle: NSUnderlineStyle([.thick, .patternDot]).rawValue,
                    .underlineColor: UIColor.systemRed,
                ], range: NSRange(location: start, length: end - start))
            }
            // Re-attribute IN PLACE: swapping `attributedText` replaces the
            // text storage and resets the scroll position (the editor jumped
            // to the top a beat after every keystroke further down a file).
            // The string is unchanged, so only attributes move.
            let offset = view.contentOffset
            let storage = view.textStorage
            guard storage.length == colored.length else {
                view.attributedText = colored
                view.selectedRange = selection
                return
            }
            storage.beginEditing()
            colored.enumerateAttributes(in: NSRange(location: 0, length: colored.length)) { attributes, range, _ in
                storage.setAttributes(attributes, range: range)
            }
            storage.endEditing()
            view.selectedRange = selection
            view.setContentOffset(offset, animated: false)
        }

        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Keep the indentation of the previous line on Return.
            guard text == "\n" else { return true }
            let ns = view.text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            let line = ns.substring(with: lineRange)
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            let opensBlock = line.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("{")
            let insertion = "\n" + indent + (opensBlock ? "    " : "")
            view.textStorage.replaceCharacters(in: range, with: insertion)
            view.selectedRange = NSRange(location: range.location + (insertion as NSString).length, length: 0)
            textViewDidChange(view)
            return false
        }
    }
}

/// The text view plus a one-line red footer for the first syntax error.
final class EditorContainer: UIView {
    let textView = UITextView()
    private let footer = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        footer.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        footer.textColor = .systemRed
        footer.numberOfLines = 2
        footer.backgroundColor = .secondarySystemBackground
        footer.isHidden = true
        let stack = UIStackView(arrangedSubviews: [textView, footer])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        footer.setContentHuggingPriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setMessage(_ message: String?) {
        footer.text = message.map { "  " + $0 }
        footer.isHidden = message == nil
    }
}

/// Read-only, wrapping, selectable monospaced text (the diagnostics view).
struct ReadOnlyCodeText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .systemRed
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        view.textContainer.lineBreakMode = .byWordWrapping
        view.alwaysBounceVertical = true
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}

/// The accessory row above the keyboard: the characters code needs that the
/// iOS keyboard buries (or "smartens"), plus Tab and a dismiss key.
enum CodingKeyboard {
    static let keys = ["⇥", "\"", "'", "{", "}", "(", ")", "[", "]", "<", ">", "=", ":", ";", ".", ",", "_", "\\", "/", "$", "!", "?", "&", "|", "*", "+", "-", "@", "#"]

    static func make(for textView: UITextView) -> UIView {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .secondarySystemBackground
        scroll.autoresizingMask = [.flexibleWidth]
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        for key in keys {
            let button = UIButton(type: .system)
            button.setTitle(key, for: .normal)
            button.titleLabel?.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
            button.backgroundColor = .tertiarySystemBackground
            button.layer.cornerRadius = 6
            button.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
            button.addAction(UIAction { [weak textView] _ in
                guard let textView else { return }
                let insertion = key == "⇥" ? "    " : key
                textView.insertText(insertion)
            }, for: .touchUpInside)
            row.addArrangedSubview(button)
        }
        let hide = UIButton(type: .system)
        hide.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        hide.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        hide.addAction(UIAction { [weak textView] _ in textView?.resignFirstResponder() }, for: .touchUpInside)
        row.addArrangedSubview(hide)
        scroll.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -6),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -12),
        ])
        return scroll
    }
}

typealias PlatformColor = UIColor
#elseif os(macOS)
import AppKit
typealias PlatformColor = NSColor
#endif

/// A small Swift lexer that colors keywords, types, strings (with
/// interpolation left plain), comments, numbers and attributes/directives.
/// Whole-buffer, single pass — playground files are small.
enum SwiftHighlighter {
    #if os(iOS)
    static let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    #else
    static let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    #endif

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

    enum Token { case keyword, type, string, comment, number, attribute, plain }

    static func color(_ token: Token) -> PlatformColor {
        switch token {
        case .keyword: return PlatformColor(red: 0.98, green: 0.30, blue: 0.62, alpha: 1)
        case .type: return PlatformColor(red: 0.36, green: 0.85, blue: 0.93, alpha: 1)
        case .string: return PlatformColor(red: 0.99, green: 0.42, blue: 0.36, alpha: 1)
        case .comment: return PlatformColor(red: 0.45, green: 0.55, blue: 0.45, alpha: 1)
        case .number: return PlatformColor(red: 0.85, green: 0.78, blue: 0.40, alpha: 1)
        case .attribute: return PlatformColor(red: 0.75, green: 0.55, blue: 0.95, alpha: 1)
        case .plain:
            #if os(iOS)
            return .label
            #else
            return .labelColor
            #endif
        }
    }

    static func highlight(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color(.plain),
        ])
        let utf16 = Array(text.utf16)
        var i = 0
        func at(_ k: Int) -> UInt16 { k < utf16.count ? utf16[k] : 0 }
        func isIdentStart(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
        func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) }
        func paint(_ from: Int, _ to: Int, _ token: Token) {
            guard to > from else { return }
            result.addAttribute(.foregroundColor, value: color(token), range: NSRange(location: from, length: to - from))
        }
        while i < utf16.count {
            let c = at(i)
            // Comments.
            if c == 47, at(i + 1) == 47 { // //
                var j = i
                while j < utf16.count, at(j) != 10 { j += 1 }
                paint(i, j, .comment); i = j; continue
            }
            if c == 47, at(i + 1) == 42 { // /* ... */ (nesting)
                var j = i + 2, depth = 1
                while j < utf16.count, depth > 0 {
                    if at(j) == 47, at(j + 1) == 42 { depth += 1; j += 2; continue }
                    if at(j) == 42, at(j + 1) == 47 { depth -= 1; j += 2; continue }
                    j += 1
                }
                paint(i, j, .comment); i = j; continue
            }
            // Strings: "…", """…""", with \( … ) interpolation left plain.
            if c == 34 {
                let triple = at(i + 1) == 34 && at(i + 2) == 34
                var j = i + (triple ? 3 : 1)
                var segmentStart = i
                while j < utf16.count {
                    if at(j) == 92 { // backslash
                        if at(j + 1) == 40 { // \( interpolation
                            paint(segmentStart, j, .string)
                            var k = j + 2, depth = 1
                            while k < utf16.count, depth > 0 {
                                if at(k) == 40 { depth += 1 } else if at(k) == 41 { depth -= 1 }
                                k += 1
                            }
                            j = k; segmentStart = k; continue
                        }
                        j += 2; continue
                    }
                    if triple {
                        if at(j) == 34, at(j + 1) == 34, at(j + 2) == 34 { j += 3; break }
                    } else if at(j) == 34 || at(j) == 10 {
                        j += at(j) == 34 ? 1 : 0; break
                    }
                    j += 1
                }
                paint(segmentStart, j, .string); i = j; continue
            }
            // Attributes and directives: @State, #if, #Preview.
            if c == 64 || c == 35, isIdentStart(at(i + 1)) {
                var j = i + 1
                while isIdent(at(j)) { j += 1 }
                paint(i, j, .attribute); i = j; continue
            }
            // Numbers.
            if c >= 48 && c <= 57 {
                var j = i
                while isIdent(at(j)) || at(j) == 46 && (at(j + 1) >= 48 && at(j + 1) <= 57) { j += 1 }
                paint(i, j, .number); i = j; continue
            }
            // Identifiers: keywords, or Capitalized → type.
            if isIdentStart(c) {
                var j = i
                while isIdent(at(j)) { j += 1 }
                let word = String(utf16CodeUnits: Array(utf16[i..<j]), count: j - i)
                if keywords.contains(word) {
                    paint(i, j, .keyword)
                } else if c >= 65 && c <= 90 {
                    paint(i, j, .type)
                }
                i = j; continue
            }
            i += 1
        }
        return result
    }
}
