import AppKit
import SwiftUI

/// The Schedules section of the Mac Projects tab: recurring headless agent runs
/// in the sandbox, fired by `LocalScheduler` while the app runs.
struct SchedulesSection: View {
    @Environment(LocalScheduler.self) private var scheduler
    @Environment(LocalSandboxController.self) private var sandbox
    @State private var editing: ScheduleDraft?
    @State private var expanded: Set<UUID> = []
    @State private var confirmDelete: ScheduledRun?

    var body: some View {
        Section {
            if let missing = scheduler.missingDenies, !missing.isEmpty {
                Label("The sandbox's Claude settings don't deny \(missing.joined(separator: ", ")). Agents could schedule themselves — re-run provision-golden.sh and snapshot the golden home.",
                      systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange)
            }
            if scheduler.schedules.isEmpty {
                Text("No schedules. A schedule runs an agent headless in a sandbox project on a cadence, with a runtime cap and a daily limit.")
                    .foregroundStyle(.secondary)
            }
            ForEach(scheduler.schedules) { schedule in
                scheduleRow(schedule)
                if expanded.contains(schedule.id) {
                    ForEach(scheduler.records(for: schedule)) { record in
                        RunRecordRow(record: record)
                    }
                }
            }
            HStack {
                Button("New Schedule…") { editing = ScheduleDraft(project: sandbox.projects.first?.bareName ?? "") }
                    .disabled(sandbox.projects.isEmpty)
                Spacer()
                Toggle("Open Longwave Companion at login", isOn: Binding(
                    get: { scheduler.openAtLogin }, set: { scheduler.openAtLogin = $0 }))
                    .toggleStyle(.checkbox)
            }
            if let error = scheduler.lastError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        } header: {
            Text("Schedules")
        } footer: {
            Text("Schedules fire only while Longwave Companion is running. Runs never overlap, bypass the agent's own permission prompts (the sandbox account is the boundary), and \"Reset before run\" also ends any interactive sessions.")
        }
        .task { await scheduler.checkSelfSchedulingGuard() }
        .sheet(item: $editing) { draft in
            ScheduleEditor(draft: draft) { saved in
                scheduler.save(saved.apply(), isNew: saved.isNew)
            }
            .environment(sandbox)
            .frame(minWidth: 520, minHeight: 560)
        }
        .confirmationDialog("Delete this schedule and its run history?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let s = confirmDelete { scheduler.delete(s) }
                confirmDelete = nil
            }
        }
    }

    private func scheduleRow(_ schedule: ScheduledRun) -> some View {
        HStack(alignment: .top) {
            Toggle("", isOn: Binding(get: { schedule.isEnabled },
                                     set: { scheduler.setEnabled(schedule, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(schedule.name.isEmpty ? schedule.projectDisplayName : schedule.name).font(.headline)
                Text("\(AgentSchedule.displayName(for: schedule.agent)) · \(schedule.projectDisplayName) · \(schedule.cadence.summary)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if let status = schedule.lastStatus {
                        Label(status.label, systemImage: status.symbol).font(.caption)
                    }
                    if scheduler.active[schedule.id] == nil, let next = schedule.nextRunAt, schedule.isEnabled {
                        Text("Next \(next.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if let record = scheduler.active[schedule.id] {
                Button("Attach") { scheduler.attach(record) }.disabled(record.tmuxSession.isEmpty)
                Button("Stop", role: .destructive) { scheduler.stop(schedule) }
            } else {
                Button("Run Now") { scheduler.runNow(schedule) }
            }
            Button {
                if expanded.contains(schedule.id) { expanded.remove(schedule.id) } else { expanded.insert(schedule.id) }
            } label: {
                Image(systemName: expanded.contains(schedule.id) ? "chevron.up" : "clock.arrow.circlepath")
            }
            .help("Run history")
            Menu {
                Button("Edit…") { editing = ScheduleDraft(schedule) }
                Button("Delete…", role: .destructive) { confirmDelete = schedule }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
        }
    }
}

private struct RunRecordRow: View {
    @Environment(LocalScheduler.self) private var scheduler
    let record: RunRecord

    var body: some View {
        HStack {
            Label(record.status.label, systemImage: record.status.symbol)
                .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened) + duration)
                    .font(.caption)
                let detail = [record.summary, record.note].filter { !$0.isEmpty }.joined(separator: " — ")
                if !detail.isEmpty {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    if record.resetBefore { Text("reset first").font(.caption2).foregroundStyle(.secondary) }
                    Text(record.firewallOn ? "firewall on" : "firewall off").font(.caption2).foregroundStyle(.secondary)
                    if let code = record.exitCode { Text("exit \(code)").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            if let path = record.transcriptPath {
                Button("Transcript") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            }
        }
        .padding(.leading, 28)
    }

    private var duration: String {
        guard let end = record.endedAt, record.status != .skipped else { return "" }
        let secs = Int(end.timeIntervalSince(record.startedAt))
        return secs < 60 ? " · \(secs)s" : " · \(secs / 60)m \(secs % 60)s"
    }
}

/// Editable copy of a schedule, so Cancel discards changes.
struct ScheduleDraft: Identifiable {
    let id = UUID()
    let target: ScheduledRun?
    var isNew: Bool { target == nil }
    var name = ""
    var project = ""
    var agent: SSHAgent = .claude
    var prompt = ""
    var daily = false
    var intervalValue = 1
    var intervalInHours = true
    var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    var weekdays: Set<Int> = []
    var maxRuntimeMinutes = 30
    var maxRunsPerDay = 6
    var resetBeforeRun = false
    var isEnabled = true

    init(project: String) {
        target = nil
        self.project = project
    }

    init(_ s: ScheduledRun) {
        target = s
        name = s.name
        project = s.projectBareName
        agent = s.agent
        prompt = s.prompt
        switch s.cadence {
        case .interval(let minutes):
            daily = false
            if minutes % 60 == 0 { intervalValue = minutes / 60; intervalInHours = true }
            else { intervalValue = minutes; intervalInHours = false }
        case .daily(let hour, let minute, let days):
            daily = true
            time = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
            weekdays = days
        }
        maxRuntimeMinutes = s.maxRuntimeMinutes
        maxRunsPerDay = s.maxRunsPerDay
        resetBeforeRun = s.resetBeforeRun
        isEnabled = s.isEnabled
    }

    var cadence: AgentSchedule.Cadence {
        if daily {
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            return .daily(hour: c.hour ?? 9, minute: c.minute ?? 0, weekdays: weekdays)
        }
        return .interval(minutes: intervalInHours ? intervalValue * 60 : intervalValue)
    }

    var isValid: Bool {
        !project.isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (daily || (intervalInHours ? intervalValue >= 1 : intervalValue >= AgentSchedule.Cadence.minimumIntervalMinutes))
    }

    /// Writes the draft into its schedule (a new one if needed) and returns it.
    func apply() -> ScheduledRun {
        let s = target ?? ScheduledRun()
        s.name = name.trimmingCharacters(in: .whitespaces)
        s.projectBareName = project
        s.agent = agent
        s.prompt = prompt
        s.cadence = cadence
        s.maxRuntimeMinutes = max(1, maxRuntimeMinutes)
        s.maxRunsPerDay = max(0, maxRunsPerDay)
        s.resetBeforeRun = resetBeforeRun
        s.isEnabled = isEnabled
        return s
    }
}

private struct ScheduleEditor: View {
    @Environment(LocalSandboxController.self) private var sandbox
    @Environment(\.dismiss) private var dismiss
    @State var draft: ScheduleDraft
    let onSave: (ScheduleDraft) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("e.g. Nightly tests"))
                    Picker("Project", selection: $draft.project) {
                        ForEach(sandbox.projects) { Text($0.displayName).tag($0.bareName) }
                    }
                    Picker("Agent", selection: $draft.agent) {
                        ForEach(AgentSchedule.schedulableAgents) { Text(AgentSchedule.displayName(for: $0)).tag($0) }
                    }
                }
                Section(draft.agent == .custom ? "Command (run with zsh in the project folder)" : "Prompt") {
                    PlainTextEditor(text: $draft.prompt)
                        .frame(minHeight: 90)
                }
                Section("When") {
                    Picker("Cadence", selection: $draft.daily) {
                        Text("Every…").tag(false)
                        Text("Daily at…").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if draft.daily {
                        DatePicker("Time", selection: $draft.time, displayedComponents: .hourAndMinute)
                        HStack {
                            ForEach(1...7, id: \.self) { day in
                                Toggle(Calendar.current.veryShortWeekdaySymbols[day - 1], isOn: Binding(
                                    get: { draft.weekdays.contains(day) },
                                    set: { on in if on { draft.weekdays.insert(day) } else { draft.weekdays.remove(day) } }))
                                    .toggleStyle(.button)
                            }
                        }
                        Text(draft.weekdays.isEmpty ? "Every day" : "Only on the selected days")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Stepper(value: $draft.intervalValue, in: 1...720) { Text("\(draft.intervalValue)") }
                            Picker("", selection: $draft.intervalInHours) {
                                Text("minutes").tag(false)
                                Text("hours").tag(true)
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        if !draft.intervalInHours, draft.intervalValue < AgentSchedule.Cadence.minimumIntervalMinutes {
                            Text("At least \(AgentSchedule.Cadence.minimumIntervalMinutes) minutes.")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                Section("Limits") {
                    Stepper("Stop a run after \(draft.maxRuntimeMinutes) min", value: $draft.maxRuntimeMinutes, in: 1...720)
                    Stepper(draft.maxRunsPerDay == 0 ? "No daily limit" : "At most \(draft.maxRunsPerDay) runs a day",
                            value: $draft.maxRunsPerDay, in: 0...96)
                    Toggle("Reset the sandbox before each run", isOn: $draft.resetBeforeRun)
                    Toggle("Enabled", isOn: $draft.isEnabled)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Create" : "Save") { onSave(draft); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid)
            }
            .padding()
        }
    }
}

/// A monospaced text editor with macOS's smart substitutions off. SwiftUI's
/// `TextEditor` inherits the system's smart quotes and dashes, which turned a
/// typed `"` into `“` and `--` into `—` — fatal in a shell command, and wrong
/// in a prompt that quotes code. There's no SwiftUI switch for it on macOS.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.textContainerInset = NSSize(width: 4, height: 6)
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}
