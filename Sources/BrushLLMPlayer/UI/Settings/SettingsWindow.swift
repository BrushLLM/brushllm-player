import SwiftUI

/// The app settings window (⌘,): General, Playback, Video.
struct SettingsWindow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label(L("settings.general", "General"), systemImage: "gearshape") }
            PlaybackSettingsTab()
                .tabItem { Label(L("settings.playback", "Playback"), systemImage: "play.circle") }
            VideoSettingsTab()
                .tabItem { Label(L("settings.video", "Video"), systemImage: "rectangle.on.rectangle") }
            SubtitleSettingsTab()
                .tabItem { Label(L("settings.subtitle", "Subtitles"), systemImage: "captions.bubble") }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // A grouped Form scrolls internally. The ScrollViewReader lets a
        // finished check auto-scroll to the status card (which sits below
        // the fold — the Settings window sizes to the content's initial
        // ideal height and does not grow when the card appears).
        ScrollViewReader { proxy in
            Form {
            Section(L("settings.general.language", "Language")) {
                Picker(L("settings.general.language", "Language"), selection: $settings.language) {
                    ForEach(Localization.supportedLanguages) { option in
                        Text(option.displayName)
                            .tag(option.code)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 280, alignment: .leading)

                Text(L("settings.general.language-note", "The change applies to most of the interface immediately."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("settings.storage", "Storage")) {
                directoryRow(L("settings.screenshot-dir", "Screenshot folder"),
                             path: $settings.screenshotDirectory)
                directoryRow(L("settings.recording-dir", "Recording folder"),
                             path: $settings.recordingDirectory)
            }

            Section(L("settings.about", "About")) {
                UpdateCheckerSection(scrollToCard: { card in
                    withAnimation { proxy.scrollTo(card, anchor: .bottom) }
                })
            }
            }
        }
    }

    /// A row showing the current folder with a Choose… button.
    private func directoryRow(_ label: String, path: Binding<String>) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Text((path.wrappedValue as NSString).lastPathComponent.isEmpty
                     ? path.wrappedValue
                     : (path.wrappedValue as NSString).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button(L("settings.choose", "Choose…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.canCreateDirectories = true
                    panel.allowedContentTypes = [.folder]
                    panel.directoryURL = URL(fileURLWithPath: path.wrappedValue)
                    if panel.runModal() == .OK, let url = panel.url {
                        path.wrappedValue = url.path
                    }
                }
                .fixedSize()
            }
        }
    }
}

// MARK: - About / updates

/// Current version, a manual check-for-updates button and a status card.
/// No automatic checks or downloads by design.
private struct UpdateCheckerSection: View {
    private enum CheckState: Equatable {
        case idle
        case checking
        case upToDate
        case available(latest: String)
        case failed
    }

    /// Scrolls the enclosing scroll view to the status card; called when a
    /// check completes so the result is always brought into view.
    var scrollToCard: (String) -> Void = { _ in }

    @State private var state: CheckState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("BrushLLM Player")
                    .font(.headline)
                Spacer()
                Text("\(L("update.current", "Current version")) v\(UpdateChecker.currentVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(L("update.check", "Check for Updates")) {
                Task { await check() }
            }
            .fixedSize()
            .disabled(state == .checking)

            statusCard
                .id(Self.cardID)
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    private static let cardID = "update-status-card"

    private func check() async {
        state = .checking
        switch await UpdateChecker.check() {
        case .upToDate: state = .upToDate
        case .available(let latest): state = .available(latest: latest)
        case .failed(let detail):
            DebugLog.log("update check failed: \(detail)")
            state = .failed
        }
        // Let SwiftUI commit the state change first — scrolling to a view
        // that doesn't exist yet is a no-op.
        DispatchQueue.main.async {
            scrollToCard(Self.cardID)
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        switch state {
        case .idle:
            EmptyView()
        case .checking:
            card(background: Color.primary.opacity(0.06), text: L("update.checking", "Checking for updates…")) {
                ProgressView()
                    .controlSize(.small)
            }
        case .upToDate:
            card(background: Color.green.opacity(0.15),
                 text: "\(L("update.up-to-date", "Up to date")) — v\(UpdateChecker.currentVersion)") {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .available(let latest):
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(BrushLLMPlayerTheme.accent)
                Text("\(L("update.available", "New version available")) — v\(latest)")
                    .font(.callout)
                    .foregroundStyle(BrushLLMPlayerTheme.accent)
                Spacer()
                Button(L("update.download", "Download Update")) {
                    NSWorkspace.shared.open(UpdateChecker.releasePageURL)
                }
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(BrushLLMPlayerTheme.accent.opacity(0.12), in: .rect(cornerRadius: 8))
        case .failed:
            card(background: Color.red.opacity(0.15),
                 text: L("update.failed", "Check failed: network error")) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
    }

    private func card(background: Color, text: String, @ViewBuilder icon: () -> some View) -> some View {
        HStack(spacing: 10) {
            icon()
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(background, in: .rect(cornerRadius: 8))
    }
}

// MARK: - Playback

private struct PlaybackSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section(L("settings.playback", "Playback")) {
                LabeledContent(L("settings.playback.volume", "Default volume")) {
                    Slider(value: $settings.defaultVolume, in: 0...130)
                        .tint(BrushPalette.violet)
                        .frame(width: 220)
                    Text("\(Int(settings.defaultVolume))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }

                Toggle(L("settings.playback.muted", "Start muted"), isOn: $settings.startMuted)
                    .toggleStyle(ThemedSwitchToggleStyle(onColor: BrushPalette.violet))

                Picker(L("settings.playback.loop", "Default loop mode"), selection: $settings.loopMode) {
                    Text(L("loop.off", "No Loop")).tag(LoopMode.off)
                    Text(L("loop.file", "Loop File")).tag(LoopMode.file)
                    Text(L("loop.playlist", "Loop Playlist")).tag(LoopMode.playlist)
                }
                .frame(maxWidth: 320, alignment: .leading)
            }
        }
    }
}

// MARK: - Video

private struct VideoSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section(L("settings.video", "Video")) {
                Toggle(L("settings.video.hwdec", "Hardware decoding (VideoToolbox)"), isOn: $settings.hardwareDecoding)
                    .toggleStyle(ThemedSwitchToggleStyle(onColor: BrushPalette.violet))
                Text(L("settings.video.hwdec.hint", "Accelerates decoding of H.264, H.265 and AV1."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L("settings.video.hwdec.note", "Applies immediately; if playback misbehaves, reopen the file."))
                    .font(.caption)
                    .foregroundStyle(BrushPalette.violet)
            }
        }
    }
}
