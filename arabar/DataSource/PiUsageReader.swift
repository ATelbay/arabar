import Foundation

/// Reads token and cost usage recorded by the Pi coding agent.
///
/// Pi stores one JSON object per line under `~/.pi/agent/sessions`. Each persisted
/// assistant response contains incremental usage for that API call, so every entry
/// can be represented as a `UsageEvent` without deriving deltas.
final class PiUsageReader: @unchecked Sendable {
    struct CacheState: Codable {
        var fileOffsets: [String: FileState] = [:]

        struct FileState: Codable {
            var byteOffset: UInt64
            var mtime: Date
            var sessionId: String
            var lastProvider: String?
            var lastModel: String?
        }
    }

    private let targetProvider: Provider
    private let rootDirs: [URL]
    private let cacheFile: URL
    private let lookbackDays: Int
    private var cache: CacheState

    init(
        targetProvider: Provider,
        rootDirs: [URL]? = nil,
        cacheFile: URL? = nil,
        lookbackDays: Int = 30
    ) {
        self.targetProvider = targetProvider
        self.lookbackDays = lookbackDays
        self.rootDirs = rootDirs ?? Self.defaultSessionRoots()

        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("arabar", isDirectory: true)
        self.cacheFile = cacheFile ?? appSupport.appendingPathComponent(
            "pi_\(targetProvider.rawValue)_cache.json"
        )

        if let data = try? Data(contentsOf: self.cacheFile),
           let loaded = try? JSONDecoder().decode(CacheState.self, from: data) {
            self.cache = loaded
        } else {
            self.cache = CacheState()
        }
    }

    func fetchNewEvents() throws -> [UsageEvent] {
        let previous = cache
        do {
            let events = try scan(rebuild: false)
            try persistCache()
            return events
        } catch {
            cache = previous
            throw error
        }
    }

    func rebuildAll() throws -> [UsageEvent] {
        let previous = cache
        do {
            cache.fileOffsets.removeAll()
            let events = try scan(rebuild: true)
            try persistCache()
            return events
        } catch {
            cache = previous
            throw error
        }
    }

