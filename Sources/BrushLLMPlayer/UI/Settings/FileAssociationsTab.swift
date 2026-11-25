import AppKit
import SwiftUI

struct FileAssociationsTab: View {
    @State private var confirming = false
    @State private var applying = false
    @State private var result: String?
    @State private var failedExtensions: [String] = []

    var body: some View {
        Form {
            Section {
                Text(L("settings.file-associations-mac-hint",
                       "Make BrushLLM Player the default app for the listed video, audio, playlist and disc-image formats."))
                    .foregroundStyle(.secondary)
                WrappingRows(spacing: 8) {
                    ForEach(MediaTypes.associationExtensions, id: \.self) { suffix in
                        Text(".\(suffix)")
                    }
                }
                    .font(.callout.monospaced())
                .accessibilityElement(children: .combine)
                Button(L("settings.file-associations-apply", "Associate All Formats…")) {
                    confirming = true
                }
                .disabled(applying || MediaTypes.associations.isEmpty)
                if applying { ProgressView().controlSize(.small) }
                if let result { Text(result).font(.callout) }
                if !failedExtensions.isEmpty {
                    Text(failedExtensions.map { ".\($0)" }.joined(separator: ", "))
                        .font(.callout.monospaced())
                }
            }
        }
        .alert(L("settings.file-associations-confirm", "Set BrushLLM Player as the default?"),
               isPresented: $confirming) {
            Button(L("settings.file-associations-confirm-apply", "Set as Default")) {
                Task { await associateFormats() }
            }
            Button(L("panel.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("settings.file-associations-mac-hint",
                   "Make BrushLLM Player the default app for the listed video, audio, playlist and disc-image formats."))
        }
    }

    @MainActor
    private func associateFormats() async {
        applying = true
        result = nil
        failedExtensions = []
        defer { applying = false }
        let app = Bundle.main.bundleURL
        let workspace = NSWorkspace.shared
        var failed = 0
        var failedSuffixes: [String] = []
        for association in MediaTypes.associations {
            let type = association.type
            if workspace.urlForApplication(toOpen: type)?.standardizedFileURL == app.standardizedFileURL { continue }
            do {
                try await workspace.setDefaultApplication(at: app, toOpen: type)
            } catch {
                failed += 1
                failedSuffixes.append(contentsOf: association.extensions)
                DebugLog.log("File association for \(type.identifier): \(error.localizedDescription)")
            }
        }
        failedExtensions = failedSuffixes.sorted()
        result = failed == 0
            ? L("settings.file-associations-done", "BrushLLM Player is set as the default for all listed formats.")
            : String(format: L("settings.file-associations-partial", "macOS could not change %d file type(s)."), failed)
    }
}
