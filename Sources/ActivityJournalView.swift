import SwiftUI

struct ActivityJournalView: View {
    @ObservedObject var journal: ActivityJournal
    @State private var day = Date()
    @State private var intention = ""
    @State private var plannedMinutes = 60.0
    @State private var editing: JournalEntry?
    @State private var confirmDelete = false

    private var entries: [JournalEntry] {
        journal.archive.entries.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }.sorted { $0.start > $1.start }
    }
    private var goals: [JournalGoal] {
        journal.archive.goals.filter { Calendar.current.isDate($0.day, inSameDayAs: day) }
    }
    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Activity Journal").font(.largeTitle.bold())
                    Text(journal.status).foregroundStyle(journal.enabled ? .green : .secondary)
                }
                Spacer()
                Toggle("Journal enabled", isOn: Binding(get: { journal.enabled }, set: { journal.setEnabled($0) }))
                    .toggleStyle(.switch).disabled(journal.storageError != nil)
            }
            Text("Frequent OCR of the active window. Specific summaries stay on this Mac for 30 days. Screenshots and OCR text are discarded after interpretation. Names and identifiers are masked on a best-effort basis; summaries can still be sensitive.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                DatePicker("Day", selection: $day, in: ...Date(), displayedComponents: .date).frame(width: 210)
                Text("\(duration(entries.reduce(0) { $0 + $1.seconds })) observed").font(.headline)
                Spacer()
                Button("Mark reviewed") { journal.review(day: day) }.disabled(entries.isEmpty)
                if journal.archive.reviewedDays[JournalCore.dayKey(day)] != nil {
                    Label("Reviewed", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    intentions
                    if !entries.isEmpty {
                        let totals = Dictionary(grouping: entries, by: \.category).map { ($0.key, $0.value.reduce(0.0) { $0 + $1.seconds }) }.sorted { $0.1 > $1.1 }
                        Text(totals.map { "\($0.0): \(duration($0.1))" }.joined(separator: "  ·  "))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Observed sessions").font(.title2.bold())
                        Spacer()
                        Text("App presence is evidence, not proof of completion.").font(.caption).foregroundStyle(.secondary)
                    }
                    if entries.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Your workday, with the details intact.").font(.headline)
                            Text("Enable the journal, then work normally. A new session is interpreted about every two minutes or when you switch apps. Add intentions above to compare planned and observed time.")
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.07)).cornerRadius(12)
                    }
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(entry.start, style: .time).monospacedDigit()
                                Text("→")
                                Text(entry.end, style: .time).monospacedDigit()
                                Text("· \(duration(entry.seconds)) · \(entry.app)")
                                Spacer()
                                Text(entry.category).font(.caption.bold())
                                Button("Edit") { editing = entry }
                            }.font(.callout)
                            Text(entry.summary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            HStack {
                                Text("\(entry.sampleCount) OCR observations · \(entry.edited ? "manually reviewed" : "confidence: \(entry.confidence)")")
                                if let goal = goals.first(where: { $0.id == entry.goalID }) { Text("· \(goal.text)").lineLimit(1) }
                                Spacer()
                                Button(role: .destructive) { journal.deleteEntry(entry.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                            }.font(.caption).foregroundStyle(.secondary)
                        }.padding(16).background(Color.secondary.opacity(0.06)).cornerRadius(12)
                    }
                }.padding(.vertical, 4)
            }
            Divider()
            DisclosureGroup("Privacy and local processing") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Exclude apps (comma-separated names or bundle IDs)", text: $journal.excludedApps)
                    Text("Password managers and this app are excluded. Private browser windows are skipped when their title identifies them; exclude your browser for a stronger boundary. Idle time after two minutes, lock and sleep are not recorded. No cloud fallback.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(journal.modelStatus).font(.caption)
                        Spacer()
                        Button("Delete entire journal…", role: .destructive) { confirmDelete = true }
                    }
                }.padding(.top, 8)
            }
            if let error = journal.storageError { Text(error).foregroundStyle(.red) }
        }
        .padding(24)
        .sheet(item: $editing) { entry in JournalEntryEditor(entry: entry, goals: goals) { journal.update($0) } }
        .alert("Delete the entire journal?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { journal.deleteAll() }
        } message: { Text("This removes all saved sessions, intentions and review markers, and pauses recording.") }
    }

    private var intentions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What you intended to do").font(.title2.bold())
            HStack {
                TextField("e.g. Rewrite the opening scene until the disagreement feels earned", text: $intention)
                TextField("Minutes", value: $plannedMinutes, format: .number).frame(width: 60)
                Text("min").foregroundStyle(.secondary)
                Button("Add intention") {
                    journal.addGoal(day: day, text: intention, minutes: plannedMinutes)
                    intention = ""
                }.disabled(intention.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || plannedMinutes <= 0)
            }
            ForEach(goals) { goal in
                let actual = entries.filter { $0.goalID == goal.id }.reduce(0.0) { $0 + $1.seconds }
                HStack {
                    Text(goal.text)
                    Spacer()
                    Text("\(duration(actual)) observed / \(duration(goal.minutes * 60)) planned").monospacedDigit().foregroundStyle(.secondary)
                    Button { journal.removeGoal(goal.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
                }.font(.callout)
            }
            if !goals.isEmpty {
                Text("Unmatched: \(duration(entries.filter { $0.goalID == nil }.reduce(0) { $0 + $1.seconds })). Edit sessions to correct automatic matches.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct JournalEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: JournalEntry
    var goals: [JournalGoal]
    var save: (JournalEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Correct this session").font(.title2.bold())
            TextField("Category", text: $entry.category)
            TextEditor(text: $entry.summary).frame(height: 140).border(Color.secondary.opacity(0.3))
            Picker("Intention", selection: $entry.goalID) {
                Text("Unmatched").tag(nil as UUID?)
                ForEach(goals) { Text($0.text).tag(Optional($0.id)) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save(entry); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 550)
    }
}
