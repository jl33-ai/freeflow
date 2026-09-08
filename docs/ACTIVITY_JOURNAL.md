# Git for Work (Den)

The app opens directly to captures. The Den menu has Open, Start/Pause, and Export; existing dictation controls are under Dictation. There is no daily-plan UI. The gear holds capture interval, exclusions, data folder, and screen permission. Branding uses the supplied Den SVG. Bundle identity and storage paths remain stable to preserve existing data and grants.

# git for work — raw capture log

Open **git for work** from FreeFlow's menu and click **Start**. Set **Screenshot
every … seconds** behind the gear (5–300 seconds, default 15). The small window
shows captures for the selected day, their processing status and local activity
descriptions. Click a capture to open its original files.

Each successful capture produces a **full-resolution, lossless PNG of the active
app's window**, literal Apple Vision OCR and relevant system metadata. Capturing,
OCR and inference have separate queues: slow inference cannot prevent saving new
screenshots. Every saved capture is queued for OCR and a local description. Pending
work survives app restarts; failures are explicit and never remove the screenshot.
There is no automatic task grouping or commit synthesis in this version.

## Raw files and export

Raw data is saved under `GitForWorkRaw/YYYY-MM-DD/<capture-uuid>/` in FreeFlow's
Application Support folder:

- `screenshot.png`: the original capture, never resized for export.
- `observation.json`: schema version, UUID, UTC and local timestamps, timezone and
  UTC offset, requested interval, idle time, app name/bundle ID/PID/executable path,
  window ID/title/bounds, image dimensions, macOS version, optional Accessibility
  document URL/focused-element role, whether the app remained foreground, and OCR.
- `ocr.txt`: literal OCR text, populated after recognition.
- `inference.json`: the separate local-model description, category, confidence,
  completion/error state and whether input was truncated. It never replaces OCR.
- `index.json`: a small internal index for the UI and durable processing queues.

OCR uses Apple Vision's accurate recognition with language correction disabled,
without confidence filtering, redaction or summarization. Text, confidence and
normalized bounding boxes (bottom-left origin) are retained. OCR is an attempt,
not an exact transcription guarantee; the PNG is always available for reprocessing.
Optional Accessibility metadata is read only when permission already exists. The
journal does not request an Accessibility grant or read clipboard/keystroke values.

Use **Export → This day…** or **Export → All captures…** and choose a destination.
A new folder contains every selected PNG, literal OCR, observation and inference
JSON, plus `manifest.jsonl` and a README. Each manifest line includes complete
observation and inference objects and relative paths to the image/text files.
There are no proprietary formats, API dependencies or summary-only exports.
An in-progress export includes pending/error statuses accurately; later processing
results appear in the next export. Original files are unchanged. Export copying
runs off the capture/store queues and publishes its destination only on success.

## Capture behavior

An observation is attempted when starting, then at the chosen cadence. App switches
do not trigger extra screenshots. Captures continue while idle, with idle seconds
recorded. Lock, sleep, excluded apps and unavailable/private windows are skipped.
Password managers and FreeFlow itself are excluded. Private-window detection is
best effort; exclude your browser when needed. There is no whole-desktop fallback.
Slow captures never overlap; macOS scheduling and unavailable windows can cause
missed intervals. Actual request/capture timestamps are exported.

## Local processing and storage

Install the dedicated model service once:

```sh
bash local-setup/install-journal-model.sh
```

Inference uses only Qwen 2.5 3B at `127.0.0.1:11436`. The dedicated Ollama service
has `OLLAMA_NO_CLOUD=1`, one model/inference slot and no runtime log files. No cloud
fallback or sync exists. Model installation needs internet; processing does not.
The first 18,000 OCR characters plus the window title inform each description;
**the raw export retains all OCR**, and inference metadata reports truncation.
The model input/output has additional masking/instruction filtering, without
changing the raw record. FreeFlow dictation has separate provider settings.

Raw files are deliberately **not obfuscated** and may contain private text or
credentials visible on screen. They are stored locally until you remove them;
there is no automatic expiry. Directories are private (0700), source data files
0600, and writes are atomic. They are not separately encrypted. The app stops
saving before available disk space falls below approximately 512 MB. Use **Open
raw data folder** to manage storage. Images can consume substantial disk space at
short intervals. Existing older summary-only history is left in its old
`ActivityJournal` folder; screenshots from that earlier version cannot be recreated.

## Permissions and updates

The capture log itself needs Screen Recording. **Allow…** appears if missing.
It requests the native grant once on explicit click; subsequent clicks open
Settings. Background capture never invokes permission prompts. macOS may still
show its own policy notices or revoke a grant.

Use `./rebuild-dev.sh` to build/install. It remembers a Developer ID identity in
Git's local metadata, refuses ad-hoc signing, verifies the signature and installs
at the same path/bundle ID. The initial change from ad-hoc signing may need one new
grant. Subsequent updates reuse the stable identity. This reduces permission churn
but cannot guarantee macOS will never request consent again.

## Validation

`make check` includes a raw-data round-trip test: screenshot bytes and literal OCR
(including whitespace, email/path/credential-like synthetic text) survive export
unchanged, even when model inference fails. It checks the JSONL manifest, metadata,
private directory permissions and path traversal rejection.

The synthetic image/local-model smoke test requires no real screen data:

```sh
swiftc -target arm64-apple-macosx13.0 -parse-as-library \
  Sources/ActivityJournalCore.swift Sources/ActivityJournalCapture.swift \
  Sources/RawCaptureStore.swift local-setup/JournalSmoke.swift \
  -o /tmp/freeflow-journal-smoke
/tmp/freeflow-journal-smoke
```

The local service was verified to reject a cloud-model request with HTTP 403.
Stable designated requirements were checked across a changed signed payload.
Live capture permission, selected-window OCR, interval changes, lock/sleep and
export-panel interaction still require manual verification before merge. Synthetic
OCR/export checks do not establish perfect real-world OCR or timing accuracy.
