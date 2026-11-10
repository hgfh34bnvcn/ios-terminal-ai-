import SwiftUI
import TermCore

/// The session list as a drawer over the main screen, opened from the top bar or by swiping from the left edge.
struct SidebarDrawer: View {
    @Environment(AppModel.self) private var model
    @State private var drag: CGFloat = 0

    var body: some View {
        let palette = model.palette
        GeometryReader { geometry in
            let width = min(geometry.size.width * 0.86, 340)
            ZStack(alignment: .leading) {
                if model.showSidebar {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture { model.showSidebar = false }
                        .transition(.opacity)
                }

                SidebarView()
                    .frame(width: width)
                    .background(palette.sidebar.ignoresSafeArea())
                    .offset(x: model.showSidebar ? min(drag, 0) : -width - 20)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 20)
                            .onChanged { value in
                                // Only a mostly horizontal drag moves the drawer; vertical ones scroll the list.
                                if abs(value.translation.width) > abs(value.translation.height) { drag = value.translation.width }
                            }
                            .onEnded { value in
                                if value.translation.width < -70, abs(value.translation.width) > abs(value.translation.height) {
                                    model.showSidebar = false
                                }
                                drag = 0
                            })

                if !model.showSidebar {
                    Color.clear
                        .frame(width: 14)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 12).onEnded { value in
                            if value.translation.width > 40 { model.showSidebar = true }
                        })
                }
            }
            .animation(.easeOut(duration: 0.22), value: model.showSidebar)
        }
    }
}

private struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var renaming: SessionSummary?
    @State private var title = ""

    var body: some View {
        let palette = model.palette
        let groups = model.groups(matching: search)

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TermAI")
                    .font(palette.heading(2))
                    .foregroundStyle(palette.text)
                Spacer()
                BarButton(symbol: "xmark", label: "Close", color: palette.dim) {
                    model.showSidebar = false
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .frame(height: 46)

            Button {
                model.newSession()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus").font(.system(size: 15, weight: .medium))
                    Text("New").font(palette.body)
                    Spacer()
                }
                .foregroundStyle(palette.text)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(palette.dim)
                TextField("", text: $search, prompt: Text("Search").foregroundStyle(palette.dim))
                    .font(palette.body)
                    .foregroundStyle(palette.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .padding(.horizontal, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if groups.isEmpty {
                        Text(search.isEmpty ? "Sessions you start are kept here." : "No sessions match.")
                            .font(palette.small)
                            .foregroundStyle(palette.dim)
                            .padding(.horizontal, 12)
                            .padding(.top, 16)
                    }
                    ForEach(groups) { group in
                        Text(group.title)
                            .font(palette.caption.weight(.semibold))
                            .foregroundStyle(palette.dim)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 12)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        ForEach(group.sessions) { summary in
                            row(summary, palette)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }

            Rectangle().fill(palette.border.opacity(0.6)).frame(height: 0.5)
            footer(palette)
        }
        .alert("Rename session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $title)
            Button("Save") {
                if let renaming { model.renameSession(renaming.id, to: title) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) {
                renaming = nil
            }
        }
    }

    private func row(_ summary: SessionSummary, _ palette: Palette) -> some View {
        Button {
            model.openSession(summary.id)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title)
                        .font(palette.body)
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    Text(summary.updatedAt.formatted(.relative(presentation: .named)))
                        .font(palette.caption)
                        .foregroundStyle(palette.dim)
                }
                Spacer(minLength: 4)
                if summary.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(palette.dim)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 50)
            .background(summary.id == model.session.id ? palette.surface : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                model.togglePin(summary.id)
            } label: {
                Label(summary.pinned ? "Unpin" : "Pin", systemImage: summary.pinned ? "pin.slash" : "pin")
            }
            Button {
                title = summary.title
                renaming = summary
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                model.deleteSession(summary.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func footer(_ palette: Palette) -> some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(model.profiles) { profile in
                    Button {
                        model.activateProfile(profile.id)
                    } label: {
                        if profile.id == model.activeProfile?.id {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
                Divider()
                Button {
                    openSettings()
                } label: {
                    Label("Connections…", systemImage: "gearshape")
                }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.activeProfile == nil ? palette.dim : palette.success)
                        .frame(width: 8, height: 8)
                    Text(model.activeProfile?.name ?? "No connection")
                        .font(palette.body)
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.dim)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            Spacer()
            BarButton(symbol: "gearshape", label: "Settings", color: palette.dim) {
                openSettings()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private func openSettings() {
        model.showSidebar = false
        model.showSettings = true
    }
}
