import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var manager: ChannelManager
    @Environment(\.dismiss) var dismiss
    @State private var outputDirectory: String = ""
    @State private var showingDirectoryPicker = false
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Output")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Output Directory")
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                if outputDirectory.isEmpty {
                                    Text("Default: ~/Documents/ChaturbateDVR")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .italic()
                                } else {
                                    Text(outputDirectory)
                                        .font(.caption)
                                        .foregroundColor(.primary)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color(NSColor.textBackgroundColor))
                                        .cornerRadius(6)
                                }
                            }

                            HStack(spacing: 12) {
                                Button(action: chooseDirectory) {
                                    Label("Choose Directory", systemImage: "folder")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)

                                if !outputDirectory.isEmpty {
                                    Button(action: {
                                        outputDirectory = ""
                                        manager.appConfig.outputDirectory = ""
                                        manager.saveAppConfig()
                                    }) {
                                        Label("Use Default", systemImage: "arrow.counterclockwise")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        .padding(16)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(10)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Advanced")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Check Interval")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Spacer()
                                    Stepper(value: Binding(
                                        get: { manager.appConfig.interval },
                                        set: {
                                            manager.appConfig.interval = max(1, $0)
                                            manager.saveAppConfig()
                                        }
                                    ), in: 1...30) {
                                        Text("\(manager.appConfig.interval) min")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Text("How often to check if offline channels are online")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Max Concurrent Requests")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Spacer()
                                    Stepper(value: Binding(
                                        get: { manager.appConfig.maxConcurrentRequests },
                                        set: {
                                            manager.appConfig.maxConcurrentRequests = max(1, min(10, $0))
                                            manager.saveAppConfig()
                                        }
                                    ), in: 1...10) {
                                        Text("\(manager.appConfig.maxConcurrentRequests)")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Text("Limit simultaneous API requests to avoid rate limiting")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Browser for Cookies & User-Agent")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                
                                Picker("", selection: Binding(
                                    get: { manager.appConfig.selectedBrowser },
                                    set: {
                                        manager.appConfig.selectedBrowser = $0
                                        manager.saveAppConfig()
                                    }
                                )) {
                                    ForEach(SupportedBrowser.allCases, id: \.self) { browser in
                                        HStack {
                                            Text(browser.displayName)
                                            if browser != .none && !browser.isInstalled {
                                                Text("(not found)")
                                                    .foregroundColor(.secondary)
                                                    .font(.caption)
                                            }
                                        }
                                        .tag(browser)
                                    }
                                }
                                .pickerStyle(.menu)
                                
                                Text("Automatically uses cookies and user-agent from selected browser")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                if manager.appConfig.selectedBrowser != .none && !manager.appConfig.selectedBrowser.isInstalled {
                                    Text("⚠️ Selected browser not found on this system")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                        .padding(16)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(10)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Logs")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        Text("Detailed logs for troubleshooting thumbnail generation and other operations are saved to:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button(action: openLogsFolder) {
                            HStack {
                                Image(systemName: "folder.fill")
                                Text("Open Log Folder")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(16)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(10)
                    }
                }
                .padding(24)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(24)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .onAppear {
            outputDirectory = manager.appConfig.outputDirectory
        }
        .frame(width: 620, height: 540)
    }
    
    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        
        if panel.runModal() == .OK {
            if let url = panel.url {
                outputDirectory = url.path
                manager.appConfig.outputDirectory = url.path
                manager.saveAppConfig()
            }
        }
    }

    private func openLogsFolder() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let logsFolder = appSupport
            .appendingPathComponent("ChaturbateDVR")
            .appendingPathComponent("logs")
        
        // Create logs folder if it doesn't exist
        try? FileManager.default.createDirectory(at: logsFolder, withIntermediateDirectories: true)
        
        NSWorkspace.shared.open(logsFolder)
    }
}
