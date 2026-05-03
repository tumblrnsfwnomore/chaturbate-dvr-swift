import SwiftUI
import AppKit
import AVKit
import AVFoundation

private enum DetailTab: String {
    case allChannels
    case channel
    case recordings
    case recording
}

enum ChannelStatusFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case online = "Online"
    case recording = "Recording"
    case paused = "Paused"
    case limitReached = "Limit Reached"
    case offline = "Offline"
    case invalid = "Invalid"

    var id: String { rawValue }
}

private func formatNoPersonDuration(_ seconds: Int) -> String {
    let clamped = max(0, seconds)
    let hours = clamped / 3600
    let minutes = (clamped % 3600) / 60
    let remainingSeconds = clamped % 60

    if hours > 0 {
        return String(format: "%dh %02dm", hours, minutes)
    }
    return String(format: "%d:%02d", minutes, remainingSeconds)
}

private enum RecordingDurationAuditStatus {
    case insufficientData
    case ok
    case mismatch
}

private func recordingDurationAuditStatus(mediaDurationSeconds: Double, startedAt: Date?, endedAt: Date?) -> RecordingDurationAuditStatus {
    guard mediaDurationSeconds > 0,
          let startedAt,
          let endedAt else {
        return .insufficientData
    }

    let periodSeconds = endedAt.timeIntervalSince(startedAt)
    guard periodSeconds > 0 else {
        return .insufficientData
    }

    let deltaSeconds = abs(mediaDurationSeconds - periodSeconds)
    return deltaSeconds > 5 ? .mismatch : .ok
}

struct ContentView: View {
    @ObservedObject var manager: ChannelManager
    @State private var showingAddChannel = false
    @State private var showingImportChannels = false
    @State private var showingSettings = false
    @State private var showingEditChannel = false
    @State private var selectedChannel: String?
    @State private var selectedDetailTab: DetailTab = .allChannels
    @State private var lastNonRecordingDetailTab: DetailTab = .allChannels
    @State private var selectedRecordingPath: String?
    @State private var recordingNavigationPaths: [String] = []
    @State private var recordingsRefreshGeneration: Int = 0
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var channelInfos: [ChannelInfo] = []
    @State private var channelInfoTimer: Timer?
    @State private var isRefreshingChannelInfos = false
    @State private var searchText: String = ""
    @State private var statusFilter: ChannelStatusFilter = .all
    @State private var genderFilter: String? = nil
    @State private var detailNavigationOrder: [String] = []
    
