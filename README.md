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

В menubar: иконка провайдера + процент **оставшегося** лимита 5-часового окна. Два провайдера (Claude / ChatGPT) чередуются каждые 30 секунд; правый клик / two-finger tap по иконке переключает вручную. Если для активного провайдера нет авторитетного источника (cookies не настроены / 401) — рядом с иконкой `ukwn`.

- **Subscription** (Pro/Max/Plus): процент **оставшегося** лимита 5h-окна и 7d-окна. Дропдаун показывает оба окна с прогресс-баром, который тоже инвертирован (бар сжимается по мере расхода).
- **API tier**: расход pay-as-you-go запросов (отдельный счёт, не пересекается с subscription).
- Цвет процента: `>30%` осталось — обычный/акцентный, `10–30%` — оранжевый, `<10%` — красный.
- Стоимость в USD и время до сброса окна — в дропдауне.
- Статус провайдера (incidents через status.anthropic.com / status.openai.com): в menubar треугольник показывается только для серьёзных outage (`partialOutage`/`majorOutage`), чтобы minor degraded не вытеснял процент; в дропдауне minor degraded всё ещё отображается текстом.

## Источники данных

| Источник | Что даёт | Как включить |
|---|---|---|
| **CLI JSONL** | Реальные токены и стоимость из Claude Code / Codex CLI (процент — только если есть cookies) | Работает автоматически если CLI установлен (`~/.claude/projects/`, `~/.codex/sessions/`) |
| **Browser cookies** | Авторитетный процент оставшегося лимита из claude.ai / chatgpt.com | Opt-in в Settings → таб Claude/ChatGPT → "Use browser session cookies" |
| **Admin API key** | API-tier usage (pay-as-you-go, отдельный счёт) | Opt-in в Settings → таб Claude/ChatGPT → поле "Admin API key" |

Subscription-источники **объединяются**: cookies дают авторитетный процент и время сброса, JSONL — реальные токены и стоимость. Если cookies недоступны — показывается только то, что есть из JSONL, а процент превращается в `ukwn`. Авторитетные snapshots имеют freshness TTL: fresh ≤2 минуты, stale 2–30 минут, expired >30 минут или после `resetAt`; expired проценты suppress-ятся в `ukwn`, но JSONL токены/стоимость остаются видимыми. API tier живёт отдельным разделом дропдауна.

## Настройки

Открыть: `⌘,` в меню или кнопка "Settings…" в дропдауне.

Три таба: **Claude**, **ChatGPT**, **About**.

Каждый таб содержит:
1. **Subscription cookies** — включить/выключить, выбрать браузер, кнопка "Test connection".
2. **Admin API key** — ввести ключ, сохраняется в Keychain, кнопка "Test".
3. **Display source** — что показывать в menubar: subscription или API tier.

## Cookies (opt-in)

Включается в Settings → нужный таб → "Use browser session cookies". По умолчанию выключено.

Поддержанные браузеры: **Safari, Chrome, Brave, Edge**. У Chromium-семейства cookies лежат в SQLite + AES-зашифрованы Keychain-ключом "Chrome Safe Storage" (Chrome 130+ префиксует value SHA256-хэшем — мы это учитываем); у Safari — бинарный `~/Library/Cookies/Cookies.binarycookies`.

Cookies используются только для запросов к `claude.ai` и `chatgpt.com` с вашего устройства — никуда не передаются, маскируются в логах приложения.

При первом подключении к Chromium-браузеру macOS попросит разрешить доступ к Keychain item "Chrome Safe Storage" (это нужно, чтобы расшифровать cookies). Для Safari при первом чтении может потребоваться **Full Disk Access** в System Settings → Privacy & Security (Safari cookies защищены TCC).

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
