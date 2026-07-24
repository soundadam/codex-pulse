import Core
import Foundation

struct StatusItemTitleFormatter {
    static func title(
        suspiciousCount: Int,
        runningCount: Int,
        errorMessage: String?
    ) -> String {
        if let errorMessage, errorMessage.isEmpty == false {
            return "Sync issue"
        }

        var parts: [String] = []
        if suspiciousCount > 0 {
            let noun = suspiciousCount == 1 ? "issue" : "issues"
            parts.append("\(suspiciousCount) \(noun)")
        }
        if runningCount > 0 {
            parts.append("\(runningCount) running")
        }
        return parts.isEmpty ? "Idle" : parts.joined(separator: " · ")
    }

    static func title(snapshot: MonitorSnapshot?, errorMessage: String?) -> String {
        title(
            suspiciousCount: snapshot?.suspiciousCount ?? 0,
            runningCount: snapshot?.runningCount ?? 0,
            errorMessage: errorMessage
        )
    }

    static func accessibilityLabel(for title: String) -> String {
        "CodexIQ — \(title)"
    }

}