    var body: some View {
        NavigationSplitView {
            ActivitySidebarView(
                manager: manager,
                channelInfos: channelInfos,
                onSelectChannel: { username in
                    selectedChannel = username
                    selectedRecordingPath = nil
                    recordingNavigationPaths = []
                    selectedDetailTab = .channel
                }
            )
        } detail: {
            VStack(spacing: 0) {
                if !manager.appConfig.recordingEnabled {
                    HStack(spacing: 8) {
                        Image(systemName: "record.circle")
                            .foregroundColor(.orange)
                        Text("Recording is globally paused. Channels are monitored but nothing is being recorded.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Resume") {
                            manager.appConfig.recordingEnabled = true
                            manager.saveAppConfig()
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.08))
                }

                Picker("View", selection: $selectedDetailTab) {
                    Text("All Channels").tag(DetailTab.allChannels)
                    Text("Channel").tag(DetailTab.channel)
                    Text("Recordings").tag(DetailTab.recordings)
                    Text("Recording").tag(DetailTab.recording)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

                Divider()

                detailContent
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: { showingAddChannel = true }) {
                    Label("Add Channel", systemImage: "plus")
                }

                Button(action: { showingImportChannels = true }) {
                    Label("Import", systemImage: "square.and.arrow.down")
                }

                Button(action: { showingSettings = true }) {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showingAddChannel) {
            AddChannelView(
                manager: manager,
                errorMessage: $errorMessage,
                showingError: $showingError,
                onChannelCreated: { username in
                    selectedChannel = username
                    selectedRecordingPath = nil
                    recordingNavigationPaths = []
                    selectedDetailTab = .allChannels
                    updateChannelInfos()
                }
            )
        }
        .sheet(isPresented: $showingImportChannels) {
            ImportChannelsView(manager: manager)
        }
        .sheet(isPresented: $showingEditChannel) {
            if let username = selectedChannel {
                EditChannelView(
                    manager: manager,
                    username: username,
                    errorMessage: $errorMessage,
                    showingError: $showingError,
                    onRenamed: { newUsername in
                        selectedChannel = newUsername
                    }
                )
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(manager: manager)
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .frame(minWidth: 1200, minHeight: 820)
        .onAppear {
            startChannelInfoTimer()
        }
        .onChange(of: selectedDetailTab) { newTab in
            if newTab != .recording {
                lastNonRecordingDetailTab = newTab
            }

            if newTab == .channel {
                if detailNavigationOrder.isEmpty {
                    detailNavigationOrder = orderedChannelUsernames
                }
            } else {
                detailNavigationOrder = []
            }
        }
        .onChange(of: selectedChannel) { newSelection in
            guard selectedDetailTab == .channel,
                  let newSelection else { return }

            if detailNavigationOrder.isEmpty {
                detailNavigationOrder = orderedChannelUsernames
            }

            if !detailNavigationOrder.contains(newSelection) {
                detailNavigationOrder.append(newSelection)
            }
        }
        .onDisappear {
            channelInfoTimer?.invalidate()
        }
    }

    private var orderedChannelUsernames: [String] {
        channelInfos.map { $0.username }
    }

    @ViewBuilder
    private var detailContent: some View {
        if selectedDetailTab == .allChannels {
            AllChannelsGridView(
                manager: manager,
                selectedChannel: $selectedChannel,
                channelInfos: channelInfos,
                searchText: $searchText,
                statusFilter: $statusFilter,
                genderFilter: $genderFilter,
                onOpenChannel: {
                    selectedRecordingPath = nil
                    recordingNavigationPaths = []
                    selectedDetailTab = .channel
                }
            )
        } else if selectedDetailTab == .recordings {
            RecordingsLibraryView(
                manager: manager,
                refreshGeneration: recordingsRefreshGeneration,
                onOpenRecording: { path, channelUsername, navigationPaths in
                    selectedChannel = channelUsername
                    selectedRecordingPath = path
                    recordingNavigationPaths = navigationPaths
                    lastNonRecordingDetailTab = .recordings
                    selectedDetailTab = .recording
                }
            )
        } else if selectedDetailTab == .recording,
                  let recordingPath = selectedRecordingPath {
            RecordingDetailView(
                manager: manager,
                recordingPath: recordingPath,
                preferredChannelUsername: selectedChannel,
                navigationPaths: recordingNavigationPaths,
                backLabel: lastNonRecordingDetailTab == .recordings ? "Back to Recordings" : "Back to Channel",
                onBack: {
                    selectedDetailTab = lastNonRecordingDetailTab == .recording ? .channel : lastNonRecordingDetailTab
                },
                onOpenChannel: { channelUsername in
                    selectedChannel = channelUsername
                    selectedDetailTab = .channel
                },
                onSelectRecording: { path, channelUsername in
                    selectedRecordingPath = path
                    if let channelUsername {
                        selectedChannel = channelUsername
                    }
                },
                onMoveToTrash: { deletedPath in
                    recordingNavigationPaths.removeAll { $0 == deletedPath }
                    recordingsRefreshGeneration &+= 1
                    if selectedRecordingPath == deletedPath {
                        selectedRecordingPath = nil
                    }
                }
            )
            .id(recordingPath)
        } else if selectedDetailTab == .recording {
            VStack(spacing: 20) {
                Image(systemName: "film.stack")
                    .font(.system(size: 60))
                    .foregroundColor(.secondary)
                Text("No Recording Selected")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("Open a recording from a channel or from the recordings library")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let username = selectedChannel {
            ChannelDetailView(
                manager: manager,
                username: username,
                initialInfo: channelInfos.first(where: { $0.username == username }),
                refreshGeneration: recordingsRefreshGeneration,
                onPrevious: previousChannelUsername == nil ? nil : {
                    if let previousChannelUsername {
                        selectedChannel = previousChannelUsername
                    }
                },
                onNext: nextChannelUsername == nil ? nil : {
                    if let nextChannelUsername {
                        selectedChannel = nextChannelUsername
                    }
                },
                canGoPrevious: previousChannelUsername != nil,
                canGoNext: nextChannelUsername != nil,
                onEdit: { showingEditChannel = true },
                onDeleted: { selectedChannel = nil },
                onOpenRecording: { recordingPath, navigationPaths in
                    selectedRecordingPath = recordingPath
                    recordingNavigationPaths = navigationPaths
                    lastNonRecordingDetailTab = .channel
                    selectedDetailTab = .recording
                }
            )
            .id(username)
        } else {
            VStack(spacing: 20) {
                Image(systemName: "tv")
                    .font(.system(size: 60))
                    .foregroundColor(.secondary)
                Text("No Channel Selected")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("Open a channel from the All Channels grid")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var navigationChannelUsernames: [String] {
        guard selectedDetailTab == .channel, !detailNavigationOrder.isEmpty else {
            return orderedChannelUsernames
        }

        let liveSet = Set(orderedChannelUsernames)
        var merged = detailNavigationOrder.filter { liveSet.contains($0) }
        for username in orderedChannelUsernames where !merged.contains(username) {
            merged.append(username)
        }
        return merged
    }

    private var selectedChannelIndex: Int? {
        guard let selectedChannel else { return nil }
        return navigationChannelUsernames.firstIndex(of: selectedChannel)
    }

    private var previousChannelUsername: String? {
        guard let selectedChannelIndex, selectedChannelIndex > 0 else { return nil }
        return navigationChannelUsernames[selectedChannelIndex - 1]
    }

    private var nextChannelUsername: String? {
        guard let selectedChannelIndex,
              selectedChannelIndex < navigationChannelUsernames.count - 1 else { return nil }
        return navigationChannelUsernames[selectedChannelIndex + 1]
    }

    private func startChannelInfoTimer() {
        updateChannelInfos()
        channelInfoTimer?.invalidate()
        channelInfoTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            updateChannelInfos()
        }
    }

    private func updateChannelInfos() {
        guard !isRefreshingChannelInfos else { return }
        isRefreshingChannelInfos = true

        Task { @MainActor in
            defer { isRefreshingChannelInfos = false }
            channelInfos = await manager.getAllChannelInfo()

                        let liveSet = Set(orderedChannelUsernames)
                        detailNavigationOrder = detailNavigationOrder.filter { liveSet.contains($0) }

            if let selectedChannel,
               !orderedChannelUsernames.contains(selectedChannel) {
                self.selectedChannel = nil
            }
        }
    }
}

struct AllChannelsGridView: View {
    private struct StatusCounts {
        let total: Int
        let online: Int
        let recording: Int
        let paused: Int
        let limitReached: Int
        let offline: Int
        let invalid: Int
    }

    @ObservedObject var manager: ChannelManager
    @Binding var selectedChannel: String?
    let channelInfos: [ChannelInfo]
    @Binding var searchText: String
    @Binding var statusFilter: ChannelStatusFilter
    @Binding var genderFilter: String?
    var onOpenChannel: (() -> Void)? = nil

    private let gridColumns = [GridItem(.adaptive(minimum: 260), spacing: 14)]

    var body: some View {
        Group {
            if channelInfos.isEmpty {
                if manager.isHydratingChannels {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.1)
                        Text("Loading channels...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Fetching your channel list")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "rectangle.grid.2x2")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No Channels")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Add a channel to populate the preview grid")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    VStack(spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            TextField("Filter by username", text: $searchText)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 240, idealWidth: 380, maxWidth: 520)

                            Spacer(minLength: 0)
                        }

                        HStack(spacing: 8) {
                            countChip("Total", count: statusCounts.total, tint: .primary) {
                                statusFilter = .all
                            }
                            countChip("Online", count: statusCounts.online, tint: .mint) {
                                statusFilter = .online
                            }
                            countChip("Recording", count: statusCounts.recording, tint: .green) {
                                statusFilter = .recording
                            }
                            countChip("Paused", count: statusCounts.paused, tint: .orange) {
                                statusFilter = .paused
                            }
                            countChip("Limit Reached", count: statusCounts.limitReached, tint: .yellow) {
                                statusFilter = .limitReached
                            }
                            countChip("Offline", count: statusCounts.offline, tint: .secondary) {
                                statusFilter = .offline
                            }
                            countChip("Invalid", count: statusCounts.invalid, tint: .red) {
                                statusFilter = .invalid
                            }
                            countChip("Showing", count: filteredChannelInfos.count, tint: .blue) {
                                statusFilter = .all
                            }
                            
                            Spacer(minLength: 0)
                        }

                        HStack(spacing: 8) {
                            Button(action: { genderFilter = nil }) {
                                HStack(spacing: 4) {
                                    Text("All")
                                        .font(.caption)
                                        .lineLimit(1)
                                    if genderFilter == nil {
                                        Image(systemName: "checkmark")
                                            .font(.caption2)
                                    }
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(GenderFilterButtonStyle(isSelected: genderFilter == nil))
                            
                            if availableGenders.isEmpty {
                                Text("Fetching bio...")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            } else {
                                ForEach(availableGenders, id: \.self) { gender in
                                    Button(action: { genderFilter = gender }) {
                                        HStack(spacing: 4) {
                                            Text(gender)
                                                .font(.caption)
                                                .lineLimit(1)
                                            if genderFilter == gender {
                                                Image(systemName: "checkmark")
                                                    .font(.caption2)
                                            }
                                        }
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                    }
                                    .buttonStyle(GenderFilterButtonStyle(isSelected: genderFilter == gender))
                                }
                            }
                            
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                    if filteredChannelInfos.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.title2)
                                .foregroundColor(.secondary)
                            Text("No matching channels")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Text("Adjust the search text or status filter")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVGrid(columns: gridColumns, spacing: 14) {
                                ForEach(filteredChannelInfos) { info in
                                    Button {
                                        selectedChannel = info.username
                                        onOpenChannel?()
                                    } label: {
                                        ChannelPreviewCard(manager: manager, info: info, isSelected: selectedChannel == info.username)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(16)
                        }
                    }
                }
            }
        }
    }

    private var filteredChannelInfos: [ChannelInfo] {
        channelInfos.filter { info in
            let matchesSearch: Bool
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                matchesSearch = true
            } else {
                matchesSearch = info.username.localizedCaseInsensitiveContains(searchText)
            }

            let matchesStatus = matchesStatusFilter(info, filter: statusFilter)
            let matchesGender = matchesGenderFilter(info, filter: genderFilter)

            return matchesSearch && matchesStatus && matchesGender
        }
    }

    private var statusCounts: StatusCounts {
        StatusCounts(
            total: channelInfos.count,
            online: channelInfos.filter { matchesStatusFilter($0, filter: .online) }.count,
            recording: channelInfos.filter { matchesStatusFilter($0, filter: .recording) }.count,
            paused: channelInfos.filter { matchesStatusFilter($0, filter: .paused) }.count,
            limitReached: channelInfos.filter { matchesStatusFilter($0, filter: .limitReached) }.count,
            offline: channelInfos.filter { matchesStatusFilter($0, filter: .offline) }.count,
            invalid: channelInfos.filter { matchesStatusFilter($0, filter: .invalid) }.count
        )
    }

    private func matchesStatusFilter(_ info: ChannelInfo, filter: ChannelStatusFilter) -> Bool {
        switch filter {
        case .all:
            return true
        case .online:
            return info.isOnline && !info.isInvalid
        case .recording:
            return info.isActivelyRecording && !info.isInvalid
        case .paused:
            return info.isPaused && !info.isPausedBySessionLimit && !info.isInvalid
        case .limitReached:
            return info.isPausedBySessionLimit && !info.isInvalid
        case .offline:
            return !info.isOnline && !info.isPaused && !info.isPausedBySessionLimit && !info.isInvalid
        case .invalid:
            return info.isInvalid
        }
    }

    private func matchesGenderFilter(_ info: ChannelInfo, filter: String?) -> Bool {
        guard let filter = filter, !filter.isEmpty else {
            return true
        }
        guard let gender = info.bioMetadata?.gender else {
            return false
        }
        return gender.localizedCaseInsensitiveContains(filter)
    }

    private var availableGenders: [String] {
        let genders = Set(channelInfos.compactMap { $0.bioMetadata?.gender })
        return genders.sorted()
    }

    private func countChip(_ title: String, count: Int, tint: Color, action: (() -> Void)? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .lineLimit(1)
            Text("\(count)")
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12))
        .foregroundColor(tint)
        .clipShape(Capsule())
        .onTapGesture {
            action?()
        }
    }
}

private struct ManualQueuePlannerSheet: View {
    @ObservedObject var manager: ChannelManager
    let channelInfos: [ChannelInfo]

    @Environment(\.dismiss) private var dismiss

    @State private var plannerOrder: [String] = []
    @State private var activeRecordings: [String] = []
    @State private var slotCapacity: Int = 1
    @State private var recordingEnabledAtLoad = true
    @State private var isLoading = true
    @State private var isApplying = false
    @State private var autoRefreshTimer: Timer?

    private var infoByUsername: [String: ChannelInfo] {
        Dictionary(uniqueKeysWithValues: channelInfos.map { ($0.username, $0) })
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Use arrows to change priority. Changes apply immediately: top rows are slot targets, rows below are queue order.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    queueStatChip("Slots", value: "\(slotCapacity)", color: .blue)
                    queueStatChip("Recording", value: "\(activeRecordings.count)", color: .green)
                    queueStatChip("Waiting", value: "\(max(0, plannerOrder.count - slotCapacity))", color: .orange)
                    if !recordingEnabledAtLoad {
                        queueStatChip("Global Recording", value: "Paused", color: .red)
                    }
                    Spacer()

                    if isApplying {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button {
                        Task {
                            await loadSnapshot()
                        }
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isLoading || isApplying)
                }

                if !recordingEnabledAtLoad {
                    Text("Global recording is paused. Queue order and slot targets will still be applied, but recordings will not start until recording is resumed.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                if isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Loading queue state...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Slot assignment order")
                        .font(.headline)

                    List {
                        ForEach(Array(plannerOrder.enumerated()), id: \.element) { index, username in
                            unifiedPlannerRow(index: index, username: username)
                        }
                    }
                    .frame(minHeight: 360)

                    Text("Tip: move a waiting-live channel into the top \(slotCapacity) rows to rotate it into a slot. Recording channels moved below slot rows are rotated out automatically.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(16)
            .navigationTitle("Manage Recording Slots")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .disabled(isApplying)
                }
            }
        }
        .frame(minWidth: 840, minHeight: 560)
        .task {
            await loadSnapshot()
            startAutoRefreshTimer()
        }
        .onDisappear {
            autoRefreshTimer?.invalidate()
            autoRefreshTimer = nil
        }
    }

    private func loadSnapshot() async {
        isLoading = true
        let snapshot = await manager.getRecordingQueueSnapshot()
        recordingEnabledAtLoad = snapshot.recordingEnabled
        activeRecordings = snapshot.activeUsernames
        slotCapacity = max(1, snapshot.maxConcurrent == 0 ? snapshot.activeUsernames.count : snapshot.maxConcurrent)

        var merged: [String] = []
        for username in snapshot.activeUsernames + snapshot.waitingUsernames {
            if !merged.contains(username) {
                merged.append(username)
            }
        }
        plannerOrder = merged

        isLoading = false
    }

    private func startAutoRefreshTimer() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { _ in
            guard !isApplying else { return }
            Task {
                await loadSnapshot()
            }
        }
    }

    private func movePriority(username: String, direction: Int) {
        guard !isApplying else { return }
        guard let currentIndex = plannerOrder.firstIndex(of: username) else { return }

        let targetIndex = currentIndex + direction
        guard plannerOrder.indices.contains(targetIndex) else { return }

        plannerOrder.swapAt(currentIndex, targetIndex)

        Task {
            await applyPlanLive()
        }
    }

    private func applyPlanLive() async {
        isApplying = true
        let desiredInSlots = Array(plannerOrder.prefix(slotCapacity))
        let desiredSlotSet = Set(desiredInSlots)
        let activeSet = Set(activeRecordings)

        let rotateOut = activeRecordings.filter { !desiredSlotSet.contains($0) }
        let waitingOrder = plannerOrder.filter { !activeSet.contains($0) }

        await manager.applyManualRecordingQueue(
            waitingOrder: waitingOrder,
            rotateOutRecordings: rotateOut,
            releaseHoldAfterApply: false
        )

        isApplying = false
        await loadSnapshot()
    }

    @ViewBuilder
    private func unifiedPlannerRow(index: Int, username: String) -> some View {
        let inSlot = index < slotCapacity
        let showsBoundary = index == slotCapacity && slotCapacity > 0 && slotCapacity < plannerOrder.count

        VStack(spacing: 6) {
            if showsBoundary {
                HStack(spacing: 8) {
                    Divider()
                    Text("Queue starts below")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Divider()
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 8) {
                Text(inSlot ? "Slot \(index + 1)" : "Queue \(index - slotCapacity + 1)")
                    .font(.caption)
                    .foregroundColor(inSlot ? .green : .orange)
                    .frame(width: 64, alignment: .leading)

                Text(username)
                    .font(.body.monospaced())
                    .lineLimit(1)
                Spacer()

                if let info = infoByUsername[username] {
                    if activeRecordings.contains(username) {
                        Text("Recording")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else if info.isOnline {
                        Text("Waiting Live")
                            .font(.caption)
                            .foregroundColor(.blue)
                    } else {
                        Text("Waiting Offline")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if info.isNoPersonDetected {
                        Text(formatNoPersonDuration(info.noPersonDurationSeconds))
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                } else {
                    Text("Unknown")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 4) {
                    Button {
                        movePriority(username: username, direction: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isApplying || index == 0)

                    Button {
                        movePriority(username: username, direction: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isApplying || index >= plannerOrder.count - 1)
                }
            }
            .contentShape(Rectangle())
        }
        .padding(.vertical, 1)
        .listRowBackground((inSlot ? Color.green.opacity(0.06) : Color.orange.opacity(0.05)))
    }

    private func queueStatChip(_ title: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.13))
        .foregroundColor(color)
        .clipShape(Capsule())
    }
}

private enum RecordingSortOption: String, CaseIterable, Identifiable {
    case newest = "Newest"
    case oldest = "Oldest"
    case largest = "Largest"
    case smallest = "Smallest"
    case filename = "Filename"

    var id: String { rawValue }
}

private struct RecordingLibraryItem: Identifiable {
    let path: String
    let filename: String
    let channelName: String
    let recordingStatus: String
    let fileExtension: String
    let sizeBytes: Int64
    let durationSeconds: Double
    let startedAt: Date?
    let endedAt: Date?
    let modifiedAt: Date
    let thumbnailSourcePath: String?
    let channelThumbnailPath: String?
    let isInProgress: Bool
    let isActivelyFinalizing: Bool
    let isPreviewable: Bool
    let isOpenable: Bool

    var id: String { path }

    var thumbnailCacheKey: String {
        let modifiedStamp = Int64(modifiedAt.timeIntervalSince1970)
        let source = thumbnailSourcePath ?? "none"
        let channelThumb = channelThumbnailPath ?? "none"
        return "\(path)|\(source)|\(channelThumb)|\(sizeBytes)|\(modifiedStamp)|\(isInProgress)"
    }
}

private actor RecordingThumbnailStore {
    static let shared = RecordingThumbnailStore()

    private var inFlight: [String: Task<String?, Never>] = [:]
    private var lastFailureAt: [String: Date] = [:]
    private let failureRetryInterval: TimeInterval = 300
    private let fileManager = FileManager.default
    private let cacheDirectory: URL

    init() {
        let cachesRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        cacheDirectory = cachesRoot
            .appendingPathComponent("ChaturbateDVR", isDirectory: true)
            .appendingPathComponent("recording-card-thumbnails", isDirectory: true)

        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func thumbnailPath(for item: RecordingLibraryItem) async -> String? {
        guard let sourcePathRaw = item.thumbnailSourcePath else {
            return nil
        }

        let cacheKey = item.thumbnailCacheKey
        let destinationURL = cacheDirectory.appendingPathComponent("\(Self.stableHash(cacheKey)).jpg")

        if fileManager.fileExists(atPath: destinationURL.path) {
            return destinationURL.path
        }

        if let failedAt = lastFailureAt[cacheKey],
           Date().timeIntervalSince(failedAt) < failureRetryInterval {
            return nil
        }

        if let existingTask = inFlight[cacheKey] {
            return await existingTask.value
        }

        let sourcePath = (sourcePathRaw as NSString).expandingTildeInPath
        let task = Task.detached(priority: .utility) {
            Self.generateThumbnail(sourcePath: sourcePath, destinationURL: destinationURL)
        }
        inFlight[cacheKey] = task

        let result = await task.value
        inFlight[cacheKey] = nil

        if result == nil {
            lastFailureAt[cacheKey] = Date()
        } else {
            lastFailureAt[cacheKey] = nil
        }

        return result
    }

    func prewarm(items: [RecordingLibraryItem]) async {
        for item in items {
            if Task.isCancelled { return }
            _ = await thumbnailPath(for: item)
        }
    }

    private nonisolated static func generateThumbnail(sourcePath: String, destinationURL: URL) -> String? {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }

        let asset = AVURLAsset(
            url: sourceURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 480, height: 270)
        imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)

        let candidateTimes = [
            CMTime(seconds: 1, preferredTimescale: 600),
            CMTime(seconds: 3, preferredTimescale: 600),
            CMTime(seconds: 0, preferredTimescale: 600)
        ]

        for time in candidateTimes {
            guard let cgImage = try? imageGenerator.copyCGImage(at: time, actualTime: nil) else {
                continue
            }

            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else {
                continue
            }

            do {
                try data.write(to: destinationURL, options: .atomic)
                return destinationURL.path
            } catch {
                return nil
            }
        }

        return nil
    }

    private nonisolated static func stableHash(_ input: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}

private struct RecordingThumbnailView: View {
    let item: RecordingLibraryItem

    @State private var thumbnailImage: NSImage?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.45))

            if let thumbnailImage {
                Image(nsImage: thumbnailImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else if isLoading {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading preview...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else if item.isInProgress {
                VStack(spacing: 7) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.orange)
                    Text("Recording in progress")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                Image(systemName: "film")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .frame(height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: item.thumbnailCacheKey) {
            isLoading = true
            thumbnailImage = nil

            if item.isInProgress {
                thumbnailImage = await loadImage(atPath: item.channelThumbnailPath)
            } else {
                let generatedPath = await RecordingThumbnailStore.shared.thumbnailPath(for: item)
                thumbnailImage = await loadImage(atPath: generatedPath)
            }

            isLoading = false
        }
    }

    private func loadImage(atPath path: String?) async -> NSImage? {
        guard let path else { return nil }

        let expandedPath = (path as NSString).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: expandedPath)

        let data = await Task.detached(priority: .utility) {
            try? Data(contentsOf: fileURL, options: [.mappedIfSafe])
        }.value

        guard let data else { return nil }
        return NSImage(data: data)
    }
}

private enum RecordingRepairFilter: Equatable {
    case all
    case durationMismatch
    case pendingScan
    case scanning
    case good
    case needsRemux
    case queued
    case remuxing
    case repaired
    case failed
    case unsupported

    var label: String {
        switch self {
        case .all:         return "All"
        case .durationMismatch: return "Duration Mismatch"
        case .pendingScan: return "Pending"
        case .scanning:    return "Scanning"
        case .good:        return "Good"
        case .needsRemux:  return "Needs Remux"
        case .queued:      return "Queued"
        case .remuxing:    return "Remuxing"
        case .repaired:    return "Repaired"
        case .failed:      return "Failed"
        case .unsupported: return "Excluded"
        }
    }

    var tint: Color {
        switch self {
        case .all:         return .primary
        case .durationMismatch: return .red
        case .pendingScan: return .secondary
        case .scanning:    return .blue
        case .good:        return .green
        case .needsRemux:  return .orange
        case .queued:      return .orange
        case .remuxing:    return .mint
        case .repaired:    return .green
        case .failed:      return .red
        case .unsupported: return .secondary
        }
    }

    func matches(_ state: RecordingRepairState) -> Bool {
        switch (self, state) {
        case (.all, _):               return true
        case (.pendingScan, .pendingScan): return true
        case (.scanning, .scanning):  return true
        case (.good, .good):          return true
        case (.needsRemux, .needsRemux): return true
        case (.queued, .queued):      return true
        case (.remuxing, .remuxing):  return true
        case (.repaired, .repaired):  return true
        case (.failed, .failed):      return true
        case (.unsupported, .unsupported): return true
        default:                      return false
        }
    }
}

private struct RecordingRepairFilterCounts {
    var all = 0
    var durationMismatch = 0
    var pendingScan = 0
    var scanning = 0
    var good = 0
    var needsRemux = 0
    var queued = 0
    var remuxing = 0
    var repaired = 0
    var failed = 0
    var unsupported = 0

    func count(for filter: RecordingRepairFilter) -> Int {
        switch filter {
        case .all: return all
        case .durationMismatch: return durationMismatch
        case .pendingScan: return pendingScan
        case .scanning: return scanning
        case .good: return good
        case .needsRemux: return needsRemux
        case .queued: return queued
        case .remuxing: return remuxing
        case .repaired: return repaired
        case .failed: return failed
        case .unsupported: return unsupported
        }
    }
}

struct RecordingsLibraryView: View {
    @ObservedObject var manager: ChannelManager
    let refreshGeneration: Int
    var onOpenRecording: ((String, String, [String]) -> Void)? = nil

    private static let thumbnailCardMinimumWidth: CGFloat = 260
    private static let thumbnailCardSpacing: CGFloat = 14
    private static let thumbnailCardEstimatedHeight: CGFloat = 230
    private static let thumbnailPrewarmDebounceNanoseconds: UInt64 = 180_000_000
    private static let pageSize = 60

    @State private var allRecordings: [RecordingLibraryItem] = []
    @State private var sortedRecordings: [RecordingLibraryItem] = []
    @State private var availableChannelFilters: [String] = []
    @State private var totalAllRecordingsBytes: Int64 = 0
    @State private var cachedVisibleRecordings: [RecordingLibraryItem] = []
    @State private var cachedPageRecordings: [RecordingLibraryItem] = []
    @State private var cachedVisibleBytes: Int64 = 0
    @State private var cachedTotalPages: Int = 1
    @State private var pageCacheVersion: Int = 0
    @State private var searchText: String = ""
    @State private var selectedChannelFilter: String = "All Channels"
    @State private var repairFilter: RecordingRepairFilter = .all
    @State private var sortOption: RecordingSortOption = .newest
    @State private var isScanning = false
    @State private var scanError: String?
    @State private var refreshTimer: Timer?
    @State private var currentPage: Int = 0
    @State private var thumbnailPrewarmTask: Task<Void, Never>?
    @State private var thumbnailViewportSize: CGSize = .zero

    private let gridColumns = [GridItem(.adaptive(minimum: Self.thumbnailCardMinimumWidth), spacing: Self.thumbnailCardSpacing)]

    private static let queryTrimSet = CharacterSet.whitespacesAndNewlines

    var body: some View {
        GeometryReader { geometry in
            let channelOptions = availableChannelFilters
            let counts = repairFilterCounts
            let visible = cachedVisibleRecordings
            let visibleBytes = cachedVisibleBytes
            let pages = cachedTotalPages
            let safePage = min(currentPage, pages - 1)
            let pageItems = cachedPageRecordings

            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        TextField("Filter by filename or channel", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 240, idealWidth: 420, maxWidth: 560)

                        Picker("Sort", selection: $sortOption) {
                            ForEach(RecordingSortOption.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 120)

                        Picker("Channel", selection: $selectedChannelFilter) {
                            Text("All Channels").tag("All Channels")
                            ForEach(channelOptions, id: \.self) { channel in
                                Text(channel).tag(channel)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 170)

                        Button {
                            refreshRecordings()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            manager.startRepairForFlaggedRecordings()
                        } label: {
                            Label(manager.isRepairingFlaggedRecordings ? "Repairing..." : "Repair Flagged", systemImage: "wrench.and.screwdriver")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(manager.isRepairingFlaggedRecordings || manager.recordingRepairSummary.needsRemux == 0)

                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 8) {
                        filterChip(.all,         count: counts.count(for: .all))
                        filterChip(.durationMismatch, count: counts.count(for: .durationMismatch))
                        filterChip(.pendingScan, count: counts.count(for: .pendingScan))
                        filterChip(.scanning,    count: counts.count(for: .scanning))
                        filterChip(.good,        count: counts.count(for: .good))
                        filterChip(.needsRemux,  count: counts.count(for: .needsRemux))
                        filterChip(.queued,      count: counts.count(for: .queued))
                        filterChip(.remuxing,    count: counts.count(for: .remuxing))
                        filterChip(.repaired,    count: counts.count(for: .repaired))
                        filterChip(.failed,      count: counts.count(for: .failed))
                        filterChip(.unsupported, count: counts.count(for: .unsupported))

                        if manager.isRecordingRepairScanActive {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Scanning")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let filename = manager.recordingRepairScanDetail, !filename.isEmpty {
                                    Text(filename)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }

                        Text("Size: \(formatByteCount(visibleBytes))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

                if let scanError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundColor(.orange)
                        Text("Could not scan recordings")
                            .font(.headline)
                        Text(scanError)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isScanning && allRecordings.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Scanning recordings...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visible.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "film.stack")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text(allRecordings.isEmpty ? "No recordings found" : "No matching recordings")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text(allRecordings.isEmpty
                                ? "Recordings are loaded from the recording database"
                             : "Adjust the search text or filters")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        ScrollView {
                            LazyVGrid(columns: gridColumns, spacing: Self.thumbnailCardSpacing) {
                                ForEach(pageItems) { item in
                                    Button {
                                        let contextPaths = cachedVisibleRecordings
                                            .filter(\ .isOpenable)
                                            .map(\ .path)
                                        onOpenRecording?(item.path, item.channelName, contextPaths)
                                    } label: {
                                        RecordingLibraryCardView(
                                            item: item,
                                            repairState: manager.recordingRepairState(
                                                for: item.path,
                                                fileExtension: item.fileExtension,
                                                recordingStatus: item.recordingStatus
                                            )
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!item.isOpenable)
                                }
                            }
                            .padding(16)
                        }

                        if pages > 1 {
                            Divider()
                            HStack(spacing: 12) {
                                Button {
                                    currentPage = max(0, currentPage - 1)
                                } label: {
                                    Image(systemName: "chevron.left")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(currentPage == 0)

                                Text("Page \(safePage + 1) of \(pages)  ·  Showing \(pageItems.count) of \(visible.count)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Button {
                                    currentPage = min(pages - 1, currentPage + 1)
                                } label: {
                                    Image(systemName: "chevron.right")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(currentPage >= pages - 1)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        }
                    }
                }
            }
            .onAppear {
                updateThumbnailViewportSize(geometry.size)
            }
            .onChange(of: geometry.size) { newSize in
                updateThumbnailViewportSize(newSize)
            }
        }
        .onAppear {
            manager.ensureRecordingRepairMaintenanceRunning()
            refreshRecordings()
            startRefreshTimer()
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
            thumbnailPrewarmTask?.cancel()
            thumbnailPrewarmTask = nil
        }
        .onChange(of: repairFilter) { _ in
            currentPage = 0
            recomputeVisibleCaches()
        }
        .onChange(of: selectedChannelFilter) { _ in
            currentPage = 0
            recomputeVisibleCaches()
        }
        .onChange(of: searchText) { _ in
            currentPage = 0
            recomputeVisibleCaches()
        }
        .onChange(of: sortOption) { _ in
            applySortOption()
            currentPage = 0
        }
        .onChange(of: currentPage) { _ in
            recomputeVisibleCaches()
        }
        .onChange(of: manager.recordingRepairSummary) { _ in
            if repairFilter != .all {
                recomputeVisibleCaches()
            }
        }
        .onChange(of: refreshGeneration) { _ in
            refreshRecordings()
        }
        .onChange(of: pageCacheVersion) { _ in
            scheduleThumbnailPrewarm(debounceNanoseconds: Self.thumbnailPrewarmDebounceNanoseconds)
        }
    }

    private var repairFilterCounts: RecordingRepairFilterCounts {
        // Derive counts using the same per-item logic as buildVisibleRecordings so
        // the badge numbers always match the number of items shown by each filter.
        var counts = RecordingRepairFilterCounts()
        counts.all = allRecordings.count
        for item in allRecordings {
            if hasDurationMismatch(item) {
                counts.durationMismatch += 1
            }
            let state = manager.recordingRepairState(
                for: item.path,
                fileExtension: item.fileExtension,
                recordingStatus: item.recordingStatus
            )
            switch state {
            case .pendingScan:  counts.pendingScan += 1
            case .scanning:     counts.scanning += 1
            case .good:         counts.good += 1
            case .needsRemux:   counts.needsRemux += 1
            case .queued:       counts.queued += 1
            case .remuxing:     counts.remuxing += 1
            case .repaired:     counts.repaired += 1
            case .failed:       counts.failed += 1
            case .unsupported:  counts.unsupported += 1
            }
        }
        return counts
    }

    private func buildVisibleRecordings() -> [RecordingLibraryItem] {
        let query = searchText.trimmingCharacters(in: Self.queryTrimSet)
        let needsChannelFilter = selectedChannelFilter != "All Channels"
        let needsRepairFilter = repairFilter != .all
        let needsQuery = !query.isEmpty

        if !needsChannelFilter && !needsRepairFilter && !needsQuery {
            return sortedRecordings
        }

        return sortedRecordings.filter { item in
            if needsChannelFilter && item.channelName != selectedChannelFilter {
                return false
            }

            if needsRepairFilter {
                if repairFilter == .durationMismatch {
                    if !hasDurationMismatch(item) {
                        return false
                    }
                } else {
                    let state = manager.recordingRepairState(
                        for: item.path,
                        fileExtension: item.fileExtension,
                        recordingStatus: item.recordingStatus
                    )
                    if !repairFilter.matches(state) {
                        return false
                    }
                }
            }

            if needsQuery {
                return item.filename.localizedCaseInsensitiveContains(query)
                    || item.channelName.localizedCaseInsensitiveContains(query)
            }

            return true
        }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { _ in
            refreshRecordings()
        }
    }

    private func refreshRecordings() {
        isScanning = true
        scanError = nil
        manager.ensureRecordingRepairMaintenanceRunning()

        Task {
            let entries = await manager.getRecordingLibraryEntries()
            let activelyFinalizingPaths = await manager.getActivelyFinalizingPaths()
            let activeChannelThumbnails = await loadActiveChannelThumbnails(entries: entries)

            let recordings = await Task.detached(priority: .utility) {
                Self.mapRecordingEntries(entries, activeChannelThumbnails: activeChannelThumbnails, activelyFinalizingPaths: activelyFinalizingPaths)
            }.value

            await MainActor.run {
                allRecordings = recordings
                totalAllRecordingsBytes = recordings.reduce(0) { $0 + $1.sizeBytes }
                availableChannelFilters = Array(Set(recordings.map { $0.channelName }))
                    .sorted { $0.lowercased() < $1.lowercased() }
                     applySortOption()

                let hasImplicitPendingMP4 = recordings.contains { item in
                    item.fileExtension.lowercased() == "mp4"
                        && !manager.hasExplicitRecordingRepairState(for: item.path)
                }
                if hasImplicitPendingMP4 {
                    manager.ensureRecordingRepairMaintenanceRunning(forceRescan: true)
                }

                if selectedChannelFilter != "All Channels",
                   !availableChannelFilters.contains(selectedChannelFilter) {
                    selectedChannelFilter = "All Channels"
                }
                isScanning = false
                scheduleThumbnailPrewarm(debounceNanoseconds: 0)
            }
        }
    }

    private func applySortOption() {
        var sorted = allRecordings

        switch sortOption {
        case .newest:
            sorted.sort { $0.modifiedAt > $1.modifiedAt }
        case .oldest:
            sorted.sort { $0.modifiedAt < $1.modifiedAt }
        case .largest:
            sorted.sort { $0.sizeBytes > $1.sizeBytes }
        case .smallest:
            sorted.sort { $0.sizeBytes < $1.sizeBytes }
        case .filename:
            sorted.sort { $0.filename.lowercased() < $1.filename.lowercased() }
        }

        sortedRecordings = sorted
        recomputeVisibleCaches()
    }

    private func loadActiveChannelThumbnails(entries: [RecordingLedgerEntry]) async -> [String: String] {
        let activeUsernames = Set(entries.filter(\.isActive).map(\.channelUsername))
        var activeChannelThumbnails: [String: String] = [:]
        activeChannelThumbnails.reserveCapacity(activeUsernames.count)

        for username in activeUsernames {
            if let thumbnailPath = await manager.getChannelThumbnailPath(username: username) {
                activeChannelThumbnails[username] = thumbnailPath
            }
        }

        return activeChannelThumbnails
    }

    private func scheduleThumbnailPrewarm(debounceNanoseconds: UInt64) {
        thumbnailPrewarmTask?.cancel()

        // Only prewarm thumbnails for the current page to stay lean.
        let prioritizedCount = prioritizedThumbnailCount(for: thumbnailViewportSize)
        let prioritizedItems = Array(cachedPageRecordings.prefix(prioritizedCount))
        let backgroundItems = Array(cachedPageRecordings.dropFirst(prioritizedCount))

        guard !prioritizedItems.isEmpty || !backgroundItems.isEmpty else {
            thumbnailPrewarmTask = nil
            return
        }

        thumbnailPrewarmTask = Task(priority: .userInitiated) {
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
                if Task.isCancelled { return }
            }

            await RecordingThumbnailStore.shared.prewarm(items: prioritizedItems)
            if Task.isCancelled { return }

            await Task.yield()
            await RecordingThumbnailStore.shared.prewarm(items: backgroundItems)
        }
    }

    private func prioritizedThumbnailCount(for viewportSize: CGSize) -> Int {
        let usableWidth = max(viewportSize.width - 32, Self.thumbnailCardMinimumWidth)
        let columns = max(1, Int((usableWidth + Self.thumbnailCardSpacing) / (Self.thumbnailCardMinimumWidth + Self.thumbnailCardSpacing)))

        let usableHeight = max(viewportSize.height - 120, Self.thumbnailCardEstimatedHeight)
        let visibleRows = max(1, Int(ceil((usableHeight + Self.thumbnailCardSpacing) / (Self.thumbnailCardEstimatedHeight + Self.thumbnailCardSpacing))))

        return max(columns * (visibleRows + 1), columns)
    }

    private func updateThumbnailViewportSize(_ newSize: CGSize) {
        guard abs(newSize.width - thumbnailViewportSize.width) > 8 || abs(newSize.height - thumbnailViewportSize.height) > 8 else {
            return
        }

        thumbnailViewportSize = newSize
        scheduleThumbnailPrewarm(debounceNanoseconds: Self.thumbnailPrewarmDebounceNanoseconds)
    }

    private nonisolated static func mapRecordingEntries(
        _ entries: [RecordingLedgerEntry],
        activeChannelThumbnails: [String: String],
        activelyFinalizingPaths: Set<String>
    ) -> [RecordingLibraryItem] {
        let fileManager = FileManager.default

        return entries.map { entry in
            let finalPath = (entry.path as NSString).expandingTildeInPath
            let fileURL = URL(fileURLWithPath: finalPath)
            let finalExists = fileManager.fileExists(atPath: finalPath)

            let workingPath = entry.workingFilePath.map { ($0 as NSString).expandingTildeInPath }
            let workingExists = workingPath.map { fileManager.fileExists(atPath: $0) } ?? false
            let isActivelyFinalizing = entry.isFinalizing && activelyFinalizingPaths.contains(finalPath)
            // Active/finalizing recordings use channel thumbnails; don't generate from incomplete files.
            let thumbnailSourcePath: String?
            if entry.isActive || entry.isFinalizing {
                thumbnailSourcePath = nil
            } else {
                thumbnailSourcePath = finalExists ? finalPath : (workingExists ? workingPath : nil)
            }

            return RecordingLibraryItem(
                path: finalPath,
                filename: fileURL.lastPathComponent,
                channelName: entry.channelUsername,
                recordingStatus: entry.status,
                fileExtension: entry.fileExtension,
                sizeBytes: entry.fileSizeBytes,
                durationSeconds: entry.durationSeconds,
                startedAt: entry.startedAt,
                endedAt: entry.endedAt,
                modifiedAt: entry.modifiedAt,
                thumbnailSourcePath: thumbnailSourcePath,
                channelThumbnailPath: (entry.isActive || entry.isFinalizing) ? activeChannelThumbnails[entry.channelUsername] : nil,
                isInProgress: entry.isActive || entry.isFinalizing,
                isActivelyFinalizing: isActivelyFinalizing,
                isPreviewable: finalExists,
                isOpenable: finalExists || workingExists
            )
        }
    }

    private func recomputeVisibleCaches() {
        let visible = buildVisibleRecordings()
        cachedVisibleRecordings = visible

        if selectedChannelFilter == "All Channels" && repairFilter == .all && searchText.trimmingCharacters(in: Self.queryTrimSet).isEmpty {
            cachedVisibleBytes = totalAllRecordingsBytes
        } else {
            cachedVisibleBytes = visible.reduce(0) { $0 + $1.sizeBytes }
        }

        let totalPages = max(1, Int(ceil(Double(visible.count) / Double(Self.pageSize))))
        cachedTotalPages = totalPages

        if currentPage >= totalPages {
            currentPage = max(totalPages - 1, 0)
        }

        let safePage = min(currentPage, totalPages - 1)
        let start = safePage * Self.pageSize
        let end = min(start + Self.pageSize, visible.count)
        if start < end {
            cachedPageRecordings = Array(visible[start..<end])
        } else {
            cachedPageRecordings = []
        }
        pageCacheVersion &+= 1
    }

    private func hasDurationMismatch(_ item: RecordingLibraryItem) -> Bool {
        recordingDurationAuditStatus(
            mediaDurationSeconds: item.durationSeconds,
            startedAt: item.startedAt,
            endedAt: item.endedAt
        ) == .mismatch
    }

    @ViewBuilder
    private func filterChip(_ filter: RecordingRepairFilter, count: Int) -> some View {
        Button {
            repairFilter = filter
        } label: {
            HStack(spacing: 6) {
                Text(filter.label)
                    .font(.caption)
                    .lineLimit(1)
                Text("\(count)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(repairFilter == filter ? filter.tint.opacity(0.25) : filter.tint.opacity(0.12))
            .foregroundColor(filter.tint)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(repairFilter == filter ? filter.tint.opacity(0.7) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func formatByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private struct RecordingLibraryCardView: View {
    let item: RecordingLibraryItem
    let repairState: RecordingRepairState

    private static let modifiedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                RecordingThumbnailView(item: item)

                Text(item.fileExtension.uppercased())
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.14))
                    .foregroundColor(.accentColor)
                    .cornerRadius(6)
                    .padding(8)
            }

            Text(item.filename)
                .font(.headline)
                .lineLimit(1)

            HStack(spacing: 6) {
                Image(systemName: "person.crop.square")
                    .foregroundColor(.secondary)
                Text(item.channelName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Label(formatModifiedDate(item.modifiedAt), systemImage: "calendar")
                Label(formatSize(item.sizeBytes), systemImage: "doc")
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)

            HStack(spacing: 0) {
                if hasDurationMismatch {
                    badge(label: "Duration Mismatch", tint: .red)
                    Spacer(minLength: 6)
                }
                repairBadge
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(NSColor.separatorColor).opacity(0.28), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 2, x: 0, y: 1)
    }

    private func formatModifiedDate(_ date: Date) -> String {
        Self.modifiedDateFormatter.string(from: date)
    }

    private func formatSize(_ bytes: Int64) -> String {
        Self.sizeFormatter.string(fromByteCount: bytes)
    }

    private var hasDurationMismatch: Bool {
        recordingDurationAuditStatus(
            mediaDurationSeconds: item.durationSeconds,
            startedAt: item.startedAt,
            endedAt: item.endedAt
        ) == .mismatch
    }

    @ViewBuilder
    private var repairBadge: some View {
        if item.recordingStatus == "finalizing" {
            if item.isActivelyFinalizing {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 10, height: 10)
                    Text("Finalizing")
                        .font(.caption2)
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.14))
                .foregroundColor(.blue)
                .clipShape(Capsule())
            } else {
                badge(label: "Queued", tint: .secondary)
            }
        } else if item.isInProgress {
            badge(label: "Recording", tint: .orange)
        } else {
            switch repairState {
            case .pendingScan:
                badge(label: "Pending Scan", tint: .secondary)
            case .scanning:
                badge(label: "Scanning", tint: .blue)
            case .good:
                badge(label: "Good", tint: .green)
            case .needsRemux:
                badge(label: "Needs Remux", tint: .orange)
            case .queued:
                badge(label: "Queued", tint: .orange)
            case .remuxing:
                badge(label: "Remuxing", tint: .mint)
            case .repaired:
                badge(label: "Repaired", tint: .green)
            case .failed:
                badge(label: "Repair Failed", tint: .red)
            case .unsupported:
                badge(label: "Excluded", tint: .secondary)
            }
        }
    }

    private func badge(label: String, tint: Color) -> some View {
        Text(label)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14))
            .foregroundColor(tint)
            .clipShape(Capsule())
    }
}

struct WrappingStatusBadgesView: View {
    @Binding var statusFilter: ChannelStatusFilter
    let totalCount: Int
    let onlineCount: Int
    let recordingCount: Int
    let pausedCount: Int
    let offlineCount: Int
    let invalidCount: Int
    let filteredCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusBadge("Total", count: totalCount, tint: .primary) {
                    statusFilter = .all
                }
                statusBadge("Online", count: onlineCount, tint: .mint) {
                    statusFilter = .online
                }
                statusBadge("Recording", count: recordingCount, tint: .green) {
                    statusFilter = .recording
                }
                statusBadge("Paused", count: pausedCount, tint: .orange) {
                    statusFilter = .paused
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                statusBadge("Offline", count: offlineCount, tint: .secondary) {
                    statusFilter = .offline
                }
                statusBadge("Invalid", count: invalidCount, tint: .red) {
                    statusFilter = .invalid
                }
                statusBadge("Showing", count: filteredCount, tint: .blue) {
                    statusFilter = .all
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func statusBadge(_ title: String, count: Int, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                Text("\(count)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
        }
        .buttonStyle(StatusBadgeButtonStyle(tint: tint))
    }
}

struct StatusBadgeButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(tint)
            .background(tint.opacity(configuration.isPressed ? 0.2 : 0.12))
            .clipShape(Capsule())
            .transition(.opacity)
    }
}

struct GenderFilterButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isSelected ? .blue : .secondary)
            .background(isSelected ? Color.blue.opacity(0.2) : Color.secondary.opacity(0.08))
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

struct ChannelPreviewCard: View {
    @ObservedObject var manager: ChannelManager
    let info: ChannelInfo
    let isSelected: Bool

    private var isWaitingForRecordingSlot: Bool { info.isWaitingForRecordingSlot }
    private var isWaitingOnline: Bool { isWaitingForRecordingSlot && info.isOnline }
    private var isLive: Bool { info.isOnline && !info.isPaused && !isWaitingForRecordingSlot }
    private var isRecording: Bool { info.isActivelyRecording }
    private var isPausedOnline: Bool { info.isOnline && info.isPaused }
    private var isOffline: Bool { !info.isOnline }
    private var isInvalid: Bool { info.isInvalid }
    private var isDegraded: Bool { info.consecutiveSegmentFailures > 0 }
    private var hasTimelineMismatchAlert: Bool { info.timelineMismatchCount > 0 }
    private var showNoPersonBadge: Bool { info.isOnline && info.isNoPersonDetected && !info.isInvalid }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let thumbnailPath = info.thumbnailPath,
                   FileManager.default.fileExists(atPath: thumbnailPath),
                   let image = NSImage(contentsOfFile: thumbnailPath) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .saturation((isLive || isWaitingOnline) ? 1.0 : (isPausedOnline ? 0.65 : 0.0))
                        .opacity((isLive || isWaitingOnline) ? 1.0 : (isPausedOnline ? 0.82 : 0.45))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
                        .overlay(
                            Group {
                                if isOffline {
                                    Color.black.opacity(0.2)
                                } else if isPausedOnline {
                                    Color.orange.opacity(0.12)
                                } else if isWaitingOnline {
                                    Color.blue.opacity(0.12)
                                }
                            }
                        )
                } else if info.isOnline {
                    ZStack {
                        Rectangle().fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
                        VStack(spacing: 6) {
                            Image(systemName: "video.fill")
                                .font(.title2)
                                .foregroundColor(.secondary)
                            Text("Generating preview...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    ZStack {
                        Rectangle().fill(Color(NSColor.controlBackgroundColor).opacity(0.3))
                        Image(systemName: isInvalid ? "exclamationmark.triangle" : "video.slash")
                            .font(.title2)
                            .foregroundColor(isInvalid ? .red : .secondary)
                    }
                }
            }
            .frame(height: 120)
            .frame(maxWidth: .infinity)
            .clipped()
            .cornerRadius(8)
            .overlay(
                Button(action: {
                    Task {
                        if info.isPaused {
                            await manager.resumeChannel(username: info.username)
                        } else {
                            await manager.pauseChannel(username: info.username)
                        }
                    }
                }) {
                    Image(systemName: info.isPaused ? "play.circle.fill" : "pause.circle.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
                }
                .buttonStyle(.plain)
                .padding(8),
                alignment: .topTrailing
            )
            .overlay(
                Group {
                    if isWaitingForRecordingSlot {
                        Text(info.isOnline ? "Waiting Live" : "Waiting")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.9))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                            .padding(8)
                    } else if isPausedOnline {
                        Text("Paused Live")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.9))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                            .padding(8)
                    } else if isInvalid {
                        Text("Invalid")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.red.opacity(0.9))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                            .padding(8)
                    }
                },
                alignment: .topLeading
            )

            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(info.isInvalid ? Color.red : (info.isPaused ? Color.orange : (info.isOnline ? Color.green : Color.gray)))
                        .frame(width: 10, height: 10)
                    
                    if info.isChecking {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 10, height: 10)
                    }
                }
                .frame(width: 10, height: 10)
                
                Text(info.username)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .layoutPriority(1)
                Spacer()

                Group {
                    if info.isChecking {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Checking")
                        }
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12))
                        .cornerRadius(6)
                    } else {
                        HStack(spacing: 6) {
                            Text(
                                info.isInvalid
                                    ? "Invalid (404)"
                                    : (info.isPaused
                                        ? (info.isOnline ? "Paused (Online)" : "Paused")
                                        : (isWaitingForRecordingSlot
                                            ? (info.isOnline ? "Waiting (Online)" : "Waiting (Rechecking)")
                                            : (isRecording ? "Recording" : (info.isOnline ? "Online" : "Offline"))))
                            )
                                .font(.caption)
                                .foregroundColor(info.isInvalid ? .red : .secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .minimumScaleFactor(0.9)

                            if isDegraded {
                                Text("Degraded")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.14))
                                    .cornerRadius(6)
                            }

                            if hasTimelineMismatchAlert {
                                Text("Timeline x\(info.timelineMismatchCount)")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.red.opacity(0.14))
                                    .cornerRadius(6)
                            }

                            if showNoPersonBadge {
                                Text("No Person \(formatNoPersonDuration(info.noPersonDurationSeconds))")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.14))
                                    .cornerRadius(6)
                                    .lineLimit(1)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }

            HStack(spacing: 10) {
                Label(info.duration, systemImage: "clock")
                Label(info.filesize, systemImage: "doc")
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(height: 16)

            Text("Last online: \(info.lastOnlineAt ?? "-")")
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(NSColor.separatorColor).opacity(0.28), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .shadow(color: Color.black.opacity(isSelected ? 0.14 : 0.08), radius: isSelected ? 5 : 3, x: 0, y: 1)
    }
}

