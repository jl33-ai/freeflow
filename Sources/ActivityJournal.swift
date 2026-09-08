import AppKit
import SwiftUI
import ImageIO

@MainActor
final class ActivityJournal: ObservableObject {
    static let shared = ActivityJournal()
    @Published private(set) var records: [RawCaptureIndex] = []
    @Published private(set) var enabled = true
    @Published private(set) var todayCount = 0
    private var todayIDs = Set<UUID>()
    private var countDay = RawCaptureJSON.day(Date())
    @Published private(set) var status = "Paused"
    @Published private(set) var modelStatus = "Qwen 3.5 · 9B vision"
    @Published private(set) var storageError: String?
    @Published private(set) var exporting = false
    @Published private(set) var captureInterval = JournalCore.captureInterval(UserDefaults.standard.double(forKey: "journal_capture_interval"))
    @Published var excludedApps = UserDefaults.standard.string(forKey: "journal_excluded_apps") ?? "" {
        didSet { UserDefaults.standard.set(excludedApps, forKey: "journal_excluded_apps") }
    }
    private let root: URL
    private let store: RawCaptureStore
    private var selectedDay = RawCaptureJSON.day(Date())
    private var viewGeneration = UUID()
    private var timer: Timer?
    private var started = false
    private var suspended = false
    private var observers: [NSObjectProtocol] = []
    private var capturing = false
    private var generation = UUID()
    private var inferenceTask: Task<Void, Never>?
    private var window: NSWindow?