    private static func defaultSessionRoots() -> [URL] {
        let environment = ProcessInfo.processInfo.environment
        if let customSessionDir = environment["PI_CODING_AGENT_SESSION_DIR"],
           !customSessionDir.isEmpty {
            return [URL(fileURLWithPath: customSessionDir, isDirectory: true)]
        }

        let configDir: URL
        if let customConfigDir = environment["PI_CODING_AGENT_DIR"],
           !customConfigDir.isEmpty {
            configDir = URL(fileURLWithPath: customConfigDir, isDirectory: true)
        } else {
            configDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".pi/agent", isDirectory: true)
        }
        return [configDir.appendingPathComponent("sessions", isDirectory: true)]
    }

    private func scan(rebuild: Bool) throws -> [UsageEvent] {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -lookbackDays,
            to: Date()
        )!
        var events: [UsageEvent] = []

        for root in rootDirs where FileManager.default.fileExists(atPath: root.path) {
            for fileURL in enumerateJSONLFiles(under: root) {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                      let mtime = attributes[.modificationDate] as? Date,
                      mtime >= cutoff,
                      let fileSize = attributes[.size] as? UInt64 else {
                    continue
                }

                let cacheKey = fileURL.path
                var cachedState = rebuild ? nil : cache.fileOffsets[cacheKey]
                if let state = cachedState, state.byteOffset > fileSize || mtime < state.mtime {
                    // The session was replaced or truncated; parse it from the beginning.
                    cachedState = nil
                }
                if let state = cachedState,
                   state.mtime == mtime,
                   state.byteOffset >= fileSize {
                    continue
                }

                events.append(contentsOf: parseFile(
                    at: fileURL,
                    startOffset: cachedState?.byteOffset ?? 0,
                    existingState: cachedState,
                    mtime: mtime,
                    cacheKey: cacheKey
                ))
            }
        }
        return events
    }

    private func parseFile(
        at url: URL,
        startOffset: UInt64,
        existingState: CacheState.FileState?,
        mtime: Date,
        cacheKey: String
    ) -> [UsageEvent] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        if startOffset > 0,
           (try? handle.seek(toOffset: startOffset)) == nil {
            return []
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            updateCache(
                cacheKey: cacheKey,
                byteOffset: startOffset,
                mtime: mtime,
                sessionId: existingState?.sessionId ?? fallbackSessionId(from: url),
                provider: existingState?.lastProvider,
                model: existingState?.lastModel
            )
            return []
        }

        // Do not consume a partially-written final JSON line. It will be retried on
        // the next refresh after Pi appends the terminating newline.
        guard let finalNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            return []
        }
        let completeData = data.prefix(through: finalNewline)
        let consumedOffset = startOffset + UInt64(completeData.count)

        var sessionId = existingState?.sessionId ?? fallbackSessionId(from: url)
        var currentProvider = existingState?.lastProvider
        var currentModel = existingState?.lastModel
        var events: [UsageEvent] = []

        for line in completeData.split(
            separator: UInt8(ascii: "\n"),
            omittingEmptySubsequences: true
        ) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = object["type"] as? String else {
                continue
            }

            if type == "session", let id = object["id"] as? String {
                sessionId = id
                continue
            }

            if type == "model_change" {
                currentProvider = object["provider"] as? String ?? currentProvider
                currentModel = object["modelId"] as? String ?? currentModel
                continue
            }

            let entryId = object["id"] as? String ?? UUID().uuidString
            let timestamp = timestamp(from: object, fallback: mtime)

            if type == "message",
               let message = object["message"] as? [String: Any] {
                currentProvider = message["provider"] as? String ?? currentProvider
                currentModel = message["model"] as? String ?? currentModel
                if let usage = message["usage"] as? [String: Any],
                   let event = makeEvent(
                       usage: usage,
                       rawProvider: message["provider"] as? String ?? currentProvider,
                       model: message["model"] as? String ?? currentModel,
                       timestamp: timestamp,
                       sessionId: sessionId,
                       entryId: entryId
                   ) {
                    events.append(event)
                }
                continue
            }

            // Compaction and branch-summary generation can also invoke an LLM and
            // persist usage at the entry's top level.
            if let usage = object["usage"] as? [String: Any],
               let event = makeEvent(
                   usage: usage,
                   rawProvider: object["provider"] as? String ?? currentProvider,
                   model: object["model"] as? String ?? currentModel,
                   timestamp: timestamp,
                   sessionId: sessionId,
                   entryId: entryId
               ) {
                events.append(event)
            }
        }

        updateCache(
            cacheKey: cacheKey,
            byteOffset: consumedOffset,
            mtime: mtime,
            sessionId: sessionId,
            provider: currentProvider,
            model: currentModel
        )
        return events
    }

    private func makeEvent(
        usage: [String: Any],
        rawProvider: String?,
        model: String?,
        timestamp: Date,
        sessionId: String,
        entryId: String
    ) -> UsageEvent? {
        guard provider(from: rawProvider, model: model) == targetProvider else {
            return nil
        }

        let cost = usage["cost"] as? [String: Any]
        return UsageEvent(
            timestamp: timestamp,
            provider: targetProvider,
            model: model ?? "unknown",
            sessionId: sessionId,
            messageId: "pi:\(sessionId):\(entryId)",
            inputTokens: integer(usage["input"]),
            outputTokens: integer(usage["output"]),
            cacheReadTokens: targetProvider == .claude ? integer(usage["cacheRead"]) : 0,
            cacheCreationTokens: integer(usage["cacheWrite"]),
            cachedTokens: targetProvider == .codex ? integer(usage["cacheRead"]) : 0,
            // Pi's `reasoning` is a subset of `output`, not an additional token
            // category. Leaving this at zero keeps the sum equal to `totalTokens`.
            reasoningTokens: 0,
            recordedCostUSD: number(cost?["total"])
        )
    }

    private func provider(from rawProvider: String?, model: String?) -> Provider? {
        let raw = rawProvider?.lowercased() ?? ""
        let modelName = model?.lowercased() ?? ""
        if raw.contains("anthropic") || modelName.hasPrefix("claude-") {
            return .claude
        }
        if raw.contains("openai")
            || raw.contains("codex")
            || modelName.hasPrefix("gpt-")
            || modelName.hasPrefix("o3")
            || modelName.hasPrefix("o4") {
            return .codex
        }
        return nil
    }

    private func timestamp(from object: [String: Any], fallback: Date) -> Date {
        if let value = object["timestamp"] as? String,
           let date = Self.isoFormatter.date(from: value)
                ?? Self.isoFallbackFormatter.date(from: value) {
            return date
        }
        if let message = object["message"] as? [String: Any],
           let milliseconds = number(message["timestamp"]) {
            return Date(timeIntervalSince1970: milliseconds / 1_000)
        }
        return fallback
    }

    private func integer(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private func updateCache(
        cacheKey: String,
        byteOffset: UInt64,
        mtime: Date,
        sessionId: String,
        provider: String?,
        model: String?
    ) {
        cache.fileOffsets[cacheKey] = CacheState.FileState(
            byteOffset: byteOffset,
            mtime: mtime,
            sessionId: sessionId,
            lastProvider: provider,
            lastModel: model
        )
    }

    private func enumerateJSONLFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            files.append(url)
        }
        return files
    }

    private func persistCache() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try FileManager.default.createDirectory(
            at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try encoder.encode(cache).write(to: cacheFile, options: .atomic)
    }

    private func fallbackSessionId(from url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFallbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
