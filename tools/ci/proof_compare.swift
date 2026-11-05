// The proof's pictures compared with its baseline's, and the `proof`
// artifact Reviews reads made of them (tools/ci/proof.sh builds this file
// with swiftc on the runner):
//
//   proof_compare <pictures> <baseline> <proof> --commit <sha> --ref <ref> --kind quick|full
//       [--run <id>] [--base-ref <ref>] [--base-commit <sha>] [--ignore <file>]
//
// <pictures> holds this commit's pictures, <name>.png; <baseline> the
// base's (its proof's screens/), or "-" when there is none. Into <proof>:
//
//   screens/<name>.png  every picture
//   before/<name>.png   the base's picture of each that changed, where it had one
//   diffs/<name>.png    each that changed: the new picture faded to grey,
//                       each changed pixel red
//   proof.json          {"commit", "ref", "kind", "run", "base": {"ref", "commit"},
//                        "screens": [{"name", "changed", "changedPixels"}]}
//
// A pixel changed when a channel moved by more than 24, as reviews'
// tools/ci/snapshot_diff.swift counts them, so text drawn a hair
// differently counts for nothing. Pictures of different sizes are laid
// over each other from the top left, and a pixel only one of them covers
// changed; a screen the base had no picture of changed everywhere. A
// Markdown table of the screens that changed goes to stdout (the job's
// summary).
//
// --ignore names regions whose pixels never count, one a line: `<screen>
// <x> <y> <width> <height>`, in the picture's pixels, then why after a #.
// Only for what the platform draws differently from run to run however
// the proof holds it (tools/ci/proof_ignore.txt says what and why); the
// region still shows, before and after.
//
// PNGs are read and written here, not by Core Graphics, so that it builds
// with any Swift (the proof runs in a Linux container): 8- and 16-bit,
// every colour type, not interlaced. Pictures are compared as stored, with
// no colour management: both sides come from the same kind of screenshot.
import Foundation

struct Pixels {
    var bytes: [UInt8]
    let width: Int
    let height: Int

    /// The picture's RGBA in a canvas of the given size, from its top left;
    /// nil draws nothing (all clear).
    init(_ image: Picture?, width: Int, height: Int) {
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let image else { return }
        for row in 0..<image.height {
            let from = row * image.width * 4
            let to = row * width * 4
            bytes.replaceSubrange(to..<to + image.width * 4, with: image.rgba[from..<from + image.width * 4])
        }
    }
}

struct Picture {
    let width: Int
    let height: Int
    var rgba: [UInt8]
}

struct Region {
    let x, y, width, height: Int

    func contains(_ px: Int, _ py: Int) -> Bool { px >= x && px < x + width && py >= y && py < y + height }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("proof_compare: \(message)\n".utf8))
    exit(1)
}

// --- Deflate: zlib's inflate (RFC 1950/1951), and a writer of fixed-code blocks.

struct Huffman {
    var counts = [Int](repeating: 0, count: 16)
    var symbols: [Int]

    init(_ lengths: [Int]) {
        for length in lengths { counts[length] += 1 }
        counts[0] = 0
        var offsets = [Int](repeating: 0, count: 16)
        for length in 1..<15 { offsets[length + 1] = offsets[length] + counts[length] }
        symbols = [Int](repeating: 0, count: lengths.count)
        for (symbol, length) in lengths.enumerated() where length != 0 {
            symbols[offsets[length]] = symbol
            offsets[length] += 1
        }
    }
}

let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                    4097, 6145, 8193, 12289, 16385, 24577]
let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

