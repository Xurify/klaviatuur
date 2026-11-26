"""Binary serializer and reader for Klaviatuur .klm (KLAM v1) language models.

Byte layout and lookup semantics mirror BinaryLanguageModel.swift.
"""

from __future__ import annotations

import math
import struct
from dataclasses import dataclass
from pathlib import Path

from lm_common import MAX_VOCAB

MAGIC = b"KLAM"
VERSION = 1
FLAGS = 0

HEADER_STRUCT = struct.Struct("<4sHHQIIIIIIIIffff")
UNIGRAM_STRUCT = struct.Struct("<IBBH")
BIGRAM_STRUCT = struct.Struct("<HBB")
TRIGRAM_CONTEXT_STRUCT = struct.Struct("<II")
TRIGRAM_STRUCT = struct.Struct("<HBB")

MAX_BIGRAMS_PER_CONTEXT = 512
MAX_TRIGRAMS_PER_CONTEXT = 32

NO_BACKOFF_SENTINEL = 0xFF
TRIGRAM_CONTEXT_SENTINEL_INDEX = 0xFFFFFFFF

CONTEXT_LIFT_MIN = -1.5
CONTEXT_LIFT_MAX = 2.5


@dataclass
class KLMModel:
    vocab_count: int
    vocab_fingerprint: int
    unigram_log_prob: list[float]
    unigram_log_bow: list[float | None]
    bigrams: dict[int, list[tuple[int, float, float | None]]]
    trigrams: dict[tuple[int, int], list[tuple[int, float]]]
    min_log_prob: float = -8.0
    max_log_prob: float = 0.0
    min_log_bow: float = -6.0
    max_log_bow: float = 2.0


@dataclass(frozen=True)
class PreparedContext:
    bigram_start: int = 0
    bigram_end: int = 0
    bigram_log_bow: float = 0.0
    trigram_start: int = 0
    trigram_end: int = 0
    trigram_log_bow: float = 0.0

    @property
    def has_bigram(self) -> bool:
        return self.bigram_start < self.bigram_end

    @property
    def has_trigram(self) -> bool:
        return self.trigram_start < self.trigram_end

    @property
    def is_empty(self) -> bool:
        return not self.has_bigram and not self.has_trigram


EMPTY_CONTEXT = PreparedContext()


def _quantize_log_prob(value: float, min_bound: float, max_bound: float) -> int:
    if not math.isfinite(value):
        raise ValueError(f"Non-finite log probability: {value!r}")
    scaled = (value - min_bound) / (max_bound - min_bound) * 255.0
    return max(0, min(255, math.floor(scaled + 0.5)))


def _quantize_log_bow(value: float | None, min_bound: float, max_bound: float) -> int:
    if value is None:
        return NO_BACKOFF_SENTINEL
    if not math.isfinite(value):
        raise ValueError(f"Non-finite backoff weight: {value!r}")
    scaled = (value - min_bound) / (max_bound - min_bound) * 254.0
    return max(0, min(254, math.floor(scaled + 0.5)))


def _validate_bounds(
    min_log_prob: float, max_log_prob: float, min_log_bow: float, max_log_bow: float
) -> None:
    if not all(math.isfinite(bound) for bound in (min_log_prob, max_log_prob, min_log_bow, max_log_bow)):
        raise ValueError("Quantization bounds must be finite")
    if not (min_log_prob < max_log_prob and min_log_bow < max_log_bow):
        raise ValueError("Quantization min bound must be < max bound")


