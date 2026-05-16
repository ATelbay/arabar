import Foundation

// MARK: - CodexUsageReader

final class CodexUsageReader {

    // MARK: - Cache types

    struct CacheState: Codable {
        var fileOffsets: [String: FileState] = [:]

        struct FileState: Codable {
            var byteOffset: UInt64
            var mtime: Date
            /// turn_id -> model string, carried across incremental reads
            var lastSessionModel: [String: String]
        }
    }

    // MARK: - Properties

    private let rootDirs: [URL]
    private let cacheFile: URL
    private var cache: CacheState
    private let lookbackDays: Int

    // MARK: - Init

    init(lookbackDays: Int = 30) {
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
        self.rootDirs = dirs

        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("arabar", isDirectory: true)
        self.cacheFile = appSupport.appendingPathComponent("codex_cache.json")

        // Load cache, or start fresh
        if let data = try? Data(contentsOf: cacheFile),
           let loaded = try? JSONDecoder().decode(CacheState.self, from: data) {
            self.cache = loaded
        } else {
            self.cache = CacheState()
        }

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Incremental read: only processes new bytes since last run.
    func fetchNewEvents() throws -> [UsageEvent] {
        let events = try scan(rebuild: false)
        try persistCache()
        return events
    }

    /// Full rebuild: ignores cached offsets, re-reads everything within lookback window.
    func rebuildAll() throws -> [UsageEvent] {
        cache.fileOffsets.removeAll()
        let events = try scan(rebuild: true)
        try persistCache()
        return events
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
                let cachedState = rebuild ? nil : cache.fileOffsets[cacheKey]

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
                    existingModelMap: cachedState?.lastSessionModel ?? [:],
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
        existingModelMap: [String: String],
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
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            // File unchanged — update mtime in cache
            let prev = cache.fileOffsets[cacheKey]
            cache.fileOffsets[cacheKey] = CacheState.FileState(
                byteOffset: startOffset,
                mtime: mtime,
                lastSessionModel: prev?.lastSessionModel ?? [:]
            )
            return []
        }

        let totalRead = startOffset + UInt64(data.count)
        var events: [UsageEvent] = []

        // Carry over cross-read turn_id → model map
        var turnModelMap: [String: String] = existingModelMap
        var sessionId: String = fallbackSessionId(from: url)
        var fallbackModel: String = "unknown"

        // Split by newline
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for lineData in lines {
            guard let record = parseRecord(Data(lineData)) else { continue }

            switch record.type {
            case "session_meta":
                if let payload = record.payloadDict,
                   let id = payload["id"] as? String {
                    sessionId = id
                }
                if let payload = record.payloadDict,
                   let modelProvider = payload["model_provider"] as? String {
                    fallbackModel = modelProvider
                }

            case "turn_context":
                if let payload = record.payloadDict,
                   let turnId = payload["turn_id"] as? String,
                   let model = payload["model"] as? String {
                    turnModelMap[turnId] = model
                }

            case "event_msg":
                guard let payload = record.payloadDict,
                      let payloadType = payload["type"] as? String,
                      payloadType == "token_count" else { continue }

                guard let info = payload["info"] as? [String: Any],
                      let lastUsage = info["last_token_usage"] as? [String: Any] else { continue }

                let inputTokens    = lastUsage["input_tokens"]           as? Int ?? 0
                let cachedTokens   = lastUsage["cached_input_tokens"]    as? Int ?? 0
                let outputTokens   = lastUsage["output_tokens"]          as? Int ?? 0
                let reasoningTokens = lastUsage["reasoning_output_tokens"] as? Int ?? 0

                let turnId = payload["turn_id"] as? String
                let model  = turnId.flatMap { turnModelMap[$0] } ?? fallbackModel

                let event = UsageEvent(
                    timestamp:           record.timestamp,
                    provider:            .codex,
                    model:               model,
                    sessionId:           sessionId,
                    messageId:           turnId,
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
            lastSessionModel: turnModelMap
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
                     ?? Date()
        } else {
            timestamp = Date()
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

        // Atomic write via temp file
        let tmpURL = cacheFile.deletingLastPathComponent()
            .appendingPathComponent("codex_cache_tmp_\(UUID().uuidString).json")
        try data.write(to: tmpURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(cacheFile, withItemAt: tmpURL)
    }

    // MARK: - Utilities

    private func fallbackSessionId(from url: URL) -> String {
        // Extract sessionId from filename: rollout-<ISO>-<sessionId>.jsonl
        let name = url.deletingPathExtension().lastPathComponent
        // Format: rollout-2024-01-15T12:34:56.789Z-<uuid>
        if let lastDash = name.lastIndex(of: "-") {
            let after = name.index(after: lastDash)
            return String(name[after...])
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
