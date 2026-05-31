import SwiftUI

struct SentryPopover: View {
    @ObservedObject var sentry: SentryState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("Sandbox Sentry")
                    .font(.headline)
                Spacer()
                StatusBadge(isRunning: sentry.isRunning, enforcement: sentry.enforcementActive)
            }

            Divider()

            // Status grid
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Label("Status", systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                    Text(sentry.isRunning ? "Monitoring" : "Stopped")
                        .foregroundStyle(sentry.isRunning ? .green : .red)
                        .fontWeight(.medium)
                }
                GridRow {
                    Label("Enforcement", systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                    Text(sentry.enforcementActive ? "ACTIVE" : "Clear")
                        .foregroundStyle(sentry.enforcementActive ? .red : .green)
                        .fontWeight(.medium)
                }
                GridRow {
                    Label("Violations", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text("\(sentry.violationCount)")
                        .fontWeight(.medium)
                }
                GridRow {
                    Label("Health", systemImage: "heart.fill")
                        .foregroundStyle(.secondary)
                    HealthBar(score: sentry.healthScore)
                }
            }

            // Recent events
            if !sentry.recentEvents.isEmpty {
                Divider()
                Text("Recent Events")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(sentry.recentEvents) { event in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(event.severity == .high ? .red : .gray)
                            .frame(width: 6, height: 6)
                        Text(event.message)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
            }

            Divider()

            // Actions
            VStack(spacing: 6) {
                Button(action: { sentry.refresh() }) {
                    Label("Refresh Status", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                Button(action: openDashboard) {
                    Label("Open Dashboard", systemImage: "globe")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive, action: toggleSentry) {
                    Label(sentry.isRunning ? "Disable Sentry" : "Enable Sentry",
                          systemImage: sentry.isRunning ? "power" : "power")
                }
                .buttonStyle(.bordered)

                Divider()

                Button(action: { NSApp.terminate(nil) }) {
                    Label("Quit", systemImage: "xmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            // Footer
            Text("Updated \(sentry.lastUpdated.formatted(date: .omitted, time: .standard))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 300)
    }

    private func openDashboard() {
        if let url = URL(string: "http://localhost:5100") {
            NSWorkspace.shared.open(url)
        }
    }

    private func toggleSentry() {
        let cmd = sentry.isRunning
            ? "kill $(pgrep -f sandbox-monitor) 2>/dev/null"
            : "cd '/Users/travis/Documents/Vibe_Coding/Agentic-Sandbox-Sentry' && nohup ./sandbox-monitor.fswatch.sh > /tmp/sentry-monitor.log 2>&1 &"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", cmd]
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            sentry.refresh()
        }
    }
}

// MARK: - Subviews

struct StatusBadge: View {
    let isRunning: Bool
    let enforcement: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
    }

    private var color: Color {
        if enforcement { return .red }
        if isRunning { return .green }
        return .orange
    }

    private var label: String {
        if enforcement { return "ALERT" }
        if isRunning { return "SAFE" }
        return "OFF"
    }
}

struct HealthBar: View {
    let score: Int

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor)
                        .frame(width: geo.size.width * CGFloat(score) / 100)
                }
            }
            .frame(width: 80, height: 8)

            Text("\(score)%")
                .font(.caption)
                .fontWeight(.medium)
        }
    }

    private var barColor: Color {
        if score >= 80 { return .green }
        if score >= 50 { return .yellow }
        return .red
    }
}
