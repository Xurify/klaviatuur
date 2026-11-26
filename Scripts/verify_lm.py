#!/usr/bin/env python3
"""Verify compiled Klaviatuur .klm language models.

    python3 Scripts/verify_lm.py [--dir PATH] [--golden]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from klm_format import KLMReader, PreparedContext, read_klm
from lm_common import read_kdict_vocabulary, vocab_fingerprint

MAX_PRODUCTION_KLM_BYTES = int(3.5 * 1024 * 1024)

GOLDEN_NEXT_WORD_CASES: dict[str, list[tuple[tuple[str, ...], set[str], int]]] = {
    # Chat phrases such as "ako sa máš" or "kuidas läheb" are rare in the news and web
    # corpora, so these cases stick to collocations every register shares.
    "en": [
        (("thank",), {"you"}, 3),
        (("i", "don't"), {"know", "think", "want"}, 3),
        (("how", "are"), {"you"}, 3),
    ],
    "sk": [
        (("ďakujem",), {"za", "vám", "veľmi"}, 3),
        (("dobrý",), {"deň"}, 3),
    ],
    "cs": [
        (("děkuji",), {"za", "moc", "vám"}, 3),
        (("to",), {"je"}, 3),
        (("mám", "se"), {"dobře"}, 3),
    ],
    "et": [
        (("ma", "ei"), {"tea", "ole", "saa"}, 3),
        (("kõik",), {"on"}, 3),
        (("tere",), {"tulemast", "hommikust"}, 3),
    ],
    "ru": [
        (("я", "не"), {"знаю", "могу"}, 3),
        (("у", "меня"), {"нет", "есть"}, 3),
        (("спасибо",), {"за", "большое", "вам"}, 3),
    ],
}

GOLDEN_RANKING_CASES: dict[str, list[tuple[tuple[str, ...], str, str]]] = {
    "en": [
        (("i", "want"), "to", "of"),
    ],
    # No case favouring "всё": news text mostly writes it as "все", so the corpora cannot
    # separate the two until ё is restored at build time.
    "ru": [
        (("почти",), "все", "всё"),
    ],
}


def _prepare_context(
    reader: KLMReader, word_to_id: dict[str, int], context_words: tuple[str, ...]
) -> tuple[PreparedContext | None, str | None]:
    ids: list[int] = []
    for word in context_words:
        word_id = word_to_id.get(word)
        if word_id is None:
            return None, word
        ids.append(word_id)
    prev1 = ids[-1]
    prev2 = ids[-2] if len(ids) == 2 else None
    return reader.prepare_context(prev1=prev1, prev2=prev2), None


def verify_golden_predictions(
    language: str, reader: KLMReader, words: list[str], word_to_id: dict[str, int]
) -> None:
    for context_words, expected_words, top_k in GOLDEN_NEXT_WORD_CASES.get(language, []):
        prepared, missing = _prepare_context(reader, word_to_id, context_words)
        if prepared is None:
            raise AssertionError(
                f"[{language}] cannot check golden next-word {context_words} "
                f"(context word {missing!r} missing from .kdict)"
            )
        present_expected = {word for word in expected_words if word in word_to_id}
        if not present_expected:
            raise AssertionError(
                f"[{language}] cannot check golden next-word {context_words} "
                f"(expected {sorted(expected_words)} missing from .kdict)"
            )
        predicted_words = [words[word_id] for word_id, _, _ in reader.top_next_words(prepared, limit=top_k)]
        assert any(word in present_expected for word in predicted_words), (
            f"[{language}] Golden failure for {' '.join(context_words)!r}: "
            f"expected one of {sorted(present_expected)} in top {top_k}, got {predicted_words}"
        )

    for context_words, higher_word, lower_word in GOLDEN_RANKING_CASES.get(language, []):
        prepared, missing = _prepare_context(reader, word_to_id, context_words)
        if prepared is None:
            raise AssertionError(
                f"[{language}] cannot check golden ranking {context_words} "
                f"(context word {missing!r} missing from .kdict)"
            )
        higher_id = word_to_id.get(higher_word)
        lower_id = word_to_id.get(lower_word)
        if higher_id is None or lower_id is None:
            missing_target = higher_word if higher_id is None else lower_word
            raise AssertionError(
                f"[{language}] cannot check golden ranking {context_words} "
                f"({higher_word!r} > {lower_word!r}): {missing_target!r} missing from .kdict"
            )
        higher_prob, higher_order = reader.log_probability(higher_id, prepared)
        lower_prob, lower_order = reader.log_probability(lower_id, prepared)
        assert higher_prob > lower_prob, (
            f"[{language}] Golden ranking failure for {' '.join(context_words)!r}: "
            f"P({higher_word!r})={higher_prob:.3f} (order {higher_order}) "
            f"<= P({lower_word!r})={lower_prob:.3f} (order {lower_order})"
        )


def verify_klm_file(klm_path: Path, run_golden: bool = False) -> None:
    language = klm_path.stem
    kdict_path = klm_path.with_suffix(".kdict")
    if not kdict_path.exists():
        raise AssertionError(f"[{language}] Missing sibling dictionary: {kdict_path}")

    file_size = klm_path.stat().st_size
    if file_size > MAX_PRODUCTION_KLM_BYTES:
        raise AssertionError(
            f"[{language}] {klm_path.name} is {file_size:,} bytes (> {MAX_PRODUCTION_KLM_BYTES:,} byte budget)"
        )

    reader = read_klm(klm_path)
    vocabulary = read_kdict_vocabulary(kdict_path)
    expected_fingerprint = vocab_fingerprint(vocabulary)
    assert reader.vocab_count == vocabulary.count, (
        f"[{language}] vocab_count ({reader.vocab_count}) != .kdict word count ({vocabulary.count})"
    )
    assert reader.vocab_fingerprint == expected_fingerprint, (
        f"[{language}] vocab_fingerprint mismatch: klm=0x{reader.vocab_fingerprint:016x} "
        f"!= kdict=0x{expected_fingerprint:016x}"
    )

    if run_golden:
        verify_golden_predictions(language, reader, vocabulary.words, vocabulary.word_to_id())

    print(
        f"[{language}] OK: {reader.vocab_count:,} words, {reader.bigram_count:,} bigrams, "
        f"{reader.trigram_context_count:,} trigram contexts, {reader.trigram_count:,} trigrams "
        f"({file_size / (1024 * 1024):.2f} MB)"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Verify compiled Klaviatuur .klm language models.")
    parser.add_argument("--dir", type=Path, default=Path("KeyboardExtension/Resources/Dictionaries"))
    parser.add_argument("--golden", action="store_true")
    arguments = parser.parse_args()

    klm_files = sorted(arguments.dir.glob("*.klm")) if arguments.dir.exists() else []
    if not klm_files:
        if arguments.golden:
            raise SystemExit(f"No .klm files found in {arguments.dir}")
        print(f"No .klm files found in {arguments.dir}; skipping verification.")
        return

    missing = sorted(set(GOLDEN_NEXT_WORD_CASES) - {path.stem for path in klm_files})
    if arguments.golden and missing:
        raise SystemExit(f"Missing .klm for {', '.join(missing)} in {arguments.dir}")
    for klm_path in klm_files:
        verify_klm_file(klm_path, run_golden=arguments.golden)
    print(f"All {len(klm_files)} compiled .klm language models passed verification.")


if __name__ == "__main__":
    main()
