import SwiftUI

/// Online-subtitle search sheet — the SwiftUI port of IINA's online subtitle
/// flow (`OpenSub.Fetcher.fetch` → `SubChooseViewController`): search Open
/// Subtitles by file hash (exact matches rank first) and file-name query,
/// pick a result, download and load it via `PlayerCore.downloadOnlineSubtitle`
/// (mpv sub-add).
///
/// V1 simplification: anonymous search only — no Open Subtitles login UI.
/// IINA has a login form in its subtitle settings; Open Subtitles allows
/// anonymous search and download without an account (with a lower download
/// quota), which is enough for V1.
struct SubtitleSearchPanel: View {
    @ObservedObject var player: PlayerCore
    @Environment(\.dismiss) private var dismiss

    /// Search state machine: spinner, results, or failure detail.
    private enum Phase: Equatable {
        case idle
        case searching
        case loaded
        case failed(String)
    }

    @State private var phase: Phase = .idle
    @State private var results: [OpenSubtitles.Subtitle] = []
    @State private var selectedLanguages: Set<String> = []
    /// The result currently being downloaded (row shows a spinner).
    @State private var downloadingID: String?
    /// The result whose download last failed (row shows an error).
    @State private var failedDownloadID: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var didAutoSearch = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(BrushLLMPlayerTheme.controlSeparator)
            controls
            Divider().overlay(BrushLLMPlayerTheme.controlSeparator)
            content
        }
        .frame(minWidth: 500, minHeight: 420)
        .background(BrushLLMPlayerTheme.panelMaterial)
        .onAppear {
            // IINA searches immediately when its subtitle chooser opens;
            // the Search button re-runs or re-searches with new languages.
            guard !didAutoSearch else { return }
            didAutoSearch = true
            selectedLanguages = Set(Self.languageOptions.map(\.code))
            runSearch()
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 12))
                .foregroundStyle(BrushPalette.violet300)
            Text(L("subtitle.online", "Online Subtitles…"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BrushLLMPlayerTheme.controlText)
            Spacer()
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

    // MARK: - Search controls (language chips + search button)

    private var controls: some View {
        HStack(spacing: 8) {
            ForEach(Self.languageOptions) { option in
                languageChip(option)
            }
            Spacer()
            Button(action: runSearch) {
                Text(L("subtitle.online-search", "Search"))
            }
            .buttonStyle(AccentProminentButtonStyle())
            .disabled(selectedLanguages.isEmpty || isSearching || downloadingID != nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var isSearching: Bool {
        if case .searching = phase { return true }
        return false
    }

    /// Capsule toggle chip (the add-server form's kind picker pattern).
    private func languageChip(_ option: LanguageOption) -> some View {
        let isOn = selectedLanguages.contains(option.code)
        return Button {
            if isOn {
                selectedLanguages.remove(option.code)
            } else {
                selectedLanguages.insert(option.code)
            }
        } label: {
            Text(option.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn ? BrushLLMPlayerTheme.onAccent : BrushLLMPlayerTheme.controlTextSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    Capsule().fill(isOn ? BrushLLMPlayerTheme.accent : Color.white.opacity(0.06))
                }
                .contentShape(.rect)
        }
        .buttonStyle(PressedDimButtonStyle())
    }

    // MARK: - Content (states + result list)

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle, .searching:
            VStack(spacing: 10) {
                ProgressView()
                    .tint(BrushLLMPlayerTheme.accent)
                Text(L("subtitle.online-searching", "Searching…"))
                    .font(.caption)
                    .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let detail):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(BrushPalette.warning)
                Text(L("subtitle.online-failed", "Search failed"))
                    .font(.callout)
                    .foregroundStyle(BrushLLMPlayerTheme.controlText)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(BrushLLMPlayerTheme.controlTextHint)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                Button(L("subtitle.online-search", "Search"), action: runSearch)
                    .buttonStyle(AccentProminentButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if results.isEmpty {
                EmptyStateView(icon: "captions.bubble",
                                message: L("subtitle.online-none", "No results"))
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(results) { subtitle in
                            row(subtitle)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    /// One result row (IINA's SubChooseViewController columns: file name,
    /// title/year/language/rating/downloads). Clicking downloads and loads
    /// the subtitle.
    private func row(_ subtitle: OpenSubtitles.Subtitle) -> some View {
        BrowserRowButton(action: { download(subtitle) }) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(subtitle.attributes.files.first?.fileName ?? subtitle.id)
                        .font(.callout)
                        .foregroundStyle(BrushLLMPlayerTheme.controlText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(featureLabel(subtitle))
                            .font(.system(size: 11))
                            .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                            .lineLimit(1)
                        KindBadge(text: subtitle.attributes.language)
                        if let rating = subtitle.attributes.ratings, rating > 0 {
                            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(BrushPalette.warning)
                        }
                        if let count = subtitle.attributes.downloadCount {
                            Label(String(count), systemImage: "arrow.down")
                                .font(.system(size: 10))
                                .foregroundStyle(BrushLLMPlayerTheme.controlTextHint)
                        }
                    }
                }
                Spacer()
                if downloadingID == subtitle.id {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text(L("subtitle.online-downloading", "Downloading…"))
                            .font(.system(size: 11))
                            .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                    }
                } else if failedDownloadID == subtitle.id {
                    Text(L("subtitle.online-download-failed", "Download failed"))
                        .font(.system(size: 11))
                        .foregroundStyle(BrushPalette.warning)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    /// "Title (Year)" — the media the subtitle belongs to.
    private func featureLabel(_ subtitle: OpenSubtitles.Subtitle) -> String {
        let details = subtitle.attributes.featureDetails
        var label = details.title
        if let year = details.year, year > 0 {
            label += " (\(year))"
        }
        return label
    }

    // MARK: - Actions

    /// Searches by hash (exact match, ranked first by the API) plus the
    /// file-name query — IINA sends both in one request. Local files search
    /// by file name, streams by media title (IINA: `searchForSubtitles`).
    private func runSearch() {
        searchTask?.cancel()
        let languages = selectedLanguages.sorted()
        guard !languages.isEmpty else { return }
        let fileURL = player.subtitleSearchFileURL
        let query = fileURL?.deletingPathExtension().lastPathComponent
            ?? (player.mediaTitle.isEmpty ? nil : player.mediaTitle)
        guard query != nil || fileURL != nil else {
            results = []
            phase = .loaded
            return
        }
        phase = .searching
        searchTask = Task { @MainActor in
            do {
                let hash = fileURL.flatMap { OpenSubtitles.hash(url: $0) }
                let found = try await OpenSubtitles.shared.search(
                    languages: languages, hash: hash, query: query)
                guard !Task.isCancelled else { return }
                results = found
                phase = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Downloads the chosen subtitle and loads it into playback; the sheet
    /// closes on success (IINA: row double-click → download → sub-add).
    private func download(_ subtitle: OpenSubtitles.Subtitle) {
        guard downloadingID == nil else { return }
        downloadingID = subtitle.id
        failedDownloadID = nil
        player.downloadOnlineSubtitle(subtitle) { result in
            switch result {
            case .success:
                dismiss()
            case .failure(let error):
                downloadingID = nil
                failedDownloadID = subtitle.id
                DebugLog.log("online subtitle: download failed — \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Language options

    /// A language chip: an Open Subtitles language code + its endonym label.
    private struct LanguageOption: Identifiable {
        let code: String
        let label: String
        var id: String { code }
    }

    /// Endonyms for the offered languages (Open Subtitles codes).
    private static let endonyms: [String: String] = [
        "en": "English", "zh": "中文", "de": "Deutsch", "es": "Español",
        "fr": "Français", "pt-BR": "Português (Brasil)", "ja": "日本語", "ko": "한국어",
    ]

    /// The app's UI language as an Open Subtitles code, when mappable.
    /// The app's AppleLanguages override redirects
    /// `Locale.preferredLanguages`, so its first entry is the effective UI
    /// language. Both Chinese scripts map to Open Subtitles' "zh".
    private static var uiLanguageCode: String? {
        guard let preferred = Locale.preferredLanguages.first else { return nil }
        let tag = preferred.lowercased()
        if tag.hasPrefix("zh") { return "zh" }
        if tag.hasPrefix("pt") { return "pt-BR" }
        for code in ["en", "de", "es", "fr", "ja", "ko"]
        where tag == code || tag.hasPrefix(code + "-") {
            return code
        }
        return nil
    }

    /// Fixed multi-select: the UI language (when mappable) + Chinese +
    /// English, deduplicated.
    private static var languageOptions: [LanguageOption] {
        var options: [LanguageOption] = []
        var seen = Set<String>()
        for code in [uiLanguageCode, "zh", "en"].compactMap({ $0 }) {
            guard seen.insert(code).inserted, let label = endonyms[code] else { continue }
            options.append(LanguageOption(code: code, label: label))
        }
        return options
    }
}
