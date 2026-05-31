import SwiftUI

@main
struct SentryMenuBarApp: App {
    @StateObject private var sentry = SentryState()

    var body: some Scene {
        MenuBarExtra {
            SentryPopover(sentry: sentry)
        } label: {
            // Dynamic icon: shield with color based on status
            Image(systemName: sentry.enforcementActive
                  ? "shield.lefthalf.filled"
                  : "shield.checkered")
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    sentry.enforcementActive ? .red : .green,
                    sentry.enforcementActive ? .red.opacity(0.6) : .green.opacity(0.6)
                )
        }
        .menuBarExtraStyle(.window)
    }
}