func inflate(_ input: [UInt8]) -> [UInt8]? {
    guard input.count > 2 else { return nil }
    var output: [UInt8] = []
    output.reserveCapacity(input.count * 4)
    var position = 2   // zlib's header
    var buffer = 0
    var count = 0
    func bits(_ needed: Int) -> Int? {
        while count < needed {
            guard position < input.count else { return nil }
            buffer |= Int(input[position]) << count
            position += 1
            count += 8
        }
        let value = buffer & ((1 << needed) - 1)
        buffer >>= needed
        count -= needed
        return value
    }
    func decode(_ code: Huffman) -> Int? {
        var value = 0, first = 0, index = 0
        for length in 1..<16 {
            guard let bit = bits(1) else { return nil }
            value |= bit
            let entries = code.counts[length]
            if value - entries < first { return code.symbols[index + value - first] }
            index += entries
            first = (first + entries) << 1
            value <<= 1
        }
        return nil
    }
    func codes(_ literals: Huffman, _ distances: Huffman) -> Bool {
        while true {
            guard let symbol = decode(literals) else { return false }
            if symbol < 256 {
                output.append(UInt8(symbol))
            } else if symbol == 256 {
                return true
            } else {
                let lengthIndex = symbol - 257
                guard lengthIndex < 29, let extra = bits(lengthExtra[lengthIndex]),
                      let distanceSymbol = decode(distances), distanceSymbol < 30,
                      let distanceBits = bits(distanceExtra[distanceSymbol]) else { return false }
                let length = lengthBase[lengthIndex] + extra
                let distance = distanceBase[distanceSymbol] + distanceBits
                guard distance <= output.count else { return false }
                let start = output.count - distance
                for offset in 0..<length { output.append(output[start + offset]) }
            }
        }
    }
    let fixedLiterals = Huffman([Int](repeating: 8, count: 144) + [Int](repeating: 9, count: 112)
                                + [Int](repeating: 7, count: 24) + [Int](repeating: 8, count: 8))
    let fixedDistances = Huffman([Int](repeating: 5, count: 30))
    var last = 0
    repeat {
        guard let final = bits(1), let type = bits(2) else { return nil }
        last = final
        switch type {
        case 0:
            buffer = 0
            count = 0
            guard position + 4 <= input.count else { return nil }
            let length = Int(input[position]) | Int(input[position + 1]) << 8
            position += 4
            guard position + length <= input.count else { return nil }
            output.append(contentsOf: input[position..<position + length])
            position += length
        case 1:
            guard codes(fixedLiterals, fixedDistances) else { return nil }
        case 2:
            guard let literalCount = bits(5).map({ $0 + 257 }), let distanceCount = bits(5).map({ $0 + 1 }),
                  let lengthCount = bits(4).map({ $0 + 4 }) else { return nil }
            var lengthLengths = [Int](repeating: 0, count: 19)
            for index in 0..<lengthCount {
                guard let length = bits(3) else { return nil }
                lengthLengths[[16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15][index]] = length
            }
            let lengthCode = Huffman(lengthLengths)
            var lengths: [Int] = []
            while lengths.count < literalCount + distanceCount {
                guard let symbol = decode(lengthCode) else { return nil }
                switch symbol {
                case 0..<16: lengths.append(symbol)
                case 16:
                    guard let previous = lengths.last, let repeats = bits(2) else { return nil }
                    lengths += [Int](repeating: previous, count: 3 + repeats)
                case 17:
                    guard let repeats = bits(3) else { return nil }
                    lengths += [Int](repeating: 0, count: 3 + repeats)
                default:
                    guard let repeats = bits(7) else { return nil }
                    lengths += [Int](repeating: 0, count: 11 + repeats)
                }
            }
            guard codes(Huffman(Array(lengths[0..<literalCount])),
                        Huffman(Array(lengths[literalCount..<literalCount + distanceCount]))) else { return nil }
        default:
            return nil
        }
    } while last == 0
    return output
}

/// zlib data of fixed-code blocks: literals, and runs of one byte as
/// matches one back (the rows are Sub-filtered, so flat colour is zeros).
func deflate(_ input: [UInt8]) -> [UInt8] {
    var output: [UInt8] = [0x78, 0x01]
    var buffer = 0
    var count = 0
    func put(_ value: Int, _ length: Int) {
        buffer |= value << count
        count += length
        while count >= 8 {
            output.append(UInt8(buffer & 0xff))
            buffer >>= 8
            count -= 8
        }
    }
    func code(_ value: Int, _ length: Int) {   // Huffman codes go most significant bit first
        var reversed = 0
        for bit in 0..<length where value & (1 << bit) != 0 { reversed |= 1 << (length - 1 - bit) }
        put(reversed, length)
    }
    func literal(_ symbol: Int) {
        switch symbol {
        case 0..<144: code(0x30 + symbol, 8)
        case 144..<256: code(0x190 + symbol - 144, 9)
        case 256..<280: code(symbol - 256, 7)
        default: code(0xc0 + symbol - 280, 8)
        }
    }
    put(1, 1)   // the only block
    put(1, 2)   // fixed codes
    var index = 0
    while index < input.count {
        var run = 0
        if index > 0 {
            while run < 258, index + run < input.count, input[index + run] == input[index - 1] { run += 1 }
        }
        if run >= 3 {
            let lengthIndex = lengthBase.lastIndex { $0 <= run }!
            literal(257 + lengthIndex)
            put(run - lengthBase[lengthIndex], lengthExtra[lengthIndex])
            code(0, 5)   // distance 1
            index += run
        } else {
            literal(Int(input[index]))
            index += 1
        }
    }
    literal(256)
    if count > 0 { put(0, 8 - count) }
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in input {
        a = (a + UInt32(byte)) % 65521
        b = (b + a) % 65521
    }
    let adler = b << 16 | a
    output += [UInt8(adler >> 24), UInt8(adler >> 16 & 0xff), UInt8(adler >> 8 & 0xff), UInt8(adler & 0xff)]
    return output
}

