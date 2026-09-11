#if os(macOS)
import Foundation
import LibreReverseCore

/// Failures are durable records of previous attempts, not proof that the
/// currently connected account or every new upload is failing.
enum LibreReverseArchiveFailurePresentation {
    static func text(summaries: [LibreReverseArchiveFailureSummary], totalFailed: Int64) -> String {
        guard totalFailed > 0 else { return "" }
        var lines = ["These files failed on an earlier backup attempt:"]
        for summary in summaries {
            let kind = summary.isHistoryIndex ? "history index" : "recording"
            let noun = summary.count == 1 ? "file" : "files"
            let reason = summary.reason.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let displayed = reason.count > 240 ? String(reason.prefix(240)) + "…" : reason
            lines.append("• \(summary.count) \(kind) \(noun): \(displayed)")
        }
        let represented = summaries.reduce(Int64(0)) { $0 + $1.count }
        if represented < totalFailed {
            lines.append("\(totalFailed - represented) other failed files; more details appear as these are retried.")
        }
        let authorizationFailure = summaries.contains {
            let reason = $0.reason.lowercased()
            return ["invalid_grant", "expired or revoked", "unauthorized", "invalid credentials"]
                .contains(where: reason.contains)
        }
        lines.append(authorizationFailure
            ? "New backups may already be working. Click Retry Backup to retry these files. If authorization fails again, reconnect the account under Cloud storage provider."
            : "Click Retry Backup to retry these files. If the same error returns, use the saved reason above to check the provider connection, available storage, or source file.")
        return lines.joined(separator: "\n")
    }
}
#endif
