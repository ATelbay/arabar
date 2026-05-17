# arabar — статус проекта

Менюбар-приложение для macOS, показывает **проценты оставшегося лимита** Claude Code и ChatGPT/Codex прямо в статусной строке. Подобие [CodexBar](https://github.com/steipete/CodexBar). Три источника данных (opt-in): локальные CLI JSONL, cookies браузера (Chrome/Brave/Edge), Admin API key для API-tier usage.

---

## Ключевые решения

| Решение | Значение | Почему |
|---|---|---|
| Стек | Swift + SwiftUI + AppKit `NSStatusItem` + `NSPopover` | Нативный, маленький бинарь, macOS 14+. С 2026-05-16 ушли с `MenuBarExtra` ради поддержки правого клика. |
| Поддерживаемые провайдеры (MVP) | Claude Code + ChatGPT/Codex | По запросу пользователя |
| Отображение в menubar | **Текст с процентами**, напр. `C 67% • G 42%` | Пользователь хочет проценты видеть сразу, без раскрытия меню |
| Доступ к credentials | Только локальные JSONL + опционально Keychain нашего приложения | Пользователь против запроса доступа к cookies Chrome/Safari |
| Окна лимитов | 5-часовое скользящее + недельное | Как у Anthropic/OpenAI |

## Источники данных

**Claude Code:**
- `~/.claude/projects/**/*.jsonl` — последние 30 дней, инкрементальный парсинг
- Опционально: OAuth токен в нашей записи Keychain (для прямых запросов к API)

**ChatGPT/Codex:**
- `~/.codex/sessions/**/*.jsonl` + `~/.codex/archived_sessions/`
- `~/.codex/auth.json` — уже существует у пользователя, читаем напрямую
- Опционально: `codex app-server` JSON-RPC (`account/read`, `account/rateLimits/read`)

**Статус провайдеров (опционально):**
- `https://status.anthropic.com/api/v2/status.json`
- `https://status.openai.com/api/v2/status.json`

---

## Архитектура

Swift Package (Package.swift), не xcodeproj. Build через `./scripts/build_app.sh release` (под капотом: `swift build -c release` + ручная сборка `.app`-бандла + `xcrun actool` для Asset Catalog + ad-hoc `codesign`).

```
arabar/
├── Package.swift, scripts/build_app.sh, Tests/arabarTests/
└── arabar/
    ├── App/
    │   ├── ArabarApp.swift              # @main, AppDelegate (NSStatusItem, не MenuBarExtra)
    │   └── AppViewModel.swift           # @StateObject, refresh(), rotation timer
    ├── DataSource/
    │   ├── ClaudeUsageReader.swift      # JSONL ~/.claude/projects/, инкрементальный
    │   ├── CodexUsageReader.swift       # JSONL ~/.codex/sessions/, инкрементальный
    │   ├── CodexAuth.swift              # читает ~/.codex/auth.json
    │   ├── ClaudeCookiesReader.swift    # claude.ai/api/organizations/{id}/usage
    │   ├── OpenAICookiesReader.swift    # chatgpt.com/backend-api/wham/usage (2-step Bearer)
    │   ├── AnthropicAdminAPIReader.swift # api.anthropic.com/v1/organizations/usage_report
    │   ├── OpenAIUsageAPIReader.swift   # api.openai.com/v1/organization/usage/completions
    │   ├── SafariBinaryCookies.swift    # парсер Apple BinaryCookies формата
    │   ├── ChromiumKeychain.swift       # унифицированный Keychain access для Chrome/Brave/Edge
    │   ├── ChromiumCookieDB.swift       # SQLite reader + Chrome 130+ hash-prefix strip
    │   └── CookieExpiry.swift           # unified provider→Date? для UI warnings
    ├── Model/
    │   ├── UsageEvent.swift             # token deltas от одной message/turn
    │   ├── UsageSnapshot.swift          # WindowSnapshot{durationHours, pct, source, resetAt, tokens, cost}
    │   ├── Provider.swift               # enum .claude, .codex
    │   └── StatusInfo.swift             # incident-level от Statuspage
    ├── Logic/
    │   ├── Aggregator.swift             # дедуп + per-window suм + cost; percentUsed возвращает (nil, .unknown)
    │   └── Pricing.swift                # таблицы $/MTok per model (актуализированы 2026-05-16)
    ├── UI/
    │   ├── MenuBarController.swift      # NSStatusItem, NSPopover, left/right-click handling
    │   ├── MenuBarLabel.swift           # SwiftUI label inside hosting view, реагирует на rotationIndex
    │   ├── MenuContentView.swift        # popover dropdown
    │   └── SettingsView.swift           # TabView Claude/ChatGPT/About, ProviderSettingsTab
    └── Infra/
        ├── Scheduler.swift              # 60s Timer auto-refresh
        ├── AppLifecycle.swift           # attach scheduler к viewModel
        ├── KeychainStore.swift          # com.arystantelbay.arabar.adminkey.{anthropic,openai}
        ├── LoginItemController.swift    # SMAppService.mainApp
        ├── StatusPagePoller.swift       # status.anthropic.com / status.openai.com
        ├── SharedDecoders.swift         # iso8601Flexible JSONDecoder extension
        └── DebugLog.swift               # debugLog(_:type:_:) gated by UserDefaults debug.cookies
```

---

## Задачи (для разбивки по agent teammates)

Легенда: `[ ]` todo · `[~]` in progress · `[x]` done.
`→` — рекомендуемый тип агента (`Explore`/`general-purpose`/`Plan`).

### Фаза 1 — разведка (можно параллельно)

- [x] **T1. Schema Detective.** Схемы JSONL заполнены ниже. Дедупликация по `message.id` обязательна для Claude. У Codex есть `last_token_usage` (дельта) vs `total_token_usage` (накопительно) — используем `last_token_usage`.

- [x] **T2. Pricing & Limits Researcher.** Создано: `arabar/Logic/Pricing.swift`, `arabar/Logic/PlanLimits.swift`. Источник цен Anthropic — официальный (`platform.claude.com/docs/en/about-claude/pricing`). OpenAI — агрегатор (`pricepertoken.com`), нужна перепроверка. Лимиты Claude Pro/Max не публикуются официально, в коде комьюнити-оценки с `// TODO: уточнить`. Промо-лимиты OpenAI Codex Pro (25x) действуют до 31.05.2026.

- [x] **T3. Xcode Scaffolder.** Выбран вариант **Swift Package** (xcodegen в системе нет). Создано: `Package.swift`, `arabar/App/ArabarApp.swift`, `arabar/Info.plist`. Сборка: `swift build -c debug` → `Build complete!`. **Ограничение**: SPM выдаёт голый бинарь `.build/debug/arabar`, не `.app`-бандл с правильным `LSUIElement`. Для релиза в T9 нужно либо `brew install xcodegen` и сгенерировать `.xcodeproj`, либо скрипт-обёртка через `xcodebuild`. Бинарь запускается и показывает иконку в menubar. LSP может показывать ложное "@main attribute cannot be used in a module that contains top-level code" — это баг индексатора, реальная сборка проходит.

### Фаза 2 — парсеры и агрегация (последовательно после Фазы 1)

- [x] **T4. Claude Parser.** Создан `arabar/DataSource/ClaudeUsageReader.swift`. Инкрементальный offset+mtime кэш в `~/Library/Application Support/arabar/claude_cache.json`, атомарная запись. Дедуп streaming-дублей по `message.id` внутри файла (`seenMessageIds: Set<String>` в FileState). Рекурсивный enumerator по `~/.claude/projects`, `$CLAUDE_CONFIG_DIR/projects`, `~/.config/claude/projects`, включая `subagents/`. Кастомный ISO8601 декодер с миллисекундами. Глобальная дедупликация и стоимость — отдано в T6.

- [x] **T5. Codex Parser.** Создан `arabar/DataSource/CodexUsageReader.swift` + `arabar/DataSource/CodexAuth.swift`. Использует `last_token_usage` (дельта), а не `total_token_usage`. Карта `turn_id → model` строится по `turn_context` и кэшируется в FileState на случай разрыва между чтениями. Корни: `~/.codex/sessions`, `~/.codex/archived_sessions`, `$CODEX_HOME/sessions`. Session_id fallback из имени файла `rollout-<ISO>-<sessionId>.jsonl`. `CodexAuth.read()` читает `~/.codex/auth.json` лениво, любое отсутствующее поле → nil.

- [x] **T6. Aggregator.** Создано: `arabar/Model/UsageSnapshot.swift` (+ `WindowSnapshot`) и `arabar/Logic/Aggregator.swift`. Глобальный дедуп по `(provider, messageId)`; `messageId == nil` → каждое событие уникально (UUID-ключ). Окна 5h и 168h по семантике "первое событие в окне + duration", при пустом окне `resetAt = nil`, проценты 0. Стоимость через `Pricing.{claudeModels, openaiModels}[model]`, `cost_unknown_model = 0` (не падаем). Проценты через `PlanLimits.{claudeLimits, chatgptLimits}(for:)`, при `maxTokens == nil` → `percentUsed = nil` (UI решит как рендерить). Замечание: у ChatGPT Plus 5h-окно есть только для Codex CLI, у чата `durationHours == 3` — выбор `first(where: durationHours == 5)` это покрывает.

### Фаза 3 — UI и упаковка

- [x] **T7. MenuBar UI.** Создано: `arabar/UI/MenuBarLabel.swift`, `arabar/UI/MenuContentView.swift`. `ArabarApp.swift` переписан под `@StateObject AppViewModel`. Label: HStack из двух чипов `C XX% • G YY%`, цвет каждого процента — `.primary` < 70%, `.orange` 70-90%, `.red` > 90%. При `percentUsed == nil` → `—`. При статусе провайдера не-`operational` — `exclamationmark.triangle.fill` бейдж. Дропдаун: `ProgressView` бары для 5h и weekly, `RelativeDateTimeFormatter` для "resets in X" и "Updated X ago", форматирование токенов `≥1M → 1.5M`, `≥1k → 12.3k`. Первый refresh — через `.task` при открытии меню.

- [x] **T8. Auto-refresh + Status.** Создано: `arabar/Infra/Scheduler.swift` (Timer 60s на main RunLoop, race-protection через isRunning), `arabar/Infra/StatusPagePoller.swift` (Anthropic/OpenAI Statuspage `/api/v2/status.json`, 10s timeout, `indicator → StatusLevel`, никогда не кидает — fallback `.unknown`), `arabar/Infra/AppLifecycle.swift` (идемпотентный attach к viewModel). `AppViewModel.refresh()` наполнен: parallel `async let` на оба ридера + оба status fetch, агрегация, атомарное обновление @Published. Patch в `ArabarApp.swift` (`.onAppear { lifecycle.attach(to: viewModel) }`) добавлен — scheduler стартует автоматически при запуске.

- [x] **T9. Packaging.** Создано: `scripts/build_app.sh` (собирает `.app` бандл из `swift build -c release` output: копирует бинарь, Info.plist, resource bundle `arabar_arabar.bundle`, делает ad-hoc `codesign --deep --sign -`), `arabar/Infra/LoginItemController.swift` (обёртка над `SMAppService.mainApp` для "Launch at Login"). Патч в `MenuContentView.swift`: `Toggle("Launch at Login", ...)` с `.toggleStyle(.checkbox)` в футер. `README.md` обновлён (инструкция сборки + установки + про приватность). Результат: `build/arabar.app` 712K (arm64), `codesign -dv` → `Signature=adhoc`. Установка: `cp -R build/arabar.app /Applications/ && open /Applications/arabar.app`. Login Item работает только из `/Applications/...`, не из dev-сборки — это ограничение `SMAppService`.

### Не делаем в MVP
- ~~Cookies браузера (Chrome/Safari) — принципиальное решение.~~ → **Пересмотр 2026-05-16**: пользователь выбрал opt-in cookies, см. Фаза 5.
- Sparkle auto-update.
- WidgetKit виджеты.
- Поддержка остальных 27 провайдеров CodexBar.

---

## Фаза 5 — Browser Cookies + UI Rotation (план, не запущен)

**Контекст**: MVP читает только локальные JSONL Claude Code / Codex CLI. Если CLI не установлен — приложение пустое. Пользователь не хочет такой зависимости. Anthropic/OpenAI не публикуют user-usage API для подписок Pro/Max/Plus — единственный путь без CLI это cookies браузера для приватных endpoints `claude.ai` и `chatgpt.com` (как делает CodexBar).

**Приватность**: всё opt-in. Дефолт — выключено. В Settings явный чек-бокс "Read browser session cookies (Safari/Chrome/Brave/Edge)". Cookies никогда никуда не передаются — используются только для запросов к официальным `claude.ai` / `chatgpt.com` endpoints с того же устройства.

### Задачи

- [x] **T10. Claude cookies reader.** `arabar/DataSource/ClaudeCookiesReader.swift` (427 строк). Поддержаны Chromium-семейство: **Chrome, Brave, Edge** (общий код через SQLite + Chrome Safe Storage Keychain). Safari = `throw .browserUnsupported` (200+ строк бинарного парсера BinaryCookies, отложено). Endpoint **взят прямо из исходников CodexBar**: `GET claude.ai/api/organizations` → orgId, `GET claude.ai/api/organizations/{orgId}/usage` → `five_hour.utilization` + `seven_day.utilization` (проценты 0-100) + `resets_at`. Cookie name: `sessionKey=sk-ant-...`. Маппинг: percentUsed = utilization/100, tokensUsed = 0 (API возвращает только проценты). Chrome AES-128-CBC: PBKDF2-SHA1 (salt "saltysalt", 1003 итерации, IV = 16 пробелов), DB копируется во временный файл (Chrome может локать).
  - Извлечь session cookie для домена `claude.ai` из Safari (`~/Library/Cookies/Cookies.binarycookies`), Chrome (`~/Library/Application Support/Google/Chrome/*/Cookies` — SQLite + расшифровка через Keychain item "Chrome Safe Storage"), Brave, Edge.
  - Дёрнуть приватный endpoint claude.ai (точный путь reverse-engineer через CodexBar исходники + DevTools на claude.ai). Распарсить usage.
  - Вернуть `[UsageEvent]` или `UsageSnapshot` напрямую (зависит от формата API).
  - Опт-ин флаг: читать только если `UserDefaults.bool(forKey: "cookies.enabled.claude")` == true.

- [x] **T11. OpenAI cookies reader.** `arabar/DataSource/OpenAICookiesReader.swift`. Поддержаны **Chrome, Brave, Edge** (тот же путь что T10). Safari TODO. Endpoint: `chatgpt.com/backend-api/conversation/limits` (returns `message_cap_user`, `message_cap_window`, `reset_at`); fallback `chatgpt.com/api/auth/session` для проверки cookie. **Важно**: ChatGPT subscription лимит измеряется в **сообщениях**, не токенах — кладём в `tokensUsed` с комментарием `// counts messages, not tokens`. Класс `OpenAIBrowserSource` отдельный от Claude reader (TODO: вынести общий `BrowserSource` enum).
  - Симметрично для `chatgpt.com`, endpoint `chatgpt.com/codex/settings/usage` (или актуальный — проверить по CodexBar).
  - Те же 4 браузера, та же логика opt-in флага.

- [x] **T12 + T18. Settings UI (объединено).** Один агент сделал оба. Создано: `arabar/UI/SettingsView.swift` (~290 строк, TabView "Claude / ChatGPT / About"). Каждый provider-таб — три секции (`Form + Section` с `.formStyle(.grouped)`): (1) Subscription cookies — Toggle + Picker(Safari/Chrome/Brave/Edge) + Test + дисклеймер "cookies used only locally"; (2) API tier — `SecureField` + Save/Clear/Test + ссылка на console; (3) Display in menubar — `.segmented` Picker "Subscription/API". Save очищает `@State apiKey = ""` сразу после `KeychainStore.set`, Clear через `KeychainStore.delete`. Никаких `print` с ключами. Патч `ArabarApp.swift`: `Settings { SettingsView() }` scene. Патч `MenuContentView.swift`: кнопка "Settings…" с `keyboardShortcut(",")` через `NSApp.sendAction(Selector("showSettingsWindow:"))`. UserDefaults keys для T19: `display.source.claude` / `display.source.openai` = `"subscription"` / `"api"`.
  - Секции: "Claude / ChatGPT". Внутри каждой — чек-бокс "Use browser cookies" + radio "Source: Safari / Chrome / Brave / Edge" + статус ("connected as user@…" / "no cookies found" / "error").
  - Хранение в `UserDefaults`. Кнопка "Test connection".
  - Открывается как отдельное `Window`/`Settings` scene (не Sheet — MenuBarExtra закрывается при потере фокуса).

- [x] **T13. AppViewModel fallback chain.** Закрыто в Группе C вместе с T19 (см. log 2026-05-16). Эволюционировало: вместо exclusive priority cookies → JSONL → пусто, теперь cookies+JSONL **мерджатся** (`mergedSnapshot`/`mergedWindow` в `AppViewModel`): cookies дают авторитетный `percentUsed`/`resetAt`, JSONL — реальные `tokensUsed`/`costUSD`. Без cookies — только JSONL (процент `unknown`).

- [x] **T14. UI Rotation + SVG icons.** `arabar/UI/MenuBarLabel.swift` переписан. Создано: `Assets.xcassets/AnthropicLogo.imageset/{anthropic.svg, Contents.json}` + `OpenAILogo.imageset/{openai.svg, Contents.json}` с `template-rendering-intent: template`. Ротация: `Timer.publish(every: 20)` + `@State currentIndex`. Если у активного провайдера нет данных (`percentUsed == nil`) → автоматически skip на следующего. Если оба пусты → `Text("arabar")`. Layout: иконка 12pt template + процент в monospaced 12pt с цветовой шкалой. `.id(provider)` для transition между провайдерами.
  - Положить SVG лого в `arabar/Assets.xcassets/AnthropicLogo.imageset/` и `OpenAILogo.imageset/`. SVG-данные:
    - **Anthropic** (viewBox 0 0 24 24): `<svg role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><title>Anthropic</title><path d="M17.3041 3.541h-3.6718l6.696 16.918H24Zm-10.6082 0L0 20.459h3.7442l1.3693-3.5527h7.0052l1.3693 3.5528h3.7442L10.5363 3.5409Zm-.3712 10.2232 2.2914-5.9456 2.2914 5.9456Z"/></svg>`
    - **OpenAI** (viewBox 0 0 24 24): `<svg role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><title>OpenAI</title><path d="M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z"/></svg>`
    - Источник: simple-icons (CC0). Сохранить как `.svg` в `Contents.json` с `"template-rendering-intent": "template"` чтобы macOS перекрашивал под тему.
  - Enum `CurrentDisplay { .claude, .codex }` в `@State`.
  - `Timer.scheduledTimer(withTimeInterval: 20, repeats: true)` переключает.
  - Если у активного провайдера нет данных (snapshot == nil или percentUsed == nil) → автоматически skip на следующего; если у обоих нет → "arabar".
  - Layout: `Image("AnthropicLogo")` или `Image("OpenAILogo")` (с `.renderingMode(.template)`, размер ~12pt) + `Text("XX%")` с цветовой шкалой.
  - Опционально: `.transition(.opacity)` между провайдерами.

- [x] **T15. README + STATUS.md.** Закрыто 2026-05-16 (cookies opt-in задокументирован) и повторно проактуализировано 2026-05-17 (rotation 30s, %-left семантика, цветовая шкала, Safari support, architecture section, открытые вопросы).

### Дополнительные задачи — API-tier usage (opt-in)

**Контекст**: помимо subscription (Pro/Max/Plus) и CLI, у пользователя может быть **API-tier** расход — pay-as-you-go API запросы через свой код, n8n, LangChain и т.п. Это **третий независимый счёт** — никак не пересекается с subscription и CLI лимитами. Оба провайдера предоставляют официальный Admin API для запроса usage.

- [x] **T16. Anthropic Admin API reader.** `arabar/DataSource/AnthropicAdminAPIReader.swift`. Endpoint: `GET api.anthropic.com/v1/organizations/usage_report/messages` с `x-api-key: <Admin>` + `anthropic-version: 2023-06-01`. Params: `starting_at`, `ending_at`, `group_by[]=workspace_id,model`, `bucket_width=1d`. Пагинация через `page=<next_page>` пока `has_more`. DTOs: `AdminUsageResponse / UsageBucket / UsageRow` с явными `CodingKeys`. Кастомный ISO8601 декодер с миллисекундами. Маппинг: `uncached_input_tokens → inputTokens`, cache fields → cacheRead/Creation, sessionId = workspace_id ?? "default-workspace".
  - Endpoint: `https://api.anthropic.com/v1/organizations/usage_report/messages` (Admin API). Требует `x-api-key` с **Admin** API key (не обычным sk-ant-...) — пользователь создаёт его в console.anthropic.com → Settings → Admin API.
  - Параметры: `starting_at` (за 7 дней / 30 дней), группировка по модели.
  - Маппинг ответа → `[UsageEvent]` с `provider = .claude`. Стоимость берётся из `Pricing.swift` (уже есть).
  - Opt-in: ключ хранится в Keychain нашей записи `com.arystantelbay.arabar.adminkey.anthropic` (только если пользователь добавил).

- [x] **T17. OpenAI Usage API reader.** `arabar/DataSource/OpenAIUsageAPIReader.swift`. Endpoint: `GET api.openai.com/v1/organization/usage/completions` с `Authorization: Bearer <sk-admin-...>`. Params: `start_time`, `end_time` (Unix int), `bucket_width=1d`, `group_by[]=model`, `limit=180`, `page=<token>`. DTOs: `UsageResponse / Bucket / CompletionResult` через `convertFromSnakeCase`. Timestamps декодируются как Int → Date(timeIntervalSince1970:). Audio tokens и batch flag парсятся, но дропаются (TODO для будущих).
  - Endpoint: `https://api.openai.com/v1/organization/usage/completions` (Usage API, появился 2024). Требует Admin API key (`sk-admin-...`), создаётся в platform.openai.com → Organization → Admin keys.
  - Параметры: `start_time` (Unix epoch), bucket_width (`1d` или `1h`), `group_by[]=model`.
  - Маппинг → `[UsageEvent]` с `provider = .codex`.
  - Opt-in: ключ в Keychain `com.arystantelbay.arabar.adminkey.openai`.

- [x] **T18. Settings UI — Admin keys секция.** Сделано в составе T12 (см. выше). → `general-purpose` (sonnet, тот же агент что T12, либо отдельный)
  - В `SettingsView` добавить секцию "API tier (pay-as-you-go)" под subscription секцией. Для каждого провайдера: `SecureField` для Admin API key + кнопка "Test", статус ("connected" / "invalid key" / "rate limited"), ссылка на инструкцию где взять ключ.
  - Ключи в Keychain, не в UserDefaults (sensitive credentials).
  - **Безопасность**: никогда не логировать ключ; в UI скрытое поле; в Test connection — таймаут 5 сек.

- [x] **T19. AppViewModel multi-source dispatch.** Закрыто 2026-05-16 в Группе C. Реализация: 4 параллельных `@Published` snapshot'а в `AppViewModel` (`claudeSnapshot`, `codexSnapshot`, `claudeApiSnapshot`, `codexApiSnapshot`); display picker `display.source.{claude,openai}` ∈ {`subscription`, `api`} в Settings override-ит primary; `MenuContentView` рендерит secondary "Claude API"/"OpenAI API" секцию если API snapshot есть и отличается от primary. Без расширения `UsageSnapshot` — параллельные snapshot'ы оказались чище.

### Параллелизация

- **Группа A (параллельно, после согласования плана)**: T10, T11, T14, **T16, T17** — независимы между собой (все ридеры + UI rotation).
- **Группа B (последовательно после A)**: T12 + T18 (Settings UI; можно одним агентом или двумя — T12 для cookies секции, T18 для API секции).
- **Группа C (после B)**: T13 + T19 (dispatcher, multi-source) — я сам.
- **T15** — финальный, я сам.

### Известные риски

1. **Chrome Safe Storage**: macOS попросит разрешить arabar доступ к Keychain item — это будет видно пользователю как диалог. Это OK (он явно опт-инил), но это новый системный диалог.
2. **Приватные endpoints могут измениться**: claude.ai и chatgpt.com не обещают стабильный API. Нужны хорошие ошибки в UI ("API changed, please update arabar").
3. **2FA / SSO**: если пользователь логинится через Google/Microsoft SSO, cookies могут иметь короткий TTL — придётся часто релогиниться в браузере.
4. **Cookie expiration**: показывать в Settings срок жизни cookie и предупреждать когда близко.

---

## ⚠️ ОТКРЫТЫЕ БАГИ ПОСЛЕ УСТАНОВКИ ФАЗЫ 5 (продолжить в следующей сессии)

Версия установлена в `/Applications/arabar.app` 2026-05-16 ~16:30 (бинарь 1.3M, ad-hoc подписан). Settings UI открывается корректно (Window scene), но реальные источники данных **не работают**:

### Bug-A: Иконка отсутствует в menubar (КРИТИЧНО)

**Симптом**: процесс arabar запущен (`pgrep -fl arabar` показывает PID), Settings окно открывается через `⌘,`, но **в самой статусной строке нет иконки** (скриншот пользователя 2026-05-16 16:33: видны 100%, play, battery 98%, RU, wifi, control center, время — `arabar` отсутствует).

**Гипотезы причин**:
1. **SVG ассеты не загружаются** даже после фикса `Image(logoName, bundle: .module)`. SPM упаковывает Assets.xcassets в `arabar_arabar.bundle`, а `Bundle.module` может резолвиться неправильно когда .app собран не через xcodebuild, а через скрипт `build_app.sh` (он копирует resource bundle, но `Bundle.module` ищет его относительно `Bundle(for: ...)`). Если `Image()` возвращает пустой view → весь label пустой → `MenuBarExtra` не показывает иконку.
2. **MenuBarExtra без `systemImage` параметра** требует чтобы label был **non-empty**. Если кастомный label пустой (только Image который не загрузился) — MenuBarExtra иконку не регистрирует.
3. **Bundle resource bundle path** в release .app: проверить `ls /Applications/arabar.app/Contents/Resources/arabar_arabar.bundle/Contents/Resources/Assets.car` — есть ли там вообще `Assets.car` с AnthropicLogo/OpenAILogo.

**Идеи фиксов для следующей сессии**:
- Добавить fallback в `MenuBarExtra` через `systemImage:` параметр (system SF Symbol всегда работает, иконка появится даже если custom image fails):
  ```swift
  MenuBarExtra("arabar", systemImage: "chart.bar.fill") { ... } 
  ```
  И отдельно показывать SVG лого внутри label / dropdown.
- Или использовать кастомный `label:` builder с **обязательным** SF Symbol fallback:
  ```swift
  if let image = NSImage(named: "AnthropicLogo") { Image(nsImage: image) }
  else { Image(systemName: "brain") }
  ```
- Диагностика: добавить временный `Text("ara")` в label чтобы понять — иконка ли проблема или сам label не рендерится.
- Проверить через `assetutil --info /Applications/arabar.app/Contents/Resources/arabar_arabar.bundle/Contents/Resources/Assets.car` — есть ли AnthropicLogo/OpenAILogo в скомпилированном asset catalog.

### Bug-B: Claude cookies — "No cookies — log in to claude.ai in Chrome"

**Симптом** (скриншот): пользователь залогинен в claude.ai в Chrome, но ридер не находит cookies. Test connection возвращает `"No cookies — log in to claude.ai in Chrome"`.

**Гипотезы**:
1. **Chrome v127+ (август 2024) внедрил App-Bound Encryption** для cookies. Старый "Chrome Safe Storage" ключ из Keychain больше не используется напрямую — есть новый слой шифрования привязанный к процессу Chrome. Это известная проблема для всех cookie extractors (browser_cookie3, kooky и т.д.). Большинство решений: либо использовать Chrome DevTools Protocol (требует remote debugging), либо обходить через decryption через сам Chrome процесс.
2. **SQL фильтр пропускает leading-dot host_key**: cookies могут быть сохранены с `host_key = ".claude.ai"` (subdomain wildcard), а `WHERE host_key LIKE '%claude.ai%'` должно подхватывать — но стоит явно проверить.
3. **Профиль Chrome не "Default"**: если пользователь использует Profile 1 / Profile 2, путь `~/Library/Application Support/Google/Chrome/Default/Cookies` неверный. Нужно сканить все профили.
4. **Cookie name не `sessionKey`**: CodexBar использует `sessionKey=sk-ant-...` для claude.ai, но Anthropic мог переименовать.

### Bug-C: ChatGPT cookies — "Error: Chrome Safe Storage decryption failed"

**Симптом** (скриншот): Test connection возвращает `"Error: Chrome Safe Storage decryption failed"`. Отличается от Bug-B — здесь Keychain item найден, но дешифрование не удалось.

**Гипотезы**:
1. **Encrypted value использует префикс `v11` или `v20`** вместо ожидаемого `v10`. С Chrome 127+ префикс изменился, AES параметры могут быть другие.
2. **Та же App-Bound Encryption** что в Bug-B — для chatgpt.com cookies нашлись (домен есть в DB), но дешифрование с старым ключом не работает.
3. **Keychain доступ заблокирован**: возможно пользователь нажал "Deny" или "Always Allow" не сработало. Проверить: Keychain Access.app → искать "Chrome Safe Storage" → Access Control tab → есть ли arabar в списке разрешённых приложений.

### Связь между B и C — диагноз

Bug-B и Bug-C **разные ошибки на одном Chrome** → значит:
- Для chatgpt.com cookies в DB есть (иначе была бы "No cookies"), но не дешифруются.
- Для claude.ai cookies в DB **нет** (иначе была бы "decryption failed", а не "No cookies").

Это означает что пользователь либо не залогинен в claude.ai в этом конкретном Chrome (может быть Safari?), либо нужно проверить SQL фильтр / профиль Chrome.

**Сразу понятная проверка** для следующей сессии:
```bash
sqlite3 ~/Library/Application\ Support/Google/Chrome/Default/Cookies "SELECT host_key, name FROM cookies WHERE host_key LIKE '%claude%' OR host_key LIKE '%anthropic%';"
```
Если пусто — пользователь логинился в другом браузере или другом профиле Chrome. Если есть — баг в SQL фильтре нашего ридера.

### Bug-D: Chrome App-Bound Encryption (общая проблема современных Chrome)

Если оба B и C вызваны App-Bound Encryption — это **архитектурная проблема Chrome 127+**. Решения:
- **Запасной путь Safari**: реализовать `BinaryCookies` парсер (~200 строк, формат Apple документирован). Safari не имеет App-Bound Encryption — proven path.
- **Chrome DevTools Protocol**: запускать Chrome с `--remote-debugging-port=9222`, цепляться через WebSocket, читать cookies через `Network.getAllCookies`. Минус: пользователь должен явно запустить Chrome с этим флагом.
- **Декрипт через системный API**: macOS Keychain item "Chrome Safe Storage" в новых Chrome больше не используется — нужно искать другой Keychain entry или использовать `chrome-remote-interface`-style инжекцию.

Реалистично для arabar: **первым делом сделать Safari** через BinaryCookies парсер. Это сразу даёт рабочий путь для пользователей Safari. Chrome поддержка остаётся, но deprecated с пометкой "Chrome 127+ not supported due to App-Bound Encryption".

### Bug-F: Фейковый процент при отсутствии cookies/API (КРИТИЧНО для UX)

**Симптом** (скриншот дропдауна пользователя): Claude Code показывает 100% / 44.7M токенов / $34.11 / "in 3 hr". Цифры расхода ($34.11, токены) — правильные (читаются из JSONL). Но **100%** — фейк.

**Корень проблемы**: процент рассчитывается в `Aggregator.swift:percentUsed()` как `tokensUsed / PlanLimits.maxTokens`. `PlanLimits.swift` для Claude Pro/Max содержит **комьюнити-оценки** (Anthropic точные лимиты не публикует, помечено `// TODO: уточнить`). Реальный лимит пользователя может быть в 3-5 раз выше, и 100% означает только "наша оценка превышена".

То же самое для Admin API source: мы получаем `[UsageEvent]` от API, агрегируем токены через тот же `PlanLimits` → тоже фейковый процент.

**Достоверный процент возможен только от cookies** — `ClaudeCookiesReader.fetchSnapshot()` берёт `utilization` прямо из приватного claude.ai endpoint. Это **настоящее** число от Anthropic.

**План фикса для следующей сессии**:

1. В `UsageSnapshot.swift` / `WindowSnapshot.swift` различать **достоверность** процента — добавить enum или флаг:
   ```swift
   enum PercentSource { case authoritative  // от cookies/API провайдера
                       case estimated       // расчёт через PlanLimits (фейк) 
                       case unknown }       // нет данных
   let percentSource: PercentSource
   ```

2. В `MenuContentView`:
   - Если `percentSource == .estimated` — показывать `~XX%` с курсивом или подписью "estimated, configure cookies for accurate limit"
   - Если `percentSource == .unknown` — `—` вместо процента
   - Если `.authoritative` — обычное `XX%`

3. В `MenuBarLabel` (статусная строка):
   - При `estimated` — серый цвет процента (приглушённо)
   - При `unknown` или `nil` — `—`
   - При `authoritative` — текущая цветовая шкала (зелёный/оранжевый/красный)

4. Маркировка источников:
   - **CLI JSONL** → `percentSource = .estimated` (используем PlanLimits, который угадан)
   - **Admin API** → `.estimated` (тот же путь)
   - **Cookies** → `.authoritative` (мы получаем готовое число)

5. В `Aggregator.makeWindowSnapshot()` нужно передавать `percentSource` явно (это решение источника, не агрегатора). Возможно `aggregate()` должен принимать параметр `eventsSource: PercentSource` или каждое `UsageEvent` должно нести его.

6. Альтернативный UX: вообще скрывать процент в `estimated` режиме (показывать только токены и стоимость), чтобы пользователь не путался. По кнопке "ⓘ" объяснять "subscription limit unknown — enable cookies in Settings".

**Связь с Bug-A/B/C**: пока cookies не работают (Bug-A иконка, Bug-B/C Chrome decryption), пользователь видит только estimated процент. После фикса cookies — Bug-F автоматически исчезнет для cookies path, но останется проблемой для JSONL и Admin API.

### Bug-E: API tier — кнопки disabled

**Симптом**: на скриншоте Save/Clear/Test все disabled когда поле пустое. Это **by design** (Save должен быть enabled только когда поле непустое, Clear/Test — только когда ключ уже сохранён). **Не баг**, но UX может быть улучшен:
- Показать "✓ Saved" зелёным под полем когда `apiKeyHasValue == true`, чтобы пользователь видел что ключ уже в Keychain.
- Сейчас `apiKeyHasValue` пересчитывается через `KeychainStore.has(...)` в init View — если пересоздать View, состояние теряется. Нужно `@AppStorage` или обновлять при `onAppear`.

---

## TODO в следующей сессии (приоритеты)

1. ~~**[P0] Bug-A**: иконка в menubar.~~ → **Закрыто 2026-05-16 (T20)**. Причина: SPM `swift build` на macOS не запускает `actool`, поэтому в `arabar_arabar.bundle/` лежали сырые `.svg`+`Contents.json` без `Assets.car`. Фикс: `scripts/build_app.sh` теперь компилирует asset catalog через `xcrun actool --compile` и кладёт `Assets.car` в корень resource bundle (где `Bundle.module` его находит). Verify: `assetutil --info build/arabar.app/.../Assets.car` → `AnthropicLogo` (24×24 vector, preserved) + `OpenAILogo` присутствуют.
2. ~~**[P0] Bug-F**: фейковый процент 100%.~~ → **Закрыто 2026-05-16 (T21)**. Добавлен `enum PercentSource { .authoritative, .estimated, .unknown }` в `WindowSnapshot`. Маркировка: cookies path (claude.ai/chatgpt.com приватные endpoints) → `.authoritative`; JSONL + Admin API (через PlanLimits) → `.estimated` если limit известен, `.unknown` если nil. UI: `MenuContentView.percentLabel` — `XX%` цветной для authoritative, `~XX%` курсив+secondary+tooltip для estimated, `—` для unknown. `MenuBarLabel.providerChip` — аналогично. Прогресс-бар: серый для estimated/unknown. `hasData(for:)` — estimated counts as data, только unknown скипает провайдера при rotation.
3. ~~**[P1] Bug-D**: Safari BinaryCookies парсер.~~ → **Закрыто 2026-05-16 (T22)**. Создан `arabar/DataSource/SafariBinaryCookies.swift` (~160 LOC, чистый Swift на Foundation, big-endian header + little-endian pages, Apple epoch +978307200s, 100 MB cap). В `ClaudeCookiesReader.swift` + `OpenAICookiesReader.swift` ветка `.safari` теперь читает `~/Library/Cookies/Cookies.binarycookies`, фильтрует по домену (`claude.ai` / `chatgpt.com`), возвращает session cookie. Новая ошибка `accessDenied` → UI показывает `"Grant Full Disk Access in System Settings → Privacy & Security → Full Disk Access"`. TCC caveat: первое чтение может потребовать Full Disk Access (Safari cookies защищены TCC даже без sandbox).
## TODO следующая сессия (пользовательский запрос 2026-05-16)

1. ~~**[P1] Dropdown layout: "Launch on start" чекбокс криво стоит**.~~ → **Закрыто 2026-05-16 (T25)**. Footer wrapped в `VStack(alignment: .leading, spacing: 6)`: Row 1 = Toggle solo, full label visible; Row 2 = существующий HStack с "Updated…" / Refresh / Settings / Quit.

2. ~~**[P1] Время "in X" — точнее**.~~ → **Закрыто 2026-05-16 (T25)**. `resetIn(_)` использует `Calendar.dateComponents([.day, .hour, .minute])`: >24h → `"in Xd Yh"`, ≥1h → `"in Xh Ym"`, <1h → `"in Xm"`, прошедшее → `"reset"`. Применено к обоим окнам (5h + 7d). `RelativeDateTimeFormatter` остался только для футера "Updated X ago".

3. ~~**[P1] Инвертировать шкалу — показывать сколько ОСТАЛОСЬ**.~~ → **Закрыто 2026-05-16 (T25 + manual fix)**. T25: текст `X% left` через `remaining = 1.0 - used`, новая `remainingColor`: >0.30 зелёный / 0.10-0.30 оранжевый / <0.10 красный. Применено к `percentLabel` и `MenuBarLabel.providerChip`. T25 агент оставил bar fill = used (тинт по remaining) — после live-теста пользователь попросил инвертировать и сам бар. Manual fix: новый helper `barFillValue` возвращает `1.0 - used` (`max(0, min(...))`); бар теперь shrinks as usage grows. Семантика консистентна с текстом: короткий бар = мало осталось, цвет — тревожность.

4. ~~**[P2] ChatGPT cookies-only % usage**.~~ → **Закрыто 2026-05-16 (T26 research + T27 impl)**. Найдено через изучение CodexBar исходников: `/backend-api/wham/usage` требует `Authorization: Bearer`, cookies-only невозможно. Решение — 2-step flow: `GET /api/auth/session` с cookies → JSON `{user.id, accessToken}` (NextAuth standard) → потом `/wham/usage` с `Authorization: Bearer <token>` + `ChatGPT-Account-Id: <user.id>`. T27 в `OpenAICookiesReader.swift`: добавлен `fetchAccessToken(cookieHeader:)`, `fetchSnapshot()` теперь делает exchange→Bearer→usage, Cookie header убран из wham. Новая ошибка `.sessionExchangeFailed(httpCode:)` с actionable message ("log out and back in on chatgpt.com"), `LocalizedError` conformance добавлен. **Live verify**: ChatGPT 99%/94% left показываются как authoritative (раньше `ukwn`).

5. ~~**[P3] Diagnostic os_log** — гейтить за UserDefaults.~~ → **Закрыто 2026-05-16 (T28)**. `arabar/Infra/DebugLog.swift`: `debugLog(_:type:_:)` helper с `@autoclosure` (skip string formatting когда флаг off) гейтит за `UserDefaults.standard.bool(forKey: "debug.cookies")`, default false. 26 сайтов переведены (11 в ClaudeCookiesReader, 15 в OpenAICookiesReader включая 1 NSLog). README: `defaults write com.arystantelbay.arabar debug.cookies -bool true` + restart → логи в Console.app по subsystem `com.arystantelbay.arabar`.

## TODO в следующей сессии (приоритеты)

4. ~~**[P2] Bug-B/C**: Chrome multi-profile + NextAuth split cookies.~~ → **Закрыто 2026-05-16 (T24)**. **Диагноз**: пользователь логинится в `Profile 1`, наш ридер смотрел только `Default` (пусто). ChatGPT NextAuth cookie разбит на `.0` + `.1` чанки, ридер искал ровно `__Secure-next-auth.session-token`. Плюс в OpenAI ридере был неправильный keychain account (`"chrome.safeStorage"` вместо `"Chrome Safe Storage"`/`"Chrome"`). Плюс ошибка `.decryptionFailed` ложно показывалась когда cookie вообще не было. **Фиксы**: `profileCookiesPaths()` энумерирует Default + `Profile \d+` (sorted), ридер итерирует по профилям пока не найдёт cookie; `assembleNextAuthCookieHeader()` собирает chunks обратно как `name.0=v0; name.1=v1` (NextAuth сервер сам реассемблит); правильный keychain account; `.cookiesNotFound` если строки SQL нет, `.decryptionFailed` только если действительно расшифровка упала; `.appBoundEncryption` (v20 prefix) с actionable message "use Safari or Chrome v126-".
5. ~~**[P3] Bug-E**: UX улучшения Settings.~~ → **Закрыто 2026-05-16 (T23)**. `apiKeyHasValue` перечитывается через `.onAppear` (всегда свежее состояние при открытии таба); зелёный `checkmark.circle.fill + "API key saved in Keychain"` под SecureField когда ключ есть и пользователь не печатает.
6. ~~**Cookie expiration UI**~~ → **Закрыто 2026-05-16 (T23, Safari only)**. Helper `cookieExpiryStatus(for:hosts:cookieName:)` показывает "Expires in X days" / "Expires today" / "Expired N days ago" под cookies статусом после Test connection. Цвет: красный для expired, оранжевый <3 дней, secondary иначе. Реализовано для Safari (используем уже готовый `SafariBinaryCookies.readCookies`). Для Chromium браузеров — пока не показывается (можно добавить чтением `expires_utc` из SQLite позже).

---

## Schemas (заполнено T1)

### Claude JSONL

- **Путь:** `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`
- **Subagents:** `~/.claude/projects/<encoded-cwd>/<sessionId>/subagents/agent-<id>.jsonl` — парсить наравне с основными.
- **Типы записей** (поле `type` верхнего уровня): `user`, `assistant`, `attachment`, `system`, `file-history-snapshot`, `ai-title`, `last-prompt`, `permission-mode`, `queue-operation`.
- **Токены** — только в `type == "assistant"`, путь:
  - `message.usage.input_tokens`
  - `message.usage.output_tokens`
  - `message.usage.cache_creation_input_tokens` (с детализацией `cache_creation.ephemeral_1h_input_tokens` / `ephemeral_5m_input_tokens`)
  - `message.usage.cache_read_input_tokens`
  - `message.usage.iterations[]` — per-iteration usage (для streaming)
  - `message.usage.service_tier` — `"standard"` и т.п.
- **Timestamp:** ISO 8601 с миллисекундами, поле `timestamp` верхнего уровня.
- **Модель:** `message.model` (например `claude-opus-4-7`).
- **IDs:** `uuid` (записи), `parentUuid` (дерево), `sessionId`, `message.id` (`msg_01…`), `requestId` (`req_011…`).
- **Дедупликация:** одинаковые `message.id` могут встречаться дважды (streaming + final). Обязательно фильтровать.
- **isSidechain == true** — параллельная ветка subagent, может задваивать расход — решить отдельно (вероятно считать).

### Codex JSONL

- **Путь:** `~/.codex/sessions/YYYY/MM/DD/rollout-<ISO-datetime>-<sessionId>.jsonl`
- **Также:** `~/.codex/session_index.jsonl` (без токенов), `~/.codex/history.jsonl` (epoch ts, redacted text).
- **Типы записей** — `type` верхнего уровня: `session_meta`, `turn_context`, `event_msg`, `response_item`. Подтипы — в `payload.type`.
- **Токены** — только в `event_msg` с `payload.type == "token_count"`:
  - `payload.info.total_token_usage.{input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens, total_tokens}` (накопительно)
  - `payload.info.last_token_usage.{...}` — **используем эту дельту** для per-turn
  - `payload.info.model_context_window`
- **Timestamp:** ISO 8601 в `timestamp` верхнего уровня. В `history.jsonl` — Unix epoch int.
- **Модель:** `turn_context.payload.model` (например `gpt-5.4`). Нужно отслеживать последний `turn_context` для каждого `turn_id`, т.к. `token_count` модель не несёт.
- **IDs:** `session_meta.payload.id` (UUID сессии = имя файла), `turn_id` в `turn_context` / `task_started` / `token_count`.
- **Особенности:** нет разбивки cache_creation vs cache_read — только суммарный `cached_input_tokens`. `reasoning_output_tokens` (o-модели) не входит в `output_tokens`.

### Черновик UsageEvent.swift (от T1, для использования в T4/T5)

```swift
enum Provider { case claude, codex }

struct UsageEvent {
    let timestamp: Date
    let provider: Provider
    let model: String
    let sessionId: String
    let messageId: String?       // Claude: message.id | Codex: turn_id

    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int     // Claude only (Codex = 0)
    let cacheCreationTokens: Int // Claude only (Codex = 0)
    let cachedTokens: Int        // Codex only — суммарный cached_input
    let reasoningTokens: Int     // Codex only — o-model thinking
}
```

---

## Открытые вопросы

Все исходные вопросы (точные лимиты Pro/Max, авто-калибровка %, SVG vs SF Symbols) сняты:

- **Лимиты Pro/Max не нужны**: `PlanLimits.swift` удалён в review pass (W2), процент берём напрямую из cookies-endpoint'ов (`utilization` от Anthropic, `used_percent` от OpenAI) — это и есть авторитетная цифра от провайдера.
- **Иконки**: SVG в `Assets.xcassets` (AnthropicLogo + OpenAILogo, simple-icons CC0), template-rendered, ресайз через NSImage drawing block. SF Symbols только как фолбэк для status-индикаторов (warning triangle).

---

## Лог сессий

- **2026-05-16** — первая сессия. Согласован стек (Swift + SwiftUI MenuBarExtra), отказ от browser cookies в пользу Keychain нашего приложения, формат отображения с процентами в menubar. Создана папка проекта. STATUS.md написан.
- **2026-05-16** — фаза 1 завершена тремя параллельными агентами (T1/T2/T3, все sonnet). Скелет собирается (`swift build` → `Build complete!`). Logic-файлы Pricing/PlanLimits подключены в target после фикса `sources: ["App", "Logic"]` в `Package.swift`. Готовы стартовать фазу 2 (T4 Claude parser, T5 Codex parser) — оба зависят от T1 (схемы есть), могут идти параллельно.
- **2026-05-16** — фаза 2 (часть): T4 + T5 закрыты параллельно (sonnet). Перед запуском вручную созданы `arabar/Model/Provider.swift` + `arabar/Model/UsageEvent.swift` чтобы оба агента опирались на готовый тип и не конфликтовали. `Package.swift` обновлён: `sources: ["App", "Logic", "Model", "DataSource"]`. Clean build с нуля (`swift package clean && swift build`) проходит чисто, 9 .swift файлов компилируются. LSP-предупреждения о ненайденных типах между файлами одного таргета — ложные, артефакт изолированной индексации SourceKit (баг не у нас). Готовы к T6 (Aggregator) — единственный блокер для перехода в фазу 3 (UI).
- **2026-05-16** — фаза 2 закрыта. T6 (Aggregator, sonnet). Clean build с нуля — 11 .swift файлов, `Build complete!` без warnings. Фаза 3 разблокирована: T7 (MenuBar UI) и T8 (Auto-refresh + Status API) могут идти параллельно — обе зависят только от T6 (UsageSnapshot готов). T9 (Packaging) — после T7.
- **2026-05-16** — фаза 3 (UI + auto-refresh) закрыта. T7 + T8 запущены параллельно (sonnet). Перед запуском вручную созданы `arabar/App/AppViewModel.swift` (общий ObservableObject со стабом `refresh()`) и `arabar/Model/StatusInfo.swift` — чтобы агенты не конкурировали за `ArabarApp.swift`. `Package.swift` дополнен `sources: [..., "UI", "Infra"]`. T7 переписал `ArabarApp.swift` на `@StateObject AppViewModel + MenuBarExtra { content } label: { label }`. T8 пропатчил тот же файл (через Edit, не Write) — добавил `@StateObject AppLifecycle` и `.onAppear { lifecycle.attach(to: viewModel) }`. Конфликта не было: T8 запускался после того как T7 уже сохранил свою версию. Clean build с нуля — 16 .swift файлов, `Build complete!` без warnings. Осталось только T9 (Packaging).
- **2026-05-16** — фаза 4 (Packaging) закрыта. T9 (sonnet). MVP готов: `build/arabar.app` 712K, ad-hoc подписан. Clean build с нуля — 17 .swift файлов. Все 9 задач (T1-T9) выполнены. Установка пользователем: `cp -R build/arabar.app /Applications/ && open /Applications/arabar.app`. Что ещё может потребоваться (вне MVP): уточнить цены OpenAI (агрегатор мог соврать), уточнить лимиты Claude Pro/Max в `PlanLimits.swift` (сейчас комьюнити-оценки с TODO), Sparkle auto-update, WidgetKit, поддержка других провайдеров.
- **2026-05-16** — `Pricing.swift` сверен с официальными источниками: `platform.claude.com/docs/en/about-claude/pricing` (Anthropic) и `developers.openai.com/api/docs/pricing` (OpenAI). Anthropic — все текущие цены совпадают, добавлены deprecated tier-ы opus-4-1/opus-4 ($15/$75) и sonnet-4. OpenAI — главный фикс: `gpt-5-5.cachedInputPerMTok` был `0.00` (TODO), реально `$0.50`; все TODO про gpt-5.5 сняты. Добавлены `gpt-5-4-pro` и `gpt-5-5-pro` ($30/$180). Старые модели (gpt-5, o3, o4) сняты с официальной страницы — оставлены в коде как fallback для исторических session логов с пометкой "retired". Build чистый.
- **2026-05-16** — установлено в `/Applications/arabar.app`, запущено. Найден архитектурный баг: `ClaudeUsageReader.fetchNewEvents()` возвращает только дельту после offset-кэша, и Aggregator получал пустой массив на каждом refresh после первого → все окна 0%. **Фикс**: в `AppViewModel` добавлен event buffer с persistence в `~/Library/Application Support/arabar/event_buffer.json`, prune старее 192h (168 + 24h запаса), `loadBuffer()` в init. Первый refresh после старта приложения вызывает `rebuildAll()` (если buffer пуст) вместо `fetchNewEvents()`, чтобы корректно подтянуть текущее 5h-окно из уже прочитанных reader-ом файлов. Также: **MenuBarLabel** — убраны буквы `C` / `G` по запросу пользователя, label теперь `XX% • YY%` (левый = Claude, правый = Codex). Codex у пользователя показывает `—` т.к. нет JSONL в `~/.codex/sessions/` за 30 дней (пользователь не использует Codex CLI).
- **2026-05-16** — Фаза 5 группа A закрыта 5 параллельными агентами (T10/T11/T14/T16/T17, все sonnet, background). Перед запуском вручную создан `arabar/Infra/KeychainStore.swift` с константами `KeychainAccount.{anthropicAdminKey, openaiAdminKey}` чтобы агенты не плодили дубликаты. Clean build с нуля — **24 .swift файла**, `Build complete!` (6.97s) без warnings. T14 уже пропатчен MenuBarLabel (ротация работает), но без cookies/admin keys источников оба провайдера показывают `arabar` placeholder (или Claude % из JSONL). Готовы к Группе B: T12 + T18 (Settings UI) — пользователь должен иметь возможность включить cookies и/или ввести Admin keys.
- **2026-05-16** — Фаза 5 закрыта полностью. Группа B (T12+T18) — единый Settings UI с табами Claude/ChatGPT/About, секции Subscription cookies + API Admin keys + Display source picker. Группа C (T13+T19) — multi-source dispatcher в AppViewModel: cookies → JSONL fallback для subscription, Admin API отдельным snapshot; override primary snapshot если user выбрал "api" как display source; в MenuContentView показываются обе секции (sub + api) если оба настроены. Clean build с нуля — **26 .swift файлов**, `Build complete!` без warnings. **MVP Фазы 5 готов**: пользователь может включить cookies в Settings, ввести Admin keys, увидеть данные либо из CLI, либо из браузера, либо из API. Остался только пересбор `.app` бандла и переустановка — это пользователь сам через `./scripts/build_app.sh release && cp -R build/arabar.app /Applications/`.

- **2026-05-16** — Фаза 5 группа B (T12+T18, один агент sonnet): Settings UI с табами Claude/ChatGPT/About. Settings секции: cookies opt-in toggle + browser picker + Test, API tier `SecureField` + Save/Clear/Test + Keychain, Display picker Subscription/API.
- **2026-05-16** — Фаза 5 группа C (T13+T19, один агент sonnet): multi-source dispatcher в AppViewModel. Параллельный refresh всех источников через `async let` (6 задач), `computeSubscriptionSnapshot` (cookies → JSONL fallback), `computeAPISnapshot` (Admin key only, `.missingKey` silently nil), override primary при `display.source == "api"`. MenuContentView рендерит secondary "Claude API"/"OpenAI API" секцию если API snapshot есть и != primary. **26 .swift файлов, clean build чистый**.
- **2026-05-16** — T15: README обновлён (3 источника, как открыть Settings, opt-in cookies дисклеймер, где взять Admin keys). STATUS лог дополнен.
- **2026-05-16** — Установка `.app` 1.3M в /Applications. Обнаружено 2 бага: (1) `Image("AnthropicLogo")` не находит ассет — SPM кладёт в `arabar_arabar.bundle`, не main bundle. Фикс агентом: `Image(name, bundle: .module)`. (2) `Settings { ... }` scene не открывается в LSUIElement apps. Фикс агентом: заменено на `Window(id: "settings")` + `@Environment(\.openWindow)` в MenuContentView. Пересобрано, переустановлено.
- **2026-05-16** — После переустановки: Settings окно работает (скриншоты пользователя подтверждают). НО: (a) иконка в menubar **не появляется вообще** (Bug-A); (b) Claude cookies в Chrome не находятся — `"No cookies — log in to claude.ai"` (Bug-B); (c) ChatGPT cookies в Chrome — `"Error: Chrome Safe Storage decryption failed"` (Bug-C). См. раздел "⚠️ ОТКРЫТЫЕ БАГИ" выше. Сессия приостановлена для продолжения в следующий раз. Приоритет в новой сессии: P0 Bug-A (без иконки приложение бесполезно).
- **2026-05-16** — Доп. наблюдение от пользователя по дропдауну (скриншот): Claude Code показывает реальные данные из JSONL (44.7M tokens, $34.11), но процент 100% — фейк, т.к. `PlanLimits.claudePro.maxTokens` это комьюнити-оценка. Зафиксировано как Bug-F (P0). Решение: ввести `PercentSource { authoritative, estimated, unknown }` в `UsageSnapshot` и различать в UI. Cookies path → authoritative, JSONL и Admin API → estimated.

- **2026-05-16** — Новая сессия: оркестрация фикса P0/P1 багов через 3 параллельных sonnet-агентов.
  - **T20 (Bug-A)**: `scripts/build_app.sh` — добавлен шаг `xcrun actool --compile` после копирования SPM resource bundle. `Assets.car` теперь кладётся в `arabar.app/Contents/Resources/arabar_arabar.bundle/Assets.car`. Сырой `Assets.xcassets/` удаляется из bundle. Verify: `assetutil --info` показывает `AnthropicLogo` (24×24, preserved vector) + `OpenAILogo`.
  - **T21 (Bug-F)**: `UsageSnapshot.swift` — `enum PercentSource { authoritative, estimated, unknown }` + `percentSource` поле в `WindowSnapshot`. `Aggregator.percentUsedWithSource()` решает source (estimated если PlanLimits.maxTokens найден, unknown если nil). `ClaudeCookiesReader.parseWindow` / `OpenAICookiesReader.buildSnapshot` → `.authoritative`. UI: `percentLabel(for:)` рендерит `XX%`/`~XX%`/`—` с цветом и tooltip; `progressBarColor` серый для estimated/unknown.
  - **T22 (Bug-D)**: `SafariBinaryCookies.swift` (~160 LOC, чистый Swift) — парсер Apple BinaryCookies (big-endian header, little-endian records, Apple epoch). Ветка `.safari` в обоих cookies readers теперь читает `~/Library/Cookies/Cookies.binarycookies`. Новый case `accessDenied` с actionable message для Full Disk Access.
  - Clean build: **25 .swift файлов** (+1 SafariBinaryCookies), `swift build -c debug` → Build complete без warnings. Release `.app` — 1.3M ad-hoc подписан, `Assets.car` на месте.
  - Установка пользователем: `cp -R build/arabar.app /Applications/ && open /Applications/arabar.app`. Ожидаем: иконка появится в menubar (Bug-A); проценты Claude из JSONL покажутся как `~XX%` курсивом серым (Bug-F, честная оценочность); Safari опция в Settings теперь работает (после Full Disk Access).
  - Остались: Bug-B/C (Chrome cookies диагностика — теперь не критично, Safari path есть), Bug-E (Settings UX), Cookie expiration UI.

- **2026-05-16** — Вторая половина сессии: ещё два sonnet-агента (T23 + T24) + диагностика Chrome.
  - **Диагностика Chrome (sqlite запросы по 3 профилям пользователя)**: `Default` пуст; **`Profile 1`** содержит 86 cookies для claude/chatgpt/openai (включая `sessionKey` для claude.ai и split `__Secure-next-auth.session-token.0/.1` для chatgpt.com); `Profile 2` пуст. App-Bound Encryption (`v20`) НЕ применяется — все cookies `v10`. Это и были причины Bug-B/C: scan только Default + неправильное cookie name + плохая обработка ошибок.
  - **T23 (Bug-E + Cookie expiration UI)**: `SettingsView.swift` — `.onAppear { apiKeyHasValue = KeychainStore.has(...) }` для актуального состояния; зелёный checkmark индикатор когда ключ сохранён; helper `cookieExpiryStatus(for:hosts:cookieName:)` показывает relative-day строку под Test статусом, цвет: red expired / orange <3d / secondary иначе. Реализовано для Safari (Chromium browsers — TODO позже, нужно читать `expires_utc` из SQLite).
  - **T24 (Bug-B/C — Chrome multi-profile + NextAuth split)**: `profileCookiesPaths(underRoot:)` энумерирует Default + `Profile \d+`, оба ридера итерируют по профилям. `assembleNextAuthCookieHeader()` собирает chunks `.0`/`.1`/... обратно в Cookie header. Правильный keychain account в OpenAI ридере. Чёткое разделение ошибок (`.cookiesNotFound` vs `.decryptionFailed` vs `.appBoundEncryption`).
  - Clean build: **25 .swift файлов**, `swift build -c debug` → Build complete, 0 warnings. Release `.app` 1.4M ad-hoc подписан. Установлено в `/Applications/arabar.app` (PID 37598).
  - Все P0/P1/P2/P3 баги закрыты. Незакрытые задачи: Chromium cookie expiration display (Safari-only сейчас), потенциальные UX polish (например, "выберите Chrome профиль" picker если пользователь хочет конкретный).

- **2026-05-16** — Финальная итерация дня. Прорыв: разобрались с **Chrome 130+ cookie format**.
  - **Корень всех "decryption failed"**: Chrome 130+ (DB schema version ≥ 24) добавил в plaintext **32-байтный SHA256(host_key)** перед собственно cookie value. AES-CBC дешифровка возвращала ОК, но первые 32 байта — бинарный hash, не UTF-8 → throw decryptionFailed. Источник: [creachadair gist](https://gist.github.com/creachadair/937179894a24571ce9860e2475a2d2ec). Фикс: в обоих ридерах читаем `SELECT value FROM meta WHERE key='version'`, если ≥ 24 — после CCCrypt drop первых 32 байт. Сразу заработало: Claude `key #0 → decrypt OK, len=131, head=sk-ant-s, valid=YES`.
  - **Изменения по UI**: иконки 10pt → через явный `NSImage` с resize до фиксированного pixel size (11pt) — теперь корректный размер; ротация 20s → 30s; `ukwn` вместо `~XX%`/`—` для `.estimated`/`.unknown` (по запросу пользователя — честность); progress bar приглушённый для не-authoritative; ротация без skip (показываем оба провайдера всегда).
  - **Bug-B/C Chrome (повторно)**: ridder сканирует все Chrome профили (Default + Profile N), enumerate Keychain `kSecMatchLimitAll`, validate by `sk-ant-` prefix; CLI fallback через `/usr/bin/security` для случаев когда native API молча падает (ad-hoc LSUIElement не получает Keychain prompt UI).
  - **Дополнительная диагностика**: переход с NSLog (приватные args редактировались в `<private>`) на `os_log` с `%{public}` маркерами + subsystem `com.arystantelbay.arabar` категории `cookies-claude`/`cookies-openai`. Проверка через `log show --predicate "subsystem == \"com.arystantelbay.arabar\""`.
  - **ChatGPT — частично работает**: cookies дешифруются OK (3933+335 bytes), но endpoint `/backend-api/wham/usage` возвращает **401** для cookies-only пути — этот endpoint требует Bearer token (OAuth/Codex CLI). Cookies-friendly endpoint неизвестен (CodexBar для cookies использует WebView scrape `chatgpt.com/codex/settings/usage`). Сейчас 401 → `emptySnapshot()` → ChatGPT показывает "Connected" + `ukwn` процент (честно).
  - **Известные cookies endpoints для ChatGPT** (TODO research):
    - `/backend-api/wham/usage` — требует `Authorization: Bearer <token>` от `~/.codex/auth.json`. JSON: `{plan_type, rate_limit: {primary_window, secondary_window}}` где WindowSnapshot имеет `used_percent`, `reset_at` (Unix), `limit_window_seconds`.
    - `/backend-api/me` — для verify session (200/401), не даёт % usage.
    - `chatgpt.com/codex/settings/usage` — HTML страница, требует WebView scrape.
  - Final state: 25 .swift файлов, `/Applications/arabar.app` 1.4M ad-hoc подписан. **Claude work end-to-end** (cookies → authoritative %); **ChatGPT cookies work**, но процент требует другого endpoint или OAuth путь.

- **2026-05-16** — Третья итерация после live-теста пользователя. Найдены: иконка слишком крупная, ротация скипает Codex (нет данных → `.unknown` → пропуск), процент `~100%` всё равно misleading, "Keychain decryption failed" не исчезла. Diagnose Bug-A повтор: SPM bundle `arabar_arabar.bundle` **без Info.plist**, AppKit AssetCatalog API его не принимает. **Фикс иконки**: `Assets.car` теперь кладётся в `arabar.app/Contents/Resources/` (главный bundle, валидный Info.plist), `MenuBarLabel` использует `Image("AnthropicLogo")` без `bundle: .module`. Параллельные агенты:
  - **Agent A (UI)**: иконка 12→10pt + `.imageScale(.small)`; ротация 20→30s; убран skip провайдеров без данных (всегда показываем оба); для `.estimated`/`.unknown` (или nil) показывается строка `ukwn` (пользователь выбрал, чтобы не было ложного `~XX%`/`100%`); progress bar для не-authoritative — приглушённый `.secondary.opacity(0.3)`.
  - **Agent B (Chrome Keychain)**: macOS подавляет Keychain prompts для ad-hoc подписанных LSUIElement apps → `SecItemCopyMatching` молча падает. Добавлен fallback: после native попытки → `Process` shell out `/usr/bin/security find-generic-password -w -s "Chrome Safe Storage" -a "Chrome"` (CLI имеет cached permission). Если security CLI тоже падает → новая ошибка `.keychainAccessDenied` с actionable message "Open Keychain Access.app → 'Chrome Safe Storage' → Access Control → add arabar". Заодно обнаружен и исправлен баг T24: OpenAI ридер искал в Keychain `"Chrome Safe Storage Safe Storage"` (двойной суффикс) — никогда не нашёл бы.
  - Clean build: 25 .swift файлов, 0 warnings. Release `.app` 1.4M переустановлен (PID 41410).

- **2026-05-16** — Финальная итерация сессии: оркестрация 4 параллельных/последовательных sonnet-агентов + один manual UX fix. Закрыты все 5 пунктов пользовательского TODO + новая регрессия.
  - **T25 (UI overhaul)**: Footer wrapped в VStack (Toggle на своей строке, "Launch at Login" целиком); custom relative time formatter через `Calendar.dateComponents` (`in Xd Yh` / `in Xh Ym` / `in Xm`); inverted % scale → текст `X% left`, цвет `remainingColor` (>0.30 зелёный / 0.10-0.30 оранжевый / <0.10 красный) в `MenuContentView.percentLabel` + `MenuBarLabel.providerChip` + `MenuBarLabel.color`. Применяется только когда `.authoritative`.
  - **T26 (research, read-only, sonnet)**: проверено через CodexBar Swift исходники + WebSearch. Корневая причина 401 на `/wham/usage` — endpoint требует `Authorization: Bearer`, никогда не примет cookies напрямую. Решение: 2-step flow `cookies → /api/auth/session → accessToken (JWT) → /wham/usage с Bearer`. Confidence High — схема `WhamUsageResponse` совпадает с тем что у нас уже было.
  - **T27 (impl)**: `OpenAICookiesReader.swift` — новый private `fetchAccessToken(cookieHeader:) -> (String, String?)` через `/api/auth/session`; `fetchSnapshot()` теперь делает exchange→Bearer→usage; Cookie header убран из wham-запроса. Добавлен `case sessionExchangeFailed(httpCode:)` в error enum + `LocalizedError` conformance, message `"ChatGPT session expired — log out and back in on chatgpt.com (HTTP <code>)"`. Существующий `WhamUsageResponse` + `buildSnapshot` оказались уже корректными (написаны изначально под Bearer flow). Старый `applyHeaders` helper остался unused — minor cruft, не блокирует.
  - **T28 (os_log gating)**: создан `arabar/Infra/DebugLog.swift` с `debugLog(_:type:_:)` и `@autoclosure` (skip string formatting когда флаг off), гейтит за `UserDefaults.standard.bool(forKey: "debug.cookies")` (default false). 26 сайтов переведены (11 ClaudeCookiesReader + 15 OpenAICookiesReader). `Package.swift` не трогался — `Infra/` уже в sources. README дополнен одной строкой с инструкцией `defaults write … debug.cookies -bool true`.
  - **T29 (regression fix)**: после успешного запуска cookies path в прошлой сессии Claude Code показывал `0 tokens · $0.00` — `computeSubscriptionSnapshot` возвращал либо cookies (только `%`, без токенов) либо JSONL (с токенами но `.estimated %`), не оба. Фикс в `AppViewModel.swift`: всегда параллельно через `async let` запускается JSONL, при успехе cookies — merge через новые `mergedSnapshot` / `mergedWindow` helpers. Из cookies: `percentUsed`, `percentSource`, `resetAt`, `durationHours`. Из JSONL: `tokensUsed`, `costUSD`. Все поля `let` → строятся новые инстансы. При cookies error → fallback к уже посчитанному JSONL без double-compute.
  - **Manual bar-fill fix (post T25 live verify)**: T25 агент выбрал bar fill = used (тинт по remaining). Пользователь после установки запросил инвертировать ещё и сам бар — "осталось 14%, но шкала большая" расходится с текстом. Helper `barFillValue(for:)` возвращает `1.0 - used` (при `percentUsed == nil` → 0). Бар теперь shrinks as usage grows: короткий красный = тревога, длинный зелёный = много осталось.
  - **Live verify пользователем** (скриншот после второй установки): footer ровный; resets как `in 8m` / `in 1d 5h` / `in 4h 59m` / `in 1h 1m`; Claude 5h `14% left` + `87.6M tokens · $65.12` (T29 закрыт); Claude 7d `92% left`; **ChatGPT cookies заработали как authoritative** (`99%/94% left` — было `ukwn` до T27).
  - Clean build: **26 .swift файлов** (+1 `DebugLog.swift`), 0 warnings. Release `.app` 1.4M ad-hoc подписан, установлен в `/Applications/arabar.app` (PID 71349).
  - **LSP false-positive caveat** (повторился): после edit с новыми символами SourceKit показывал ошибки `Cannot find 'debugLog' in scope` / `Cannot find 'barFillValue' in scope` пока не переиндексировал. Реальный `swift build -c debug` чистый. Та же история что в логе 2026-05-16 ранней сессии.

- **2026-05-16** — Ещё одна итерация по запросу пользователя: 4 параллельных/последовательных sonnet-агентов + один inline cleanup. Polling интервалы зафиксированы: 60s auto-refresh, 30s ротация иконки в menubar.
  - **T31 (inline cleanup)**: убран unused `applyHeaders` из `OpenAICookiesReader.swift` (cruft после T27). Verified `grep -c applyHeaders` == 0.
  - **T33 (sticky last-good snapshot, sonnet)**: фикс flicker — ChatGPT иногда мелькал на `ukwn` при transient `.sessionExchangeFailed` / 5xx, потом возвращался. `AppViewModel.swift`: новые helpers `preferUseful(new:current:)` и `isUseful(_:)` — снапшот считается useful если `sessionWindow` ИЛИ `weeklyWindow` имеет `percentSource == .authoritative`. Все 4 `@Published` поля (`claudeSnapshot`, `codexSnapshot`, `claudeApiSnapshot`, `codexApiSnapshot`) теперь проходят через `preferUseful`. Поведение: новый authoritative → используем; новый non-useful + старый useful → keep old; оба non-useful → используем new. Для API path (всегда `.estimated`/`.unknown`) — sticky не срабатывает, что и задумано (юзер жаловался только на cookies path). TODO comment про инвалидацию sticky при toggle cookies в Settings — не реализовано (rare edge case, restart процесса лечит).
  - **T34 (footer reorg, sonnet)**: финальный layout — Row 1: `[☑ Launch at Login] [Spacer] [Updated X seconds ago]` (полный текст, без truncation), Row 2: `[↻] [Settings…] [Quit] [Spacer]` (кнопки кластерятся слева, полные labels). `MenuContentView.swift` lines 171-214 переписаны. Все bindings/actions/shortcuts/help сохранены без изменений.
  - **T30 + T32 (Chromium cookie expiry + SSO/2FA TTL warning UX, sonnet)**: одним агентом, т.к. T32 нуждается в expiry helper'е T30. Новые файлы: `arabar/DataSource/ChromiumCookieDB.swift` (~115 LOC, SQLite reader через `import SQLite3`, конвертирует `expires_utc` из Windows FILETIME микросекунд `/1_000_000 - 11_644_473_600` в Unix epoch, скан Default + Profile N, copy DB в /tmp чтобы не словить lock от запущенного Chrome; `SQLITE_TRANSIENT` через `unsafeBitCast(-1, to: sqlite3_destructor_type.self)` workaround) и `arabar/DataSource/CookieExpiry.swift` (~60 LOC, unified `forProvider(_:Provider) -> Date?` — читает selected browser из UserDefaults `cookies.source.claude` / `cookies.source.openai`, диспатчит на ChromiumCookieDB или `SafariBinaryCookies.readCookies` для Safari). Enum — `BrowserSource` (находится в ClaudeCookiesReader.swift), не `BrowserKind`. `SafariBinaryCookies` уже экспозит `SafariCookie.expiry: Date?` — extension не понадобился. `SettingsView` теперь показывает expiry для всех 4 браузеров (раньше только Safari через T23): `cookieExpiryDate(for:hosts:cookieName:)` extracted helper, `expiryStatusString(from:)` extracted чтобы не дублировать форматирование. Dropdown UX: `AppViewModel.{claudeCookieExpiresAt, codexCookieExpiresAt}: Date?` обновляются в `refresh()` через `Task.detached { CookieExpiry.forProvider(...) }.value`; `MenuContentView.providerSection` принимает доп. `provider: Provider?` (nil для API sub-sections), рендерит inline HStack triangle+text warning под title когда expiry: <1h "in Xm" red, <24h "in Xh" red, <72h "in X days" orange, ≥72h или expired → nil. ChatGPT cookie name — пробуем `__Secure-next-auth.session-token.0` сначала, fallback на plain `__Secure-next-auth.session-token` (NextAuth chunks share expiry). `expires_utc == 0` (session cookie) → nil, warning не показываем.

- **2026-05-16** — Большая review-сессия. Пытались `/ultrareview` (multi-agent cloud review): сделали публичный репо `https://github.com/ATelbay/arabar`, установили Claude GitHub App на `ATelbay/arabar`, создали ветку `review` orphan-rebased на пустой `main` для merge-base. Команда упёрлась в известный backend bug Anthropic ([anthropics/claude-code#53648](https://github.com/anthropics/claude-code/issues/53648)) — `"Claude GitHub app must be installed"` при корректно установленном App, без обхода. Перешли на ручную оркестрацию.
  - **Review pass — 5 sonnet-агентов параллельно**: R1 (дубликаты/dead code), R2 (архитектура), R3 (security), R4 (memory/concurrency), R5 (PlanLimits + test coverage). Нашли **32 findings**: 1 critical, 13 high, 12 medium, 4 low. R3 верифицировал чистоту: нет shell injection в `/usr/bin/security` (argv-style), AES-CBC параметры корректны, Chrome 130+ hash-prefix правильно strip-ается, TOCTOU отсутствует, `Info.plist` без подозрительных entitlements.
  - **Wave 1 — 3 параллельных агента** (W1+W2+W3, sonnet): W1 удалил `print()` Admin API key prefix (C1, release-path leak) + 3 raw `print()` в `ClaudeUsageReader` (→ `debugLog`). W2 удалил `PlanLimits.swift` целиком (-269 LOC), `Aggregator.percentUsedWithSource()` → `(nil, .unknown)`. W3 security mediums: `kSecAttrAccessibleAfterFirstUnlock` → `WhenUnlocked` в `KeychainStore`, `%{public}@` → `%{private}@` в `DebugLog`, SQL queries параметризованы через `sqlite3_bind_text` в обоих cookies ридерах.
  - **Wave 2 — 2 агента параллельно**: W4+W7 (Концerns + arch в AppViewModel, MenuContentView, 2 admin readers — 8 fixes за один прогон) и W6 (Chromium dedup — новый `ChromiumKeychain.swift` +125 LOC, расширен `ChromiumCookieDB.swift` +76 LOC, ужал `ClaudeCookiesReader.swift` -199 LOC и `OpenAICookiesReader.swift` -181 LOC). W7 fixes: sticky snapshot инвалидация при toggle cookies в Settings (Combine subscription на `UserDefaults.didChangeNotification`), `mergedWindow` фолбэк на `cookies.tokensUsed` если JSONL пуст, per-provider rebuild tracking (`Set<Provider>`) вместо одного флага → race fix, gate `saveBuffer()` на `!eventBuffer.isEmpty`, inline warning в MenuContentView когда Admin API+JSONL оба активны для провайдера. W4: Admin API readers получили `timeoutInterval = 15`, cookies readers hoisted как stored properties (избегаем re-copy SQLite на каждом refresh), `Task.detached` → `Task` для structured cancellation. W6 закрыл correctness gap: новый `decryptChromeCookieBlob` использует safe `v10/v11` prefix-check (раньше blind 3-byte strip).
  - **Wave 3 — 3 агента параллельно**: W5 (MainActor I/O offload — `loadBuffer/jsonlSnapshot/saveBuffer` ушли на `Task.detached`, добавлен `isBufferLoaded` gate чтобы `jsonlSnapshot` ждал асинхронной загрузки, `@unchecked Sendable` на `ClaudeUsageReader`+`CodexUsageReader` с обоснованием single-owner serial access). W8 (unit tests — впервые в проекте: `Tests/arabarTests/` target + 23 теста для `Aggregator.cost`, `Aggregator.aggregate`, `makeWindowSnapshot` summation, `SafariBinaryCookies.parse`, byte-order helpers; `private` → `internal` для тестируемости; **bonus bug fix**: `load(as:)` → `loadUnaligned(as:)` в `readUInt32BE/LE`/`readFloat64LE` — реальный arm64 crash при нечётном offset, обнаружен только из-за тестов). W9 (мелкие dedup: удалён `OpenAIBrowserSource` дубль, `mapSafariError` consolidated через `SafariErrorCategory`, `JSONDecoder.iso8601Flexible` extracted в новый `SharedDecoders.swift`, `ProviderSettingsTab` extracted из дубля `Claude/OpenAISettingsTab` (-170 LOC в SettingsView), удалён dead `.estimated` case из `PercentSource` enum, добавлен `ChromiumCookieDB.withTempCopy` helper).
  - **Покрытие**: Critical 1/1 ✅, High 13/13 ✅, Medium 12/13 ✅ (осталось M3 — упростить `PercentSource` до `Bool` после удаления `.estimated`), Low 4/5 ✅ (L4 strict-concurrency hint — optional polish). Все билды чистые на каждом шаге.
  - **Ротация menubar — фикс нестабильности**: пользователь пожаловался что переключение Claude↔ChatGPT в menubar работает рандомно. Root cause: `let timer = Timer.publish(...).autoconnect()` объявлен на `MenuBarLabel` (View struct, value type) — пересоздавался на каждом parent re-render (а с `@Published` обновлениями viewModel это часто), сбрасывая 30-секундный отсчёт. **Фикс**: rotation state (`rotationIndex: Int` + `Timer.scheduledTimer`) переехал в `AppViewModel` (`@StateObject`, живёт весь lifecycle процесса). `MenuBarLabel` стал stateless — читает `viewModel.rotationIndex % providers.count`.
  - **Right-click переключение провайдера (новая фича)**: пользователь захотел чтобы ПКМ / two-finger tap по иконке менял провайдера. `MenuBarExtra` не различает кнопки мыши → миграция на AppKit `NSStatusItem` + `NSPopover` через новый `MenuBarController.swift`. `ArabarApp.swift` теперь через `@NSApplicationDelegateAdaptor(AppDelegate.self)`, AppDelegate владеет `viewModel`/`lifecycle`/`menuBarController`. Settings scene осталась SwiftUI `Window`. `button.sendAction(on: [.leftMouseUp, .rightMouseUp])` + проверка `NSApp.currentEvent?.type` → left-click открывает popover, right-click инкрементит `rotationIndex`. После первой установки проценты пропали (auto-layout problem) — `NSHostingView` пинился только leading/trailing/centerY + 4pt insets, ширина status item не догнала intrinsic ширину SwiftUI → KVO на `fittingSize` + явное `statusItem.length = max(fittingSize.width, 24)` всё починило.
  - **Git/GitHub**: 27 файлов, +1114 / -1039. Pushed `f53b466` в `main` (force, после удаления искусственного empty baseline от `/ultrareview`-обхода). Branch `review` удалён локально+remote. Default branch на GitHub теперь содержит весь код: https://github.com/ATelbay/arabar
  - Final state: **30 production + 5 test .swift файлов** (35 total), 23/23 тестов pass, `Build complete!` чисто, `/Applications/arabar.app` 1.5M ad-hoc подписан.

- **2026-05-17** — Короткая follow-up сессия. 3 коммита прямо в `main` (явное разрешение пользователя), один self-revert.
  - **`3536bad` — ChatGPT 99% floor + explicit ⌘Q.** В `OpenAICookiesReader.window(from:fallbackHours:)` теперь `max(0, s.usedPercent - 1)`. Причина: endpoint `/backend-api/wham/usage` отдаёт `used_percent` как `Int` с минимумом 1 — любое использование (включая 7d rolling window, ловящий давние сессии) показывалось как «99% left», даже когда юзер не работал. Применено к обоим окнам (primary 5h + secondary 168h). Цена: −1% точности в нижней части шкалы, незаметно. Параллельно `keyboardShortcut("q")` → `keyboardShortcut("q", modifiers: .command)` — поведение не меняется (`.command` — дефолтный modifier у SwiftUI), но запись однозначнее (был момент лже-диагноза с моей стороны).
  - **`3dce25d` — Option-gated Quit (отменён `ce15542`).** Юзерский процесс arabar два раза подряд завершался без видимых действий (16-05 20:41, 17-05 14:43). В обоих случаях лог идентичен: `trackMouse send action on mouseUp → sendAction: → terminate:`, без крэшей и без SIGTERM. Заметил в логе **бурст из 12 sendAction за 10 секунд** перед final terminate, ложно предположил accessibility-эмулированный ввод / фантомные клики. Закатал `OptionKeyMonitor` (`ObservableObject` поверх `NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged])`), кнопку Quit спрятал за зажатый Option, рядом подсказку `⌥ to quit`.
  - **`ce15542` — корневой фикс + revert Option-gate.** Юзер нашёл реальную причину: красный крестик на окне Settings закрывал ВСЁ приложение. SwiftUI `Window` scene по дефолту вызывает `applicationShouldTerminateAfterLastWindowClosed = YES`, что для `LSUIElement` menubar-app некорректно. Это и был источник «12 sendAction за 10 секунд» — юзер кликал по табам / SecureField / тогглам в Settings, потом по X. Фикс в `AppDelegate`: переопределение `applicationShouldTerminateAfterLastWindowClosed → false`. Option-gate откатан как лечение симптома (3 строки в `AppDelegate` дешевле, чем `NSEvent`-мониторинг + условный рендер кнопки).
  - **Документация**: README выровнен с фактическим кодом — rotation 20→30s, %-семантика «осталось», цветовая шкала >30/10–30/<10, явное упоминание merge cookies + JSONL (cookies для %, JSONL для tokens/cost), `ukwn` вместо placeholder `arabar`.
  - **Build**: 30 production + 5 test файлов, без новых файлов / без правок `Package.swift` / без новых тестов. Все правки в существующих `OpenAICookiesReader.swift`, `MenuContentView.swift`, `ArabarApp.swift`. Чистая release-сборка, ad-hoc подписана, установлена в `/Applications/arabar.app`.

### Закрыто из бэклога

Прошлый "[P0] Тщательное ревью всего проекта" — выполнено полностью (см. запись выше: review pass + 9 waves of fixes + rotation refactor + NSStatusItem migration).

### Остаточный бэклог

- **M3** (низкий приоритет): после удаления `.estimated` из `PercentSource`, enum обслуживает только `.authoritative` vs `.unknown` — можно упростить до `Bool isAuthoritative?` или удалить enum.
- **L4**: включить `-strict-concurrency=complete` в `Package.swift` и разрезолвить warnings — закрепит invariants после W5 рефактора.
- **M1** из R2: переход на `[Provider: [Tier: Snapshot]]` map вместо 4 параллельных `@Published` полей — крупный архитектурный рефактор, отложен.
- Future-major work: Sparkle auto-update, WidgetKit, поддержка остальных 25+ провайдеров (CodexBar list). MVP feature-complete, регрессий нет.
