// Writes WasmFixtures' modules to the directory given, for the web's linker
// test (side_modules_test.mjs), which loads the same bytes.
import Foundation
import WasmFixtures

@main
struct WriteFixtures {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        for (name, bytes) in WasmFixtures.all {
            try Data(bytes).write(to: directory.appendingPathComponent(name))
        }
    }
}
