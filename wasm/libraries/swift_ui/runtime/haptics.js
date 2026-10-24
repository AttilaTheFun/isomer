// `.sensoryFeedback`'s haptics in a browser: the platform command
// "haptic" with the feedback's name ("success", "impact:heavy:1.0"…),
// played as a vibration where the browser has one (Android's Chrome; not
// iOS's Safari, which has no vibration), else nothing.

const PATTERNS = {
  success: [12, 60, 18],
  warning: [20, 80, 20],
  error: [30, 50, 30, 50, 30],
  selection: [6],
  increase: [8],
  decrease: [8],
  start: [14],
  stop: [14],
  alignment: [5],
  levelChange: [10],
  pathComplete: [10, 50, 10],
};

/** Plays the named feedback; false when the browser can't. */
export function playHaptic(name) {
  if (typeof navigator === "undefined" || typeof navigator.vibrate !== "function") return false;
  const [kind, flavor, intensity] = String(name).split(":");
  let pattern = PATTERNS[kind];
  if (kind === "impact") {
    const base = { light: 8, soft: 8, medium: 14, solid: 14, heavy: 22, rigid: 18 }[flavor] || 14;
    pattern = [Math.max(1, Math.round(base * (Number(intensity) || 1)))];
  }
  return pattern ? navigator.vibrate(pattern) : false;
}
