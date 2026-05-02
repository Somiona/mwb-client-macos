import SwiftUI

struct LogConsoleView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        VStack(spacing: 0) {
            logTable
            toolbar
        }
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
    }

    private var logTable: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    let entries = InMemoryLogStore.shared.entries
                    ForEach(entries) { entry in
                        logRow(entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(minHeight: 200, maxHeight: 400)
            .font(.system(.caption, design: .monospaced))
            .onChange(of: InMemoryLogStore.shared.entries.count) {
                if let last = InMemoryLogStore.shared.entries.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func logRow(_ entry: LogEntry) -> some View {
        HStack(spacing: 6) {
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .foregroundStyle(.gray)
            Text(entry.category)
                .foregroundStyle(.cyan)
                .frame(width: 70, alignment: .leading)
            levelBadge(entry.level)
            Text(entry.message)
                .foregroundStyle(messageColor(entry.level))
                .lineLimit(1)
        }
    }

    private func levelBadge(_ level: LogLevel) -> some View {
        Text(level.rawValue.uppercased())
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(levelColor(level))
            .frame(width: 44, alignment: .center)
    }

    private func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .debug: return .gray
        case .info: return .gray
        case .warning: return .yellow
        case .error: return .red
        }
    }

    private func messageColor(_ level: LogLevel) -> Color {
        switch level {
        case .debug: return .gray.opacity(0.8)
        case .info: return .white.opacity(0.7)
        case .warning: return .yellow.opacity(0.9)
        case .error: return .red.opacity(0.9)
        }
    }

    private var toolbar: some View {
        HStack {
            Text("\(InMemoryLogStore.shared.entries.count) entries")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.gray)
            Spacer()
            Button {
                InMemoryLogStore.shared.clear()
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.gray)
            .help("Clear log")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.gray.opacity(0.15))
    }
}
