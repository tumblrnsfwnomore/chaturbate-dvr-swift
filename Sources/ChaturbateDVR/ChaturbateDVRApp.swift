import SwiftUI
import AppKit

struct TerminationProgressStatus: Sendable {
    let blockingCount: Int
    let reason: String
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let minimumMainWindowSize = NSSize(width: 1200, height: 820)
    private let terminationGracePeriodSeconds: UInt64 = 20
    var gracefulShutdownHandler: (() async -> Void)?
    var terminationStatusProvider: (() async -> TerminationProgressStatus)?
    private var hasStartedTermination = false
    private var hasCompletedTermination = false
    private var terminationProgressWindow: NSWindow?
    private var terminationProgressPollingTask: Task<Void, Never>?
    private var terminationTimeoutTask: Task<Void, Never>?
    private var terminationDetailLabel: NSTextField?

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
        terminationProgressPollingTask?.cancel()
        terminationProgressPollingTask = nil
        terminationTimeoutTask?.cancel()
        terminationTimeoutTask = nil
        dismissTerminationProgressWindow()
        cleanupTemporaryPreviewFiles()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await FileLogger.shared.log("[app] applicationShouldTerminate requested")
        }

        guard !hasStartedTermination else {
            return .terminateLater
        }

        guard let gracefulShutdownHandler else {
            return .terminateNow
        }

        hasStartedTermination = true
        hasCompletedTermination = false
        showTerminationProgressWindow(reason: "Stopping channels and background workers...")
        startTerminationProgressPolling()
        startTerminationTimeout()

        Task { @MainActor in
            await gracefulShutdownHandler()
            guard !hasCompletedTermination else { return }
            hasCompletedTermination = true
            terminationProgressPollingTask?.cancel()
            terminationProgressPollingTask = nil
            terminationTimeoutTask?.cancel()
            terminationTimeoutTask = nil
            dismissTerminationProgressWindow()
            await FileLogger.shared.log("[app] applicationShouldTerminate completed")
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    private func startTerminationTimeout() {
        terminationTimeoutTask?.cancel()
        terminationTimeoutTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(nanoseconds: terminationGracePeriodSeconds * 1_000_000_000)
            } catch {
                return
            }

            await MainActor.run {
                guard self.hasStartedTermination, !self.hasCompletedTermination else { return }

                self.hasCompletedTermination = true
                self.terminationProgressPollingTask?.cancel()
                self.terminationProgressPollingTask = nil
                self.terminationTimeoutTask = nil
                self.dismissTerminationProgressWindow()
                Task {
                    await FileLogger.shared.log("[app] termination grace period expired; allowing quit to continue", level: "WARN")
                }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
    }

    private func startTerminationProgressPolling() {
        guard let terminationStatusProvider else { return }

        terminationProgressPollingTask?.cancel()
        terminationProgressPollingTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                let status = await terminationStatusProvider()

                await MainActor.run {
                    guard self.hasStartedTermination else { return }
                    let fallbackReason = "Still shutting down background tasks..."
                    let visibleReason = status.blockingCount > 0 ? status.reason : fallbackReason
                    self.showTerminationProgressWindow(reason: visibleReason)
                }

                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    private func terminationProgressMessage(blockingCount: Int) -> String {
        if blockingCount == 1 {
            return "1 video finalization task is blocking quit."
        }
        return "\(blockingCount) video finalization tasks are blocking quit."
    }

    private func showTerminationProgressWindow(reason: String) {
        if let existing = terminationProgressWindow {
            terminationDetailLabel?.stringValue = reason
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
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .moveToActiveSpace]
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
        terminationDetailLabel = detailLabel

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
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dismissTerminationProgressWindow() {
        terminationProgressWindow?.close()
        terminationProgressWindow = nil
        terminationDetailLabel = nil
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
