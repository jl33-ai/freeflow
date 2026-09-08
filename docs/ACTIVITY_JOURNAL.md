# Local activity journal

Open **Activity Journal…** in the menu bar and enable **Journal enabled**.
The book icon in the menu bar indicates that journaling is enabled. The journal
is off by default and remembers the toggle across launches. It uses the app's
Screen Recording permission; grant that in macOS settings if requested.

The journal reads the foreground window with Apple Vision OCR every 15 seconds
and on app activation. On macOS 14+ it uses ScreenCaptureKit with a 2560-pixel
width cap. macOS 13 uses the legacy single-window API. There is no full-screen
fallback, microphone recording, keyboard logging, or clipboard capture.
Sessions close at app/window changes and about every two minutes. Time is
observed foreground time, not a claim of productive work or completed outcomes.
Two minutes without input counts as idle; lock, sleep and scheduling gaps are
excluded. Window-switch boundaries within an app are approximate to the sampling
interval. Time spent reading without input for over two minutes is also excluded.

## Local inference

Install once on an Apple Silicon Mac:

```sh
brew install ollama
brew services start ollama
ollama pull qwen2.5:3b
```

Only model installation needs internet. The journal always calls the native
Ollama endpoint `http://127.0.0.1:11434/api/chat` with `qwen2.5:3b`. This is separate
from FreeFlow's dictation providers and hybrid router. There are no configurable
remote URLs, redirects, cookies, proxies or cloud fallback. Model weights are
about 1.9 GB; the loaded model uses additional RAM and is kept warm for two minutes.
The service starts at login. Dictation's existing provider configuration is unchanged.

One interpretation runs at a time, with at most four queued sessions. Evidence is
bounded to a first observation and three recent observations, up to 4,500 characters
each. Identical consecutive OCR results are not duplicated. If inference fails
or falls behind, an explicit unclassified entry preserves observed time. Failed
observations are not written to disk or retried after restart.

## Review and privacy

Add daily intentions and planned minutes. A local model suggests intention matches;
edit entries to correct the summary, work category or intention. App name and work
purpose are separate fields. Totals count each session once. Marking a day reviewed
records a review timestamp, not an immutable Git commit. Subsequent changes clear
the marker.

Only summaries, durations, app names, confidence, sample counts, intentions and
review timestamps are saved in `ActivityJournal/journal.json` inside this app's
Application Support directory. The directory is mode 0700 and the file is 0600;
atomic writes replace the prior archive. It is not separately encrypted. The app
retains 30 days. Corrupt files stop recording instead of silently overwriting data.

Screenshots are never written to disk. OCR and window titles stay in memory only
until interpretation. URL/email/path/token redaction runs before inference and
on summaries. The prompt asks for generic people/company roles while retaining
specific technical work. This is best-effort masking, **not guaranteed anonymity**.
The journal intentionally retains specific descriptions of work. Local model
state may remain in RAM until Ollama unloads it.

Password managers and FreeFlow itself are excluded. Add other excluded app names
or bundle IDs as comma-separated text. Private browser detection relies on window
titles and cannot reliably identify every private tab; exclude the whole browser
when needed. Pause from the menu bar at any time. Delete individual sessions or
clear the entire archive from the journal. Clearing also cancels pending work and
pauses collection; it is ordinary file replacement, not secure disk erasure.

## Validation

`make check` includes synthetic tests for idle/gap accounting, redaction,
exclusions, interpretation validation, local endpoint selection, atomic storage,
private file permissions and corrupt files.

For a real local-model test using only a generated text image:

```sh
swiftc -target arm64-apple-macosx13.0 -parse-as-library \
  Sources/ActivityJournalCore.swift Sources/ActivityJournalCapture.swift \
  local-setup/JournalSmoke.swift -o /tmp/freeflow-journal-smoke
/tmp/freeflow-journal-smoke
```

Manual checks before merge: enable on a synthetic document, switch apps/windows,
wait through an idle interval, lock/unlock, sleep/wake, pause during OCR, exclude
an app, edit/delete a session, restart, and check Screen Recording permission
revocation. Confirm the journal is quiet while FreeFlow is foreground. Never use
personal screenshots or journal contents as repository fixtures or build logs.

Implementation validation (2026-09-08): `make check`, full arm64 bundle build,
strict code-signature verification and `git diff --check` passed. The synthetic
OCR + local model smoke test passed, including intention matching and a known
instruction-injection fixture. Warm fixture OCR was about 0.09 seconds and local
interpretation about 1.4 seconds; cold initialization was substantially slower.
These are fixture measurements, not battery or real-workday benchmarks.
The installed process launched with the journal window requested. Live UI and
capture verification remain pending: the desktop inspection service returned
ScreenCaptureKit error -3811 before it could inspect the window. The lock/sleep,
permission and real-window checklist above has not been completed. Do not merge
on the strength of the synthetic tests alone.
