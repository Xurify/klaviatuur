# Klaviatuur — Pixel-Inspired Multilingual iOS Keyboard

Klaviatuur is a native Swift iOS custom keyboard (`UIInputViewController`) built to bring the Google Pixel 8 Gboard typing experience to iOS without Gboard's 3-language limit.

## What's Included

- **Unlimited Simultaneous Languages (5 built-in: English, Slovak, Czech, Estonian, Russian)**
  - Type across **all enabled Latin languages simultaneously** (`EN · SK · CS · ET`) with automatic diacritic restoration (`dakujem → ďakujem`, `prilis → příliš`, `tanan → tänan`, `еще → ещё`) and sentence-level language momentum.
  - Switch instantly to **Russian Cyrillic (`RU`)** via the Globe key, top-right language badge, or long-pressing Spacebar. Long-press Globe to switch to other iOS keyboards (such as Emoji).
  - Beats iOS's ~48–60 MB keyboard extension RAM ceiling using compact, zero-copy **memory-mapped binary dictionaries (`.kdict`) and language models (`.klm`)**.
- **Pixel 8 Layout & Touch Feel**
  - Zero-latency UIKit multi-touch surface with rollover typing (no SwiftUI button lag).
  - Dedicated number row (toggleable), subtle top-right long-press symbol hints, floating key popups, and slide-to-pick long-press diacritic strips (`á ä č ď é ě í ľ ĺ ň ó ô õ ö ř ŕ š ť ú ů ü ý ž ё ъ`).
  - Dynamic Material You Dark & Light themes, haptics, hold-to-repeat backspace, double-tap Shift for Caps Lock, and spacebar cursor scrubbing.
- **Autocorrect, Predictions & Probabilistic Key Hitboxes**
  - Keyboard-proximity weighted Damerau-Levenshtein autocorrect + Kneser-Ney bigram/trigram next-word prediction bar.
  - **Probabilistic Key Hitboxes**: taps near the border between two keys dynamically favor the linguistically probable next letter across your active languages while keeping center taps 100% deterministic.
  - Instant **Undo Autocorrect on Backspace**.
- **Clipboard History & Pinned Snippets**
  - Inline Pixel-style 2-column clipboard panel inside the keyboard, one-tap quick-paste chip when new text is copied, and persistent pinned snippets synced via App Groups with the companion app.

## Project Layout

```text
klaviatuur/
├── project.yml                      # XcodeGen project definition
├── .github/workflows/ios-ci.yml     # macOS CI: SwiftPM tests + XcodeGen + unsigned .ipa
├── Scripts/
│   ├── fetch_corpora.py             # Downloads the pinned Leipzig and Tatoeba corpora
│   ├── build_lm.py                  # Corpora -> word lists and .klm n-gram models
│   ├── build_dicts.py               # Word lists -> .kdict binary dictionaries
│   ├── evaluate_lm.py               # Next-word quality on held-out sentences
│   └── verify_dicts.py, verify_lm.py
├── Data/sources/                    # 50,000-word frequency lists (en, sk, cs, et, ru)
├── Packages/KeyboardCore/           # Pure Swift engine + XCTest suite
├── KeyboardExtension/               # UIInputViewController + Pixel UIKit views
└── App/                             # SwiftUI companion app (Setup, Languages, Clipboard, Preferences)
```

## Testing on Your iPhone

You need a Mac with Xcode, your iPhone and a USB cable. A free Apple ID is enough to start; apps it signs stop opening after 7 days, so run them again from Xcode to renew.

1. **Generate the Xcode project** (the dictionaries and models are already in the repo):
   ```bash
   brew install xcodegen
   xcodegen generate
   open Klaviatuur.xcodeproj
   ```
2. **Set up signing.** In Xcode, for both the **Klaviatuur** and **KlaviatuurKeyboard** targets, open **Signing & Capabilities** and pick your team (your Apple ID).
   - If Xcode says the bundle ID is taken, use your own prefix, such as `com.yourname.klaviatuur` and `com.yourname.klaviatuur.keyboard`; the keyboard's ID must start with the app's.
   - Both targets need the same App Group. If you change it from `group.com.klaviatuur.shared`, change it in `AppGroupStorage.swift`, `App/Klaviatuur.entitlements` and `KeyboardExtension/KlaviatuurKeyboard.entitlements` too.
