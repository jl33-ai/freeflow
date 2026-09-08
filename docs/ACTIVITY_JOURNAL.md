# Git for Work (Den)

Copy today's commits (menu) and Copy all (window) copy only completed local-model
summaries, oldest first, with local time, UTC offset and app name:

```
9:32am +10:00 · Synthetic Editor: Reviewed export timing and repeated final frames.
```

Copy prepends the user's instruction verbatim:

> Summarize what I worked on today, one very short easy to read dotpoint for each, broken by time. You will see timestamps + app name + summary
>
> E.g. - worked on stories (2hrs)

No raw OCR, window title, JSON, or system metadata is included. Pending, failed,
interrupted and skipped descriptions are excluded. An empty day leaves the clipboard
unchanged and shows “No completed LLM summaries for this day”. Day selection and
formatting use the current local timezone and its daylight-saving rules.

Screenshots are processed in memory and given directly to Qwen3.5 9B on loopback
Ollama (`127.0.0.1:11436`). Settings has a persistent segmented switch: Use OCR / Use Vision Model. OCR is
the default. Vision sends the PNG directly to Qwen3.5 9B; OCR uses Apple Vision in
memory and supplies up to 18,000 characters to local Qwen2.5 3B without attaching
an image. The selected mode is fixed for each capture even if the switch changes
while it is processing. Both modes save only summaries. Neither OCR text nor screenshot files are
saved. Only index data (time/app/status) and model inference (summary/category/
confidence/model/status) are persisted. No source window titles or other raw context
are saved. At startup legacy screenshot.png, ocr.txt and observation.json files
(including embedded OCR) are removed from the feature's data folder; summaries are
preserved. Previously exported user copies outside that folder are not touched.

The data path remains `~/Library/Application Support/FreeFlow Dev/GitForWorkRaw`
for compatibility. Directory permissions are 0700, JSON 0600. Screenshot buffers
are released after processing/failure; macOS controls memory and swap. One description
runs at a time. Busy captures are marked skipped instead of retaining an image queue.
The default interval is 60 seconds, configurable from 5–300. Locked, sleeping, own,
private and excluded windows are skipped. The daily count includes captured images,
including those whose summaries fail or are skipped.

The dedicated model runtime has cloud disabled and no remote fallback, redirects,
proxy, cookies, URL cache or runtime log files. Model download requires internet;
processing has no API fees. FreeFlow speech-to-text remains available under Dictation
with its existing shortcuts and independent provider settings. Stable app identity,
install path and signing preserve data/permissions across updates.

Validation: make check exercises summary-only persistence/copy formatting, absence
of source data, idempotent source cleanup preserving summaries/unrelated files,
failed/other-day filtering, a private pasteboard round-trip, icon alpha and the
existing speech/hotkey/provider tests. git diff --check must pass.

The optional local-setup/JournalSmoke.swift uses generated images only, including
an unlabeled color/shape canvas proving image input is used. Never print actual
capture content or clipboard data during testing. Native UI, live microphone/paste
and screen permission/timing still require manual verification before merge.

Validated locally on the 24 GB M4 Pro with Qwen3.5 9B installed: synthetic work
screenshot description completed in 32.2 seconds (first request), and an unlabeled
blue-circle/orange-bars image was correctly described in 13.9 seconds. Synthetic
instruction-injection smoke also passed. These measurements are limited examples,
not guaranteed latency for all screenshots. Source-file cleanup was verified by
filename counts only: zero screenshot.png, ocr.txt or observation.json remaining.

The default installer downloads only Qwen2.5 3B. Qwen3.5 9B was removed from this
Mac at the user's request; selecting Vision later requires installing it manually.
The current saved preference is OCR. No screenshots or OCR text are retained.