def serialize_klm(model: KLMModel) -> bytes:
    vocab_count = model.vocab_count
    if not (0 <= vocab_count <= MAX_VOCAB):
        raise ValueError(f"vocab_count out of range [0, {MAX_VOCAB}]: {vocab_count}")
    if not (0 <= model.vocab_fingerprint <= 0xFFFFFFFFFFFFFFFF):
        raise ValueError(f"vocab_fingerprint out of UInt64 range: {model.vocab_fingerprint}")

    _validate_bounds(model.min_log_prob, model.max_log_prob, model.min_log_bow, model.max_log_bow)
    # Quantize against float32-rounded bounds so encode and decode share identical ranges.
    min_log_prob, max_log_prob, min_log_bow, max_log_bow = struct.unpack(
        "<ffff",
        struct.pack("<ffff", model.min_log_prob, model.max_log_prob, model.min_log_bow, model.max_log_bow),
    )
    _validate_bounds(min_log_prob, max_log_prob, min_log_bow, max_log_bow)

    expected_unigrams = vocab_count + 1
    if len(model.unigram_log_prob) != expected_unigrams or len(model.unigram_log_bow) != expected_unigrams:
        raise ValueError(f"Unigram tables must have length vocab_count + 1 ({expected_unigrams})")

    live_trigrams: dict[tuple[int, int], list[tuple[int, float]]] = {}
    for context_pair, entries in model.trigrams.items():
        if not entries:
            continue
        if len(context_pair) != 2:
            raise ValueError(f"Invalid trigram context key: {context_pair!r}")
        prev2_index, prev1_id = context_pair
        if not (0 <= prev2_index <= vocab_count) or not (0 <= prev1_id < vocab_count):
            raise ValueError(f"Trigram context out of range: {context_pair}")
        if len(entries) > MAX_TRIGRAMS_PER_CONTEXT:
            raise ValueError(f"Trigram slice for {context_pair} exceeds cap {MAX_TRIGRAMS_PER_CONTEXT}")
        sorted_entries = sorted(entries, key=lambda item: item[0])
        previous_next_id = -1
        for next_id, log_prob in sorted_entries:
            if not (0 <= next_id < vocab_count):
                raise ValueError(f"Trigram next word id out of range: {next_id}")
            if next_id == previous_next_id:
                raise ValueError(f"Duplicate trigram next word id {next_id} in context {context_pair}")
            if not math.isfinite(log_prob):
                raise ValueError(f"Non-finite trigram log_prob for {context_pair} -> {next_id}")
            previous_next_id = next_id
        live_trigrams[(prev2_index, prev1_id)] = sorted_entries

    for context_index in model.bigrams:
        if not (0 <= context_index <= vocab_count):
            raise ValueError(f"Bigram context index out of range: {context_index}")

    packed_unigrams = bytearray()
    packed_bigrams = bytearray()
    bigram_index_by_pair: dict[tuple[int, int], tuple[int, float | None]] = {}
    bigram_count = 0

    for context_index in range(vocab_count + 1):
        bigram_start = bigram_count
        raw_entries = model.bigrams.get(context_index, [])
        if len(raw_entries) > MAX_BIGRAMS_PER_CONTEXT:
            raise ValueError(f"Bigram slice for context {context_index} exceeds cap {MAX_BIGRAMS_PER_CONTEXT}")
        previous_next_id = -1
        for next_id, log_prob, trigram_log_bow in sorted(raw_entries, key=lambda item: item[0]):
            if not (0 <= next_id < vocab_count):
                raise ValueError(f"Bigram next word id out of range: {next_id}")
            if next_id == previous_next_id:
                raise ValueError(f"Duplicate bigram next word id {next_id} in context {context_index}")
            previous_next_id = next_id

            pair = (context_index, next_id)
            bigram_index_by_pair[pair] = (bigram_count, trigram_log_bow)
            # Only emit a non-0xFF trigram bow when trigrams exist so lookup can skip Table 3 in O(1).
            effective_bow = trigram_log_bow if pair in live_trigrams else None
            packed_bigrams.extend(
                BIGRAM_STRUCT.pack(
                    next_id,
                    _quantize_log_prob(log_prob, min_log_prob, max_log_prob),
                    _quantize_log_bow(effective_bow, min_log_bow, max_log_bow),
                )
            )
            bigram_count += 1

        unigram_prob_q = (
            0
            if context_index == vocab_count
            else _quantize_log_prob(model.unigram_log_prob[context_index], min_log_prob, max_log_prob)
        )
        unigram_bow_q = _quantize_log_bow(model.unigram_log_bow[context_index], min_log_bow, max_log_bow)
        packed_unigrams.extend(UNIGRAM_STRUCT.pack(bigram_start, unigram_prob_q, unigram_bow_q, 0))

    packed_unigrams.extend(UNIGRAM_STRUCT.pack(bigram_count, 0, NO_BACKOFF_SENTINEL, 0))

    resolved_trigram_contexts: list[tuple[int, list[tuple[int, float]]]] = []
    for pair, entries in live_trigrams.items():
        parent = bigram_index_by_pair.get(pair)
        if parent is None:
            raise ValueError(f"Trigram context {pair} has no parent bigram")
        bigram_index, trigram_log_bow = parent
        if trigram_log_bow is None:
            raise ValueError(f"Trigram context {pair} has parent bigram with log_bow=None")
        resolved_trigram_contexts.append((bigram_index, entries))
    resolved_trigram_contexts.sort(key=lambda item: item[0])

    packed_trigram_contexts = bytearray()
    packed_trigrams = bytearray()
    trigram_count = 0
    for bigram_index, entries in resolved_trigram_contexts:
        packed_trigram_contexts.extend(TRIGRAM_CONTEXT_STRUCT.pack(bigram_index, trigram_count))
        for next_id, log_prob in entries:
            packed_trigrams.extend(
                TRIGRAM_STRUCT.pack(next_id, _quantize_log_prob(log_prob, min_log_prob, max_log_prob), 0)
            )
            trigram_count += 1
    packed_trigram_contexts.extend(
        TRIGRAM_CONTEXT_STRUCT.pack(TRIGRAM_CONTEXT_SENTINEL_INDEX, trigram_count)
    )

    trigram_context_count = len(resolved_trigram_contexts)
    unigrams_offset = HEADER_STRUCT.size
    bigrams_offset = unigrams_offset + (vocab_count + 2) * UNIGRAM_STRUCT.size
    trigram_contexts_offset = bigrams_offset + bigram_count * BIGRAM_STRUCT.size
    trigrams_offset = trigram_contexts_offset + (trigram_context_count + 1) * TRIGRAM_CONTEXT_STRUCT.size

    header = HEADER_STRUCT.pack(
        MAGIC,
        VERSION,
        FLAGS,
        model.vocab_fingerprint,
        vocab_count,
        bigram_count,
        trigram_context_count,
        trigram_count,
        unigrams_offset,
        bigrams_offset,
        trigram_contexts_offset,
        trigrams_offset,
        min_log_prob,
        max_log_prob,
        min_log_bow,
        max_log_bow,
    )
    return bytes(header + packed_unigrams + packed_bigrams + packed_trigram_contexts + packed_trigrams)


