import SwiftUI

enum PlayerSidebarSection: String, Identifiable {
    case sources, playlist, history, bookmarks, chapters

    static let destinations: [Self] = [.sources, .playlist, .history, .bookmarks]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sources: L("player.sources", "Sources")
        case .playlist: L("panel.playlist.title", "Playlist")
        case .history: L("panel.history", "History")
        case .bookmarks: L("panel.bookmarks", "Bookmarks")
        case .chapters: L("panel.chapters", "Chapters")
        }
    }

    var icon: String {
        switch self {
        case .sources: "folder"
        case .playlist: "list.bullet"
        case .history: "clock.arrow.circlepath"
        case .bookmarks: "bookmark"
        case .chapters: "list.and.film"
        }
    }
}

struct PlayerSidebar: View {
    let player: PlayerCore
    let section: PlayerSidebarSection
    let compact: Bool
    let onSelect: (PlayerSidebarSection) -> Void
    let onOpenFiles: () -> Void
    let onOpenNetwork: (NetworkPanel.Tab) -> Void

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            brand
            VStack(spacing: 4) {
                ForEach(PlayerSidebarSection.destinations) { destination in
                    let selected = section == destination || (section == .chapters && destination == .playlist)
                    Button {
                        onSelect(destination)
                    } label: {
                        SidebarLabel(title: destination.title, icon: destination.icon,
                                     compact: compact, selected: selected)
                    }
                    .buttonStyle(PressedDimButtonStyle())
                    .accessibilityLabel(destination.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .help(destination.title)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            if compact {
                Spacer(minLength: 0)
            } else {
                Divider().padding(.horizontal, 14)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            Divider().padding(.horizontal, 14)
            footer
        }
        .frame(width: compact ? 64 : 200)
        .background(BrushLLMPlayerTheme.rail)
        .overlay(alignment: .trailing) {
            Rectangle().fill(BrushLLMPlayerTheme.controlSeparator).frame(width: 1)
        }
    }

    private var brand: some View {
        HStack(spacing: 9) {
            PlayerIcon(size: 32)
            if !compact {
                Text("BrushLLM Player")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(BrushLLMPlayerTheme.controlText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .frame(height: 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("BrushLLM Player")
    }

    @ViewBuilder
    private var content: some View {
        if section == .sources {
            ScrollView {
                VStack(spacing: 2) {
                    sourceButton(L("player.open-files", "Open files…"), icon: "folder", action: onOpenFiles)
                    sourceButton(L("network.tab.url", "Stream URL"), icon: "link") { onOpenNetwork(.stream) }
                    sourceButton(L("network.tab.servers", "Media Servers"), icon: "externaldrive") { onOpenNetwork(.servers) }
                }
                .padding(12)
            }
        } else {
            PlayerLibraryPanel(player: player, section: section)
        }
    }

    private func sourceButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SidebarLabel(title: title, icon: icon, compact: false)
        }
        .buttonStyle(PressedDimButtonStyle())
        .accessibilityLabel(title)
        .help(title)
    }

    private var footer: some View {
        Group {
            if compact {
                VStack(spacing: 4) { settingsLink; aboutButton }
            } else {
                HStack(spacing: 4) { settingsLink; aboutButton }
            }
        }
        .padding(12)
    }

    private var settingsLink: some View {
        let title = L("player.settings", "Settings")
        return SettingsLink {
            SidebarLabel(title: title, icon: "gearshape", compact: compact)
        }
        .buttonStyle(PressedDimButtonStyle())
        .accessibilityLabel(title)
        .help(title)
    }

    private var aboutButton: some View {
        PlayerIconButton(icon: "info.circle", help: L("about.menu", "About BrushLLM Player")) {
            openWindow(id: "about")
        }
    }
}

private struct SidebarLabel: View {
    let title: String
    let icon: String
    let compact: Bool
    var selected = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            if !compact {
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .foregroundStyle(foreground)
        .background {
            RoundedRectangle(cornerRadius: DesignRadius.row)
                .fill(selected ? BrushLLMPlayerTheme.selectionFill : (hovering ? BrushLLMPlayerTheme.hoverFill : .clear))
        }
        .overlay(alignment: .leading) {
            if selected {
                Capsule().fill(BrushLLMPlayerTheme.accent)
                    .frame(width: 3, height: 16)
                    .padding(.leading, 2)
            }
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        selected ? BrushLLMPlayerTheme.accentText : BrushLLMPlayerTheme.controlTextSecondary
    }
}
