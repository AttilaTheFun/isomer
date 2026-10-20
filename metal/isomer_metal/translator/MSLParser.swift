// The shader translator's parser: tokens to a translation unit. A
// recursive-descent parser for the subset of the Metal Shading Language the
// translator handles; it reports anything else as an error with its source
// location rather than guessing.

struct MSLParser {
    private var tokens: [MSLToken]
    private var position = 0
    private var unit = MSLTranslationUnit()
    /// Object-like `#define`s: name to its replacement tokens.
    private var macros: [String: [MSLToken]] = [:]

    static let scalarTypes: Set<String> = [
        "void", "bool", "char", "uchar", "short", "ushort", "int", "uint", "long", "ulong",
        "half", "float", "size_t", "ptrdiff_t", "int8_t", "uint8_t", "int16_t", "uint16_t",
        "int32_t", "uint32_t", "int64_t", "uint64_t",
    ]

    static let templateTypes: Set<String> = [
        "texture1d", "texture1d_array", "texture2d", "texture2d_array", "texture2d_ms", "texture3d",
        "texturecube", "texturecube_array", "depth2d", "depth2d_array", "depth2d_ms", "depthcube",
        "array", "atomic", "vec", "matrix", "packed_vec",
    ]

    static func isBuiltinType(_ name: String) -> Bool {
        if scalarTypes.contains(name) || templateTypes.contains(name) { return true }
        if ["sampler", "atomic_int", "atomic_uint", "atomic_bool", "atomic_float"].contains(name) { return true }
        var base = name
        if base.hasPrefix("packed_") { base.removeFirst("packed_".count) }
        for scalar in ["bool", "char", "uchar", "short", "ushort", "int", "uint", "half", "float"] where base.hasPrefix(scalar) {
            let rest = base.dropFirst(scalar.count)
            if ["2", "3", "4"].contains(rest) { return true }
            if (scalar == "half" || scalar == "float"), rest.count == 3, rest.dropFirst().first == "x",
               "234".contains(rest.first!), "234".contains(rest.last!) {
                return true
            }
        }
        return false
    }

    init(source: String) throws {
        var lexer = MSLLexer(source)
        tokens = try lexer.tokenize()
    }

    mutating func parse() throws -> MSLTranslationUnit {
        while !current.isEnd {
            try parseTopLevel()
        }
        return unit
    }

    // MARK: Tokens

    private var current: MSLToken {
        tokens[position]
    }

    private func peek(_ offset: Int = 1) -> MSLToken {
        let i = Swift.min(position + offset, tokens.count - 1)
        return tokens[i]
    }

    @discardableResult
    private mutating func advance() -> MSLToken {
        let token = tokens[position]
        if position < tokens.count - 1 { position += 1 }
        return token
    }

    private mutating func expect(_ punctuation: String) throws {
        guard current.isPunctuation(punctuation) else {
            throw MSLTranslationError("expected '\(punctuation)', found \(describe(current))", at: current.location)
        }
        advance()
    }

    private mutating func accept(_ punctuation: String) -> Bool {
        if current.isPunctuation(punctuation) {
            advance()
            return true
        }
        return false
    }

    private mutating func acceptIdentifier(_ name: String) -> Bool {
        if current.isIdentifier(name) {
            advance()
            return true
        }
        return false
    }

    private mutating func expectIdentifier() throws -> String {
        guard let name = current.identifier else {
            throw MSLTranslationError("expected a name, found \(describe(current))", at: current.location)
        }
        advance()
        return name
    }

    private func describe(_ token: MSLToken) -> String {
        switch token.kind {
        case .identifier(let name): return "'\(name)'"
        case .integer(let text), .float(let text): return "'\(text)'"
        case .punctuation(let p): return "'\(p)'"
        case .preprocessor(let line): return "'\(line)'"
        case .end: return "the end of the source"
        }
    }

    // MARK: Top level

