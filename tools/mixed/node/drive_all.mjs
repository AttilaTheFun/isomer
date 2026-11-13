// Taps every tap id of the first frame in turn (rendering after each) and
// writes the concatenated render stream, to compare two builds byte for byte.
import fs from 'node:fs';
import { loadMainWith, loadSide } from './loader.mjs';
const [, , out, runtimePath, ...sides] = process.argv;
let stream = []; let side = null; let main;
const mem = () => new Uint8Array(main.exports.memory.buffer);
const iso_hot = { render_tree: (p, n) => { for (const b of mem().subarray(p, p + n)) stream.push(b); }, log: () => {}, epoch_millis: () => 1.7e12, schedule_render: () => {}, platform_command: () => {}, host_value: () => -1 };
main = loadMainWith(runtimePath, { iso_hot, env: { __main_argc_argv: (a, b) => side.inst.exports.__main_argc_argv(a, b) } });
for (const s of sides) side = loadSide(main, s);
const E = main.exports;
E.iso_hot_start(1024, 768); E.iso_hot_render();
const ids = []; const ok = c => (c >= 48 && c <= 57) || c === 46 || (c >= 97 && c <= 122);
for (let i = 0; i + 4 <= stream.length; i++) if (stream[i] === 46 && stream[i+1] === 116 && stream[i+2] === 97 && stream[i+3] === 112) { let st = i; while (st > 0 && ok(stream[st-1])) st--; const id = String.fromCharCode(...stream.slice(st, i + 4)).replace(/^\.+/, ''); if (!ids.includes(id)) ids.push(id); }
const enc = new TextEncoder(); let traps = 0;
const t0 = performance.now();
for (const id of ids) {
  const idb = enc.encode(id); const ip = E.iso_hot_alloc(idb.length); mem().set(idb, ip); const vp = E.iso_hot_alloc(1);
  try { E.iso_hot_event(ip, idb.length, vp, 0); E.iso_hot_render(); } catch (e) { traps++; console.log('trap on', id, e.message); break; }
}
const ms = performance.now() - t0;
fs.writeFileSync(out, Uint8Array.from(stream));
const text = Buffer.from(stream).toString('latin1');
console.log(`${ids.length} taps, ${stream.length} bytes of frames, ${traps} traps, ${ms.toFixed(0)} ms; mentions Toggle:${text.includes('Toggle')} Slider:${text.includes('Slider')} Grid:${text.includes('Grid')}`);
