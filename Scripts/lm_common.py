"""Shared helpers for the Klaviatuur language-model pipeline.

Everything that has to agree byte-for-byte with Swift lives here: corpus tokenization,
the .kdict vocabulary reader, and the vocabulary fingerprint that ties a .klm file to the
.kdict it was built against (BinaryDictionary.vocabFingerprint() in Swift).
"""

from __future__ import annotations

import re
import struct
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator

FNV_OFFSET_BASIS = 0xCBF29CE484222325
FNV_PRIME = 0x100000001B3
MASK64 = 0xFFFFFFFFFFFFFFFF

# Word IDs are stored as UInt16 in .klm and index vocabCount is reserved for <BOS>.
MAX_VOCAB = 0xFFFE

KDICT_HEADER_FORMAT = "<4sHHIIIIIIIIIIII"
KDICT_HEADER_SIZE = struct.calcsize(KDICT_HEADER_FORMAT)

LATIN_LANGUAGES = {"en", "cs", "sk", "et"}
CYRILLIC_LANGUAGES = {"ru"}


@dataclass(frozen=True)
class KdictVocabulary:
    words: list[str]
    strings_length: int

    @property
    def count(self) -> int:
        return len(self.words)

    def word_to_id(self) -> dict[str, int]:
        mapping: dict[str, int] = {}
        for index, word in enumerate(self.words):
            mapping.setdefault(word, index)
        return mapping


def read_kdict_vocabulary(path: Path) -> KdictVocabulary:
    blob = path.read_bytes()
    if len(blob) < KDICT_HEADER_SIZE:
        raise ValueError(f"{path}: truncated .kdict header")
    header = struct.unpack_from(KDICT_HEADER_FORMAT, blob, 0)
    magic, version = header[0], header[1]
    if magic != b"KLAD" or version != 1:
        raise ValueError(f"{path}: not a KLAD v1 dictionary")
    word_count = header[3]
    words_offset = header[8]
    strings_offset = header[12]
    strings_length = header[14]
    words: list[str] = []
    for index in range(word_count):
        utf8_offset, utf8_length, _score = struct.unpack_from("<IHH", blob, words_offset + index * 8)
        start = strings_offset + utf8_offset
        words.append(blob[start : start + utf8_length].decode("utf-8"))
    return KdictVocabulary(words=words, strings_length=strings_length)


def _fnv_update(state: int, data: bytes) -> int:
    for byte in data:
        state ^= byte
        state = (state * FNV_PRIME) & MASK64
    return state


def vocab_fingerprint(vocabulary: KdictVocabulary) -> int:
    """64-bit FNV-1a over the word count and every word, NUL-separated.

    Must match BinaryDictionary.vocabFingerprint() in Swift byte for byte.
    """
    state = _fnv_update(FNV_OFFSET_BASIS, struct.pack("<I", vocabulary.count))
    for word in vocabulary.words:
        state = _fnv_update(state, word.encode("utf-8") + b"\0")
    return state


BOS = "<BOS>"
BREAK = None  # clause boundary / out-of-vocabulary marker; n-grams never span it

_APOSTROPHES = str.maketrans({"’": "'", "ʼ": "'", "‘": "'"})
_SENTENCE_END = re.compile(r"(?<=[.!?…])\s+")


def normalize_text(text: str) -> str:
    return unicodedata.normalize("NFC", text).translate(_APOSTROPHES).lower()


def _is_word_char(character: str) -> bool:
    return character.isalpha()


def _script_ok(word: str, language: str) -> bool:
    for character in word:
        if not character.isalpha():
            continue
        codepoint = ord(character)
        is_cyrillic = 0x0400 <= codepoint <= 0x04FF
        if language in CYRILLIC_LANGUAGES and not is_cyrillic:
            return False
        if language in LATIN_LANGUAGES and (is_cyrillic or codepoint > 0x024F):
            return False
    return True


def tokenize_sentence(sentence: str, language: str) -> list[str | None]:
    """Split one normalized sentence into words and clause breaks (None).

    Words are runs of letters with single internal apostrophes or hyphens ("don't",
    "что-то"). Digits, commas, quotes, brackets and any other symbol become a break, so
    the language model never learns a pair that straddles punctuation, which mirrors
    TypingSessionController clearing its previous-word context on punctuation.
    """
    tokens: list[str | None] = []
    length = len(sentence)
    index = 0
    while index < length:
        character = sentence[index]
        if _is_word_char(character):
            start = index
            index += 1
            while index < length:
                current = sentence[index]
                if _is_word_char(current):
                    index += 1
                elif (
                    current in "'-"
                    and index + 1 < length
                    and _is_word_char(sentence[index + 1])
                ):
                    index += 2
                else:
                    break
            word = sentence[start:index]
            if len(word) <= 32 and _script_ok(word, language):
                tokens.append(word)
            else:
                tokens.append(BREAK)
        elif character.isspace():
            index += 1
        else:
            if tokens and tokens[-1] is not BREAK:
                tokens.append(BREAK)
            index += 1
    while tokens and tokens[-1] is BREAK:
        tokens.pop()
    return tokens


def split_sentences(line: str) -> list[str]:
    return [part for part in _SENTENCE_END.split(line) if part.strip()]


def iter_corpus_sentences(paths: Iterable[Path]) -> Iterator[str]:
    """Yield raw sentences from Leipzig (`id<TAB>text`) or Tatoeba (`id<TAB>lang<TAB>text`) files.

    Plain one-sentence-per-line files are accepted too, which is what the tests use.
    """
    for path in paths:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for raw in handle:
                line = raw.rstrip("\n")
                if not line:
                    continue
                text = line.rsplit("\t", 1)[-1]
                for sentence in split_sentences(text):
                    yield sentence

