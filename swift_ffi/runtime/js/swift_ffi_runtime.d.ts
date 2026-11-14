// The types of swift_ffi_runtime.js (the bridge runtime every generated
// module imports), for consumers who check their own code with TypeScript.
// Nothing in the build reads this file: `js_swift_wasm_library` stages it
// beside the runtime, and the generated `<name>.d.ts` imports from it.

export type WasmValue = number | bigint;

export declare class Runtime {
  readonly memory: WebAssembly.Memory;
  private readonly exports;
  constructor(exports: WebAssembly.Exports);
  call(name: string, ...args: WasmValue[]): WasmValue;
  /** True when the reactor exports `name` (e.g. an interface's register
   * entry point). */
  has(name: string): boolean;
}

export declare const encoder: TextEncoder;
export declare const decoder: TextDecoder;

export declare function stageBytes(runtime: Runtime, bytes: Uint8Array): {
  ptr: number;
  len: number;
  drop(): void;
};
export declare function stageString(runtime: Runtime, value: string): {
  ptr: number;
  len: number;
  drop(): void;
};
export declare function takeBytes(runtime: Runtime, handle: number): Uint8Array;
export declare function takeString(runtime: Runtime, handle: number): string;

/** Releases leaked Swift-owned wrappers after garbage collection. */
export declare const registry: FinalizationRegistry<() => void>;

/** A Swift error surfaced across the bridge (message only). */
export declare class SwiftError extends Error {
}

/** The bridged shape of Swift `throws` and `Result` returns. */
export type Result<T> = { ok: true; value: T } | { ok: false; error: SwiftError };

export type PendingCall = {
  resolve: (value: unknown) => void;
  decode: (blob: Uint8Array) => unknown;
};
export declare const pendingCalls: Map<number, PendingCall>;
export declare function nextCallId(): number;

/** An ERROR blob carrying `message` (a dispatcher's failure answer). */
export declare function encodeError(message: string): Uint8Array;

/** Delivers a host implementation's answer to an in-flight async interface
 * call. */
export declare function resumeAsync(runtime: Runtime, callId: number, blob: Uint8Array): void;

export type ForeignDispatcher = (args: Uint8Array) => Uint8Array;
export declare const foreignObjects: Map<number, ForeignDispatcher>;
export declare function registerForeign(dispatcher: ForeignDispatcher): number;

/** WASI calls a host adds or replaces (wasiShim's `overrides`). */
export type WasiOverrides = Record<string, (...args: any[]) => number>;
export type WasiOverridesFactory = (
  getMemory: () => WebAssembly.Memory,
  builtins: Readonly<WasiOverrides>,
) => WasiOverrides;
export declare function wasiShim(
  getMemory: () => WebAssembly.Memory,
  overridesOrFactory?: WasiOverrides | WasiOverridesFactory,
): Record<string, (...args: number[]) => number>;

export declare const Tags: {
  readonly void: 0;
  readonly int: 1;
  readonly int32: 2;
  readonly double: 3;
  readonly bool: 4;
  readonly string: 5;
  readonly bytes: 6;
  readonly struct: 7;
  readonly list: 8;
  readonly handle: 9;
  readonly error: 10;
  readonly foreign: 11;
};

export declare class BlobWriter {
  private chunks;
  i32(value: number): this;
  i64(value: bigint): this;
  f64(value: number): this;
  bytes(value: Uint8Array): this;
  header(tag: number, aux: number): this;
  /** A STRUCT/HANDLE/FOREIGN header: types are identified on the wire by
   * NAME (aux is the name's byte length, the name follows). */
  typeHeader(tag: number, name: string): this;
  private push;
  data(): Uint8Array;
}

export declare class BlobReader {
  private view;
  private raw;
  private cursor;
  constructor(bytes: Uint8Array);
  i32(): number;
  i64(): bigint;
  f64(): number;
  bytes(count: number): Uint8Array;
  /** True when every byte has been consumed. */
  get done(): boolean;
}

export declare function readTypeHeader(r: BlobReader): { tag: number; name: string };
export declare function readHandleBits(r: BlobReader, expected: string): number;
export declare function writeHandle(w: BlobWriter, name: string, bits: number): void;
export declare function writeForeign(w: BlobWriter, name: string, id: number): void;

/** A runtime type token: generic bridge calls take one of these per type
 * parameter (e.g. `Types.int`, `Types.result(Types.string)`, or a generated
 * `<Struct>Type`). */
export interface BridgeType<T> {
  encode(writer: BlobWriter, value: T): void;
  decode(reader: BlobReader): T;
}

export declare const Types: {
  /** Swift `Int` (a 64-bit value; safe up to 2^53). */
  int: BridgeType<number>;
  int32: BridgeType<number>;
  double: BridgeType<number>;
  bool: BridgeType<boolean>;
  string: BridgeType<string>;
  bytes: BridgeType<Uint8Array>;
  /** Swift `Result<T, Error>` as a value. */
  result<T>(inner: BridgeType<T>): BridgeType<Result<T>>;
  /** Swift `Array<Element>` as a value. */
  array<T>(element: BridgeType<T>): BridgeType<T[]>;
  /** Swift `Dictionary<Key, Value>` as a value. */
  dictionary<K, V>(key: BridgeType<K>, value: BridgeType<V>): BridgeType<Map<K, V>>;
};

export declare function encodeWith<T>(type: BridgeType<T>, value: T): Uint8Array;
export declare function decodeWith<T>(type: BridgeType<T>, bytes: Uint8Array): T;
export declare function errorMessageOf(bytes: Uint8Array): string | null;
export declare function encodeErrorBlob(message: string): Uint8Array;

/** A deferred Swift value: the Swift-side computation runs on first
 * `value()` (then caches, releasing the handle). */
export declare class Lazy<T> {
  private readonly runtime;
  private readonly type;
  private handle;
  private cached;
  private hasValue;
  /** @internal */
  constructor(runtime: Runtime, handle: number, type: BridgeType<T>);
  value(): T;
  /** Releases the underlying Swift handle. Idempotent. */
  close(): void;
}