    private mutating func parseTopLevel() throws {
        if case .preprocessor(let line) = current.kind {
            let location = current.location
            advance()
            try handlePreprocessor(line, at: location)
            return
        }
        if accept(";") { return }
        if acceptIdentifier("using") {
            if acceptIdentifier("namespace") {
                _ = try expectIdentifier()
                try expect(";")
                return
            }
            let name = try expectIdentifier()
            try expect("=")
            let type = try parseType()
            try expect(";")
            unit.typeAliases[name] = type
            return
        }
        if acceptIdentifier("typedef") {
            if current.isIdentifier("struct") {
                let structLocation = current.location
                advance()
                if current.identifier != nil, !peek().isPunctuation("{") {
                    // typedef struct Foo Bar;
                    let target = try expectIdentifier()
                    let alias = try expectIdentifier()
                    try expect(";")
                    unit.typeAliases[alias] = MSLTypeSpec(name: target)
                    return
                }
                var tag: String?
                if let name = current.identifier {
                    tag = name
                    advance()
                }
                let fields = try parseStructBody()
                let alias = try expectIdentifier()
                try expect(";")
                unit.structs.append(MSLStruct(name: alias, fields: fields, location: structLocation))
                if let tag, tag != alias { unit.typeAliases[tag] = MSLTypeSpec(name: alias) }
                return
            }
            let type = try parseType()
            let alias = try expectIdentifier()
            try expect(";")
            unit.typeAliases[alias] = type
            return
        }
        if current.isIdentifier("struct") {
            let location = current.location
            advance()
            let name = try expectIdentifier()
            if accept(";") { return }  // forward declaration
            let fields = try parseStructBody()
            try expect(";")
            unit.structs.append(MSLStruct(name: name, fields: fields, location: location))
            return
        }
        if current.isIdentifier("namespace") {
            throw MSLTranslationError("namespaces of the shader's own are not supported", at: current.location)
        }
        if current.isIdentifier("template") {
            throw MSLTranslationError("templates of the shader's own are not supported", at: current.location)
        }
        try parseFunctionOrGlobal()
    }

    private mutating func handlePreprocessor(_ line: String, at location: MSLSourceLocation) throws {
        let text = line.drop(while: { $0 == "#" || $0 == " " || $0 == "\t" })
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let directive = parts.first else { return }
        switch directive {
        case "include", "pragma", "line":
            return
        case "define":
            guard parts.count > 1 else { return }
            let body = parts[1]
            var nameEnd = body.startIndex
            while nameEnd < body.endIndex, body[nameEnd].isLetter || body[nameEnd].isNumber || body[nameEnd] == "_" {
                nameEnd = body.index(after: nameEnd)
            }
            let name = String(body[body.startIndex..<nameEnd])
            if nameEnd < body.endIndex, body[nameEnd] == "(" {
                throw MSLTranslationError("function-like macros are not supported (#define \(name)(…))", at: location)
            }
            var lexer = MSLLexer(String(body[nameEnd...]))
            var replacement = try lexer.tokenize()
            replacement.removeLast()  // .end
            macros[name] = replacement.map { MSLToken(kind: $0.kind, location: location) }
            expandMacros()
        case "undef":
            if parts.count > 1 { macros[String(parts[1]).trimmingSpaces()] = nil }
        default:
            throw MSLTranslationError("#\(directive) is not supported", at: location)
        }
    }

    /// Replaces the identifiers that name a macro, in the tokens still to
    /// read.
    private mutating func expandMacros() {
        var expanded: [MSLToken] = Array(tokens[..<position])
        for token in tokens[position...] {
            if let name = token.identifier, let replacement = macros[name] {
                expanded.append(contentsOf: replacement)
            } else {
                expanded.append(token)
            }
        }
        tokens = expanded
    }

