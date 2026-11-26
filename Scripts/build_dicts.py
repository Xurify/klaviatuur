#!/usr/bin/env python3
"""
Compiles UTF-8 frequency word lists into memory-mapped binary dictionaries (.kdict).
Next-word data lives in the separate .klm language model (Scripts/build_lm.py).

Binary format (KLAD v1, little-endian):
  Header (56 bytes):
    magic            4s   b"KLAD"
    version          H    1
    flags            H    0
    wordCount        I
    nodeCount        I
    edgeCount        I
    wordIdListCount  I
    pairCount        I    always 0; reserved word-pair table from format v1
    wordsOffset      I
    nodesOffset      I
    edgesOffset      I
    wordIdsOffset    I
    stringsOffset    I
    pairsOffset      I
    stringsLength    I

  Word Record (8 bytes, count = wordCount):
    utf8Offset       I    byte offset into strings blob
    utf8Length       H    byte length of canonical UTF-8 string
    frequencyScore   H    1..65535 (higher = more frequent)

  Trie Node (16 bytes, count = nodeCount):
    edgeStart        I    index into edges table
    edgeCount        H    number of sorted child edges
    wordCountAtNode  H    number of canonical word IDs terminating here
    wordListOffset   I    index into wordIds table
    maxSubtreeScore  H    max frequencyScore in this node's subtree
    reserved         H    0

  Trie Edge (8 bytes, count = edgeCount):
    scalar           I    folded lowercase Unicode scalar value
    targetNode       I    index into nodes table

  WordIdList (4 bytes each, count = wordIdListCount):
    wordId           I    index into words table (sorted descending by frequencyScore)

  Strings Blob (raw UTF-8 bytes, length = stringsLength)

"""

from __future__ import annotations

import argparse
import math
import struct
import unicodedata
from pathlib import Path

MAGIC = b"KLAD"
VERSION = 1
HEADER_FORMAT = "<4sHHIIIIIIIIIIII"
HEADER_SIZE = struct.calcsize(HEADER_FORMAT)
assert HEADER_SIZE == 56

SPECIAL_LATIN_FOLDS = {
    "ł": "l",
    "ø": "o",
    "đ": "d",
    "ß": "s",
    "æ": "ae",
    "œ": "oe",
    "\u2019": "'",
    "\u2018": "'",
    "\u02bc": "'",
}


def fold_for_lookup(text: str) -> str:
    """Fold text consistently with Swift DiacriticFolding.fold(_:)."""
    result_chars: list[str] = []
    for character in text.lower():
        if character == "ё":
            result_chars.append("е")
            continue
        if character == "й":
            result_chars.append("й")
            continue
        if character in SPECIAL_LATIN_FOLDS:
            result_chars.append(SPECIAL_LATIN_FOLDS[character])
            continue
        codepoint = ord(character)
        if 0x0400 <= codepoint <= 0x04FF:
            result_chars.append(character)
            continue
        decomposed = unicodedata.normalize("NFD", character)
        for mark in decomposed:
            if unicodedata.category(mark) != "Mn":
                result_chars.append(mark)
    return "".join(result_chars)


class TrieBuilderNode:
    __slots__ = ("children", "word_ids", "max_subtree_score")

    def __init__(self) -> None:
        self.children: dict[int, TrieBuilderNode] = {}
        self.word_ids: list[int] = []
        self.max_subtree_score: int = 0


def load_word_frequencies(
    source_path: Path, max_words: int
) -> list[tuple[str, int]]:
    entries: dict[str, int] = {}
    with source_path.open("r", encoding="utf-8") as handle:
        for line_number, raw_line in enumerate(handle, start=1):
            stripped = raw_line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            parts = stripped.split("\t") if "\t" in stripped else stripped.split()
            word = parts[0].strip()
            if not word:
                continue
            if len(parts) >= 2:
                try:
                    raw_count = int(parts[1])
                except ValueError:
                    raw_count = max(1, 100000 - line_number)
            else:
                raw_count = max(1, 100000 - line_number)
            existing = entries.get(word, 0)
            if raw_count > existing:
                entries[word] = raw_count

    ranked = sorted(entries.items(), key=lambda pair: (-pair[1], pair[0]))
    if max_words > 0:
        ranked = ranked[:max_words]
    if not ranked:
        return []

    max_log = math.log1p(ranked[0][1])
    min_log = math.log1p(ranked[-1][1])
    span = max(max_log - min_log, 1e-6)

    normalized: list[tuple[str, int]] = []
    for word, count in ranked:
        ratio = (math.log1p(count) - min_log) / span
        score = int(round(1000 + ratio * (65535 - 1000)))
        score = max(1, min(65535, score))
        normalized.append((word, score))
    return normalized


