import SwiftUI
import Combine

/// Observable state for the Sentry menu bar app.
/// Polls sentryctl / sentry-status.sh for live data.
@MainActor
final class SentryState: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var enforcementActive: Bool = false
    @Published var violationCount: Int = 0
    @Published var healthScore: Int = 100
    @Published var recentEvents: [SentryEvent] = []
    @Published var lastUpdated: Date = .now

    private var timer: Timer?

    init() {
        refresh()
        // Poll every 3 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refresh() {
        // Try to read from sentry-status.sh output
        let statusOutput = runShell("cd '\(projectRoot)' && ./sentry-status.sh 2>/dev/null || echo 'UNAVAILABLE'")

        if statusOutput.contains("UNAVAILABLE") || statusOutput.isEmpty {
            // Fallback: check if enforcement lock file exists
            let enforcementCheck = runShell("test -f /tmp/agentsentry-enforcement.lock && echo ACTIVE || echo CLEAR")
            enforcementActive = enforcementCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "ACTIVE"
            isRunning = runShell("pgrep -f sandbox-monitor >/dev/null && echo YES || echo NO")
                .trimmingCharacters(in: .whitespacesAndNewlines) == "YES"
        } else {
            parseStatusOutput(statusOutput)
        }

        // Read recent violations from log
        let logOutput = runShell("tail -5 /tmp/agentsentry.log 2>/dev/null || echo ''")
        parseEvents(logOutput)

        lastUpdated = .now
    }

    private func parseStatusOutput(_ output: String) {
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            let lower = line.lowercased()
            if lower.contains("enforcement") && lower.contains("active") {
                enforcementActive = true
            }
            if lower.contains("running") || lower.contains("monitor") {
                isRunning = true
            }
            if let scoreRange = line.range(of: #"health[:\s]+(\d+)"#, options: .regularExpression) {
                let match = line[scoreRange]
                if let num = match.compactMap({ $0.isNumber ? String($0) : nil }).joined().first {
                    healthScore = Int(String(num)) ?? 100
                }
            }
        }
    }

    private func parseEvents(_ log: String) {
        let lines = log.components(separatedBy: .newlines).filter { !$0.isEmpty }
        recentEvents = lines.prefix(5).map { line in
            SentryEvent(
                timestamp: Date(),
                message: String(line.prefix(80)),
                severity: line.lowercased().contains("block") ? .high : .info
            )
        }
        violationCount = recentEvents.filter { $0.severity == .high }.count
    }

    private var projectRoot: String {
        // Resolve relative to the binary location, or fall back to known path
        let known = "/Users/travis/Documents/Vibe_Coding/Agentic-Sandbox-Sentry"
        return FileManager.default.fileExists(atPath: known) ? known : "."
    }

    private func runShell(_ command: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

struct SentryEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let severity: Severity

    enum Severity {
        case info, warning, high
    }
}
