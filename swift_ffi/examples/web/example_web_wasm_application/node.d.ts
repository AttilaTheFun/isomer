// The two things greeter_web_test.ts takes from Node, declared by hand so the
// example needs no npm packages (no @types/node, so no pnpm lock and no @npm
// repository in the module).
declare module "node:fs" {
  export function readFileSync(path: string): Uint8Array<ArrayBuffer>;
}

declare const process: { argv: string[] };
