# arabar

Menubar-приложение для macOS, показывает % оставшегося лимита Claude и ChatGPT прямо в статусной строке. Три независимых источника данных: CLI JSONL, cookies браузера (opt-in), Admin API key (opt-in).

## Требования

- macOS 14+
- Swift 5.9+ (Xcode 15 или Command Line Tools)
- Хотя бы один источник данных: Claude Code CLI, Codex CLI, браузер с сессией claude.ai/chatgpt.com, или Admin API key

## Сборка

```bash
./scripts/build_app.sh release
open build/arabar.app
```

Готовый бандл — в `build/arabar.app`. Чтобы установить на постоянку:

```bash
cp -R build/arabar.app /Applications/
open /Applications/arabar.app
```

## Что показывает

В menubar: иконка провайдера + процент использования. Два провайдера чередуются каждые 20 секунд. Если данных нет — `arabar`.

- **Subscription** (Pro/Max/Plus): процент использованного лимита окна. Claude и ChatGPT имеют разные окна (5h / 7d).
- **API tier**: расход pay-as-you-go запросов (отдельный счёт, не пересекается с subscription).
- Цвет процента: `<70%` — обычный, `70–90%` — оранжевый, `>90%` — красный.
- Стоимость в USD и время до сброса окна — в дропдауне.
- Статус провайдера (incidents через status.anthropic.com / status.openai.com).

## Источники данных

| Источник | Что даёт | Как включить |
|---|---|---|
| **CLI JSONL** | Subscription-tier usage из Claude Code / Codex CLI | Работает автоматически если CLI установлен (`~/.claude/projects/`, `~/.codex/sessions/`) |
| **Browser cookies** | Subscription usage напрямую из claude.ai / chatgpt.com | Opt-in в Settings → таб Claude/ChatGPT → "Use browser session cookies" |
| **Admin API key** | API-tier usage (pay-as-you-go, отдельный счёт) | Opt-in в Settings → таб Claude/ChatGPT → поле "Admin API key" |

Источники subscription не смешиваются (риск двойного счёта): приоритет cookies → JSONL.

## Настройки

Открыть: `⌘,` в меню или кнопка "Settings…" в дропдауне.

Три таба: **Claude**, **ChatGPT**, **About**.

Каждый таб содержит:
1. **Subscription cookies** — включить/выключить, выбрать браузер, кнопка "Test connection".
2. **Admin API key** — ввести ключ, сохраняется в Keychain, кнопка "Test".
3. **Display source** — что показывать в menubar: subscription или API tier.

## Cookies (opt-in)

Включается в Settings → нужный таб → "Use browser session cookies". По умолчанию выключено.

Поддержанные браузеры: **Chrome, Brave, Edge** (Chromium-семейство). Safari — в планах.

Cookies используются только для запросов к `claude.ai` и `chatgpt.com` с вашего устройства — никуда не передаются, маскируются в логах приложения.

macOS покажет системный диалог разрешения доступа к Keychain (Chrome Safe Storage) — это ожидаемо при первом включении.

Enable cookies-reader debug logs: `defaults write com.arystantelbay.arabar debug.cookies -bool true` (then restart arabar; view in Console.app filtered by subsystem `com.arystantelbay.arabar`).

## Admin API keys

Дают доступ к **API-tier usage** — расход pay-as-you-go запросов (не subscription лимиты).

- **Anthropic**: [console.anthropic.com](https://console.anthropic.com) → Settings → Admin API keys. Нужен ключ с правами на чтение usage.
- **OpenAI**: [platform.openai.com](https://platform.openai.com) → Organization → Admin keys. Ключ формата `sk-admin-...`.

Ключи хранятся в Keychain приложения (`com.arystantelbay.arabar`), никогда не логируются.

## Приватность

- **CLI JSONL** — только локальные файлы (`~/.claude/projects/`, `~/.codex/sessions/`). Сеть не используется.
- **Cookies** — opt-in. Используются только для запросов к `claude.ai` и `chatgpt.com`. Маскируются в логах, никуда не передаются третьим сторонам.
- **Admin API keys** — хранятся в Keychain нашего приложения. Никогда не логируются. Используются только для запросов к `api.anthropic.com` и `api.openai.com`.
- Публичные Statuspage JSON (`status.anthropic.com`, `status.openai.com`) — единственные внешние запросы без credentials.

## Login at startup

Открой меню → переключи "Launch at Login".

> Примечание: `SMAppService` работает только когда приложение запущено из `.app` бандла, установленного в `/Applications/` или из домашней папки. При запуске через `swift run` или голым бинарём toggle не возымеет эффекта — это ожидаемо.

## Разработка (без бандла)

```bash
swift build -c debug
.build/debug/arabar
```

Приложение появится в menubar как иконка — без Dock иконки (`LSUIElement = YES`).
