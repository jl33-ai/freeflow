"""Deterministic decoder control-flow tests; no MLX, model weights, or providers."""
from dataclasses import dataclass
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import fast_decoder as d


class Array:
    dtype = "synthetic"

    def __init__(self, value):
        self.value = value

    @property
    def shape(self):
        result, value = [], self.value
        while isinstance(value, list):
            result.append(len(value))
            value = value[0] if value else None
        return tuple(result)

    def __getitem__(self, key):
        def select(value, keys):
            if not keys:
                return value
            head, *tail = keys
            if isinstance(head, slice):
                return [select(v, tail) for v in value[head]]
            return select(value[head], tail)
        return Array(select(self.value, key if isinstance(key, tuple) else (key,)))

    def astype(self, _):
        return self

    def tolist(self):
        return self.value

    def __int__(self):
        return int(self.value)


def flatten(value):
    if isinstance(value, list):
        return [v for item in value for v in flatten(item)]
    return [value]


def argmax(array):
    values = flatten(array.value)
    return Array(max(range(len(values)), key=values.__getitem__))


class Greedy:
    pass


@dataclass
class Token:
    id: int
    text: str
    start: float
    duration: float
    confidence: float


class Model:
    vocabulary = ["one", "two"]
    durations = [0, 1]
    max_symbols = 2
    time_ratio = .08

    def __init__(self, decisions):
        self.decisions = decisions
        self.predict_calls = 0
        self.predict_inputs = []
        self.original_calls = []
        self.fail_on_step = None

    def decoder(self, token, hidden):
        self.predict_calls += 1
        self.predict_inputs.append((token, hidden))
        return Array([0]), (Array(1), Array(2))

    def joint(self, feature, output):
        step = flatten(feature.value)[0]
        if step == self.fail_on_step:
            raise RuntimeError("synthetic private payload")
        token, duration = self.decisions[step]
        scores = [int(i == token) for i in range(3)] + [int(i == duration) for i in range(2)]
        return Array([[[scores]]])

    def decode_greedy(self, *args, **kwargs):
        self.original_calls.append((args, kwargs))
        return "original"


