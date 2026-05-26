# Third-Party Licenses

Koe ships with, links against, or downloads at runtime the third-party
components listed below. Each component is distributed under its own license;
their copyright notices are reproduced here per the terms of those licenses.

If you spot a missing or incorrect entry, please open a PR or issue.

---

## Bundled in macOS app (`Koe.app/Contents/Frameworks/`)

### whisper.cpp — MIT

Source: <https://github.com/ggerganov/whisper.cpp>

```
MIT License

Copyright (c) 2023-2026 Georgi Gerganov

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### llama.cpp — MIT

Source: <https://github.com/ggerganov/llama.cpp>

```
MIT License

Copyright (c) 2023-2026 Georgi Gerganov

[Same text as above]
```

### ggml — MIT

Source: <https://github.com/ggerganov/ggml>

```
MIT License

Copyright (c) 2022-2026 Georgi Gerganov

[Same text as above]
```

---

## Bundled in Windows app

### whisper-rs — MIT OR Apache-2.0

Source: <https://github.com/tazz4843/whisper-rs>

Dual-licensed. Koe distributes under the MIT terms; see upstream for the
Apache-2.0 alternative. whisper-rs vendors whisper.cpp and ggml; their MIT
notices above apply transitively.

---

## Site (`site/`)

The Fly.io-hosted marketing site links to or embeds:

- **axum / tokio / serde** — MIT OR Apache-2.0 (Rust ecosystem)
- **Inter** — SIL Open Font License 1.1 (Rasmus Andersson)
- **Noto Sans JP** — SIL Open Font License 1.1 (Google Fonts)

Full font license text: <https://openfontlicense.org/>

---

## Runtime model downloads

Koe downloads Whisper ggml model weights from Hugging Face on first launch.
These are derived from OpenAI Whisper and republished by the ggerganov project:

- **Whisper model weights (ggml format)** — MIT
  Source: <https://huggingface.co/ggerganov/whisper.cpp>

- **Kotoba Whisper v2.0 (Japanese fine-tune)** — Apache-2.0
  Source: <https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0-ggml>

Original OpenAI Whisper paper / weights:
<https://github.com/openai/whisper> (MIT)

---

## Optional / planned dependencies

- **openWakeWord** — Apache-2.0 (wake-word detection, when enabled)
  Source: <https://github.com/dscripka/openWakeWord>

---

## Reporting

If you ship a derivative work or republish Koe, please retain this file and
the `LICENSE` at the repo root, and reproduce the copyright notices of any
bundled third-party libraries you continue to ship.
