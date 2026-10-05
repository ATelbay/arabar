import Foundation

// MARK: - CodexUsageReader

// Single-owner serial access from AppViewModel — safe to treat as Sendable
final class CodexUsageReader: @unchecked Sendable {

    // MARK: - Cache types

    struct CacheState: Codable {
        var fileOffsets: [String: FileState] = [:]

        struct FileState: Codable {
            var byteOffset: UInt64
            var mtime: Date
            /// turn_id -> model string, carried across incremental reads
            var lastSessionModel: [String: String]
            var sessionId: String?
            var currentModel: String?
            var lastTotalUsage: [String: Int]?
        }
    }

    // MARK: - Properties

    private let rootDirs: [URL]
    private let cacheFile: URL
    private var cache: CacheState
    private let lookbackDays: Int

    // MARK: - Init

    init(lookbackDays: Int = 30, rootDirs: [URL]? = nil, cacheFile: URL? = nil) {
        self.lookbackDays = lookbackDays

        let codexHome = CodexAuth.codexHome()
        var dirs: [URL] = [
            codexHome.appendingPathComponent("sessions"),
            codexHome.appendingPathComponent("archived_sessions")
        ]
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            let envSessions = URL(fileURLWithPath: env).appendingPathComponent("sessions")
            if !dirs.contains(envSessions) { dirs.append(envSessions) }
        }
        self.rootDirs = rootDirs ?? dirs

        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("arabar", isDirectory: true)
        self.cacheFile = cacheFile ?? appSupport.appendingPathComponent("codex_cache.json")