def compile_dictionary(words_path: Path, output_path: Path, max_words: int) -> tuple[int, int, int]:
    words = load_word_frequencies(words_path, max_words)
    root = TrieBuilderNode()

    string_chunks: list[bytes] = []
    string_offset = 0
    word_records: list[tuple[int, int, int]] = []

    for word_id, (canonical_word, frequency_score) in enumerate(words):
        encoded = canonical_word.encode("utf-8")
        word_records.append((string_offset, len(encoded), frequency_score))
        string_chunks.append(encoded)
        string_offset += len(encoded)

        folded = fold_for_lookup(canonical_word)
        node = root
        if frequency_score > node.max_subtree_score:
            node.max_subtree_score = frequency_score
        for character in folded:
            scalar = ord(character)
            child = node.children.get(scalar)
            if child is None:
                child = TrieBuilderNode()
                node.children[scalar] = child
            node = child
            if frequency_score > node.max_subtree_score:
                node.max_subtree_score = frequency_score
        node.word_ids.append(word_id)

    # Flatten trie in BFS order for cache locality on shallow prefixes
    flat_nodes: list[TrieBuilderNode] = []
    node_to_index: dict[int, int] = {}
    queue: list[TrieBuilderNode] = [root]
    node_to_index[id(root)] = 0
    flat_nodes.append(root)

    cursor = 0
    while cursor < len(queue):
        current = queue[cursor]
        cursor += 1
        for scalar in sorted(current.children.keys()):
            child = current.children[scalar]
            child_index = len(flat_nodes)
            node_to_index[id(child)] = child_index
            flat_nodes.append(child)
            queue.append(child)

    packed_nodes = bytearray()
    packed_edges = bytearray()
    packed_word_ids = bytearray()
    edge_count = 0
    word_id_list_count = 0

    for current in flat_nodes:
        edge_start = edge_count
        sorted_scalars = sorted(current.children.keys())
        for scalar in sorted_scalars:
            target_index = node_to_index[id(current.children[scalar])]
            packed_edges.extend(struct.pack("<II", scalar, target_index))
        edge_count += len(sorted_scalars)

        word_list_offset = word_id_list_count
        sorted_word_ids = sorted(
            current.word_ids,
            key=lambda identifier: (-word_records[identifier][2], identifier),
        )
        for identifier in sorted_word_ids:
            packed_word_ids.extend(struct.pack("<I", identifier))
        word_id_list_count += len(sorted_word_ids)

        packed_nodes.extend(
            struct.pack(
                "<IHHIHH",
                edge_start,
                len(sorted_scalars),
                len(sorted_word_ids),
                word_list_offset,
                current.max_subtree_score,
                0,
            )
        )

    packed_words = bytearray()
    for utf8_offset, utf8_length, frequency_score in word_records:
        packed_words.extend(struct.pack("<IHH", utf8_offset, utf8_length, frequency_score))

    strings_blob = b"".join(string_chunks)
    strings_padding = (4 - (len(strings_blob) % 4)) % 4

    words_offset = HEADER_SIZE
    nodes_offset = words_offset + len(packed_words)
    edges_offset = nodes_offset + len(packed_nodes)
    word_ids_offset = edges_offset + len(packed_edges)
    strings_offset = word_ids_offset + len(packed_word_ids)
    pairs_offset = strings_offset + len(strings_blob) + strings_padding

    header = struct.pack(
        HEADER_FORMAT,
        MAGIC,
        VERSION,
        0,
        len(word_records),
        len(flat_nodes),
        edge_count,
        word_id_list_count,
        0,
        words_offset,
        nodes_offset,
        edges_offset,
        word_ids_offset,
        strings_offset,
        pairs_offset,
        len(strings_blob),
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("wb") as output_handle:
        output_handle.write(header)
        output_handle.write(packed_words)
        output_handle.write(packed_nodes)
        output_handle.write(packed_edges)
        output_handle.write(packed_word_ids)
        output_handle.write(strings_blob)
        if strings_padding:
            output_handle.write(b"\x00" * strings_padding)

    total_bytes = output_path.stat().st_size
    return len(word_records), len(flat_nodes), total_bytes


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Compile Klaviatuur .kdict binary dictionaries."
    )
    parser.add_argument(
        "--source-dir",
        type=Path,
        default=Path("Data/sources"),
        help="Directory containing <lang>.tsv word lists",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("KeyboardExtension/Resources/Dictionaries"),
        help="Destination directory for compiled .kdict files",
    )
    parser.add_argument(
        "--max-words",
        type=int,
        default=50000,
        help="Maximum words per language dictionary",
    )
    arguments = parser.parse_args()

    wordlist_files = sorted(arguments.source_dir.glob("*.tsv"))
    if not wordlist_files:
        raise SystemExit(f"No .tsv wordlists found in {arguments.source_dir}")

    for wordlist_path in wordlist_files:
        language_code = wordlist_path.stem
        output_path = arguments.output_dir / f"{language_code}.kdict"
        word_count, node_count, total_bytes = compile_dictionary(
            wordlist_path, output_path, arguments.max_words
        )
        print(f"[{language_code}] {word_count} words, {node_count} trie nodes -> {output_path} ({total_bytes:,} bytes)")


if __name__ == "__main__":
    main()
