import SwiftUI
import TermCore
import UIKit
import UniformTypeIdentifiers

/// The input box with everything that steers a turn: environment, folder, model, effort and permissions.
struct ComposerView: View {
    @Environment(AppModel.self) private var model
    var focused: FocusState<Bool>.Binding
    @State private var importing = false

    var body: some View {
        @Bindable var model = model
        let palette = model.palette
        let active = model.isRunning || model.canSend

        VStack(spacing: 8) {
            if let approval = model.pendingApproval {
                ApprovalCard(approval: approval, palette: palette)
            } else if !model.suggestions.isEmpty {
                SuggestionList(palette: palette)
            }

            VStack(alignment: .leading, spacing: 6) {
                if !model.attachments.isEmpty {
                    AttachmentRow(palette: palette)
                }
                HStack(alignment: .bottom, spacing: 6) {
                    Menu {
                        AddOptions(importing: $importing)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(palette.dim)
                            .frame(width: 34, height: 34)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Add")

                    TextField("", text: $model.input, prompt: Text(model.placeholder).foregroundStyle(palette.dim), axis: .vertical)
                        .lineLimit(1...8)
                        .font(model.shellMode ? palette.monoBody : palette.body)
                        .foregroundStyle(palette.text)
                        .textInputAutocapitalization(model.shellMode ? .never : .sentences)
                        .autocorrectionDisabled(model.shellMode)
                        .focused(focused)
                        .padding(.vertical, 7)

                    Button {
                        if model.isRunning {
                            model.cancel()
                        } else {
                            model.submit()
                        }
                    } label: {
                        Image(systemName: model.isRunning ? "stop.fill" : "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(active ? palette.background : palette.dim)
                            .frame(width: 34, height: 34)
                            .background(active ? palette.accent : palette.border, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!active)
                    .accessibilityLabel(model.isRunning ? "Stop" : "Send")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(model.shellMode ? palette.accent.opacity(0.8) : palette.border, lineWidth: 1))

            ChipRow(palette: palette)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(palette.background)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                if let data = try? Data(contentsOf: url) {
                    model.attach(name: url.lastPathComponent, data: data)
                }
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        }
    }
}

private struct AddOptions: View {
    @Environment(AppModel.self) private var model
    @Binding var importing: Bool

    var body: some View {
        Button {
            importing = true
        } label: {
            Label("Attach file", systemImage: "paperclip")
        }
        Button {
            if let text = UIPasteboard.general.string { model.input += text }
        } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
        }
        if !model.recentPrompts.isEmpty {
            Menu {
                ForEach(model.recentPrompts, id: \.self) { prompt in
                    Button(String(prompt.prefix(60))) {
                        model.input = prompt
                    }
                }
            } label: {
                Label("Recent prompts", systemImage: "clock.arrow.circlepath")
            }
        }
        Menu {
            ForEach(Commands.all, id: \.name) { command in
                Button("/\(command.name)  \(command.help)") {
                    model.input = "/\(command.name) "
                }
            }
        } label: {
            Label("Commands", systemImage: "slash.circle")
        }
    }
}

private struct AttachmentRow: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip").font(.system(size: 11))
                        Text(attachment.name).lineLimit(1)
                        Button {
                            model.removeAttachment(attachment.id)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.name)")
                    }
                    .font(palette.caption)
                    .foregroundStyle(palette.text)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(palette.background, in: Capsule())
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
        }
    }
}

