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