    private init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppName.displayName).appendingPathComponent("GitForWorkRaw")
        store = RawCaptureStore(root: root)
    }

    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspended = true; self?.generation = UUID() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspended = false }
            })
        }
        Task {
            do {
                try await store.removeSourceMaterial()
                var all = try await store.list()
                // In-memory images cannot resume after restart. Keep explicit status, never fabricate OCR.
                for item in all where item.inferenceStatus == "pending" {
                    _ = try await store.saveInference(RawInference(status: "interrupted", error: "Image no longer retained."), index: item)
                }
                all = try await store.list()
                todayIDs = Set(all.filter { Calendar.current.isDateInToday($0.capturedAt) }.map(\.id))
                todayCount = todayIDs.count
                records = all.filter { $0.day == selectedDay }
                configureTimer()
                capture()
            } catch { failStorage() }
        }
    }

    func showDay(_ day: Date) {
        selectedDay = RawCaptureJSON.day(day)
        let token = UUID()
        viewGeneration = token
        let key = selectedDay
        Task {
            do {
                let items = try await store.list(day: key)
                if viewGeneration == token { records = items }
            } catch { storageError = "Could not read captures. Summaries have been preserved." }
        }
    }

    func setCaptureInterval(_ seconds: Double) {
        let interval = JournalCore.captureInterval(seconds)
        guard interval != captureInterval else { return }
        captureInterval = interval
        UserDefaults.standard.set(interval, forKey: "journal_capture_interval")
        configureTimer()
    }

    private func configureTimer() {
        timer?.invalidate(); timer = nil
        guard enabled, storageError == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: captureInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.capture() }
        }
        timer?.tolerance = min(1, captureInterval * 0.05)
    }

    func setEnabled(_ value: Bool) {
        guard storageError == nil else { return }
        generation = UUID()
        enabled = value
        UserDefaults.standard.set(value, forKey: "journal_enabled")
        configureTimer()
        status = value ? "Starting…" : "Paused"
        if value { capture() }
    }

    func requestCapturePermission() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        let key = "journal_screen_permission_requested"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            _ = CGRequestScreenCaptureAccess()
        } else { openPermissions() }
    }

    func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func shutdown() {
        generation = UUID()
        timer?.invalidate()
        // Screenshot buffers are memory-only and are released when the process exits.
    }

    private func publish(_ index: RawCaptureIndex) {
        refreshCountDay()
        if Calendar.current.isDateInToday(index.capturedAt) { todayIDs.insert(index.id); todayCount = todayIDs.count }
        guard index.day == selectedDay else { return }
        if let position = records.firstIndex(where: { $0.id == index.id }) { records[position] = index }
        else { records.append(index) }
    }

    private func failStorage() {
        storageError = "Recording stopped. Check disk space and file access, then restart the app. Summaries are preserved."
        enabled = false
        UserDefaults.standard.set(false, forKey: "journal_enabled")
        configureTimer()
    }

    private func refreshCountDay() {
        let current = RawCaptureJSON.day(Date())
        if current != countDay { countDay = current; todayIDs.removeAll(); todayCount = 0 }
    }

    private func capture() {
        refreshCountDay()
        guard enabled, storageError == nil else { return }
        guard !suspended else { status = "Asleep · no screenshots"; return }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any], session["CGSSessionScreenIsLocked"] as? Bool == true {
            status = "Locked · no screenshots"; return
        }
        guard CGPreflightScreenCaptureAccess() else { status = "Screen Recording permission required"; return }
        guard !capturing else { status = "Finishing the previous screenshot"; return }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier,
              !JournalCore.excluded(bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? "", custom: excludedApps) else {
            status = "Excluded app · no screenshots"; return
        }
        capturing = true
        let token = generation
        let requestedAt = Date()
        let idle = JournalCapture.idleSeconds()
        let interval = captureInterval
        let pid = app.processIdentifier
        let name = app.localizedName ?? "Unknown app"
        let bundle = app.bundleIdentifier
        let executable = app.executableURL?.path
        Task {
            defer { capturing = false }
            do {
                let result = try await Task.detached(priority: .utility) { () -> (JournalCapture.WindowCapture, Data)? in
                    guard let capture = try await JournalCapture.captureWindow(pid: pid),
                          let png = NSBitmapImageRep(cgImage: capture.image).representation(using: .png, properties: [:]) else { return nil }
                    return (capture, png)
                }.value
                guard token == generation, enabled else { return }
                guard let (capture, png) = result else { status = "Window unavailable or private · skipped"; return }
                let zone = TimeZone.current
                let record = RawObservation(id: UUID(), requestedAt: requestedAt, capturedAt: capture.capturedAt,
                    localTimestamp: RawCaptureJSON.timestamp(capture.capturedAt, timeZone: zone), timeZoneIdentifier: zone.identifier,
                    utcOffsetSeconds: zone.secondsFromGMT(for: capture.capturedAt), intervalSeconds: interval, idleSeconds: idle.isFinite ? idle : nil,
                    appName: name, bundleIdentifier: bundle, processID: pid, executablePath: executable,
                    windowID: capture.windowID, windowTitle: capture.title, windowBounds: RawRect(capture.bounds),
                    imageWidth: capture.image.width, imageHeight: capture.image.height,
                    osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    documentURL: capture.documentURL, focusedElementRole: capture.focusedRole,
                    frontmostAtCompletion: NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)
                let index = try await store.save(record)
                publish(index)
                if inferenceTask == nil { runInference(index: index, record: record, png: png) }
                else {
                    publish(try await store.saveInference(RawInference(status: "skipped", error: "Previous description still processing. Image discarded."), index: index))
                }
                status = "Reading the screen every \(Int(captureInterval)) seconds"
            } catch {
                // Capture API failures do not destroy prior captures or their processing queue.
                status = "Capture failed; retrying at the next interval"
                if (error as NSError).domain == NSCocoaErrorDomain { failStorage() }
            }
        }
    }

    private func runInference(index: RawCaptureIndex, record: RawObservation, png: Data) {
        modelStatus = "Describing screenshot locally"
        inferenceTask = Task {
            do {
                let inference: RawInference
                do {
                    let result = try await JournalLocalModel.summarize(app: record.appName,
                        observations: "Window: \(record.windowTitle)", screenshotPNG: png)
                    inference = RawInference(status: "complete", completedAt: Date(), summary: result.summary, category: result.category, confidence: result.confidence,
                                             modelInputCharacterLimit: 0, modelInputTruncated: false, inputMode: "screenshot+app/window metadata")
                } catch {
                    inference = RawInference(status: "failed", completedAt: Date(), error: "Local model unavailable or response invalid. Screenshot discarded.",
                                             modelInputCharacterLimit: 0, modelInputTruncated: false, inputMode: "screenshot+app/window metadata")
                }
                let updated = try await store.saveInference(inference, index: index)
                publish(updated)
            } catch { failStorage() }
            inferenceTask = nil
            modelStatus = "Qwen 3.5 · 9B vision"
        }
    }

    func revealCapture(_ index: RawCaptureIndex) {
        Task {
            if let folder = try? await store.folder(index) { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        }
    }

    func revealStorage() { NSWorkspace.shared.open(root) }

    func export(day: Date? = nil) {
        guard !exporting else { return }
        exporting = true
        let selected = day ?? Date()
        Task {
            defer { exporting = false }
            do {
                let text = try await store.summaryText(day: selected)
                guard !text.isEmpty else { status = "No completed LLM summaries for this day"; return }
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(text, forType: .string) else { throw CocoaError(.fileWriteUnknown) }
                status = "Copied summaries to clipboard"
            } catch { status = "Could not copy summaries. Please try again." }
        }
    }

    func showWindow() {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            panel.title = "Git for Work (Den)"
            panel.contentView = NSHostingView(rootView: ActivityJournalView(journal: self))
            panel.minSize = NSSize(width: 500, height: 420)
            panel.isReleasedWhenClosed = false
            panel.center(); window = panel
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