/// The row under the input: where the session works and how the model is set up.
private struct ChipRow: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Menu {
                    EnvironmentOptions()
                } label: {
                    Chip(symbol: model.hasShell ? "server.rack" : "iphone", text: model.environmentLabel, palette: palette)
                }
                Button {
                    model.showFolderPicker = true
                } label: {
                    Chip(symbol: "folder", text: model.folderLabel, palette: palette)
                }
                .buttonStyle(.plain)
                Menu {
                    ModelOptions()
                } label: {
                    Chip(text: model.modelLabel, detail: model.currentEffort == .auto ? nil : model.currentEffort.title, palette: palette)
                }
                Menu {
                    ModeOptions()
                } label: {
                    Chip(symbol: model.session.mode.symbol, text: model.session.mode.title,
                         tint: model.session.mode == .bypass ? palette.error : nil, palette: palette)
                }
                if let context = model.contextLabel {
                    Text("\(context) tokens")
                        .font(palette.caption)
                        .foregroundStyle(palette.dim)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

private struct Chip: View {
    var symbol: String?
    let text: String
    var detail: String?
    var tint: Color?
    let palette: Palette

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 11))
            }
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail {
                Text(detail).foregroundStyle(palette.dim)
            }
        }
        .font(palette.caption)
        .foregroundStyle(tint ?? palette.text.opacity(0.9))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .frame(maxWidth: 200)
        .background(palette.surface.opacity(0.8), in: Capsule())
        .contentShape(Capsule())
    }
}

private struct ModelOptions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let profile = model.activeProfile {
            Section("Model") {
                ForEach(profile.pickerModels, id: \.self) { id in
                    Button {
                        model.selectModel(id)
                    } label: {
                        if id == model.currentModel {
                            Label(profile.shortName(for: id), systemImage: "checkmark")
                        } else {
                            Text(profile.shortName(for: id))
                        }
                    }
                }
            }
            Menu {
                ForEach(Effort.allCases) { effort in
                    Button {
                        model.selectEffort(effort)
                    } label: {
                        if effort == model.currentEffort {
                            Label(effort.title, systemImage: "checkmark")
                        } else {
                            Text(effort.title)
                        }
                    }
                }
            } label: {
                Label("Effort: \(model.currentEffort.title)", systemImage: "speedometer")
            }
        } else {
            Button("Set up a connection…") {
                model.showSettings = true
            }
        }
    }
}

private struct SuggestionList: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.suggestions.prefix(6), id: \.name) { command in
                Button {
                    model.input = "/\(command.name) "
                } label: {
                    HStack(spacing: 10) {
                        Text("/\(command.name)").foregroundStyle(palette.accent)
                        Text(command.help).foregroundStyle(palette.dim).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(palette.mono)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Asks before a tool call runs: once, never, or always for calls like it.
private struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    let approval: PendingApproval
    let palette: Palette

    private var question: String {
        switch approval.tool {
        case "Bash": return "Run this command?"
        case "Edit": return "Make this edit?"
        case "Write": return "Write this file?"
        case "Fetch": return "Fetch this URL?"
        case "Read", "Glob", "Grep": return "Look outside the working folder?"
        default: return "Allow \(approval.tool)?"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question)
                .font(palette.bodyBold)
                .foregroundStyle(palette.text)
            if approval.preview != approval.summary {
                Text(approval.summary)
                    .font(palette.mono)
                    .foregroundStyle(palette.dim)
                    .lineLimit(3)
            }
            if let preview = approval.preview, !preview.isEmpty {
                ScrollView {
                    if approval.isDiff {
                        DiffView(lines: preview.split(separator: "\n", omittingEmptySubsequences: false), palette: palette)
                    } else {
                        Text(preview)
                            .font(palette.mono)
                            .foregroundStyle(palette.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                }
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)
                .background(palette.code, in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 8) {
                choice("Deny", filled: false) { model.resolveApproval(allow: false) }
                choice("Allow once", filled: true) { model.resolveApproval(allow: true) }
            }
            if let grant = approval.grant {
                choice(grant.label, filled: false) { model.allowAlways() }
            }
        }
        .padding(14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(palette.accent.opacity(0.6), lineWidth: 1))
    }

    private func choice(_ label: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(palette.smallBold)
                .foregroundStyle(filled ? palette.background : palette.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(filled ? palette.accent : palette.background, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(filled ? Color.clear : palette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
