import SwiftUI

struct ActivityJournalView: View {
    @ObservedObject var journal: ActivityJournal
    @State private var day = Date()
    @State private var settings = false
    @State private var captureSeconds = 15.0
    @FocusState private var editingCaptureInterval: Bool
    private var isToday: Bool { Calendar.current.isDateInToday(day) }

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
                Text("\(journal.records.count) captures").foregroundStyle(.secondary)
                Menu(journal.exporting ? "Exporting…" : "Export") {
                    Button("This day…") { journal.export(day: day) }
                    Button("All captures…") { journal.export(day: nil) }
                }.disabled(journal.exporting)
            }.buttonStyle(.plain).padding(.horizontal, 20).padding(.bottom, 16)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if journal.records.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "camera").font(.system(size: 30)).foregroundStyle(.tertiary)
                            Text("Your raw captures will show up here.").font(.headline)
                            Text("Screenshots, literal OCR, and local activity descriptions.").foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 75)
                    }
                    ForEach(journal.records.sorted { $0.capturedAt > $1.capturedAt }) { item in
                        Button { journal.revealCapture(item) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(item.capturedAt, style: .time).monospacedDigit()
                                    Text("· \(item.appName)")
                                    Spacer()
                                    Image(systemName: "folder")
                                }.font(.caption).foregroundStyle(.secondary)
                                Text(item.summary.isEmpty ? (item.inferenceStatus == "failed" ? "Description unavailable. Raw capture saved." : "Raw capture saved. Processing locally…") : item.summary)
                                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                                if item.ocrStatus == "failed" { Text("OCR failed; original screenshot is available.").font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 14).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Open screenshot, OCR and metadata files")
                        Divider()
                    }
                }.padding(.horizontal, 20)
            }
            Divider()
            HStack {
                Text(journal.storageError ?? journal.status).lineLimit(2)
                if journal.status == "Screen Recording permission required" {
                    Button("Allow…") { journal.requestCapturePermission() }
                }
                Spacer()
                Label("On this Mac", systemImage: "lock").fixedSize()
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .onAppear { journal.showDay(day) }
        .onChange(of: day) { value in journal.showDay(value) }
    }

    private func moveDay(_ offset: Int) { day = Calendar.current.date(byAdding: .day, value: offset, to: day) ?? day }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Screenshot every")
                TextField("Seconds", value: $captureSeconds, format: .number).frame(width: 50)
                    .focused($editingCaptureInterval).onSubmit { saveInterval() }
                Text("seconds")
            }
            Text("5–300 seconds. Captures continue while idle; lock, sleep and excluded windows are skipped.").foregroundStyle(.secondary)
            Divider()
            Text("Raw means raw").font(.headline)
            Text("Full-resolution PNGs, literal OCR and app/window metadata are saved locally until you delete them. Raw files are not obfuscated and can include private text visible on screen.")
            Text("Every capture is queued for local OCR and an activity description. Export includes the originals even if processing is pending or fails.")
            TextField("Excluded apps, separated by commas", text: $journal.excludedApps)
            Text("Password managers and this app are excluded. Private-window detection is best effort.").foregroundStyle(.secondary)
            Divider()
            Text(journal.modelStatus).foregroundStyle(.secondary)
            Button("Open raw data folder") { journal.revealStorage() }
            Button("Screen Recording settings…") { journal.openPermissions() }
            Text("No cloud processing or sync. FreeFlow dictation has separate provider settings.").foregroundStyle(.secondary)
        }.font(.callout).padding(20).frame(width: 340)
            .onAppear { captureSeconds = journal.captureInterval }
            .onChange(of: editingCaptureInterval) { focused in if !focused { saveInterval() } }
            .onDisappear { saveInterval() }
    }
    private func saveInterval() { journal.setCaptureInterval(captureSeconds); captureSeconds = journal.captureInterval }
}
