#!/usr/bin/env python3
"""Measure the .klm models on the sentences build_lm.py holds out of training.

    python3 Scripts/evaluate_lm.py [--sentences 2000] [--languages sk cs]

Walks each held-out sentence as if typing it with three suggestions on screen:
  next-word top-1 / top-3  the word is predicted before any letter is typed
  keystrokes saved         letters and spaces skipped by tapping the word as soon as it shows up
The frequency column ranks completions by word frequency alone, with no predictions, which is
what the keyboard offered before the language model. Rankings come from the model, not the
full Swift engine, so treat the numbers as the model's contribution rather than the product's.
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from build_lm import LANGUAGES, corpus_files, iter_language_sentences  # noqa: E402
from klm_format import EMPTY_CONTEXT, KLMReader, read_klm  # noqa: E402
from lm_common import read_kdict_vocabulary  # noqa: E402

SHOWN = 3
PREFIX_POOL = 8


@dataclass
class Tally:
    words: int = 0
    predicted_top1: int = 0
    predicted_top3: int = 0
    keystrokes: int = 0
    keystrokes_with_model: int = 0
    keystrokes_with_frequency: int = 0

    def saved(self, cost: int) -> float:
        return 100 * (1 - cost / self.keystrokes) if self.keystrokes else 0.0


def frequency_order(sources_dir: Path, language: str, word_to_id: dict[str, int]) -> list[int]:
    ranked: list[int] = []
    with (sources_dir / f"{language}.tsv").open(encoding="utf-8") as handle:
        for line in handle:
            if not line.startswith("#"):
                word_id = word_to_id.get(line.split("\t", 1)[0])
                if word_id is not None:
                    ranked.append(word_id)
    return ranked


def top_by_prefix(words: list[str], ranked: list[int]) -> dict[str, list[int]]:
    """The most frequent few words under every prefix, including the empty one."""
    pools: dict[str, list[int]] = {}
    for word_id in ranked:
        word = words[word_id]
        for end in range(len(word) + 1):
            pool = pools.setdefault(word[:end], [])
            if len(pool) < PREFIX_POOL:
                pool.append(word_id)
    return pools


def taps_to_enter(word: str, shown_for_prefix) -> int:
    """Letters typed before the word appears among the suggestions, plus the tap; at worst the word and a space."""
    for typed in range(len(word)):
        if word in shown_for_prefix(word[:typed]):
            return typed + 1
    return len(word) + 1


def evaluate(language: str, dict_dir: Path, sources_dir: Path, corpora_dir: Path, limit: int) -> str:
    reader: KLMReader = read_klm(dict_dir / f"{language}.klm")
    words = read_kdict_vocabulary(dict_dir / f"{language}.kdict").words
    word_to_id = {word: index for index, word in enumerate(words)}
    pools = top_by_prefix(words, frequency_order(sources_dir, language, word_to_id))
    bos = reader.vocab_count

    files = [path for path, _ in corpus_files(corpora_dir, language)]
    if not files:
        return f"[{language}] no corpus files in {corpora_dir / language}, skipped"
    per_file = max(1, limit // len(files))
    tally = Tally()
    sentences = 0
    for path in files:
        taken = 0
        for tokens in iter_language_sentences(path, language, held_out=True):
            if taken == per_file:
                break
            taken += 1
            prev1, prev2 = bos, None
            for token in tokens:
                if token is None:
                    prev1 = prev2 = None
                    continue
                score(token, word_to_id.get(token), reader, words, pools, prev1, prev2, tally)
                word_id = word_to_id.get(token)
                prev1, prev2 = (word_id, prev1) if word_id is not None else (None, None)
        sentences += taken

    if not tally.words:
        return f"[{language}] no held-out words, skipped"
    return (
        f"| {language} | {sentences:,} | {tally.words:,} "
        f"| {100 * tally.predicted_top1 / tally.words:.1f}% | {100 * tally.predicted_top3 / tally.words:.1f}% "
        f"| {tally.saved(tally.keystrokes_with_model):.1f}% | {tally.saved(tally.keystrokes_with_frequency):.1f}% |"
    )


def score(token, word_id, reader, words, pools, prev1, prev2, tally: Tally) -> None:
    context = reader.prepare_context(prev1, prev2) if prev1 is not None else EMPTY_CONTEXT
    listed = [(words[next_id], probability) for next_id, probability, _ in reader.top_next_words(context, 512)]
    listed_words = {word for word, _ in listed}
    narrowed = {"": listed}

    def with_model(prefix: str) -> list[str]:
        if prefix not in narrowed:
            narrowed[prefix] = [item for item in narrowed[prefix[:-1]] if item[0].startswith(prefix)]
        candidates = list(narrowed[prefix])
        if prefix:
            candidates += [
                (words[other], reader.log_probability(other, context)[0])
                for other in pools.get(prefix, [])
                if words[other] not in listed_words
            ]
        candidates.sort(key=lambda item: -item[1])
        return [word for word, _ in candidates[:SHOWN]]

    def with_frequency(prefix: str) -> list[str]:
        return [words[other] for other in pools.get(prefix, [])[:SHOWN]] if prefix else []

    tally.words += 1
    tally.keystrokes += len(token) + 1
    if word_id is None:
        tally.keystrokes_with_model += len(token) + 1
        tally.keystrokes_with_frequency += len(token) + 1
        return
    predicted = with_model("")
    tally.predicted_top1 += predicted[:1] == [token]
    tally.predicted_top3 += token in predicted
    tally.keystrokes_with_model += taps_to_enter(token, with_model)
    tally.keystrokes_with_frequency += taps_to_enter(token, with_frequency)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--corpora-dir", type=Path, default=Path("Data/corpora"))
    parser.add_argument("--sources-dir", type=Path, default=Path("Data/sources"))
    parser.add_argument("--dict-dir", type=Path, default=Path("KeyboardExtension/Resources/Dictionaries"))
    parser.add_argument("--languages", nargs="+", default=list(LANGUAGES))
    parser.add_argument("--sentences", type=int, default=2000, help="held-out sentences per language")
    arguments = parser.parse_args()

    print("| Language | Sentences | Words | Next word top-1 | Next word top-3 | Keystrokes saved | Frequency only |")
    print("|---|---|---|---|---|---|---|")
    for language in arguments.languages:
        print(evaluate(language, arguments.dict_dir, arguments.sources_dir, arguments.corpora_dir, arguments.sentences),
              flush=True)


if __name__ == "__main__":
    main()
