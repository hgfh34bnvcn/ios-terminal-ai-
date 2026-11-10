import SwiftUI
import TermCore
import UIKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var composerFocused: Bool

    var body: some View {
        @Bindable var model = model
        let palette = model.palette

        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                TopBar()
                if model.session.transcript.isEmpty {
                    StartView()
                } else {
                    TranscriptView()
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposerView(focused: $composerFocused)
            }
            .background(palette.background.ignoresSafeArea())

            SidebarDrawer()
        }
        .preferredColorScheme(model.theme.isDark ? .dark : .light)
        .tint(palette.accent)
        .onChange(of: model.showSidebar) {
            if model.showSidebar { composerFocused = false }
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $model.showFolderPicker) {
            FolderPicker()
        }
        .sheet(item: $model.shareItem) { item in
            ShareSheet(text: item.text)
        }
        .task {
            // Screenshot runs wait for this file before capturing; it is only written with sample content.
            guard model.demo != nil else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            try? Data().write(to: FileManager.default.temporaryDirectory.appendingPathComponent("demo-ready"))
        }
    }
}

private struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let palette = model.palette
        HStack(spacing: 2) {
            BarButton(symbol: "sidebar.left", label: "Sessions", color: palette.text) {
                model.showSidebar = true
            }
            Text(model.session.transcript.isEmpty ? Session.untitled : model.session.title)
                .font(palette.bodyBold)
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .padding(.leading, 4)
            Spacer(minLength: 8)
            if model.hasShell {
                BarButton(symbol: "terminal", label: "Shell mode", color: model.shellMode ? palette.accent : palette.dim) {
                    model.shellMode.toggle()
                }
            }
            BarButton(symbol: "square.and.pencil", label: "New session", color: palette.text) {
                model.newSession()
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 46)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.border.opacity(0.6)).frame(height: 0.5)
        }
    }
}

struct BarButton: View {
    let symbol: String
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Environments to work in: this device, the saved SSH hosts, and a way to add one.
struct EnvironmentOptions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.selectEnvironment(nil)
        } label: {
            Label(model.deviceName, systemImage: model.session.hostID == nil ? "checkmark" : "iphone")
        }
        ForEach(model.hosts) { host in
            Button {
                model.selectEnvironment(host.id)
            } label: {
                Label("\(host.name)  \(host.address)", systemImage: model.session.hostID == host.id ? "checkmark" : "server.rack")
            }
        }
        Divider()
        Button {
            model.showSettings = true
        } label: {
            Label("Add SSH host…", systemImage: "plus")
        }
    }
}

struct ModeOptions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(PermissionMode.allCases) { mode in
            Button {
                model.selectMode(mode)
            } label: {
                Label(mode.title, systemImage: model.session.mode == mode ? "checkmark" : mode.symbol)
            }
        }
    }
}

/// The screen a new session starts on: where it will work, and how to get going.
struct StartView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let palette = model.palette
        ScrollView {
            VStack(spacing: 12) {
                Text("❯_")
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .foregroundStyle(palette.accent)
                    .frame(width: 60, height: 60)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.top, 48)
                    .padding(.bottom, 8)

                if model.needsSetup {
                    setup(palette)
                } else {
                    workplace(palette)
                    shortcuts(palette)
                }
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func setup(_ palette: Palette) -> some View {
        VStack(spacing: 12) {
            Text("Connect a gateway to start")
                .font(palette.bodyBold)
                .foregroundStyle(palette.text)
            Text("Enter the base URL, API key and models of your inference gateway, the same values Claude Code uses.")
                .font(palette.small)
                .foregroundStyle(palette.dim)
                .multilineTextAlignment(.center)
            Button {
                model.showSettings = true
            } label: {
                Text("Set up connection")
                    .font(palette.bodyBold)
                    .foregroundStyle(palette.background)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func workplace(_ palette: Palette) -> some View {
        VStack(spacing: 0) {
            Button {
                model.showFolderPicker = true
            } label: {
                StartRow(symbol: "folder", title: model.folderLabel, trailing: "checkmark", palette: palette)
            }
            .buttonStyle(.plain)
            Rectangle().fill(palette.border.opacity(0.6)).frame(height: 0.5)
            Menu {
                EnvironmentOptions()
            } label: {
                StartRow(symbol: model.hasShell ? "server.rack" : "iphone", title: model.environmentLabel,
                         detail: "Choose environment", trailing: "chevron.down", palette: palette)
            }
        }
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func shortcuts(_ palette: Palette) -> some View {
        VStack(spacing: 0) {
            if let last = model.lastSession {
                Button {
                    model.openSession(last.id)
                } label: {
                    StartRow(symbol: "clock.arrow.circlepath", title: "Resume: \(last.title)", palette: palette)
                }
                .buttonStyle(.plain)
                Rectangle().fill(palette.border.opacity(0.6)).frame(height: 0.5)
            }
            Menu {
                ModeOptions()
            } label: {
                StartRow(symbol: model.session.mode.symbol, title: model.session.mode.title,
                         detail: model.session.mode.detail, trailing: "chevron.down", palette: palette)
            }
        }
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct StartRow: View {
    let symbol: String
    let title: String
    var detail: String?
    var trailing: String?
    let palette: Palette

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(palette.dim)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(palette.body)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(palette.caption)
                        .foregroundStyle(palette.dim)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 8)
            if let trailing {
                Image(systemName: trailing)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.dim)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
