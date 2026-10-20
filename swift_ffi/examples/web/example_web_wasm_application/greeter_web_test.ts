// End-to-end test of the generated TypeScript bindings: loads the Swift wasm
// reactor and exercises the bridged surface, including the String copy round
// trip and interface handle ownership.
import { readFileSync } from "node:fs";
import { Dependencies, load, type Result } from "./greeter_web.js";

function assertEqual<T>(actual: T, expected: T, what: string): void {
  if (actual !== expected) {
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function expectOk<T>(result: Result<T>, what: string): T {
  if (!result.ok) throw new Error(`${what}: unexpected error ${result.error.message}`);
  return result.value;
}

function expectError<T>(result: Result<T>, what: string): string {
  if (result.ok) throw new Error(`${what}: expected an error, got ${JSON.stringify(result.value)}`);
  return result.error.message;
}

const wasmPath = process.argv[2];
const bridge = await load(readFileSync(wasmPath));

// Scalars over the flat C ABI.
assertEqual(bridge.add(2, 3), 5, "add");
assertEqual(bridge.isEven(4), true, "isEven(4)");
assertEqual(bridge.isEven(7), false, "isEven(7)");

// Strings are copied at the boundary — including non-ASCII UTF-8.
assertEqual(bridge.greeting("wörld 🌍"), "Hello from Swift, wörld 🌍!", "greeting");

// Interfaces cross as owned handles behind idiomatic wrappers.
const counter = bridge.makeCounter("clicks");
assertEqual(counter.increment(), 1, "increment #1");
assertEqual(counter.increment(), 2, "increment #2");
assertEqual(counter.label(), "clicks is at 2", "label");

// Deterministic disposal: close() releases the Swift instance exactly once,
// and use-after-close fails loudly.
counter.close();
counter.close(); // idempotent
let threw = false;
try {
  counter.increment();
} catch {
  threw = true;
}
assertEqual(threw, true, "use after close throws");

// Interface parameters going consumer -> Swift: a Swift-owned wrapper passes
// its handle; a plain TypeScript implementation of Counter crosses as a
// foreign object Swift calls back into.
const swiftCounter = bridge.makeCounter("swift-side");
swiftCounter.increment();
assertEqual(
  bridge.describe(swiftCounter),
  "counter says: swift-side is at 1",
  "Swift-owned interface passed back in as a parameter",
);
swiftCounter.close();
assertEqual(
  bridge.describe({ increment: () => 7, label: () => "a TS counter" }),
  "counter says: a TS counter",
  "consumer-implemented interface passed in as a parameter",
);

// The reverse direction: a TypeScript object implements the Swift protocol
// GreetingObserver and is passed *into* Swift, which calls back out through
// the foreign proxy — with parameters crossing the boundary both ways,
// including an interface parameter going Swift -> consumer (sessionEnded
// receives an owned Counter wrapper).
const received: string[] = [];
let tallyLabel = "";
const delivered = bridge.deliverGreetings(
  {
    greetingDelivered(greeting, index) {
      received.push(`${index}: ${greeting}`);
    },
    shouldContinue(after) {
      return after < 3;
    },
    sessionEnded(tally) {
      tally.increment();
      tallyLabel = tally.label();
      tally.close();
    },
  },
  "wasm",
  10,
);
assertEqual(delivered, 3, "deliverGreetings stops when the observer declines");
assertEqual(received.length, 3, "observer received each greeting");
assertEqual(received[0], "1: Hello, wasm #1!", "string parameters cross into the observer");
assertEqual(received[2], "3: Hello, wasm #3!", "index parameter crosses into the observer");
assertEqual(tallyLabel, "tally is at 4", "interface parameter crossed Swift -> consumer");

// Structs are copied field-wise: plain objects in, plain objects out.
const metrics = bridge.measure("hi", 10);
assertEqual(metrics.label, "HI", "struct string field");
assertEqual(metrics.height, 13, "struct double field");
assertEqual(bridge.area({ width: 3, height: 4, label: "x" }), 12, "struct parameter");
assertEqual(
  bridge.describeMetrics({
    metrics(scale) {
      return { width: scale * 3, height: 4, label: "from TS" };
    },
  }),
  "from TS: 6.0x4.0",
  "struct returned from a consumer-implemented method",
);

// Raw bytes cross by copy as Uint8Array.
assertEqual(bridge.checksum(new Uint8Array([1, 2, 3])), 6, "bytes parameter");
const doubledBytes = bridge.doubled(new Uint8Array([7, 9]));
assertEqual(doubledBytes.join(","), "7,7,9,9", "bytes return");

// Swift `throws` and `Result` returns both bridge as Result<T>.
assertEqual(expectOk(bridge.requireEven(42), "requireEven(42)"), 21, "throwing success");
assertEqual(expectError(bridge.requireEven(7), "requireEven(7)"), "7 is odd", "throwing failure");
assertEqual(expectOk(bridge.parseNumber("19"), "parseNumber"), 19, "Result success");
assertEqual(
  expectError(bridge.parseNumber("nope"), "parseNumber"),
  "not a number: nope",
  "Result failure",
);

// Async functions bridge to Promises (of Result when failable), resumed
// through Swift's executor pumped by microtasks.
assertEqual(await bridge.fetchMotd(), "Greetings arrive asynchronously.", "async");
assertEqual(expectOk(await bridge.fetchNumber(41), "fetchNumber(41)"), 42, "async throwing success");
assertEqual(
  expectError(await bridge.fetchNumber(1000), "fetchNumber(1000)"),
  "1000 is too large",
  "async throwing failure",
);

// A guest Task.sleep resumes through the host's timer, and not before it.
{
  const started = Date.now();
  assertEqual(await bridge.sleepThenAnswer(60), "Slept 60 ms.", "Task.sleep resumes");
  const waited = Date.now() - started;
  if (waited < 50) throw new Error(`Task.sleep returned after ${waited} ms, before its 60 ms`);
}

// --- Bridge v2 --------------------------------------------------------------

// Generic exports: TypeScript generics are erased at runtime, so each type
// parameter takes a runtime token (Types.int / Types.string / a struct token).
const { Types, TextMetricsType, SwiftError: BridgedError } = await import("./greeter_web.js");
assertEqual(bridge.choose(Types.int, 1, 2, false), 1, "choose<Int>");
assertEqual(bridge.choose(Types.string, "a", "b", true), "b", "choose<String>");
// Containers cross generic positions via the LIST composite (the same
// convention Swift's Result/Array/Dictionary+Bridgeable conformances use).
assertEqual(
  JSON.stringify(bridge.choose(Types.array(Types.int), [1, 2], [3], false)),
  JSON.stringify([1, 2]),
  "choose<[Int]>");
const chosenDict = bridge.choose(
  Types.dictionary(Types.string, Types.int),
  new Map([["a", 1], ["b", 2]]),
  new Map(),
  false);
assertEqual(chosenDict.get("a"), 1, "choose<[String: Int]> (a)");
assertEqual(chosenDict.get("b"), 2, "choose<[String: Int]> (b)");
const chosenMetrics = bridge.choose(
  TextMetricsType,
  { width: 1, height: 2, label: "first" },
  { width: 3, height: 4, label: "second" },
  true,
);
assertEqual(chosenMetrics.label, "second", "choose<TextMetrics> (struct through a generic)");

// Callback closures cross consumer -> Swift through the foreign registry.
assertEqual(
  bridge.transform(14, (v) => v * 3),
  42,
  "closure parameter",
);
assertEqual(
  bridge.renderList(3, (i) => `item${i}`),
  "item1, item2, item3",
  "closure returning String",
);

// Lazy<T>: the Swift-side computation defers to the first unwrap and caches.
const lazy = bridge.expensiveGreeting("web");
const lazyValue = lazy.value();
assertEqual(
  lazyValue.startsWith("Expensively greeting web"),
  true,
  "Lazy computes on first unwrap",
);
assertEqual(lazy.value(), lazyValue, "Lazy caches");

// Result<T, Error> as a first-class value (a parameter here).
assertEqual(
  bridge.describeOutcome({ ok: true, value: 7 }),
  "ok(7)",
  "Result value parameter (success)",
);
assertEqual(
  bridge.describeOutcome({ ok: false, error: new BridgedError("boom") }).startsWith("err("),
  true,
  "Result value parameter (failure)",
);

assertEqual(bridge.tonedGreeting("web", "cheerful"), "Hey hey, web!", "enum parameter");

// Dependency injection: the host injects a lazily-constructed Counter; the
// guest resolves it through the dependency dictionary and drives it.
let constructed = 0;
class HostCounter {
  private count = 0;
  increment(): number { return ++this.count; }
  label(): string { return `host is at ${this.count}`; }
}
const bridgeWithDeps = await load(readFileSync(wasmPath), {
  dependencies: {
    counter: Dependencies.counter(() => {
      constructed += 1;
      return new HostCounter();
    }),
  },
});
assertEqual(constructed, 0, "dependency construction is deferred");
assertEqual(bridgeWithDeps.dependentCount(), 1, "guest resolves and drives the injected Counter");
assertEqual(constructed, 1, "dependency constructed on first use");
assertEqual(bridgeWithDeps.dependentCount(), 2, "the same instance persists");
assertEqual(bridge.dependentCount(), -1, "absent dependencies resolve nil");

console.log("greeter_web_test: OK");