    private mutating func parseStructBody() throws -> [MSLStructField] {
        try expect("{")
        var fields: [MSLStructField] = []
        while !accept("}") {
            let location = current.location
            let type = try parseType()
            repeat {
                let name = try expectIdentifier()
                var arraySize: MSLExpr?
                if !isAttributeStart, accept("[") {
                    arraySize = try parseExpression()
                    try expect("]")
                }
                let attributes = try parseAttributes()
                fields.append(MSLStructField(type: type, name: name, arraySize: arraySize, attributes: attributes, location: location))
            } while accept(",")
            try expect(";")
        }
        return fields
    }

    private mutating func parseFunctionOrGlobal() throws {
        let location = current.location
        var stage: MSLStage?
        var isConstexpr = false
        // Leading qualifiers in any order.
        while let name = current.identifier {
            if let s = MSLStage(rawValue: name), stage == nil, !peek().isPunctuation("(") {
                stage = s
                advance()
            } else if ["static", "inline", "__attribute__", "INLINE", "METAL_FUNC"].contains(name) {
                advance()
            } else if name == "constexpr" {
                isConstexpr = true
                advance()
            } else {
                break
            }
        }
        var leadingAttributes = try parseAttributes()
        let type = try parseType()
        leadingAttributes += try parseAttributes()
        let name = try expectIdentifier()
        if current.isPunctuation("(") && !(isConstexpr && type.name == "sampler") && !isGlobalConstructor(type) {
            advance()
            var parameters: [MSLParameter] = []
            if !accept(")") {
                repeat {
                    parameters.append(try parseParameter())
                } while accept(",")
                try expect(")")
            }
            let attributes = leadingAttributes + (try parseAttributes())
            if accept(";") { return }  // prototype
            let body = try parseBlock()
            unit.functions.append(MSLFunction(
                stage: stage, returnType: type, name: name, parameters: parameters, body: body,
                attributes: attributes, location: location))
            return
        }
        // A global: `constant float k = 1;`, `constant float2 p[] = {…};`,
        // `constexpr sampler s(…);`.
        var declarations = [try finishDeclarator(type: type, name: name, location: location, isConstexpr: isConstexpr)]
        while accept(",") {
            let next = try expectIdentifier()
            declarations.append(try finishDeclarator(type: type, name: next, location: location, isConstexpr: isConstexpr))
        }
        try expect(";")
        unit.globals.append(contentsOf: declarations)
    }

    private func isGlobalConstructor(_ type: MSLTypeSpec) -> Bool {
        type.addressSpace == "constant" && type.name == "sampler"
    }

    private mutating func parseParameter() throws -> MSLParameter {
        let location = current.location
        var type = try parseType()
        var isReference = false
        var isPointer = false
        while true {
            if accept("&") {
                isReference = true
            } else if accept("*") {
                isPointer = true
            } else if current.isIdentifier("const") {
                advance()
                type.isConst = true
            } else {
                break
            }
        }
        let name = try expectIdentifier()
        var arraySize: MSLExpr?
        if !isAttributeStart, accept("[") {
            arraySize = try parseExpression()
            try expect("]")
        }
        let attributes = try parseAttributes()
        return MSLParameter(type: type, isReference: isReference, isPointer: isPointer, name: name,
                            arraySize: arraySize, attributes: attributes, location: location)
    }

    private var isAttributeStart: Bool {
        current.isPunctuation("[") && peek().isPunctuation("[")
    }

    /// `[[a, b(1)]] [[c]]`, as many as there are.
    private mutating func parseAttributes() throws -> [MSLAttribute] {
        var attributes: [MSLAttribute] = []
        while current.isPunctuation("[") && peek().isPunctuation("[") {
            advance()
            advance()
            repeat {
                var name = try expectIdentifier()
                while accept("::") { name = try expectIdentifier() }
                var arguments: [String] = []
                if accept("(") {
                    var depth = 0
                    var argument = ""
                    while !(depth == 0 && current.isPunctuation(")")) {
                        let token = advance()
                        switch token.kind {
                        case .punctuation("("): depth += 1; argument += "("
                        case .punctuation(")"): depth -= 1; argument += ")"
                        case .punctuation(","): if depth == 0 { arguments.append(argument); argument = "" } else { argument += "," }
                        case .punctuation(let p): argument += p
                        case .identifier(let n): argument += n
                        case .integer(let t), .float(let t): argument += t
                        default: throw MSLTranslationError("unexpected token in an attribute", at: token.location)
                        }
                    }
                    advance()
                    if !argument.isEmpty { arguments.append(argument) }
                }
                attributes.append(MSLAttribute(name: name, arguments: arguments))
            } while accept(",")
            try expect("]")
            try expect("]")
        }
        return attributes
    }