def write_klm(model: KLMModel, path: Path) -> int:
    blob = serialize_klm(model)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(blob)
    return len(blob)


class KLMReader:
    def __init__(self, data: bytes) -> None:
        if len(data) < HEADER_STRUCT.size:
            raise ValueError(f"Truncated header: {len(data)} bytes < {HEADER_STRUCT.size}")
        (
            magic,
            version,
            flags,
            vocab_fingerprint,
            vocab_count,
            bigram_count,
            trigram_context_count,
            trigram_count,
            unigrams_offset,
            bigrams_offset,
            trigram_contexts_offset,
            trigrams_offset,
            min_log_prob,
            max_log_prob,
            min_log_bow,
            max_log_bow,
        ) = HEADER_STRUCT.unpack_from(data, 0)

        if magic != MAGIC:
            raise ValueError(f"Invalid magic: {magic!r}")
        if version != VERSION:
            raise ValueError(f"Unsupported version: {version}")
        if flags != FLAGS:
            raise ValueError(f"Unsupported flags: {flags}")
        if vocab_count > MAX_VOCAB:
            raise ValueError(f"vocab_count {vocab_count} > {MAX_VOCAB}")
        _validate_bounds(min_log_prob, max_log_prob, min_log_bow, max_log_bow)

        expected_unigrams = HEADER_STRUCT.size
        expected_bigrams = expected_unigrams + (vocab_count + 2) * UNIGRAM_STRUCT.size
        expected_trigram_contexts = expected_bigrams + bigram_count * BIGRAM_STRUCT.size
        expected_trigrams = (
            expected_trigram_contexts + (trigram_context_count + 1) * TRIGRAM_CONTEXT_STRUCT.size
        )
        expected_end = expected_trigrams + trigram_count * TRIGRAM_STRUCT.size
        if (
            (unigrams_offset, bigrams_offset, trigram_contexts_offset, trigrams_offset)
            != (expected_unigrams, expected_bigrams, expected_trigram_contexts, expected_trigrams)
            or len(data) != expected_end
        ):
            raise ValueError("Corrupted table offsets or file length")

        view = memoryview(data)
        bigram_rows = list(BIGRAM_STRUCT.iter_unpack(view[bigrams_offset:trigram_contexts_offset]))
        expected_trigram_bigrams: list[int] = []
        previous_bigram_start = 0
        for unigram_index, (bigram_start, prob_q, bow_q, reserved) in enumerate(
            UNIGRAM_STRUCT.iter_unpack(view[unigrams_offset:bigrams_offset])
        ):
            if reserved != 0:
                raise ValueError(f"Unigram {unigram_index} has non-zero reserved={reserved}")
            if unigram_index == 0:
                if bigram_start != 0:
                    raise ValueError(f"unigrams[0].bigram_start={bigram_start} != 0")
            else:
                if bigram_start < previous_bigram_start or bigram_start > bigram_count:
                    raise ValueError(f"Invalid bigram_start at unigram {unigram_index}")
                if bigram_start - previous_bigram_start > MAX_BIGRAMS_PER_CONTEXT:
                    raise ValueError(
                        f"Bigram slice for context {unigram_index - 1} exceeds cap {MAX_BIGRAMS_PER_CONTEXT}"
                    )
                previous_next_id = -1
                for bigram_index in range(previous_bigram_start, bigram_start):
                    next_id, _prob_q, trigram_bow_q = bigram_rows[bigram_index]
                    if next_id >= vocab_count or next_id <= previous_next_id:
                        raise ValueError(f"Invalid or unsorted bigram entry at index {bigram_index}")
                    previous_next_id = next_id
                    if trigram_bow_q != NO_BACKOFF_SENTINEL:
                        expected_trigram_bigrams.append(bigram_index)

            if unigram_index == vocab_count and prob_q != 0:
                raise ValueError(f"<BOS> unigram_log_prob_q={prob_q} != 0")
            if unigram_index == vocab_count + 1 and (
                bigram_start != bigram_count or prob_q != 0 or bow_q != NO_BACKOFF_SENTINEL
            ):
                raise ValueError("Corrupted sentinel in unigrams table")
            previous_bigram_start = bigram_start

        trigram_rows = list(TRIGRAM_STRUCT.iter_unpack(view[trigrams_offset:expected_end]))
        actual_trigram_bigrams: list[int] = []
        previous_bigram_index = -1
        previous_trigram_start = 0
        for slot, (bigram_index, trigram_start) in enumerate(
            TRIGRAM_CONTEXT_STRUCT.iter_unpack(view[trigram_contexts_offset:trigrams_offset])
        ):
            if slot == trigram_context_count:
                if bigram_index != TRIGRAM_CONTEXT_SENTINEL_INDEX or trigram_start != trigram_count:
                    raise ValueError("Corrupted sentinel in trigram contexts table")
            else:
                if bigram_index >= bigram_count or bigram_index <= previous_bigram_index:
                    raise ValueError(f"Invalid or unsorted trigram context at slot {slot}")
                actual_trigram_bigrams.append(bigram_index)
                previous_bigram_index = bigram_index

            if slot == 0:
                if trigram_start != 0:
                    raise ValueError(f"trigram_contexts[0].trigram_start={trigram_start} != 0")
            else:
                if trigram_start < previous_trigram_start or trigram_start > trigram_count:
                    raise ValueError(f"Invalid trigram_start at slot {slot}")
                slice_length = trigram_start - previous_trigram_start
                if not (1 <= slice_length <= MAX_TRIGRAMS_PER_CONTEXT):
                    raise ValueError(
                        f"Trigram slice {slot - 1} length {slice_length} outside 1..{MAX_TRIGRAMS_PER_CONTEXT}"
                    )
                previous_next_id = -1
                for trigram_index in range(previous_trigram_start, trigram_start):
                    next_id, _prob_q, reserved = trigram_rows[trigram_index]
                    if reserved != 0 or next_id >= vocab_count or next_id <= previous_next_id:
                        raise ValueError(f"Invalid or unsorted trigram entry at index {trigram_index}")
                    previous_next_id = next_id
            previous_trigram_start = trigram_start

        if expected_trigram_bigrams != actual_trigram_bigrams:
            raise ValueError("Mismatch between non-0xFF bigram trigram_bow_q flags and Table 3 contexts")

        self.data = data
        self.vocab_count = vocab_count
        self.vocab_fingerprint = vocab_fingerprint
        self.bigram_count = bigram_count
        self.trigram_context_count = trigram_context_count
        self.trigram_count = trigram_count
        self.unigrams_offset = unigrams_offset
        self.bigrams_offset = bigrams_offset
        self.trigram_contexts_offset = trigram_contexts_offset
        self.trigrams_offset = trigrams_offset
        self.min_log_prob = min_log_prob
        self.max_log_prob = max_log_prob
        self.min_log_bow = min_log_bow
        self.max_log_bow = max_log_bow
        self._prob_span = max_log_prob - min_log_prob
        self._bow_span = max_log_bow - min_log_bow

    def decode_log_prob(self, quantized: int) -> float:
        return self.min_log_prob + (quantized / 255.0) * self._prob_span

    def decode_log_bow(self, quantized: int) -> float:
        if quantized == NO_BACKOFF_SENTINEL:
            return 0.0
        return self.min_log_bow + (quantized / 254.0) * self._bow_span

    def _unigram(self, index: int) -> tuple[int, int, int, int]:
        return UNIGRAM_STRUCT.unpack_from(self.data, self.unigrams_offset + index * UNIGRAM_STRUCT.size)

    def _bsearch(
        self, table_offset: int, entry_struct: struct.Struct, start: int, end: int, target: int
    ) -> tuple[int, tuple[int, ...]] | None:
        low = start
        high = end - 1
        stride = entry_struct.size
        while low <= high:
            middle = (low + high) // 2
            fields = entry_struct.unpack_from(self.data, table_offset + middle * stride)
            key = fields[0]
            if key == target:
                return middle, fields
            if key < target:
                low = middle + 1
            else:
                high = middle - 1
        return None

    def prepare_context(self, prev1: int | None, prev2: int | None) -> PreparedContext:
        if prev1 is None or not (0 <= prev1 <= self.vocab_count):
            return EMPTY_CONTEXT

        bigram_start, _, unigram_bow_q, _ = self._unigram(prev1)
        bigram_end, _, _, _ = self._unigram(prev1 + 1)
        has_bigram = bigram_start < bigram_end
        bigram_log_bow = self.decode_log_bow(unigram_bow_q) if has_bigram else 0.0

        trigram_start = 0
        trigram_end = 0
        trigram_log_bow = 0.0
        if prev2 is not None and 0 <= prev2 <= self.vocab_count and prev1 < self.vocab_count:
            prev2_start, _, _, _ = self._unigram(prev2)
            prev2_end, _, _, _ = self._unigram(prev2 + 1)
            parent = (
                self._bsearch(self.bigrams_offset, BIGRAM_STRUCT, prev2_start, prev2_end, prev1)
                if prev2_start < prev2_end
                else None
            )
            if parent is not None:
                bigram_index, (_, _, trigram_bow_q) = parent
                if trigram_bow_q != NO_BACKOFF_SENTINEL:
                    found = self._bsearch(
                        self.trigram_contexts_offset,
                        TRIGRAM_CONTEXT_STRUCT,
                        0,
                        self.trigram_context_count,
                        bigram_index,
                    )
                    if found is not None:
                        slot, (_, trigram_start) = found
                        _, trigram_end = TRIGRAM_CONTEXT_STRUCT.unpack_from(
                            self.data,
                            self.trigram_contexts_offset + (slot + 1) * TRIGRAM_CONTEXT_STRUCT.size,
                        )
                        trigram_log_bow = self.decode_log_bow(trigram_bow_q)

        if not has_bigram and trigram_start == trigram_end:
            return EMPTY_CONTEXT
        return PreparedContext(
            bigram_start=bigram_start if has_bigram else 0,
            bigram_end=bigram_end if has_bigram else 0,
            bigram_log_bow=bigram_log_bow,
            trigram_start=trigram_start,
            trigram_end=trigram_end,
            trigram_log_bow=trigram_log_bow,
        )

    def unigram_log_probability(self, word_id: int) -> float:
        if not (0 <= word_id < self.vocab_count):
            return self.min_log_prob
        return self.decode_log_prob(self._unigram(word_id)[1])

    def log_probability(self, word_id: int, context: PreparedContext) -> tuple[float, int]:
        if not (0 <= word_id < self.vocab_count):
            return self.min_log_prob, 0
        if context.has_trigram:
            found = self._bsearch(
                self.trigrams_offset, TRIGRAM_STRUCT, context.trigram_start, context.trigram_end, word_id
            )
            if found is not None:
                return self.decode_log_prob(found[1][1]), 3
        if context.has_bigram:
            found = self._bsearch(
                self.bigrams_offset, BIGRAM_STRUCT, context.bigram_start, context.bigram_end, word_id
            )
            if found is not None:
                return min(0.0, context.trigram_log_bow + self.decode_log_prob(found[1][1])), 2
        backed_off = context.trigram_log_bow + context.bigram_log_bow + self.unigram_log_probability(word_id)
        return max(self.min_log_prob - 2.0, min(0.0, backed_off)), 1

    def context_lift(self, word_id: int, context: PreparedContext) -> float:
        if context.is_empty or not (0 <= word_id < self.vocab_count):
            return 0.0
        conditional, _ = self.log_probability(word_id, context)
        return max(CONTEXT_LIFT_MIN, min(CONTEXT_LIFT_MAX, conditional - self.unigram_log_probability(word_id)))

    def top_next_words(self, context: PreparedContext, limit: int) -> list[tuple[int, float, int]]:
        if limit <= 0 or context.is_empty:
            return []
        candidates: list[tuple[int, float, int]] = []
        trigram_words: set[int] = set()
        if context.has_trigram:
            for index in range(context.trigram_start, context.trigram_end):
                next_id, prob_q, _ = TRIGRAM_STRUCT.unpack_from(
                    self.data, self.trigrams_offset + index * TRIGRAM_STRUCT.size
                )
                trigram_words.add(next_id)
                candidates.append((next_id, self.decode_log_prob(prob_q), 3))
        if context.has_bigram:
            for index in range(context.bigram_start, context.bigram_end):
                next_id, prob_q, _ = BIGRAM_STRUCT.unpack_from(
                    self.data, self.bigrams_offset + index * BIGRAM_STRUCT.size
                )
                if next_id in trigram_words:
                    continue
                score = min(0.0, context.trigram_log_bow + self.decode_log_prob(prob_q))
                candidates.append((next_id, score, 2))
        candidates.sort(key=lambda item: (-item[1], -item[2], item[0]))
        return candidates[:limit]


def read_klm(path: Path) -> KLMReader:
    return KLMReader(path.read_bytes())
