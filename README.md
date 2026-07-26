# AetherFeed

Native RSS/Atom reader for macOS with AI enrichment: per-article summaries and
bilingual tags, category suggestions when adding feeds, and an AI-generated
briefing ("What's new") as the home page.

Three interchangeable AI backends:

- **Apple Intelligence** — the on-device model (macOS 26+, no setup at all)
- **Ollama** — a local or remote Ollama server
- **OpenAI-compatible** — OpenAI itself or any compatible server
  (LM Studio, llama.cpp, vLLM, …)

## Features

- Live-updating article list backed by SQLite (GRDB) with full-text search
- AI summaries and bilingual topic tags for every article — summaries in
  German, English, Italian, French, Spanish, or the article's original
  language
- Daily briefing home page grouped by your feed categories — regenerated
  incrementally (only categories with new articles), with an overview that
  follows your category order
- Read articles aloud with the system voice (briefing and article view)
- Ad blocking in the article web view (Adblock-format blocklists)
- Starred articles, per-feed customization (rename, categories, favicons)
- Export articles as Markdown (reader-style full-page extraction) or PDF
- OPML import/export, retention limits, notifications for new articles and
  the finished briefing
- Built-in update check against GitHub releases with one-click self-update
- Localized UI in five languages (English, German, Italian, French,
  Spanish), switchable at runtime

## Build & Run

Requires macOS 15+ and the Xcode Command Line Tools (Swift 6.1+). Xcode
itself is not required.

```sh
./Scripts/build-app.sh      # builds build/AetherFeed.app (ad-hoc signed)
open build/AetherFeed.app
```

For development: `swift build` and run `.build/debug/AetherFeed`, or
`./Scripts/test.sh` for the test suite.

## Configuration

Settings (⌘,): AI provider (Apple Intelligence / Ollama / OpenAI-compatible)
with connection test and model picker, UI and summary language, feed refresh
(manually, on launch, or every 5–120 minutes), retention, notifications,
update check, and ad-block lists.

## License

[MIT](LICENSE.md) — © 2026 [andeedotnet](https://github.com/andeedotnet)
