#!/usr/bin/env python3
"""Download App Store-safe Leipzig (CC BY 4.0) and Tatoeba (CC BY 2.0 FR) corpora.

    python3 Scripts/fetch_corpora.py [--languages en cs sk et ru] [--size 1M|300K]

Only Leipzig web/news archives are fetched (never Wikipedia or mixed). Existing files are skipped.
"""

from __future__ import annotations

import argparse
import bz2
import hashlib
import json
import os
import tarfile
import tempfile
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

LEIPZIG_BASE = "https://downloads.wortschatz-leipzig.de/corpora"
TATOEBA_BASE = "https://downloads.tatoeba.org/exports/per_language"
OUTPUT_DIR = Path("Data/corpora")

HTTP_TIMEOUT_SECONDS = 20
CHUNK_SIZE = 256 * 1024
USER_AGENT = "KlaviatuurCorpusFetcher/1.0"

# (leipzig_prefixes, tatoeba_iso3) for every language in Data/corpora/manifest.json.
SOURCES: dict[str, tuple[tuple[str, ...], str]] = {
    "en": (("eng-com_web-public_2018", "eng_news_2024"), "eng"),
    "cs": (("ces-cz_web-public_2019", "ces_news_2024"), "ces"),
    "sk": (("slk-sk_web_2016", "slk_newscrawl_2016"), "slk"),
    "et": (("est-ee_web_2015", "est_newscrawl_2017"), "est"),
    "ru": (("rus-ru_web-public_2019", "rus_news_2024"), "rus"),
}


