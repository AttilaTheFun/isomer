// The proof's pictures compared with its baseline's, and the `proof`
// artifact Reviews reads made of them (tools/ci/proof.sh builds this file
// with swiftc on the runner):
//
//   proof_compare <pictures> <baseline> <proof> --commit <sha> --ref <ref> --kind quick|full
//       [--run <id>] [--base-ref <ref>] [--base-commit <sha>]
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
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Pixels {
    var bytes: [UInt8]
    let width: Int
    let height: Int

    /// The picture's RGBA, premultiplied, in a canvas of the given size, from
    /// its top left; nil draws nothing (all clear).
    init(_ image: CGImage?, width: Int, height: Int) {
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let image else { return }
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // Core Graphics counts from the bottom: the top left is height - image.height up.
            context.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
        }
    }
}

func load(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("proof_compare: \(message)\n".utf8))
    exit(1)
}

/// How many pixels changed from `kept` (nil: the base had no picture) to
/// `new`, and the diff picture when any did.
func compare(_ kept: CGImage?, _ new: CGImage) -> (changed: Int, diff: CGImage?) {
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
                    for channel in 0..<4 where abs(Int(a[index + channel]) - Int(b[index + channel])) > 24 {
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
    let picture: CGImage? = diff.withUnsafeMutableBytes { buffer in
        CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }
    return (changed, picture)
}

func write(_ image: CGImage, to path: String) {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        fail("can't make \(path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination), data.write(toFile: path, atomically: true) else { fail("can't write \(path)") }
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
    let (changed, diff) = compare(keptImage, new)
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