// --- PNG

let crcTable: [UInt32] = (0..<256).map { n in
    var c = UInt32(n)
    for _ in 0..<8 { c = c & 1 != 0 ? 0xedb8_8320 ^ (c >> 1) : c >> 1 }
    return c
}

func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
    return crc ^ 0xffff_ffff
}

func load(_ path: String) -> Picture? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    let bytes = [UInt8](data)
    guard bytes.count > 8, bytes[0..<8] == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] else { return nil }
    func u32(_ at: Int) -> Int { Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3]) }
    var width = 0, height = 0, depth = 0, colour = 0
    var palette: [UInt8] = [], transparency: [UInt8] = [], compressed: [UInt8] = []
    var position = 8
    while position + 8 <= bytes.count {
        let length = u32(position)
        let type = String(decoding: bytes[position + 4..<position + 8], as: UTF8.self)
        let body = position + 8
        guard body + length <= bytes.count else { return nil }
        switch type {
        case "IHDR":
            width = u32(body); height = u32(body + 4); depth = Int(bytes[body + 8]); colour = Int(bytes[body + 9])
            guard bytes[body + 12] == 0 else { return nil }   // interlaced
        case "PLTE": palette = Array(bytes[body..<body + length])
        case "tRNS": transparency = Array(bytes[body..<body + length])
        case "IDAT": compressed += bytes[body..<body + length]
        default: break
        }
        if type == "IEND" { break }
        position = body + length + 4
    }
    let channels = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][colour] ?? 0
    guard width > 0, height > 0, channels > 0, [1, 2, 4, 8, 16].contains(depth), var raw = inflate(compressed) else { return nil }
    let rowBytes = (width * channels * depth + 7) / 8
    let step = max(1, channels * depth / 8)
    guard raw.count >= (rowBytes + 1) * height else { return nil }
    // Unfilter in place, row by row.
    for row in 0..<height {
        let start = row * (rowBytes + 1) + 1
        let filter = raw[start - 1]
        for index in 0..<rowBytes {
            let left = index >= step ? Int(raw[start + index - step]) : 0
            let up = row > 0 ? Int(raw[start + index - rowBytes - 1]) : 0
            let corner = row > 0 && index >= step ? Int(raw[start + index - step - rowBytes - 1]) : 0
            let predicted: Int
            switch filter {
            case 1: predicted = left
            case 2: predicted = up
            case 3: predicted = (left + up) / 2
            case 4:
                let p = left + up - corner
                let (pa, pb, pc) = (abs(p - left), abs(p - up), abs(p - corner))
                predicted = pa <= pb && pa <= pc ? left : pb <= pc ? up : corner
            default: predicted = 0
            }
            raw[start + index] = UInt8((Int(raw[start + index]) + predicted) & 0xff)
        }
    }
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    let maximum = (1 << depth) - 1
    for row in 0..<height {
        let start = row * (rowBytes + 1) + 1
        for column in 0..<width {
            // Each sample as 8 bits: 16-bit ones by their high byte, small ones scaled.
            func sample(_ channel: Int) -> Int {
                if depth == 16 { return Int(raw[start + (column * channels + channel) * 2]) }
                if depth == 8 { return Int(raw[start + column * channels + channel]) }
                let bit = (column * channels + channel) * depth
                return Int(raw[start + bit / 8]) >> (8 - depth - bit % 8) & maximum
            }
            let out = (row * width + column) * 4
            switch colour {
            case 0, 4:
                let grey = UInt8(depth < 8 ? sample(0) * 255 / maximum : sample(0))
                rgba[out] = grey; rgba[out + 1] = grey; rgba[out + 2] = grey
                if colour == 4 { rgba[out + 3] = UInt8(sample(1)) }
            case 3:
                let entry = sample(0)
                guard entry * 3 + 2 < palette.count else { return nil }
                rgba[out] = palette[entry * 3]; rgba[out + 1] = palette[entry * 3 + 1]; rgba[out + 2] = palette[entry * 3 + 2]
                if entry < transparency.count { rgba[out + 3] = transparency[entry] }
            default:
                rgba[out] = UInt8(sample(0)); rgba[out + 1] = UInt8(sample(1)); rgba[out + 2] = UInt8(sample(2))
                if colour == 6 { rgba[out + 3] = UInt8(sample(3)) }
            }
        }
    }
    return Picture(width: width, height: height, rgba: rgba)
}

