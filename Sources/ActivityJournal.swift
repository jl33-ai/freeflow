import AppKit
import SwiftUI

@MainActor
final class ActivityJournal: ObservableObject {
    static let shared = ActivityJournal()
    @Published private(set) var archive = JournalArchive()
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "journal_enabled")
    @Published private(set) var status = "Paused"
    @Published private(set) var modelStatus = "Local model: Qwen 2.5 · 3B"
    @Published private(set) var storageError: String?
    @Published var excludedApps = UserDefaults.standard.string(forKey: "journal_excluded_apps") ?? "" {
        didSet {
            UserDefaults.standard.set(excludedApps, forKey: "journal_excluded_apps")
            finishSession()
        }
    }
    private let disk = JournalDiskStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(AppName.displayName).appendingPathComponent("ActivityJournal"))
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []
    private var suspended = false
    private var screenLocked = false
    private var capturing = false
    private var generation = UUID()
    private var captureGeneration = UUID()
    private var activeID: UUID?
    private var activePID: pid_t?
    private var identity = ""
    private var lastObservation: Date?
    private var observations: [String] = []
    private var lastSaved = Date.distantPast
    private var window: NSWindow?
    private struct Pending {
        var entry: JournalEntry
        var text: String
    }
    private var pending: [Pending] = []
    private var modelTask: Task<Void, Never>?

    private init() {
        do { archive = try disk.load() }
        catch { storageError = "Journal could not be read. Recording is stopped to protect the existing file."; enabled = false }
    }

    func start() {
        guard timer == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.finishSession()
                self?.sample()
            }
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspend() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspended = false }
            })
        }
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            lockObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.screenLocked = locked
                    if locked { self?.suspend() } else { self?.suspended = false }
                }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        timer?.tolerance = 2
        sample()
    }

    func setEnabled(_ value: Bool) {
        guard storageError == nil else { return }
        if !value { finishSession() }
        enabled = value
        UserDefaults.standard.set(value, forKey: "journal_enabled")
        status = value ? "Starting OCR…" : "Paused"
        if value { sample() }
    }

    func shutdown() { finishSession(); persist() }

    private func suspend() {
        finishSession()
        suspended = true
        status = "Paused while locked or asleep"
    }

    private var idle: Double {
        JournalCapture.idleSeconds()
    }

    private func credit(until now: Date) {
        guard let id = activeID, let last = lastObservation,
              let index = archive.entries.firstIndex(where: { $0.id == id }) else { return }
        // Never carry time into the next day or across a long scheduling gap.
        let boundary = Calendar.current.startOfDay(for: last).addingTimeInterval(36 * 3600)
        let nextDay = Calendar.current.startOfDay(for: boundary)
        let end = min(now, nextDay)
        let seconds = JournalCore.creditedSeconds(from: last, to: now, idle: idle)
        archive.entries[index].seconds += min(seconds, max(0, end.timeIntervalSince(last)))
        archive.entries[index].end = end
        lastObservation = now
    }

    private func finishSession(at now: Date = Date()) {
        captureGeneration = UUID()
        guard activeID != nil else { return }
        credit(until: now)
        if let id = activeID, let entry = archive.entries.first(where: { $0.id == id }), !observations.isEmpty {
            if pending.count < 4 {
                pending.append(Pending(entry: entry, text: observations.joined(separator: "\n--- next observation ---\n")))
            } else if let index = archive.entries.firstIndex(where: { $0.id == id }) {
                archive.entries[index].summary = "Local interpretation queue was full. Visible activity was not interpreted."
            }
        }
        activeID = nil; activePID = nil; identity = ""; lastObservation = nil; observations = []
        persist()
        drainQueue()
    }

    private func sample() {
        guard enabled, storageError == nil else { return }
        guard !suspended, !screenLocked else { return }
        // Also catches a locked session when launched after the lock notification.
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any], session["CGSSessionScreenIsLocked"] as? Bool == true {
            suspend(); return
        }
        guard idle < 120 else { finishSession(); status = "Idle · no screenshots"; return }
        guard CGPreflightScreenCaptureAccess() else {
            finishSession(); status = "Screen Recording permission required"; return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              !JournalCore.excluded(bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? "", custom: excludedApps) else {
            finishSession(); status = "Excluded app · no screenshots"; return
        }
        let now = Date()
        if let id = activeID, let entry = archive.entries.first(where: { $0.id == id }),
           (activePID != app.processIdentifier || now.timeIntervalSince(entry.start) >= 120 || !Calendar.current.isDate(entry.start, inSameDayAs: now)) {
            finishSession()
        }
        guard !capturing else { return }
        credit(until: now)
        capturing = true
        let epoch = captureGeneration
        let pid = app.processIdentifier
        let appName = app.localizedName ?? "Unknown app"
        Task {
            let snapshot = await Task.detached(priority: .utility) { try? await JournalCapture.capture(pid: pid) }.value
            capturing = false
            guard epoch == captureGeneration, enabled, !suspended,
                  !screenLocked, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            guard let snapshot else {
                finishSession(); status = "Window unavailable or private · skipped"; return
            }
            if activeID != nil && identity != snapshot.identity { finishSession(at: now) }
            if activeID == nil {
                let entry = JournalEntry(start: now, end: now, app: appName)
                activeID = entry.id; activePID = pid; identity = snapshot.identity
                archive.entries.append(entry)
            }
            lastObservation = now
            if let index = archive.entries.firstIndex(where: { $0.id == activeID }) {
                archive.entries[index].sampleCount += 1
            }
            // Bounded rolling evidence: the first view and up to three recent views.
            let text = String(snapshot.text.prefix(4500))
            if observations.last != text {
                if observations.count >= 4 { observations.remove(at: 1) }
                observations.append(text)
            }
            status = "Recording your day"
            if Date().timeIntervalSince(lastSaved) >= 60 { persist() }
        }
    }

    private func drainQueue() {
        guard modelTask == nil, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        let epoch = generation
        let goals = archive.goals.filter { Calendar.current.isDate($0.day, inSameDayAs: job.entry.start) }
        modelStatus = "Interpreting on this Mac…"
        modelTask = Task {
            do {
                let result = try await JournalLocalModel.summarize(app: job.entry.app, observations: job.text, goals: goals)
                guard epoch == generation else { return }
                if let index = archive.entries.firstIndex(where: { $0.id == job.entry.id }), !archive.entries[index].edited {
                    archive.entries[index].summary = result.summary
                    archive.entries[index].category = result.category
                    archive.entries[index].confidence = result.confidence
                    archive.entries[index].goalID = goals.first { $0.id.uuidString == result.goalID }?.id
                    persist()
                }
                modelStatus = "Local model ready · Qwen 2.5 3B"
            } catch {
                guard epoch == generation else { return }
                modelStatus = "Local model unavailable. App time is still recorded; no cloud fallback."
                if let index = archive.entries.firstIndex(where: { $0.id == job.entry.id }), !archive.entries[index].edited {
                    archive.entries[index].summary = "Observed foreground activity; local interpretation was unavailable."
                    persist()
                }
            }
            modelTask = nil
            drainQueue()
        }
    }

    private func persist() {
        guard storageError == nil else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        archive.entries.removeAll { $0.end < cutoff }
        archive.goals.removeAll { $0.day < Calendar.current.startOfDay(for: cutoff) }
        do { try disk.save(archive); lastSaved = Date() }
        catch {
            storageError = "Could not save journal. Recording stopped; check disk space and file permissions."
            enabled = false
            UserDefaults.standard.set(false, forKey: "journal_enabled")
        }
    }

    func addGoal(day: Date, text: String, minutes: Double) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, minutes.isFinite, minutes > 0 else { return }
        archive.goals.append(JournalGoal(day: Calendar.current.startOfDay(for: day), text: JournalCore.redact(String(clean.prefix(500))), minutes: minutes))
        persist()
    }

    func removeGoal(_ id: UUID) {
        archive.goals.removeAll { $0.id == id }
        for index in archive.entries.indices where archive.entries[index].goalID == id { archive.entries[index].goalID = nil }
        persist()
    }

    func update(_ entry: JournalEntry) {
        guard let index = archive.entries.firstIndex(where: { $0.id == entry.id }) else { return }
        var revised = entry
        revised.summary = JournalCore.redact(String(entry.summary.prefix(900)))
        revised.category = JournalCore.redact(String(entry.category.prefix(80)))
        revised.edited = true
        // Preserve live timer updates while a user edits the description.
        revised.seconds = archive.entries[index].seconds
        revised.end = archive.entries[index].end
        revised.sampleCount = archive.entries[index].sampleCount
        archive.entries[index] = revised
        persist()
    }

    func deleteEntry(_ id: UUID) {
        if activeID == id { finishSession() }
        archive.entries.removeAll { $0.id == id }
        pending.removeAll { $0.entry.id == id }
        persist()
    }

    func deleteAll() {
        enabled = false; UserDefaults.standard.set(false, forKey: "journal_enabled")
        generation = UUID(); captureGeneration = UUID()
        modelTask?.cancel(); modelTask = nil; pending = []; observations = []
        activeID = nil; activePID = nil; lastObservation = nil
        archive = JournalArchive(); storageError = nil
        persist(); status = "Paused · journal cleared"
    }

    func showWindow() {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            panel.title = "git for work"
            panel.contentView = NSHostingView(rootView: ActivityJournalView(journal: self))
            panel.minSize = NSSize(width: 500, height: 420)
            panel.isReleasedWhenClosed = false
            panel.center(); window = panel
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