    // MARK: Types

    private func isTypeStart(_ token: MSLToken, _ next: MSLToken) -> Bool {
        guard let name = token.identifier else { return false }
        if ["const", "constant", "device", "thread", "threadgroup", "volatile", "constexpr", "static"].contains(name) {
            return true
        }
        if name == "metal" && next.isPunctuation("::") { return true }
        return MSLParser.isBuiltinType(name) || unit.typeAliases[name] != nil
            || unit.structs.contains { $0.name == name }
    }

    private mutating func parseType() throws -> MSLTypeSpec {
        var isConst = false
        var addressSpace: String?
        while let name = current.identifier {
            if name == "const" {
                isConst = true
                advance()
            } else if ["constant", "device", "thread", "threadgroup"].contains(name) {
                addressSpace = name
                advance()
            } else if ["volatile", "static", "struct"].contains(name) {
                advance()
            } else {
                break
            }
        }
        var name = try expectIdentifier()
        while accept("::") {
            // metal::float4, metal::texture2d…
            name = try expectIdentifier()
        }
        var templateArguments: [String] = []
        if MSLParser.templateTypes.contains(name), accept("<") {
            var depth = 0
            var argument = ""
            while !(depth == 0 && current.isPunctuation(">")) {
                let token = advance()
                switch token.kind {
                case .punctuation("<"): depth += 1; argument += "<"
                case .punctuation(">"): depth -= 1; argument += ">"
                case .punctuation(","): if depth == 0 { templateArguments.append(argument); argument = "" } else { argument += "," }
                case .punctuation("::"): argument += "::"
                case .punctuation(let p): argument += p
                case .identifier(let n): argument += n
                case .integer(let t), .float(let t): argument += t
                default: throw MSLTranslationError("unexpected token in template arguments", at: token.location)
                }
            }
            advance()
            templateArguments.append(argument)
        }
        if current.isIdentifier("const") {
            isConst = true
            advance()
        }
        if let alias = unit.typeAliases[name] {
            var resolved = alias
            resolved.isConst = resolved.isConst || isConst
            resolved.addressSpace = addressSpace ?? resolved.addressSpace
            return resolved
        }
        return MSLTypeSpec(name: name, templateArguments: templateArguments, isConst: isConst, addressSpace: addressSpace)
    }

    // MARK: Statements

    private mutating func parseBlock() throws -> [MSLStmt] {
        try expect("{")
        var statements: [MSLStmt] = []
        while !accept("}") {
            statements.append(try parseStatement())
        }
        return statements
    }

