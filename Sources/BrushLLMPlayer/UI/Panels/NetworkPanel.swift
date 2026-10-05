import SwiftUI
import AppKit

/// Network panel with two tabs, decoupling direct stream playback from
/// WebDAV media-server management:
/// - Tab 1 (Stream): centered URL input with a play action; the low-frequency
///   User-Agent setting is folded into a collapsed "Advanced" section.
/// - Tab 2 (Servers): WebDAV source list, structured add form and browser.
///
/// Visual language: dark glass cards (white/5 fill, 12pt radius, white/10
/// hairline border), brand-violet primary buttons, and a custom focus
/// treatment on text fields (no system blue ring).
struct NetworkPanel: View {
    enum Tab {
        case stream
        case servers
    }

    @State private var tab: Tab = .stream

    let onPlay: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            segmentedControl

            Divider().overlay(BrushLLMPlayerTheme.controlSeparator)

            switch tab {
            case .stream:
                StreamTab(onPlay: onPlay)
            case .servers:
                ServersTab(onPlay: onPlay)
            }
        }
        .frame(minWidth: 540, minHeight: 460)
        .background(BrushLLMPlayerTheme.panelMaterial)
    }

    // MARK: - Segmented control

    /// Custom segmented control — the system one follows the system accent
    /// color; this one stays in the panel's neutral glass language. A close
    /// button sits at the trailing edge.
    private var segmentedControl: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                tabButton(L("network.tab.url", "Stream URL"), target: .stream)
                tabButton(L("network.tab.servers", "Media Servers"), target: .servers)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                    .frame(width: 26, height: 26)
                    .background {
                        Circle().fill(Color.white.opacity(0.06))
                    }
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(L("panel.cancel", "Cancel"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func tabButton(_ title: String, target: Tab) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { tab = target }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tab == target ? BrushLLMPlayerTheme.controlText : BrushLLMPlayerTheme.controlTextSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background {
                    if tab == target {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.white.opacity(0.1))
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared pieces

/// Glass card treatment for input groups: white/5 fill, 12pt radius,
/// white/10 hairline; a focused card gets a subtle brand-violet edge.
struct GlassCard: ViewModifier {
    var focused: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(focused ? BrushPalette.violet.opacity(0.55) : Color.white.opacity(0.1),
                                  lineWidth: 1)
            }
    }
}

/// Primary action button: solid brand violet with a bold white label —
/// the panel's single prominent-action style.
struct VioletProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(BrushPalette.violet)
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - Tab 1: Stream URL

private struct StreamTab: View {
    @ObservedObject private var settings = AppSettings.shared
    let onPlay: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var showAdvanced = false
    @FocusState private var urlFocused: Bool

    private var trimmedURL: String {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 28)

            // Hero
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(BrushPalette.violet.opacity(0.85))
            Text(L("network.tab.url", "Stream URL"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(BrushLLMPlayerTheme.controlText)
                .padding(.top, 10)

            // URL input card + play
            HStack(spacing: 10) {
                TextField(L("panel.url.hint", "Direct media link or m3u8/HLS address"), text: $urlText)
                    .textFieldStyle(.plain)
                    .focused($urlFocused)
                    .font(.system(size: 13))
                    .foregroundStyle(BrushLLMPlayerTheme.controlText)
                    .onSubmit(play)
                Button(action: play) {
                    Text(L("panel.url.open", "Play"))
                }
                .buttonStyle(VioletProminentButtonStyle())
                .disabled(trimmedURL.isEmpty)
                .opacity(trimmedURL.isEmpty ? 0.45 : 1)
            }
            .modifier(GlassCard(focused: urlFocused))
            .padding(.horizontal, 28)
            .padding(.top, 22)

            // Paste from clipboard
            Button {
                if let clipboard = NSPasteboard.general.string(forType: .string),
                   !clipboard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    urlText = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
                    urlFocused = true
                }
            } label: {
                Label(L("network.paste", "Paste from Clipboard"), systemImage: "doc.on.clipboard")
                    .font(.system(size: 12))
                    .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background {
                        Capsule().fill(Color.white.opacity(0.06))
                    }
            }
            .buttonStyle(.plain)
            .padding(.top, 14)

            Spacer()

            advancedSection
        }
    }

    private func play() {
        guard !trimmedURL.isEmpty, let url = URL(string: trimmedURL) else { return }
        dismiss()
        onPlay(url)
    }

    // MARK: Advanced (collapsed by default)

    /// The User-Agent is a low-frequency setting: folded away by default so
    /// the main interface stays clean.
    private var advancedSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                    Text(L("network.advanced", "Advanced Settings"))
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(showAdvanced ? 180 : 0))
                }
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if showAdvanced {
                VStack(spacing: 14) {
                    userAgentRow
                    bufferRows
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .background(Color.white.opacity(0.03))
    }

    private var userAgentRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("network.user-agent", "User-Agent"))
                .font(.caption)
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
            HStack {
                TextField("", text: $settings.userAgent)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(BrushLLMPlayerTheme.controlText)
                Button {
                    settings.userAgent = AppSettings.defaultUserAgent
                } label: {
                    Text(L("network.user-agent-reset", "Reset"))
                        .font(.caption)
                        .foregroundStyle(BrushPalette.violet300)
                }
                .buttonStyle(.plain)
            }
            .modifier(GlassCard())
            Text(L("network.user-agent-hint", "Sent with every network request; a browser UA passes most CDNs."))
                .font(.system(size: 10))
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary.opacity(0.7))
        }
    }

    /// Demuxer read-ahead and buffer size — the tunable knobs behind smooth
    /// network playback. (The demuxer itself always runs on its own thread.)
    private var bufferRows: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(L("network.readahead", "Read-ahead"))
                    .font(.caption)
                    .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                    .frame(width: 64, alignment: .leading)
                Slider(value: $settings.readaheadSeconds, in: 5...120, step: 5)
                    .tint(BrushPalette.violet)
                Text("\(Int(settings.readaheadSeconds))s")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                    .frame(width: 34, alignment: .trailing)
            }
            HStack(spacing: 12) {
                Text(L("network.buffer", "Buffer"))
                    .font(.caption)
                    .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                    .frame(width: 64, alignment: .leading)
                Slider(value: $settings.bufferMB, in: 16...512, step: 16)
                    .tint(BrushPalette.violet)
                Text("\(Int(settings.bufferMB))MB")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                    .frame(width: 34, alignment: .trailing)
            }
            Text(L("network.buffer-hint", "The demuxer thread buffers ahead of playback; larger values smooth unstable networks."))
                .font(.system(size: 10))
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary.opacity(0.7))
        }
    }
}


