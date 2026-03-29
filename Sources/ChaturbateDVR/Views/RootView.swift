import SwiftUI
import AppKit

struct RootView: View {
    @StateObject private var manager = ChannelManager()
    @State private var showingLoginSheet = false

    private var shouldShowOnboarding: Bool {
        !manager.appConfig.hasCompletedOnboarding
    }

    var body: some View {
        Group {
            if shouldShowOnboarding {
                onboardingView
            } else {
                ContentView(manager: manager)
            }
        }
        .sheet(isPresented: $showingLoginSheet) {
            ChaturbateLoginSheet(manager: manager, isPresented: $showingLoginSheet)
        }
    }

    private var onboardingView: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "video.badge.plus")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(.red)

                VStack(spacing: 8) {
                    Text("Chaturbate DVR")
                        .font(.largeTitle.bold())
                    Text("Sign in once, then manage channels and open pages inside the app.")
                        .font(.title3)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 14) {
                    Button {
                        showingLoginSheet = true
                    } label: {
                        Text("Sign in with In-App Browser")
                            .frame(minWidth: 260)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return)

                    outputDirectoryRow

                    Button("Use Legacy Browser Cookie Mode") {
                        manager.appConfig.authMode = .browserCookies
                        if manager.appConfig.selectedBrowser == .none {
                            manager.appConfig.selectedBrowser = .chrome
                        }
                        manager.completeOnboardingWithoutLogin()
                    }
                    .buttonStyle(.bordered)
                }

                if !manager.appConfig.loggedInUsername.isEmpty {
                    Text("Last account: @\(manager.appConfig.loggedInUsername)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("Credentials stay local to this Mac.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 20)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
        }
    }

    private var outputDirectoryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundColor(.secondary)
            Text(displayOutputPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Change") {
                chooseOutputDirectory()
            }
            .buttonStyle(.borderless)
        }
    }

    private var displayOutputPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return manager.appConfig.getOutputPath().replacingOccurrences(of: home, with: "~")
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.directoryURL = URL(fileURLWithPath: manager.appConfig.getOutputPath())

        if panel.runModal() == .OK, let url = panel.url {
            manager.appConfig.outputDirectory = url.path
            manager.saveAppConfig()
        }
    }
}