    private mutating func parseStatement() throws -> MSLStmt {
        let location = current.location
        if current.isPunctuation("{") { return .block(try parseBlock()) }
        if accept(";") { return .empty }
        if acceptIdentifier("return") {
            if accept(";") { return .returnStmt(nil, location) }
            let value = try parseExpression()
            try expect(";")
            return .returnStmt(value, location)
        }
        if acceptIdentifier("break") {
            try expect(";")
            return .breakStmt
        }
        if acceptIdentifier("continue") {
            try expect(";")
            return .continueStmt
        }
        if acceptIdentifier("discard_fragment") {
            try expect("(")
            try expect(")")
            try expect(";")
            return .discard
        }
        if acceptIdentifier("if") {
            try expect("(")
            let condition = try parseExpression()
            try expect(")")
            let then = try parseStatement()
            var otherwise: MSLStmt?
            if acceptIdentifier("else") { otherwise = try parseStatement() }
            return .ifStmt(condition, then, otherwise)
        }
        if acceptIdentifier("for") {
            try expect("(")
            var initializer: MSLStmt?
            if !accept(";") {
                if isTypeStart(current, peek()) {
                    initializer = .declaration(try parseDeclarations())
                } else {
                    initializer = .expression(try parseExpression())
                    try expect(";")
                }
            }
            var condition: MSLExpr?
            if !current.isPunctuation(";") { condition = try parseExpression() }
            try expect(";")
            var step: MSLExpr?
            if !current.isPunctuation(")") { step = try parseExpression() }
            try expect(")")
            let body = try parseStatement()
            return .forStmt(initializer, condition, step, body)
        }
        if acceptIdentifier("while") {
            try expect("(")
            let condition = try parseExpression()
            try expect(")")
            return .whileStmt(condition, try parseStatement())
        }
        if acceptIdentifier("do") {
            let body = try parseStatement()
            guard acceptIdentifier("while") else {
                throw MSLTranslationError("expected 'while' after a do loop's body", at: current.location)
            }
            try expect("(")
            let condition = try parseExpression()
            try expect(")")
            try expect(";")
            return .doWhile(body, condition)
        }
        if acceptIdentifier("switch") {
            try expect("(")
            let selector = try parseExpression()
            try expect(")")
            try expect("{")
            var cases: [MSLSwitchCase] = []
            while !accept("}") {
                var values: [MSLExpr]? = []
                if acceptIdentifier("default") {
                    values = nil
                } else if acceptIdentifier("case") {
                    values = [try parseExpression()]
                } else {
                    throw MSLTranslationError("expected 'case' or 'default'", at: current.location)
                }
                try expect(":")
                var body: [MSLStmt] = []
                while !current.isIdentifier("case") && !current.isIdentifier("default") && !current.isPunctuation("}") {
                    body.append(try parseStatement())
                }
                cases.append(MSLSwitchCase(values: values, body: body))
            }
            return .switchStmt(selector, cases)
        }
        if isDeclarationStart() {
            return .declaration(try parseDeclarations())
        }
        let expression = try parseExpression()
        try expect(";")
        return .expression(expression)
    }

    /// A statement that declares: a type (known, or a name followed by a
    /// name) and then a name.
    private func isDeclarationStart() -> Bool {
        guard let name = current.identifier else { return false }
        if ["const", "constexpr", "thread", "threadgroup", "static", "constant", "device"].contains(name) {
            return true
        }
        if isTypeStart(current, peek()) {
            // `float4(…)` is an expression; `float4 x` is a declaration.
            if peek().isPunctuation("(") || peek().isPunctuation("{") || peek().isPunctuation(".") { return false }
            return true
        }
        return peek().identifier != nil
    }

    private mutating func parseDeclarations() throws -> [MSLVarDecl] {
        let location = current.location
        var isConstexpr = false
        if acceptIdentifier("constexpr") { isConstexpr = true }
        let type = try parseType()
        var declarations: [MSLVarDecl] = []
        repeat {
            let isReference = accept("&")
            if current.isPunctuation("*") {
                throw MSLTranslationError("pointer variables are not supported; use a reference (T &x = …) or an index", at: current.location)
            }
            let name = try expectIdentifier()
            var declaration = try finishDeclarator(type: type, name: name, location: location, isConstexpr: isConstexpr)
            declaration.isReference = isReference
            declarations.append(declaration)
        } while accept(",")
        try expect(";")
        return declarations
    }