// MARK: - Tab 2: Media servers (WebDAV / SMB / FTP / Emby / Jellyfin)

private struct ServersTab: View {
    @ObservedObject var store = MediaServerStore.shared
    let onPlay: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var showAddForm = false
    /// The server being edited; the add form reopens pre-filled.
    @State private var editingSource: MediaServerSource?
    /// The server currently being browsed; nil = server list.
    @State private var browsingSourceID: UUID?
    @State private var pathStack: [String] = []
    @State private var items: [MediaItem] = []
    @State private var isLoading = false
    /// True while a folder's contents are being fetched for the playlist.
    @State private var browserAddingFolder = false
    @State private var errorMessage: String?

    private var browsingSource: MediaServerSource? {
        store.sources.first { $0.id == browsingSourceID }
    }

    var body: some View {
        Group {
            if showAddForm {
                AddServerForm(store: store, editing: editingSource) { source in
                    showAddForm = false
                    editingSource = nil
                    enterBrowser(source)
                } onCancel: {
                    showAddForm = false
                    editingSource = nil
                }
            } else if let source = browsingSource {
                BrowserView(
                    source: source,
                    pathStack: $pathStack,
                    items: items,
                    isLoading: isLoading,
                    errorMessage: errorMessage,
                    onReload: reload,
                    onExit: {
                        MediaServerBrowser.disconnect(source: source)
                        browsingSourceID = nil
                    },
                    onPlay: { url in
                        dismiss()
                        onPlay(url)
                    },
                    onAddFolderToPlaylist: { folder in
                        browserAddingFolder = true
                        addFolderToPlaylist(source: source, folder: folder)
                    },
                    addingFolder: browserAddingFolder
                )
            } else {
                serverList
            }
        }
    }

