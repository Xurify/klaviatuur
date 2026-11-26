#!/usr/bin/env python3
"""Checks that each compiled .kdict resolves unaccented spellings the way BinaryDictionary.swift does."""

from __future__ import annotations

import struct
from pathlib import Path

from build_dicts import HEADER_FORMAT, HEADER_SIZE, MAGIC, fold_for_lookup

CHECKS = [
    ("en", "thank", "thank"),
    ("sk", "dakujem", "ďakujem"),
    ("cs", "prilis", "příliš"),
    ("cs", "dekuji", "děkuji"),
    ("et", "tanan", "tänan"),
    ("et", "koik", "kõik"),
    ("ru", "еще", "ещё"),
    ("ru", "мой", "мой"),
]


class Kdict:
    def __init__(self, path: Path) -> None:
        self.data = path.read_bytes()
        (magic, version, _flags, _words, _nodes, _edges, _ids, pair_count, words_offset,
         self.nodes_offset, self.edges_offset, self.word_ids_offset, self.strings_offset,
         pairs_offset, _strings_length) = struct.unpack_from(HEADER_FORMAT, self.data, 0)
        assert magic == MAGIC and version == 1, f"{path}: not a KLAD v1 dictionary"
        assert words_offset == HEADER_SIZE
        assert pairs_offset + pair_count * 12 == len(self.data)
        self.words_offset = words_offset

    def word(self, word_id: int) -> str:
        utf8_offset, utf8_length, _ = struct.unpack_from("<IHH", self.data, self.words_offset + word_id * 8)
        start = self.strings_offset + utf8_offset
        return self.data[start : start + utf8_length].decode("utf-8")

    def node(self, index: int) -> tuple[int, int, int, int]:
        edge_start, edge_count, word_count, word_list, _, _ = struct.unpack_from(
            "<IHHIHH", self.data, self.nodes_offset + index * 16
        )
        return edge_start, edge_count, word_count, word_list

    def exact_matches(self, text: str) -> list[str]:
        current = 0
        for character in fold_for_lookup(text):
            edge_start, edge_count, _, _ = self.node(current)
            edges = (
                struct.unpack_from("<II", self.data, self.edges_offset + index * 8)
                for index in range(edge_start, edge_start + edge_count)
            )
            current = next((target for scalar, target in edges if scalar == ord(character)), None)
            if current is None:
                return []
        _, _, word_count, word_list = self.node(current)
        return [
            self.word(struct.unpack_from("<I", self.data, self.word_ids_offset + (word_list + offset) * 4)[0])
            for offset in range(word_count)
        ]


def main() -> None:
    directory = Path("KeyboardExtension/Resources/Dictionaries")
    for code, query, expected in CHECKS:
        matches = Kdict(directory / f"{code}.kdict").exact_matches(query)
        assert expected in matches, f"[{code}] expected {expected!r} for {query!r}, got {matches}"
    assert fold_for_lookup("мой") != fold_for_lookup("мои"), "й must not fold to и"
    print("All 5 compiled .kdict dictionaries passed verification.")


if __name__ == "__main__":
    main()