    private mutating func finishDeclarator(
        type: MSLTypeSpec, name: String, location: MSLSourceLocation, isConstexpr: Bool
    ) throws -> MSLVarDecl {
        var declaration = MSLVarDecl(type: type, name: name, location: location)
        declaration.isConstexpr = isConstexpr
        if !isAttributeStart, accept("[") {
            if accept("]") {
                declaration.arrayUnsized = true
            } else {
                declaration.arraySize = try parseExpression()
                try expect("]")
            }
        }
        _ = try parseAttributes()
        if accept("=") {
            declaration.initializer = try parseInitializer()
        } else if current.isPunctuation("{") {
            declaration.initializer = try parseInitializer()
        } else if accept("(") {
            var arguments: [MSLExpr] = []
            if !accept(")") {
                repeat { arguments.append(try parseAssignment()) } while accept(",")
                try expect(")")
            }
            if type.name == "sampler" {
                declaration.constructorArguments = arguments
            } else {
                declaration.initializer = MSLExpr(kind: .construct(type, arguments, braces: false), location: location)
            }
        }
        return declaration
    }

    private mutating func parseInitializer() throws -> MSLExpr {
        if current.isPunctuation("{") {
            let location = current.location
            advance()
            var elements: [MSLExpr] = []
            if !accept("}") {
                repeat {
                    if current.isPunctuation("}") { break }
                    elements.append(try parseInitializer())
                } while accept(",")
                try expect("}")
            }
            return MSLExpr(kind: .initializerList(elements), location: location)
        }
        return try parseAssignment()
    }

    // MARK: Expressions

    mutating func parseExpression() throws -> MSLExpr {
        var expression = try parseAssignment()
        while current.isPunctuation(",") {
            // The comma operator: kept only where a for loop's step uses it.
            let location = current.location
            advance()
            let next = try parseAssignment()
            expression = MSLExpr(kind: .binary(",", expression, next), location: location)
        }
        return expression
    }

    private static let assignmentOperators: Set<String> = ["=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="]

    private mutating func parseAssignment() throws -> MSLExpr {
        let left = try parseTernary()
        if case .punctuation(let p) = current.kind, MSLParser.assignmentOperators.contains(p) {
            let location = current.location
            advance()
            let right = try parseAssignment()
            return MSLExpr(kind: .assign(p, left, right), location: location)
        }
        return left
    }

    private mutating func parseTernary() throws -> MSLExpr {
        let condition = try parseBinary(0)
        if current.isPunctuation("?") {
            let location = current.location
            advance()
            let a = try parseAssignment()
            try expect(":")
            let b = try parseAssignment()
            return MSLExpr(kind: .ternary(condition, a, b), location: location)
        }
        return condition
    }

    private static let precedence: [[String]] = [
        ["||"], ["&&"], ["|"], ["^"], ["&"], ["==", "!="], ["<", ">", "<=", ">="], ["<<", ">>"],
        ["+", "-"], ["*", "/", "%"],
    ]

    private mutating func parseBinary(_ level: Int) throws -> MSLExpr {
        if level == MSLParser.precedence.count { return try parseUnary() }
        var left = try parseBinary(level + 1)
        while case .punctuation(let p) = current.kind, MSLParser.precedence[level].contains(p) {
            let location = current.location
            advance()
            let right = try parseBinary(level + 1)
            left = MSLExpr(kind: .binary(p, left, right), location: location)
        }
        return left
    }

    private mutating func parseUnary() throws -> MSLExpr {
        let location = current.location
        if case .punctuation(let p) = current.kind, ["-", "+", "!", "~", "++", "--", "*", "&"].contains(p) {
            advance()
            let operand = try parseUnary()
            return MSLExpr(kind: .unary(p, operand), location: location)
        }
        // A C cast: `(float)x`.
        if current.isPunctuation("("), isTypeStart(peek(), peek(2)),
           peek(2).isPunctuation(")") || peek(2).isPunctuation("<") || peek(2).isPunctuation("::") {
            let saved = position
            advance()
            if let type = try? parseType(), accept(")") {
                let operand = try parseUnary()
                return MSLExpr(kind: .construct(type, [operand], braces: false), location: location)
            }
            position = saved
        }
        return try parsePostfix()
    }

