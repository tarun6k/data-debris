import AppKit
import DebrisCore
import Foundation

/// What "Report a problem" puts in the email, and nothing more. Assembled
/// from values the user can already see; shown in full before sending.
///
/// Never included: file hashes, Trash locations, the license key, the
/// machine id, any email address (unless the user types one into the
/// description), and no file contents of any kind.
struct ProblemReport: Equatable {
    enum Kind: String, Identifiable {
        case problem, betaFeedback
        var id: String { rawValue }

        var title: String { self == .problem ? "Report a problem" : "Beta feedback" }
        var subject: String {
            self == .problem ? "Data Debris problem report" : "Data Debris beta feedback"
        }
        var prompt: String {
            self == .problem ? "What happened, and what did you expect?" : "What would you change?"
        }
    }

    struct JournalEntry: Equatable {
        let path: String
        let bytes: Int64
        let status: String
    }

    struct LastRun: Equatable {
        let mode: String
        let startedAt: Date
        let status: String
        let movedBytes: Int64
        let entries: [JournalEntry]
        let omitted: Int
    }

    static let journalLimit = 200

    var kind: Kind
    var macOSVersion: String
    var appVersion: String
    var planState: String
    var fdaStatus: String
    var lastRun: LastRun?
    /// The user's own words; the only free text in the report.
    var description = ""
    var generatedAt = Date()

    // MARK: - Gathering

    static func gather(kind: Kind, history: HistoryStore, entitlement: EntitlementState,
                       fdaGranted: Bool, macOSVersion: String = AppInfo.macOSVersion,
                       appVersion: String = AppInfo.versionString) -> ProblemReport {
        ProblemReport(
            kind: kind,
            macOSVersion: macOSVersion,
            appVersion: appVersion,
            planState: planDescription(entitlement),
            fdaStatus: fdaGranted ? "Granted" : "Not granted",
            lastRun: lastRun(from: history))
    }

    /// Plan without identifiers: no key, no machine names, no email.
    static func planDescription(_ state: EntitlementState) -> String {
        switch state {
        case .free: return "Free"
        case .active(let plan, let expiresAt, let autoRenew, let machines):
            return "Active, \(plan == .oneYear ? "1 Year" : "3 Years"), "
                + "expires \(Self.day(expiresAt)), auto-renew \(autoRenew ? "on" : "off"), "
                + "\(machines.count) of 2 Macs"
        case .expiring(let daysLeft): return "Active, expires in \(daysLeft) days"
        case .lapsed(let since): return "Lapsed since \(Self.day(since))"
        case .offlineGrace(let until): return "Active offline, grace until \(Self.day(until))"
        case .pastDue: return "Past due"
        }
    }

    /// Paths and sizes only; hashes and Trash locations stay out.
    static func lastRun(from history: HistoryStore) -> LastRun? {
        guard let run = (try? history.runs())?.first else { return nil }
        let items = (try? history.items(runId: run.id)) ?? []
        let entries = items.prefix(journalLimit).map { item in
            JournalEntry(path: item.originalPath,
                         bytes: item.allocatedSize,
                         status: Self.status(of: item))
        }
        return LastRun(mode: run.mode.rawValue,
                       startedAt: run.startedAt,
                       status: run.status.rawValue,
                       movedBytes: run.movedBytes,
                       entries: Array(entries),
                       omitted: max(0, items.count - journalLimit))
    }

    private static func status(of item: ItemRecord) -> String {
        switch item.skipReason {
        case .inUse(let process): return "skipped (in use by \(process))"
        case .moveFailed: return "skipped (move failed)"
        case .some(let reason): return "skipped (\(reason))"
        case .none: return item.status.rawValue
        }
    }

    private static func day(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: - Rendering

    /// The exact text that goes out, for the preview and the attachment.
    func text() -> String {
        var lines: [String] = []
        lines.append(kind.subject)
        lines.append("Generated \(generatedAt.formatted(date: .abbreviated, time: .shortened))")
        lines.append("")
        lines.append("App: \(appVersion)")
        lines.append("macOS: \(macOSVersion)")
        lines.append("Plan: \(planState)")
        lines.append("Full Disk Access: \(fdaStatus)")
        lines.append("")
        if let run = lastRun {
            lines.append("Last run: \(run.mode), \(run.startedAt.formatted(date: .abbreviated, time: .shortened)), "
                         + "\(run.status), moved \(Format.bytes(run.movedBytes))")
            for entry in run.entries {
                lines.append("  \(entry.path)  ·  \(Format.bytes(entry.bytes))  ·  \(entry.status)")
            }
            if run.omitted > 0 { lines.append("  … and \(run.omitted) more") }
        } else {
            lines.append("Last run: none yet")
        }
        lines.append("")
        lines.append(kind == .problem ? "What happened:" : "Feedback:")
        lines.append(description.isEmpty ? "(not filled in)" : description)
        return lines.joined(separator: "\n")
    }
}

/// Opens a compose window with the report attached. The user presses Send
/// in their mail app; nothing leaves this Mac on its own.
enum ReportMailer {
    enum Outcome: Equatable { case composeWindow, mailto, failed(String) }

    @discardableResult
    static func compose(to recipient: String, subject: String, body: String) -> Outcome {
        let attachment = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataDebris-report-\(Int(Date().timeIntervalSince1970)).txt")
        do { try body.write(to: attachment, atomically: true, encoding: .utf8) } catch {
            return .failed(error.localizedDescription)
        }
        if let service = NSSharingService(named: .composeEmail) {
            service.recipients = [recipient]
            service.subject = subject
            let items: [Any] = [body, attachment]
            if service.canPerform(withItems: items) {
                service.perform(withItems: items)
                return .composeWindow
            }
        }
        // No mail account configured for Mail.app: fall back to the default
        // mail handler with the report inline (no attachment possible).
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        components.queryItems = [URLQueryItem(name: "subject", value: subject),
                                 URLQueryItem(name: "body", value: body)]
        if let url = components.url, NSWorkspace.shared.open(url) { return .mailto }
        return .failed("No mail app is set up on this Mac. The report is saved at \(attachment.path).")
    }
}
