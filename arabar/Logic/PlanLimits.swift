import Foundation

// Plan limits sourced from (May 2026):
// - Anthropic Claude Code limits: support.claude.com/en/articles/11145838,
//   faros.ai/blog/claude-code-token-limits, 9to5google.com/2026/05/06/claude-code-is-getting-higher-usage-limits
// - OpenAI Codex limits: blog.laozhang.ai/en/posts/openai-codex-usage-limits,
//   community.openai.com/t/understanding-the-new-codex-limit-system-after-the-april-9-update
// - ChatGPT plan limits: customgpt.ai/chatgpt-plus-limits-2026/, northflank.com/blog/chatgpt-usage-limits-free-plus-enterprise

enum PlanLimits {

    // MARK: - Claude Plan Tiers
    enum ClaudePlan {
        case free
        case pro         // $20/month — Claude.ai + Claude Code
        case max5x       // $100/month — 5x usage vs Pro
        case max20x      // $200/month — 20x usage vs Pro
    }

    // MARK: - ChatGPT Plan Tiers
    enum ChatGPTPlan {
        case free
        case plus        // $20/month
        case pro         // $100/month (restructured from $200 in April 2026)
        case proPlus     // $200/month (previously "Pro", now top tier)
        case team        // $25-30/user/month (Business plan)
    }

    // MARK: - Window Structure
    struct Window {
        /// Rolling window duration in hours (5 = Claude's standard; 3 = some ChatGPT limits; 168 = weekly)
        let durationHours: Int
        /// Token cap for this window (nil = undisclosed or "unlimited with fair-use guardrails")
        let maxTokens: Int?
        /// Message cap for this window (nil = not applicable or token-based)
        let maxMessages: Int?
        /// Model IDs this window applies to. Empty = applies to all plan models.
        let appliesTo: [String]
        /// Human-readable note
        let note: String
    }

    // MARK: - Claude Code Limits
    // Key facts (May 2026):
    // • Pro baseline ~44k tokens / 5h window (pre-doubling estimate, Anthropic doesn't publish exact numbers).
    // • On May 6 2026, Anthropic doubled the 5h rate limits for Pro, Max, Team, Enterprise.
    //   Post-doubling estimates: Pro ~88k, Max5x ~176k, Max20x ~440k per 5h.
    // • Since Aug 2025: two additional weekly caps overlay the 5h windows —
    //   (a) all-models weekly cap, (b) Sonnet-only weekly cap. Exact numbers not published.
    // • Usage is shared between Claude.ai and Claude Code on the same plan.
    // • Peak-hour throttling removed for Pro and Max as of May 2026.
    static func claudeLimits(for plan: ClaudePlan) -> [Window] {
        switch plan {

        case .free:
            return [
                Window(
                    durationHours: 5,
                    maxTokens: nil,        // TODO: уточнить, Anthropic не публикует точных цифр для Free
                    maxMessages: 10,       // approximate; varies with message size
                    appliesTo: ["claude-haiku-4-5"],
                    note: "Free tier; limited to lighter models; exact token cap not disclosed"
                ),
            ]

        case .pro:
            return [
                // 5-hour rolling window (post-May-6-2026 doubling)
                Window(
                    durationHours: 5,
                    maxTokens: 88_000,     // ~44k pre-doubling × 2; community estimates, NOT official
                    maxMessages: nil,
                    appliesTo: ["claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5"],
                    note: "Approximate post-doubling estimate (May 2026). Anthropic does not publish exact token caps."
                ),
                // Weekly all-models cap
                Window(
                    durationHours: 168,
                    maxTokens: nil,        // TODO: уточнить, Anthropic не публикует точную недельную квоту
                    maxMessages: nil,
                    appliesTo: [],         // all models
                    note: "Weekly all-models cap exists since Aug 2025; exact limit not disclosed"
                ),
                // Weekly Sonnet-only cap
                Window(
                    durationHours: 168,
                    maxTokens: nil,        // TODO: уточнить
                    maxMessages: nil,
                    appliesTo: ["claude-sonnet-4-6", "claude-sonnet-4-5"],
                    note: "Separate weekly Sonnet-specific cap; exact limit not disclosed"
                ),
            ]

        case .max5x:
            return [
                // 5-hour rolling window (post-May-6-2026 doubling; 5x Pro pre-doubling = 10x effective)
                Window(
                    durationHours: 5,
                    maxTokens: 440_000,    // 5× Pro pre-doubling (44k×5=220k), then ×2 for doubling = 440k
                    // TODO: уточнить — некоторые источники трактуют умножители иначе
                    maxMessages: nil,
                    appliesTo: ["claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5"],
                    note: "Community estimate: 5× Pro baseline, then ×2 for May 2026 doubling. Not officially confirmed."
                ),
                Window(
                    durationHours: 168,
                    maxTokens: nil,        // TODO: уточнить
                    maxMessages: nil,
                    appliesTo: [],
                    note: "Weekly all-models cap; exact limit not disclosed"
                ),
                Window(
                    durationHours: 168,
                    maxTokens: nil,        // TODO: уточнить
                    maxMessages: nil,
                    appliesTo: ["claude-sonnet-4-6", "claude-sonnet-4-5"],
                    note: "Weekly Sonnet-specific cap; exact limit not disclosed"
                ),
            ]

        case .max20x:
            return [
                // 5-hour rolling window (20x Pro pre-doubling, then ×2)
                Window(
                    durationHours: 5,
                    maxTokens: 1_760_000,  // 20× Pro pre-doubling (44k×20=880k), then ×2 = 1.76M
                    // TODO: уточнить — множители могут не суммироваться так линейно
                    maxMessages: nil,
                    appliesTo: ["claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5"],
                    note: "Community estimate: 20× Pro baseline, then ×2 for May 2026 doubling. Not officially confirmed."
                ),
                Window(
                    durationHours: 168,
                    maxTokens: nil,        // TODO: уточнить
                    maxMessages: nil,
                    appliesTo: [],
                    note: "Weekly all-models cap; exact limit not disclosed"
                ),
                Window(
                    durationHours: 168,
                    maxTokens: nil,        // TODO: уточнить
                    maxMessages: nil,
                    appliesTo: ["claude-sonnet-4-6", "claude-sonnet-4-5"],
                    note: "Weekly Sonnet-specific cap; exact limit not disclosed"
                ),
            ]
        }
    }

