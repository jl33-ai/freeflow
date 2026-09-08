import SwiftUI

struct ActivityJournalView: View {
    @ObservedObject var journal: ActivityJournal
    @State private var day = Date()
    @State private var intention = ""
    @State private var plannedMinutes = 60.0
    @State private var editing: JournalEntry?
    @State private var settings = false
    @State private var confirmDelete = false
    @State private var copied = false

    private var entries: [JournalEntry] {
        journal.archive.entries.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }.sorted { $0.start > $1.start }
    }
    private var goals: [JournalGoal] {
        journal.archive.goals.filter { Calendar.current.isDate($0.day, inSameDayAs: day) }
    }
    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes == 0 { return seconds > 0 ? "<1m" : "0m" }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
    private func moveDay(_ offset: Int) {
        day = Calendar.current.date(byAdding: .day, value: offset, to: day) ?? day
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("git for work").font(.title2.bold())
                Spacer()
                Button(journal.enabled ? "Pause" : "Start") { journal.setEnabled(!journal.enabled) }
                    .buttonStyle(.borderedProminent).disabled(journal.storageError != nil)
                Button { settings.toggle() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help("Settings")
                    .popover(isPresented: $settings, arrowEdge: .bottom) { preferences }
            }.padding(20)

            HStack {
                Button { moveDay(-1) } label: { Image(systemName: "chevron.left") }.help("Previous day")
                Text(isToday ? "Today" : day.formatted(date: .abbreviated, time: .omitted)).font(.headline)
                Button { moveDay(1) } label: { Image(systemName: "chevron.right") }.disabled(isToday).help("Next day")
                Spacer()
                Text("\(duration(entries.reduce(0) { $0 + $1.seconds })) recorded").foregroundStyle(.secondary)
                Button(copied ? "Copied" : "Copy") {
                    let history = JournalCore.commitHistory(journal.archive.entries, day: day)
                    guard !history.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(history, forType: .string)
                }.buttonStyle(.bordered).disabled(entries.isEmpty).help("Copy this day's commit history")
            }.buttonStyle(.plain).padding(.horizontal, 20).padding(.bottom, 16)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    DisclosureGroup("Daily plan") { plan.padding(.top, 10) }
                        .padding(.bottom, 20)
                    if entries.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "book.closed").font(.system(size: 30)).foregroundStyle(.tertiary)
                            Text(isToday ? "Your day will show up here." : "Nothing recorded this day.").font(.headline)
                            if isToday {
                                Text(journal.enabled ? "Your first entry will appear as you work." : "Click Start, then get on with your work.")
                                    .foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity).padding(.vertical, 75)
                    }
                    ForEach(entries) { entry in
                        Button { editing = entry } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 6) {
                                    Text(entry.start, style: .time).monospacedDigit()
                                    Text("· \(entry.app)")
                                    Spacer()
                                    Text(duration(entry.seconds)).monospacedDigit()
                                }.font(.caption).foregroundStyle(.secondary)
                                Text(entry.summary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                                if let goal = goals.first(where: { $0.id == entry.goalID }) {
                                    Label(goal.text, systemImage: "scope").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.padding(.vertical, 14).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Edit this entry")
                        Divider()
                    }
                }.padding(.horizontal, 20)
            }
            Divider()
            HStack {
                Text(journal.storageError ?? journal.status).lineLimit(2)
                Spacer()
                Label("On this Mac", systemImage: "lock").fixedSize()
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .sheet(item: $editing) { entry in
            JournalEntryEditor(entry: entry, goals: goals, save: { journal.update($0) }, delete: { journal.deleteEntry(entry.id) })
        }
        .onChange(of: day) { _ in copied = false }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { copied = false }
        }
        .alert("Delete all history?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { journal.deleteAll() }
        } message: { Text("All entries and daily plans will be removed. Recording will pause.") }
    }

    private var plan: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(goals) { goal in
                let actual = entries.filter { $0.goalID == goal.id }.reduce(0.0) { $0 + $1.seconds }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(goal.text)
                        Spacer()
                        Button { journal.removeGoal(goal.id) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove intention")
                    }
                    Text("\(duration(actual)) of \(duration(goal.minutes * 60)) planned").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("What do you want to get done?", text: $intention)
                TextField("Minutes", value: $plannedMinutes, format: .number).frame(width: 45)
                Text("min").foregroundStyle(.secondary)
                Button("Add") {
                    journal.addGoal(day: day, text: intention, minutes: plannedMinutes)
                    intention = ""
                }.disabled(intention.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || plannedMinutes <= 0)
            }
        }
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Everything stays on this Mac").font(.headline)
            Text("Local OCR reads the active window every 15 seconds. A local model describes your activity. No cloud processing or sync.")
            Text("Only entries and timing are saved, for 30 days. Screenshots and OCR text are discarded. Details are masked where possible, but entries can still be sensitive.")
            Divider()
            Text("Excluded apps").font(.headline)
            TextField("Names, separated by commas", text: $journal.excludedApps)
            Text("Password managers and this app are always excluded. Private-window detection is best effort; exclude your browser if needed.")
            Divider()
            Text(journal.modelStatus).foregroundStyle(.secondary)
            Text("Descriptions are AI interpretations; click an entry to correct it. FreeFlow dictation uses its own provider settings.").foregroundStyle(.secondary)
            Button("Screen Recording settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            Button("Delete all entries…", role: .destructive) { settings = false; confirmDelete = true }
        }.font(.callout).padding(20).frame(width: 320)
    }
}

private struct JournalEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: JournalEntry
    var goals: [JournalGoal]
    var save: (JournalEntry) -> Void
    var delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit entry").font(.title2.bold())
            TextEditor(text: $entry.summary).frame(height: 140).border(Color.secondary.opacity(0.2))
            if !goals.isEmpty {
                Picker("Daily plan", selection: $entry.goalID) {
                    Text("Not linked").tag(nil as UUID?)
                    ForEach(goals) { Text($0.text).tag(Optional($0.id)) }
                }
            }
            HStack {
                Button("Delete", role: .destructive) { delete(); dismiss() }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save(entry); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 440)
    }
}
