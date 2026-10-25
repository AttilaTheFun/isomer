#!/bin/bash
# See BUILD.bazel: dev compile server + headless Chrome drive of the host hook.
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"  # node, python3 (bazel scrubs PATH)
SITE="$1"; SDK="$2"; SERVER="$3"; EVAL="$4"
# The toolchain repos live in bazel's output base — derive it from where the
# test runs (<output_base>/execroot/…; HOME is sandboxed under bazel test).
OUTPUT_BASE="${ISO_OUTPUT_BASE:-${PWD%%/execroot/*}}"
PORT=$((8100 + RANDOM % 500))
LOG="${TEST_UNDECLARED_OUTPUTS_DIR:-/tmp}/dev_compile_server.log"
python3 "$SERVER" --site "$SITE" --sdk "$SDK" --output-base "$OUTPUT_BASE" --port "$PORT" >"$LOG" 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null' EXIT
sleep 2
RESULT="$(node "$EVAL" "http://127.0.0.1:$PORT/" 10 '(async () => { const h = window.__playgroundHost; const src = await (await fetch("./assets/Counter.swift")).text(); const d = await h.compile(src); if (d) return "compile failed: " + d.slice(0, 300); await h.run(); await new Promise(r => setTimeout(r, 1500)); await h.tap("Tap me"); await new Promise(r => setTimeout(r, 600)); return h.uiTree().split("\n").filter(l => /Tapped/.test(l)).join(""); })()')"
echo "$RESULT"
echo "$RESULT" | grep -q "Tapped 1 times" && echo PASS || { echo FAIL; echo "--- dev compile server log:"; tail -20 "$LOG"; exit 1; }
