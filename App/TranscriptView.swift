import SwiftUI
import TermCore
import UIKit

struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<UUID> = []

    var body: some View {
        let palette = model.palette
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.session.transcript) { item in
                            TranscriptRow(item: item, palette: palette, expanded: expanded.contains(item.id)) {
                                if !expanded.insert(item.id).inserted { expanded.remove(item.id) }
                            }
                        }
                        if model.isRunning, model.pendingApproval == nil {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(model.activity ?? "Working…")
                                    .font(palette.small)
                                    .foregroundStyle(palette.dim)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    // A short transcript starts at the top rather than hugging the composer.
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                    .shadow(color: model.theme.glow ? palette.text.opacity(0.5) : .clear, radius: 3)
                }
                // Stay pinned to the newest output while it streams, unless the user scrolls up.
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.scrollTick) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}

private struct TranscriptRow: View {
    let item: TranscriptItem
    let palette: Palette
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        switch item.kind {
        case .user:
            UserBubble(item: item, palette: palette)
        case .assistant:
            MarkdownView(text: item.text, palette: palette)
        case .thinking:
            ThinkingRow(item: item, palette: palette, expanded: expanded, toggle: toggle)
        case .tool:
            ToolRow(item: item, palette: palette, expanded: expanded, toggle: toggle)
        case .info:
            Text(item.text)
                .font(palette.mono)
                .foregroundStyle(palette.dim)
                .textSelection(.enabled)
        case .error:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 12))
                Text(item.text).textSelection(.enabled)
            }
            .font(palette.small)
            .foregroundStyle(palette.error)
        }
    }
}

private struct UserBubble: View {
    let item: TranscriptItem
    let palette: Palette

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(item.attachments ?? [], id: \.self) { name in
                Label(name, systemImage: "paperclip")
                    .font(palette.caption)
                    .foregroundStyle(palette.dim)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(palette.surface, in: Capsule())
            }
            if !item.text.isEmpty {
                Text(item.text)
                    .font(palette.body)
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 36)
    }
}

private struct ThinkingRow: View {
    let item: TranscriptItem
    let palette: Palette
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Thinking")
                }
                .font(palette.small)
                .foregroundStyle(palette.dim)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(item.text)
                    .font(palette.small)
                    .italic()
                    .foregroundStyle(palette.dim)
                    .textSelection(.enabled)
            }
        }
    }
}

/// One tool call: what ran, how it went, and its output or the change it made.
private struct ToolRow: View {
    let item: TranscriptItem
    let palette: Palette
    let expanded: Bool
    let toggle: () -> Void

    /// Lookups and edits stay closed until tapped; commands show the end of their output.
    private var quiet: Bool {
        ["Read", "Glob", "Grep", "Fetch", "Write", "Edit", "Todos"].contains(item.tool ?? "")
    }

    private var output: String? {
        let text = item.text.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return nil }
        if item.status == .denied { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if quiet {
            guard expanded || item.status == .failed else { return nil }
            guard lines.count > 40 else { return text }
            return lines.prefix(40).joined(separator: "\n") + "\n… \(lines.count - 40) more lines"
        }
        let limit = expanded ? 80 : 6
        guard lines.count > limit else { return text }
        return "… \(lines.count - limit) earlier lines\n" + lines.suffix(limit).joined(separator: "\n")
    }

