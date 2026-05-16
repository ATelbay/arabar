import Foundation

// MARK: - Raw JSONL structures

private struct ClaudeRecord: Decodable {
    let type: String
    let timestamp: Date
    let sessionId: String?
    let message: ClaudeMessage?
    let isSidechain: Bool?
}

private struct ClaudeMessage: Decodable {
    let id: String?
    let model: String?
    let usage: ClaudeUsage?
}

private struct ClaudeUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
    }
}

// MARK: - Cache state

private struct CacheState: Codable {
    var fileStates: [String: FileState] = [:]

    struct FileState: Codable {
        var byteOffset: UInt64
        var mtime: Date
        var seenMessageIds: Set<String>
    }
}

// MARK: - ClaudeUsageReader

final class ClaudeUsageReader {

    // MARK: - Private state

    private let rootDirs: [URL]
    private let cacheFile: URL
    private let lookbackDays: Int
    private var cache: CacheState

    // Decoder with millis-aware ISO8601
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            // Try with fractional seconds first, then without
            let withMillis = ISO8601DateFormatter()
            withMillis.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withMillis.date(from: str) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot parse date: \(str)"
            )
        }
        return d
    }()

    // MARK: - Init

    init(lookbackDays: Int = 30) {
        self.lookbackDays = lookbackDays

        // Candidate root dirs
        var dirs: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        dirs.append(home.appendingPathComponent(".claude/projects"))
        if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            dirs.append(URL(fileURLWithPath: configDir).appendingPathComponent("projects"))
        }
        dirs.append(home.appendingPathComponent(".config/claude/projects"))
        self.rootDirs = dirs

        // Cache file
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let arabarDir = appSupport.appendingPathComponent("arabar")
        self.cacheFile = arabarDir.appendingPathComponent("claude_cache.json")

        // Load existing cache
        self.cache = CacheState()
        if let data = try? Data(contentsOf: cacheFile),
           let loaded = try? JSONDecoder().decode(CacheState.self, from: data) {
            self.cache = loaded
        }
    }

    // MARK: - Public API

    /// Incremental scan — reads only new bytes since last offset.
    func fetchNewEvents() throws -> [UsageEvent] {
        var events: [UsageEvent] = []
        let files = discoverJSONLFiles()
        for fileURL in files {
            events.append(contentsOf: processFile(fileURL, resetCache: false))
        }
        saveCache()
        return events
    }

    /// Full rebuild — ignores offset cache.
    func rebuildAll() throws -> [UsageEvent] {
        cache = CacheState()
        var events: [UsageEvent] = []
        let files = discoverJSONLFiles()
        for fileURL in files {
            events.append(contentsOf: processFile(fileURL, resetCache: true))
        }
        saveCache()
        return events
    }

    // MARK: - File discovery

    private func discoverJSONLFiles() -> [URL] {
        let cutoff = Date().addingTimeInterval(-Double(lookbackDays) * 86400)
        var results: [URL] = []
        let fm = FileManager.default

        for root in rootDirs {
            guard fm.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "jsonl" else { continue }
                guard let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      attrs.isRegularFile == true else { continue }
                let mtime = attrs.contentModificationDate ?? .distantPast
                // Skip files older than lookback window
                if mtime < cutoff { continue }
                results.append(fileURL)
            }
        }
        return results
    }

    // MARK: - Per-file processing

    private func processFile(_ fileURL: URL, resetCache: Bool) -> [UsageEvent] {
        let fm = FileManager.default
        let key = fileURL.path

        // Get current mtime
        let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
        let currentMtime = (attrs?[.modificationDate] as? Date) ?? Date.distantPast

        var fileState = cache.fileStates[key] ?? CacheState.FileState(
            byteOffset: 0,
            mtime: currentMtime,
            seenMessageIds: []
        )

        // If file was rewritten (mtime went backwards) or forced reset → restart from 0
        if resetCache || currentMtime < fileState.mtime {
            fileState = CacheState.FileState(byteOffset: 0, mtime: currentMtime, seenMessageIds: [])
        }

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            print("[ClaudeUsageReader] Cannot open \(fileURL.lastPathComponent)")
            return []
        }
        defer { try? handle.close() }

        // Seek to last known offset
        do {
            try handle.seek(toOffset: fileState.byteOffset)
        } catch {
            print("[ClaudeUsageReader] Seek failed for \(fileURL.lastPathComponent): \(error)")
            return []
        }

        // Read remaining bytes
        let newData = handle.readDataToEndOfFile()
        guard !newData.isEmpty else {
            // Update mtime even if no new data
            fileState.mtime = currentMtime
            cache.fileStates[key] = fileState
            return []
        }

        // Update offset
        fileState.byteOffset += UInt64(newData.count)
        fileState.mtime = currentMtime

        // Infer sessionId from path
        let sessionId = inferSessionId(from: fileURL)

        // Parse new lines
        let cutoff = Date().addingTimeInterval(-Double(lookbackDays) * 86400)
        var events: [UsageEvent] = []

        // Split on newlines, handle trailing newline gracefully
        // Keep track of incomplete last line → save as unprocessed (not done here: offset already advanced)
        let lines = splitLines(newData)

        for line in lines {
            guard !line.isEmpty else { continue }
            guard let record = parseRecord(line) else { continue }
            guard record.type == "assistant" else { continue }
            guard record.timestamp >= cutoff else { continue }

            guard let msg = record.message,
                  let msgId = msg.id,
                  !msgId.isEmpty else { continue }

            // Deduplicate within file
            if fileState.seenMessageIds.contains(msgId) { continue }
            fileState.seenMessageIds.insert(msgId)

            let usage = msg.usage
            let event = UsageEvent(
                timestamp: record.timestamp,
                provider: .claude,
                model: msg.model ?? "unknown",
                sessionId: record.sessionId ?? sessionId,
                messageId: msgId,
                inputTokens: usage?.inputTokens ?? 0,
                outputTokens: usage?.outputTokens ?? 0,
                cacheReadTokens: usage?.cacheReadInputTokens ?? 0,
                cacheCreationTokens: usage?.cacheCreationInputTokens ?? 0,
                cachedTokens: 0,
                reasoningTokens: 0
            )
            events.append(event)
        }

        cache.fileStates[key] = fileState
        return events
    }

    // MARK: - Helpers

    private func parseRecord(_ lineData: Data) -> ClaudeRecord? {
        do {
            return try Self.decoder.decode(ClaudeRecord.self, from: lineData)
        } catch {
            if let str = String(data: lineData, encoding: .utf8) {
                print("[ClaudeUsageReader] Parse error: \(error.localizedDescription) — line: \(str.prefix(120))")
            }
            return nil
        }
    }

    private func splitLines(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var start = data.startIndex
        while let range = data.range(of: Data([0x0A]), in: start..<data.endIndex) {
            let line = data[start..<range.lowerBound]
            lines.append(line)
            start = range.upperBound
        }
        // Trailing bytes without newline — still try to parse
        if start < data.endIndex {
            lines.append(data[start...])
        }
        return lines
    }

    /// Extract sessionId from path like:
    ///   ~/.claude/projects/<encoded>/<sessionId>.jsonl
    ///   ~/.claude/projects/<encoded>/<sessionId>/subagents/agent-<id>.jsonl
    private func inferSessionId(from url: URL) -> String {
        let components = url.pathComponents
        // Look for "subagents" marker
        if let idx = components.firstIndex(of: "subagents"), idx >= 1 {
            return components[idx - 1]
        }
        // Otherwise filename without extension
        return url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Cache persistence

    private func saveCache() {
        let fm = FileManager.default
        let dir = cacheFile.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheFile, options: .atomic)
    }
}
