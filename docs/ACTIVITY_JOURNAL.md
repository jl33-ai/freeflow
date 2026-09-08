# Git for Work (Den)

The menu starts with **Copy today’s commits**, followed by **N screenshots taken
today**. The window’s **Copy day** copies the selected date. Both write the whole
day directly to the clipboard: local time (including seconds, timezone and offset),
app, window title, literal Apple Vision OCR, and complete observation/inference
JSON. No save dialog, summarization, obfuscation, or remote export step is involved.
The day is selected using the current local timezone, including daylight saving.

Capture starts automatically. The default interval is 60 seconds; the gear accepts
5–300 seconds and preserves an explicitly chosen interval. Lock, sleep, private
windows, password managers, excluded apps, and this app are skipped. A slow capture
can miss a timer tick; timers are not a real-time guarantee.

## Screenshot lifetime

Screenshots are never written to disk by this feature. A capture is OCR’d in memory,
then its literal OCR and metadata are written locally. If the local vision model
is free, it receives the PNG directly over loopback; otherwise its description is
marked skipped. Only one description runs at a time; no image backlog is retained.
The image is released after processing, failure, or process exit. macOS manages RAM
and swap; this is an application-level no-file-persistence policy.

At startup, legacy `screenshot.png` files under this feature’s data directory are
removed. Existing OCR, metadata, and descriptions are retained. Pending work from
an earlier process is marked interrupted because its image cannot be recovered.
Copies users previously exported to other folders are outside this migration.

Text lives at `~/Library/Application Support/FreeFlow Dev/GitForWorkRaw/<date>/<id>`:
`observation.json`, `ocr.txt`, `inference.json`, and `index.json`. Raw text is not
obfuscated and may include sensitive visible material. Directories are private
(0700), source text files 0600, and JSON writes atomic. Text has no automatic expiry.
The earlier `ActivityJournal` archive is preserved. Bundle ID, canonical install
path, and signing identity stay stable to preserve data and permission grants.

## Models and speech

Apple Vision OCR uses accurate recognition with language correction disabled.
The vision path uses `qwen3.5:9b` at `127.0.0.1:11436`, with cloud disabled and no
redirects, proxy, cookies, URL cache, or remote fallback. It gets the original image
plus app/window metadata, not OCR text. Description output is separate from raw data.
Install with `bash local-setup/install-journal-model.sh` (needs internet and 8 GB free).
The 6.6 GB model download previously failed for lack of space; the partial download
was removed. Until installed, OCR and copying work, and descriptions are marked failed.

FreeFlow speech-to-text remains under **Dictation**, with the existing hotkeys,
provider settings, setup, and transcription pipeline. The Den icon shows recording
or transcribing state alongside it. Dictation provider costs remain separate.

## Validation

`make check` covers text persistence/copy output, unredacted OCR, local timezone,
other-day exclusion, migration without deleting unrelated files, no saved image,
image transport, icon alpha, and the existing speech/hotkey/provider test suite.
`git diff --check` checks patch formatting. No real user screenshots, OCR, audio,
clipboard content, or transcript data is included in tests or logs.

Native clipboard interaction, live microphone/paste, screen grants, and live model
inference require manual verification before merge; synthetic checks do not prove
these end-to-end behaviors. A draft PR must keep that boundary explicit.
