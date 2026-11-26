import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import build_dicts  # noqa: E402
import build_lm  # noqa: E402
import evaluate_lm  # noqa: E402
from lm_common import KdictVocabulary, normalize_text, tokenize_sentence, vocab_fingerprint  # noqa: E402

import klm_format  # noqa: E402

CORPUS = [
    "Thank you very much.",
    "Thank you for coming.",
    "Thank you so much, really.",
    "I want to go home.",
    "I want to eat now.",
    "I want to sleep.",
    "We want to go out.",
    "I don't know.",
    "I don't think so.",
    "I don't know why.",
    "You know what I mean.",
    "The cat is on the mat.",
    "The dog is in the house.",
    "Go home now.",
    "I want some of the cake.",
    "Talk to the man.",
    "Walk to the shop.",
    "Go to the park.",
]


class TokenizerTests(unittest.TestCase):
    def test_breaks_on_punctuation_and_digits(self):
        tokens = tokenize_sentence(normalize_text("I don’t know, 42 cats"), "en")
        self.assertEqual(tokens, ["i", "don't", "know", None, "cats"])

    def test_keeps_hyphenated_russian(self):
        tokens = tokenize_sentence(normalize_text("Что-то всё-таки"), "ru")
        self.assertEqual(tokens, ["что-то", "всё-таки"])

    def test_rejects_wrong_script(self):
        tokens = tokenize_sentence(normalize_text("hello мир friend"), "en")
        self.assertEqual(tokens, ["hello", None, "friend"])


class FingerprintTests(unittest.TestCase):
    def test_any_swap_changes_fingerprint(self):
        words = [f"w{index}" for index in range(500)]
        swapped = list(words)
        swapped[201], swapped[202] = swapped[202], swapped[201]
        strings_length = sum(len(word) for word in words)
        self.assertNotEqual(
            vocab_fingerprint(KdictVocabulary(words, strings_length)),
            vocab_fingerprint(KdictVocabulary(swapped, strings_length)),
        )


class DiscountTests(unittest.TestCase):
    def test_discounts_in_range(self):
        counts = [1] * 50 + [2] * 20 + [3] * 10 + [4] * 6 + [9] * 5
        d1, d2, d3 = build_lm.discounts(counts)
        self.assertTrue(0 < d1 < 1 and 0 < d2 < 2 and 0 < d3 < 3)
        self.assertLess(d1, d2)

    def test_fallback_when_counts_sparse(self):
        self.assertEqual(build_lm.discounts([1, 1, 5]), (0.5, 1.0, 1.5))


class ModelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        root = Path(cls.temp.name)
        corpus_dir = root / "corpora" / "en"
        corpus_dir.mkdir(parents=True)
        (corpus_dir / "sample.txt").write_text("\n".join(CORPUS * 3) + "\n", encoding="utf-8")
        build_lm.build_wordlist("en", root / "corpora", root / "sources", 1000, 1)
        kdict = root / "en.kdict"
        build_dicts.compile_dictionary(root / "sources" / "en.tsv", kdict, 1000)
        cls.kdict = kdict
        cls.vocab = {word: index for index, word in enumerate(
            build_lm.read_kdict_vocabulary(kdict).words
        )}
        cls.model = build_lm.build_model(
            "en",
            build_lm.corpus_files(root / "corpora", "en"),
            kdict,
            build_lm.Budget(10_000, 1_000, 10_000),
            min_count=1,
            log=lambda _line: None,
        )

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def _distribution(self, prev1, prev2=None):
        model = self.model
        return {
            word: build_lm.model_probability(model, index, prev1, prev2)
            for word, index in self.vocab.items()
        }

    def test_unigram_normalizes(self):
        self.assertAlmostEqual(sum(self._distribution(None).values()), 1.0, places=6)

    def test_bigram_context_normalizes(self):
        total = sum(self._distribution(self.vocab["thank"]).values())
        self.assertAlmostEqual(total, 1.0, places=6)

    def test_trigram_context_normalizes(self):
        total = sum(self._distribution(self.vocab["to"], self.vocab["want"]).values())
        self.assertAlmostEqual(total, 1.0, places=6)

    def test_thank_predicts_you(self):
        distribution = self._distribution(self.vocab["thank"])
        self.assertEqual(max(distribution, key=distribution.get), "you")

    def test_trigram_overrides_bigram(self):
        after_to = self._distribution(self.vocab["to"])
        after_want_to = self._distribution(self.vocab["to"], self.vocab["want"])
        self.assertGreater(after_to["the"], after_to["go"])
        self.assertGreater(after_want_to["go"], after_want_to["the"])

    def test_tight_budget_prunes_and_still_normalizes(self):
        root = Path(self.temp.name)
        model = build_lm.build_model(
            "en",
            build_lm.corpus_files(root / "corpora", "en"),
            self.kdict,
            build_lm.Budget(6, 2, 3),
            min_count=1,
            log=lambda _line: None,
        )
        self.assertLessEqual(sum(map(len, model.bigrams.values())), 6)
        self.assertLessEqual(sum(map(len, model.trigrams.values())), 3)
        for context in list(model.bigrams)[:3]:
            total = sum(
                build_lm.model_probability(model, index, context, None) for index in self.vocab.values()
            )
            self.assertAlmostEqual(total, 1.0, places=6)

    def test_sentence_start_context(self):
        bos = self.model.vocab_count
        distribution = self._distribution(bos)
        self.assertEqual(max(distribution, key=distribution.get), "i")

    def test_comma_breaks_context(self):
        # "much, really" must not produce a much -> really bigram.
        rows = {row[0] for row in self.model.bigrams.get(self.vocab["much"], [])}
        self.assertNotIn(self.vocab["really"], rows)

    def test_round_trip_through_klm(self):
        path = Path(self.temp.name) / "en.klm"
        klm_format.write_klm(self.model, path)
        reader = klm_format.read_klm(path)
        self.assertEqual(reader.vocab_count, self.model.vocab_count)
        context = reader.prepare_context(self.vocab["thank"], None)
        top = reader.top_next_words(context, 1)
        self.assertEqual(top[0][0], self.vocab["you"])


class EvaluationSplitTests(unittest.TestCase):
    def test_held_out_sentences_never_reach_training(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "corpus.txt"
            sentences = [f"Sentence {index} is here." for index in range(2000)]
            path.write_text("\n".join(sentences), encoding="utf-8")
            training = sum(1 for _ in build_lm.iter_language_sentences(path, "en"))
            held_out = sum(1 for _ in build_lm.iter_language_sentences(path, "en", held_out=True))
        self.assertGreater(held_out, 0)
        self.assertEqual(training + held_out, len(sentences))
        self.assertEqual(held_out, sum(build_lm.is_held_out(sentence) for sentence in sentences))

    def test_copies_differing_in_case_or_spacing_share_a_side(self):
        for index in range(200):
            sentence = f"I don't know {index} things."
            variant = f"  i  DON’T know {index}   things."
            self.assertEqual(build_lm.is_held_out(sentence), build_lm.is_held_out(variant), sentence)

    def test_taps_to_enter_counts_letters_before_the_word_shows(self):
        shown_after_two = lambda prefix: ["hello"] if prefix == "he" else []  # noqa: E731
        self.assertEqual(evaluate_lm.taps_to_enter("hello", shown_after_two), 3)
        self.assertEqual(evaluate_lm.taps_to_enter("hello", lambda prefix: []), 6)
        self.assertEqual(evaluate_lm.taps_to_enter("hello", lambda prefix: ["hello"]), 1)


if __name__ == "__main__":
    unittest.main()
