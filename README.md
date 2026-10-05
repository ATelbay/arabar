# arabar

Menubar-приложение для macOS, показывает % оставшегося лимита Claude и ChatGPT, а также лимиты аккаунтов Gemini Code Assist, Kimi Code и GLM Coding Plan прямо в статусной строке. Источники: CLI JSONL, cookies браузера (opt-in), Admin API key (opt-in), account quota API (opt-in).

## Требования

- macOS 14+
- Swift 5.9+ (Xcode 15 или Command Line Tools)
- Хотя бы один источник данных: Claude Code CLI, Codex CLI, Pi, браузер с сессией claude.ai/chatgpt.com, или Admin API key

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

В menubar: иконка провайдера + процент **оставшегося** лимита 5-часового окна. Провайдеры, у которых в Settings → Providers включено «Show in menu bar»,  чередуются каждые 30 секунд; правый клик / two-finger tap по иконке переключает вручную. Если для активного провайдера нет авторитетного источника (cookies не настроены / 401) — рядом с иконкой `ukwn`.

- **Subscription** (Pro/Max/Plus): процент **оставшегося** лимита 5h-окна и 7d-окна. Дропдаун показывает оба окна с прогресс-баром, который тоже инвертирован (бар сжимается по мере расхода).
- **API tier**: расход pay-as-you-go запросов (отдельный счёт, не пересекается с subscription).
- Цвет процента: `>30%` осталось — обычный/акцентный, `10–30%` — оранжевый, `<10%` — красный.
- Стоимость в USD и время до сброса окна — в дропдауне.
- Статус провайдера (incidents через status.anthropic.com / status.openai.com): в menubar треугольник показывается только для серьёзных outage (`partialOutage`/`majorOutage`), чтобы minor degraded не вытеснял процент; в дропдауне minor degraded всё ещё отображается текстом.

## Источники данных

| Источник | Что даёт | Как включить |
| --- | --- | --- |
| **Local JSONL** | Реальные токены и стоимость из Claude Code / Codex CLI / Pi (процент — только если есть cookies) | Работает автоматически (`~/.claude/projects/`, `~/.codex/sessions/`, `~/.pi/agent/sessions/`) |
| **Browser cookies** | Авторитетный процент оставшегося лимита из claude.ai / chatgpt.com | Opt-in в Settings → Providers → Claude Code / ChatGPT → "Use browser session cookies" |
| **Admin API key** | API-tier usage (pay-as-you-go, отдельный счёт) | Opt-in в Settings → Providers → Claude Code / ChatGPT → поле "Admin API key" |

Subscription-источники **объединяются**: cookies дают авторитетный процент и время сброса, JSONL — реальные токены и стоимость. Для Pi учитываются usage-записи OpenAI и Anthropic, включая точную стоимость, сохранённую в сессии. Если cookies недоступны — показывается только то, что есть из JSONL, а процент превращается в `ukwn`. Авторитетные snapshots имеют freshness TTL: fresh ≤2 минуты, stale 2–30 минут, expired >30 минут или после `resetAt`; expired проценты suppress-ятся в `ukwn`, но JSONL токены/стоимость остаются видимыми. API tier живёт отдельным разделом дропдауна.

## Настройки

Открыть: `⌘,` в меню или кнопка "Settings…" в дропдауне.

Слева группа **Providers** (Claude Code, ChatGPT / Codex, Gemini, Kimi, GLM) и **About**. Страница каждого провайдера начинается с переключателя **Show in menu bar and menu** (Gemini, Kimi и GLM по умолчанию скрыты), затем идут настройки подключения.

Страницы Claude Code и ChatGPT содержат:

1. **Subscription cookies** — включить/выключить, выбрать браузер, кнопка "Test connection".
2. **Admin API key** — ввести ключ, сохраняется в Keychain, кнопка "Test".
3. **Display source** — что показывать в menubar: subscription или API tier.

## Лимиты аккаунтов Gemini, Kimi и GLM

Откройте **Settings → Providers → Gemini / Kimi / GLM** и включите **Read account limits**. Провайдер автоматически добавится в menubar; видимость меняется переключателем на той же странице. **Test connection** проверяет доступ к квотам. По умолчанию подключения выключены.

