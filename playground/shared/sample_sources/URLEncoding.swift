// URL helpers shared by the example screens (and their Playground templates).

/// Percent-encodes a query for a URL without Foundation (so it compiles on the
/// wasm / Android reimplementation, which doesn't link Foundation).
func percentEncoded(_ text: String) -> String {
    let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
    var result = ""
    for scalar in text.unicodeScalars {
        let ch = Character(scalar)
        if unreserved.contains(ch) {
            result.append(ch)
        } else {
            for byte in String(scalar).utf8 {
                result += "%"
                result += hexByte(byte)
            }
        }
    }
    return result
}

private func hexByte(_ byte: UInt8) -> String {
    let digits = Array("0123456789ABCDEF")
    return String(digits[Int(byte >> 4)]) + String(digits[Int(byte & 0xF)])
}