        // Load cache, or start fresh
        if let data = try? Data(contentsOf: self.cacheFile),
           let loaded = try? JSONDecoder().decode(CacheState.self, from: data) {
            self.cache = loaded
        } else {
            self.cache = CacheState()
        }
    }

    // MARK: - Public API

    /// Incremental read: only processes new bytes since last run.
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

    /// Full rebuild: ignores cached offsets, re-reads everything within lookback window.
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

    // MARK: - Core scan

    private func scan(rebuild: Bool) throws -> [UsageEvent] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date())!
        var events: [UsageEvent] = []

        for root in rootDirs {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let files = enumerateJSONLFiles(under: root)
            for fileURL in files {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                guard mtime >= cutoff else { continue }

                let cacheKey = fileURL.path
                var cachedState = rebuild ? nil : cache.fileOffsets[cacheKey]
                if let state = cachedState,
                   state.byteOffset > (attrs[.size] as? UInt64 ?? 0) || mtime < state.mtime {
                    cachedState = nil
                }

                // Skip if mtime unchanged and offset covers full file
                if let cs = cachedState,
                   cs.mtime == mtime,
                   let size = attrs[.size] as? UInt64,
                   cs.byteOffset >= size {
                    continue
                }

                let fileEvents = parseFile(
                    at: fileURL,
                    startOffset: cachedState?.byteOffset ?? 0,
                    existingState: cachedState,
                    mtime: mtime,
                    cacheKey: cacheKey
                )
                events.append(contentsOf: fileEvents)
            }
        }
        return events
    }

    // MARK: - File parsing

    private func parseFile(
        at url: URL,
        startOffset: UInt64,
        existingState: CacheState.FileState?,
        mtime: Date,
        cacheKey: String
    ) -> [UsageEvent] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        // Seek to last known position
        if startOffset > 0 {
            guard (try? handle.seek(toOffset: startOffset)) != nil else { return [] }
        }

        // Read remaining bytes
        guard let data = try? handle.readToEnd(), !data.isEmpty,
              let finalNewline = data.lastIndex(of: 0x0A) else { return [] }
        let completeData = data.prefix(through: finalNewline)
        let totalRead = startOffset + UInt64(completeData.count)
        var events: [UsageEvent] = []
        var turnModelMap = existingState?.lastSessionModel ?? [:]
        var sessionId = existingState?.sessionId ?? fallbackSessionId(from: url)
        var fallbackModel = existingState?.currentModel ?? "unknown"
        var lastTotalUsage = existingState?.lastTotalUsage
        var lineOffset = startOffset
        let lines = completeData.split(separator: 0x0A, omittingEmptySubsequences: false)
        for lineData in lines {
            let recordOffset = lineOffset
            lineOffset += UInt64(lineData.count + 1)
            guard let record = parseRecord(Data(lineData)) else { continue }

            switch record.type {
            case "session_meta":
                if let payload = record.payloadDict,
                   let id = payload["id"] as? String {
                    sessionId = id
                }
                if let payload = record.payloadDict,
                   let model = payload["model"] as? String {
                    fallbackModel = model
                }

            case "turn_context":
                if let payload = record.payloadDict,
                   let model = payload["model"] as? String {
                    fallbackModel = model
                    if let turnId = payload["turn_id"] as? String {
                        turnModelMap[turnId] = model
                    }
                }

            case "event_msg":
                guard let payload = record.payloadDict,
                      let payloadType = payload["type"] as? String,
                      payloadType == "token_count" else { continue }

                guard record.timestamp != .distantPast else { continue }
                guard let info = payload["info"] as? [String: Any],
                      let lastUsage = info["last_token_usage"] as? [String: Any] else { continue }

                // token_count can repeat the same cumulative usage when only rate
                // limits change. Carry this fingerprint across incremental reads.
                let totalUsage = info["total_token_usage"] as? [String: Int]
                if let totalUsage, totalUsage == lastTotalUsage { continue }
                lastTotalUsage = totalUsage

                let totalInput = max(0, lastUsage["input_tokens"] as? Int ?? 0)
                let totalOutput = max(0, lastUsage["output_tokens"] as? Int ?? 0)
                let cachedTokens = min(totalInput, max(0, lastUsage["cached_input_tokens"] as? Int ?? 0))
                let reasoningTokens = min(totalOutput, max(0, lastUsage["reasoning_output_tokens"] as? Int ?? 0))
                // UsageEvent categories are exclusive, unlike the Codex wire format.
                let inputTokens = totalInput - cachedTokens
                let outputTokens = totalOutput - reasoningTokens

                let turnId = payload["turn_id"] as? String
                let model  = turnId.flatMap { turnModelMap[$0] } ?? fallbackModel

                let event = UsageEvent(
                    timestamp:           record.timestamp,
                    provider:            .codex,
                    model:               model,
                    sessionId:           sessionId,
                    messageId:           "codex:\(sessionId):\(recordOffset)",
                    inputTokens:         inputTokens,
                    outputTokens:        outputTokens,
                    cacheReadTokens:     0,
                    cacheCreationTokens: 0,
                    cachedTokens:        cachedTokens,
                    reasoningTokens:     reasoningTokens
                )
                events.append(event)

            default:
                break
            }
        }

        // Persist updated state
        cache.fileOffsets[cacheKey] = CacheState.FileState(
            byteOffset: totalRead,
            mtime: mtime,
            lastSessionModel: turnModelMap,
            sessionId: sessionId,
            currentModel: fallbackModel,
            lastTotalUsage: lastTotalUsage
        )
        return events
    }

    // MARK: - JSONL record helpers

    private struct RawRecord {
        let type: String
        let timestamp: Date
        let payloadDict: [String: Any]?
    }

    private func parseRecord(_ data: Data) -> RawRecord? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else { return nil }

        let timestamp: Date
        if let tsStr = obj["timestamp"] as? String {
            timestamp = Self.isoFormatter.date(from: tsStr)
                     ?? Self.isoFallbackFormatter.date(from: tsStr)
                     ?? .distantPast
        } else {
            timestamp = .distantPast
        }

        let payload = obj["payload"] as? [String: Any]
        return RawRecord(type: type, timestamp: timestamp, payloadDict: payload)
    }

    // MARK: - File enumeration

    private func enumerateJSONLFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .nameKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-") else { continue }
            results.append(url)
        }
        return results
    }

    // MARK: - Cache persistence (atomic write)

    private func persistCache() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(cache)

        try FileManager.default.createDirectory(
            at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Data.atomic also creates a cache on the first run.
        try data.write(to: cacheFile, options: .atomic)
    }

    // MARK: - Utilities

    private func fallbackSessionId(from url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        if name.count >= 36 {
            let candidate = String(name.suffix(36))
            if UUID(uuidString: candidate) != nil { return candidate }
        }
        return name
    }

    // MARK: - Date formatters (static to avoid repeated allocation)

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFallbackFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