func write(_ picture: Picture, to path: String) {
    // Each row Sub-filtered: a flat run of colour becomes zeros, which deflate() runs.
    let rowBytes = picture.width * 4
    var raw = [UInt8](repeating: 0, count: (rowBytes + 1) * picture.height)
    for row in 0..<picture.height {
        let start = row * (rowBytes + 1)
        raw[start] = 1
        for index in 0..<rowBytes {
            let value = picture.rgba[row * rowBytes + index]
            let left = index >= 4 ? picture.rgba[row * rowBytes + index - 4] : 0
            raw[start + 1 + index] = value &- left
        }
    }
    func big(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)] }
    var file: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
    func chunk(_ type: String, _ body: [UInt8]) {
        let typed = Array(type.utf8) + body
        file += big(body.count) + typed + big(Int(crc32(typed[...])))
    }
    chunk("IHDR", big(picture.width) + big(picture.height) + [8, 6, 0, 0, 0])
    chunk("IDAT", deflate(raw))
    chunk("IEND", [])
    guard FileManager.default.createFile(atPath: path, contents: Data(file)) else { fail("can't write \(path)") }
}

/// How many pixels changed from `kept` (nil: the base had no picture) to
/// `new`, not counting those in `ignored`, and the diff picture when any did.
func compare(_ kept: Picture?, _ new: Picture, ignoring ignored: [Region] = []) -> (changed: Int, diff: Picture?) {
    let width = max(new.width, kept?.width ?? 0)
    let height = max(new.height, kept?.height ?? 0)
    let after = Pixels(new, width: width, height: height)
    let before = Pixels(kept, width: width, height: height)
    var diff = after.bytes
    var changed = 0
    after.bytes.withUnsafeBufferPointer { a in
        before.bytes.withUnsafeBufferPointer { b in
            diff.withUnsafeMutableBufferPointer { d in
                for index in stride(from: 0, to: a.count, by: 4) {
                    var differs = false
                    let pixel = index / 4
                    let (x, y) = (pixel % width, pixel / width)
                    for channel in 0..<4 where abs(Int(a[index + channel]) - Int(b[index + channel])) > 24
                        && !ignored.contains(where: { $0.contains(x, y) }) {
                        differs = true
                        break
                    }
                    if differs {
                        changed += 1
                        d[index] = 255; d[index + 1] = 0; d[index + 2] = 0; d[index + 3] = 255
                    } else {
                        // Grey, faded two thirds of the way to white: the screen's shapes, behind the red.
                        let grey = (Int(a[index]) * 3 + Int(a[index + 1]) * 6 + Int(a[index + 2])) / 10
                        let faded = UInt8(255 - (255 - grey) / 3)
                        d[index] = faded; d[index + 1] = faded; d[index + 2] = faded; d[index + 3] = 255
                    }
                }
            }
        }
    }
    guard changed > 0 else { return (0, nil) }
    return (changed, Picture(width: width, height: height, rgba: diff))
}

// What proof.json says.
struct Base: Encodable {
    let ref: String?
    let commit: String?
}

struct Screen: Encodable {
    let name: String
    let changed: Bool
    let changedPixels: Int
}