struct ActivitySidebarView: View {
    private struct CombinedLogEntry {
        let sortOrder: Int
        let line: String
        let color: Color
    }

    private enum SlotState {
        case active(ChannelInfo)
        case busyUnknown
        case idle
    }

    @ObservedObject var manager: ChannelManager
    let channelInfos: [ChannelInfo]
    var onSelectChannel: ((String) -> Void)? = nil
    @State private var slotColumnCount: Int = 1
    @State private var showingCombinedLog = true
    @State private var showingManualQueuePlanner = false
    
    var body: some View {
        VStack(spacing: 0) {
            if !manager.backgroundWorkerWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Background Health")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                    }

                    ForEach(manager.backgroundWorkerWarnings, id: \.self) { warning in
                        Text(warning)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(10)
                .padding(.horizontal, 10)
                .padding(.top, 10)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Account")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)

                        HStack(spacing: 10) {
                            if manager.appConfig.authMode == .inAppWebView {
                                if manager.appConfig.hasValidInAppSession() {
                                    Image(systemName: "person.crop.circle.fill")
                                        .font(.title2)
                                        .foregroundColor(.green)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(manager.appConfig.loggedInUsername.isEmpty
                                             ? "Signed In"
                                             : "@\(manager.appConfig.loggedInUsername)")
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                        Text("In-App Session • Active")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                } else {
                                    Image(systemName: "person.crop.circle.badge.xmark")
                                        .font(.title2)
                                        .foregroundColor(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Not Signed In")
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                        Text("Open Settings to sign in")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            } else {
                                Image(systemName: "globe")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Legacy Mode")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Text("Using \(manager.appConfig.selectedBrowser.displayName) cookies")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(10)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recording")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)

                        Toggle(isOn: recordingEnabledBinding) {
                            Label(
                                manager.appConfig.recordingEnabled ? "Recording Enabled" : "Recording Paused",
                                systemImage: manager.appConfig.recordingEnabled ? "record.circle.fill" : "record.circle"
                            )
                            .font(.title3)
                            .foregroundStyle(manager.appConfig.recordingEnabled ? Color.red : Color.orange)
                        }
                        .toggleStyle(.switch)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Recording Slots")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(slotCountLabel)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }

                            HStack(spacing: 8) {
                                Button {
                                    adjustSlotLimit(by: -1)
                                } label: {
                                    Image(systemName: "minus")
                                        .frame(width: 18)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(isUnlimitedSlots || finiteSlotCount <= 1)

                                Text("Max concurrent recordings: \(finiteSlotCount)")
                                    .font(.callout)

                                Button {
                                    adjustSlotLimit(by: 1)
                                } label: {
                                    Image(systemName: "plus")
                                        .frame(width: 18)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(isUnlimitedSlots || finiteSlotCount >= 12)

                                Spacer(minLength: 0)

                                Button {
                                    toggleUnlimitedSlots()
                                } label: {
                                    Text("Unlimited")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(isUnlimitedSlots ? .accentColor : .secondary)
                            }

                            if isUnlimitedSlots {
                                Text("Unlimited mode: visualizing first \(visualizedSlotCount) slots")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }

                        LazyVGrid(columns: slotGridColumns, spacing: 6) {
                            ForEach(0..<visualizedSlotCount, id: \.self) { index in
                                recordingSlotRow(for: index)
                            }
                        }

                        VStack(spacing: 6) {
                            HStack {
                                Text("In use: \(activeRecordingCount)")
                                    .font(.footnote)
                                    .foregroundColor(.green)
                                Spacer()
                                Text("Idle: \(idleSlotCount)")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }

                            Text("Queued: \(manager.runtimeDiagnostics.queuedRecordings)")
                                .font(.footnote)
                                .foregroundColor(manager.runtimeDiagnostics.queuedRecordings > 0 ? .blue : .secondary)

                            Button {
                                showingManualQueuePlanner = true
                            } label: {
                                Label("Manage Slots & Queue", systemImage: "arrow.up.arrow.down.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(10)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(10)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Request Slots")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)

                        HStack(spacing: 8) {
                            Button {
                                adjustRequestSlotLimit(by: -1)
                            } label: {
                                Image(systemName: "minus")
                                    .frame(width: 18)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(requestSlotLimit <= 1)

                            Text("Max concurrent requests: \(requestSlotLimit)")
                                .font(.callout)

                            Button {
                                adjustRequestSlotLimit(by: 1)
                            } label: {
                                Image(systemName: "plus")
                                    .frame(width: 18)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(requestSlotLimit >= 24)

                            Spacer(minLength: 0)
                        }

                        LazyVGrid(columns: slotGridColumns, spacing: 6) {
                            ForEach(0..<visualizedRequestSlotCount, id: \.self) { index in
                                requestSlotRow(for: index)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Queued: \(manager.runtimeDiagnostics.queuedRequests)")
                                .font(.footnote)
                                .foregroundColor(manager.runtimeDiagnostics.queuedRequests > 0 ? .blue : .secondary)

                            Text("Avg wait: \(manager.runtimeDiagnostics.averageQueueWaitMs)ms")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(10)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(10)

                }
                .padding(10)
            }
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            updateSlotColumnCount(for: geometry.size.width)
                        }
                        .onChange(of: geometry.size.width) { newWidth in
                            updateSlotColumnCount(for: newWidth)
                        }
                }
            )

            Divider()

            DisclosureGroup(isExpanded: $showingCombinedLog) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if combinedLogEntries.isEmpty {
                            Text("No activity yet")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(Array(combinedLogEntries.enumerated()), id: \.offset) { _, entry in
                                Text(entry.line)
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundColor(entry.color)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: 220)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(8)
            } label: {
                HStack {
                    Text("Activity Feed")
                        .font(.headline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(combinedLogEntries.count)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .navigationTitle("Activity")
        .sheet(isPresented: $showingManualQueuePlanner) {
            ManualQueuePlannerSheet(manager: manager, channelInfos: channelInfos)
        }
    }

    private var combinedLogEntries: [CombinedLogEntry] {
        let merged = channelInfos.flatMap { info in
            info.logs.suffix(5).map { log in
                CombinedLogEntry(
                    sortOrder: sortKey(from: log),
                    line: "[\(info.username)] \(log)",
                    color: colorForLog(log, info: info)
                )
            }
        }

        return Array(
            merged
                .sorted { lhs, rhs in
                    if lhs.sortOrder == rhs.sortOrder {
                        return lhs.line > rhs.line
                    }
                    return lhs.sortOrder > rhs.sortOrder
                }
                .prefix(60)
        )
    }

    private func sortKey(from log: String) -> Int {
        let timestamp = String(log.prefix(5))
        let parts = timestamp.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else {
            return -1
        }
        return (hour * 60) + minute
    }

    private func colorForLog(_ log: String, info: ChannelInfo) -> Color {
        let lower = log.lowercased()

        if lower.contains("error") || lower.contains("blocked") {
            return .red
        }
        if lower.contains("check") || lower.contains("probing") {
            return .accentColor
        }
        if lower.contains("online") {
            return .green
        }
        if lower.contains("offline") {
            return .gray
        }

        if info.isChecking {
            return .accentColor
        }
        if info.isPaused {
            return .orange
        }
        if info.isOnline {
            return .green
        }
        return .secondary
    }

    private var recordingEnabledBinding: Binding<Bool> {
        Binding(
            get: { manager.appConfig.recordingEnabled },
            set: { newValue in
                manager.appConfig.recordingEnabled = newValue
                manager.saveAppConfig()
            }
        )
    }

    private var activeRecordingCount: Int {
        manager.runtimeDiagnostics.activeRecordings
    }

    private var recordingChannels: [ChannelInfo] {
        channelInfos
            .filter {
                $0.isActivelyRecording &&
                !$0.isInvalid
            }
            .sorted { $0.username.localizedStandardCompare($1.username) == .orderedAscending }
    }

    private var requestActiveChannels: [ChannelInfo] {
        channelInfos
            .filter { $0.isChecking }
            .sorted { $0.username.localizedStandardCompare($1.username) == .orderedAscending }
    }

    private var isUnlimitedSlots: Bool {
        manager.appConfig.maxConcurrentRecordings == 0
    }

    private var finiteSlotCount: Int {
        isUnlimitedSlots ? 4 : max(manager.appConfig.maxConcurrentRecordings, 1)
    }

    private var displayedSlotCapacity: Int {
        if manager.appConfig.maxConcurrentRecordings == 0 {
            return max(4, activeRecordingCount)
        }
        return max(manager.appConfig.maxConcurrentRecordings, 1)
    }

    private var visualizedSlotCount: Int {
        min(displayedSlotCapacity, 12)
    }

    private var idleSlotCount: Int {
        max(0, visualizedSlotCount - min(activeRecordingCount, visualizedSlotCount))
    }

    private var requestSlotLimit: Int {
        max(1, manager.appConfig.maxConcurrentRequests)
    }

    private var visualizedRequestSlotCount: Int {
        min(requestSlotLimit, 12)
    }

    private var slotCountLabel: String {
        isUnlimitedSlots ? "Unlimited" : "\(manager.appConfig.maxConcurrentRecordings)"
    }

    private var slotGridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 150), spacing: 6, alignment: .top),
            count: slotColumnCount
        )
    }

    private func recordingSlotState(at index: Int) -> SlotState {
        if index < recordingChannels.count {
            return .active(recordingChannels[index])
        }
        if index < min(activeRecordingCount, visualizedSlotCount) {
            return .busyUnknown
        }
        return .idle
    }

    private func requestSlotState(at index: Int) -> SlotState {
        if index < requestActiveChannels.count {
            return .active(requestActiveChannels[index])
        }
        if index < min(manager.runtimeDiagnostics.activeRequests, visualizedRequestSlotCount) {
            return .busyUnknown
        }
        return .idle
    }

    @ViewBuilder
    private func recordingSlotRow(for index: Int) -> some View {
        let state = recordingSlotState(at: index)
        switch state {
        case .active(let info):
            Button {
                onSelectChannel?(info.username)
            } label: {
                slotRowContent(
                    primary: info.username,
                    secondary: "recording",
                    trailing: "\(info.duration) • \(info.filesize)",
                    accent: .green,
                    isInteractive: true
                )
            }
            .buttonStyle(.plain)
            .help("Open \(info.username)")
        case .busyUnknown:
            slotRowContent(
                primary: "Recording in progress",
                secondary: "syncing details",
                trailing: nil,
                accent: .green,
                isInteractive: false
            )
        case .idle:
            slotRowContent(
                primary: "Idle",
                secondary: "available",
                trailing: nil,
                accent: .secondary,
                isInteractive: false
            )
        }
    }

    @ViewBuilder
    private func requestSlotRow(for index: Int) -> some View {
        let state = requestSlotState(at: index)
        switch state {
        case .active(let info):
            Button {
                onSelectChannel?(info.username)
            } label: {
                slotRowContent(
                    primary: info.username,
                    secondary: "checking",
                    trailing: info.isOnline ? "online" : "offline",
                    accent: .accentColor,
                    isInteractive: true
                )
            }
            .buttonStyle(.plain)
            .help("Open \(info.username)")
        case .busyUnknown:
            slotRowContent(
                primary: "Busy",
                secondary: "request in progress",
                trailing: nil,
                accent: .accentColor,
                isInteractive: false
            )
        case .idle:
            slotRowContent(
                primary: "Idle",
                secondary: "available",
                trailing: nil,
                accent: .secondary,
                isInteractive: false
            )
        }
    }

    private func slotRowContent(
        primary: String,
        secondary: String,
        trailing: String?,
        accent: Color,
        isInteractive: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(accent.opacity(0.9))
                .frame(width: 8, height: 8)

            HStack(spacing: 8) {
                Text(primary)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(secondary)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let trailing {
                Text(trailing)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if isInteractive {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(NSColor.textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(NSColor.separatorColor).opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func adjustSlotLimit(by delta: Int) {
        let next = max(1, min(12, finiteSlotCount + delta))
        manager.appConfig.maxConcurrentRecordings = next
        manager.saveAppConfig()
    }

    private func adjustRequestSlotLimit(by delta: Int) {
        let next = max(1, min(24, requestSlotLimit + delta))
        manager.appConfig.maxConcurrentRequests = next
        manager.saveAppConfig()
    }

    private func toggleUnlimitedSlots() {
        if isUnlimitedSlots {
            manager.appConfig.maxConcurrentRecordings = 4
        } else {
            manager.appConfig.maxConcurrentRecordings = 0
        }
        manager.saveAppConfig()
    }

    private func updateSlotColumnCount(for width: CGFloat) {
        let nextCount = width >= 520 ? 2 : 1
        guard nextCount != slotColumnCount else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            slotColumnCount = nextCount
        }
    }
}

struct ChannelDetailView: View {
    @ObservedObject var manager: ChannelManager
    let username: String
    let initialInfo: ChannelInfo?
    let refreshGeneration: Int
    var onPrevious: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil
    var canGoPrevious: Bool = false
    var canGoNext: Bool = false
    var onEdit: (() -> Void)? = nil
    var onDeleted: (() -> Void)? = nil
    var onOpenRecording: ((String, [String]) -> Void)? = nil
    @State private var info: ChannelInfo?
    @State private var timer: Timer?
    @State private var showingDeleteConfirmation = false
    @State private var recordingsCache: [RecordingLedgerEntry] = []
    @State private var recordingsScanTask: Task<Void, Never>?
    @State private var lastRecordingsScanKey: String = ""
    @State private var showingChannelPage = false
    @State private var isDetailProbeInFlight = false
    @State private var lastDetailProbeAt = Date.distantPast

    private let detailProbeInterval: TimeInterval = 5

    init(
        manager: ChannelManager,
        username: String,
        initialInfo: ChannelInfo? = nil,
        refreshGeneration: Int = 0,
        onPrevious: (() -> Void)? = nil,
        onNext: (() -> Void)? = nil,
        canGoPrevious: Bool = false,
        canGoNext: Bool = false,
        onEdit: (() -> Void)? = nil,
        onDeleted: (() -> Void)? = nil,
        onOpenRecording: ((String, [String]) -> Void)? = nil
    ) {
        self.manager = manager
        self.username = username
        self.initialInfo = initialInfo
        self.refreshGeneration = refreshGeneration
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.canGoPrevious = canGoPrevious
        self.canGoNext = canGoNext
        self.onEdit = onEdit
        self.onDeleted = onDeleted
        self.onOpenRecording = onOpenRecording
        _info = State(initialValue: initialInfo)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            channelBody
        }
        .navigationTitle(username)
        .onAppear {
            updateInfo()
            refreshRecordingsCacheIfNeeded(force: true)
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                updateInfo()
            }
        }
        .onChange(of: info?.recordingsDirectory ?? "") { _ in
            refreshRecordingsCacheIfNeeded(force: true)
        }
        .onChange(of: info?.recordings.count ?? 0) { _ in
            refreshRecordingsCacheIfNeeded(force: false)
        }
        .onChange(of: info?.filename ?? "") { _ in
            refreshRecordingsCacheIfNeeded(force: false)
        }
        .onChange(of: refreshGeneration) { _ in
            refreshRecordingsCacheIfNeeded(force: true)
        }
        .onDisappear {
            timer?.invalidate()
            recordingsScanTask?.cancel()
        }
        .alert("Delete Channel?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await manager.deleteChannel(username: username)
                    await MainActor.run {
                        onDeleted?()
                    }
                }
            }
        } message: {
            Text("This removes the channel from the app. Existing recording files are kept on disk.")
        }
        .sheet(isPresented: $showingChannelPage) {
            ChaturbateChannelPageSheet(username: username, cookies: manager.appConfig.inAppCookies, isPresented: $showingChannelPage)
        }
    }

    @ViewBuilder
    private var channelBody: some View {
        if let info {
            channelContent(info: info)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func channelContent(info: ChannelInfo) -> some View {
        GeometryReader { geometry in
            let detailWidth = responsiveDetailWidth(totalWidth: geometry.size.width)
            let activityLogHeight = min(max(geometry.size.height * 0.22, 120), 190)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Live Preview")
                            .font(.headline)

                        previewView(info: info)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(info.isOnline ? Color.green : Color.gray.opacity(0.35), lineWidth: 2)
                            )
                    }

                    activityLogSection(info: info)
                        .frame(height: activityLogHeight)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .top)

                channelDetailsPanel(info: info)
                    .frame(width: detailWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(minHeight: 520)
        .padding(20)
    }

    @ViewBuilder
    private func activityLogSection(info: ChannelInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Activity Log")
                    .font(.headline)

                Spacer(minLength: 0)

                Button(action: { copyActivityLogs(info.logs) }) {
                    Label("Copy Logs", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(info.logs.isEmpty)
            }

            ScrollView {
                Text(info.logs.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .padding(10)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func channelDetailsPanel(info: ChannelInfo) -> some View {
        let sidebarHorizontalInset: CGFloat = 4

        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Channel Details")
                        .font(.headline)

                    HStack(spacing: 8) {
                        Button(action: { onPrevious?() }) {
                            Label("Previous", systemImage: "chevron.left")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canGoPrevious)

                        Button(action: { onNext?() }) {
                            Label("Next", systemImage: "chevron.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canGoNext)
                    }

                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusIndicatorColor(info: info))
                            .frame(width: 10, height: 10)
                        Text(statusLabel(info: info))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(info.isInvalid ? .red : .primary)
                            .lineLimit(1)

                        if info.consecutiveSegmentFailures > 0 {
                            Text("Degraded")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.orange)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.14))
                                .cornerRadius(6)
                        }

                        if info.timelineMismatchCount > 0 {
                            Text("Timeline Mismatch x\(info.timelineMismatchCount)")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.red)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.14))
                                .cornerRadius(6)
                        }

                        if info.isOnline && info.isNoPersonDetected && !info.isInvalid {
                            Text("No Person \(formatNoPersonDuration(info.noPersonDurationSeconds))")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.orange)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.14))
                                .cornerRadius(6)
                                .lineLimit(1)
                        }
                    }

                    ChannelInfoView(info: info)

                    BioMetadataView(info: info, manager: manager, username: username)

                    recordingsSection(info: info)
                }
                .padding(.horizontal, sidebarHorizontalInset)
            }
            .frame(maxHeight: .infinity)

            VStack(spacing: 8) {
                Button(action: {
                    showingChannelPage = true
                }) {
                    Label("Open Channel In App", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: {
                    Task {
                        await manager.openRecordingFolder(username: username)
                    }
                }) {
                    Label("Open Recordings Folder", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                HStack(spacing: 8) {
                    if info.isPaused {
                        Button(action: {
                            Task {
                                await manager.resumeChannel(username: username)
                            }
                        }) {
                            Label("Resume", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Button(action: {
                            Task {
                                await manager.pauseChannel(username: username)
                            }
                        }) {
                            Label("Pause", systemImage: "pause.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button(action: { onEdit?() }) {
                        Label("Edit", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, sidebarHorizontalInset)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func statusLabel(info: ChannelInfo) -> String {
        if info.isInvalid {
            return "Invalid (404)"
        }
        if info.isWaitingForRecordingSlot {
            return info.isOnline ? "Waiting Live" : "Offline"
        }
        if info.isPaused {
            return info.isOnline ? "Paused (Online)" : "Paused"
        }
        if info.isActivelyRecording {
            return "Recording"
        }
        if info.isOnline {
            return "Online"
        }
        return "Offline"
    }

    private func statusIndicatorColor(info: ChannelInfo) -> Color {
        if info.isInvalid {
            return .red
        }
        if info.isWaitingForRecordingSlot {
            return info.isOnline ? .blue : .gray
        }
        if info.isPaused {
            return .orange
        }
        if info.isActivelyRecording {
            return .green
        }
        if info.isOnline {
            return .mint
        }
        return .gray
    }
    
    private func updateInfo() {
        Task { @MainActor in
            let preservedThumbnailPath = info?.thumbnailPath ?? initialInfo?.thumbnailPath

            if var refreshed = await manager.getChannelInfo(username: username) {
                if refreshed.thumbnailPath == nil,
                   let preservedThumbnailPath,
                   FileManager.default.fileExists(atPath: preservedThumbnailPath) {
                    refreshed.thumbnailPath = preservedThumbnailPath
                }
                info = refreshed

                if shouldRunDetailProbe(for: refreshed) {
                    isDetailProbeInFlight = true
                    lastDetailProbeAt = Date()

                    let shouldRefreshPausedThumbnail = refreshed.isOnline
                        && (refreshed.isPaused || !refreshed.globalRecordingEnabled)

                    if let probed = await manager.refreshChannelStatusForDetail(
                        username: username,
                        refreshPausedThumbnail: shouldRefreshPausedThumbnail
                    ) {
                        info = probed
                    }

                    isDetailProbeInFlight = false
                }
            }

            refreshRecordingsCacheIfNeeded(force: false)
        }
    }

    private func shouldRunDetailProbe(for info: ChannelInfo) -> Bool {
        guard !isDetailProbeInFlight else { return false }
        guard Date().timeIntervalSince(lastDetailProbeAt) >= detailProbeInterval else { return false }

        // Prioritize probing cases where stale online state is most visible in detail view.
        return info.isOnline || info.isWaitingForRecordingSlot || info.liveStreamURL != nil
    }

    @ViewBuilder
    private func recordingsSection(info: ChannelInfo) -> some View {
        let entries = recordingsCache
        let activeCount = entries.filter(\ .isActive).count
        let missingCount = entries.filter { !$0.fileExists && !$0.isActive && !$0.isFinalizing }.count

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recordings")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Spacer()
            }

            HStack(spacing: 4) {
                Text("\(entries.count) recording\(entries.count == 1 ? "" : "s") in ledger")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("• active \(activeCount)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if missingCount > 0 {
                    Text("• missing \(missingCount)")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            if entries.isEmpty {
                Text("No recordings found for this channel in the recording ledger")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(entries, id: \.path) { entry in
                            Button {
                                onOpenRecording?(entry.path, entries.map(\ .path))
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text((entry.path as NSString).lastPathComponent)
                                            .font(.system(.caption, design: .monospaced))
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)

                                        HStack(spacing: 6) {
                                            Text(recordingStatusLabel(for: entry))
                                                .font(.caption2)
                                                .foregroundColor(recordingStatusColor(for: entry))
                                            Text(recordingDateText(for: entry.modifiedAt))
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                            Text(recordingSizeText(for: entry.fileSizeBytes))
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }

                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 220)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func refreshRecordingsCacheIfNeeded(force: Bool) {
        guard let info else {
            recordingsCache = []
            lastRecordingsScanKey = ""
            return
        }

        let scanKey = [
            info.username,
            info.filename ?? "",
            String(info.isOnline),
            String(info.isPaused)
        ].joined(separator: "|")

        if !force, scanKey == lastRecordingsScanKey {
            return
        }

        lastRecordingsScanKey = scanKey
        recordingsScanTask?.cancel()

        let username = info.username
        recordingsScanTask = Task(priority: .utility) {
            let scanned = await manager.getChannelRecordingEntries(username: username, includeMissing: true)
            if Task.isCancelled { return }

            await MainActor.run {
                recordingsCache = scanned
            }
        }
    }

    private func recordingStatusLabel(for entry: RecordingLedgerEntry) -> String {
        if entry.isActive {
            return "Recording"
        }
        if entry.isFinalizing {
            return "Finalizing"
        }
        if entry.status == "deleted" {
            return "Deleted"
        }
        if !entry.fileExists {
            return "Missing"
        }
        return entry.status.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func recordingStatusColor(for entry: RecordingLedgerEntry) -> Color {
        if entry.isActive {
            return .green
        }
        if entry.isFinalizing {
            return .orange
        }
        if entry.status == "deleted" {
            return .secondary
        }
        if !entry.fileExists {
            return .orange
        }
        return .secondary
    }

    private func recordingDateText(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func recordingSizeText(for bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func responsiveDetailWidth(totalWidth: CGFloat) -> CGFloat {
        let target = totalWidth * 0.29
        return min(max(target, 300), 380)
    }

    private func copyActivityLogs(_ logs: [String]) {
        guard !logs.isEmpty else { return }
        let text = logs.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @ViewBuilder
    private func previewView(info: ChannelInfo) -> some View {
        ChannelLivePreviewView(
            manager: manager,
            username: username,
            streamURL: info.liveStreamURL,
            thumbnailPath: info.thumbnailPath,
            isOnline: info.isOnline
        )
    }
}

private struct ChannelLivePreviewView: View {
    let manager: ChannelManager
    let username: String
    let streamURL: String?
    let thumbnailPath: String?
    let isOnline: Bool

    @State private var player: AVPlayer?
    @State private var currentStreamURL: String?
    @State private var failedToPlayObserver: NSObjectProtocol?
    @State private var playbackStalledObserver: NSObjectProtocol?
    @State private var playerItemStatusObserver: NSKeyValueObservation?
    @State private var recoveryTask: Task<Void, Never>?
    @State private var isRecovering = false
    @State private var lastRecoveryAt = Date.distantPast
    @State private var recoveryAttempts = 0
    @State private var streamUnavailable = false

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .onAppear {
                        player.play()
                    }
                if isRecovering {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Recovering stream...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            } else if let thumbnailPath,
                      FileManager.default.fileExists(atPath: thumbnailPath),
                      let nsImage = NSImage(contentsOfFile: thumbnailPath) {
                ZStack {
                    Color(NSColor.controlBackgroundColor).opacity(0.3)

                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .saturation(isOnline ? 1.0 : 0.0)
                        .opacity(isOnline ? 1.0 : 0.45)
                        .overlay(
                            Group {
                                if !isOnline {
                                    Color.black.opacity(0.2)
                                }
                            }
                        )
                }
            } else if isOnline {
                ZStack {
                    Rectangle()
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    VStack(spacing: 8) {
                        if streamUnavailable {
                            Image(systemName: "wifi.exclamationmark")
                                .font(.title2)
                                .foregroundColor(.secondary)
                            Text("Live stream unavailable")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Channel may be offline. Status will update shortly.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                            Text("Waiting for stream...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } else {
                ZStack {
                    Rectangle()
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.3))
                    Image(systemName: "video.slash")
                        .font(.title)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16/9, contentMode: .fit)
        .clipped()
        .cornerRadius(10)
        .task(id: isOnline) {
            guard isOnline else {
                resetPlayerState()
                return
            }

            if streamURL != nil {
                streamUnavailable = false
            }
            await configurePlayerIfNeeded()
        }
        .onChange(of: streamURL) { newValue in
            guard isOnline else { return }
            if newValue != nil {
                streamUnavailable = false
            }

            // Ignore routine URL churn while playback is healthy to avoid flashing.
            guard player == nil || isRecovering || streamUnavailable else { return }
            Task { @MainActor in
                await configurePlayerIfNeeded()
            }
        }
        .onChange(of: isOnline) { online in
            if !online {
                resetPlayerState()
            } else {
                streamUnavailable = false
            }
        }
        .onDisappear {
            resetPlayerState()
        }
    }

    @MainActor
    private func configurePlayerIfNeeded(using overrideStreamURL: String? = nil, forceReplace: Bool = false) async {
        guard isOnline,
              let candidateURLString = overrideStreamURL ?? streamURL,
              let url = URL(string: candidateURLString) else {
            resetPlayerState()
            return
        }

        if !forceReplace,
           let player,
           player.timeControlStatus == .playing || player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            currentStreamURL = candidateURLString
            return
        }

        guard currentStreamURL != candidateURLString || forceReplace else {
            if player?.timeControlStatus != .playing {
                player?.play()
            }
            return
        }

        // Rebuild player item on URL refresh/failure to recover from stale HLS manifests.
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPUserAgentKey": manager.appConfig.getUserAgent()
        ])
        let item = AVPlayerItem(asset: asset)

        playerItemStatusObserver?.invalidate()
        playerItemStatusObserver = item.observe(\ .status, options: [.initial, .new]) { _, _ in
            if item.status == .failed {
                Task { @MainActor in
                    scheduleRecovery(reason: item.error?.localizedDescription ?? "player item failed")
                }
            }
        }

        if let failedToPlayObserver {
            NotificationCenter.default.removeObserver(failedToPlayObserver)
        }
        failedToPlayObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { note in
            let nsError = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            let reason = nsError?.localizedDescription ?? "failed to play to end"
            Task { @MainActor in
                scheduleRecovery(reason: reason)
            }
        }

        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(playbackStalledObserver)
        }
        playbackStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                scheduleRecovery(reason: "playback stalled")
            }
        }

        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = true
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        newPlayer.play()

        player?.pause()
        player = newPlayer
        currentStreamURL = candidateURLString
        isRecovering = false
        recoveryAttempts = 0
        streamUnavailable = false
    }

    @MainActor
    private func scheduleRecovery(reason _: String) {
        guard isOnline else { return }

        // Avoid retry storms when AVPlayer emits multiple back-to-back failures.
        if Date().timeIntervalSince(lastRecoveryAt) < 1.2 {
            return
        }
        lastRecoveryAt = Date()
        isRecovering = true
        recoveryAttempts += 1

        if recoveryAttempts >= 4 {
            streamUnavailable = true
            resetPlayerState()
            return
        }

        recoveryTask?.cancel()
        recoveryTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            if Task.isCancelled { return }

            let refreshed = await manager.refreshLiveStreamURL(username: username)
            if Task.isCancelled { return }

            if refreshed == nil {
                await MainActor.run {
                    streamUnavailable = true
                    resetPlayerState()
                }
                return
            }

            await configurePlayerIfNeeded(using: refreshed, forceReplace: true)
        }
    }

    @MainActor
    private func resetPlayerState() {
        recoveryTask?.cancel()
        recoveryTask = nil

        if let failedToPlayObserver {
            NotificationCenter.default.removeObserver(failedToPlayObserver)
            self.failedToPlayObserver = nil
        }
        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(playbackStalledObserver)
            self.playbackStalledObserver = nil
        }
        playerItemStatusObserver?.invalidate()
        playerItemStatusObserver = nil

        player?.pause()
        player = nil
        currentStreamURL = nil
        isRecovering = false
    }
}

struct RecordingDetailView: View {
    @ObservedObject var manager: ChannelManager
    let recordingPath: String
    let preferredChannelUsername: String?
    let navigationPaths: [String]
    let backLabel: String
    let onBack: () -> Void
    let onOpenChannel: (String) -> Void
    let onSelectRecording: (String, String?) -> Void
    var onMoveToTrash: ((String) -> Void)? = nil

    @State private var detail: RecordingLedgerDetail?
    @State private var siblingEntries: [RecordingLedgerEntry] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var player: AVPlayer?
    @State private var playerStatusObserver: NSKeyValueObservation?
    @State private var playerLoadTask: Task<Void, Never>?
    @State private var isPreparingPlayer = false
    @State private var playerError: String?
    @State private var posterImage: NSImage?
    @State private var posterLoadTask: Task<Void, Never>?
    @State private var channelThumbnailPath: String?

    private enum PlayerPreparationError: LocalizedError {
        case timedOut

        var errorDescription: String? {
            switch self {
            case .timedOut:
                return "Video preparation timed out. The file may be very large or partially unreadable."
            }
        }
    }

    private static let metadataDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let eventDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let fileSizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        Group {
            if isLoading && detail == nil {
                ProgressView("Loading recording...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let detail {
                recordingDetailBody(detail)
            } else if let loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundColor(.orange)
                    Text("Could not load recording")
                        .font(.headline)
                    Text(loadError)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button(backLabel, action: onBack)
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ProgressView("Loading recording...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: recordingPath) {
            await loadRecordingDetail()
        }
        .onDisappear {
            cleanupPlayer()
        }
    }

    @ViewBuilder
    private func recordingDetailBody(_ detail: RecordingLedgerDetail) -> some View {
        GeometryReader { geometry in
            let sideWidth = min(max(geometry.size.width * 0.31, 320), 420)

            VStack(alignment: .leading, spacing: 0) {
                header(detail)

                Divider()

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        playerSection(detail)
                        eventsSection(detail)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            metadataSection(detail)
                            metricsSection(detail)
                            fileSection(detail)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                    .frame(width: sideWidth)
                }
                .padding(20)
            }
        }
    }

    @ViewBuilder
    private func header(_ detail: RecordingLedgerDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(URL(fileURLWithPath: detail.path).lastPathComponent)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text(detail.channelUsername)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        statusBadge(label: recordingStatusLabel(detail), color: recordingStatusColor(detail))
                        statusBadge(label: detail.fileExtension.uppercased(), color: .accentColor)
                        if detail.isRemuxed {
                            statusBadge(label: "Remuxed", color: .mint)
                        }
                        if detail.isBackfilled {
                            statusBadge(label: "Backfilled", color: .secondary)
                        }
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Button(backLabel, action: onBack)
                        .buttonStyle(.bordered)

                    Button {
                        onOpenChannel(detail.channelUsername)
                    } label: {
                        Label("Open Channel", systemImage: "person.crop.square")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        selectSibling(offset: -1)
                    } label: {
                        Label("Previous", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .disabled(previousSiblingPath == nil)

                    Button {
                        selectSibling(offset: 1)
                    } label: {
                        Label("Next", systemImage: "chevron.right")
                    }
                    .buttonStyle(.bordered)
                    .disabled(nextSiblingPath == nil)
                }
            }

            HStack(spacing: 8) {
                if shouldAllowPlayback(detail) {
                    Button {
                        togglePlayback()
                    } label: {
                        Label(isPlayerPlaying ? "Pause" : "Play", systemImage: isPlayerPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(player == nil)

                    Button {
                        reloadPlayer()
                    } label: {
                        Label("Reload Video", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isPreparingPlayer || !detail.fileExists)
                }

                Button {
                    revealRecordingInFinder(detail.path)
                } label: {
                    Label("Reveal File", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .disabled(!detail.fileExists)

                Button {
                    openRecordingFolder(detail.path)
                } label: {
                    Label("Open Folder", systemImage: "folder.badge.gearshape")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    moveRecordingToTrash(detail)
                } label: {
                    Label("Move To Trash", systemImage: "trash")
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private func playerSection(_ detail: RecordingLedgerDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shouldAllowPlayback(detail) ? "Playback" : "Preview")
                .font(.headline)

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.4))

                if let posterImage {
                    Image(nsImage: posterImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .opacity(player == nil ? 0.95 : 0.75)
                }

                if player == nil, posterImage != nil {
                    Rectangle()
                        .fill(Color.black.opacity(0.26))
                        .background(.ultraThinMaterial)
                }

                if let player {
                    RecordingPlayerView(player: player, videoGravity: .resizeAspectFill)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if let playerError, player == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundColor(.orange)
                        Text(playerError)
                            .font(.caption)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if isPreparingPlayer, player == nil {
                    VStack(spacing: 10) {
                        ProgressView("Preparing video...")
                            .tint(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if !detail.fileExists, player == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "tray")
                            .font(.title2)
                            .foregroundColor(.white)
                        Text("The recording file is missing from disk.")
                            .font(.caption)
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if !shouldAllowPlayback(detail), player == nil {
                    VStack(spacing: 10) {
                        Image(systemName: detail.isFinalizing ? "hourglass" : "record.circle")
                            .font(.title2)
                            .foregroundColor(.white)
                        Text(detail.isFinalizing
                                ? "Finalization is still in progress. Playback will be available when the file is complete."
                                : "This recording is still in progress. Playback is disabled until the file is finalized.")
                            .font(.caption)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if player == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "video")
                            .font(.title2)
                            .foregroundColor(.white)
                        Text("Poster image is shown first. Press Play when ready.")
                            .font(.caption)
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)

            if let playerError {
                Text(playerError)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func eventsSection(_ detail: RecordingLedgerDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recording Events")
                    .font(.subheadline)
                Spacer(minLength: 0)
                Text("\(detail.events.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if detail.events.isEmpty {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.32))
                    .overlay(
                        Text("No recording events captured for this entry.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    )
                    .frame(height: 108)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(detail.events.prefix(120)) { event in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    statusBadge(label: event.level.uppercased(), color: eventLevelColor(event.level))
                                    Text(Self.eventDateFormatter.string(from: event.createdAt))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(event.eventType)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }

                                Text(event.message)
                                    .font(.caption2)
                                    .foregroundColor(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .textSelection(.enabled)

                                if let metadataJSON = event.metadataJSON, !metadataJSON.isEmpty {
                                    Text(metadataJSON)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color(NSColor.textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                .frame(height: 168)
            }
        }
    }

    @ViewBuilder
    private func metadataSection(_ detail: RecordingLedgerDetail) -> some View {
        let recordingPeriod: Double? = {
            guard let s = detail.startedAt, let e = detail.endedAt else { return nil }
            let v = e.timeIntervalSince(s)
            return v > 0 ? v : nil
        }()
        let durationDelta: Double? = recordingPeriod.map { detail.durationSeconds - $0 }
        let deltaAbsSignificant = durationDelta.map { abs($0) > 5 } ?? false

        detailCard(title: "Metadata") {
            metadataRow("Channel", detail.channelUsername)
            metadataRow("Status", recordingStatusLabel(detail))
            metadataRow("Format", detail.fileExtension.uppercased())
            metadataRow("Duration", formatDuration(detail.durationSeconds))
            if let period = recordingPeriod {
                metadataRow("Recording Period", formatDuration(period))
            }
            if let delta = durationDelta {
                metadataRow("Duration Delta", formatSignedDuration(delta), valueColor: deltaAbsSignificant ? .red : .primary)
                metadataRow("Duration Audit",
                    deltaAbsSignificant
                        ? "Mismatch (\(formatDuration(abs(delta))) delta)"
                        : "OK",
                    valueColor: deltaAbsSignificant ? .red : .green)
            }
            metadataRow("File Size", Self.fileSizeFormatter.string(fromByteCount: detail.fileSizeBytes))
            metadataRow("Audio", audioPresenceLabel(detail.audioPresent))
            metadataRow("Started", formatOptionalDate(detail.startedAt))
            metadataRow("Ended", formatOptionalDate(detail.endedAt))
            metadataRow("Modified", formatOptionalDate(detail.fileLastModifiedAt))
            metadataRow("Last Seen", formatOptionalDate(detail.fileLastSeenAt))
            metadataRow("Missing Since", formatOptionalDate(detail.missingSince))
            metadataRow("First Person", formatOptionalDate(detail.firstPersonDetectedAt))
            metadataRow("Last Person", formatOptionalDate(detail.lastPersonDetectedAt))
            metadataRow("Remuxed At", formatOptionalDate(detail.remuxedAt))
        }
    }

    @ViewBuilder
    private func metricsSection(_ detail: RecordingLedgerDetail) -> some View {
        detailCard(title: "Runtime Counters") {
            metadataRow("No Person Duration", formatNoPersonDuration(detail.noPersonDurationSeconds))
            metadataRow("Segment Retries", "\(detail.segmentRetryCount)")
            metadataRow("Consecutive Failures", "\(detail.consecutiveSegmentFailures)")
            metadataRow("Cloudflare Blocks", "\(detail.cloudflareBlockCount)")
            metadataRow("Timeline Mismatches", "\(detail.timelineMismatchCount)")
            metadataRow("File Exists", detail.fileExists ? "Yes" : "No")
            metadataRow("Backfilled", detail.isBackfilled ? "Yes" : "No")
            metadataRow("Remuxed", detail.isRemuxed ? "Yes" : "No")
        }
    }

    @ViewBuilder
    private func fileSection(_ detail: RecordingLedgerDetail) -> some View {
        detailCard(title: "Paths") {
            metadataBlock("File Path", detail.path)
            if let workingFilePath = detail.workingFilePath, !workingFilePath.isEmpty {
                metadataBlock("Working File", workingFilePath)
            }
        }
    }

    @ViewBuilder
    private func detailCard(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.34))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func metadataRow(_ title: String, _ value: String, valueColor: Color = .primary) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 112, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundColor(valueColor)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func formatSignedDuration(_ seconds: Double) -> String {
        let prefix = seconds < 0 ? "-" : "+"
        return "\(prefix)\(formatDuration(abs(seconds)))"
    }

    @ViewBuilder
    private func metadataBlock(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func loadRecordingDetail() async {
        isLoading = true
        loadError = nil

        playerLoadTask?.cancel()
        await MainActor.run {
            cleanupPlayer()
            posterLoadTask?.cancel()
            posterImage = nil
            channelThumbnailPath = nil
        }

        guard let loadedDetail = await manager.getRecordingDetail(path: recordingPath) else {
            await MainActor.run {
                detail = nil
                siblingEntries = []
                loadError = "No ledger entry was found for this recording."
                isLoading = false
                cleanupPlayer()
            }
            return
        }

        let fallbackUsername = preferredChannelUsername ?? ""
        let channelUsername = loadedDetail.channelUsername.isEmpty ? fallbackUsername : loadedDetail.channelUsername
        async let siblingsTask: [RecordingLedgerEntry] = channelUsername.isEmpty
            ? []
            : manager.getChannelRecordingEntries(username: channelUsername, includeMissing: true)
        async let channelThumbnailTask: String? = channelUsername.isEmpty
            ? nil
            : manager.getChannelThumbnailPath(username: channelUsername)

        let siblings = await siblingsTask
        let resolvedChannelThumbnailPath = await channelThumbnailTask

        if Task.isCancelled { return }

        await MainActor.run {
            detail = loadedDetail
            siblingEntries = siblings
            channelThumbnailPath = resolvedChannelThumbnailPath
            isLoading = false
        }

        let requestedPath = recordingPath
        loadPoster(for: loadedDetail, requestedPath: requestedPath)

        guard shouldAllowPlayback(loadedDetail) else {
            await MainActor.run {
                playerError = nil
            }
            return
        }

        playerLoadTask = Task {
            await preparePlayer(for: loadedDetail, requestedPath: requestedPath)
        }
    }

    private func preparePlayer(for detail: RecordingLedgerDetail, requestedPath: String) async {
        let normalizedRequestedPath = normalizedPath(requestedPath)

        // Reset player state directly — do NOT call cleanupPlayer() here because that would
        // cancel playerLoadTask, which IS this task, making Task.isCancelled true for all
        // subsequent awaits and leaving isPreparingPlayer stuck at true forever.
        await MainActor.run {
            playerStatusObserver?.invalidate()
            playerStatusObserver = nil
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
            playerError = nil
            isPreparingPlayer = false
        }

        guard detail.fileExists else {
            await MainActor.run {
                playerError = "Playback is unavailable because the file is missing from disk."
            }
            return
        }

        let fileURL = URL(fileURLWithPath: (detail.path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            await MainActor.run {
                playerError = "Playback is unavailable because the file no longer exists at the stored path."
            }
            return
        }

        await MainActor.run {
            isPreparingPlayer = true
        }

        let asset = AVURLAsset(url: fileURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

        do {
            let isReadable = try await loadIsReadableWithTimeout(asset, timeoutSeconds: 18)
            if Task.isCancelled { return }

            guard isReadable else {
                await MainActor.run {
                    playerError = "The media file is not readable by AVFoundation."
                    isPreparingPlayer = false
                }
                return
            }

            await MainActor.run {
                guard normalizedPath(recordingPath) == normalizedRequestedPath else { return }

                let item = AVPlayerItem(asset: asset)
                playerStatusObserver = item.observe(\.status, options: [.initial, .new]) { item, _ in
                    Task { @MainActor in
                        if item.status == .failed {
                            playerError = item.error?.localizedDescription ?? "Playback failed while preparing the video."
                        }
                    }
                }

                let newPlayer = AVPlayer(playerItem: item)
                newPlayer.pause()
                player = newPlayer
                isPreparingPlayer = false
            }
        } catch {
            // Always clear isPreparingPlayer, even on cancellation — otherwise the UI freezes.
            let wasCancelled = Task.isCancelled
            await MainActor.run {
                isPreparingPlayer = false
                if !wasCancelled {
                    playerError = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func reloadPlayer() {
        guard let detail, shouldAllowPlayback(detail) else { return }
        playerLoadTask?.cancel()
        let requestedPath = recordingPath
        playerLoadTask = Task {
            await preparePlayer(for: detail, requestedPath: requestedPath)
        }
    }

    private func cleanupPlayer() {
        playerLoadTask?.cancel()
        playerLoadTask = nil
        playerStatusObserver?.invalidate()
        playerStatusObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isPreparingPlayer = false
        playerError = nil
    }

    private var effectiveNavigationPaths: [String] {
        let explicitPaths = Array(NSOrderedSet(array: navigationPaths).compactMap { $0 as? String })
        if explicitPaths.contains(recordingPath) {
            return explicitPaths
        }

        let siblingPaths = siblingEntries.map(\ .path)
        if siblingPaths.contains(recordingPath) {
            return siblingPaths
        }

        if !explicitPaths.isEmpty {
            return explicitPaths
        }

        return recordingPath.isEmpty ? [] : [recordingPath]
    }

    private func loadPoster(for detail: RecordingLedgerDetail, requestedPath: String) {
        let normalizedRequestedPath = normalizedPath(requestedPath)
        posterLoadTask?.cancel()
        posterLoadTask = Task {
            let posterPath = await resolvePosterPath(for: detail)
            if Task.isCancelled { return }
            let image = await loadImage(atPath: posterPath)
            if Task.isCancelled { return }

            await MainActor.run {
                guard normalizedPath(recordingPath) == normalizedRequestedPath else { return }
                posterImage = image
            }
        }
    }

    private func resolvePosterPath(for detail: RecordingLedgerDetail) async -> String? {
        if let channelThumbnailPath,
           FileManager.default.fileExists(atPath: channelThumbnailPath) {
            return channelThumbnailPath
        }

        guard detail.fileExists else { return nil }

        let resolvedWorkingFilePath = detail.workingFilePath.map { ($0 as NSString).expandingTildeInPath }
        let hasWorkingFile = resolvedWorkingFilePath.map { FileManager.default.fileExists(atPath: $0) } ?? false

        let item = RecordingLibraryItem(
            path: detail.path,
            filename: URL(fileURLWithPath: detail.path).lastPathComponent,
            channelName: detail.channelUsername,
            recordingStatus: detail.status,
            fileExtension: detail.fileExtension,
            sizeBytes: detail.fileSizeBytes,
            durationSeconds: detail.durationSeconds,
            startedAt: detail.startedAt,
            endedAt: detail.endedAt,
            modifiedAt: detail.fileLastModifiedAt ?? detail.fileLastSeenAt ?? Date(),
            thumbnailSourcePath: shouldAllowPlayback(detail) ? detail.path : nil,
            channelThumbnailPath: channelThumbnailPath,
            isInProgress: detail.isActive || detail.isFinalizing,
            isActivelyFinalizing: detail.isFinalizing,
            isPreviewable: detail.fileExists,
            isOpenable: detail.fileExists || hasWorkingFile
        )

        return await RecordingThumbnailStore.shared.thumbnailPath(for: item)
    }

    private func loadImage(atPath path: String?) async -> NSImage? {
        guard let path else { return nil }

        let expandedPath = (path as NSString).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: expandedPath)
        let data = await Task.detached(priority: .utility) {
            try? Data(contentsOf: fileURL, options: [.mappedIfSafe])
        }.value

        guard let data else { return nil }
        return NSImage(data: data)
    }

    private func normalizedPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private func shouldAllowPlayback(_ detail: RecordingLedgerDetail) -> Bool {
        detail.fileExists && !detail.isActive && !detail.isFinalizing
    }

    private func loadIsReadableWithTimeout(_ asset: AVURLAsset, timeoutSeconds: Double) async throws -> Bool {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await asset.load(.isReadable)
            }

            group.addTask {
                let delay = UInt64(max(timeoutSeconds, 1) * 1_000_000_000)
                try await Task.sleep(nanoseconds: delay)
                throw PlayerPreparationError.timedOut
            }

            guard let first = try await group.next() else {
                throw PlayerPreparationError.timedOut
            }

            group.cancelAll()
            return first
        }
    }

    private var currentNavigationIndex: Int? {
        effectiveNavigationPaths.firstIndex(of: recordingPath)
    }

    private var previousSiblingPath: String? {
        guard let currentNavigationIndex, currentNavigationIndex > 0 else { return nil }
        return effectiveNavigationPaths[currentNavigationIndex - 1]
    }

    private var nextSiblingPath: String? {
        guard let currentNavigationIndex,
              currentNavigationIndex < effectiveNavigationPaths.count - 1 else { return nil }
        return effectiveNavigationPaths[currentNavigationIndex + 1]
    }

    private func selectSibling(offset: Int) {
        guard let currentNavigationIndex else { return }
        let nextIndex = currentNavigationIndex + offset
        guard effectiveNavigationPaths.indices.contains(nextIndex) else { return }

        let nextPath = effectiveNavigationPaths[nextIndex]
        let nextChannel = siblingEntries.first(where: { $0.path == nextPath })?.channelUsername
        onSelectRecording(nextPath, nextChannel)
    }

    private func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    private var isPlayerPlaying: Bool {
        player?.timeControlStatus == .playing
    }

    private func revealRecordingInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func openRecordingFolder(_ path: String) {
        let folderURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        NSWorkspace.shared.open(folderURL)
    }

    private func moveRecordingToTrash(_ detail: RecordingLedgerDetail) {
        let normalizedPath = (detail.path as NSString).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: normalizedPath)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: fileURL, resultingItemURL: &resultingURL)
            } catch {
                playerError = "Could not move recording to Trash: \(error.localizedDescription)"
                return
            }
        }

        Task {
            await manager.markRecordingMovedToTrash(path: detail.path)
            await MainActor.run {
                onMoveToTrash?(detail.path)

                let remainingNavigation = effectiveNavigationPaths.filter { $0 != detail.path }
                if let currentNavigationIndex,
                   !remainingNavigation.isEmpty {
                    let replacementIndex = min(currentNavigationIndex, remainingNavigation.count - 1)
                    let replacementPath = remainingNavigation[replacementIndex]
                    let replacementChannel = siblingEntries.first(where: { $0.path == replacementPath })?.channelUsername
                    onSelectRecording(replacementPath, replacementChannel)
                } else {
                    onBack()
                }
            }
        }
    }

    private func recordingStatusLabel(_ detail: RecordingLedgerDetail) -> String {
        if detail.isActive {
            return "Recording"
        }
        if detail.isFinalizing {
            return "Finalizing"
        }
        if detail.status == "deleted" {
            return "Deleted"
        }
        if !detail.fileExists {
            return "Missing"
        }
        return detail.status.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func recordingStatusColor(_ detail: RecordingLedgerDetail) -> Color {
        if detail.isActive {
            return .green
        }
        if detail.isFinalizing {
            return .orange
        }
        if detail.status == "deleted" {
            return .secondary
        }
        if !detail.fileExists {
            return .orange
        }
        return .secondary
    }

    private func eventLevelColor(_ level: String) -> Color {
        switch level.uppercased() {
        case "ERROR":
            return .red
        case "WARN", "WARNING":
            return .orange
        case "DEBUG":
            return .blue
        default:
            return .secondary
        }
    }

    private func statusBadge(label: String, color: Color) -> some View {
        Text(label)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    private func formatOptionalDate(_ date: Date?) -> String {
        guard let date else { return "-" }
        return Self.metadataDateFormatter.string(from: date)
    }

    private func formatDuration(_ durationSeconds: Double) -> String {
        guard durationSeconds > 0 else { return "0s" }
        let totalSeconds = Int(durationSeconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, seconds)
        }
        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, seconds)
        }
        return "\(seconds)s"
    }

    private func audioPresenceLabel(_ audioPresent: Int) -> String {
        switch audioPresent {
        case 1:
            return "Yes"
        case 0:
            return "No"
        default:
            return "Unknown"
        }
    }
}

struct RecordingPreviewSheet: View {
    @Binding var paths: [String]
    @Binding var currentIndex: Int
    @Binding var isPresented: Bool
    var onMoveToTrash: ((String) -> Void)? = nil
    @State private var player: AVPlayer?
    @State private var loadError: String?
    @State private var failedToPlayObserver: NSObjectProtocol?
    @State private var loadingTask: Task<Void, Never>?
    @State private var isLoading = false
    @State private var loadingMessage = "Preparing video..."
    @State private var showPlayerSurface = false
    @State private var statusObserver: NSKeyValueObservation?
    @State private var timeControlObserver: NSKeyValueObservation?
    @State private var timeObserverToken: Any?
    @State private var timeoutTask: Task<Void, Never>?
    @State private var currentChannelName = "Unknown"
    @State private var currentFileSize = "Unknown"
    @State private var currentModifiedAt = "Unknown"

    private var currentURL: URL? {
        guard paths.indices.contains(currentIndex) else { return nil }
        let normalized = (paths[currentIndex] as NSString).expandingTildeInPath
        return URL(fileURLWithPath: normalized)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(currentURL?.lastPathComponent ?? "Recording Preview")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("\(currentIndex + 1)/\(max(paths.count, 1))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ZStack {
                if let player = player, showPlayerSurface {
                    RecordingPlayerView(player: player)
                        .cornerRadius(10)
                } else if let loadError = loadError {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Could not load video")
                            .font(.headline)
                        Text(loadError)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 500)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 10) {
                        ProgressView(loadingMessage)
                        Text("Large transport stream files can take a bit to initialize")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if isLoading {
                            Button("Cancel Load") {
                                cancelLoading()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 420)
            .frame(maxWidth: .infinity)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.25))
            .cornerRadius(10)

            if let currentURL {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 14) {
                        Label(currentChannelName, systemImage: "person.crop.square")
                        Label(currentModifiedAt, systemImage: "calendar")
                        Label(currentFileSize, systemImage: "doc")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)

                    Text(currentURL.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 10) {
                Button {
                    guard !paths.isEmpty else { return }
                    currentIndex = (currentIndex - 1 + paths.count) % paths.count
                } label: {
                    Label("Previous", systemImage: "chevron.left")
                }
                .keyboardShortcut(.leftArrow, modifiers: [])

                Button {
                    togglePlayback()
                } label: {
                    Label("Play/Pause", systemImage: "playpause")
                }
                .keyboardShortcut(KeyEquivalent(" "), modifiers: [])

                Button(role: .destructive) {
                    moveCurrentVideoToTrash()
                } label: {
                    Label("Move To Trash", systemImage: "trash")
                }
                .disabled(currentURL == nil)

                Button {
                    guard !paths.isEmpty else { return }
                    currentIndex = (currentIndex + 1) % paths.count
                } label: {
                    Label("Next", systemImage: "chevron.right")
                }
                .keyboardShortcut(.rightArrow, modifiers: [])

                Spacer()

                Button("Done") {
                    closePreview()
                }
                .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(minWidth: 880, minHeight: 560)
        .onAppear {
            loadCurrentVideo()
        }
        .onChange(of: currentIndex) { _ in
            loadCurrentVideo()
        }
        .onDisappear {
            cleanupPlayer()
        }
    }

    private func closePreview() {
        cancelLoading()
        cleanupPlayer()
        isPresented = false
    }

    private func cancelLoading() {
        loadingTask?.cancel()
        loadingTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        isLoading = false
        loadingMessage = "Preparing video..."
    }

    private func cleanupPlayer() {
        if let failedToPlayObserver {
            NotificationCenter.default.removeObserver(failedToPlayObserver)
            self.failedToPlayObserver = nil
        }

        statusObserver?.invalidate()
        statusObserver = nil
        timeControlObserver?.invalidate()
        timeControlObserver = nil

        if let player, let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
            self.timeObserverToken = nil
        }

        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        showPlayerSurface = false
        loadError = nil
    }
    
    private func loadCurrentVideo() {
        guard let currentURL else {
            loadError = "Invalid file path"
            player = nil
            return
        }

        refreshCurrentMetadata(for: currentURL)
        
        // Verify file exists
        guard FileManager.default.fileExists(atPath: currentURL.path) else {
            loadError = "File not found: \(currentURL.lastPathComponent)"
            player = nil
            return
        }

        cancelLoading()
        cleanupPlayer()
        loadError = nil
        isLoading = true
        loadingMessage = "Preparing video..."
        showPlayerSurface = false

        let expectedPath = currentURL.path
        let loadURL = currentURL

        loadingTask = Task {
            let asset = AVURLAsset(
                url: loadURL,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
            )

            do {
                let isReadable = try await asset.load(.isReadable)
                if Task.isCancelled { return }

                await MainActor.run {
                    guard self.currentURL?.path == expectedPath else {
                        isLoading = false
                        return
                    }

                    guard isReadable else {
                        loadError = "Video is not readable"
                        isLoading = false
                        return
                    }

                    let item = AVPlayerItem(asset: asset)

                    statusObserver = item.observe(\ .status, options: [.initial, .new]) { _, _ in
                        Task { @MainActor in
                            switch item.status {
                            case .readyToPlay:
                                loadingMessage = "Starting playback..."
                            case .failed:
                                let message = item.error?.localizedDescription ?? "Unknown player item error"
                                loadError = "Playback setup failed: \(message)"
                                isLoading = false
                            case .unknown:
                                break
                            @unknown default:
                                break
                            }
                        }
                    }

                    failedToPlayObserver = NotificationCenter.default.addObserver(
                        forName: .AVPlayerItemFailedToPlayToEndTime,
                        object: item,
                        queue: .main
                    ) { note in
                        let nsError = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                        let message = nsError?.localizedDescription ?? "Unsupported or unreadable media format"
                        loadError = "Playback failed: \(message)"
                    }

                    let newPlayer = AVPlayer(playerItem: item)
                    timeControlObserver = newPlayer.observe(\ .timeControlStatus, options: [.initial, .new]) { player, _ in
                        Task { @MainActor in
                            if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                                loadingMessage = "Buffering video..."
                            }
                        }
                    }

                    timeObserverToken = newPlayer.addPeriodicTimeObserver(
                        forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                        queue: .main
                    ) { time in
                        if time.seconds > 0.01 {
                            showPlayerSurface = true
                            isLoading = false
                        }
                    }

                    player = newPlayer
                    newPlayer.play()
                    loadingTask = nil

                    timeoutTask = Task {
                        try? await Task.sleep(nanoseconds: 15_000_000_000)
                        if Task.isCancelled { return }
                        await MainActor.run {
                            guard self.currentURL?.path == expectedPath else { return }
                            if isLoading && !showPlayerSurface {
                                loadingMessage = "Still loading. This file may be very large or damaged."
                            }
                        }
                    }
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    guard self.currentURL?.path == expectedPath else {
                        isLoading = false
                        return
                    }
                    loadError = "Could not load video: \(error.localizedDescription)"
                    isLoading = false
                    loadingTask = nil
                }
            }
        }
    }

    private func moveCurrentVideoToTrash() {
        guard let currentURL else { return }
        let removedPath = currentURL.path

        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: currentURL, resultingItemURL: &resultingURL)
            onMoveToTrash?(removedPath)

            let removedIndex = currentIndex
            if paths.indices.contains(removedIndex) {
                paths.remove(at: removedIndex)
            }

            if paths.isEmpty {
                closePreview()
                return
            }

            currentIndex = min(removedIndex, paths.count - 1)
            loadCurrentVideo()
        } catch {
            loadError = "Could not move file to Trash: \(error.localizedDescription)"
        }
    }

    private func togglePlayback() {
        guard let player = player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    private func refreshCurrentMetadata(for url: URL) {
        currentChannelName = url.deletingLastPathComponent().lastPathComponent

        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        if let values = try? url.resourceValues(forKeys: resourceKeys),
           let size = values.fileSize {
            let sizeFormatter = ByteCountFormatter()
            sizeFormatter.countStyle = .file
            currentFileSize = sizeFormatter.string(fromByteCount: Int64(size))
        } else {
            currentFileSize = "Unknown"
        }

        if let modified = try? url.resourceValues(forKeys: resourceKeys).contentModificationDate {
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .short
            dateFormatter.timeStyle = .short
            currentModifiedAt = dateFormatter.string(from: modified)
        } else {
            currentModifiedAt = "Unknown"
        }
    }
}

private struct RecordingPlayerView: NSViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = videoGravity
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
        nsView.videoGravity = videoGravity
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player = nil
    }
}

struct ChannelInfoView: View {
    let info: ChannelInfo
    
    var body: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 8) {
                InfoCard(title: "Duration", value: info.duration, icon: "clock")
                InfoCard(title: "File Size", value: info.filesize, icon: "doc")
                InfoCard(title: "Split After Duration", value: info.maxDuration, icon: "timer")
                InfoCard(title: "Split After File Size", value: info.maxFilesize, icon: "externaldrive")
            }
            
            if let filename = info.filename {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current File")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text((filename as NSString).lastPathComponent)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            
            if let streamedAt = info.streamedAt {
                detailRow(label: "Stream Started", value: streamedAt)
            }

            if let lastOnlineAt = info.lastOnlineAt {
                detailRow(label: "Last Online", value: lastOnlineAt)
            }

            if info.isOnline {
                let personDetectionText: String = {
                    if let isPersonDetected = info.isPersonDetected {
                        return isPersonDetected ? "Person detected" : "No person detected"
                    }

                    return info.isNoPersonDetected
                        ? "No person detected for \(formatNoPersonDuration(info.noPersonDurationSeconds))"
                        : "Person detected"
                }()

                let personDetectionColor: Color = {
                    if let isPersonDetected = info.isPersonDetected {
                        return isPersonDetected ? .primary : .orange
                    }
                    return info.isNoPersonDetected ? .orange : .primary
                }()

                detailRow(
                    label: "Person Detection",
                    value: personDetectionText,
                    valueColor: personDetectionColor
                )
            }

            detailRow(label: "Segment Retries", value: "\(info.segmentRetryCount)")

            detailRow(
                label: "Consecutive Segment Failures",
                value: "\(info.consecutiveSegmentFailures)",
                valueColor: info.consecutiveSegmentFailures > 0 ? .orange : .primary
            )

            detailRow(
                label: "Timeline Mismatch Events",
                value: "\(info.timelineMismatchCount)",
                valueColor: info.timelineMismatchCount > 0 ? .red : .primary
            )

            if let lastFailureAt = info.lastSegmentFailureAt {
                detailRow(label: "Last Segment Failure", value: lastFailureAt, valueColor: .orange)
            }

            if let lastTimelineMismatchAt = info.lastTimelineMismatchAt {
                detailRow(label: "Last Timeline Mismatch", value: lastTimelineMismatchAt, valueColor: .red)
            }
        }
    }

    private func detailRow(label: String, value: String, valueColor: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(label):")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
            Text(value)
                .font(.caption)
                .foregroundColor(valueColor)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 2)
    }
}

struct InfoCard: View {
    let title: String
    let value: String
    let icon: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.headline)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct BioMetadataView: View {
    let info: ChannelInfo
    let manager: ChannelManager
    let username: String
    @State private var isFetchingBio = false
    @State private var localBioMetadata: BioMetadata?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bio Metadata")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            if let bioMetadata = localBioMetadata ?? info.bioMetadata {
                VStack(alignment: .leading, spacing: 7) {
                    if let gender = bioMetadata.gender {
                        metadataRow("Gender", value: gender, labelFont: .caption, valueFont: .caption)
                    }

                    if let followers = bioMetadata.followers {
                        metadataRow("Followers", value: String(followers), labelFont: .caption, valueFont: .caption)
                    }

                    if let location = bioMetadata.location {
                        metadataRow("Location", value: location, labelFont: .caption, valueFont: .caption)
                    }

                    if let body = bioMetadata.body {
                        metadataRow("Body", value: body, labelFont: .caption, valueFont: .caption)
                    }

                    if let language = bioMetadata.language {
                        metadataRow("Language", value: language, labelFont: .caption, valueFont: .caption)
                    }

                    if let lastBioRefresh = bioMetadata.lastBioRefresh {
                        metadataRow("Last Refreshed", value: formatTimestamp(lastBioRefresh), labelFont: .caption, valueFont: .caption)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No bio data yet")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button(action: fetchBio) {
                        if isFetchingBio {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.7)
                                Text("Fetching...")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Label("Fetch Bio Data", systemImage: "arrow.down.circle")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isFetchingBio)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)
            }
        }
        .onAppear {
            localBioMetadata = info.bioMetadata
        }
        .onChange(of: info.bioMetadata?.lastBioRefresh) { _ in
            if localBioMetadata == nil {
                localBioMetadata = info.bioMetadata
            }
        }
    }

    private func metadataRow(_ label: String, value: String, labelFont: Font = .body, valueFont: Font = .body) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(labelFont)
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(valueFont)
                .fontWeight(.medium)
                .multilineTextAlignment(.trailing)
        }
    }
    
    private func fetchBio() {
        isFetchingBio = true
        Task { @MainActor in
            await manager.refreshBioMetadata(username: username)
            if let updated = await manager.getChannelInfo(username: username) {
                localBioMetadata = updated.bioMetadata
            }
            isFetchingBio = false
        }
    }
    
    private func formatTimestamp(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct ImportChannelsView: View {
    @ObservedObject var manager: ChannelManager
    @Environment(\.dismiss) var dismiss
    @State private var importStatusMessage: String?
    @State private var isImporting = false
    @State private var importErrorMessage: String?
    @State private var showingImportError = false
    @State private var followedImportPreview: FollowedImportPreview?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Import Channels")
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
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Quick Import")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        HStack(spacing: 12) {
                            Button(action: importChannelsFromFolder) {
                                Label("Import Channels From Folders", systemImage: "tray.and.arrow.down")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isImporting)

                            Button(action: importFollowedCams) {
                                Label("Import Followed Cams", systemImage: "person.2.badge.gearshape")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isImporting)

                            if isImporting {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }

                        Text("Import from folders or directly from your followed cams list (online + offline).")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("Bio metadata refresh is available in Settings.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if let importStatusMessage {
                            Text(importStatusMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if let preview = followedImportPreview {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Review Followed Import")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)

                                Text("Found \(preview.found.count) followed channels: \(preview.existing.count) already exist, \(preview.toAdd.count) ready to add.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                ScrollView {
                                    VStack(alignment: .leading, spacing: 4) {
                                        if preview.toAdd.isEmpty {
                                            Text("No new channels to add.")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        } else {
                                            ForEach(preview.toAdd, id: \.self) { username in
                                                Text("+ \(username)")
                                                    .font(.system(.caption, design: .monospaced))
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        }
                                    }
                                }
                                .frame(maxHeight: 180)
                                .padding(8)
                                .background(Color(NSColor.textBackgroundColor))
                                .cornerRadius(6)

                                HStack(spacing: 10) {
                                    Button("Cancel") {
                                        followedImportPreview = nil
                                        importStatusMessage = nil
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Add \(preview.toAdd.count) Channels") {
                                        confirmFollowedImport(preview)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(preview.toAdd.isEmpty || isImporting)
                                }
                            }
                            .padding(10)
                            .background(Color(NSColor.textBackgroundColor).opacity(0.6))
                            .cornerRadius(8)
                        }
                    }
                    .padding(16)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(10)
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
        .frame(width: 700, height: 520)
        .alert("Import Error", isPresented: $showingImportError) {
            Button("OK") { }
        } message: {
            Text(importErrorMessage ?? "Unknown import error")
        }
    }

    private func importChannelsFromFolder() {
        followedImportPreview = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Import"
        panel.message = "Select the parent folder that contains channel subfolders"
        panel.directoryURL = URL(fileURLWithPath: manager.appConfig.getOutputPath())

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isImporting = true
        importStatusMessage = "Scanning folders..."

        Task { @MainActor in
            let result = await manager.importChannelsFromFolders(parentDirectory: url.path)
            isImporting = false
            importStatusMessage = "Imported \(result.imported) channel\(result.imported == 1 ? "" : "s"), skipped \(result.skipped)."
        }
    }

    private func importFollowedCams() {
        followedImportPreview = nil
        isImporting = true
        importStatusMessage = "Loading followed cams preview..."

        Task { @MainActor in
            do {
                let preview = try await manager.prepareFollowedImport(progress: { message in
                    Task { @MainActor in
                        importStatusMessage = message
                    }
                })
                isImporting = false
                followedImportPreview = preview
                importStatusMessage = "Preview ready: \(preview.toAdd.count) new, \(preview.existing.count) existing. Confirm to add."
            } catch {
                isImporting = false
                importStatusMessage = nil
                importErrorMessage = error.localizedDescription
                showingImportError = true
            }
        }
    }

    private func confirmFollowedImport(_ preview: FollowedImportPreview) {
        isImporting = true
        importStatusMessage = "Adding selected followed channels..."

        Task { @MainActor in
            let result = await manager.importFollowedChannelsFromPreview(preview)
            isImporting = false
            followedImportPreview = nil
            importStatusMessage = "Imported \(result.imported) followed channel\(result.imported == 1 ? "" : "s"), skipped \(result.skipped)."
        }
    }
}

struct AddChannelView: View {
    @ObservedObject var manager: ChannelManager
    @Environment(\.dismiss) var dismiss
    @Binding var errorMessage: String?
    @Binding var showingError: Bool
    var onChannelCreated: ((String) -> Void)? = nil
    
    @State private var username = ""
    @State private var resolution = 1080
    @State private var framerate = 30
    @State private var maxDuration = 0
    @State private var maxFilesize = 0
    @State private var maxSessionDuration = 0
    @State private var maxSessionFilesize = 0
    @State private var outputDirectory = ""
    @State private var pattern = "{{.Username}}_{{.Year}}-{{.Month}}-{{.Day}}_{{.Hour}}-{{.Minute}}-{{.Second}}{{if .Sequence}}_{{.Sequence}}{{end}}"
    @State private var isSubmitting = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add Channel")
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
                    // Channel Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Channel")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Username")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            TextField("Enter channel username", text: $username)
                                .textFieldStyle(.roundedBorder)
                                .textContentType(.username)
                                .autocorrectionDisabled()
                        }
                        .padding(16)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(10)
                    }
                    
                    // Quality Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Quality")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        VStack(spacing: 12) {
                            HStack {
                                Text("Resolution")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .frame(width: 100, alignment: .leading)
                                Picker("", selection: $resolution) {
                                    Text("360p").tag(360)
                                    Text("480p").tag(480)
                                    Text("720p").tag(720)
                                    Text("1080p").tag(1080)
                                    Text("1440p").tag(1440)
                                    Text("2160p").tag(2160)
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            
                            Divider()
                            
                            HStack {
                                Text("Framerate")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .frame(width: 100, alignment: .leading)
                                Picker("", selection: $framerate) {
                                    Text("30 fps").tag(30)
                                    Text("60 fps").tag(60)
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(16)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(10)
                    }
                    
                    // Limits Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Limits")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        VStack(spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Split After Duration")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("Split recording after duration limit")
                                }
                                Spacer()
                                HStack(spacing: 12) {
                                    Text(maxDuration == 0 ? "Unlimited" : "\(maxDuration) min")
                                        .foregroundColor(maxDuration == 0 ? .secondary : .primary)
                                        .frame(minWidth: 80, alignment: .trailing)
                                    Stepper("", value: $maxDuration, in: 0...1440, step: 15)
                                        .labelsHidden()
                                }
                            }
                            
                            Divider()
                            
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Split After File Size")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("Split recording after file size limit")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                HStack(spacing: 12) {
                                    Text(maxFilesize == 0 ? "Unlimited" : "\(maxFilesize) MB")
                                        .foregroundColor(maxFilesize == 0 ? .secondary : .primary)
                                        .frame(minWidth: 80, alignment: .trailing)
                                    Stepper("", value: $maxFilesize, in: 0...10240, step: 100)
                                        .labelsHidden()
                                }
                            }
                            
                            Divider()
                            
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Max Session Duration")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("Pause recording after session duration limit")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                HStack(spacing: 12) {
                                    Text(maxSessionDuration == 0 ? "Unlimited" : "\(maxSessionDuration) min")
                                        .foregroundColor(maxSessionDuration == 0 ? .secondary : .primary)
                                        .frame(minWidth: 80, alignment: .trailing)
                                    Stepper("", value: $maxSessionDuration, in: 0...1440, step: 15)
                                        .labelsHidden()
                                }
                            }

                            Divider()

                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Max Session File Size")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("Pause recording after total session file size limit")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                HStack(spacing: 12) {
                                    Text(maxSessionFilesize == 0 ? "Unlimited" : "\(maxSessionFilesize) MB")
                                        .foregroundColor(maxSessionFilesize == 0 ? .secondary : .primary)
                                        .frame(minWidth: 80, alignment: .trailing)
                                    Stepper("", value: $maxSessionFilesize, in: 0...102400, step: 500)
                                        .labelsHidden()
                                }
                            }
                        }
                        .padding(16)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(10)
                    }
                    
                    // Output Section
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
                                    Text("Uses app default output directory")
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
                                    Button(action: { outputDirectory = "" }) {
                                        Label("Clear", systemImage: "xmark.circle")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        .padding(16)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(10)
                        
                        Divider()
                            .padding(.vertical, 4)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Naming Pattern")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            TextField("Filename pattern", text: $pattern, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(2...4)
                                .font(.system(.caption, design: .monospaced))
                            
                            Text("Available: {{.Username}}, {{.Year}}, {{.Month}}, {{.Day}}, {{.Hour}}, {{.Minute}}, {{.Second}}, {{.Sequence}}")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(24)
            }
            
            Divider()
            
            // Footer Actions
            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
                .disabled(isSubmitting)
                
                Spacer()

                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                }
                
                Button("Add Channel") {
                    addChannel()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
            }
            .padding(24)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 600, height: 640)
    }
    
    private func addChannel() {
        if isSubmitting { return }

        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else { return }

        isSubmitting = true
        
        let config = ChannelConfig(
            username: trimmedUsername,
            outputDirectory: outputDirectory,
            framerate: framerate,
            resolution: resolution,
            pattern: pattern,
            maxDuration: maxDuration,
            maxFilesize: maxFilesize,
            maxSessionDuration: maxSessionDuration,
            maxSessionFilesize: maxSessionFilesize
        )
        
        Task { @MainActor in
            do {
                let createdUsername = try await manager.createChannel(config: config)
                onChannelCreated?(createdUsername)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
                isSubmitting = false
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url.path
        }
    }
}

struct EditChannelView: View {
    @ObservedObject var manager: ChannelManager
    let username: String
    @Environment(\.dismiss) var dismiss
    @Binding var errorMessage: String?
    @Binding var showingError: Bool
    var onRenamed: ((String) -> Void)? = nil
    
    @State private var editedUsername = ""
    @State private var resolution = 1080
    @State private var framerate = 30
    @State private var maxDuration = 0
    @State private var maxFilesize = 0
    @State private var maxSessionDuration = 0
    @State private var maxSessionFilesize = 0
    @State private var outputDirectory = ""
    @State private var pattern = ""
    @State private var isLoading = true
    @State private var canEditUsername = true
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Edit \(username)")
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
            
            if isLoading {
                ProgressView("Loading channel settings...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        // Identity Section
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Identity")
                                .font(.headline)
                                .foregroundColor(.secondary)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Username")
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                TextField("Username", text: $editedUsername)
                                    .textFieldStyle(.roundedBorder)
                                    .autocorrectionDisabled()
                                    .disabled(!canEditUsername)

                                if let usernameValidationError {
                                    Text(usernameValidationError)
                                        .font(.caption)
                                        .foregroundColor(.red)
                                } else if let usernameValidationNote {
                                    Text(usernameValidationNote)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                if !canEditUsername {
                                    Text("Username can only be changed when the channel is not currently recording.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(16)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(10)
                        }

                        // Quality Section
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Quality")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            
                            VStack(spacing: 12) {
                                HStack {
                                    Text("Resolution")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .frame(width: 100, alignment: .leading)
                                    Picker("", selection: $resolution) {
                                        Text("360p").tag(360)
                                        Text("480p").tag(480)
                                        Text("720p").tag(720)
                                        Text("1080p").tag(1080)
                                        Text("1440p").tag(1440)
                                        Text("2160p").tag(2160)
                                    }
                                    .pickerStyle(.menu)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                
                                Divider()
                                
                                HStack {
                                    Text("Framerate")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .frame(width: 100, alignment: .leading)
                                    Picker("", selection: $framerate) {
                                        Text("30 fps").tag(30)
                                        Text("60 fps").tag(60)
                                    }
                                    .pickerStyle(.menu)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(16)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(10)
                        }
                        
                        // Limits Section
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Limits")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            
                            VStack(spacing: 12) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Split After Duration")
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                        Text("Split recording after duration limit")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    HStack(spacing: 12) {
                                        Text(maxDuration == 0 ? "Unlimited" : "\(maxDuration) min")
                                            .foregroundColor(maxDuration == 0 ? .secondary : .primary)
                                            .frame(minWidth: 80, alignment: .trailing)
                                        Stepper("", value: $maxDuration, in: 0...1440, step: 15)
                                            .labelsHidden()
                                    }
                                }
                                
                                Divider()
                                
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Split After File Size")
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                        Text("Split recording after file size limit")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    HStack(spacing: 12) {
                                        Text(maxFilesize == 0 ? "Unlimited" : "\(maxFilesize) MB")
                                            .foregroundColor(maxFilesize == 0 ? .secondary : .primary)
                                            .frame(minWidth: 80, alignment: .trailing)
                                        Stepper("", value: $maxFilesize, in: 0...10240, step: 100)
                                            .labelsHidden()
                                    }
                                }

                                Divider()

                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Max Session Duration")
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                        Text("Pause recording after session duration limit")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    HStack(spacing: 12) {
                                        Text(maxSessionDuration == 0 ? "Unlimited" : "\(maxSessionDuration) min")
                                            .foregroundColor(maxSessionDuration == 0 ? .secondary : .primary)
                                            .frame(minWidth: 80, alignment: .trailing)
                                        Stepper("", value: $maxSessionDuration, in: 0...1440, step: 15)
                                            .labelsHidden()
                                    }
                                }

                                Divider()

                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Max Session File Size")
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                        Text("Pause recording after total session file size limit")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    HStack(spacing: 12) {
                                        Text(maxSessionFilesize == 0 ? "Unlimited" : "\(maxSessionFilesize) MB")
                                            .foregroundColor(maxSessionFilesize == 0 ? .secondary : .primary)
                                            .frame(minWidth: 80, alignment: .trailing)
                                        Stepper("", value: $maxSessionFilesize, in: 0...102400, step: 500)
                                            .labelsHidden()
                                    }
                                }
                            }
                            .padding(16)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(10)
                        }
                        
                        // Output Section 
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
                                        Text("Uses app default output directory")
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
                                        Button(action: { outputDirectory = "" }) {
                                            Label("Clear", systemImage: "xmark.circle")
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                            .padding(16)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(10)
                            
                            Divider()
                                .padding(.vertical, 4)
                            
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Naming Pattern")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                
                                TextField("Filename pattern", text: $pattern, axis: .vertical)
                                    .textFieldStyle(.roundedBorder)
                                    .lineLimit(2...4)
                                    .font(.system(.caption, design: .monospaced))
                                
                                Text("Available: {{.Username}}, {{.Year}}, {{.Month}}, {{.Day}}, {{.Hour}}, {{.Minute}}, {{.Second}}, {{.Sequence}}")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(24)
                }
                
                Divider()
                
                // Footer Actions
                HStack(spacing: 12) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                    
                    Spacer()
                    
                    Button("Save Changes") {
                        saveChanges()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isSaveDisabled)
                }
                .padding(24)
                .background(Color(NSColor.controlBackgroundColor))
            }
        }
        .frame(width: 600, height: 650)
        .onAppear {
            loadChannelConfig()
        }
    }
    
    private func loadChannelConfig() {
        Task {
            if let config = await manager.getChannelConfig(username: username) {
                let channelInfo = await manager.getChannelInfo(username: username)
                await MainActor.run {
                    editedUsername = config.username
                    resolution = config.resolution
                    framerate = config.framerate
                    maxDuration = config.maxDuration
                    maxFilesize = config.maxFilesize
                    maxSessionDuration = config.maxSessionDuration
                    maxSessionFilesize = config.maxSessionFilesize
                    outputDirectory = config.outputDirectory
                    pattern = config.pattern
                    canEditUsername = !(channelInfo?.isOnline == true && channelInfo?.isPaused == false)
                    isLoading = false
                }
            } else {
                await MainActor.run {
                    errorMessage = "Failed to load channel configuration"
                    showingError = true
                    dismiss()
                }
            }
        }
    }
    
    private func saveChanges() {
        Task { @MainActor in
            do {
                if let usernameValidationError {
                    errorMessage = usernameValidationError
                    showingError = true
                    return
                }

                // Get current config first to preserve username and other fields
                guard let currentConfig = await manager.getChannelConfig(username: username) else {
                    throw ChaturbateError.networkError("Channel not found")
                }
                
                let updatedConfig = ChannelConfig(
                    isPaused: currentConfig.isPaused,
                    username: sanitizedEditedUsername,
                    outputDirectory: outputDirectory,
                    framerate: framerate,
                    resolution: resolution,
                    pattern: pattern,
                    maxDuration: maxDuration,
                    maxFilesize: maxFilesize,
                    maxSessionDuration: maxSessionDuration,
                    maxSessionFilesize: maxSessionFilesize,
                    createdAt: currentConfig.createdAt,
                    lastOnlineAt: currentConfig.lastOnlineAt,
                    recordingHistory: currentConfig.recordingHistory
                )
                
                let resultingUsername = try await manager.updateChannel(username: username, newConfig: updatedConfig)
                onRenamed?(resultingUsername)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    private var sanitizedEditedUsername: String {
        sanitizeUsername(editedUsername)
    }

    private var usernameValidationError: String? {
        let sanitized = sanitizedEditedUsername
        if sanitized.isEmpty {
            return "Username cannot be empty"
        }

        let currentLower = username.lowercased()
        let targetLower = sanitized.lowercased()
        let hasDuplicate = manager.channels.keys.contains { $0.lowercased() == targetLower && $0.lowercased() != currentLower }
        if hasDuplicate {
            return "Channel \(sanitized) already exists"
        }

        return nil
    }

    private var usernameValidationNote: String? {
        let trimmed = editedUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != sanitizedEditedUsername {
            return "Username will be saved as: \(sanitizedEditedUsername)"
        }
        return nil
    }

    private var isSaveDisabled: Bool {
        isLoading || usernameValidationError != nil
    }

    private func sanitizeUsername(_ username: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return username
            .components(separatedBy: allowed.inverted)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url.path
        }
    }
}
