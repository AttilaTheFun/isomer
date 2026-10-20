// The platform services (shared/platform_services) implemented with browser
// APIs: localStorage (the keychain, under a sandbox prefix), a popup for
// OAuth, the file input as the image picker. A page hands the result to
// `boot({ dependencies })` — or spreads it and overrides a service. Networking
// and files are Foundation's (URLSession over network.js, FileManager over
// file_system.js), not services.
//
//   import the module next to boot.js, and the generated app_bridge's
//   `Dependencies`, then:
//   const dependencies = browserPlatformServices(Dependencies, { sandbox: "myapp." });

export function browserPlatformServices(Dependencies, options = {}) {
  const sandbox = options.sandbox || "isomer.";
  // The default sandbox was "universalui." before the framework's rename:
  // what a page saved under it moves across, once.
  if (!options.sandbox) {
    try {
      const former = "universalui.";
      const keys = [];
      for (let i = 0; i < localStorage.length; i++) { const key = localStorage.key(i); if (key && key.startsWith(former)) keys.push(key); }
      for (const key of keys) {
        const moved = sandbox + key.slice(former.length);
        if (localStorage.getItem(moved) === null) localStorage.setItem(moved, localStorage.getItem(key));
        localStorage.removeItem(key);
      }
    } catch (_) { /* storage unavailable */ }
  }
  const flags = options.flags || {};
  const toBase64 = (bytes) => { let s = ""; for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000)); return btoa(s); };
  const fromBase64 = (text) => Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
  return {
      keychain: Dependencies.keychainService(() => ({
        async get(key) {
          const stored = localStorage.getItem(sandbox + "keychain:" + key);
          if (stored === null) throw new Error("no keychain value for " + key);
          return fromBase64(stored);
        },
        async set(value, key) { localStorage.setItem(sandbox + "keychain:" + key, toBase64(value)); },
        async delete(key) { localStorage.removeItem(sandbox + "keychain:" + key); },
      })),
      // One-shot delays.
    timer: Dependencies.timerService(() => ({
      delay(milliseconds) { return new Promise((resolve) => setTimeout(resolve, Math.max(0, milliseconds))); },
    })),
    // OAuth through a popup: the redirect lands on this origin's
    // `/oauth/callback` (options.oauthCallbackPath), whose page posts
    // `{ oauthRedirect: location.search }` back with postMessage — or, when
    // it is same-origin, the popup's own location is read directly.
    oauth: Dependencies.oAuthService(() => ({
      async redirectURI() { return location.origin + (options.oauthCallbackPath || "/oauth/callback"); },
      authorize(url) {
        return new Promise((resolve, reject) => {
          const popup = window.open(url, "iso-oauth", "width=520,height=680");
          if (!popup) { reject(new Error("popup blocked")); return; }
          const prefix = location.origin + (options.oauthCallbackPath || "/oauth/callback");
          const finish = (query) => { window.removeEventListener("message", onMessage); clearInterval(poll); try { popup.close(); } catch (_) {} resolve(query.replace(/^\?/, "")); };
          const onMessage = (event) => {
            if (event.origin === location.origin && event.data && typeof event.data.oauthRedirect === "string") finish(event.data.oauthRedirect);
          };
          window.addEventListener("message", onMessage);
          const poll = setInterval(() => {
            try {
              if (popup.closed) { window.removeEventListener("message", onMessage); clearInterval(poll); reject(new Error("cancelled")); return; }
              const href = popup.location.href;
              if (href && href.startsWith(prefix)) finish(popup.location.search);
            } catch (_) { /* cross-origin while at the provider */ }
          }, 300);
        });
      },
    })),
    analytics: Dependencies.analyticsService(() => ({
        track(event) { if (options.devlog) console.warn("[analytics]", event); },
      })),
      configuration: Dependencies.configurationService(() => ({
        flag(key) { return !!flags[key]; },
      })),
      // `<input type="file" accept="image/*">`, scaled on a canvas to
      // maxDimension and returned as a blob URL ("" when cancelled).
      imagePicker: Dependencies.imagePickerService(() => ({
        pickImage(maxDimension) {
          return new Promise((resolve, reject) => {
            const input = document.createElement("input");
            input.type = "file";
            input.accept = "image/*";
            input.style.display = "none";
            document.body.appendChild(input);
            const finish = (value) => { input.remove(); resolve(value); };
            input.onchange = () => {
              const file = input.files && input.files[0];
              if (!file) return finish("");
              const image = new Image();
              const objectURL = URL.createObjectURL(file);
              image.onload = () => {
                const scale = Math.min(1, maxDimension / Math.max(1, image.width, image.height));
                const canvas = document.createElement("canvas");
                canvas.width = Math.max(1, Math.round(image.width * scale));
                canvas.height = Math.max(1, Math.round(image.height * scale));
                canvas.getContext("2d").drawImage(image, 0, 0, canvas.width, canvas.height);
                URL.revokeObjectURL(objectURL);
                // A blob URL: the <img> loads it directly, nothing crosses the tree but the URL.
                canvas.toBlob((blob) => finish(blob ? URL.createObjectURL(blob) : ""), "image/jpeg", 0.85);
              };
              image.onerror = () => { URL.revokeObjectURL(objectURL); reject(new Error("not an image")); };
              image.src = objectURL;
            };
            input.oncancel = () => finish("");
            input.click();
          });
        },
      })),
      };
}
