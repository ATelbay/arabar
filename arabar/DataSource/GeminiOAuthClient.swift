import Foundation

/// Resolves the public installed-app OAuth configuration from the user's Gemini CLI.
/// Client identifiers are not embedded in arabar or fetched from an unrelated service.
struct GeminiOAuthClient {
    let id: String
    let secret: String

    static func load(credentials: [String: Any], candidateFiles: [URL]? = nil) throws -> Self {
        if let id = credentials["client_id"] as? String, !id.isEmpty,
           let secret = credentials["client_secret"] as? String, !secret.isEmpty {
            return Self(id: id, secret: secret)
        }
        for file in candidateFiles ?? installedSources() {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size < 20_000_000,
                  let source = try? String(contentsOf: file, encoding: .utf8),
                  let client = parse(source: source) else { continue }
            return client
        }
        throw AccountQuotaError.missingGeminiClient
    }

    static func parse(source: String) -> Self? {
        func constant(_ name: String) -> String? {
            let pattern = "\\b" + name + "(?:_?[0-9]+)?\\s*=\\s*[\"']([^\"'\\r\\n]+)[\"']"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                  let range = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[range])
        }
        guard let id = constant("OAUTH_CLIENT_ID"), let secret = constant("OAUTH_CLIENT_SECRET") else { return nil }
        return Self(id: id, secret: secret)
    }

    private static func installedSources() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = [
            "/opt/homebrew/lib/node_modules/@google/gemini-cli",
            "/usr/local/lib/node_modules/@google/gemini-cli",
            "/opt/homebrew/opt/gemini-cli/libexec/lib/node_modules/@google/gemini-cli",
            "/usr/local/opt/gemini-cli/libexec/lib/node_modules/@google/gemini-cli",
            home.appendingPathComponent(".npm-global/lib/node_modules/@google/gemini-cli").path
        ].map { URL(fileURLWithPath: $0) }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let binDirs = path.split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path]
        var files: [URL] = []
        for dir in binDirs {
            let executable = URL(fileURLWithPath: dir).appendingPathComponent("gemini").resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: executable.path) else { continue }
            files.append(executable)
            var parent = executable.deletingLastPathComponent()
            for _ in 0..<6 {
                roots.append(parent)
                parent.deleteLastPathComponent()
                if parent.path == "/" { break }
            }
        }
        for root in roots {
            for relative in [
                "node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
                "../gemini-cli-core/dist/src/code_assist/oauth2.js",
                "dist/src/code_assist/oauth2.js",
                "dist/gemini.js",
                "bundle/gemini.js"
            ] {
                files.append(root.appendingPathComponent(relative).standardizedFileURL)
            }
        }
        var seen: Set<String> = []
        return files.filter { seen.insert($0.path).inserted }
    }
}
