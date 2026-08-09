import SwiftUI
import OSLog

/// Console tab: live view of the app's os_log output (subsystem-filtered),
/// polled from OSLogStore while visible.
struct ConsoleView: View {
    /// True when hosted in the dedicated console window (hides the pop-out button).
    var isPopout = false

    @Environment(\.openWindow) private var openWindow
    @State private var logStore = LogStore.shared
    @State private var autoScroll = true

    private static let timeFormat = Date.FormatStyle.dateTime
        .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if logStore.filteredEntries.isEmpty {
                            Text("No log output yet.")
                                .foregroundStyle(.secondary)
                                .padding()
                        }
                        ForEach(logStore.filteredEntries) { entry in
                            row(entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal)
                }
                .onChange(of: logStore.filteredEntries.last?.id) { _, lastID in
                    if autoScroll, let lastID {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            .navigationTitle("Console")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Level", selection: $logStore.minimumLevel) {
                            Text("Debug").tag(OSLogEntryLog.Level.debug)
                            Text("Info").tag(OSLogEntryLog.Level.info)
                            Text("Notice").tag(OSLogEntryLog.Level.notice)
                            Text("Error").tag(OSLogEntryLog.Level.error)
                        }
                        Picker("Category", selection: $logStore.categoryFilter) {
                            Text("All Categories").tag(String?.none)
                            ForEach(logStore.categories, id: \.self) { category in
                                Text(category).tag(String?.some(category))
                            }
                        }
                    } label: {
                        Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                    }

                    Toggle(isOn: $autoScroll) {
                        Label("Auto-scroll", systemImage: "arrow.down.to.line")
                    }

                    Button {
                        Pasteboard.copy(logStore.filteredEntries
                            .map { "\($0.date.formatted(Self.timeFormat)) \($0.category) \($0.message)" }
                            .joined(separator: "\n"))
                    } label: {
                        Label("Copy All", systemImage: "doc.on.doc")
                    }

                    Button {
                        logStore.clear()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }

                    if !isPopout {
                        Button {
                            openWindow(id: "console")
                        } label: {
                            Label("Open in New Window", systemImage: "arrow.up.forward.app")
                        }
                    }
                }
            }
        }
        .onAppear { logStore.start() }
        .onDisappear { logStore.stop() }
    }

    private func row(_ entry: LogStore.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.date.formatted(Self.timeFormat))
                .foregroundStyle(.secondary)
            Text(entry.category)
                .foregroundStyle(.tint)
            Text(entry.message)
                .foregroundStyle(color(for: entry.level))
                .textSelection(.enabled)
        }
        .font(.system(.caption, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(for level: OSLogEntryLog.Level) -> Color {
        switch level {
        case .error, .fault: return .red
        case .debug: return .secondary
        default: return .primary
        }
    }
}