    // MARK: - ChatGPT / Codex Limits
    // Key facts (May 2026):
    // • ChatGPT operates on 3-hour rolling windows for standard model messages.
    // • Thinking (o-series / extended reasoning) has a separate weekly cap.
    // • Codex CLI switched to token-based limits (per rolling 5h window) on Apr 2, 2026.
    // • Codex CLI models used: gpt-5-4, gpt-5-4-mini, gpt-5-3-codex (cloud tasks).
    // • Promotional Codex boosts run through May 31, 2026 (Pro 20x → 25x vs Plus).
    static func chatgptLimits(for plan: ChatGPTPlan) -> [Window] {
        switch plan {

        case .free:
            return [
                Window(
                    durationHours: 5,
                    maxTokens: nil,
                    maxMessages: 10,       // ~10 GPT-5 messages / 5h; then downgrade to mini
                    appliesTo: ["gpt-5"],
                    note: "Free: ~10 GPT-5 messages per 5h, then falls back to GPT-4o mini"
                ),
            ]

        case .plus:
            return [
                // Standard GPT-5.5 / GPT-5 chat messages (3h rolling window)
                Window(
                    durationHours: 3,
                    maxTokens: nil,
                    maxMessages: 160,      // "up to 160 GPT-5.5 / GPT-5 messages per 3h" — chatgpt.com confirmed
                    appliesTo: ["gpt-5-5", "gpt-5", "gpt-5-4"],
                    note: "160 standard messages per 3h rolling window; excess falls back to mini model"
                ),
                // Thinking / reasoning (manual selection) — weekly cap
                Window(
                    durationHours: 168,
                    maxTokens: nil,
                    maxMessages: 3_000,    // "3,000 Thinking messages per week" — confirmed
                    appliesTo: ["o3", "o3-mini", "o4-mini"],
                    note: "Manual Thinking / reasoning model weekly cap"
                ),
                // Codex CLI — 5h rolling, token-based (Plus baseline)
                Window(
                    durationHours: 5,
                    maxTokens: nil,        // TODO: уточнить — диапазон зависит от модели и сложности задачи
                    maxMessages: nil,
                    appliesTo: ["gpt-5-4", "gpt-5-4-mini", "gpt-5-3-codex"],
                    note: "Codex CLI Plus: 20-100 local GPT-5.4 msgs or 10-60 cloud tasks per 5h (soft ranges, token-based)"
                ),
            ]

        case .pro:
            // Pro ($100/month, restructured Apr 2026) — 5x Plus usage
            return [
                Window(
                    durationHours: 3,
                    maxTokens: nil,
                    maxMessages: nil,      // TODO: уточнить, "5× Plus quota" для GPT-5.5 Thinking; точных чисел нет
                    appliesTo: ["gpt-5-5", "gpt-5", "gpt-5-4"],
                    note: "Pro ($100/mo): 5× Plus GPT-5.5 Thinking quota; effectively unlimited with anti-abuse guardrails"
                ),
                // Codex CLI — 5h rolling, 5x Plus (promotional 25x through May 31 2026)
                Window(
                    durationHours: 5,
                    maxTokens: nil,
                    maxMessages: nil,      // ranges: GPT-5.4 100-500, GPT-5.4-mini 300-1750, gpt-5-3-codex 150-750
                    appliesTo: ["gpt-5-4", "gpt-5-4-mini", "gpt-5-3-codex"],
                    note: "Codex CLI Pro 5x: GPT-5.4 100-500 msgs per 5h; promotional 25× vs Plus through May 31 2026"
                ),
            ]

        case .proPlus:
            // Pro+ / old Pro ($200/month) — ~20x Plus usage; access to GPT-5.5 Pro
            return [
                Window(
                    durationHours: 3,
                    maxTokens: nil,
                    maxMessages: nil,      // "unlimited with anti-abuse guardrails"
                    appliesTo: ["gpt-5-5", "gpt-5-5-pro", "gpt-5", "gpt-5-4", "o3-pro"],
                    note: "Pro+ ($200/mo): unlimited access incl. GPT-5.5 Pro; anti-abuse guardrails apply"
                ),
                // Codex CLI — 5h rolling, ~20x Plus
                Window(
                    durationHours: 5,
                    maxTokens: nil,
                    maxMessages: nil,      // ranges: GPT-5.4 400-2000, GPT-5.4-mini 1200-7000, gpt-5-3-codex 600-3000
                    appliesTo: ["gpt-5-4", "gpt-5-4-mini", "gpt-5-3-codex"],
                    note: "Codex CLI Pro 20x: GPT-5.4 400-2000 msgs per 5h; exact token cap not published"
                ),
            ]

        case .team:
            // Team / Business plan — virtually unlimited GPT-5 messages, token-based
            return [
                Window(
                    durationHours: 3,
                    maxTokens: nil,        // "virtually unlimited with fair-use"
                    maxMessages: nil,
                    appliesTo: ["gpt-5-5", "gpt-5", "gpt-5-4"],
                    note: "Business/Team: virtually unlimited GPT-5 messages subject to fair-use"
                ),
                // Weekly Thinking cap (same as Plus)
                Window(
                    durationHours: 168,
                    maxTokens: nil,
                    maxMessages: 3_000,    // "3,000 Thinking messages per week" — same as Plus according to sources
                    appliesTo: ["o3", "o3-mini", "o4-mini"],
                    note: "Weekly reasoning/Thinking cap; same 3k/week as Plus (TODO: уточнить для Team)"
                ),
                // Codex CLI — matches Plus included usage + flexible workspace credits
                Window(
                    durationHours: 5,
                    maxTokens: nil,        // TODO: уточнить — Business matches Plus baseline but adds credit top-ups
                    maxMessages: nil,
                    appliesTo: ["gpt-5-4", "gpt-5-4-mini", "gpt-5-3-codex"],
                    note: "Codex CLI Business: Plus-equivalent baseline + flexible credits; exact cap not published"
                ),
            ]
        }
    }
}