    private var diffLines: [Substring]? {
        guard let diff = item.diff, !diff.isEmpty else { return nil }
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        guard !expanded, lines.count > 14 else { return lines }
        return Array(lines.prefix(14)) + [Substring("… \(lines.count - 14) more lines")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(alignment: .center, spacing: 8) {
                    glyph.font(.system(size: 11, weight: .bold)).frame(width: 14)
                    Text(item.tool ?? "Tool")
                        .font(palette.smallBold)
                        .foregroundStyle(palette.text)
                    Text(item.title ?? "")
                        .font(palette.mono)
                        .foregroundStyle(palette.dim)
                        .lineLimit(expanded ? 6 : 1)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.dim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let todos = item.todos {
                TodoListView(todos: todos, palette: palette)
            } else if let diffLines {
                DiffView(lines: diffLines, palette: palette)
            }
            if let output {
                Text(output)
                    .font(palette.mono)
                    .foregroundStyle(item.status == .failed ? palette.text.opacity(0.85) : palette.dim)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(palette.code, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(10)
        .background(palette.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.border.opacity(0.7), lineWidth: 0.5))
    }

    @ViewBuilder private var glyph: some View {
        switch item.status {
        case .running: ProgressView().controlSize(.mini)
        case .ok: Image(systemName: "checkmark").foregroundStyle(palette.success)
        case .failed: Image(systemName: "xmark").foregroundStyle(palette.error)
        case .denied: Image(systemName: "nosign").foregroundStyle(palette.dim)
        case nil: Image(systemName: "circle").foregroundStyle(palette.dim)
        }
    }
}

struct DiffView: View {
    let lines: [Substring]
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : String(line))
                    .font(palette.mono)
                    .foregroundStyle(color(line))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(background(line))
            }
        }
        .padding(.vertical, 5)
        .background(palette.code)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func color(_ line: Substring) -> Color {
        if line.hasPrefix("+") { return palette.success }
        if line.hasPrefix("-") { return palette.error }
        if line.hasPrefix("@@") || line.hasPrefix("…") { return palette.dim }
        return palette.text.opacity(0.85)
    }

    private func background(_ line: Substring) -> Color {
        if line.hasPrefix("+") { return palette.success.opacity(0.13) }
        if line.hasPrefix("-") { return palette.error.opacity(0.13) }
        return .clear
    }
}

private struct TodoListView: View {
    let todos: [TodoItem]
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(todo.status))
                        .font(.system(size: 12))
                        .foregroundStyle(color(todo.status))
                    Text(todo.content)
                        .font(palette.small)
                        .foregroundStyle(todo.status == .completed ? palette.dim : palette.text)
                        .strikethrough(todo.status == .completed)
                }
            }
        }
    }

    private func symbol(_ status: TodoItem.Status) -> String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .inProgress: return "circle.lefthalf.filled"
        case .pending: return "circle"
        }
    }

    private func color(_ status: TodoItem.Status) -> Color {
        switch status {
        case .completed: return palette.success
        case .inProgress: return palette.accent
        case .pending: return palette.dim
        }
    }
}

/// Renders the model's Markdown: headings, lists, quotes, code blocks and inline styles.
struct MarkdownView: View {
    let text: String
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Markdown.blocks(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .font(palette.body)
        .foregroundStyle(palette.text)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: Markdown.Block) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text)
        case .heading(let level, let text):
            inline(text).font(palette.heading(level))
        case .code(_, let code):
            CodeBlock(code: code, palette: palette)
        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker).foregroundStyle(palette.dim)
                        inline(item.text)
                    }
                    .padding(.leading, CGFloat(item.indent) * 16)
                }
            }
        case .quote(let text):
            inline(text)
                .foregroundStyle(palette.dim)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(palette.border).frame(width: 3)
                }
        case .rule:
            Rectangle().fill(palette.border).frame(height: 1)
        }
    }

    /// Bold, italic, links and inline code within one block.
    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var attributed = try? AttributedString(markdown: text, options: options) else { return Text(text) }
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].swiftUI.font = palette.monoBody
            attributed[run.range].swiftUI.foregroundColor = palette.accent
        }
        return Text(attributed)
    }
}

private struct CodeBlock: View {
    let code: String
    let palette: Palette

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(palette.mono)
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
                .padding(.vertical, 10)
                .padding(.leading, 12)
                .padding(.trailing, 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.code, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.border.opacity(0.7), lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            Button {
                UIPasteboard.general.string = code
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.dim)
                    .padding(9)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy code")
        }
    }
}
