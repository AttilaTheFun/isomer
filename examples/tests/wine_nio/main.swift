// SwiftNIO under Wine (BUILD.bazel): an event loop, a loopback echo, and a
// shutdown, each step said on standard error (unbuffered, so a crash
// still shows the last one). Exits 0 when every step passed.

import NIOCore
import NIOPosix
#if os(Windows)
import ucrt
#else
import Glibc
#endif

func say(_ line: String) {
    fputs("nio_probe: \(line)\n", stderr)
}

final class Echo: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

final class Reply: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let received: EventLoopPromise<String>

    init(_ received: EventLoopPromise<String>) {
        self.received = received
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        received.succeed(buffer.readString(length: buffer.readableBytes) ?? "")
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        received.fail(error)
    }
}

do {
    // Each event loop's selector makes its wake-up pair here.
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    say("event loop started")
    let server = try ServerBootstrap(group: group)
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(Echo()) }
        }
        .bind(host: "127.0.0.1", port: 0).wait()
    guard let address = server.localAddress else { throw ChannelError.unknownLocalAddress }
    say("listening on \(address)")
    let received = group.next().makePromise(of: String.self)
    let client = try ClientBootstrap(group: group)
        .channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(Reply(received)) }
        }
        .connect(to: address).wait()
    say("connected")
    try client.writeAndFlush(ByteBuffer(string: "ping")).wait()
    let reply = try received.futureResult.wait()
    say("echoed \"\(reply)\"")
    try client.close().wait()
    try server.close().wait()
    try group.syncShutdownGracefully()
    say(reply == "ping" ? "ok" : "wrong reply")
    exit(reply == "ping" ? 0 : 1)
} catch {
    say("failed: \(error)")
    exit(1)
}