    /// Adds a folder's playable files to the playlist: lists the folder,
    /// filters playable extensions, builds playback URLs, enqueues them,
    /// then opens the playlist sidebar so the result is visible.
    private func addFolderToPlaylist(source: MediaServerSource, folder: MediaItem) {
        Task { @MainActor in
            defer { Task { @MainActor in browserAddingFolder = false } }
            do {
                let children = try await MediaServerBrowser.list(source: source, path: folder.id)
                let playable = children.filter { item in
                    !item.isDirectory
                    && !item.name.hasPrefix(".")
                    && MediaTypes.playableExtensions.contains(
                        URL(fileURLWithPath: item.name).pathExtension.lowercased())
                }
                var urls: [URL] = []
                for item in playable {
                    if let url = await MediaServerBrowser.playbackURL(source: source, item: item) {
                        urls.append(url)
                    }
                }
                let count = PlayerCore.sharedForSettings.enqueue(urls)
                if count > 0 {
                    NotificationCenter.default.post(name: .brushPlayerShowPlaylist, object: nil)
                }
                DebugLog.log("add-folder: \(count) of \(children.count) items enqueued from \(folder.name)")
            } catch {
                DebugLog.log("add-folder failed: \(error)")
            }
        }
    }

    // MARK: Server list

    private var serverList: some View {
        Group {
            if store.sources.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(store.sources) { source in
                            serverCard(source)
                        }
                        addServerCard
                    }
                    .padding(16)
                }
            }
        }
    }

    private func serverCard(_ source: MediaServerSource) -> some View {
        HStack(spacing: 12) {
            Image(systemName: source.kind.icon)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(BrushPalette.violet300)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(source.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BrushLLMPlayerTheme.controlText)
                        .lineLimit(1)
                    Text(source.kind.rawValue.uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(BrushPalette.violet300)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background {
                            Capsule().fill(BrushPalette.violet.opacity(0.18))
                        }
                }
                Text(Self.hostLabel(of: source))
                    .font(.system(size: 11))
                    .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(L("webdav.connect-server", "Connect")) {
                enterBrowser(source)
            }
            .buttonStyle(VioletProminentButtonStyle())
            Button {
                editingSource = source
                showAddForm = true
            } label: {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help(L("webdav.edit", "Edit"))
            Button {
                MediaServerBrowser.disconnect(source: source)
                store.remove(source)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help(L("panel.delete", "Delete"))
        }
        .modifier(GlassCard())
    }

    private var addServerCard: some View {
        Button {
            showAddForm = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14))
                Text(L("webdav.add", "Add Server…"))
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(BrushPalette.violet300)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.03))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(BrushPalette.violet.opacity(0.7))
            Text(L("media.empty", "No media servers configured"))
                .font(.callout)
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
            Button(L("webdav.add", "Add Server…")) {
                showAddForm = true
            }
            .buttonStyle(VioletProminentButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// scheme://host[:port] of a source, for the card subtitle.
    private static func hostLabel(of source: MediaServerSource) -> String {
        guard let components = URLComponents(string: source.baseURL), let host = components.host else {
            return source.baseURL
        }
        var label = host
        if let port = components.port {
            label += ":\(port)"
        }
        return label
    }

    // MARK: Browsing

    private func enterBrowser(_ source: MediaServerSource) {
        browsingSourceID = source.id
        pathStack = [MediaServerBrowser.rootPath(of: source)]
        reload()
    }

    private func reload() {
        guard let source = browsingSource else { return }
        isLoading = true
        errorMessage = nil
        items = []
        let path = pathStack.last ?? MediaServerBrowser.rootPath(of: source)
        Task {
            do {
                let loaded = try await MediaServerBrowser.list(source: source, path: path)
                await MainActor.run {
                    items = loaded
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - Browser (item list of one server)

private struct BrowserView: View {
    let source: MediaServerSource
    @Binding var pathStack: [String]
    let items: [MediaItem]
    let isLoading: Bool
    let errorMessage: String?
    let onReload: () -> Void
    let onExit: () -> Void
    let onPlay: (URL) -> Void
    /// Adds a folder's playable files to the playlist (context menu).
    let onAddFolderToPlaylist: (MediaItem) -> Void
    /// True while the folder listing is being fetched (parent state).
    var addingFolder = false

    @ObservedObject private var settings = AppSettings.shared

    private var currentPath: String {
        pathStack.last ?? "/"
    }

    /// Cached sorted items — recomputed only when items or the sort change.
    private var sortedItems: [MediaItem] {
        settings.mediaSort.apply(items, ascending: settings.mediaSortAscending)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header: back / server / path
            HStack(spacing: 10) {
                Button {
                    if pathStack.count > 1 {
                        pathStack.removeLast()
                        onReload()
                    } else {
                        onExit()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BrushLLMPlayerTheme.controlText)
                }
                .buttonStyle(.plain)
                .help(L("webdav.back", "Back"))

                Image(systemName: source.kind.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(BrushPalette.violet300)
                Text(source.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BrushLLMPlayerTheme.controlText)
                if source.kind != .emby && source.kind != .jellyfin {
                    Text(currentPath)
                        .font(.system(size: 11))
                        .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer()

                if addingFolder {
                    ProgressView()
                        .scaleEffect(0.7)
                        .help(L("browser.adding-folder", "Adding…"))
                }
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                sortMenu
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().overlay(BrushLLMPlayerTheme.controlSeparator)

            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26))
                    .foregroundStyle(BrushPalette.orange)
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                Button(L("webdav.retry", "Retry")) { onReload() }
                    .buttonStyle(VioletProminentButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty && !isLoading {
            Text(L("webdav.empty-folder", "Empty folder"))
                .font(.callout)
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(sortedItems) { item in
                        row(item)
                    }
                }
                .padding(12)
            }
        }
    }

    /// The sort menu: three modes, each toggleable between ascending and
    /// descending with an arrow indicator.
    private var sortMenu: some View {
        Menu {
            ForEach([MediaSortMode.name, .modified, .size], id: \.self) { mode in
                Button {
                    if settings.mediaSort == mode {
                        settings.mediaSortAscending.toggle()
                    } else {
                        settings.mediaSort = mode
                        settings.mediaSortAscending = true
                    }
                } label: {
                    let label = sortLabel(mode)
                    if settings.mediaSort == mode {
                        let arrow = settings.mediaSortAscending ? "↑" : "↓"
                        Text("\(label) \(arrow)")
                    } else {
                        Text(label)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 26, height: 20)
        .help(L("browser.sort", "Sort"))
    }

    private func sortLabel(_ mode: MediaSortMode) -> String {
        switch mode {
        case .name: return L("browser.sort.name", "Name")
        case .modified: return L("browser.sort.modified", "Modified")
        case .size: return L("browser.sort.size", "Size")
        }
    }

    private func row(_ item: MediaItem) -> some View {
        Button {
            if item.isDirectory {
                pathStack.append(item.id)
                onReload()
            } else {
                // Playback URL resolution is async for Emby/Jellyfin (token).
                Task { @MainActor in
                    if let url = await MediaServerBrowser.playbackURL(source: source, item: item) {
                        onPlay(url)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon(for: item))
                    .font(.system(size: 12))
                    .foregroundStyle(BrushPalette.violet300)
                Text(item.name)
                    .font(.callout)
                    .foregroundStyle(BrushLLMPlayerTheme.controlText)
                    .lineLimit(1)
                Spacer()
                if !item.isDirectory {
                    if item.size > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                            .font(.system(size: 10))
                            .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                    }
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background {
                            Circle().fill(BrushPalette.violet)
                        }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.03))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if item.isDirectory {
                Button {
                    onAddFolderToPlaylist(item)
                } label: {
                    Label(L("browser.add-to-playlist", "Add to Playlist"), systemImage: "text.badge.plus")
                }
            }
        }
    }

    /// Emby folders are libraries, not plain directories — still folder icon;
    /// playable video items get a film icon.
    private func icon(for item: MediaItem) -> String {
        if item.isDirectory { return "folder.fill" }
        if source.kind == .emby || source.kind == .jellyfin { return "film" }
        return "doc"
    }
}

// MARK: - Add server form (kind-aware)

private struct AddServerForm: View {
    @ObservedObject var store = MediaServerStore.shared
    /// When set, the form edits this server instead of adding one.
    let editing: MediaServerSource?
    let onAdded: (MediaServerSource) -> Void
    let onCancel: () -> Void

    @State private var kind: MediaServerKind = .webdav
    @State private var newName = ""
    @State private var newScheme = "https"
    @State private var newHost = ""
    @State private var newPort = ""
    @State private var newPath = ""
    @State private var newUsername = ""
    @State private var newPassword = ""
    @State private var didPrefill = false

    /// The connection string composed from the structured fields.
    private var composedBaseURL: String {
        let host = newHost.trimmingCharacters(in: .whitespaces)
        let port = newPort.trimmingCharacters(in: .whitespaces)
        var path = newPath.trimmingCharacters(in: .whitespaces)
        if !path.isEmpty && !path.hasPrefix("/") { path = "/" + path }
        switch kind {
        case .webdav:
            var base = "\(newScheme)://\(host)"
            if !port.isEmpty { base += ":\(port)" }
            if !path.isEmpty { base += path }
            return base
        case .smb:
            // path = the share name.
            let share = path.isEmpty ? "" : (path.hasPrefix("/") ? path : "/" + path)
            return "smb://\(host)\(share)"
        case .ftp:
            var base = "ftp://\(host)"
            if !port.isEmpty { base += ":\(port)" }
            if !path.isEmpty { base += path }
            return base
        case .emby, .jellyfin:
            var base = "\(newScheme)://\(host)"
            if !port.isEmpty { base += ":\(port)" }
            return base
        }
    }

    /// The field set adapts to the selected kind.
    private var requiredFieldsFilled: Bool {
        !newHost.trimmingCharacters(in: .whitespaces).isEmpty
            && (kind != .smb || !newPath.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                kindPicker

                fieldRow(L("webdav.title", "Title")) {
                    TextField("NAS", text: $newName)
                        .textFieldStyle(.plain)
                }

                if kind == .webdav || kind == .emby || kind == .jellyfin {
                    fieldRow(L("webdav.scheme", "Protocol")) {
                        Picker("", selection: $newScheme) {
                            Text("https").tag("https")
                            Text("http").tag("http")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 140)
                    }
                }

                fieldRow(L("webdav.host", "Host")) {
                    TextField(placeholderHost, text: $newHost)
                        .textFieldStyle(.plain)
                }

                if kind == .smb {
                    fieldRow(L("webdav.share", "Share")) {
                        TextField("media", text: $newPath)
                            .textFieldStyle(.plain)
                    }
                } else if kind != .emby && kind != .jellyfin {
                    fieldRow(L("webdav.port", "Port")) {
                        TextField(placeholderPort, text: $newPort)
                            .textFieldStyle(.plain)
                    }
                    fieldRow(L("webdav.path", "Path")) {
                        TextField("/dav", text: $newPath)
                            .textFieldStyle(.plain)
                    }
                } else {
                    fieldRow(L("webdav.port", "Port")) {
                        TextField("8096", text: $newPort)
                            .textFieldStyle(.plain)
                    }
                }

                fieldRow(L("webdav.username", "Username")) {
                    TextField("", text: $newUsername)
                        .textFieldStyle(.plain)
                }
                fieldRow(L("webdav.password", "Password")) {
                    SecureField("", text: $newPassword)
                        .textFieldStyle(.plain)
                }
                Text(L("webdav.password-keychain", "The password is stored in the Keychain."))
                    .font(.system(size: 10))
                    .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary.opacity(0.7))

                if !newHost.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(composedBaseURL)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.03))
                        }
                }

                HStack {
                    Button(L("panel.cancel", "Cancel"), action: onCancel)
                        .buttonStyle(.plain)
                        .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                    Spacer()
                    Button(editing == nil
                           ? L("webdav.connect", "Add & Connect")
                           : L("webdav.save", "Save")) { add() }
                        .buttonStyle(VioletProminentButtonStyle())
                        .disabled(!requiredFieldsFilled)
                        .opacity(requiredFieldsFilled ? 1 : 0.45)
                }
                .padding(.top, 6)
            }
            .padding(20)
        }
        .onAppear {
            prefillIfEditing()
        }
    }

    /// Decomposes the editing source's baseURL back into the structured
    /// fields so the form opens exactly as it was added.
    private func prefillIfEditing() {
        guard !didPrefill, let source = editing else { return }
        didPrefill = true
        kind = source.kind
        newName = source.name
        newUsername = source.username
        newPassword = store.password(for: source) ?? ""
        guard let url = URL(string: source.baseURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            newHost = source.baseURL
            return
        }
        newScheme = components.scheme ?? "https"
        newHost = components.host ?? ""
        if let port = components.port {
            newPort = String(port)
        }
        switch source.kind {
        case .smb:
            // path = the share name (leading slash stripped for the field)
            newPath = (components.path.isEmpty ? "" : String(components.path.dropFirst()))
        default:
            newPath = components.path
        }
    }

    private var placeholderHost: String {
        switch kind {
        case .webdav: return "cloud.example.com"
        case .smb: return "192.168.1.10"
        case .ftp: return "ftp.example.com"
        case .emby, .jellyfin: return "media.example.com"
        }
    }

    private var placeholderPort: String {
        switch kind {
        case .webdav: return newScheme == "https" ? "443" : "80"
        case .ftp: return "21"
        default: return "8096"
        }
    }

    /// Capsule chips for the server type.
    private var kindPicker: some View {
        HStack(spacing: 6) {
            ForEach(MediaServerKind.allCases) { candidate in
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { kind = candidate }
                } label: {
                    Text(candidate.rawValue.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(kind == candidate ? .white : BrushLLMPlayerTheme.controlTextSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background {
                            Capsule().fill(kind == candidate ? BrushPalette.violet : Color.white.opacity(0.06))
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Label + input in one glass card row.
    private func fieldRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                .frame(width: 64, alignment: .leading)
            content()
                .font(.system(size: 13))
                .foregroundStyle(BrushLLMPlayerTheme.controlText)
        }
        .modifier(GlassCard())
    }

    private func add() {
        let host = newHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        if var source = editing {
            source.kind = kind
            source.name = newName.isEmpty ? host : newName
            source.baseURL = composedBaseURL
            source.username = newUsername
            store.update(source, password: newPassword)
            onAdded(source)
        } else {
            let source = store.add(kind: kind,
                                   name: newName.isEmpty ? host : newName,
                                   baseURL: composedBaseURL,
                                   username: newUsername,
                                   password: newPassword)
            onAdded(source)
        }
    }
}
