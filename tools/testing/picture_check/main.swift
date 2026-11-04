// picture_check: a test's picture of an app, checked for having drawn
// something and written as a PNG. Reads a binary PPM (P6: what the Linux
// host's ISO_SHOT dumps each frame) or a 32-bit BMP (what Windows' and
// Wine's hosts dump), writes the PNG (stored, uncompressed: no zlib needed
// off Apple's platforms), and fails (exit 1) when every pixel is one colour,
// as a window that never drew is.
//
//   picture_check <in.ppm | in.bmp> <out.png>
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("picture_check: \(message)\n".utf8))
    exit(1)
}

struct Picture {
    var width: Int
    var height: Int
    var rgb: [UInt8]  // width × height × 3, rows top to bottom
}

func readPPM(_ data: [UInt8]) -> Picture? {
    guard data.count > 2, data[0] == UInt8(ascii: "P"), data[1] == UInt8(ascii: "6") else { return nil }
    var index = 2
    var fields: [Int] = []
    while fields.count < 3, index < data.count {
        while index < data.count, data[index] == 32 || data[index] == 10 || data[index] == 13 || data[index] == 9 { index += 1 }
        if index < data.count, data[index] == UInt8(ascii: "#") {
            while index < data.count, data[index] != 10 { index += 1 }
            continue
        }
        var value = 0
        while index < data.count, data[index] >= 48, data[index] <= 57 {
            value = value * 10 + Int(data[index] - 48)
            index += 1
        }
        fields.append(value)
    }
    index += 1
    let (width, height) = (fields[0], fields[1])
    guard fields.count == 3, fields[2] == 255, data.count - index >= width * height * 3 else { return nil }
    return Picture(width: width, height: height, rgb: Array(data[index..<(index + width * height * 3)]))
}

func readBMP(_ data: [UInt8]) -> Picture? {
    guard data.count > 54, data[0] == UInt8(ascii: "B"), data[1] == UInt8(ascii: "M") else { return nil }
    func u32(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16 | Int(data[at + 3]) << 24 }
    let offset = u32(10)
    let width = u32(18)
    var height = Int(Int32(truncatingIfNeeded: u32(22)))
    let bits = Int(data[28]) | Int(data[29]) << 8
    guard bits == 32 || bits == 24 else { return nil }
    let topDown = height < 0
    height = abs(height)
    let stride = ((width * bits / 8) + 3) & ~3
    guard data.count >= offset + stride * height else { return nil }
    var rgb = [UInt8](repeating: 0, count: width * height * 3)
    for y in 0..<height {
        let row = offset + stride * (topDown ? y : height - 1 - y)
        for x in 0..<width {
            let pixel = row + x * bits / 8
            let out = (y * width + x) * 3
            rgb[out] = data[pixel + 2]
            rgb[out + 1] = data[pixel + 1]
            rgb[out + 2] = data[pixel]
        }
    }
    return Picture(width: width, height: height, rgb: rgb)
}

let crcTable: [UInt32] = (0..<256).map { n in
    var c = UInt32(n)
    for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    return c
}

func crc32(_ bytes: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFF_FFFF
}

func bigEndian(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

func png(_ picture: Picture) -> [UInt8] {
    // Each row a filter byte (none) and its pixels, in zlib's stored blocks.
    var raw = [UInt8]()
    raw.reserveCapacity(picture.height * (picture.width * 3 + 1))
    for y in 0..<picture.height {
        raw.append(0)
        raw += picture.rgb[(y * picture.width * 3)..<((y + 1) * picture.width * 3)]
    }
    var zlib: [UInt8] = [0x78, 0x01]
    var offset = 0
    repeat {
        let count = min(65535, raw.count - offset)
        let last: UInt8 = offset + count == raw.count ? 1 : 0
        zlib += [last, UInt8(count & 0xFF), UInt8(count >> 8), UInt8(~count & 0xFF), UInt8((~count >> 8) & 0xFF)]
        zlib += raw[offset..<(offset + count)]
        offset += count
    } while offset < raw.count
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in raw {
        a = (a + UInt32(byte)) % 65521
        b = (b + a) % 65521
    }
    zlib += bigEndian(b << 16 | a)
    func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let typed = Array(type.utf8) + body
        return bigEndian(UInt32(body.count)) + typed + bigEndian(crc32(typed))
    }
    let header = bigEndian(UInt32(picture.width)) + bigEndian(UInt32(picture.height)) + [8, 2, 0, 0, 0]
    return [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", header) + chunk("IDAT", zlib) + chunk("IEND", [])
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fail("usage: picture_check <in.ppm | in.bmp> <out.png>") }
guard let data = FileManager.default.contents(atPath: arguments[1]) else { fail("no picture at \(arguments[1])") }
let bytes = [UInt8](data)
guard let picture = readPPM(bytes) ?? readBMP(bytes), picture.width > 0, picture.height > 0 else {
    fail("\(arguments[1]) is neither a binary PPM nor a 24- or 32-bit BMP")
}
do {
    try Data(png(picture)).write(to: URL(fileURLWithPath: arguments[2]))
} catch {
    fail("\(arguments[2]): \(error)")
}
let first = picture.rgb[0..<3]
var colours = 1
var index = 3
while index < picture.rgb.count, colours == 1 {
    if picture.rgb[index..<(index + 3)] != first { colours = 2 }
    index += 3
}
if colours == 1 { fail("\(arguments[1]) is one colour (\(picture.width)×\(picture.height)): nothing was drawn") }
print("picture_check: \(arguments[2]) (\(picture.width)×\(picture.height))")
