import Core
import Foundation

struct StatusItemTitleFormatter {
    static func title(
        suspiciousCount: Int,
        runningCount: Int,
        errorMessage: String?
    ) -> String {
        let base: String
        if suspiciousCount > 0 {
            base = "Cdx !\(suspiciousCount) ~\(runningCount)"
        } else if runningCount > 0 {
            base = "Cdx ~\(runningCount)"
        } else {
            base = "Cdx"
        }

        guard let errorMessage, errorMessage.isEmpty == false else {
            return base
        }
        return "\(base)?"
    }

    static func title(snapshot: MonitorSnapshot?, errorMessage: String?) -> String {
        title(
            suspiciousCount: snapshot?.suspiciousCount ?? 0,
            runningCount: snapshot?.runningCount ?? 0,
            errorMessage: errorMessage
        )
    }
}
