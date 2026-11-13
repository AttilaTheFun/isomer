// Loads an Isomer runtime module (SwiftUI + iso_hot bridge, exporting everything)
// and a feature side module, then renders, taps and renders again.
import { loadMainWith, loadSide } from './loader.mjs';
const [, , runtimePath, ...sides] = process.argv;
let stream = []; let side = null; let renderRequested = false;
const dec = new TextDecoder();
let main;
const mem = () => new Uint8Array(main.exports.memory.buffer);
const iso_hot = {
  render_tree: (p, n) => { stream.push(...mem().slice(p, p + n)); },
  log: (p, n) => console.log('[guest]', dec.decode(mem().slice(p, p + n))),
  epoch_millis: () => Date.now(),
  schedule_render: () => { renderRequested = true; },
  platform_command: () => {},
  host_value: () => -1,
};
// The runtime's entry point into the app (`__main_argc_argv`) resolves to the
// side module loaded after it.
const env = { __main_argc_argv: (a, b) => side.inst.exports.__main_argc_argv(a, b) };
main = loadMainWith(runtimePath, { iso_hot, env });
const t0 = performance.now();
for (const s of sides) side = loadSide(main, s);
const tLoad = performance.now() - t0;
const E = main.exports;
const ascii = () => String.fromCharCode(...stream.filter(b => b >= 0x20 && b < 0x7f));
E.iso_hot_start(390, 680); E.iso_hot_render();
const first = ascii(); const firstBytes = stream.slice();
console.log('side load ms', tLoad.toFixed(1), '| first frame has "Tap me":', first.includes('Tap me'), '| "Tapped 0 times":', first.includes('Tapped 0 times'));
let id = null; { const k = stream.findIndex((_, i) => String.fromCharCode(...stream.slice(i, i + 4)) === '.tap'); let st = k; const ok = c => (c >= 48 && c <= 57) || c === 46 || (c >= 97 && c <= 122); while (st > 0 && ok(stream[st - 1])) st--; id = String.fromCharCode(...stream.slice(st, k + 4)).replace(/^\.+/, ''); }
const k = stream.findIndex((_, i) => String.fromCharCode(...stream.slice(i, i + 4)) === '.tap'); 
console.log('tap id', id);
const enc = new TextEncoder(); const idb = enc.encode(id);
const ip = E.iso_hot_alloc(idb.length); mem().set(idb, ip); const vp = E.iso_hot_alloc(1);
stream = []; E.iso_hot_event(ip, idb.length, vp, 0); E.iso_hot_render();
console.log('after tap has "Tapped 1 time":', ascii().includes('Tapped 1 time'));
if (process.env.DUMP) { const fs = await import('node:fs'); fs.writeFileSync(process.env.DUMP + '.first.bin', Uint8Array.from(firstBytes)); fs.writeFileSync(process.env.DUMP + '.after.bin', Uint8Array.from(stream)); }
console.log('frames', firstBytes.length, stream.length, '| text:', first.replace(/[^A-Za-z ]+/g, ' ').replace(/ +/g, ' ').slice(0, 160));
E.fflush?.(0);
