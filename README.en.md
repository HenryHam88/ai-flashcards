<div align="center">

<img src="docs/logo.png" width="112" alt="AI Flashcards logo">

# AI Flashcards

**Turn your textbooks into flashcards and quizzes, and remember them with spaced repetition.**

[![Release](https://img.shields.io/github/v/release/HenryHam88/ai-flashcards?color=8FA68B&label=release)](https://github.com/HenryHam88/ai-flashcards/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/HenryHam88/ai-flashcards/total?color=A3B1BD)](https://github.com/HenryHam88/ai-flashcards/releases)
[![License](https://img.shields.io/github/license/HenryHam88/ai-flashcards?color=D9CBB4)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Android%207.0%2B-8FA68B?logo=android&logoColor=white)](#download)
[![Flutter](https://img.shields.io/badge/Flutter-3.50-02569B?logo=flutter&logoColor=white)](https://flutter.dev)

[简体中文](README.md) | **English**

</div>

AI Flashcards (闪卡刷题) is an open-source study app for Android. Import a PDF, Word, or TXT textbook and AI extracts the key points, generates flashcards and practice questions, and schedules your reviews with the FSRS algorithm. Formulas are typeset like a textbook, and all your study data stays on your phone.

> [!NOTE]
> The app interface is currently available in Simplified Chinese only.

## Screenshots

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/1_home.png" width="190"><br><sub>Projects</sub></td>
    <td align="center"><img src="docs/screenshots/2_flashcard.png" width="190"><br><sub>Flashcard review</sub></td>
    <td align="center"><img src="docs/screenshots/3_quiz.png" width="190"><br><sub>Quiz</sub></td>
    <td align="center"><img src="docs/screenshots/14_explain_markdown.png" width="190"><br><sub>AI explanation</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/25_stats_overview.png" width="190"><br><sub>Study data</sub></td>
    <td align="center"><img src="docs/screenshots/8_wrong_mixed.png" width="190"><br><sub>Mistake book</sub></td>
    <td align="center"><img src="docs/screenshots/16_word_doc_list.png" width="190"><br><sub>Documents</sub></td>
    <td align="center"><img src="docs/screenshots/15_word_doc.png" width="190"><br><sub>Parsing settings</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/19_settings.png" width="190"><br><sub>Settings</sub></td>
    <td align="center"><img src="docs/screenshots/23_explain_history.png" width="190"><br><sub>Explanation history</sub></td>
    <td align="center"><img src="docs/screenshots/22_dark.png" width="190"><br><sub>Dark mode</sub></td>
    <td align="center"><img src="docs/screenshots/21_onboarding.png" width="190"><br><sub>Onboarding</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/24_quality_review.png" width="190"><br><sub>Review new cards</sub></td>
    <td align="center"><img src="docs/screenshots/26_mastery.png" width="190"><br><sub>Mastery and weak spots</sub></td>
    <td align="center"><img src="docs/screenshots/27_auto_count.png" width="190"><br><sub>Automatic count</sub></td>
    <td align="center"><img src="docs/screenshots/28_chapter_view.png" width="190"><br><sub>Chapter content</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/29_help_home.png" width="190"><br><sub>In-app help</sub></td>
    <td align="center"><img src="docs/screenshots/30_help_article.png" width="190"><br><sub>Help article</sub></td>
    <td align="center"><img src="docs/screenshots/31_table_render.png" width="190"><br><sub>Tables</sub></td>
    <td align="center"><img src="docs/screenshots/32_latex_text.png" width="190"><br><sub>LaTeX text formatting</sub></td>
    <td align="center"><img src="docs/screenshots/34_txt_doc.png" width="190"><br><sub>TXT files</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/35_new_vs_review.png" width="190"><br><sub>New vs. due</sub></td>
    <td align="center"><img src="docs/screenshots/36_card_badge.png" width="190"><br><sub>Card badges</sub></td>
    <td align="center"><img src="docs/screenshots/37_due_by_day.png" width="190"><br><sub>Due by day</sub></td>
    <td align="center"><img src="docs/screenshots/38_chapter_reparse.png" width="190"><br><sub>Re-parse a chapter</sub></td>
    <td align="center"><img src="docs/screenshots/42_concurrency.png" width="190"><br><sub>Concurrency</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/43_typed_count.png" width="190"><br><sub>Type a count</sub></td>
  </tr>
</table>

## Features

**Documents and generation**
- PDF, Word (.docx / .doc), and TXT, batch import with per-file progress
- TXT files are read on the phone (offline, free) with automatic UTF-8 / UTF-16 / GBK detection, split into sections at paragraph breaks, then chaptered as usual
- Scanned PDFs are supported; formulas are kept as LaTeX
- Automatic chapter detection (bookmarks, table of contents, heading formats, with AI as a fallback), plus a manual chapter editor
- Chapter content viewer: read the parsed text of each chapter page by page with textbook-style formulas, switch chapters, search with highlighting, copy, see which parser produced it, and generate from that chapter in one tap
- Re-parse just one chapter (with a different engine if you like), compare old and new text page by page before replacing it, and undo the last re-parse; view or re-analyze a chapter's knowledge points
- Generate from the whole document, selected chapters, or a page range; choose count (tap the number to type it, up to 1500 cards and 1500 questions, split into batches automatically), question types, difficulty, and focus
- Adjustable concurrency (1–2500, default 4): PDF OCR batches, knowledge-point analysis, and generation batches run in parallel under one shared request limit, with automatic backoff on HTTP 429
- "Automatic (by knowledge point)" count: the knowledge points in the selection are listed first, then about 1 card and 1–3 questions per point (by difficulty) are proposed as "about N items" for you to confirm; a per-generation cap keeps count and cost in check
- Question types: single choice, multiple choice, true/false, fill-in-the-blank, short answer, calculation
- Every card and question links back to its source in the original text
- Automatic quality checks after generation: source matching, formula rendering, multiple-choice validity, and near-duplicate detection; failing items get one batched AI fix or are dropped, with a summary such as "30 generated, 2 auto-fixed, 3 duplicates removed"
- Optional "review before adding": new items wait in an inbox where you can accept, edit, delete, or have AI rewrite them
- Flag any card or question as wrong, too easy, duplicate, out of scope, or unclear; future generation avoids those problems

**Review and practice**
- FSRS spaced-repetition scheduling, swipe to grade, step back and forward through cards
- New and due cards are counted separately (Anki-style): "Learn new", "Review", and "Study all" (due reviews first, then new); 20 new cards a day by default, with "10 more today"; each card is badged new / review / relearn
- Due by day: see which cards come due on which day (including overdue), filter by project, and review them right away
- Objective questions are graded automatically; short-answer and calculation questions are graded by AI
- AI explanations grounded in the source text, with follow-up questions; every explanation is kept in a searchable history you can star and continue
- Mistake book: wrong answers are collected automatically, filterable by project, with new questions generated for weak points
- Study data: daily overview (reviews, accuracy, time, streak), a six-month heatmap, a due forecast for 7 / 30 / 90 days or everything (weekly or monthly bars beyond 30 days; tap a bar to see that day's cards), and mastery per project and chapter
- Weak-spot suggestions based on lapses, mistakes, and recall, with one tap to review them or generate new questions targeting them
- Study settings: daily new / review limits, FSRS desired retention, day start time
- Daily review reminder (local notification, no network needed)

**Data**
- Export everything to a single `.afcbak` backup and restore it on a new phone, including review progress, mistakes, and explanation history
- Integrity check before import; choose "Overwrite" (a safety backup is made first) or "Merge" (keeps the more recent progress for each card)
- Export a single project to share with classmates, with or without your own progress
- Optional weekly automatic backup, keeping the latest 3

**Experience**
- Full LaTeX typesetting and Markdown formatting; tables recognized in your material (formulas included) are shown as real, horizontally scrollable tables; LaTeX text commands outside formulas (`\texttt`, `\textbf`, itemize, tabular, …) are displayed as proper formatting
- Calm Morandi color palette with a glass-style interface, plus dark mode
- Built-in help (我的 → 使用帮助, in Chinese): step-by-step guides for every feature plus an FAQ, searchable and available offline; the **?** button on the key, chapter editor, and generation screens opens the matching guide
- Adjustable text and formula size; reduce motion and haptics toggles
- Review progress is saved automatically

## Download

Get the latest version from [Releases](https://github.com/HenryHam88/ai-flashcards/releases/latest):

| Package | Devices |
| --- | --- |
| `ai-flashcards-<version>-arm64-v8a.apk` | **Most phones (recommended)** |
| `ai-flashcards-<version>-armeabi-v7a.apk` | Older 32-bit devices |
| `ai-flashcards-<version>-x86_64.apk` | Emulators and x86 tablets |

Requires Android 7.0 or later. Allow "Install unknown apps" on first install. New versions install over the old one and keep your data.

<details>
<summary>Signing certificate fingerprint</summary>

```
SHA-256: f5:ec:04:9f:25:ef:21:59:36:28:23:59:4a:08:49:46:f5:66:6d:cc:54:35:19:b9:9a:e1:d0:2f:be:a1:0d:59
```

Verify with `apksigner verify --print-certs <apk>`.
</details>

## Quick start

1. Create an API key on the [DeepSeek Platform](https://platform.deepseek.com/).
2. In the app, open **我的 (Me) → 出题模型 (Generation model)**, paste the key, and tap 测试连接 (Test connection).
3. Create a project, upload a textbook, and tap 生成 (Generate) once parsing finishes.

> [!TIP]
> The generation model works with any OpenAI-compatible API, such as Qwen or Kimi.

## Supported parsing providers

Choose in **我的 → 文档解析（PDF / Word）** (Me → Document parsing):

| Provider | PDF | Word (.docx / .doc) | Scanned | Cost |
| :-- | :-: | :-: | :-: | :-- |
| DeepSeek OCR (default) | ✓ | ✓ | ✓ | Per page |
| Kimi file extraction | ✓ | ✓ | — | Currently free |
| Local text layer | ✓ | — | — | Free, offline |

TXT files ignore this setting and are always read on the phone, free and offline.

## Privacy

- Documents, cards, mistakes, and review history are stored only on your device. The project runs no servers.
- API keys are kept in the system secure storage (Android Keystore).
- Document content is sent only to the providers you configure; "Local text layer" mode never goes online.
- Backups exclude API keys by default; they are included only if you turn on "包含 API 密钥" (backups are not encrypted, so keep them private).

## FAQ

<details>
<summary><b>Is it free?</b></summary>

The app is free and open source. Parsing and generation use your own API key and are billed by that provider. Results are cached, so the same content is never billed twice.
</details>

<details>
<summary><b>Uploading Word says "the current parsing model does not support Word"?</b></summary>

Local text-layer mode reads PDFs only. Switch to DeepSeek OCR or Kimi in parsing settings, or save the document as PDF.
</details>

<details>
<summary><b>How do I move my data to a new phone?</b></summary>

On the old phone open **我的 → 导出 / 导入数据 → 导出数据** and save or share the `.afcbak` file (turn on "include original PDF / Word" if you want to re-parse or view source pages later). On the new phone choose **导入数据 → 覆盖当前数据** on the same page. API keys are not migrated by default.
</details>

<details>
<summary><b>A formula looks wrong. What can I do?</b></summary>

Ask for a rewrite in the card's AI explanation, or mark the question as "AI 出错了" (AI made a mistake) in the quiz.
</details>

## Known issues

- Generation and grading quality depends on the model you choose; double-check important content against the source.
- With Kimi, source page numbers for PDFs may be imprecise.
- Chapters of unusually formatted books may be detected incorrectly; adjust them in the chapter editor or let AI re-split them.
- Android only for now; no real-time multi-device sync yet (use backup files to migrate).

## Roadmap

- [x] PDF / Word parsing and AI generation
- [x] FSRS review, quizzes, and mistake book
- [x] Data backup and migration, dark mode, explanation history
- [x] Generation quality control, study data, and weak-spot suggestions
- [ ] Cloud sync (WebDAV)
- [ ] Web version
- [ ] iOS version

Suggestions are welcome in [Issues](https://github.com/HenryHam88/ai-flashcards/issues).

## Build from source

Requirements: Flutter 3.50 (stable), Android SDK, JDK 17.

```bash
git clone https://github.com/HenryHam88/ai-flashcards.git
cd ai-flashcards
flutter pub get
flutter test
flutter build apk --release --split-per-abi
```

Release signing reads `android/key.properties` (or the file pointed to by `AI_FLASHCARDS_KEY_PROPERTIES`); without it, the debug key is used.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) and the [CHANGELOG](CHANGELOG.md).

## License

Released under the [MIT License](LICENSE). The Noto Sans SC font used in tests is licensed under the [SIL Open Font License 1.1](test/fonts/OFL.txt).
