import Foundation

// Pricing data sourced from:
// - Anthropic: https://platform.claude.com/docs/en/about-claude/pricing (verified May 2026)
// - OpenAI: https://developers.openai.com/api/docs/pricing (verified May 2026)
// All prices in USD per 1,000,000 tokens (MTok).
//
// Re-verified May 2026: all current Anthropic prices match official docs.
// OpenAI: only gpt-5.4-* and gpt-5.5-* families are on current pricing page.
// Older models (gpt-5, o3, o4) retained as fallback for sessions logged with retired models.

enum Pricing {

    struct ModelPrice {
        /// Standard input tokens per MTok
        let inputPerMTok: Double
        /// Cache read (hit) per MTok — 0.1x of input for Anthropic, varies for OpenAI
        let cachedInputPerMTok: Double
        /// 5-minute cache write per MTok (Anthropic only; 1.25x input)
        let cacheWrite5mPerMTok: Double?
        /// 1-hour cache write per MTok (Anthropic only; 2x input)
        let cacheWrite1hPerMTok: Double?
        /// Output tokens per MTok
        let outputPerMTok: Double
    }

    // MARK: - Anthropic Claude Models
    // Source: platform.claude.com/docs/en/about-claude/pricing, confirmed May 2026.
    // Cache multipliers: write-5m = 1.25x input, write-1h = 2x input, cache read = 0.1x input.
    static let claudeModels: [String: ModelPrice] = [

        // Claude Opus 4.7 — current flagship (new tokenizer: up to 35% more tokens vs older models)
        "claude-opus-4-7": .init(
            inputPerMTok:        5.00,
            cachedInputPerMTok:  0.50,
            cacheWrite5mPerMTok: 6.25,
            cacheWrite1hPerMTok: 10.00,
            outputPerMTok:       25.00
        ),

        // Claude Opus 4.6 — same price tier as 4.7
        "claude-opus-4-6": .init(
            inputPerMTok:        5.00,
            cachedInputPerMTok:  0.50,
            cacheWrite5mPerMTok: 6.25,
            cacheWrite1hPerMTok: 10.00,
            outputPerMTok:       25.00
        ),

        // Claude Opus 4.5
        "claude-opus-4-5": .init(
            inputPerMTok:        5.00,
            cachedInputPerMTok:  0.50,
            cacheWrite5mPerMTok: 6.25,
            cacheWrite1hPerMTok: 10.00,
            outputPerMTok:       25.00
        ),

        // Claude Opus 4.1 — older tier (3x price of 4.5+)
        "claude-opus-4-1": .init(
            inputPerMTok:        15.00,
            cachedInputPerMTok:  1.50,
            cacheWrite5mPerMTok: 18.75,
            cacheWrite1hPerMTok: 30.00,
            outputPerMTok:       75.00
        ),

        // Claude Opus 4 — deprecated, same tier as 4.1
        "claude-opus-4": .init(
            inputPerMTok:        15.00,
            cachedInputPerMTok:  1.50,
            cacheWrite5mPerMTok: 18.75,
            cacheWrite1hPerMTok: 30.00,
            outputPerMTok:       75.00
        ),

        // Claude Sonnet 4.6 — main workhorse for Claude Code
        "claude-sonnet-4-6": .init(
            inputPerMTok:        3.00,
            cachedInputPerMTok:  0.30,
            cacheWrite5mPerMTok: 3.75,
            cacheWrite1hPerMTok: 6.00,
            outputPerMTok:       15.00
        ),

        // Claude Sonnet 4.5
        "claude-sonnet-4-5": .init(
            inputPerMTok:        3.00,
            cachedInputPerMTok:  0.30,
            cacheWrite5mPerMTok: 3.75,
            cacheWrite1hPerMTok: 6.00,
            outputPerMTok:       15.00
        ),

        // Claude Sonnet 4 — deprecated, same tier as 4.5/4.6
        "claude-sonnet-4": .init(
            inputPerMTok:        3.00,
            cachedInputPerMTok:  0.30,
            cacheWrite5mPerMTok: 3.75,
            cacheWrite1hPerMTok: 6.00,
            outputPerMTok:       15.00
        ),

        // Claude Haiku 4.5 — cheapest current-gen model
        "claude-haiku-4-5": .init(
            inputPerMTok:        1.00,
            cachedInputPerMTok:  0.10,
            cacheWrite5mPerMTok: 1.25,
            cacheWrite1hPerMTok: 2.00,
            outputPerMTok:       5.00
        ),

        // Claude Haiku 3.5 — retired except Bedrock/Vertex AI
        "claude-haiku-3-5": .init(
            inputPerMTok:        0.80,
            cachedInputPerMTok:  0.08,
            cacheWrite5mPerMTok: 1.00,
            cacheWrite1hPerMTok: 1.60,
            outputPerMTok:       4.00
        ),
    ]