struct Proof: Encodable {
    let commit: String
    let ref: String
    let kind: String
    let run: Int?
    let base: Base
    let screens: [Screen]
}

var positional: [String] = []
var options: [String: String] = [:]
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    if argument.hasPrefix("--") {
        guard let value = arguments.popFirst() else { fail("\(argument) takes a value") }
        options[String(argument.dropFirst(2))] = value
    } else {
        positional.append(argument)
    }
}
guard positional.count == 3, let commit = options["commit"], let ref = options["ref"],
      let kind = options["kind"], kind == "quick" || kind == "full" else {
    fail("usage: proof_compare <pictures> <baseline|-> <proof> --commit <sha> --ref <ref> --kind quick|full "
         + "[--run <id>] [--base-ref <ref>] [--base-commit <sha>]")
}
let (pictures, baseline, proof) = (positional[0], positional[1] == "-" ? nil : positional[1], positional[2])
let files = FileManager.default
let names = ((try? files.contentsOfDirectory(atPath: pictures)) ?? [])
    .filter { $0.hasSuffix(".png") }.map { String($0.dropLast(4)) }.sorted()
for folder in ["screens", "before", "diffs"] {
    try? files.createDirectory(atPath: "\(proof)/\(folder)", withIntermediateDirectories: true)
}

// The regions that never count, by screen.
var ignored: [String: [Region]] = [:]
if let path = options["ignore"] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("can't read \(path)") }
    for line in text.split(separator: "\n") {
        let fields = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first?.split(separator: " ") ?? []
        guard !fields.isEmpty else { continue }
        let numbers = fields.dropFirst().compactMap { Int($0) }
        guard numbers.count == 4 else { fail("\(path): \(line): <screen> <x> <y> <width> <height>") }
        ignored[String(fields[0]), default: []].append(Region(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]))
    }
}

var screens: [Screen] = []
for name in names {
    let picture = "\(pictures)/\(name).png"
    let kept = baseline.map { "\($0)/\(name).png" }.flatMap { files.fileExists(atPath: $0) ? $0 : nil }
    try? files.removeItem(atPath: "\(proof)/screens/\(name).png")
    do { try files.copyItem(atPath: picture, toPath: "\(proof)/screens/\(name).png") } catch { fail("can't copy \(picture): \(error)") }
    // The same bytes: nothing changed, nothing to decode.
    if let kept, let a = files.contents(atPath: kept), let b = files.contents(atPath: picture), a == b {
        screens.append(Screen(name: name, changed: false, changedPixels: 0))
        continue
    }
    guard let new = load(picture) else { fail("can't read \(picture)") }
    let keptImage = kept.flatMap(load)
    if kept != nil, keptImage == nil { fail("can't read \(kept!)") }
    let (changed, diff) = compare(keptImage, new, ignoring: kept == nil ? [] : ignored[name] ?? [])
    if let diff {
        write(diff, to: "\(proof)/diffs/\(name).png")
        if let kept { try? files.copyItem(atPath: kept, toPath: "\(proof)/before/\(name).png") }
    }
    screens.append(Screen(name: name, changed: changed > 0 || kept == nil, changedPixels: changed))
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let document = Proof(commit: commit, ref: ref, kind: kind, run: options["run"].flatMap { Int($0) },
                     base: Base(ref: options["base-ref"], commit: options["base-commit"]), screens: screens)
do {
    try encoder.encode(document).write(to: URL(fileURLWithPath: "\(proof)/proof.json"))
} catch {
    fail("can't write proof.json: \(error)")
}

// The job's summary: how many, and which changed.
let changed = screens.filter(\.changed)
var summary = "### Proof (\(kind)) of \(commit.prefix(7))\n\n"
summary += "\(screens.count) screens against "
summary += options["base-commit"].map { "\(options["base-ref"] ?? "the base") at \($0.prefix(7))" } ?? "no baseline (every screen is new)"
summary += ": \(changed.isEmpty ? "none changed" : "\(changed.count) changed").\n"
if !changed.isEmpty {
    summary += "\n| Screen | Changed pixels |\n| --- | --- |\n"
    for screen in changed { summary += "| \(screen.name) | \(screen.changedPixels) |\n" }
}
print(summary, terminator: "")