    private mutating func parsePostfix() throws -> MSLExpr {
        var expression = try parsePrimary()
        while true {
            let location = current.location
            if accept("(") {
                var arguments: [MSLExpr] = []
                if !accept(")") {
                    repeat { arguments.append(try parseAssignment()) } while accept(",")
                    try expect(")")
                }
                expression = MSLExpr(kind: .call(expression, arguments), location: location)
            } else if current.isPunctuation("[") && !peek().isPunctuation("[") {
                advance()
                let index = try parseExpression()
                try expect("]")
                expression = MSLExpr(kind: .index(expression, index), location: location)
            } else if accept(".") || accept("->") {
                let name = try expectIdentifier()
                expression = MSLExpr(kind: .member(expression, name), location: location)
            } else if current.isPunctuation("++") || current.isPunctuation("--") {
                let op = advance()
                if case .punctuation(let p) = op.kind {
                    expression = MSLExpr(kind: .postfix(p, expression), location: location)
                }
            } else {
                return expression
            }
        }
    }

    private mutating func parsePrimary() throws -> MSLExpr {
        let token = current
        let location = token.location
        switch token.kind {
        case .integer(let text):
            advance()
            return MSLExpr(kind: .integer(text), location: location)
        case .float(let text):
            advance()
            return MSLExpr(kind: .float(text), location: location)
        case .punctuation("("):
            advance()
            let expression = try parseExpression()
            try expect(")")
            return expression
        case .punctuation("{"):
            return try parseInitializer()
        case .identifier(let name):
            if name == "true" || name == "false" {
                advance()
                return MSLExpr(kind: .bool(name == "true"), location: location)
            }
            if ["as_type", "static_cast", "reinterpret_cast", "const_cast"].contains(name), peek().isPunctuation("<") {
                advance()
                advance()
                let type = try parseType()
                try expect(">")
                try expect("(")
                var arguments: [MSLExpr] = []
                if !accept(")") {
                    repeat { arguments.append(try parseAssignment()) } while accept(",")
                    try expect(")")
                }
                return MSLExpr(kind: .templateCall(name, [type], arguments), location: location)
            }
            if isTypeStart(token, peek()) && !["const", "constant", "device", "thread", "threadgroup", "static", "constexpr"].contains(name) {
                // A constructor: `float4(…)`, `Foo{…}`, `metal::float2(…)`.
                let saved = position
                let type = try parseType()
                if current.isPunctuation("(") || current.isPunctuation("{") {
                    let braces = current.isPunctuation("{")
                    advance()
                    var arguments: [MSLExpr] = []
                    let close = braces ? "}" : ")"
                    if !accept(close) {
                        repeat {
                            if current.isPunctuation(close) { break }
                            arguments.append(braces ? try parseInitializer() : try parseAssignment())
                        } while accept(",")
                        try expect(close)
                    }
                    return MSLExpr(kind: .construct(type, arguments, braces: braces), location: location)
                }
                position = saved
            }
            advance()
            if current.isPunctuation("::") {
                var parts = [name]
                while accept("::") { parts.append(try expectIdentifier()) }
                if parts.first == "metal" && parts.count == 2 {
                    return MSLExpr(kind: .identifier(parts[1]), location: location)
                }
                return MSLExpr(kind: .qualified(parts), location: location)
            }
            return MSLExpr(kind: .identifier(name), location: location)
        default:
            throw MSLTranslationError("expected an expression, found \(describe(token))", at: location)
        }
    }
}

extension MSLToken {
    var isEnd: Bool {
        if case .end = kind { return true }
        return false
    }
}

extension String {
    func trimmingSpaces() -> String {
        var s = Substring(self)
        while s.first == " " || s.first == "\t" { s.removeFirst() }
        while s.last == " " || s.last == "\t" { s.removeLast() }
        return String(s)
    }
}
