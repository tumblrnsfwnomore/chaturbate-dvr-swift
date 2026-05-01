import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let minimumMainWindowSize = NSSize(width: 1200, height: 820)
    var gracefulShutdownHandler: (() async -> Void)?
    var terminationBlockReasonProvider: (() -> String?)?
    private var hasStartedTermination = false
    private var terminationProgressWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        cleanupTemporaryPreviewFiles()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first {
            window.minSize = minimumMainWindowSize
            window.makeKeyAndOrderFront(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dismissTerminationProgressWindow()
        cleanupTemporaryPreviewFiles()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !hasStartedTermination else {
            return .terminateLater
        }

        let pendingReason = terminationBlockReasonProvider?()

        guard let gracefulShutdownHandler else {
            return .terminateNow
        }

        hasStartedTermination = true

        if let pendingReason {
            showTerminationProgressWindow(reason: pendingReason)
        }

        Task { @MainActor in
            await gracefulShutdownHandler()
            dismissTerminationProgressWindow()
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    private func showTerminationProgressWindow(reason: String) {
        if let existing = terminationProgressWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let panelSize = NSSize(width: 470, height: 150)
        let panel = NSWindow(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Quitting ChaturbateDVR"
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.center()

        let container = NSView(frame: NSRect(origin: .zero, size: panelSize))
        container.translatesAutoresizingMaskIntoConstraints = false

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)

        let titleLabel = NSTextField(labelWithString: "Finishing pending work before quit...")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let detailLabel = NSTextField(wrappingLabelWithString: reason)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 3
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(spinner)
        container.addSubview(titleLabel)
        container.addSubview(detailLabel)
        panel.contentView = container

        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            spinner.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 34),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor)
        ])

        terminationProgressWindow = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dismissTerminationProgressWindow() {
        terminationProgressWindow?.close()
        terminationProgressWindow = nil
    }

    private func cleanupTemporaryPreviewFiles() {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let appTempDir = tempRoot.appendingPathComponent("ChaturbateDVR")
        let recordingPreviewsDir = appTempDir.appendingPathComponent("recording_previews")

        // Remove rolling recording preview files used for thumbnail extraction.
        try? fileManager.removeItem(at: recordingPreviewsDir)

        // Best-effort cleanup for paused preview temp files if any were left behind.
        if let tempEntries = try? fileManager.contentsOfDirectory(
            at: tempRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for entry in tempEntries where entry.lastPathComponent.hasSuffix("_paused_preview.ts") {
                try? fileManager.removeItem(at: entry)
            }
        }

        // Remove app temp directory only when it is empty.
        if let remaining = try? fileManager.contentsOfDirectory(atPath: appTempDir.path),
           remaining.isEmpty {
            try? fileManager.removeItem(at: appTempDir)
        }
    }
}

@main
struct ChaturbateDVRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var manager = ChannelManager()
    
    var body: some Scene {
        WindowGroup {
            RootView(manager: manager, appDelegate: appDelegate)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