    // MARK: - OpenAI Models
    // Source (current): developers.openai.com/api/docs/pricing (verified May 2026)
    // OpenAI does not have 5m/1h cache-write tiers — only a single "cached input" discount.
    // cacheWrite5mPerMTok and cacheWrite1hPerMTok are nil for all OpenAI models.
    // Pro tier (gpt-5.4-pro, gpt-5.5-pro) has no cached-input price (kept at 0.00).
    // Older models below (gpt-5, o3, o4) are NOT on current pricing page — kept as fallback
    // for parsing historical session logs that reference retired models.
    static let openaiModels: [String: ModelPrice] = [

        // GPT-5 family — retired, retained as fallback for legacy session logs
        "gpt-5": .init(
            inputPerMTok:        1.25,
            cachedInputPerMTok:  0.125,
            cacheWrite5mPerMTok: nil,
            cacheWrite1hPerMTok: nil,
            outputPerMTok:       10.00
        ),

        "gpt-5-mini": .init(
            inputPerMTok:        0.25,
            cachedInputPerMTok:  0.025,
            cacheWrite5mPerMTok: nil,
            cacheWrite1hPerMTok: nil,
            outputPerMTok:       2.00
        ),

        "gpt-5-nano": .init(
            inputPerMTok:        0.05,
            cachedInputPerMTok:  0.005,
            cacheWrite5mPerMTok: nil,
            cacheWrite1hPerMTok: nil,
            outputPerMTok:       0.40
        ),

        // GPT-5 Pro — retired, retained as fallback
        "gpt-5-pro": .init(
            inputPerMTok:        15.00,
            cachedInputPerMTok:  0.00,   // historical: cache pricing not listed
            cacheWrite5mPerMTok: nil,
            cacheWrite1hPerMTok: nil,
            outputPerMTok:       120.00
        ),

        // GPT-5.4 series — current (May 2026), heavily used by Codex CLI
        "gpt-5-4": .init(
            inputPerMTok:        2.50,
            cachedInputPerMTok:  0.25,
            cacheWrite5mPerMTok: nil,
            cacheWrite1hPerMTok: nil,
            outputPerMTok:       15.00
        ),

        "gpt-5-4-mini": .init(
            inputPerMTok:        0.75,
            cachedInputPerMTok:  0.075,
            cacheWrite5mPerMTok: nil,
            cacheWrite1hPerMTok: nil,
            outputPerMTok:       4.50
        ),

        "gpt-5-4-nano": .init(
            inputPerMTok:        0.20,
            cachedInputPerMTok:  0.02,
            cacheWrite5mPerMTok: nil,
            cacheWrite1hPerMTok: nil,
            outputPerMTok:       1.25
        ),

        // GPT-5.4 Pro
        "gpt-5-4-pro": .init(
            inputPerMTok:        30.00,
            cachedInputPerMTok:  0.00,   // Pro tier: no cached-input price listed
            cacheWrite5mPerMTok: nil,
            cacheWrite1hPerMTok: nil,
            outputPerMTok:       180.00
        ),

        // GPT-5.5 — current flagship (verified from official pricing page)
        "gpt-5-5": .init(
            inputPerMTok:        5.00,
            cachedInputPerMTok:  0.50,
            cacheWrite5mPerMTok: nil,
            cacheWrite1hPerMTok: nil,
            outputPerMTok:       30.00
        ),

        // GPT-5.5 Pro
        "gpt-5-5-pro": .init(
            inputPerMTok:        30.00,
            cachedInputPerMTok:  0.00,   // Pro tier: no cached-input price listed
            cacheWrite5mPerMTok: nil,
            cacheWrite1hPerMTok: nil,
            outputPerMTok:       180.00
        ),

        // o3 reasoning model — retired, retained as fallback
        "o3": .init(
            inputPerMTok:        2.00,
            cachedInputPerMTok:  0.50,
            cacheWrite5mPerMTok: nil,
            cacheWrite1hPerMTok: nil,
            outputPerMTok:       8.00
        ),

        "o3-mini": .init(
            inputPerMTok:        1.10,
            cachedInputPerMTok:  0.55,
            cacheWrite5mPerMTok: nil,
            cacheWrite1hPerMTok: nil,
            outputPerMTok:       4.40
        ),

        "o3-pro": .init(
            inputPerMTok:        20.00,
            cachedInputPerMTok:  0.00,   // historical: cache pricing not listed
            cacheWrite5mPerMTok: nil,
            cacheWrite1hPerMTok: nil,
            outputPerMTok:       80.00
        ),

        // o4 mini (available in Codex CLI alongside o3)
        "o4-mini": .init(
            inputPerMTok:        1.10,
            cachedInputPerMTok:  0.275,
            cacheWrite5mPerMTok: nil,
            cacheWrite1hPerMTok: nil,
            outputPerMTok:       4.40
        ),

        // GPT-5.3-Codex — current Codex CLI cloud task model
        // (verified on developers.openai.com/api/docs/pricing May 2026; input price confirmed,
        //  output price from pricepertoken.com — official page does not show output rate for codex models)
        "gpt-5-3-codex": .init(
            inputPerMTok:        1.75,
            cachedInputPerMTok:  0.175,
            cacheWrite5mPerMTok: nil,
            cacheWrite1hPerMTok: nil,
            outputPerMTok:       14.00
        ),
    ]
}
