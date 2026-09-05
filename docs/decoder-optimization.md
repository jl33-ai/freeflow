# Local decoder optimization

FreeFlow's local Parakeet service now uses the accuracy-preserving decoder from
the September 5, 2026 experiments. The change applies to both streaming and
complete-file transcription. It does not change model weights, precision,
streaming context, partial cadence, settlement rules, or transcript cleanup.

## Implementation

`local-setup/fast_decoder.py` compiles the predictor and joint steps, combines
token/duration synchronization, and reuses predictor output after a blank token.
It removes entropy confidence calculations because the service consumes only
text and timestamps. Confidence values from this adapter are unscored zeros.
The derivative includes the upstream Apache 2.0 license.

The adapter is scoped to `mlx-community/parakeet-tdt-0.6b-v2`, the Parakeet TDT
class, `parakeet-mlx` 0.5.2, and MLX 0.31.2. Untested versions and models keep
the original decoder. A setup failure also keeps the original. If optimized
inference fails, the current request retries once with its original inputs and
all later requests use the original decoder until restart. Exceptions are not
logged by the adapter.

Set `STT_FAST_DECODER=0` before starting the service to disable optimization.
`/health` reports `decoder.mode`, `decoder.reason`, and `decoder.source_sha`.
These fields contain only implementation state, without user content. Deployment
copies and verifies both the server and decoder source; the module and license
must accompany any manual server update.

## Accuracy and model timing

On September 5, 2026, the production implementation was compared directly with
the original decoder using the same loaded model. The corpus was 200
speaker-balanced LibriSpeech test-clean clips and 200 test-other clips: 73
speakers, 49.15 minutes, and 7,973 reference words. Execution order alternated
original/optimized and optimized/original between clips after warming both.
Audio conversion and scoring were outside the inference timer.

| Decoder | Model p50 | Model p95 | WER | Word errors |
|---|---:|---:|---:|---:|
| Original | 88.5 ms | 197.4 ms | 2.784% | 222 |
| Optimized | 72.6 ms | 148.7 ms | 2.784% | 222 |

All 800 calls succeeded. **All 400 full transcripts, token IDs, and token
timestamps matched exactly.** The measured median reduction is 18%, with a
25% reduction at p95. These are model-processing times on an Apple M4 Pro
with 24 GiB RAM, not physical key-release-to-paste times. They do not prove
equivalence on every utterance, language, or future library version.

Public speech is from [OpenSLR 12](https://www.openslr.org/12), with attribution
and CC BY 4.0 licensing retained in the prepared corpus. This validation reuses
the experiment corpus, so it checks the implementation port rather than serving
as a new held-out accuracy study. No private recordings or transcripts were used.

## Running-product validation

The installed FreeFlow Dev configuration uses the local STT service on port
8082. A paced replay using the production Swift transcription client compares
the installed service before and after deployment. The same eight public and
synthetic clips are replayed twice in matched order, including short/long speech
and silence. This measures commit-to-final raw transcription, excluding actual
microphone shutdown, keyboard shortcuts, cleanup, and paste.

| Installed service | Mean delay | p50 delay | p95 delay | Word errors |
|---|---:|---:|---:|---:|
| Before | 155.7 ms | 114.4 ms | 335.9 ms | 20/384 |
| Optimized | 140.2 ms | 111.5 ms | 285.9 ms | 20/384 |

All 32 scored streaming calls succeeded, every paired word-error count matched,
and neither pass hallucinated words in the two silence calls. Average delay
fell 10%; p50 changed only 3 ms. Percentiles use nearest rank, making p95 the
worst call in each small 16-call pass. This is a development-machine sample,
not a broad tail-latency claim. The two phases ran sequentially with matching
clip order; background service activity and thermal drift were not controlled.

The existing STT launch agent was updated and restarted after checking it had
no active session. Server source `a3c0b40239ee` and decoder source
`a1f25b1508fe` were verified against the running health response. The decoder
remained `compiled-cache` / `validated` through the entire after-update replay.
The prior files were held in memory for rollback if startup verification failed;
the update succeeded. The app process and its realtime setting were confirmed
active. No app rebuild, router restart, or settings change was needed.

## Verification and retained artifacts

`make check` covers the app's Swift type-check and deterministic tests, plist,
shell/YAML validation, and ten dependency-free decoder tests. The local STT
suite also passes 19 synthetic protocol tests, including the active decoder's
health response. Tests cover blank reuse/invalidation, token timing, termination,
independent batches/calls, version/model gating, setup fallback, and a failure
after partial state changes that must retry the untouched original inputs once.

Reusable numeric reports remain outside the repository in
`~/.cache/freeflow-benchmark/results/`:

- `decoder-production-parity-20260905.json`
- `decoder-production-live-before-20260905.json`
- `decoder-production-live-after-20260905.json`

The benchmark harness and prior experimental results are maintained separately
in [benchmark PR #3](https://github.com/linustalacko/freeflow/pull/3) and
[experiment PR #4](https://github.com/linustalacko/freeflow/pull/4). For future
comparisons, explicitly disable the production fast decoder when measuring the
original baseline. Source hashes and per-clip numeric errors are in the reports;
reference text, hypothesis text, audio, and token payloads are excluded.

No app rebuild, permission change, credential change, release, or new data
transmission is needed. Physical microphone/shortcut/paste verification remains
a separate manual check before merge. The rejected quantization, short-context,
and experimental cache settings are not activated.
