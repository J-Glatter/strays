import StraysCore
import SwiftUI

struct StrayRow: View, Equatable {
    let row: RowModel
    /// For actions only. Deliberately not observed, so other rows' changes don't redraw this one.
    let store: Store
    @State private var expanded: Bool
    @State private var hovering = false
    @State private var confirming = false

    init(row: RowModel, store: Store, expanded: Bool = false) {
        self.row = row
        self.store = store
        _expanded = State(initialValue: expanded)
    }

    nonisolated static func == (a: StrayRow, b: StrayRow) -> Bool { a.row == b.row }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: row.hot ? "flame.fill" : row.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(row.hot ? Color.orange : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(row.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .layoutPriority(1)
                        ForEach(row.ports.prefix(2)) { PortBadge(port: $0) }
                        if row.ports.count > 2 {
                            Text(verbatim: "+\(row.ports.count - 2)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                    Text(row.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Metrics(cpu: row.cpu, secondary: row.secondary, hot: row.hot)
                StopButton(busy: row.stopping, help: row.stopHelp) { primary() }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
            .help("Click for details")

            if confirming, let confirm = row.confirm {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(confirm).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Cancel") { confirming = false }
                    Button(row.stopLabel) {
                        confirming = false
                        store.primaryAction(row.id)
                    }
                    .foregroundStyle(.red)
                }
                .buttonStyle(.link)
                .font(.caption)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.08)))
                .padding(.leading, 28)
            }

            if expanded { StrayDetail(row: row, store: store, primary: primary) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering || expanded ? Color.primary.opacity(0.05) : .clear)
                .padding(.horizontal, 6)
        )
        .onHover { hovering = $0 }
        .contextMenu { StrayMenu(row: row, store: store, primary: primary) }
    }

    /// Things with side effects worth spelling out (quitting Docker stops every container) ask first.
    private func primary() {
        if row.confirm != nil {
            withAnimation(.easeOut(duration: 0.15)) { confirming = true }
        } else {
            store.primaryAction(row.id)
        }
    }
}

private struct StrayDetail: View {
    let row: RowModel
    let store: Store
    let primary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                ForEach(row.facts) { fact in
                    GridRow {
                        Text(fact.label)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(fact.value)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                GridRow {
                    Text("Command").foregroundStyle(.secondary)
                    Text(row.command)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                if let cwd = row.cwd {
                    GridRow {
                        Text("Folder").foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Text(abbreviateHome(cwd)).lineLimit(1).truncationMode(.middle)
                            Button("Reveal") { store.reveal(cwd) }
                            Button("Terminal") { store.openTerminal(at: cwd) }
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            .font(.caption)

            if !row.pages.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open pages").font(.caption).foregroundStyle(.secondary)
                    ForEach(row.pages) { page in
                        Label {
                            Text(page.title.isEmpty ? page.url : page.title).lineLimit(1)
                        } icon: {
                            Image(systemName: "doc.richtext")
                        }
                        .font(.caption)
                        .help(page.url)
                    }
                }
            }

            if !row.containers.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Running containers").font(.caption).foregroundStyle(.secondary)
                    ForEach(row.containers) { ContainerRow(container: $0, store: store) }
                }
            }

            if !row.ports.isEmpty {
                HStack(spacing: 10) {
                    ForEach(row.ports) { port in
                        if let url = URL(string: "http://localhost:\(port.port)") {
                            Link(destination: url) { Text(verbatim: "Open localhost:\(port.port)") }
                        }
                    }
                }
                .font(.caption)
            }

            HStack(spacing: 14) {
                Button(row.stopLabel, action: primary)
                    .help(row.stopHelp)
                if row.canForceKill {
                    Button("Force kill") { store.stop(row.id, force: true) }
                        .help("Kill it immediately, without asking it to quit first")
                }
                if row.ignored {
                    Button("Un-ignore") { store.setIgnored(row.id, false) }
                } else {
                    Button("Ignore") { store.setIgnored(row.id, true) }
                        .help("Hide this from the count and the menu bar")
                }
                Button("Copy command") { store.copy(row.command) }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.leading, 28)
        .padding(.bottom, 4)
    }
}

private struct ContainerRow: View {
    let container: ContainerModel
    let store: Store

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "cube").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(container.name).font(.caption.weight(.medium))
                Text(container.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            StopButton(busy: container.stopping, help: "docker stop \(container.name)") {
                store.stopContainer(container.id)
            }
        }
    }
}

private struct StrayMenu: View {
    let row: RowModel
    let store: Store
    let primary: () -> Void

    var body: some View {
        Button(row.stopLabel, action: primary)
        if row.canForceKill {
            Button("Force kill") { store.stop(row.id, force: true) }
        }
        Divider()
        Button(row.ignored ? "Un-ignore" : "Ignore") { store.setIgnored(row.id, !row.ignored) }
        Divider()
        Button("Copy command") { store.copy(row.command) }
        if let cwd = row.cwd {
            Button("Reveal folder") { store.reveal(cwd) }
            Button("Open Terminal here") { store.openTerminal(at: cwd) }
        }
    }
}

struct ClaudeSessionRow: View, Equatable {
    let session: SessionModel
    let store: Store
    @State private var expanded = false
    @State private var hovering = false

    nonisolated static func == (a: ClaudeSessionRow, b: ClaudeSessionRow) -> Bool { a.session == b.session }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.system(size: 13))
                    .foregroundStyle(session.idle ? Color.secondary : Color.orange)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(session.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Metrics(cpu: session.cpu, secondary: session.secondary)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
            .help("Click for what this session is running")

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    if session.tasks.isEmpty {
                        Text("No background tasks.").font(.caption).foregroundStyle(.secondary).padding(.leading, 28)
                    }
                    ForEach(session.tasks) { StrayRow(row: $0, store: store).equatable() }
                    if let mcp = session.mcp {
                        Text(mcp).font(.caption).foregroundStyle(.secondary).padding(.leading, 28)
                    }
                    HStack {
                        Text(verbatim: "pid \(session.pid)").foregroundStyle(.secondary)
                        Spacer()
                        if session.stopping {
                            ProgressView().controlSize(.small)
                        } else {
                            ConfirmButton(
                                label: "End session",
                                confirmLabel: session.childCount > 0 ? "End it and its \(session.childCount) child processes?" : "End this session?"
                            ) { store.endSession(session.id) }
                            .help("Quits this Claude Code session. You can pick the conversation up again with claude --resume.")
                        }
                    }
                    .font(.caption)
                    .padding(.leading, 28)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering || expanded ? Color.primary.opacity(0.05) : .clear)
                .padding(.horizontal, 6)
        )
        .onHover { hovering = $0 }
    }
}