class DecoderTests(unittest.TestCase):
    def setUp(self):
        self.mx = SimpleNamespace(array=Array, argmax=argmax, compile=lambda f: f,
                                  stack=lambda arrays: Array([a.value for a in arrays]))
        modules = {"mlx": SimpleNamespace(core=self.mx), "mlx.core": self.mx,
                   "parakeet_mlx": SimpleNamespace(tokenizer=SimpleNamespace(
                       decode=lambda ids, vocabulary: vocabulary[ids[0]])),
                   "parakeet_mlx.alignment": SimpleNamespace(AlignedToken=Token),
                   "parakeet_mlx.parakeet": SimpleNamespace(Greedy=Greedy, ParakeetTDT=Model,
                       DecodingConfig=lambda: SimpleNamespace(decoding=Greedy()))}
        for mock in [patch.dict("sys.modules", modules),
                     patch.object(d, "version", side_effect=d.VALIDATED_VERSIONS.__getitem__)]:
            mock.start()
            self.addCleanup(mock.stop)

    def install(self, model):
        state = d.install_fast_decoder(model, d.VALIDATED_MODEL)
        self.assertEqual(state.summary()["mode"], "compiled-cache")
        return state

    def test_blank_cache_preserves_tokens_and_resets_after_emission(self):
        model = Model([(2, 1), (2, 1), (0, 1), (2, 1), (1, 1)])
        self.install(model)
        result, state = model.decode_greedy(Array([[[i] for i in range(5)]]))
        self.assertEqual([t.id for t in result[0]], [0, 1])
        self.assertEqual([t.start for t in result[0]], [.16, .32])
        self.assertEqual([t.duration for t in result[0]], [.08, .08])
        self.assertTrue(all(t.confidence == 0 for t in result[0]))
        self.assertEqual(model.predict_calls, 2)
        self.assertIsNone(model.predict_inputs[0][0])
        self.assertEqual(model.predict_inputs[1][0].value, [[0]])
        self.assertIsNotNone(model.predict_inputs[1][1])
        self.assertIsNotNone(state[0])

    def test_zero_duration_guard_terminates_and_lengths_are_respected(self):
        model = Model([(2, 0), (0, 1), (1, 1)])
        self.install(model)
        result, _ = model.decode_greedy(Array([[[0], [1], [2]]]), Array([2]))
        self.assertEqual([t.id for t in result[0]], [0])
        self.assertEqual(model.predict_calls, 1)

    def test_batch_and_call_state_are_independent(self):
        model = Model([(0, 1)])
        self.install(model)
        last, hidden = [None, None], [None, None]
        for _ in range(2):
            result, _ = model.decode_greedy(Array([[[0]], [[0]]]), last_token=last, hidden_state=hidden)
            self.assertEqual([[t.id for t in row] for row in result], [[0], [0]])
        self.assertEqual(model.predict_calls, 4)
        self.assertEqual(last, [None, None])
        self.assertEqual(hidden, [None, None])

    def test_disabled_and_unsupported_model_do_not_touch_decoder(self):
        model = Model([])
        original = model.decode_greedy
        for model_id, enabled, reason in [(d.VALIDATED_MODEL, False, "disabled"),
                                          ("synthetic-other-model", True, "unsupported-model")]:
            state = d.install_fast_decoder(model, model_id, enabled)
            self.assertEqual(state.summary()["reason"], reason)
            self.assertEqual(model.decode_greedy, original)

    def test_unvalidated_library_versions_use_original(self):
        for changed_package in d.VALIDATED_VERSIONS:
            versions = {**d.VALIDATED_VERSIONS, changed_package: "999.0.0"}
            model = Model([])
            original = model.decode_greedy
            with patch.object(d, "version", side_effect=versions.__getitem__):
                state = d.install_fast_decoder(model, d.VALIDATED_MODEL)
            self.assertEqual(state.summary()["reason"], "unsupported-version")
            self.assertEqual(model.decode_greedy, original)

    def test_unvalidated_model_class_uses_original(self):
        class DifferentModel(Model):
            pass
        model = DifferentModel([])
        original = model.decode_greedy
        state = d.install_fast_decoder(model, d.VALIDATED_MODEL)
        self.assertEqual(state.summary()["reason"], "unsupported-model")
        self.assertEqual(model.decode_greedy, original)

    def test_non_greedy_config_uses_original_without_disabling(self):
        model = Model([])
        state = self.install(model)
        self.assertEqual(model.decode_greedy(None, config=SimpleNamespace(decoding="beam")), "original")
        self.assertEqual(state.summary()["mode"], "compiled-cache")

    def test_compile_setup_failure_preserves_original(self):
        model = Model([])
        original = model.decode_greedy
        with patch.object(self.mx, "compile", side_effect=RuntimeError("synthetic private payload")):
            state = d.install_fast_decoder(model, d.VALIDATED_MODEL)
        self.assertEqual(state.summary()["reason"], "setup-fallback")
        self.assertEqual(model.decode_greedy, original)

    def test_partial_failure_retries_original_inputs_and_disables_fast_path(self):
        model = Model([(0, 1), (1, 1)])
        model.fail_on_step = 1  # Fails after a token has updated speculative state.
        state = self.install(model)
        features, last, hidden = Array([[[0], [1]]]), [None], [None]
        self.assertEqual(model.decode_greedy(features, last_token=last, hidden_state=hidden), "original")
        self.assertEqual(last, [None])
        self.assertEqual(hidden, [None])
        self.assertIs(model.original_calls[0][0][0], features)
        self.assertIs(model.original_calls[0][0][2], last)
        self.assertIs(model.original_calls[0][0][3], hidden)
        self.assertEqual(state.summary(), {"mode": "original", "reason": "runtime-fallback", "source_sha": d.SOURCE_SHA})
        calls = model.predict_calls
        model.decode_greedy(features)
        self.assertEqual(model.predict_calls, calls)
        self.assertEqual(len(model.original_calls), 2)

    def test_original_failure_is_not_retried_recursively(self):
        model = Model([(0, 1)])
        with patch.object(model, "decode_greedy", side_effect=ValueError("synthetic original failure")) as original:
            self.install(model)
            model.fail_on_step = 0
            with self.assertRaises(ValueError):
                model.decode_greedy(Array([[[0]]]))
            original.assert_called_once()


if __name__ == "__main__":
    unittest.main()
