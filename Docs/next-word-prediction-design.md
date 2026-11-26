> The original design. Where it differs from the code, [the plan's amendments](next-word-prediction-plan.md#amendments-to-the-design) win.

## Verdict

**BUILD Option 2 first, then Option 4 as a small second phase. Do not build Option 3.**

Two findings in the current codebase drive this call:

1. Klaviatuur already has next-word UI, bigram plumbing in [BinaryDictionary.swift](../Packages/KeyboardCore/Sources/KeyboardCore/Lexicon/BinaryDictionary.swift#L328-L370), and bigram boosting in [MultilingualEngine.swift](../Packages/KeyboardCore/Sources/KeyboardCore/Lexicon/MultilingualEngine.swift#L203-L214). Right now it runs on 160 to 220 starter words and 26 to 50 hand-typed bigrams per language, and the existing scoring design breaks down as soon as you scale up. Autocorrect reranking only checks the top 8 unconditional next words after `previousWord`, scores are global log-counts instead of conditional probabilities, and [TypingSessionController.swift](../Packages/KeyboardCore/Sources/KeyboardCore/Input/TypingSessionController.swift#L121-L136) leaks `previousCommittedWord` across sentence-ending periods.
2. Unigram-only typing fails constantly on Klaviatuur's core feature: simultaneous 4-language Latin input (`en`, `sk`, `cs`, `et`) with automatic diacritic restoration plus Russian `ё` restoration. Without previous-word context, the engine cannot reliably split same-language diacritic pairs (`все` vs `всё`, `ma` vs `má`, `ze` vs `že`, `stát` vs `stať`, `tood` vs `tööd`), short cross-language collisions (`to`, `on`, `do`, `sa`, `se`, `ma`), or adjacent-key typos (`want ot` choosing `of` at edit cost 0.42 over `to` at transposition cost 0.55).

**Recommended build order:**

1. **Phase 1 (core build): Unified legal corpus pipeline + Option 2.** Build a new read-only memory-mapped binary format (`.klm`, pruned Modified Kneser-Ney bigrams + trigrams) next to `.kdict`, fed by legally clean corpora (Leipzig Corpora Collection + Tatoeba). Use the same corpus pipeline to replace the 170-word starter `.kdict` files with 50,000-word production dictionaries and remove the license-risky `hermitdave/FrequencyWords` recommendation from [README.md](../README.md#L67).
2. **Phase 2 (small follow-up): Option 4.** Add a capped, privacy-filtered on-device personal unigram and bigram overlay (max 4,000 bigrams, ~150 KB on disk) plus Apple's `requestSupplementaryLexicon` (which works without Full Access). Store it in the extension's own private `Application Support` container when Full Access is off, and mirror to the App Group when Full Access is on.
3. **Skip Option 3 (neural LM / Core ML).** Core ML adds heavy dirty-RAM overhead inside an extension with a 48 to 70 MB Jetsam ceiling, simultaneous 4-language rescoring of 10 to 15 fuzzy candidates per keystroke blows past a few-ms latency budget on subword models, word-level 10k vocabs miss too many inflected forms in Czech, Slovak, Estonian, and Russian, and developing/profiling neural weights from Windows with no local Swift or Xcode Instruments loop carries high risk.

---

## Option comparison

| Dimension | Option 1: Do nothing | Option 2: Mmapped `.klm` (MKN bigram + trigram) | Option 3: Tiny neural LM (Core ML or int8) | Option 4: On-device personal bigrams |
|---|---|---|---|---|
| **Expected user quality gain** | None. Empty bar after space on >98% of words; weak on diacritic homographs (`все`/`всё`, `ma`/`má`) and cross-language stopwords (`to`, `on`, `sa`/`se`). | **High.** Covers 3-slot next-word predictions, fixes diacritic and cross-language disambiguation, resolves Czech/Slovak Wackernagel clitics (`ako sa máš`, `jak se máš`), Estonian `ei` negation, Russian `не`, and adjacent-key typos. | **Medium-high in English, uneven across 5 languages.** Better long-range context than trigrams, but a 1 to 5 MB shared multilingual model starves Czech/Slovak/Estonian, while 5 per-language 10k-word models miss inflected morphology. | **Poor alone (cold start). High as an overlay on Option 2.** Learns names, slang, and cross-lingual code-switching (`ahoj bro`) that no static corpus has. |
| **On-disk size per language** | 0 B extra (~3.5 to 4.5 MB per 50k `.kdict`). | **2.4 to 3.2 MB** uncompressed (~13.8 MB total for 5 languages; ~7 to 8 MB zipped in IPA). | 1.5 to 5 MB int8 per language (7.5 to 25 MB for 5 models), or 3 to 5 MB shared. | **0.1 to 0.25 MB total** across all languages combined (capped at 4,000 bigrams + 2,000 unigrams). |
| **Heap / dirty RAM (`phys_footprint`)** | 0 B extra. | **< 1 KB heap** for 5 wrappers + ~0.5 KB scratch. Clean file-backed `mmap` pages do not count toward iOS Jetsam `phys_footprint` (Apple docs on `NSData.ReadingOptions.mappedIfSafe` / `alwaysMapped`). | **Core ML: 15 to 35+ MB dirty RAM** (framework, Espresso/BNNS runtime, activation tensors; high Jetsam kill risk with 4 active Latin models). **Hand-rolled int8:** 0.5 to 2 MB heap if weights are mmapped. | **0.3 to 0.6 MB heap** for capped dictionary in memory. |
| **Per-keystroke latency (iPhone)** | ~0.3 to 1.5 ms (current fuzzy trie search). | **< 0.15 ms** for next-word prediction across 4 languages; **< 0.02 ms** to rescore 60 autocorrect candidates (replaces string-allocating top-8 loop, so faster than today). Cold page fault adds 1 to 3 ms once per cold page. | **Word LSTM (1.4M params, Gboard CIFG-LSTM):** ~2 to 5 ms per language (~8 to 20 ms across 4 Latin languages). **Subword Transformer:** 15 to 80+ ms per keystroke for beam search or multi-subword candidate rescoring. | **< 0.01 ms** (`O(1)` hash lookup). Debounced async disk flush on `viewWillDisappear` or every 20 commits. |
| **Implementation risk** | Zero code risk; high product-quality gap. | **Low.** Same `NSData(.alwaysMapped)` + `UnsafeRawPointer` pattern as `BinaryDictionary.swift`. Entire pipeline and byte verifier run natively in Python on Windows. | **Very high.** Needs GPU training for 5 languages, calibration/quantization, custom tokenizer, and either Core ML (cannot run `coremlcompiler` on Windows) or hand-rolled SIMD int8 + beam search verified blind without local Swift/Instruments. | **Low-medium.** Main traps are the Full Access sandbox split, privacy filtering (`isSecureTextEntry`), and avoiding learning typos before backspace undo. |
| **Fit with current code** | Matches current toy state, leaves existing `nextWordPredictions` and `bigramBonusByWord` underused. | **Direct fit.** Drops into `Dictionaries/` (already bundled by [project.yml](../project.yml#L62-L64)), mirrors `BinaryDictionary` idioms, keeps legacy `.kdict` fallback for tests. | **Poor fit.** Requires new ML runtime, tokenization layer, async pipeline (to avoid UI thread stalls), and careful lifecycle unloading in `didReceiveMemoryWarning`. | **Direct fit.** Persists the already-stubbed `userLearnedWords` in [MultilingualEngine.swift](../Packages/KeyboardCore/Sources/KeyboardCore/Lexicon/MultilingualEngine.swift#L49) and `userDictionaryFileURL` in [AppGroupStorage.swift](../Packages/KeyboardCore/Sources/KeyboardCore/Shared/AppGroupStorage.swift#L41-L43). |

### Notes on Option 3 benchmarks and Option 4 without Full Access

- **Why neural LMs are harder on iOS extensions than Android:** Google's Gboard CIFG-LSTM (Hard et al., 2018, *Federated Learning for Mobile Keyboard Prediction*, arXiv:1811.03604) shrinks to 1.4 MB quantized with 1.4M parameters, but only by capping vocabulary at 10,000 words with a 96-dim tied embedding and running via TFLite on Android without a 48 MB extension ceiling. FUTO Keyboard ships a 36M-parameter Llama-style Transformer, yet even on Android it is English-only and FUTO advises disabling it on older phones due to typing lag and thermal drain. On iOS, loading Core ML inside a `UIInputViewController` extension risks silent Jetsam termination with no crash log because Jetsam enforces `phys_footprint` aggressively.
- **What happens to Option 4 without Full Access:** On iOS, when the user leaves "Allow Full Access" OFF, Apple's sandbox blocks the keyboard extension from **writing** to the shared App Group container (`FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)` and `UserDefaults(suiteName:)`). Reading from the App Group still works, and the keyboard extension **can** read and write inside its own private sandbox container (`FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)`). [AppGroupStorage.swift](../Packages/KeyboardCore/Sources/KeyboardCore/Shared/AppGroupStorage.swift#L10-L12) already uses this exact pattern for settings. If Phase 2 writes personal bigrams solely to `AppGroupStorage.userDictionaryFileURL`, personal learning silently breaks for every user without Full Access. Instead, Phase 2 must write to the extension's private `Application Support/personal_lm.bin` whenever `!hasFullAccess`, mirror to the App Group container when `hasFullAccess` is true, and watch a `personalResetTimestamp` key written by the companion app to the App Group (readable without Full Access) so "Clear Learned Data" in the companion app still works either way. Never record tokens when `textDocumentProxy.isSecureTextEntry == true`, `autocorrectionType == .no`, or `textContentType` is `.password`, `.newPassword`, `.oneTimeCode`, `.creditCardNumber`, `.emailAddress`, or `.URL`.

---

## Corpus sources and App Store licensing

| Source | Languages (`en, cs, sk, et, ru`) | License | App Store verdict | Notes |
|---|---|---|---|---|
| **Leipzig Corpora Collection (Wortschatz)** downloadable `.tar.gz` archives (`downloads.wortschatz-leipzig.de`) | All 5 (`eng`, `ces`, `slk`, `est`, `rus`), up to 1M sentences per release | **CC BY 4.0** (downloads only; live web interface is CC BY-NC, do not scrape it) | **SAFE (Primary)** | Commercial use and redistribution allowed with attribution (`uni-leipzig.de` / Wortschatz Leipzig). Sentences are randomized to avoid reconstructing source articles. **Important:** use `*_web_*` and `*_news_*` only; skip `*_wikipedia_*` and `*_mixed_*` to avoid CC BY-SA mixing. |
| **Tatoeba** sentence exports (`downloads.tatoeba.org`) | All 5 (`eng` ~2.05M, `rus` ~1.24M, `ces` ~90k, `slk` ~33k, `est` ~6.5k sentences) | **CC BY 2.0 FR** (some sentences CC0 1.0) | **SAFE (Conversational blend)** | Commercial use allowed with attribution (`tatoeba.org`). Short everyday sentences fix the formal news bias of Leipzig when upweighted 4x. Too small on its own for Slovak and Estonian. |
| **FineWeb-2** (`HuggingFaceFW/fineweb-2`) + **FineWeb** (`eng`) | All 5 (`rus_Cyrl` ~589B words, `ces_Latn` ~35.5B, `slk_Latn` ~14.8B, `est_Latn` included) | **ODC-By 1.0** (database license over Common Crawl web text) | **USABLE WITH CAVEAT (Optional booster)** | Commercial use permitted under ODC-By 1.0 with attribution. Shipping pruned 2- and 3-word aggregate counts avoids redistributing expressive web text, though underlying text comes from Common Crawl. Use as an optional 1M to 2M sentence slice only if Estonian or Slovak web coverage needs a lift. |
| **HPLT v2/v3** (`hplt-project.org`) | All 5 | **CC0 1.0** (packaging; Common Crawl / Internet Archive text) | **USABLE WITH CAVEAT** | Same Common Crawl caveat as FineWeb-2; backup option. |
| **Europarl** (`statmt.org` / CLARIN) | 4 of 5 (`en, cs, sk, et`; no `ru`) | CC0 / EU open reuse | **SAFE, skip** | Missing Russian and overwhelmingly formal parliamentary prose. |
| **Google Books Ngrams (v2/v3)** | 2 of 5 (`en`, `ru` only; no `cs`, `sk`, `et`) | **CC BY 3.0 / 4.0** | **SAFE, skip** | Missing three of Klaviatuur's five languages and skewed toward older formal books with OCR noise. |
| **Wikipedia Dumps** (`dumps.wikimedia.org`) | All 5 | **CC BY-SA 4.0** + GFDL | **FLAG / AVOID** | ShareAlike copyleft plus CC BY-SA 4.0's anti-TPM ("no technological measures") clause conflicts with Apple App Store DRM and standard EULA if n-gram tables are treated as adapted material bundled inside the app. Encyclopedic register also predicts poorly for texting. |
| **OpenSubtitles via OPUS** (`opus.nlpl.eu`) & **`hermitdave/FrequencyWords`** | All 5 | OPUS disclaims third-party copyright; OpenSubtitles ToS prohibits commercial use; `hermitdave/FrequencyWords` data is **CC BY-SA 4.0** | **BLOCKER, DO NOT SHIP** | Subtitles are unauthorized derivative works of copyrighted films and TV shows, violating Apple App Store Review Guideline 5.2.1 and OpenSubtitles' non-commercial terms. `hermitdave/FrequencyWords` layers CC BY-SA 4.0 on top. Replace the `hermitdave/FrequencyWords` instruction in [README.md](../README.md#L67). |
| **Czech National Corpus (CNC)** & **Estonian National / Reference Corpus** | `cs` only / `et` only | Academic non-commercial / **CC BY-NC-SA** | **BLOCKER, DO NOT SHIP** | Explicit non-commercial terms bar App Store distribution without a separate paid commercial license. |

**Attribution requirement:** Include a `THIRD_PARTY_NOTICES.md` file in the repo and a short "Licenses & Data Attributions" section in the companion SwiftUI app crediting Leipzig Corpora Collection (CC BY 4.0) and Tatoeba (CC BY 2.0 FR), plus FineWeb-2 (ODC-By 1.0) if used.

---

## Technical specification (Phase 1: `.klm` language model)

### 1. Binary file format (`KLAM` v1, little-endian, memory-mapped)

One companion `<lang>.klm` file sits alongside `<lang>.kdict` in `KeyboardExtension/Resources/Dictionaries/`. Keeping `.klm` separate from `.kdict` leaves `KLAD` v1 untouched, isolates trie page faults from n-gram page faults, and lets `MultilingualEngine` fall back cleanly when a `.klm` is absent (such as in existing `BinaryDictionary.buildInMemory` tests).

#### Word ID mapping and vocabulary sync

- `.klm` reuses `.kdict`'s exact `wordId` numbering (`0 ..< vocabCount`, ordered by descending unigram frequency in `.kdict`).
- `vocabCount` is capped at **`65534`** (`<= 0xFFFE`) so every in-vocabulary `wordId` fits in `UInt16`.
- Unigram slot index `vocabCount` represents **`<BOS>`** (beginning of sentence). `<BOS>` never appears as a `nextWordId`.
- To prevent silent drift if `.kdict` is rebuilt without rebuilding `.klm`, both sides compute a deterministic 64-bit FNV-1a **`vocabFingerprint`** (`offsetBasis = 0xcbf29ce484222325`, `prime = 0x100000001b3`):
  1. Feed `UInt32(vocabCount)` little-endian (4 bytes).
  2. Feed `UInt32(kdict.stringsLength)` little-endian (4 bytes).
  3. Let `step = max(1, vocabCount / 64)`. Iterate `index` over `0, step, 2*step, ... < vocabCount`, plus `vocabCount - 1` if not already included (at most 65 words, touching ~2 pages in < 5 µs). For each sampled `index`, feed `UInt32(index)` LE, `UInt16(utf8Length)` LE, and the raw UTF-8 bytes of word `index`.
- At load time, `MultilingualEngine` checks `lm.vocabCount <= dict.wordCount` and `lm.vocabFingerprint == dict.vocabFingerprint(prefixCount: lm.vocabCount)`. On mismatch, it ignores the stale `.klm` and logs in `#if DEBUG`.

#### Quantization

All scores use base-10 log space (ARPA convention), quantized to `UInt8`:

- **Log-probabilities (`logProbQ: UInt8`, `0..255`):**
  - Header bounds: `minLogProb = -8.0`, `maxLogProb = 0.0` (step `0.03137` log10 units).
  - Encode: `q = clamp(round((log10p - minLogProb) / (maxLogProb - minLogProb) * 255.0), 0, 255)`.
  - Decode: `log10p = minLogProb + (Double(q) / 255.0) * (maxLogProb - minLogProb)`.
  - Higher `UInt8` means higher probability, so hot loops can compare `UInt8` directly.
- **Backoff weights (`bowQ: UInt8`, `0..254`, with `0xFF` sentinel):**
  - Header bounds: `minLogBow = -6.0`, `maxLogBow = +2.0` (step `0.03150` log10 units). Supporting positive `log10(bow)` up to `+2.0` is required because post-pruning renormalized backoff weights can exceed `1.0`.
  - **`0xFF` (`255`)** is a sentinel meaning "no child n-grams stored for this context, backoff weight is `0.0`". For `BigramRecord.trigramBowQ`, `0xFF` lets lookups skip the trigram tables in `O(1)` without touching a single trigram page.
  - Decode for `q < 255`: `log10bow = minLogBow + (Double(q) / 254.0) * (maxLogBow - minLogBow)`.

#### Byte layout

All multi-byte fields are little-endian. All tables are 4-byte aligned.

**Header (64 bytes, offset `0..<64`, Python struct `"<4sHHQIIIIIIIIffff"`):**

| Offset | Size | Type | Field | Constraints / meaning |
|---:|---:|---|---|---|
| `0` | 4 | `[UInt8; 4]` | `magic` | `0x4B, 0x4C, 0x41, 0x4D` (`"KLAM"`) |
| `4` | 2 | `UInt16` | `version` | `1` |
| `6` | 2 | `UInt16` | `flags` | `0` (reserved; non-zero rejected in v1) |
| `8` | 8 | `UInt64` | `vocabFingerprint` | 64-bit FNV-1a fingerprint matching `.kdict` |
| `16` | 4 | `UInt32` | `vocabCount` | `<= 65534`; `<BOS>` is at unigram index `vocabCount` |
| `20` | 4 | `UInt32` | `bigramCount` | Number of records in Table 2 |
| `24` | 4 | `UInt32` | `trigramContextCount` | Number of live records in Table 3 (excluding sentinel) |
| `28` | 4 | `UInt32` | `trigramCount` | Number of records in Table 4 |
| `32` | 4 | `UInt32` | `unigramsOffset` | `64` |
| `36` | 4 | `UInt32` | `bigramsOffset` | `unigramsOffset + (vocabCount + 2) * 8` |
| `40` | 4 | `UInt32` | `trigramContextsOffset` | `bigramsOffset + bigramCount * 4` |
| `44` | 4 | `UInt32` | `trigramsOffset` | `trigramContextsOffset + (trigramContextCount + 1) * 8` |
| `48` | 4 | `Float32` | `minLogProb` | Default `-8.0`; must be finite and `< maxLogProb` |
| `52` | 4 | `Float32` | `maxLogProb` | Default `0.0`; must be finite |
| `56` | 4 | `Float32` | `minLogBow` | Default `-6.0`; must be finite and `< maxLogBow` |
| `60` | 4 | `Float32` | `maxLogBow` | Default `+2.0`; must be finite |

**Table 1: Unigrams (`unigramsOffset`, `(vocabCount + 2)` records × 8 bytes, `"<IBBH"`):**

- Indices `0 ..< vocabCount`: `.kdict` words.
- Index `vocabCount`: `<BOS>` (`unigramLogProbQ = 0`; its bigram slice holds sentence-start words, and its children can have sentence-initial trigrams `(<BOS>, w1, w2)` automatically).
- Index `vocabCount + 1`: CSR sentinel (`bigramStart = bigramCount`, `unigramLogProbQ = 0`, `backoffWeightQ = 0xFF`, `reserved = 0`).

| Rel offset | Size | Type | Field | Meaning |
|---:|---:|---|---|---|
| `+0` | 4 | `UInt32` | `bigramStart` | CSR start index in Table 2; slice for `u` is `unigrams[u].bigramStart ..< unigrams[u+1].bigramStart` |
| `+4` | 1 | `UInt8` | `unigramLogProbQ` | Quantized $\log_{10} P_{\text{KN}}(u)$ |
| `+5` | 1 | `UInt8` | `backoffWeightQ` | Quantized $\log_{10} \text{bow}(u)$ (`0..254`), or `0xFF` if none |
| `+6` | 2 | `UInt16` | `reserved` | `0` |

**Table 2: Bigrams (`bigramsOffset`, `bigramCount` records × 4 bytes, `"<HBB"`):**

Within each `prevWord` CSR slice, records are sorted strictly by `nextWordId ASC` for $O(\log d)$ pointwise binary search. Because every slice is capped at `<= 512` records (2 KB contiguous), top-K next-word scanning stays under 2 µs with zero duplicate index tables.

| Rel offset | Size | Type | Field | Meaning |
|---:|---:|---|---|---|
| `+0` | 2 | `UInt16` | `nextWordId` | `.kdict` word ID (`0 ..< vocabCount`) |
| `+2` | 1 | `UInt8` | `logProbQ` | Quantized $\log_{10} P_{\text{KN}}(w_2 \mid w_1)$ |
| `+3` | 1 | `UInt8` | `trigramBowQ` | `0xFF` = no trigrams for `(w1, w2)`; `0..254` = has trigrams and gives quantized $\log_{10} \text{bow}(w_1, w_2)$ |

**Table 3: Trigram contexts (`trigramContextsOffset`, `(trigramContextCount + 1)` records × 8 bytes, `"<II"`):**

Sorted strictly by `bigramIndex ASC`. Final record at `trigramContextCount` is a CSR sentinel with `bigramIndex = 0xFFFFFFFF`, `trigramStart = trigramCount`. Even when `trigramContextCount == 0`, the 1 sentinel record is always written.

| Rel offset | Size | Type | Field | Meaning |
|---:|---:|---|---|---|
| `+0` | 4 | `UInt32` | `bigramIndex` | 0-based index of parent `(w1, w2)` in Table 2 |
| `+4` | 4 | `UInt32` | `trigramStart` | CSR start index in Table 4; slice is `ctx[i].trigramStart ..< ctx[i+1].trigramStart` |

**Table 4: Trigrams (`trigramsOffset`, `trigramCount` records × 4 bytes, `"<HBB"`):**

Within each `(w1, w2)` CSR slice (capped at `<= 32` records), sorted strictly by `nextWordId ASC`.

| Rel offset | Size | Type | Field | Meaning |
|---:|---:|---|---|---|
| `+0` | 2 | `UInt16` | `nextWordId` | `.kdict` word ID (`0 ..< vocabCount`) |
| `+2` | 1 | `UInt8` | `logProbQ` | Quantized $\log_{10} P_{\text{KN}}(w_3 \mid w_1, w_2)$ |
| `+3` | 1 | `UInt8` | `reserved` | `0` |

**Loader validation (`BinaryLanguageModel.init(storage:)`):** Verify `data.count >= 64`, magic `"KLAM"`, `version == 1`, `flags == 0`, `vocabCount <= 65534`, finite ordered quantization floats, exact non-overflowing table offsets with `trigramsOffset + trigramCount * 4 <= data.count`, `unigrams[vocabCount + 1].bigramStart == bigramCount`, and `trigramContexts[trigramContextCount].trigramStart == trigramCount`.

#### Lookup algorithms

1. `prepareContext(prev1: LMContextToken?, prev2: LMContextToken?) -> PreparedLMContext` runs **once** per keystroke per language:
   - Maps `prev1` to `idx1` (`vocabCount` for `.bos`, `Int(id)` for `.word(id)` if `< vocabCount`, else `nil`).
   - If `idx1 != nil`, reads `bigramRange = unigrams[idx1].bigramStart ..< unigrams[idx1+1].bigramStart` and `bigramBow = decodeLogBow(unigrams[idx1].backoffWeightQ)`.
   - If `prev2` maps to `idx2` AND `prev1` is `.word(w1)` with `w1 < vocabCount`: binary-searches `unigrams[idx2]`'s bigram slice for `UInt16(w1)`. If found at `bIdx` with `trigramBowQ != 0xFF`, binary-searches Table 3 for `bigramIndex == bIdx` to populate `trigramRange` and `trigramBow`.
2. `logProbability(of wordId: UInt32, in ctx: PreparedLMContext) -> (logProb: Double, matchedOrder: UInt8)`:
   - If `wordId >= vocabCount`: returns `(Double(minLogProb), 0)`.
   - If `ctx.trigramRange` contains `UInt16(wordId)`: returns `(decodeLogProb(t.logProbQ), 3)`.
   - If `ctx.bigramRange` contains `UInt16(wordId)`: returns `(min(0.0, ctx.trigramBow + decodeLogProb(b.logProbQ)), 2)`.
   - Otherwise: returns `(clamp(ctx.trigramBow + ctx.bigramBow + decodeLogProb(u.unigramLogProbQ), minLogProb - 2.0, 0.0), 1)`.
3. `topNextWords(in ctx: PreparedLMContext, limit: Int) -> [LMNextWordPrediction]`:
   - If `ctx.trigramRange == nil && ctx.bigramRange == nil`, returns `[]` (prevents 4-language unigram spam after an unknown word while still serving curated `<BOS>` starters at sentence start).
   - Scans `ctx.trigramRange` (<= 32 items) into a top-`limit` array sorted by descending `logProb`.
   - Scans `ctx.bigramRange` (<= 512 items), computing `score = min(0.0, ctx.trigramBow + decodeLogProb(b.logProbQ))`. Only if `results.count < limit || score > results.last!.logProb`, binary-searches `ctx.trigramRange` to skip words already scored as trigrams, then inserts.

---

### 2. Build pipeline

- **Language & environment:** Pure Python 3.10+ (stdlib only, no C++ compiler or KenLM dependency) so it runs identically on Windows and macOS CI.
- **Scripts:**
  - `Scripts/fetch_corpora.py`: downloads pinned Leipzig `*_web_*_1M.tar.gz` + `*_news_*_1M.tar.gz` and Tatoeba sentence exports for `en, cs, sk, et, ru` into gitignored `Data/corpora/`, verifying SHA-256 checksums.
  - `Scripts/build_dicts.py` (minor extension): allow compiling 50,000-word `.kdict` from the same normalized corpus counts with `--skip-legacy-bigrams` (so production `.kdict` doesn't duplicate `.klm` data, while default behavior keeps starter tests green).
  - `Scripts/build_lm.py`: reads compiled `<lang>.kdict` (as the authoritative vocabulary + `vocabFingerprint`) and sentence files, trains Modified Kneser-Ney, prunes, quantizes, and writes `KeyboardExtension/Resources/Dictionaries/<lang>.klm`.
  - `Scripts/verify_lm.py`: mirrors `BinaryLanguageModel.swift` byte-for-byte in Python, checks fingerprint parity against `<lang>.kdict`, checks probability/sorting invariants, and asserts golden predictions for all 5 languages.

#### Corpus preprocessing rules

1. Blend Leipzig `web` + `news` sentences (weight `1`) with Tatoeba sentences (weight `4`) per language.
2. Sentence splitting on `.`, `!`, `?`, `\n`; wrap each sentence with `<BOS>` and `<EOS>`.
3. Internal punctuation (`,`, `;`, `:`, quotes, brackets, dashes) emits `<OOV>` so bigrams never bridge across clauses.
4. Normalize curly apostrophe `’` (U+2019) to ASCII `'` (U+0027). Lowercase tokens, keeping **full canonical diacritics** (never fold diacritics during n-gram counting).
5. Russian `ё` preprocessing: keep ambiguous pairs (`все`/`всё`, `небо`/`нёбо`, `узнаем`/`узнаём`) untouched so context separates them; optionally normalize unambiguous `ё`-only words (`еще` -> `ещё`) using a small static list before counting so `ещё` doesn't split its probability mass.
6. Blocklist: keep profanity searchable in `.kdict` if typed, but exclude profanity words from appearing as `nextWordId` in `.klm` next-word tables.

#### Two-pass Modified Kneser-Ney estimation and pruning

1. **Pass 1 (unigrams + bigrams):** Map tokens to `.kdict` `wordId` (`0..<V`), `<BOS>`, or `OOV`. Count all in-vocab unigrams and bigrams (skipping pairs touching `OOV`). Compute exact MKN discounts $D_1, D_2, D_{3+}$ from raw bigram count-of-counts $n_1..n_4$, continuation unigram probabilities $P_{\text{cont}}(w)$, and full interpolated $P_{\text{KN}}(w_2 \mid w_1)$.
2. **Bigram pruning:**
   - Drop raw count `< 3` (use `< 2` for `<BOS>` bigrams and for `et`/`sk` if total tokens < 15M).
   - Rank surviving bigrams by Stolcke weighted KL loss: $\Delta H(u, v) = P_{\text{emp}}(u, v) \cdot [\ln P_{\text{KN}}(v \mid u) - \ln(\gamma(u) P_{\text{cont}}(v))]$.
   - Protect top 3 continuations for the top 15,000 unigrams (and top 32 for `<BOS>`) so common words always populate the 3-slot bar; fill the rest by descending $\Delta H$ up to the target bigram cap, capping any single context at **512 bigrams max**.
   - Recompute post-pruning $\text{bow}(u) = \text{clamp}\!\left(\frac{1 - \sum_{v \in \text{kept}(u)} P_{\text{KN}}(v \mid u)}{1 - \sum_{v \in \text{kept}(u)} P_{\text{cont}}(v)},\; 10^{-6},\; 100.0\right)$.
3. **Pass 2 (trigrams):** Take the top `trigramContextCap` kept bigrams (including `(<BOS>, w1)`) by empirical frequency as eligible contexts. Stream sentences a second time counting only trigrams whose `(w1, w2)` is in that eligible set. Compute exact MKN discounts $D_1^{(3)}, D_2^{(3)}, D_{3+}^{(3)}$ and interpolated $P_{\text{KN}}(w_3 \mid w_1, w_2)$. Drop raw count `< 3` (`< 2` for `et`/`sk`), rank by Stolcke $\Delta H(u, v, w)$, keep up to `trigramCap` trigrams with **max 32 trigrams per `(w1, w2)` context**, discard contexts that retained 0 trigrams, and recompute post-pruning $\text{bow}(u, v)$.

#### Target budgets per language

| Language | Vocab (`V`) | Bigrams | Trigram contexts | Trigrams | Uncompressed `.klm` |
|---|---:|---:|---:|---:|---:|
| `en` | 50,000 | 350,000 | 45,000 | 250,000 | **3.16 MB** |
| `ru` | 50,000 | 350,000 | 45,000 | 250,000 | **3.16 MB** |
| `cs` | 50,000 | 300,000 | 40,000 | 200,000 | **2.72 MB** |
| `sk` | 50,000 | 250,000 | 35,000 | 180,000 | **2.40 MB** |
| `et` | 50,000 | 250,000 | 35,000 | 180,000 | **2.40 MB** |
| **Total** | — | **1,500,000** | **200,000** | **1,060,000** | **13.84 MB** (~7.5 MB in IPA) |

---

### 3. Scoring formula and integration with existing autocorrect

#### Mid-word typing (`typedWord` non-empty)

[MultilingualEngine.swift](../Packages/KeyboardCore/Sources/KeyboardCore/Lexicon/MultilingualEngine.swift#L223-L314) already adds a unigram frequency prior (`frequency * 0.9` / `0.85` / `0.75`). Adding raw $\log_{10} P_{\text{KN}}(w \mid h)$ would double-count unigram frequency. Instead, compute the **clamped pointwise contextual lift**:

$$\Delta_{\text{ctx}}(w \mid h) = \text{clamp}\!\left(\log_{10} P_{\text{KN}}(w \mid h) - \log_{10} P_{\text{KN}}(w),\; -1.5,\; +2.5\right)$$

When context is empty, OOV, or `.klm` is absent, $\Delta_{\text{ctx}} = 0.0$ identically, preserving all existing unigram thresholds (`1.30` autocorrect floor, `0.15` diacritic override margin).

Replace `bigramBoost` in each candidate group (before multiplying by `momentumBoost = 1.0 + momentum * 0.40`):

- **Exact & diacritic-restoration matches:**
  `baseScore = (isLiteral ? 2.45 : 2.35) + frequency * 0.90 + 0.25 * contextLift`
  - Maximum swing between a strong contextual match (`+2.5`) and a disfavored homograph (`-1.0`) is `+0.875`, enough to clear the `0.10 + 0.15 = 0.25` literal margin for `"это всё"` vs `"пришли все"` and `"on má"` vs `"to ma"`.
- **Fuzzy autocorrect matches:**
  `baseScore = 2.10 - fuzzy.editCost * 0.85 + frequency * 0.85 + 0.28 * contextLift`
  - Maximum positive boost is `2.5 * 0.28 = +0.70`, which is less than one non-adjacent edit (`0.85`). Context resolves adjacent-key and transposition ties (`"I want ot"` -> `"to"` beats `"of"`) and pushes implausible 1-edit candidates below `1.30`, without hallucinating a 2-edit word over a clean 1-edit word.
- **Prefix completions (`typedWord.count >= 2`):**
  `baseScore = 1.15 + frequency * 0.75 + 0.30 * contextLift - lengthPenalty`
- **1-character context completions (`typedWord.count == 1` with non-empty `lmContext`):**
  Filter `lm.topNextWords(in: lmContext, limit: 12)` where `DiacriticFolding.fold(word).hasPrefix(foldedTyped)` and append to `prefixCandidates` with `baseScore = 1.35 + ((logProb - minLogProb) / -minLogProb) * 0.85`. Typing `"y"` after `"thank "` immediately surfaces `"you"` without doing a full trie prefix crawl at depth 1.

#### Next-word prediction after space (`typedWord` empty)

Here we want true conditional probability, not PMI lift:

$$\text{score}(w, L) = \frac{\log_{10} P_{\text{KN}}(w \mid h) - \text{minLogProb}}{-\text{minLogProb}} \cdot \text{orderBonus} \cdot \text{momentumBoost}_L$$

- `orderBonus`: `1.20` for trigram hit (`matchedOrder == 3`), `1.00` for bigram or `<BOS>` hit (`matchedOrder == 2`).
- `momentumBoost`: `1.0 + (languageMomentum[L] ?? 0.0) * 0.45` (existing value).
- **Language-momentum tie-breaker at sentence start:** In `MultilingualEngine.resetSentenceMomentum()`, decay existing momentum by `0.30` (capped at `0.20`) instead of `removeAll()`, or keep a `lastActiveLanguage` hint (`+0.12` tie-break). That way `<BOS>` starters after a period stay in the language the user was just typing instead of interleaving English, Slovak, Czech, and Estonian starters equally, while a single committed word in another language still flips momentum right away.
- **Language-momentum boost from bigram hits:** In `recordCommittedWord(_:previousWord:activeLanguages:)`, if a language matches a stored bigram `(previousWord, word)` in `.klm`, add `+0.20` extra momentum (clamped to `1.0`). Ambiguous words like `"to je"` lock onto Czech/Slovak immediately.

#### Phase 2 personal overlay blend (additive later)

With decayed user counts $c_{\text{user}}(u, v)$ and $c_{\text{user}}(u)$, compute $P_{\text{user}}(v \mid u) = \frac{c_{\text{user}}(u, v)}{c_{\text{user}}(u) + 5.0}$ and interpolate linearly in probability space before taking $\log_{10}$:

$$P_{\text{final}}(w \mid h) = (1 - \mu) P_{\text{static}}(w \mid h) + \mu P_{\text{user}}(w \mid h), \qquad \mu = \min\!\left(0.55,\; \frac{c_{\text{user}}(u)}{c_{\text{user}}(u) + 8.0}\right)$$

On Day 1, $\mu = 0$. Cross-language personal pairs (`"ahoj"` -> `"bro"`) and OOV contact names surface through `P_user` even when `P_static = 0`.

---

### 4. Exact Swift integration points

| File | Types & functions to add or change |
|---|---|
| `Packages/KeyboardCore/Sources/KeyboardCore/Lexicon/BinaryLanguageModel.swift` *(new)* | `LanguageModelError`, `LMContextToken` (`.bos`, `.word(UInt32)`), `LMNextWordPrediction`, `PreparedLMContext`, `BinaryLanguageModel` (`init(contentsOf:)`, `init(data:)`, `prepareContext(prev1:prev2:)`, `unigramLogProbability(of:)`, `logProbability(of:in:)`, `contextLift(of:in:)`, `topNextWords(in:limit:)`, `buildInMemory(...)`). |
| [BinaryDictionary.swift](../Packages/KeyboardCore/Sources/KeyboardCore/Lexicon/BinaryDictionary.swift) | Add `public let wordId: UInt32` to `FuzzyWordMatch` (populated at line 247 where `match.wordId` is already in scope). Add `public func word(at wordId: UInt32) -> DictionaryWordMatch?` (exposing `readWord(at:)`), `public func exactWordId(for word: String) -> UInt32?` (prefers literal lowercased match before falling back to top folded match), and `public func vocabFingerprint(prefixCount: Int) -> UInt64`. |
| [MultilingualEngine.swift](../Packages/KeyboardCore/Sources/KeyboardCore/Lexicon/MultilingualEngine.swift) | Add `private var languageModels: [LanguageCode: BinaryLanguageModel] = [:]` and `registerLanguageModel(_:for:)`. Extend `loadDictionaries(from:languages:)` to map `<lang>.klm` and validate `vocabFingerprint`. Extend `recordCommittedWord(_:previousWord:activeLanguages:)` and `resetSentenceMomentum()`. Add default-argument parameters `secondPreviousWord: String? = nil, isSentenceStart: Bool = false` to `nextWordSuggestions(...)` and `suggestions(...)`. Replace `bigramBonusByWord` top-8 loop with `PreparedLMContext` pointwise `contextLift` when `languageModels[language] != nil`, keeping the legacy `.kdict` bigram loop as fallback when `.klm` is absent. |
| [TypingSessionController.swift](../Packages/KeyboardCore/Sources/KeyboardCore/Input/TypingSessionController.swift) | Add `private(set) public var secondPreviousCommittedWord: String?`, `private(set) public var isAtSentenceStart: Bool = true`, and private `previousWordStartedSentence: Bool`. Extend `LookupKey` with `secondPreviousWord` and `isSentenceStart`. Fix sentence-boundary leakage in `handleSpace` (double-space period, lines 97 to 111) and `handlePunctuation` (lines 121 to 136): clear `previousCommittedWord` and `secondPreviousCommittedWord` on all punctuation, setting `isAtSentenceStart = true` for `.`, `!`, `?`, `\n` and `false` for `,`, `;`, `:`, digits. Replace `extractTrailingWord(from:)` with `extractTrailingContext(from:)` returning `(currentWord, previousWord, secondPreviousWord, isSentenceStart)`. Update `commitCurrentWord` and `acceptSuggestion` to shift `secondPreviousCommittedWord = previousCommittedWord`. |
| [SuggestionToolbarView.swift](../KeyboardExtension/Views/SuggestionToolbarView.swift) | Fix `updateSuggestions(_:)` (lines 117 to 130) so that when `isQuickPasteAvailable == true` and the user has not typed into the current word (pass `hasActiveWord: Bool` or clear quick-paste on first keystroke), `quickPasteButton` stays visible instead of being hidden by `<BOS>` sentence-start predictions. |
| [KeyboardViewController.swift](../KeyboardExtension/KeyboardViewController.swift) | Phase 1 needs only the `quickPasteButton` check and passing `shiftState == .capsLock` if uppercase next-word display is desired (`.klm` files in `KeyboardExtension/Resources/Dictionaries/` are bundled automatically by [project.yml](../project.yml#L62-L64)). Phase 2 adds `PersonalLanguageStore` initialization, `requestSupplementaryLexicon` in `viewDidLoad`, `isSecureTextEntry` guard before recording commits, and `personalStore.flushIfNeeded()` in `viewWillDisappear`. |

---

### 5. Edge cases

- **Sentence start (`<BOS>`):** Empty document, after `\n`, after `. `, `! `, `? `, or after double-space period sets `isAtSentenceStart = true` and `prev1 = .bos`. Right after typing `.` (before Space), keep suggestions empty; after Space, serve `<BOS>` predictions. After word 1 of a sentence, `prev2 = .bos, prev1 = word1` activates sentence-initial trigrams `(<BOS>, word1, word2)` automatically. Quick-paste chip takes precedence over `<BOS>` predictions until the first keystroke.
- **Punctuation & apostrophes:** Terminal punctuation (`.`, `!`, `?`, `\n`) resets previous words and sets `isAtSentenceStart = true`. Clause punctuation (`,`, `;`, `:`, quotes, brackets, numbers) clears `previousCommittedWord` and `secondPreviousCommittedWord` with `isAtSentenceStart = false` (no fake cross-comma bigrams, momentum stays intact). Normalize curly `’` (U+2019) to `'` (U+0027) in both corpus tokenization and `exactWordId`. Also allow `-` in `previousWord` inside `extractTrailingContext` (currently [TypingSessionController.swift](../Packages/KeyboardCore/Sources/KeyboardCore/Input/TypingSessionController.swift#L288-L311) allows `-` in `currentWord` but strips it from `previousWord`), so Russian hyphenated particles (`как-то`, `что-то`, `всё-таки`) stay intact.
- **Capitalization:** `.klm` and `.kdict` store words lowercase. `nextWordSuggestions` must apply two casing rules missing today: (1) for `.english`, always capitalize `"i"` -> `"I"` and `"i'..."` -> `"I'..."`; (2) when `isSentenceStart == true`, title-case the first grapheme (`String(word.prefix(1)).uppercased() + word.dropFirst()`, which handles `ď -> Ď`, `ř -> Ř`, `õ -> Õ`, `ё -> Ё`). When Caps Lock is active, uppercase the suggestion text.
- **Mixed-language text:** Each `.klm` resolves `prev1`/`prev2` strictly against its own `.kdict`. Mid-sentence code-switching (`"I think že to "`) drops out of `en.klm` naturally (`"že"` is OOV in English -> `[]` and `contextLift = 0`) and picks up `sk.klm`/`cs.klm` trigrams (`("že", "to")` -> `"je"`). Cyrillic and Latin never overlap because `settings.activeLanguagesForCurrentLayout()` partitions layouts by script. Cross-language pairs (`"ahoj"` -> `"bro"`) are covered by Phase 2's language-agnostic personal store.
- **Cyrillic (`ru`):** Because `.klm` stores `UInt16` word IDs rather than UTF-8 strings, Russian `.klm` has zero UTF-8 size penalty compared to English. `DiacriticFolding` preserves `й` distinct from `и` (`мой` != `мои`). For `ё`/`е`, `exactWordId(for:)` prefers the literal form so committing `"всё"` keeps `"всё"`'s context separate from `"все"`, while typing `"все"` lets `contextLift` pick between `"все"` and `"всё"`.
- **Diacritic folding (`sk`, `cs`, `et`):** Same rule as Russian `ё`. When a user types `"ma"` in Slovak or `"ze"` in Czech, both folded variants receive independent `contextLift` scores. If autocorrect is OFF and the user commits unaccented `"dakujem"`, `exactWordId(for: "dakujem")` finds no literal `"dakujem"` in `sk.kdict`, falls back to the top folded match `"ďakujem"`, and still predicts `"veľmi"`.

---

### 6. Test plan

#### Windows-runnable Python tests (`Scripts/verify_lm.py` + `Scripts/test_build_lm.py`)

- **Format & parity:** Verify header magic, version, flags, float ranges, 4-byte offset alignment, exact file size, sentinel values, `nextWordId < vocabCount`, strict ascending `nextWordId` within every bigram and trigram slice, strict ascending `bigramIndex` in Table 3, and `vocabFingerprint` match against compiled `<lang>.kdict`. Negative test: swap two words in `.kdict` and verify fingerprint mismatch fails.
- **Math invariants:** Verify MKN discount bounds (`0 < D_k < k`), probability normalization (`sum(kept P) + bow * sum(backoff P) ≈ 1.0` within quantization tolerance), quantization round-trip error `<= (max - min) / 254`, and per-context caps (`<= 512` bigrams, `<= 32` trigrams).
- **Golden linguistic assertions across all 5 languages (on full corpora):**
  - `en`: `thank` -> `you`; `i don't` -> `know`/`think`/`want`; `P("to" | "i", "want") > P("of" | "i", "want")`.
  - `sk`: `ako sa` -> `máš`; `ďakujem` -> `veľmi`; `P("má" | "on") > P("ma" | "on")`.
  - `cs`: `jak se` -> `máš`; `děkuji` -> `moc`; `to` -> `je`.
  - `et`: `kuidas` -> `läheb`; `ma ei` -> `tea`/`ole`/`saa`; `kõik` -> `on`.
  - `ru`: `я не` -> `знаю`/`могу`; `у меня` -> `нет`/`есть`; `P("всё" | "это") > P("все" | "это")` and `P("все" | "почти") > P("всё" | "почти")`.
- **Size budgets:** Assert each production `.klm <= 3.5 MB`.

#### Swift unit tests (`swift test --package-path Packages/KeyboardCore` on macOS CI)

- **`BinaryLanguageModelTests.swift` (new):**
  - `buildInMemory` round-trip for unigram, bigram, trigram, `<BOS>`, and `(<BOS>, w1, w2)` lookups.
  - Rejection of truncated header, bad magic, unsupported version, non-zero flags, corrupted offsets, bad sentinels, and invalid float bounds.
  - Backoff chain tests covering both negative and positive `trigramBowQ`, `0xFF` no-trigram sentinel fast path, and OOV `wordId` / OOV context handling.
  - `topNextWords` deduplication when a word exists in both trigram and bigram slices, and empty return when context has neither.
  - Loading shipped `.klm` via `NSData(.alwaysMapped)` and asserting `vocabFingerprint` matches shipped `.kdict`.
- **`MultilingualEngineTests.swift` (additions):**
  - Typo tie-break: `"I want ot"` autocorrects to `"to"` over `"of"` using `.klm`.
  - Diacritic homograph disambiguation: Russian `"это все"` -> `"всё"` vs `"пришли все"` -> `"все"`; Slovak `"on ma"` -> `"má"` vs `"to ma"` -> `"ma"`.
  - Simultaneous 4-language context: `"ako sa "` ranks Slovak `"máš"` above Estonian continuations of `"sa"`.
  - 1-char prefix context completion: `"thank "` + `"y"` includes `"you"`.
  - Casing in `nextWordSuggestions`: English `"i"` -> `"I"` and `<BOS>` title-casing.
  - Fallback behavior when `.klm` is missing or fingerprint mismatches `.kdict`.
- **`TypingSessionControllerTests.swift` (additions):**
  - `secondPreviousCommittedWord`, `previousCommittedWord`, and `isAtSentenceStart` across typing, Space, suggestion tap, backspace into previous word, and `syncWithDocumentContext`.
  - Regression tests for sentence boundary bugs: `.`, `!`, `?`, `\n`, and double-space period clear previous words and set `isAtSentenceStart = true`; `,` clears previous words with `isAtSentenceStart = false`.
  - Curly apostrophe `’` normalization and hyphen preservation in `previousCommittedWord`.
- **`PersonalLanguageStoreTests.swift` (Phase 2):**
  - Count update, decay, 4,000-entry eviction cap, cross-language user bigrams, secure-field opt-out, private vs App Group fallback path, and companion-app reset timestamp invalidation.

#### On-device iOS checks (Mac + physical iPhone)

- Xcode Instruments **Allocations** & **VM Tracker** on a physical iPhone with all 5 `.kdict` + `.klm` files loaded: confirm dirty `phys_footprint < 25 MB` and `0 MB` dirty delta from mapping `.klm`.
- **Time Profiler** on device: confirm p95 `< 2 ms` per character tap and `< 0.5 ms` per Space next-word refresh.
- Manual test with **Allow Full Access OFF** and **ON**: verify predictions work identically offline without Full Access, Quick Paste chip still shows in an empty field when clipboard changed, and Phase 2 personal bigrams survive keyboard dismiss/reopen.

---

## Work breakdown

Split into **tricky tasks** (architecture, math, engine behavior, and edge-case semantics that need careful review) and **mechanical tasks** (implementable directly from the spec above by another agent).

### Tricky parts (design-sensitive, do first or review closely)

1. **T1. Vocabulary fingerprint & `BinaryDictionary` API additions** (`BinaryDictionary.swift` + `build_dicts.py` parity). Define the exact FNV-1a 64-bit `vocabFingerprint` in both Swift and Python, add `wordId` to `FuzzyWordMatch`, add `word(at:)` and literal-first `exactWordId(for:)`.
2. **T2. Modified Kneser-Ney trainer & Stolcke pruner** (`Scripts/build_lm.py` core algorithm). Implement two-pass counting, exact $D_1, D_2, D_{3+}$ discounting, continuation unigrams, post-pruning backoff renormalization, and Russian `ё` / apostrophe / clause-boundary tokenization rules.
3. **T3. Scoring integration & multilingual disambiguation** (`MultilingualEngine.swift`). Wire `PreparedLMContext`, $\Delta_{\text{ctx}}$ lift weights (`0.25`/`0.28`/`0.30`), 1-character context completions, `<BOS>` momentum carry-over, trigram `orderBonus`, English `"I"` / `<BOS>` casing, and clean fallback when `.klm` is absent.
4. **T4. Two-word history & sentence-boundary state machine** (`TypingSessionController.swift` + `SuggestionToolbarView.swift`). Fix the existing `.`/double-space/comma context-leak bugs, extend `extractTrailingContext`, track `previousWordStartedSentence` for `(<BOS>, w1, w2)`, and preserve Quick Paste precedence over `<BOS>` predictions.
5. **T5. Phase 2 personal learning & sandbox split** (`PersonalLanguageStore.swift` + `KeyboardViewController.swift`). Handle `!hasFullAccess` private container persistence vs App Group mirroring, companion-app reset timestamp, `isSecureTextEntry` filtering, `requestSupplementaryLexicon`, and avoiding learning immediately-undone typos.

### Mechanical parts (self-contained from this spec)

1. **M1. Corpus downloader & notice generator** (`Scripts/fetch_corpora.py`, `THIRD_PARTY_NOTICES.md`, `README.md` update). Download pinned Leipzig `web`/`news` and Tatoeba archives for `en, cs, sk, et, ru` with SHA-256 verification into gitignored `Data/corpora/`, and replace the `hermitdave/FrequencyWords` instructions in `README.md`. Depends on: none.
2. **M2. Binary `.klm` serializer & Python byte verifier** (`Scripts/build_lm.py` writer + `Scripts/verify_lm.py` + `Scripts/test_build_lm.py`). Pack the 64-byte header and 4 tables byte-for-byte per Section 1, verify offsets/sentinels/sorting/quantization/fingerprint parity, and run golden assertions on Windows. Depends on: T1, T2.
3. **M3. Swift `BinaryLanguageModel` reader & in-memory builder** (`Packages/KeyboardCore/Sources/KeyboardCore/Lexicon/BinaryLanguageModel.swift`). Implement `NSData(.alwaysMapped)` loader, header/sentinel validation, `loadUnaligned` table readers, `prepareContext`, `logProbability`, `contextLift`, `topNextWords`, and `buildInMemory` matching the exact byte layout in Section 1. Depends on: T1.
4. **M4. Swift unit test suites** (`BinaryLanguageModelTests.swift` + additions to `MultilingualEngineTests.swift` and `TypingSessionControllerTests.swift`). Implement all test cases listed in Section 6, including starter `.klm` fixture checks. Depends on: M3, T3, T4.
5. **M5. CI pipeline wiring** ([.github/workflows/ios-ci.yml](../.github/workflows/ios-ci.yml)). Add `python3 Scripts/build_lm.py` (starter mode by default in CI) and `python3 Scripts/verify_lm.py` right after the `.kdict` build/verify step. Depends on: M2.

---

### Citations

- **Leipzig Corpora Collection (Wortschatz):** Downloadable corpora licensed CC BY 4.0; live web platform queries CC BY-NC (`wortschatz-leipzig.de`, `uni-leipzig.de`).
- **Tatoeba:** Text sentences licensed CC BY 2.0 FR / CC0 1.0 (`tatoeba.org`).
- **FineWeb-2 / FineWeb:** ODC-By 1.0 (`huggingface.co/datasets/HuggingFaceFW/fineweb-2`).
- **HPLT v2/v3:** CC0 1.0 dataset packaging (`hplt-project.org`).
- **OpenSubtitles / OPUS & `hermitdave/FrequencyWords`:** OPUS third-party copyright disclaimer (`opus.nlpl.eu`), OpenSubtitles non-commercial restriction (`opensubtitles.com`), `hermitdave/FrequencyWords` CC BY-SA 4.0 content license (`github.com/hermitdave/FrequencyWords`).
- **Wikipedia / Wikimedia:** CC BY-SA 4.0 and anti-TPM clause (`wikimedia.org`, `creativecommons.org/licenses/by-sa/4.0/`).
- **Czech National Corpus & Estonian National Corpus:** Academic non-commercial / CC BY-NC-SA (`korpus.cz`, `ut.ee`, `clarin.eu`).
- **Google Books Ngrams:** CC BY 3.0 / 4.0; core corpus covers English and Russian, omits Czech, Slovak, and Estonian (`opendata.aws`, `wikipedia.org`).
- **Gboard CIFG-LSTM:** Hard et al. (2018), *Federated Learning for Mobile Keyboard Prediction*, arXiv:1811.03604 (1.4M params, 1.4 MB quantized, 10k vocab, $D=96$).
- **FUTO Keyboard Transformer:** 36M-param Llama variant, English-only, documented lag on older phones, FUTO Source First non-commercial license (`futo.org`, `futo.tech`).
- **iOS keyboard extension sandbox, `UILexicon`, and `mmap` `phys_footprint`:** Apple Developer Documentation for Custom Keyboards (`RequestsOpenAccess`, `requestSupplementaryLexicon`, `NSData.ReadingOptions.mappedIfSafe` / `alwaysMapped`, `developer.apple.com`).