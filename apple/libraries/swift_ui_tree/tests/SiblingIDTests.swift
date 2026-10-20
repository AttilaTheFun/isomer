import IsomerTree
import XCTest

/// IsomerTreeView's sibling identities (`siblingIDs`): the IDs its stacks and
/// boxes hand SwiftUI's ForEach, which must be distinct among siblings and
/// keep a keyed child's identity when a sibling comes in before it.
final class SiblingIDTests: XCTestCase {
    func testRepeatedKeysStayDistinct() {
        // A fallback spelled into the key ("a#2") once made the third "a"
        // take the second's identity.
        XCTAssertEqual(siblingIDs(["a", "a#2", "a"]), [
            .key("a", occurrence: 0), .key("a#2", occurrence: 0), .key("a", occurrence: 1),
        ])
    }

    func testKeysNeverPassForPositions() {
        let ids = siblingIDs(["#1", nil, "#0", nil])
        XCTAssertEqual(ids, [.key("#1", occurrence: 0), .position(1), .key("#0", occurrence: 0), .position(3)])
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testAKeyedChildKeepsItsIdentityWhenASiblingComesInBeforeIt() {
        // The composer: a suggestions row put in above the field.
        let before = siblingIDs(["field", "bar"])
        let after = siblingIDs(["suggestions", "field", "bar"])
        XCTAssertEqual(before[0], after[1])
        XCTAssertEqual(before[1], after[2])
    }

    func testEveryMixOfKeysIsDistinct() {
        // Every sequence of up to five siblings drawn from keys that look
        // like each other, like positions, and like none.
        let alphabet: [String?] = [nil, "a", "a#1", "a#2", "#0", "#1", ""]
        var sequences: [[String?]] = [[]]
        for _ in 0..<5 {
            sequences += sequences.filter { $0.count == sequences.last!.count }.flatMap { prefix in
                alphabet.map { prefix + [$0] }
            }
        }
        for keys in sequences {
            let ids = siblingIDs(keys)
            XCTAssertEqual(ids.count, keys.count)
            XCTAssertEqual(Set(ids).count, ids.count, "\(keys) gave \(ids)")
        }
    }
}
