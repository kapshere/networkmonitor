import AppKit
import SwiftUI

struct ChatView: View {
    @Bindable var model: ChatViewModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .onAppear { inputFocused = true }
    }

    private var header: some View {
        HStack {
            Text("Network Monitor").font(.headline)
            if model.isRunning {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Clear", systemImage: "trash", action: model.clear)
                .labelStyle(.iconOnly)
                .disabled(model.entries.isEmpty)
                .help("Clear conversation")
            Button("Quit", systemImage: "power") { NSApp.terminate(nil) }
                .labelStyle(.iconOnly)
                .help("Quit Network Monitor")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if model.entries.isEmpty {
                        Text("Ask about your network, e.g. \u{201C}How much traffic is en0 doing?\u{201D}")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(model.entries) { entry in
                        EntryView(entry: entry).id(entry.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: model.entries.last) { _, last in
                guard let last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($inputFocused)
                .onSubmit(model.send)
            if model.isRunning {
                Button("Stop", systemImage: "stop.circle.fill", action: model.stop)
                    .labelStyle(.iconOnly)
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill", action: model.send)
                    .labelStyle(.iconOnly)
                    .disabled(!model.canSend)
            }
        }
        .buttonStyle(.borderless)
        .font(.title3)
        .padding(12)
    }
}

private struct EntryView: View {
    let entry: ChatViewModel.Entry
    @State private var expanded = false

    var body: some View {
        switch entry.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                bubble(entry.text, background: Color.accentColor, foreground: .white)
            }
        case .assistant:
            HStack {
                bubble(entry.text, background: Color.secondary.opacity(0.15), foreground: .primary)
                Spacer(minLength: 40)
            }
        case .tool(let name, let state):
            DisclosureGroup(isExpanded: $expanded) {
                Text(entry.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(name, systemImage: icon(for: state))
                    .font(.caption)
                    .foregroundStyle(state == .failed ? Color.red : Color.secondary)
            }
            .disabled(state == .running)
        case .error:
            Text(entry.text)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func bubble(_ text: String, background: Color, foreground: Color) -> some View {
        Text(text)
            .textSelection(.enabled)
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(background, in: RoundedRectangle(cornerRadius: 10))
    }

    private func icon(for state: ChatViewModel.ToolState) -> String {
        switch state {
        case .running: return "gearshape.arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
}
