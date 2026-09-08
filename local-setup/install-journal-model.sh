#!/bin/bash
set -euo pipefail

# A dedicated local-only runtime, independent of dictation's hybrid router.
if ! command -v ollama >/dev/null; then brew install ollama; fi
journal_ollama="$(command -v ollama)"
journal_plist="$HOME/Library/LaunchAgents/com.freeflow.journal-model.plist"
mkdir -p "$HOME/Library/LaunchAgents"
python3 - "$journal_plist" "$journal_ollama" <<'PY'
import os, plistlib, sys
path, binary = sys.argv[1:]
with open(path, 'wb') as stream:
    plistlib.dump({
        'Label': 'com.freeflow.journal-model',
        'ProgramArguments': [binary, 'serve'],
        'EnvironmentVariables': {
            'OLLAMA_HOST': '127.0.0.1:11436',
            'OLLAMA_NO_CLOUD': '1',
            'OLLAMA_MAX_LOADED_MODELS': '1',
            'OLLAMA_NUM_PARALLEL': '1',
            'OLLAMA_KEEP_ALIVE': '2m',
            'OLLAMA_FLASH_ATTENTION': '1',
            'OLLAMA_KV_CACHE_TYPE': 'q8_0',
        },
        'RunAtLoad': True,
        'KeepAlive': True,
        'StandardOutPath': '/dev/null',
        'StandardErrorPath': '/dev/null',
    }, stream)
os.chmod(path, 0o600)
PY
launchctl bootout "gui/$(id -u)/com.freeflow.journal-model" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$journal_plist"
for journal_attempt in {1..20}; do
    if curl --silent --fail --max-time 1 http://127.0.0.1:11436/api/version >/dev/null; then break; fi
    sleep 1
done
OLLAMA_HOST=127.0.0.1:11436 "$journal_ollama" pull qwen2.5:3b
