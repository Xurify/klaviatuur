# Third-Party Data Notices

Klaviatuur's bundled word frequency lists (`.kdict`) and statistical next-word language models (`.klm`) are derived from the following open-licensed text corpora:

## Leipzig Corpora Collection (Wortschatz Leipzig)

- **Source:** Leipzig Corpora Collection (`https://wortschatz.uni-leipzig.de/en/download`, `https://downloads.wortschatz-leipzig.de/corpora/`), Natural Language Processing Group, Leipzig University.
- **Subcorpora used:** `*_web_*` and `*_news_*` downloadable sentence archives only (English `eng`, Czech `ces`, Slovak `slk`, Estonian `est`, Russian `rus`). No `*_wikipedia_*` or `*_mixed_*` archives are used.
- **License:** Creative Commons Attribution 4.0 International (**CC BY 4.0**), `https://creativecommons.org/licenses/by/4.0/`.
- **Reference:** Goldhahn, D., Eckart, T., & Quasthoff, U. (2012). *Building Large Monolingual Dictionaries at the Leipzig Corpora Collection: From 100 to 200 Languages.* Proceedings of the 8th International Language Resources and Evaluation (LREC'12).
- **Modifications:** Sentences are tokenized into lowercase words with canonical diacritics and aggregated into pruned unigram, bigram, and trigram probability tables. No original sentences are redistributed in the compiled binary files.

## Tatoeba

- **Source:** Tatoeba per-language sentence exports (`https://tatoeba.org`, `https://downloads.tatoeba.org/exports/per_language/`) for English (`eng`), Czech (`ces`), Slovak (`slk`), Estonian (`est`), and Russian (`rus`).
- **License:** Creative Commons Attribution 2.0 France (**CC BY 2.0 FR**), `https://creativecommons.org/licenses/by/2.0/fr/` (individual sentences may also be released under CC0 1.0).
- **Modifications:** Sentences are tokenized and blended with Leipzig Corpora Collection counts to improve everyday conversational coverage in the compiled unigram, bigram, and trigram tables. No original sentences are redistributed in the compiled binary files.
