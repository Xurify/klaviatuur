"""Unit tests for Scripts/klm_format.py."""

from __future__ import annotations

import copy
import math
import struct
import tempfile
import unittest
from pathlib import Path

from klm_format import (
    BIGRAM_STRUCT,
    HEADER_STRUCT,
    KLMModel,
    KLMReader,
    MAX_BIGRAMS_PER_CONTEXT,
    MAX_TRIGRAMS_PER_CONTEXT,
    MAX_VOCAB,
    TRIGRAM_CONTEXT_STRUCT,
    TRIGRAM_STRUCT,
    UNIGRAM_STRUCT,
    read_klm,
    serialize_klm,
    write_klm,
)
from lm_common import KdictVocabulary, vocab_fingerprint

# Shared test vocabulary mirrored in BinaryLanguageModelTests.swift:
# 0: "i", 1: "want", 2: "to", 3: "of", 4: "you", 5: "thank", 6: <BOS>
SAMPLE_VOCAB_COUNT = 6
SAMPLE_FINGERPRINT = 0x0123456789ABCDEF


def _make_sample_model() -> KLMModel:
    return KLMModel(
        vocab_count=SAMPLE_VOCAB_COUNT,
        vocab_fingerprint=SAMPLE_FINGERPRINT,
        unigram_log_prob=[-1.2, -2.0, -1.5, -1.6, -1.8, -2.4, -99.0],
        unigram_log_bow=[-0.3, -0.4, None, None, None, -0.5, -0.2],
        bigrams={
            # Unsorted inputs verify the serializer sorts by next_id ascending.
            6: [(5, -1.1, -0.35), (0, -0.6, -0.25)],
            0: [(1, -0.8, 0.45), (5, -2.2, None)],
            1: [(3, -1.4, None), (2, -0.5, None), (4, -0.9, None)],
            5: [(4, -0.2, None)],
        },
        trigrams={
            (6, 0): [(5, -1.9), (1, -0.4)],
            (6, 5): [(4, -0.15)],
            (0, 1): [(2, -0.3)],
            (0, 5): [],
        },
    )


def _patch(blob: bytes, fmt: str, offset: int, *values: object) -> bytes:
    patched = bytearray(blob)
    struct.pack_into(fmt, patched, offset, *values)
    return bytes(patched)


class KLMFormatTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sample_model = _make_sample_model()
        cls.sample_blob = serialize_klm(cls.sample_model)
        cls.sample_reader = KLMReader(cls.sample_blob)

    def test_round_trip_and_quantization_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output_path = Path(directory) / "sample.klm"
            written = write_klm(self.sample_model, output_path)
            self.assertEqual(written, output_path.stat().st_size)
            reader = read_klm(output_path)

        self.assertEqual(reader.vocab_count, SAMPLE_VOCAB_COUNT)
        self.assertEqual(reader.vocab_fingerprint, SAMPLE_FINGERPRINT)
        self.assertEqual(reader.bigram_count, 8)
        self.assertEqual(reader.trigram_context_count, 3)
        self.assertEqual(reader.trigram_count, 4)

        prob_step = (self.sample_model.max_log_prob - self.sample_model.min_log_prob) / 255.0
        for word_id, expected in enumerate(self.sample_model.unigram_log_prob[:-1]):
            self.assertLessEqual(abs(reader.unigram_log_probability(word_id) - expected), prob_step / 2.0 + 1e-6)

        _, bos_prob_q, _, _ = UNIGRAM_STRUCT.unpack_from(
            reader.data, reader.unigrams_offset + SAMPLE_VOCAB_COUNT * UNIGRAM_STRUCT.size
        )
        self.assertEqual(bos_prob_q, 0)

        context_i_want = reader.prepare_context(prev1=1, prev2=0)
        log_prob, order = reader.log_probability(2, context_i_want)
        self.assertEqual(order, 3)
        self.assertLessEqual(abs(log_prob - (-0.3)), prob_step / 2.0 + 1e-6)

        context_thank = reader.prepare_context(prev1=5, prev2=None)
        log_prob, order = reader.log_probability(4, context_thank)
        self.assertEqual(order, 2)
        self.assertLessEqual(abs(log_prob - (-0.2)), prob_step / 2.0 + 1e-6)

    def test_bos_context_and_bos_trigrams(self) -> None:
        reader = self.sample_reader

        bos_context = reader.prepare_context(prev1=SAMPLE_VOCAB_COUNT, prev2=None)
        self.assertTrue(bos_context.has_bigram and not bos_context.has_trigram)
        top_bos = reader.top_next_words(bos_context, limit=5)
        self.assertEqual([word_id for word_id, _, _ in top_bos], [0, 5])
        self.assertTrue(all(order == 2 for _, _, order in top_bos))

        for prev1, target_id, expected_prob in ((0, 1, -0.4), (5, 4, -0.15)):
            context = reader.prepare_context(prev1=prev1, prev2=SAMPLE_VOCAB_COUNT)
            self.assertTrue(context.has_trigram)
            log_prob, order = reader.log_probability(target_id, context)
            self.assertEqual(order, 3)
            self.assertAlmostEqual(log_prob, expected_prob, delta=0.02)

    def test_backoff_chain_sentinels_and_oov(self) -> None:
        reader = self.sample_reader

        context_i_want = reader.prepare_context(prev1=1, prev2=0)
        self.assertGreater(context_i_want.trigram_log_bow, 0.4)

        prob_you, order_you = reader.log_probability(4, context_i_want)
        self.assertEqual(order_you, 2)
        expected_you = min(0.0, context_i_want.trigram_log_bow + reader.decode_log_prob(round((-0.9 + 8.0) / 8.0 * 255)))
        self.assertAlmostEqual(prob_you, expected_you, places=6)
        self.assertGreater(prob_you, -0.6)

        prob_i, order_i = reader.log_probability(0, context_i_want)
        self.assertEqual(order_i, 1)
        expected_i = context_i_want.trigram_log_bow + context_i_want.bigram_log_bow + reader.unigram_log_probability(0)
        self.assertAlmostEqual(prob_i, expected_i, places=6)

        context_i_thank = reader.prepare_context(prev1=5, prev2=0)
        self.assertTrue(context_i_thank.has_bigram and not context_i_thank.has_trigram)
        self.assertEqual(context_i_thank.trigram_log_bow, 0.0)

        context_to = reader.prepare_context(prev1=2, prev2=None)
        self.assertTrue(context_to.is_empty)
        self.assertEqual(reader.top_next_words(context_to, limit=3), [])
        self.assertEqual(reader.context_lift(0, context_to), 0.0)

        self.assertEqual(reader.log_probability(99, context_i_want), (reader.min_log_prob, 0))
        self.assertEqual(reader.context_lift(99, context_i_want), 0.0)
        self.assertTrue(reader.prepare_context(prev1=99, prev2=0).is_empty)

    def test_positive_bow_clamps_backed_off_bigram_at_zero(self) -> None:
        model = KLMModel(
            vocab_count=3,
            vocab_fingerprint=1,
            unigram_log_prob=[-1.0, -1.0, -1.0, 0.0],
            unigram_log_bow=[-0.1, -0.1, None, None],
            bigrams={0: [(1, -0.2, 1.5)], 1: [(0, -0.1, None), (2, -0.5, None)]},
            trigrams={(0, 1): [(2, -0.3)]},
        )
        reader = KLMReader(serialize_klm(model))
        context = reader.prepare_context(prev1=1, prev2=0)
        self.assertEqual(reader.log_probability(0, context), (0.0, 2))

    def test_top_next_words_dedupes_trigram_and_bigram(self) -> None:
        context_i_want = self.sample_reader.prepare_context(prev1=1, prev2=0)
        predictions = self.sample_reader.top_next_words(context_i_want, limit=5)
        self.assertEqual([word_id for word_id, _, _ in predictions], [2, 4, 3])
        self.assertEqual([order for _, _, order in predictions], [3, 2, 2])

        # A trigram that misses top-limit must still suppress its higher-scoring backed-off bigram.
        model = KLMModel(
            vocab_count=4,
            vocab_fingerprint=2,
            unigram_log_prob=[-1.0, -1.0, -1.0, -1.0, 0.0],
            unigram_log_bow=[-0.1, -0.1, None, None, None],
            bigrams={0: [(1, -0.2, 1.0)], 1: [(2, -0.2, None), (3, -0.8, None)]},
            trigrams={(0, 1): [(2, -3.0), (3, -0.5)]},
        )
        reader = KLMReader(serialize_klm(model))
        top_one = reader.top_next_words(reader.prepare_context(prev1=1, prev2=0), limit=1)
        self.assertEqual([(word_id, order) for word_id, _, order in top_one], [(3, 3)])

    def test_context_lift_clamping(self) -> None:
        context_thank = self.sample_reader.prepare_context(prev1=5, prev2=None)
        self.assertAlmostEqual(self.sample_reader.context_lift(4, context_thank), 1.6, delta=0.05)

        extreme_model = KLMModel(
            vocab_count=3,
            vocab_fingerprint=3,
            unigram_log_prob=[-0.1, -6.0, -0.1, 0.0],
            unigram_log_bow=[-3.0, None, None, None],
            bigrams={0: [(1, -0.1, None)]},
            trigrams={},
        )
        extreme_reader = KLMReader(serialize_klm(extreme_model))
        context = extreme_reader.prepare_context(prev1=0, prev2=None)
        self.assertEqual(extreme_reader.context_lift(1, context), 2.5)
        self.assertEqual(extreme_reader.context_lift(2, context), -1.5)

    def test_reader_rejects_corrupted_inputs(self) -> None:
        valid = self.sample_blob
        reader = self.sample_reader
        unigram_sentinel_offset = reader.unigrams_offset + (SAMPLE_VOCAB_COUNT + 1) * UNIGRAM_STRUCT.size
        trigram_context_sentinel_offset = (
            reader.trigram_contexts_offset + reader.trigram_context_count * TRIGRAM_CONTEXT_STRUCT.size
        )

        cases: list[tuple[str, bytes]] = [
            ("truncated header", valid[: HEADER_STRUCT.size - 1]),
            ("bad magic", b"NOPE" + valid[4:]),
            ("unsupported version", _patch(valid, "<H", 4, 2)),
            ("unsupported flags", _patch(valid, "<H", 6, 1)),
            ("nan quantization bound", _patch(valid, "<f", 48, math.nan)),
            ("min_log_prob >= max_log_prob", _patch(valid, "<ff", 48, 0.0, -8.0)),
            ("min_log_bow >= max_log_bow", _patch(valid, "<ff", 56, 2.0, 2.0)),
            ("bad unigrams offset", _patch(valid, "<I", 32, 68)),
            ("truncated body", valid[:-1]),
            ("trailing byte", valid + b"\x00"),
            ("corrupted unigram sentinel", _patch(valid, "<I", unigram_sentinel_offset, 999)),
            ("corrupted trigram context sentinel", _patch(valid, "<I", trigram_context_sentinel_offset, 0x12345678)),
            ("non-zero unigram reserved", _patch(valid, "<H", reader.unigrams_offset + 6, 1)),
            ("non-zero bos prob_q", _patch(valid, "<B", reader.unigrams_offset + SAMPLE_VOCAB_COUNT * UNIGRAM_STRUCT.size + 4, 1)),
            ("non-monotonic bigram_start", _patch(valid, "<I", reader.unigrams_offset + 2 * UNIGRAM_STRUCT.size, 0)),
            ("unsorted bigram slice", _patch(valid, "<H", reader.bigrams_offset, 5)),
            ("bigram next_id out of range", _patch(valid, "<H", reader.bigrams_offset, SAMPLE_VOCAB_COUNT)),
            ("non-zero trigram reserved", _patch(valid, "<B", reader.trigrams_offset + 3, 1)),
            ("unsorted trigram slice", _patch(valid, "<H", reader.trigrams_offset + TRIGRAM_STRUCT.size, 5)),
            ("unsorted trigram contexts", _patch(valid, "<I", reader.trigram_contexts_offset + TRIGRAM_CONTEXT_STRUCT.size, 0)),
            ("trigram_bow_q mismatch with table 3", _patch(valid, "<B", reader.bigrams_offset + BIGRAM_STRUCT.size + 3, 10)),
        ]
        for label, payload in cases:
            with self.subTest(case=label):
                with self.assertRaises(ValueError):
                    KLMReader(payload)

    def test_writer_rejects_invalid_models(self) -> None:
        bigram_vocab = MAX_BIGRAMS_PER_CONTEXT + 2
        trigram_vocab = MAX_TRIGRAMS_PER_CONTEXT + 2

        missing_parent = copy.deepcopy(self.sample_model)
        missing_parent.trigrams[(2, 3)] = [(4, -1.0)]

        none_bow_parent = copy.deepcopy(self.sample_model)
        none_bow_parent.trigrams[(0, 5)] = [(4, -1.0)]

        cases: list[tuple[str, KLMModel]] = [
            (
                "bigram slice cap",
                KLMModel(
                    vocab_count=bigram_vocab,
                    vocab_fingerprint=0,
                    unigram_log_prob=[-2.0] * (bigram_vocab + 1),
                    unigram_log_bow=[None] * (bigram_vocab + 1),
                    bigrams={0: [(word_id, -3.0, None) for word_id in range(MAX_BIGRAMS_PER_CONTEXT + 1)]},
                    trigrams={},
                ),
            ),
            (
                "trigram slice cap",
                KLMModel(
                    vocab_count=trigram_vocab,
                    vocab_fingerprint=0,
                    unigram_log_prob=[-2.0] * (trigram_vocab + 1),
                    unigram_log_bow=[-0.1] + [None] * trigram_vocab,
                    bigrams={0: [(1, -1.0, -0.2)]},
                    trigrams={(0, 1): [(word_id, -2.0) for word_id in range(MAX_TRIGRAMS_PER_CONTEXT + 1)]},
                ),
            ),
            (
                "vocab count cap",
                KLMModel(
                    vocab_count=MAX_VOCAB + 1,
                    vocab_fingerprint=0,
                    unigram_log_prob=[],
                    unigram_log_bow=[],
                    bigrams={},
                    trigrams={},
                ),
            ),
            ("missing parent bigram", missing_parent),
            ("parent bigram has log_bow=None", none_bow_parent),
        ]
        for label, model in cases:
            with self.subTest(case=label):
                with self.assertRaises(ValueError):
                    serialize_klm(model)

    def test_fingerprint_mismatch_detected_on_swapped_words(self) -> None:
        vocab_a = KdictVocabulary(words=["the", "and", "you", "thank"], strings_length=14)
        vocab_b = KdictVocabulary(words=["and", "the", "you", "thank"], strings_length=14)
        self.assertNotEqual(vocab_fingerprint(vocab_a), vocab_fingerprint(vocab_b))


if __name__ == "__main__":
    unittest.main()
