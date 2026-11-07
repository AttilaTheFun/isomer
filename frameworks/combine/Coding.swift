// decode(type:decoder:) and encode(encoder:), over the coder protocols
// Foundation's JSON and property-list coders adopt (Foundation's side: it
// imports Combine, as Apple's does).

public protocol TopLevelDecoder {
    associatedtype Input
    func decode<T>(_ type: T.Type, from: Self.Input) throws -> T where T: Decodable
}

public protocol TopLevelEncoder {
    associatedtype Output
    func encode<T>(_ value: T) throws -> Self.Output where T: Encodable
}

extension Publisher {
    public func decode<Item, Coder>(type: Item.Type, decoder: Coder) -> Publishers.Decode<Self, Item, Coder>
    where Item: Decodable, Coder: TopLevelDecoder, Self.Output == Coder.Input {
        Publishers.Decode(upstream: self, decoder: decoder)
    }
}

extension Publisher where Self.Output: Encodable {
    public func encode<Coder>(encoder: Coder) -> Publishers.Encode<Self, Coder> where Coder: TopLevelEncoder {
        Publishers.Encode(upstream: self, encoder: encoder)
    }
}

extension Publishers {
    public struct Decode<Upstream, Output, Coder>: Publisher
    where Upstream: Publisher, Output: Decodable, Coder: TopLevelDecoder, Upstream.Output == Coder.Input {
        public typealias Failure = Error

        public let upstream: Upstream
        private let decoder: Coder

        public init(upstream: Upstream, decoder: Coder) {
            self.upstream = upstream
            self.decoder = decoder
        }

        public func receive<S>(subscriber: S) where Output == S.Input, S: Subscriber, S.Failure == any Error {
            let decoder = self.decoder
            upstream.subscribeTrying("Decode", subscriber) { .send(try decoder.decode(Output.self, from: $0)) }
        }
    }

    public struct Encode<Upstream, Coder>: Publisher where Upstream: Publisher, Coder: TopLevelEncoder, Upstream.Output: Encodable {
        public typealias Failure = Error
        public typealias Output = Coder.Output

        public let upstream: Upstream
        private let encoder: Coder

        public init(upstream: Upstream, encoder: Coder) {
            self.upstream = upstream
            self.encoder = encoder
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Coder.Output == S.Input, S.Failure == any Error {
            let encoder = self.encoder
            upstream.subscribeTrying("Encode", subscriber) { .send(try encoder.encode($0)) }
        }
    }
}
