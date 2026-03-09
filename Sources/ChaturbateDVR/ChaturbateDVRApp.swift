import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let minimumMainWindowSize = NSSize(width: 1200, height: 820)

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
        cleanupTemporaryPreviewFiles()
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
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
