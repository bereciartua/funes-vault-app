#!/bin/sh
# Task 3.10: PNGs of every main screen, sheet and panel, light and dark, from the UI-review build
# (FUNES_UI_REVIEW: a throwaway vault with sample data; it never opens the real vault, starts the
# MCP server or writes agents' configs). Needs a logged-in GUI session. The app shows each window
# and this script captures it with screencapture, which needs Screen Recording permission for the
# terminal that runs it.
#   sh scripts/ui_snapshots.sh [output folder]     (default build/ui-snapshots)
#   FUNES_UI_ONLY=menubar-panel sh scripts/ui_snapshots.sh   (only the scenes whose name contains it)
set -eu
cd "$(dirname "$0")/.."
output=${1:-build/ui-snapshots}
xcodebuild -project FunesVault.xcodeproj -scheme FunesMac -configuration Debug \
    -destination 'generic/platform=macOS' -derivedDataPath build/ui-review \
    CODE_SIGNING_ALLOWED=NO SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG FUNES_UI_REVIEW' build -quiet
mkdir -p "$output"
if [ -z "${FUNES_UI_ONLY:-}" ]; then rm -f "$output"/*.png; fi
PYTHONPYCACHEPREFIX="$PWD/build/pycache" python3 - build/ui-review/Build/Products/Debug/FunesVault.app/Contents/MacOS/FunesVault "$output" <<'PY'
import json, os, subprocess, sys, time

app, folder = sys.argv[1:3]
process = subprocess.Popen([app, "--ui-snapshots", folder], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
count = 0
for line in process.stdout:
    try:
        message = json.loads(line)
    except ValueError:
        continue
    if "ready" in message:
        path = os.path.join(folder, message["ready"] + ".png")
        time.sleep(0.2)
        subprocess.run(["screencapture", "-x", "-o", "-l", str(message["windowNumber"]), path], check=True)
        count += 1
        process.stdin.write("\n")
        process.stdin.flush()
    elif message.get("outcome") != "passed":
        process.kill()
        raise SystemExit("ui_snapshots: the review build failed: " + line)
if process.wait() != 0:
    raise SystemExit("ui_snapshots: the review build exited with an error")
print(f"ui_snapshots: {count} snapshots in {folder}")
PY
# A window captured before it was ready comes out tiny.
small=""
for file in "$output"/*${FUNES_UI_ONLY:-}*.png; do
    width=$(sips -g pixelWidth "$file" | awk '/pixelWidth/ { print $2 }')
    height=$(sips -g pixelHeight "$file" | awk '/pixelHeight/ { print $2 }')
    [ "$width" -ge 300 ] && [ "$height" -ge 100 ] || small="$small $(basename "$file") (${width}x$height px)"
done
if [ -n "$small" ]; then
    printf 'ui_snapshots: captured too small:%s\n' "$small" >&2
    exit 1
fi
