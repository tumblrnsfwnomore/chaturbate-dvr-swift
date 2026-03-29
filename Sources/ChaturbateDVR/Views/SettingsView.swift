import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var manager: ChannelManager
    @Environment(\.dismiss) var dismiss
    @State private var outputDirectory: String = ""
    @State private var showingDirectoryPicker = false
    @State private var diagnosticsTimer: Timer?
    @State private var bioBackfillMessage: String?
    @State private var isBackfillingBio = false
    @State private var bioBackfillCount = 0
    @State private var bioBackfillTotal = 0
    @State private var bioBackfillTask: Task<Void, Never>?
    @State private var webServerPortString: String = ""
    @State private var showingLoginSheet = false
    
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
                                            manager.appConfig.maxConcurrentRequests = max(1, min(30, $0))
                                            manager.saveAppConfig()
                                        }
                                    ), in: 1...30) {
                                        Text("\(manager.appConfig.maxConcurrentRequests)")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Text("Limit simultaneous API requests to avoid rate limiting")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("Recommended now: \(recommendedRequestRange)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Max Simultaneous Recordings")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Spacer()
                                    Stepper(value: Binding(
                                        get: { manager.appConfig.maxConcurrentRecordings },
                                        set: {
                                            manager.appConfig.maxConcurrentRecordings = max(0, min(50, $0))
                                            manager.saveAppConfig()
                                        }
                                    ), in: 0...50) {
                                        Text(manager.appConfig.maxConcurrentRecordings == 0 ? "Unlimited" : "\(manager.appConfig.maxConcurrentRecordings)")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Text("Cap active recordings separately from request slots. Set to 0 for unlimited.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("Recommended now: \(recommendedRecordingRange)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Break: Static Scene Threshold")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Spacer()
                                    Stepper(value: Binding(
                                        get: { manager.appConfig.breakStaticThresholdMinutes },
                                        set: {
                                            manager.appConfig.breakStaticThresholdMinutes = max(1, min(180, $0))
                                            manager.saveAppConfig()
                                        }
                                    ), in: 1...180) {
                                        Text("\(manager.appConfig.breakStaticThresholdMinutes) min")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Text("Treat stream as break/offline when frames stay essentially static this long")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Break: No Person + Low Motion")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Spacer()
                                    Stepper(value: Binding(
                                        get: { manager.appConfig.breakNoPersonNoMotionThresholdMinutes },
                                        set: {
                                            manager.appConfig.breakNoPersonNoMotionThresholdMinutes = max(1, min(60, $0))
                                            manager.saveAppConfig()
                                        }
                                    ), in: 1...60) {
                                        Text("\(manager.appConfig.breakNoPersonNoMotionThresholdMinutes) min")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Text("Require both no detected human body/face and low motion for this duration")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Break Analysis Interval")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Spacer()
                                    Stepper(value: Binding(
                                        get: { manager.appConfig.breakAnalysisIntervalSeconds },
                                        set: {
                                            manager.appConfig.breakAnalysisIntervalSeconds = max(5, min(60, $0))
                                            manager.saveAppConfig()
                                        }
                                    ), in: 5...60) {
                                        Text("\(manager.appConfig.breakAnalysisIntervalSeconds) sec")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Text("How frequently live frames are sampled for break detection")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Authentication")
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                Picker("", selection: Binding(
                                    get: { manager.appConfig.authMode },
                                    set: {
                                        manager.appConfig.authMode = $0
                                        manager.saveAppConfig()
                                    }
                                )) {
                                    ForEach(AuthMode.allCases) { mode in
                                        Text(mode.rawValue).tag(mode)
                                    }
                                }
                                .pickerStyle(.menu)

                                if manager.appConfig.authMode == .inAppWebView {
                                    if manager.appConfig.hasValidInAppSession() {
                                        Text(manager.appConfig.loggedInUsername.isEmpty
                                             ? "Logged in with in-app session"
                                             : "Logged in as @\(manager.appConfig.loggedInUsername)")
                                            .font(.caption)
                                            .foregroundColor(.green)

                                        HStack(spacing: 10) {
                                            Button("Re-Login") {
                                                showingLoginSheet = true
                                            }
                                            .buttonStyle(.bordered)

                                            Button("Sign Out", role: .destructive) {
                                                manager.signOutInAppSession()
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    } else {
                                        Text("No active in-app session")
                                            .font(.caption)
                                            .foregroundColor(.secondary)

                                        Button("Login In App") {
                                            showingLoginSheet = true
                                        }
                                        .buttonStyle(.borderedProminent)
                                    }
                                }

                                Divider()

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

                                Text("Browser settings are only used in Legacy mode.")
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
                        Text("Bio Metadata")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        HStack(spacing: 12) {
                            Button(action: refreshAllBioMetadataFromSettings) {
                                Label("Refresh All Bio Data", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isBackfillingBio)

                            if isBackfillingBio {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("\(bioBackfillCount)/\(bioBackfillTotal)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Button("Cancel") {
                                        bioBackfillTask?.cancel()
                                        bioBackfillTask = nil
                                        isBackfillingBio = false
                                        bioBackfillMessage = "Cancelled."
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }

                        Text("Bio metadata is fetched automatically for every new channel. Use this to refresh all channels on demand.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if let bioBackfillMessage {
                            Text(bioBackfillMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(16)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(10)

                    // MARK: Web Interface
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Web Interface")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(isOn: Binding(
                                get: { manager.appConfig.webServerEnabled },
                                set: { enabled in
                                    manager.appConfig.webServerEnabled = enabled
                                    manager.saveAppConfig()
                                }
                            )) {
                                Text("Enable web server")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                            .toggleStyle(.switch)

                            if manager.appConfig.webServerEnabled {
                                Divider()

                                HStack {
                                    Text("Port")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Spacer()
                                    TextField("8888", text: $webServerPortString)
                                        .frame(width: 72)
                                        .multilineTextAlignment(.trailing)
                                        .textFieldStyle(.roundedBorder)
                                        .onSubmit { applyWebServerPort() }
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Access from any device on your local network:")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("http://[your-mac-ip]:\(manager.appConfig.webServerPort)")
                                        .font(.caption)
                                        .fontDesign(.monospaced)
                                        .foregroundColor(.secondary)
                                        .textSelection(.enabled)
                                }
                            }

                            Text("Monitor channel status and pause or resume recording from any browser on your local network.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(16)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(10)
                    }

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
            webServerPortString = String(manager.appConfig.webServerPort)
            startDiagnosticsRefresh()
        }
        .onDisappear {
            diagnosticsTimer?.invalidate()
            diagnosticsTimer = nil
            bioBackfillTask?.cancel()
            bioBackfillTask = nil
        }
        .sheet(isPresented: $showingLoginSheet) {
            ChaturbateLoginSheet(manager: manager, isPresented: $showingLoginSheet)
        }
        .frame(width: 620, height: 640)
    }

    private var recommendedRequestRange: String {
        let current = max(1, manager.appConfig.maxConcurrentRequests)
        let diagnostics = manager.runtimeDiagnostics

        if diagnostics.cloudflareBlockedChannels > 0 {
            let lower = max(2, current - 3)
            let upper = max(lower + 1, min(12, current))
            return "\(lower)-\(upper) (Cloudflare pressure)"
        }

        if diagnostics.queuedRequests > 0 || diagnostics.averageQueueWaitMs > 200 {
            let lower = max(3, current)
            let upper = min(30, max(lower + 2, current + 4))
            return "\(lower)-\(upper)"
        }

        let lower = max(2, min(current, 8))
        let upper = min(20, max(lower + 2, current + 2))
        return "\(lower)-\(upper)"
    }

    private var recommendedRecordingRange: String {
        let diagnostics = manager.runtimeDiagnostics
        let requestCap = max(1, manager.appConfig.maxConcurrentRequests)
        let current = manager.appConfig.maxConcurrentRecordings

        if diagnostics.cloudflareBlockedChannels > 0 || diagnostics.degradedChannels > 0 {
            let cap = max(1, requestCap)
            return "1-\(cap)"
        }

        if diagnostics.queuedRecordings > 0 {
            let base = current == 0 ? max(2, requestCap / 2) : current
            let lower = max(2, base)
            let upper = min(50, max(lower + 2, base + 5))
            return "\(lower)-\(upper)"
        }

        let baseline = max(2, requestCap / 2)
        let upper = min(50, max(baseline + 2, requestCap + 4))
        return "\(baseline)-\(upper) (0 = unlimited if stable)"
    }

    private func startDiagnosticsRefresh() {
        refreshDiagnostics()
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            refreshDiagnostics()
        }
    }

    private func refreshDiagnostics() {
        Task { @MainActor in
            _ = await manager.getAllChannelInfo()
        }
    }

    private func refreshAllBioMetadataFromSettings() {
        bioBackfillMessage = nil
        isBackfillingBio = true
        bioBackfillCount = 0
        bioBackfillTotal = manager.channelCount

        bioBackfillTask = Task { @MainActor in
            do {
                try await manager.backfillAllChannelsBioMetadata { progress in
                    Task { @MainActor in
                        bioBackfillCount = progress.completed
                        bioBackfillMessage = "Fetching bio data from \(progress.currentChannel)..."
                    }
                }
                isBackfillingBio = false
                bioBackfillMessage = "Bio metadata refresh complete."
                bioBackfillTask = nil
            } catch is CancellationError {
                isBackfillingBio = false
                bioBackfillMessage = "Cancelled."
                bioBackfillTask = nil
            } catch {
                isBackfillingBio = false
                bioBackfillMessage = "Error: \(error.localizedDescription)"
                bioBackfillTask = nil
            }
        }
    }
    
    private func applyWebServerPort() {
        let trimmed = webServerPortString.trimmingCharacters(in: .whitespaces)
        guard let port = Int(trimmed), port >= 1024, port <= 65535 else {
            webServerPortString = String(manager.appConfig.webServerPort)
            return
        }
        manager.appConfig.webServerPort = port
        manager.saveAppConfig()
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
