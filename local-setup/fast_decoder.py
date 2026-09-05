"""Accuracy-validated fast path for FreeFlow's Parakeet v2 greedy decoder.

Derived from parakeet-mlx 0.5.2 (Apache-2.0):
https://github.com/senstella/parakeet-mlx/blob/master/parakeet_mlx/parakeet.py
FreeFlow modifications: omit unused confidence, combine host synchronization,
compile predictor/joint steps, and reuse the predictor after blank tokens.
License: licenses/parakeet-mlx-Apache-2.0.txt

Confidence is deliberately 0 (unscored). FreeFlow uses text and timestamps only;
this adapter is not suitable for callers that consume token confidence.
"""
import hashlib
from importlib.metadata import version
from pathlib import Path
from types import MethodType

SOURCE_SHA = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()[:12]
VALIDATED_MODEL = "mlx-community/parakeet-tdt-0.6b-v2"
VALIDATED_VERSIONS = {"parakeet-mlx": "0.5.2", "mlx": "0.31.2"}


class DecoderState:
    """Content-free local health metadata; replace the snapshot atomically."""
    def __init__(self, reason):
        self.set("original", reason)

    def set(self, mode, reason):
        self._summary = {"mode": mode, "reason": reason, "source_sha": SOURCE_SHA}

    def summary(self):
        return dict(self._summary)


def install_fast_decoder(model, model_id, enabled=True):
    """Install only for the tested stack; failures retain the original decoder.

    Called once per freshly loaded model on the service's inference worker.
    A runtime failure disables the fast path for this model's remaining lifetime
    and retries the current request with its original inputs exactly once.
    """
    state = DecoderState("disabled" if not enabled else "unsupported-model")
    if not enabled or model_id != VALIDATED_MODEL:
        return state
    try:
        if any(version(package) != expected for package, expected in VALIDATED_VERSIONS.items()):
            state.set("original", "unsupported-version")
            return state
        import mlx.core as mx
        from parakeet_mlx.alignment import AlignedToken
        from parakeet_mlx import tokenizer
        from parakeet_mlx.parakeet import DecodingConfig, Greedy, ParakeetTDT
        if type(model) is not ParakeetTDT:
            return state
        original = model.decode_greedy

        def predict(token, hidden_state, feature):
            output, (hidden, cell) = model.decoder(token, hidden_state)
            return output.astype(feature.dtype), (hidden.astype(feature.dtype), cell.astype(feature.dtype))

        def joint(feature, output):
            logits = model.joint(feature, output)[0, 0]
            return mx.stack([mx.argmax(logits[:, :len(model.vocabulary) + 1]),
                             mx.argmax(logits[:, len(model.vocabulary) + 1:])])

        predictor = mx.compile(predict)
        joint_step = mx.compile(joint)

        def fast(features, lengths, last_token, hidden_state):
            batch_count, steps, *_ = features.shape
            # Preserve caller-owned lists for retries and independent batches.
            hidden_state = list(hidden_state) if hidden_state is not None else [None] * batch_count
            last_token = list(last_token) if last_token is not None else [None] * batch_count
            lengths = lengths if lengths is not None else mx.array([steps] * batch_count)
            results = []
            for batch in range(batch_count):
                hypothesis, step, new_symbols = [], 0, 0
                feature, length = features[batch:batch + 1], int(lengths[batch])
                cached = None
                while step < length:
                    current = feature[:, step:step + 1]
                    if cached is None:
                        token = mx.array([[last_token[batch]]]) if last_token[batch] is not None else None
                        cached = predictor(token, hidden_state[batch], current)
                    output, next_hidden = cached
                    pred_token, decision = joint_step(current, output).tolist()
                    duration = model.durations[decision]
                    if pred_token != len(model.vocabulary):
                        hypothesis.append(AlignedToken(pred_token,
                            text=tokenizer.decode([pred_token], model.vocabulary),
                            start=step * model.time_ratio, duration=duration * model.time_ratio,
                            confidence=0.0))
                        last_token[batch] = pred_token
                        hidden_state[batch] = next_hidden
                        cached = None
                    # A blank leaves token/state unchanged, so its next predictor
                    # output is identical and can be reused for the next frame.
                    step += duration
                    new_symbols += 1
                    if duration:
                        new_symbols = 0
                    elif model.max_symbols is not None and new_symbols >= model.max_symbols:
                        step += 1
                        new_symbols = 0
                results.append(hypothesis)
            return results, hidden_state

        def decode(self, features, lengths=None, last_token=None, hidden_state=None, *, config=DecodingConfig()):
            if state.summary()["mode"] == "compiled-cache" and isinstance(config.decoding, Greedy):
                try:
                    return fast(features, lengths, last_token, hidden_state)
                except Exception:
                    # Do not log exception payloads: model inputs are sensitive.
                    state.set("original", "runtime-fallback")
            return original(features, lengths, last_token, hidden_state, config=config)

        model.decode_greedy = MethodType(decode, model)
        state.set("compiled-cache", "validated")
    except Exception:
        state.set("original", "setup-fallback")
    return state
