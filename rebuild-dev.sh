#!/usr/bin/env bash
# Build/install at a fixed path with a remembered signing identity. Never silently
# fall back to ad-hoc signing: that can invalidate macOS privacy grants.
set -euo pipefail
cd "$(dirname "$0")"
identity_file="$(git rev-parse --git-path freeflow-signing-identity)"
identity="${CODESIGN_IDENTITY:-}"
if [ -z "$identity" ] && [ -f "$identity_file" ]; then identity="$(cat "$identity_file")"; fi
if [ -z "$identity" ]; then
  identity="$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')"
fi
if [ -z "$identity" ] || [ "$identity" = '-' ]; then
  echo 'A stable Developer ID signing identity is required. No ad-hoc fallback was used.' >&2
  exit 1
fi
printf '%s\n' "$identity" > "$identity_file"
make ARCH="$(uname -m)" CODESIGN_IDENTITY="$identity"
# Re-sign even when make did not rebuild an existing ad-hoc bundle.
codesign --force --options runtime --sign "$identity" --entitlements FreeFlow.entitlements 'build/FreeFlow Dev.app'
codesign --verify --deep --strict 'build/FreeFlow Dev.app'
ditto 'build/FreeFlow Dev.app' '/Applications/FreeFlow Journal-staging.app'
python3 - <<'PY'
import pathlib, subprocess, os, signal, time
result = subprocess.run(['pgrep', '-f', r'^/Applications/FreeFlow Dev\.app/Contents/MacOS/FreeFlow Dev'], capture_output=True, text=True)
if result.returncode not in (0, 1): raise RuntimeError('Could not identify the running app')
for raw in result.stdout.split():
    pid = int(raw)
    os.kill(pid, signal.SIGTERM)
    for _ in range(50):
        try: os.kill(pid, 0)
        except ProcessLookupError: break
        time.sleep(0.1)
    else: raise RuntimeError('App is still running; installation stopped')
installed = pathlib.Path('/Applications/FreeFlow Dev.app')
if installed.exists():
    trash = pathlib.Path.home() / '.Trash'
    trash.mkdir(exist_ok=True)
    installed.rename(trash / ('FreeFlow Dev-before-update-' + str(time.time_ns()) + '.app'))
pathlib.Path('/Applications/FreeFlow Journal-staging.app').rename(installed)
PY
open -a '/Applications/FreeFlow Dev.app' --args --activity-journal
echo 'Installed with stable signing. macOS may require a grant when changing from the old ad-hoc identity.'
