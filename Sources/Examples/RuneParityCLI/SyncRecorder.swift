import Foundation

/// Reads upstream git `HEAD` metadata and writes `.upstream-sync.json`.
public enum SyncRecorder {
    public static func recordSync(
        upstreamRoot: URL,
        syncURL: URL,
        swiftTargets: Int? = nil,
        swiftExecutables: Int? = nil,
        now: Date = Date()
    ) throws -> UpstreamSyncState {
        guard FileManager.default.fileExists(atPath: upstreamRoot.path) else {
            throw ParityError.fileNotFound(upstreamRoot.path)
        }

        let sha = try ProcessRunner.runChecked(
            executable: "/usr/bin/git",
            arguments: ["-C", upstreamRoot.path, "rev-parse", "HEAD"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let date = try ProcessRunner.runChecked(
            executable: "/usr/bin/git",
            arguments: ["-C", upstreamRoot.path, "show", "-s", "--format=%cI", "HEAD"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let subject = try ProcessRunner.runChecked(
            executable: "/usr/bin/git",
            arguments: ["-C", upstreamRoot.path, "show", "-s", "--format=%s", "HEAD"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let existing = try? ParityMapper.loadSyncState(at: syncURL)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let syncedAt = formatter.string(from: now)

        let state = UpstreamSyncState(
            upstreamRepo: existing?.upstreamRepo ?? "https://github.com/anomalyco/rune",
            syncedCommit: sha,
            syncedCommitDate: date,
            syncedCommitSubject: subject,
            syncedAt: syncedAt,
            swiftTargets: swiftTargets ?? existing?.swiftTargets ?? 17,
            swiftExecutables: swiftExecutables ?? existing?.swiftExecutables ?? 33
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(state)
        data.append(0x0A) // trailing newline

        let parent = syncURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: syncURL, options: .atomic)

        return state
    }
}
