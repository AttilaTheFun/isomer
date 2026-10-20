// Dictionary<Key, Value> as a bridgeable value, following the
// generic-container pattern established in Result+Bridgeable.swift: entries
// encode into `.list` as alternating key/value pairs (order unspecified —
// dictionaries are unordered). Usable wherever erased values flow, whenever
// `Key` and `Value` are themselves bridgeable.

extension Dictionary: Bridgeable where Key: Bridgeable, Value: Bridgeable {
    public init(bridgeValue: BridgeValue) throws {
        guard case .list(let items) = bridgeValue, items.count.isMultiple(of: 2) else {
            throw BridgeDecodingError("expected Dictionary, got \(bridgeValue)")
        }
        self.init(minimumCapacity: items.count / 2)
        var index = 0
        while index < items.count {
            let key = try Key(bridgeValue: items[index])
            let value = try Value(bridgeValue: items[index + 1])
            self[key] = value
            index += 2
        }
    }

    public var bridgeValue: BridgeValue {
        var items: [BridgeValue] = []
        items.reserveCapacity(count * 2)
        for (key, value) in self {
            items.append(key.bridgeValue)
            items.append(value.bridgeValue)
        }
        return .list(items)
    }
}
