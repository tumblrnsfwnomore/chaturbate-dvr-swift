import SwiftUI
import AppKit
import AVKit
import AVFoundation

private enum DetailTab: String {
    case allChannels
    case channel
    case recordings
}

enum ChannelStatusFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case online = "Online"
    case recording = "Recording"
    case paused = "Paused"
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

struct ContentView: View {
    @StateObject private var manager = ChannelManager()
    @State private var showingAddChannel = false
    @State private var showingImportChannels = false
    @State private var showingSettings = false
    @State private var showingEditChannel = false
    @State private var selectedChannel: String?
    @State private var selectedDetailTab: DetailTab = .allChannels
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var channelInfos: [ChannelInfo] = []
    @State private var channelInfoTimer: Timer?
    @State private var searchText: String = ""
    @State private var statusFilter: ChannelStatusFilter = .all
    @State private var genderFilter: String? = nil
    
    var body: some View {
        NavigationSplitView {
            ChannelListView(
                manager: manager,
                selectedChannel: $selectedChannel,
                channelInfos: channelInfos,
                searchText: $searchText,
                statusFilter: $statusFilter,
                genderFilter: $genderFilter,
                onActivateChannel: { username in
                    selectedChannel = username
                    selectedDetailTab = .channel
                }
            )
        } detail: {
            VStack(spacing: 0) {
                Picker("View", selection: $selectedDetailTab) {
                    Text("All Channels").tag(DetailTab.allChannels)
                    Text("Channel").tag(DetailTab.channel)
                    Text("Recordings").tag(DetailTab.recordings)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

                Divider()

                Group {
                    if selectedDetailTab == .allChannels {
                        AllChannelsGridView(
                            manager: manager,
                            selectedChannel: $selectedChannel,
                            channelInfos: channelInfos,
                            searchText: $searchText,
                            statusFilter: $statusFilter,
                            genderFilter: $genderFilter,
                            onOpenChannel: { selectedDetailTab = .channel }
                        )
                    } else if selectedDetailTab == .recordings {
                        RecordingsLibraryView(manager: manager)
                    } else if let username = selectedChannel {
                        ChannelDetailView(
                            manager: manager,
                            username: username,
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
                            onDeleted: { selectedChannel = nil }
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
                            Text("Pick a channel from the list or All Channels grid")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
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
            AddChannelView(manager: manager, errorMessage: $errorMessage, showingError: $showingError)
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
        .onDisappear {
            channelInfoTimer?.invalidate()
        }
    }

    private var orderedChannelUsernames: [String] {
        channelInfos.map { $0.username }
    }

    private var selectedChannelIndex: Int? {
        guard let selectedChannel else { return nil }
        return orderedChannelUsernames.firstIndex(of: selectedChannel)
    }

    private var previousChannelUsername: String? {
        guard let selectedChannelIndex, selectedChannelIndex > 0 else { return nil }
        return orderedChannelUsernames[selectedChannelIndex - 1]
    }

    private var nextChannelUsername: String? {
        guard let selectedChannelIndex,
              selectedChannelIndex < orderedChannelUsernames.count - 1 else { return nil }
        return orderedChannelUsernames[selectedChannelIndex + 1]
    }

    private func startChannelInfoTimer() {
        updateChannelInfos()
        channelInfoTimer?.invalidate()
        channelInfoTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            updateChannelInfos()
        }
    }

    private func updateChannelInfos() {
        Task { @MainActor in
            channelInfos = await manager.getAllChannelInfo()

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
            return info.isOnline && !info.isPaused && !info.isWaitingForRecordingSlot && !info.isInvalid
        case .paused:
            return info.isPaused && !info.isInvalid
        case .offline:
            return !info.isOnline && !info.isPaused && !info.isInvalid
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

private enum RecordingSortOption: String, CaseIterable, Identifiable {
    case newest = "Newest"
    case oldest = "Oldest"
    case largest = "Largest"
    case smallest = "Smallest"
    case filename = "Filename"

    var id: String { rawValue }
}

private struct RecordingLibraryItem: Identifiable, Equatable {
    let path: String
    let filename: String
    let channelName: String
    let fileExtension: String
    let sizeBytes: Int64
    let modifiedAt: Date

    var id: String { path }

    var thumbnailCacheKey: String {
        let modifiedStamp = Int64(modifiedAt.timeIntervalSince1970)
        return "\(path)|\(sizeBytes)|\(modifiedStamp)"
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

        let sourcePath = (item.path as NSString).expandingTildeInPath
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

    @State private var thumbnailPath: String?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.45))

            if let thumbnailPath,
               FileManager.default.fileExists(atPath: thumbnailPath),
               let image = NSImage(contentsOfFile: thumbnailPath) {
                Image(nsImage: image)
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
            thumbnailPath = await RecordingThumbnailStore.shared.thumbnailPath(for: item)
            isLoading = false
        }
    }
}

struct RecordingsLibraryView: View {
    @ObservedObject var manager: ChannelManager

    private static let thumbnailCardMinimumWidth: CGFloat = 260
    private static let thumbnailCardSpacing: CGFloat = 14
    private static let thumbnailCardEstimatedHeight: CGFloat = 230
    private static let thumbnailPrewarmDebounceNanoseconds: UInt64 = 180_000_000

    @State private var allRecordings: [RecordingLibraryItem] = []
    @State private var searchText: String = ""
    @State private var selectedChannelFilter: String = "All Channels"
    @State private var sortOption: RecordingSortOption = .newest
    @State private var isScanning = false
    @State private var scanError: String?
    @State private var refreshTimer: Timer?

    @State private var showingPreview = false
    @State private var previewPaths: [String] = []
    @State private var previewIndex = 0
    @State private var thumbnailPrewarmTask: Task<Void, Never>?
    @State private var thumbnailViewportSize: CGSize = .zero

    private let gridColumns = [GridItem(.adaptive(minimum: Self.thumbnailCardMinimumWidth), spacing: Self.thumbnailCardSpacing)]

    var body: some View {
        GeometryReader { geometry in
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
                            ForEach(channelFilters, id: \.self) { channel in
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

                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 8) {
                        countChip("Total", count: allRecordings.count, tint: .primary)
                        countChip("Showing", count: visibleRecordings.count, tint: .blue)
                        Text("Size: \(formatByteCount(totalVisibleBytes))")
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
                } else if visibleRecordings.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "film.stack")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text(allRecordings.isEmpty ? "No recordings found" : "No matching recordings")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text(allRecordings.isEmpty
                             ? "Recordings are discovered from the target output folder"
                             : "Adjust the search text or filters")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: gridColumns, spacing: Self.thumbnailCardSpacing) {
                            ForEach(visibleRecordings) { item in
                                Button {
                                    openRecordingPreview(for: item)
                                } label: {
                                    RecordingLibraryCardView(item: item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
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
        .sheet(isPresented: $showingPreview) {
            RecordingPreviewSheet(paths: $previewPaths, currentIndex: $previewIndex, isPresented: $showingPreview)
        }
        .onAppear {
            refreshRecordings()
            startRefreshTimer()
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
            thumbnailPrewarmTask?.cancel()
            thumbnailPrewarmTask = nil
        }
        .onChange(of: showingPreview) { isShowing in
            if !isShowing {
                refreshRecordings()
            }
        }
        .onChange(of: visibleRecordings.map(\.thumbnailCacheKey)) { _ in
            scheduleThumbnailPrewarm(debounceNanoseconds: Self.thumbnailPrewarmDebounceNanoseconds)
        }
    }

    private var channelFilters: [String] {
        Array(Set(allRecordings.map { $0.channelName }))
            .sorted { $0.lowercased() < $1.lowercased() }
    }

    private var visibleRecordings: [RecordingLibraryItem] {
        var filtered = allRecordings.filter { item in
            if selectedChannelFilter != "All Channels" && item.channelName != selectedChannelFilter {
                return false
            }

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty { return true }

            return item.filename.localizedCaseInsensitiveContains(query)
                || item.channelName.localizedCaseInsensitiveContains(query)
        }

        switch sortOption {
        case .newest:
            filtered.sort { $0.modifiedAt > $1.modifiedAt }
        case .oldest:
            filtered.sort { $0.modifiedAt < $1.modifiedAt }
        case .largest:
            filtered.sort { $0.sizeBytes > $1.sizeBytes }
        case .smallest:
            filtered.sort { $0.sizeBytes < $1.sizeBytes }
        case .filename:
            filtered.sort { $0.filename.lowercased() < $1.filename.lowercased() }
        }

        return filtered
    }

    private var totalVisibleBytes: Int64 {
        visibleRecordings.reduce(0) { $0 + $1.sizeBytes }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { _ in
            refreshRecordings()
        }
    }

    private func refreshRecordings() {
        let rootPath = manager.appConfig.getOutputPath()
        isScanning = true
        scanError = nil

        Task { @MainActor in
            let recordings = await loadRecordings(rootPath: rootPath)
            allRecordings = recordings

            if selectedChannelFilter != "All Channels",
               !channelFilters.contains(selectedChannelFilter) {
                selectedChannelFilter = "All Channels"
            }
            isScanning = false
            scheduleThumbnailPrewarm(debounceNanoseconds: 0)
        }
    }

    private func scheduleThumbnailPrewarm(debounceNanoseconds: UInt64) {
        thumbnailPrewarmTask?.cancel()

        let prioritizedCount = prioritizedThumbnailCount(for: thumbnailViewportSize)
        let prioritizedItems = Array(visibleRecordings.prefix(prioritizedCount))
        let backgroundItems = Array(visibleRecordings.dropFirst(prioritizedCount))

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

    private func loadRecordings(rootPath: String) async -> [RecordingLibraryItem] {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let normalizedRoot = (rootPath as NSString).expandingTildeInPath
            let rootURL = URL(fileURLWithPath: normalizedRoot, isDirectory: true)

            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return []
            }

            let validExtensions = Set(["ts", "mp4", "mkv", "mov"])
            let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return []
            }

            var items: [RecordingLibraryItem] = []
            while let fileURL = enumerator.nextObject() as? URL {
                let ext = fileURL.pathExtension.lowercased()
                guard validExtensions.contains(ext) else { continue }

                guard let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                      values.isRegularFile == true else {
                    continue
                }

                let sizeBytes = Int64(values.fileSize ?? 0)
                let modifiedAt = values.contentModificationDate ?? Date.distantPast
                let channelName = fileURL.deletingLastPathComponent().lastPathComponent

                items.append(
                    RecordingLibraryItem(
                        path: fileURL.path,
                        filename: fileURL.lastPathComponent,
                        channelName: channelName,
                        fileExtension: ext,
                        sizeBytes: sizeBytes,
                        modifiedAt: modifiedAt
                    )
                )
            }

            return items
        }.value
    }

    private func openRecordingPreview(for item: RecordingLibraryItem) {
        let orderedPaths = visibleRecordings.map { $0.path }
        guard let index = orderedPaths.firstIndex(of: item.path) else { return }

        previewPaths = orderedPaths
        previewIndex = index
        showingPreview = true
    }

    private func countChip(_ title: String, count: Int, tint: Color) -> some View {
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
    }

    private func formatByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private struct RecordingLibraryCardView: View {
    let item: RecordingLibraryItem

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
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
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
    private var isRecording: Bool { info.isOnline && !info.isPaused && !isWaitingForRecordingSlot }
    private var isPausedOnline: Bool { info.isOnline && info.isPaused }
    private var isOffline: Bool { !info.isOnline }
    private var isInvalid: Bool { info.isInvalid }
    private var isDegraded: Bool { info.consecutiveSegmentFailures > 0 }
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
                        .saturation((isRecording || isWaitingOnline) ? 1.0 : (isPausedOnline ? 0.65 : 0.0))
                        .opacity((isRecording || isWaitingOnline) ? 1.0 : (isPausedOnline ? 0.82 : 0.45))
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
                                            : (info.isOnline ? "Recording" : "Offline")))
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

struct ChannelListView: View {
    private struct CombinedLogEntry {
        let sortOrder: Int
        let line: String
        let color: Color
    }

    private struct StatusCounts {
        let total: Int
        let online: Int
        let recording: Int
        let paused: Int
        let offline: Int
        let invalid: Int
    }

    @ObservedObject var manager: ChannelManager
    @Binding var selectedChannel: String?
    let channelInfos: [ChannelInfo]
    @Binding var searchText: String
    @Binding var statusFilter: ChannelStatusFilter
    @Binding var genderFilter: String?
    var onActivateChannel: ((String) -> Void)? = nil
    @State private var showingCombinedLog = true
    
    var body: some View {
        Group {
            if channelInfos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No Channels")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Add a channel to get started")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    VStack(spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            TextField("Filter by username", text: $searchText)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 190, idealWidth: 250, maxWidth: 320)

                            Spacer(minLength: 0)
                        }

                        WrappingStatusBadgesView(
                            statusFilter: $statusFilter,
                            totalCount: statusCounts.total,
                            onlineCount: statusCounts.online,
                            recordingCount: statusCounts.recording,
                            pausedCount: statusCounts.paused,
                            offlineCount: statusCounts.offline,
                            invalidCount: statusCounts.invalid,
                            filteredCount: filteredChannelInfos.count
                        )

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Gender")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                            
                            if availableGenders.isEmpty {
                                Text("Fetching bio data...")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            } else {
                                HStack(spacing: 8) {
                                    Button(action: { genderFilter = nil }) {
                                        HStack(spacing: 4) {
                                            Text("All")
                                                .font(.caption)
                                            if genderFilter == nil {
                                                Image(systemName: "checkmark")
                                                    .font(.caption2)
                                            }
                                        }
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                    }
                                    .buttonStyle(GenderFilterButtonStyle(isSelected: genderFilter == nil))
                                    
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
                                    
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .padding(.vertical, 6)

                        if manager.runtimeDiagnostics.requestQueueSaturated ||
                            manager.runtimeDiagnostics.queuedRecordings > 0 ||
                            manager.runtimeDiagnostics.cloudflareBlockedChannels > 0 ||
                            manager.runtimeDiagnostics.degradedChannels > 0 {
                            HStack(spacing: 8) {
                                Image(systemName: "gauge.with.dots.needle.33percent")
                                    .foregroundColor(.orange)

                                Text("Request pressure: \(manager.runtimeDiagnostics.activeRequests)/\(manager.runtimeDiagnostics.maxConcurrentRequests) active, \(manager.runtimeDiagnostics.queuedRequests) queued")
                                    .font(.caption2)
                                    .lineLimit(1)

                                let recordingCap = manager.runtimeDiagnostics.maxConcurrentRecordings == 0 ? "unlimited" : String(manager.runtimeDiagnostics.maxConcurrentRecordings)
                                Text("Recordings: \(manager.runtimeDiagnostics.activeRecordings)/\(recordingCap), \(manager.runtimeDiagnostics.queuedRecordings) waiting")
                                    .font(.caption2)
                                    .lineLimit(1)

                                if manager.runtimeDiagnostics.cloudflareBlockedChannels > 0 {
                                    Text("Cloudflare: \(manager.runtimeDiagnostics.cloudflareBlockedChannels)")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }

                                if manager.runtimeDiagnostics.degradedChannels > 0 {
                                    Text("Degraded: \(manager.runtimeDiagnostics.degradedChannels)")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(8)
                            .help("Avg queue wait: \(manager.runtimeDiagnostics.averageQueueWaitMs)ms, max observed: \(manager.runtimeDiagnostics.maxQueueWaitMs)ms")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

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
                        List(selection: $selectedChannel) {
                            ForEach(filteredChannelInfos) { info in
                                NavigationLink(value: info.username) {
                                    ChannelRowView(info: info)
                                }
                                .simultaneousGesture(TapGesture().onEnded {
                                    onActivateChannel?(info.username)
                                })
                            }
                        }
                    }

                    Divider()

                    DisclosureGroup(isExpanded: $showingCombinedLog) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                if combinedLogEntries.isEmpty {
                                    Text("No activity yet")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    ForEach(Array(combinedLogEntries.enumerated()), id: \.offset) { _, entry in
                                        Text(entry.line)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundColor(entry.color)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                        }
                        .frame(maxWidth: .infinity, maxHeight: 170)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(8)
                    } label: {
                        HStack {
                            Text("Combined Activity")
                                .font(.caption)
                                .fontWeight(.semibold)
                            Spacer()
                            Text("\(combinedLogEntries.count)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(10)
                    .background(Color(NSColor.controlBackgroundColor))
                }
            }
        }
        .navigationTitle("Channels")
    }

    private var combinedLogEntries: [CombinedLogEntry] {
        let merged = filteredChannelInfos.flatMap { info in
            info.logs.suffix(5).map { log in
                CombinedLogEntry(
                    sortOrder: sortKey(from: log),
                    line: "[\(info.username)] \(log)",
                    color: colorForLog(log, info: info)
                )
            }
        }

        return merged
            .sorted { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder {
                    return lhs.line > rhs.line
                }
                return lhs.sortOrder > rhs.sortOrder
            }
            .suffix(60)
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
            return info.isOnline && !info.isPaused && !info.isWaitingForRecordingSlot && !info.isInvalid
        case .paused:
            return info.isPaused && !info.isInvalid
        case .offline:
            return !info.isOnline && !info.isPaused && !info.isInvalid
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

    private func countChip(_ title: String, count: Int, tint: Color) -> some View {
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
}

struct ChannelRowView: View {
    let info: ChannelInfo

    private var isPausedOnline: Bool {
        info.isPaused && info.isOnline
    }

    private var isInvalid: Bool {
        info.isInvalid
    }

    private var isDegraded: Bool {
        info.consecutiveSegmentFailures > 0
    }

    private var showNoPersonBadge: Bool {
        info.isOnline && info.isNoPersonDetected && !info.isInvalid
    }

    private var hasCloudflarePressure: Bool {
        info.cloudflareBlockCount > 0
    }

    private var isWaitingForRecordingSlot: Bool {
        info.isWaitingForRecordingSlot
    }
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isInvalid ? Color.red : (info.isPaused ? Color.orange : (info.isOnline ? Color.green : Color.gray)))
                    .frame(width: 10, height: 10)
                
                if info.isChecking {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                }
            }
            .frame(width: 10, height: 10)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(info.username)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                HStack(spacing: 8) {
                    if isInvalid {
                        Text("Invalid (404)")
                    } else if info.isPaused {
                        Text(info.isOnline ? "Paused (Online)" : "Paused")
                    } else if isWaitingForRecordingSlot {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                            Text(info.isOnline ? "Waiting For Slot (Online)" : "Waiting For Slot (Rechecking)")
                        }
                        .font(.caption2)
                        .foregroundColor(.blue)
                    } else if info.isOnline {
                        Label(info.duration, systemImage: "clock")
                        Label(info.filesize, systemImage: "doc")
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
                        if hasCloudflarePressure {
                            Text("CF x\(info.cloudflareBlockCount)")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.14))
                                .cornerRadius(6)
                        }
                    } else {
                        Text("Offline")
                    }
                }
                .font(.caption)
                .foregroundColor(isInvalid ? .red : .secondary)

                if let lastOnlineAt = info.lastOnlineAt {
                    Text("Last online: \(lastOnlineAt)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if info.isChecking {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Checking...")
                    }
                    .font(.caption2)
                    .foregroundColor(.accentColor)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isInvalid ? Color.red.opacity(0.10) : (isPausedOnline ? Color.orange.opacity(0.10) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isInvalid ? Color.red.opacity(0.24) : (isPausedOnline ? Color.orange.opacity(0.22) : Color.clear), lineWidth: 1)
        )
    }
}

struct ChannelDetailView: View {
    @ObservedObject var manager: ChannelManager
    let username: String
    var onPrevious: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil
    var canGoPrevious: Bool = false
    var canGoNext: Bool = false
    var onEdit: (() -> Void)? = nil
    var onDeleted: (() -> Void)? = nil
    @State private var info: ChannelInfo?
    @State private var timer: Timer?
    @State private var showingDeleteConfirmation = false
    @State private var recordingPreviewPaths: [String] = []
    @State private var selectedRecordingIndex: Int = 0
    @State private var showingRecordingPreview = false
    @State private var recordingsCache: [String] = []
    @State private var recordingsScanTask: Task<Void, Never>?
    @State private var lastRecordingsScanKey: String = ""
    
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
        .onChange(of: showingRecordingPreview) { isShowing in
            if !isShowing {
                refreshRecordingsCacheIfNeeded(force: true)
            }
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
        .sheet(isPresented: $showingRecordingPreview) {
            if !recordingPreviewPaths.isEmpty,
               recordingPreviewPaths.indices.contains(selectedRecordingIndex) {
                RecordingPreviewSheet(
                    paths: $recordingPreviewPaths,
                    currentIndex: $selectedRecordingIndex,
                    isPresented: $showingRecordingPreview
                )
            }
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
                            .fill(info.isInvalid ? Color.red : (info.isPaused ? Color.orange : (info.isOnline ? Color.green : Color.gray)))
                            .frame(width: 10, height: 10)
                        Text(info.isInvalid ? "Invalid (404)" : (info.isPaused ? (info.isOnline ? "Paused (Online)" : "Paused") : (info.isOnline ? "Recording" : "Offline")))
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
                    manager.openChannelPage(username: username)
                }) {
                    Label("Open Channel Page", systemImage: "link")
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
    
    private func updateInfo() {
        Task { @MainActor in
            info = await manager.getChannelInfo(username: username)
            refreshRecordingsCacheIfNeeded(force: false)
        }
    }

    @ViewBuilder
    private func recordingsSection(info: ChannelInfo) -> some View {
        let existingRecordings = recordingsCache
        let activeRecordingPath = info.filename.map { ($0 as NSString).expandingTildeInPath }
        let previewableRecordings = existingRecordings.filter { recording in
            guard let activeRecordingPath else { return true }
            return recording != activeRecordingPath
        }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recordings")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Spacer()

                if !existingRecordings.isEmpty {
                    Button(action: {
                        recordingPreviewPaths = previewableRecordings
                        selectedRecordingIndex = previewableRecordings.count - 1
                        showingRecordingPreview = true
                    }) {
                        Text("View All")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                }
            }

            HStack(spacing: 4) {
                Text("\(existingRecordings.count) video\(existingRecordings.count == 1 ? "" : "s") found")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("• app recorded \(info.recordings.count) session\(info.recordings.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if existingRecordings.isEmpty {
                Text("No video files found in destination folder")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        if let activeRecordingPath,
                           FileManager.default.fileExists(atPath: activeRecordingPath) {
                            Text("\((activeRecordingPath as NSString).lastPathComponent) (recording)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.green)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        ForEach(previewableRecordings.suffix(10).reversed(), id: \.self) { recording in
                            Button {
                                if let index = previewableRecordings.firstIndex(of: recording) {
                                    recordingPreviewPaths = previewableRecordings
                                    selectedRecordingIndex = index
                                    showingRecordingPreview = true
                                }
                            } label: {
                                Text((recording as NSString).lastPathComponent)
                                    .font(.system(.caption2, design: .monospaced))
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }

                        if previewableRecordings.count > 10 {
                            Text("+ \(previewableRecordings.count - 10) more (click View All)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .italic()
                        }
                    }
                }
                .frame(maxHeight: 96)
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
            info.recordingsDirectory,
            String(info.recordings.count),
            info.filename ?? "",
            String(info.isOnline),
            String(info.isPaused)
        ].joined(separator: "|")

        if !force, scanKey == lastRecordingsScanKey {
            return
        }

        lastRecordingsScanKey = scanKey
        recordingsScanTask?.cancel()

        let snapshot = info
        recordingsScanTask = Task(priority: .utility) {
            let scanned = Self.recordingsOnDisk(info: snapshot)
            if Task.isCancelled { return }

            await MainActor.run {
                recordingsCache = scanned
            }
        }
    }

    private func responsiveDetailWidth(totalWidth: CGFloat) -> CGFloat {
        let target = totalWidth * 0.29
        return min(max(target, 300), 380)
    }

    private static func recordingsOnDisk(info: ChannelInfo) -> [String] {
        var paths = Set<String>()

        for tracked in info.recordings {
            let normalized = (tracked as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: normalized) {
                paths.insert(normalized)
            }
        }

        let directoryPath = (info.recordingsDirectory as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: directoryPath),
           let fileNames = try? FileManager.default.contentsOfDirectory(atPath: directoryPath) {
            for fileName in fileNames {
                let lower = fileName.lowercased()
                guard lower.hasSuffix(".ts") || lower.hasSuffix(".mp4") || lower.hasSuffix(".mkv") || lower.hasSuffix(".mov") else {
                    continue
                }
                let fullPath = (directoryPath as NSString).appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: fullPath) {
                    paths.insert(fullPath)
                }
            }
        }

        return paths.sorted(by: recordingSortComparator)
    }

    private static func recordingSortComparator(_ lhs: String, _ rhs: String) -> Bool {
        let lhsDate = (try? FileManager.default.attributesOfItem(atPath: lhs)[.modificationDate] as? Date) ?? Date.distantPast
        let rhsDate = (try? FileManager.default.attributesOfItem(atPath: rhs)[.modificationDate] as? Date) ?? Date.distantPast
        if lhsDate == rhsDate {
            return lhs < rhs
        }
        return lhsDate < rhsDate
    }

    private func colorForDetailLog(_ log: String, info: ChannelInfo) -> Color {
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

    private func copyActivityLogs(_ logs: [String]) {
        guard !logs.isEmpty else { return }
        let text = logs.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @ViewBuilder
    private func previewView(info: ChannelInfo) -> some View {
        if let thumbnailPath = info.thumbnailPath,
           FileManager.default.fileExists(atPath: thumbnailPath),
           let nsImage = NSImage(contentsOfFile: thumbnailPath) {
            ZStack {
                Color(NSColor.controlBackgroundColor).opacity(0.3)

                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .saturation(info.isOnline ? 1.0 : 0.0)
                    .opacity(info.isOnline ? 1.0 : 0.45)
                    .overlay(
                        Group {
                            if !info.isOnline {
                                Color.black.opacity(0.2)
                            }
                        }
                    )
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16/9, contentMode: .fit)
            .clipped()
            .cornerRadius(10)
        } else if info.isOnline {
            ZStack {
                Rectangle()
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
                VStack(spacing: 8) {
                    Image(systemName: "video.fill")
                        .font(.title)
                        .foregroundColor(.secondary)
                    Text("Generating preview...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16/9, contentMode: .fit)
            .cornerRadius(10)
        } else {
            ZStack {
                Rectangle()
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.3))
                Image(systemName: "video.slash")
                    .font(.title)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16/9, contentMode: .fit)
            .cornerRadius(10)
        }
    }
}

struct RecordingPreviewSheet: View {
    @Binding var paths: [String]
    @Binding var currentIndex: Int
    @Binding var isPresented: Bool
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

        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: currentURL, resultingItemURL: &resultingURL)

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

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
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
                InfoCard(title: "Max Duration", value: info.maxDuration, icon: "timer")
                InfoCard(title: "Max File Size", value: info.maxFilesize, icon: "externaldrive")
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
                detailRow(
                    label: "Person Detection",
                    value: info.isNoPersonDetected
                        ? "No person detected for \(formatNoPersonDuration(info.noPersonDurationSeconds))"
                        : "Person detected",
                    valueColor: info.isNoPersonDetected ? .orange : .primary
                )
            }

            detailRow(label: "Segment Retries", value: "\(info.segmentRetryCount)")

            detailRow(
                label: "Consecutive Segment Failures",
                value: "\(info.consecutiveSegmentFailures)",
                valueColor: info.consecutiveSegmentFailures > 0 ? .orange : .primary
            )

            if let lastFailureAt = info.lastSegmentFailureAt {
                detailRow(label: "Last Segment Failure", value: lastFailureAt, valueColor: .orange)
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
    
    @State private var username = ""
    @State private var resolution = 1080
    @State private var framerate = 30
    @State private var maxDuration = 0
    @State private var maxFilesize = 0
    @State private var outputDirectory = ""
    @State private var pattern = "{{.Username}}_{{.Year}}-{{.Month}}-{{.Day}}_{{.Hour}}-{{.Minute}}-{{.Second}}{{if .Sequence}}_{{.Sequence}}{{end}}"
    
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
                                    Text("Max Duration")
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
                                    Text("Max File Size")
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
                
                Button("Add Channel") {
                    addChannel()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(24)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 600, height: 640)
    }
    
    private func addChannel() {
        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)
        guard !trimmedUsername.isEmpty else { return }
        
        let config = ChannelConfig(
            username: trimmedUsername,
            outputDirectory: outputDirectory,
            framerate: framerate,
            resolution: resolution,
            pattern: pattern,
            maxDuration: maxDuration,
            maxFilesize: maxFilesize
        )
        
        Task { @MainActor in
            do {
                try await manager.createChannel(config: config)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
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
                                        Text("Max Duration")
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
                                        Text("Max File Size")
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
