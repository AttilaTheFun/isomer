// The renderer side of the Electron example: loads the Swift wasm reactor
// through the generated TypeScript bindings and renders the bridged calls.
// esbuild bundles this file together with the generated bindings into plain
// JS at build time (Chromium cannot strip TypeScript types itself).
import { load } from "./greeter_web.js";

const response = await fetch("greeter_web.wasm");
const bridge = await load(await response.arrayBuffer());

// An interface instance crosses as an owned handle; close() releases the
// Swift object deterministically.
const counter = bridge.makeCounter("taps");
let counterLabel: string;
try {
  counter.increment();
  counter.increment();
  counter.increment();
  counterLabel = counter.label();
} finally {
  counter.close();
}

// Interface parameters going TypeScript -> Swift: a Swift-owned wrapper
// passes its handle; a plain object implementing Counter crosses as a
// foreign object Swift calls back into.
const swiftSide = bridge.makeCounter("swift-side");
swiftSide.increment();
const describedSwift = bridge.describe(swiftSide);
swiftSide.close();
const describedForeign = bridge.describe({ increment: () => 7, label: () => "a TS counter" });

// The reverse direction: this object implements the Swift protocol
// GreetingObserver and is passed *into* Swift, which calls back out through
// the foreign proxy — with parameters crossing both ways, including an
// interface parameter going Swift -> TypeScript (sessionEnded receives an
// owned SwiftCounter).
const observed: string[] = [];
let sessionLine = "";
const delivered = bridge.deliverGreetings(
  {
    greetingDelivered(greeting, index) {
      observed.push(`observer #${index}: ${greeting}`);
    },
    shouldContinue(after) {
      return after < 3;
    },
    sessionEnded(tally) {
      tally.increment();
      sessionLine = `session ended: ${tally.label()}`;
      tally.close();
    },
  },
  "Electron",
  10,
);

// Swift `throws` and `Result` returns both bridge as Result<T>; async
// functions bridge as Promises (of Result when failable).
const parsed = bridge.parseNumber("nope");
const parsedLine = parsed.ok ? `parseNumber("nope") = ${parsed.value}` : `parseNumber("nope") failed: ${parsed.error.message}`;
const motd = await bridge.fetchMotd();
const fetched = await bridge.fetchNumber(41);
const fetchedLine = fetched.ok ? `fetchNumber(41) = ${fetched.value}` : `fetchNumber(41) failed: ${fetched.error.message}`;

const lines = [
  bridge.greeting("Electron"),
  `add(19, 23) = ${bridge.add(19, 23)}`,
  `isEven(42) = ${bridge.isEven(42)}`,
  counterLabel,
  describedSwift,
  describedForeign,
  ...observed,
  sessionLine,
  `delivered ${delivered} greetings`,
  parsedLine,
  `motd: ${motd}`,
  fetchedLine,
];

const output = document.getElementById("output")!;
for (const line of lines) {
  const paragraph = document.createElement("p");
  paragraph.textContent = line;
  output.appendChild(paragraph);
}