| Провайдер | Подключение | Что отображается |
| --- | --- | --- |
| **Gemini** | Источник на выбор: Google login в Gemini CLI (`~/.gemini/oauth_creds.json`) или в Antigravity CLI `agy` (Keychain item `gemini`/`antigravity`, только чтение); при необходимости Google Cloud project ID | Gemini CLI: квоты Code Assist по моделям. agy: квоты моделей Antigravity (`fetchAvailableModels`). Время сброса |
| **Kimi** | Логин Kimi Code CLI (`~/.kimi-code`, только чтение, пока токен CLI активен ~15 мин), иначе Kimi Code API key и регион ключа (`kimi.ai` / `kimi.com`) | 5h, недельная и месячные квоты, возвращённые Kimi Code |
| **GLM** | GLM Coding Plan API key и регион Z.ai / Zhipu | Окна квот coding plan и tools, возвращённые провайдером |

Menubar показывает **оставшийся процент самой ограниченной из возвращённых квот**. Дропдаун показывает каждую квоту отдельно и время сброса. Если хотя бы одна ранее полученная квота истекла, общий процент становится `ukwn`; старые данные не выдаются за актуальные. TTL: fresh ≤2 минуты, stale ≤30 минут, затем процент скрывается; наступивший reset также скрывает процент до следующего успешного запроса. Ошибки подключения видны рядом с провайдером.

Для этих трёх провайдеров локальные сессии, токены и стоимость не используются. Gemini показывает **Code Assist / CLI quotas**, а не лимиты чата gemini.google.com; Gemini API keys для этого подключения не подходят. Отдельная месячная квота членства Kimi может не возвращаться Kimi Code API и не вычисляется из локальных логов. Отсутствующие окна не придумываются.

Ключи Kimi/GLM хранятся в Keychain приложения. Токен Kimi Code CLI никогда не обновляется приложением: Kimi ротирует refresh token, и обновление разлогинило бы CLI. Для agy логин читается через `/usr/bin/security`, access token обновляется только в памяти (Google не ротирует refresh token), Keychain item не меняется; OAuth-клиент берётся из установленного бинарника `agy`. Токены и стоимость для agy недоступны — он не пишет их локально. Gemini CLI: приложение читает только файл авторизации CLI, находит публичную OAuth-конфигурацию в установленном Gemini CLI (npm/Homebrew, включая `bundle/chunk-*.js`), обновляет access token через Google и держит его в памяти, не меняя файл CLI. Если используется только зашифрованное хранилище Gemini без `oauth_creds.json`, приложение сообщает, что подключение недоступно. Credentials не логируются.

Источники и контракты:

- [Gemini CLI quota API](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/server.ts), [schema](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/types.ts), [Google OAuth](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/oauth2.ts).
- [Kimi Code quota reader](https://github.com/MoonshotAI/kimi-code/blob/main/packages/oauth/src/managed-usage.ts), [Kimi quota documentation](https://www.kimi.com/code/docs/en/kimi-code/membership.html).
- [Z.ai official quota plugin](https://github.com/zai-org/zai-coding-plugins/blob/main/plugins/glm-plan-usage/skills/usage-query-skill/scripts/query-usage.mjs), [plugin documentation](https://docs.z.ai/devpack/extension/usage-query-plugin).

Это внутренние quota endpoints провайдеров: схема или доступ могут измениться. Проверены сборка, разбор ответов и HTTP/auth поведение на изолированных fixtures; живое подключение к платным аккаунтам проверяется через **Test connection**.

## Cookies (opt-in)

Включается в Settings → Providers → Claude Code / ChatGPT → "Use browser session cookies". По умолчанию выключено.

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

- **Local JSONL** — только локальные файлы (`~/.claude/projects/`, `~/.codex/sessions/`, `~/.pi/agent/sessions/`). Сеть не используется.
- **Cookies** — opt-in. Используются только для запросов к `claude.ai` и `chatgpt.com`. Маскируются в логах, никуда не передаются третьим сторонам.
- **Admin API keys** — хранятся в Keychain нашего приложения. Никогда не логируются. Используются только для запросов к `api.anthropic.com` и `api.openai.com`.
- **Account limits** — opt-in. Запросы только к `cloudcode-pa.googleapis.com` / `daily-cloudcode-pa.googleapis.com` / `oauth2.googleapis.com` (Gemini CLI / agy), `api.kimi.ai` / `api.kimi.com` (Kimi), `api.z.ai` / `open.bigmodel.cn` (GLM), в зависимости от выбранного подключения.
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
