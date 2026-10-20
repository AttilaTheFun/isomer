// Files the person picked or dropped, where the wasm build's Foundation can
// read them: a read-only directory, /tmp/iso-import, in every app's file
// system (file_system.js), so `Data(contentsOf: url)` works on the web as
// it does on Android (the app's cache directory) and Apple.

import { addImportedFile } from "./file_system.js";

let serial = 0;

/** Stores `fileList` (a FileList or File[]); resolves to the absolute paths
 *  Swift reads them at ("/tmp/iso-import/<n>/<name>"). */
export async function storeFiles(fileList) {
  const paths = [];
  for (const file of Array.from(fileList || [])) {
    serial += 1;
    const name = (file.name || "file").replace(/\//g, "_");
    const relative = `${serial}/${name}`;
    addImportedFile(relative, new Uint8Array(await file.arrayBuffer()));
    paths.push(`/tmp/iso-import/${relative}`);
  }
  return paths;
}