def _hash_and_count(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    sentences = 0
    with path.open("rb") as handle:
        while chunk := handle.read(CHUNK_SIZE):
            digest.update(chunk)
            sentences += chunk.count(b"\n")
    return digest.hexdigest(), sentences


def _fetch_leipzig(language: str, prefix: str, size: str) -> dict[str, object]:
    archive_name = f"{prefix}_{size}.tar.gz"
    url = f"{LEIPZIG_BASE}/{archive_name}"
    target = OUTPUT_DIR / language / f"{prefix}_{size}-sentences.txt"
    target.parent.mkdir(parents=True, exist_ok=True)

    record: dict[str, object] = {
        "language": language,
        "source": "leipzig",
        "license": "CC BY 4.0",
        "archive": archive_name,
        "url": url,
        "size_tier": size,
        "path": target.as_posix(),
    }
    if target.exists():
        extracted_sha256, sentences = _hash_and_count(target)
        return {**record, "bytes": target.stat().st_size, "sentences": sentences, "extracted_sha256": extracted_sha256, "status": "cached"}

    temp_tar: Path | None = None
    temp_out = target.with_suffix(".txt.part")
    try:
        with tempfile.NamedTemporaryFile(prefix=f"klaviatuur-{language}-", suffix=".tar.gz", delete=False) as temp_file:
            temp_tar = Path(temp_file.name)

        print(f"[{language}] Downloading {archive_name}...", flush=True)
        archive_digest = hashlib.sha256()
        archive_bytes = 0
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response, temp_tar.open("wb") as handle:
            while chunk := response.read(CHUNK_SIZE):
                handle.write(chunk)
                archive_digest.update(chunk)
                archive_bytes += len(chunk)

        extracted_digest = hashlib.sha256()
        extracted_bytes = 0
        sentences = 0
        with tarfile.open(temp_tar, mode="r:gz") as archive:
            member = next(
                (entry for entry in archive.getmembers() if entry.isfile() and entry.name.endswith("-sentences.txt")),
                None,
            )
            extracted = archive.extractfile(member) if member is not None else None
            if extracted is None:
                raise RuntimeError(f"No *-sentences.txt member found inside {archive_name}")
            with extracted, temp_out.open("wb") as handle:
                while chunk := extracted.read(CHUNK_SIZE):
                    handle.write(chunk)
                    extracted_digest.update(chunk)
                    extracted_bytes += len(chunk)
                    sentences += chunk.count(b"\n")

        os.replace(temp_out, target)
        print(f"[{language}] Extracted {target.name}: {sentences:,} sentences", flush=True)
        return {
            **record,
            "archive_bytes": archive_bytes,
            "bytes": extracted_bytes,
            "sentences": sentences,
            "archive_sha256": archive_digest.hexdigest(),
            "extracted_sha256": extracted_digest.hexdigest(),
            "status": "downloaded",
        }
    finally:
        if temp_tar is not None:
            temp_tar.unlink(missing_ok=True)
        temp_out.unlink(missing_ok=True)


def _fetch_tatoeba(language: str, iso3: str) -> dict[str, object]:
    archive_name = f"{iso3}_sentences.tsv.bz2"
    url = f"{TATOEBA_BASE}/{iso3}/{archive_name}"
    target = OUTPUT_DIR / language / "tatoeba.txt"
    target.parent.mkdir(parents=True, exist_ok=True)

    record: dict[str, object] = {
        "language": language,
        "source": "tatoeba",
        "license": "CC BY 2.0 FR",
        "archive": archive_name,
        "url": url,
        "path": target.as_posix(),
    }
    if target.exists():
        extracted_sha256, sentences = _hash_and_count(target)
        return {**record, "bytes": target.stat().st_size, "sentences": sentences, "extracted_sha256": extracted_sha256, "status": "cached"}

    temp_out = target.with_suffix(".txt.part")
    try:
        print(f"[{language}] Downloading {archive_name}...", flush=True)
        archive_digest = hashlib.sha256()
        extracted_digest = hashlib.sha256()
        decompressor = bz2.BZ2Decompressor()
        archive_bytes = 0
        extracted_bytes = 0
        sentences = 0
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response, temp_out.open("wb") as handle:
            expected_bytes = int(response.headers.get("Content-Length") or 0)
            while compressed := response.read(CHUNK_SIZE):
                archive_digest.update(compressed)
                archive_bytes += len(compressed)
                plain = b""
                # Tatoeba exports can hold several bz2 streams back to back.
                while compressed:
                    if decompressor.eof:
                        decompressor = bz2.BZ2Decompressor()
                    plain += decompressor.decompress(compressed)
                    compressed = decompressor.unused_data if decompressor.eof else b""
                if plain:
                    handle.write(plain)
                    extracted_digest.update(plain)
                    extracted_bytes += len(plain)
                    sentences += plain.count(b"\n")

        if not decompressor.eof or (expected_bytes and archive_bytes != expected_bytes):
            raise OSError(f"{archive_name} ended early; the download was truncated")
        os.replace(temp_out, target)
        print(f"[{language}] Extracted {target.name}: {sentences:,} sentences", flush=True)
        return {
            **record,
            "archive_bytes": archive_bytes,
            "bytes": extracted_bytes,
            "sentences": sentences,
            "archive_sha256": archive_digest.hexdigest(),
            "extracted_sha256": extracted_digest.hexdigest(),
            "status": "downloaded",
        }
    finally:
        temp_out.unlink(missing_ok=True)


def _write_manifest(records: list[dict[str, object]]) -> Path:
    manifest_path = OUTPUT_DIR / "manifest.json"
    entries: dict[str, dict[str, object]] = {}
    if manifest_path.exists():
        try:
            for entry in json.loads(manifest_path.read_text(encoding="utf-8")).get("files", []):
                if "path" in entry:
                    entries[str(entry["path"])] = entry
        except (json.JSONDecodeError, OSError):
            pass

    for record in records:
        key = str(record["path"])
        entries[key] = {**entries.get(key, {}), **record}

    payload = {
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "files": sorted(entries.values(), key=lambda entry: str(entry["path"])),
    }
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return manifest_path


def main() -> None:
    parser = argparse.ArgumentParser(description="Fetch Leipzig (web/news) and Tatoeba corpora.")
    parser.add_argument("--languages", nargs="+", default=None)
    parser.add_argument("--size", choices=("1M", "300K"), default="1M")
    arguments = parser.parse_args()

    if not arguments.languages:
        languages = list(SOURCES)
    else:
        languages = []
        for item in arguments.languages:
            for code in item.split(","):
                code = code.strip().lower()
                if not code:
                    continue
                if code not in SOURCES:
                    raise SystemExit(f"Unsupported language {code!r}; choose from {', '.join(SOURCES)}")
                if code not in languages:
                    languages.append(code)

    records: list[dict[str, object]] = []
    for language in languages:
        leipzig_prefixes, tatoeba_iso3 = SOURCES[language]
        for prefix in leipzig_prefixes:
            records.append(_fetch_leipzig(language, prefix, arguments.size))
        records.append(_fetch_tatoeba(language, tatoeba_iso3))

    manifest_path = _write_manifest(records)
    print(f"Manifest written to {manifest_path}")


if __name__ == "__main__":
    main()