3. **Prepare the iPhone.** Plug it in and tap **Trust** on the phone. On iOS 16 or later, turn on **Settings → Privacy & Security → Developer Mode** and let the phone restart.
4. **Install.** Choose your iPhone as the run destination and run the **Klaviatuur** scheme. The first time, iOS may block it: open **Settings → General → VPN & Device Management**, select your Apple ID and tap **Trust**, then run again.
5. **Turn the keyboard on.** **Settings → General → Keyboard → Keyboards → Add New Keyboard → Klaviatuur**. Tap **Klaviatuur** in the list and turn on **Allow Full Access** if you want clipboard history and haptics; typing and predictions work without it.
6. **Try it.** Open Notes or Messages, hold the globe key and pick Klaviatuur, then check:
   - type `dakujem`, `prilis`, `tanan` and see the accents restored;
   - mix English, Czech, Slovak and Estonian in one sentence without switching;
   - after a few words, the bar shows next-word predictions; after `thank`, expect `you`;
   - an autocorrection followed straight away by Backspace goes back to what you typed;
   - double-tap Shift for Caps Lock, and the suggestions turn to capitals;
   - switch to Russian with the globe key or a long press on the space bar;
   - try a few apps (Safari, WhatsApp, a web form), since each host app feeds the keyboard text differently.

Without a Mac, the unsigned `.ipa` from each CI run can be installed with AltStore or SideStore, which sign it with your Apple ID.

## Debugging the Keyboard on a Device

- **Logs:** with the iPhone connected, open Console.app on the Mac, select the phone and filter by subsystem `com.klaviatuur.app.keyboard`. Turn on **Action → Include Debug Messages** to see how much text the host app gives the keyboard and whether autocorrect undo survives its text-change reports. Typed text is never logged.
- **Debugger:** run the **Klaviatuur** scheme, open any text field with the keyboard showing, then **Debug → Attach to Process → KlaviatuurKeyboard**.
- **Memory and speed:** profile the attached extension with Instruments (Allocations, Time Profiler). iOS ends keyboard extensions at roughly 48 MB.

## Developing from Windows with GitHub Actions CI

Push this repository to GitHub. Every push and pull request runs `.github/workflows/ios-ci.yml` on `macos-15`:
1. Compiles all `.kdict` binary dictionaries (`Scripts/build_dicts.py`).
2. Runs the full `KeyboardCore` unit test suite (`swift test`), then the keystroke latency and memory benchmark in an optimized build.
3. Generates `Klaviatuur.xcodeproj` with XcodeGen and compiles for iOS Simulator.
4. Builds and uploads `Klaviatuur-unsigned.ipa` as a workflow artifact (ready to sign with AltStore/SideStore or on your MacBook).

## Scaling Dictionaries to 50,000+ Words per Language

The repository ships the built 50,000-word dictionaries and models, so everything builds without the corpora. To rebuild the production dictionaries (`.kdict`) and pruned Modified Kneser-Ney bigram/trigram language models (`.klm`) using App Store–safe corpora (Leipzig Corpora Collection CC BY 4.0 + Tatoeba CC BY 2.0 FR; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)):

1. Download the pinned Leipzig (`web`/`news`) and Tatoeba sentence corpora into gitignored `Data/corpora/<lang>/`:
   ```bash
   python3 Scripts/fetch_corpora.py
   ```
2. Generate 50,000-word frequency lists (`Data/sources/<lang>.tsv`) with the shared tokenizer:
   ```bash
   python3 Scripts/build_lm.py wordlists
   ```
3. Compile the `.kdict` binary tries and `.klm` language models, then verify format, fingerprints, and golden predictions:
   ```bash
   python3 Scripts/build_dicts.py --max-words 50000
   python3 Scripts/build_lm.py model
   python3 Scripts/verify_lm.py --golden
   ```
4. Measure the models on the one sentence in 200 that `build_lm.py` holds out of training:
   ```bash
   python3 Scripts/evaluate_lm.py
   ```

Results for the shipped models, with up to 2,000 held-out sentences per language drawn evenly from each corpus file. Czech, Slovak and Estonian have small Tatoeba exports, so their samples are smaller and lean towards news and web text, while a third of the English and Russian samples are short conversational Tatoeba sentences:

| Language | Sentences | Words | Next word top-1 | Next word top-3 | Keystrokes saved | Frequency only |
|---|---|---|---|---|---|---|
| en | 1,998 | 29,602 | 15.1% | 25.1% | 48.8% | 37.5% |
| cs | 1,720 | 20,008 | 9.2% | 16.3% | 37.2% | 28.4% |
| sk | 1,503 | 19,476 | 9.4% | 16.4% | 36.0% | 27.0% |
| et | 1,361 | 17,640 | 7.6% | 12.2% | 33.9% | 27.5% |
| ru | 1,998 | 21,649 | 10.5% | 18.7% | 39.7% | 29.1% |

"Keystrokes saved" counts the letters and spaces skipped by tapping a word as soon as it is one of the three suggestions; "Frequency only" is the same with completions ranked by word frequency and no predictions. Words are typed exactly as written (lowercased), and candidates are ranked by the `.klm` model alone, so the numbers measure the model rather than the full Swift engine with its autocorrect and frequency blending. The split is by sentence text, so exact duplicates never straddle it, though near-duplicate news sentences can. Czech, Slovak and Estonian likely score lower than English because every inflected form is a separate dictionary word, and because their samples hold less conversational text.
