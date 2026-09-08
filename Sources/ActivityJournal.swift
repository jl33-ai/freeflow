import AppKit
import SwiftUI
import ImageIO

@MainActor
final class ActivityJournal: ObservableObject {
    static let shared = ActivityJournal()
    @Published private(set) var records: [RawCaptureIndex] = []
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "journal_enabled")
    @Published private(set) var status = "Paused"
    @Published private(set) var modelStatus = "Local OCR and Qwen 2.5 · 3B"
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
    private var ocrQueue: [RawCaptureIndex] = []
    private var inferenceQueue: [RawCaptureIndex] = []
    private var ocrTask: Task<Void, Never>?
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
                let all = try await store.list()
                records = all.filter { $0.day == selectedDay }
                ocrQueue = all.filter { $0.ocrStatus == "pending" }
                inferenceQueue = all.filter { $0.ocrStatus != "pending" && $0.inferenceStatus == "pending" }
                runOCR(); runInference()
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
            } catch { storageError = "Could not read captures. Raw files have been preserved." }
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
        // Every queued item is already durable on disk and resumes next launch.
    }

    private func publish(_ index: RawCaptureIndex) {
        guard index.day == selectedDay else { return }
        if let position = records.firstIndex(where: { $0.id == index.id }) { records[position] = index }
        else { records.append(index) }
    }

    private func failStorage() {
        storageError = "Recording stopped. Check disk space and file access, then restart the app. Raw files are preserved."
        enabled = false
        UserDefaults.standard.set(false, forKey: "journal_enabled")
        configureTimer()
    }

    private func capture() {
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
                let index = try await store.save(record, png: png)
                publish(index)
                ocrQueue.append(index); runOCR()
                status = "Saving a screenshot every \(Int(captureInterval)) seconds"
            } catch {
                // Capture API failures do not destroy prior captures or their processing queue.
                status = "Capture failed; retrying at the next interval"
                if (error as NSError).domain == NSCocoaErrorDomain { failStorage() }
            }
        }
    }

    private func runOCR() {
        guard ocrTask == nil, !ocrQueue.isEmpty else { return }
        let index = ocrQueue.removeFirst()
        ocrTask = Task {
            do {
                let folder = try await store.folder(index)
                let ocr: RawOCR = await Task.detached(priority: .utility) {
                    do {
                        guard let source = CGImageSourceCreateWithURL(folder.appendingPathComponent("screenshot.png") as CFURL, nil),
                              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
                        return try JournalCapture.literalOCR(image: image)
                    } catch { return RawOCR(status: "failed", error: "Apple Vision could not recognize this capture.") }
                }.value
                let updated = try await store.saveOCR(ocr, index: index)
                publish(updated)
                inferenceQueue.append(updated); runInference()
            } catch { failStorage() }
            ocrTask = nil
            if storageError == nil { runOCR() }
        }
    }

    private func runInference() {
        guard inferenceTask == nil, !inferenceQueue.isEmpty else { return }
        let index = inferenceQueue.removeFirst()
        modelStatus = "Describing captures locally · \(inferenceQueue.count + 1) queued"
        inferenceTask = Task {
            do {
                let record = try await store.read(index)
                let inference: RawInference
                do {
                    // Raw files retain ALL text; only the model input is bounded.
                    let evidence = "Window: \(record.windowTitle)\n" + String(record.ocr.text.prefix(18000))
                    let result = try await JournalLocalModel.summarize(app: record.appName, observations: evidence)
                    inference = RawInference(status: "complete", completedAt: Date(), summary: result.summary, category: result.category, confidence: result.confidence,
                                             rawOCRCharacterCount: record.ocr.text.count, modelInputTruncated: record.ocr.text.count > 18000)
                } catch {
                    inference = RawInference(status: "failed", completedAt: Date(), error: "Local model unavailable or response invalid. Raw screenshot and OCR retained.",
                                             rawOCRCharacterCount: record.ocr.text.count, modelInputTruncated: record.ocr.text.count > 18000)
                }
                let updated = try await store.saveInference(inference, index: index)
                publish(updated)
            } catch { failStorage() }
            inferenceTask = nil
            modelStatus = "Local OCR and Qwen 2.5 · 3B"
            if storageError == nil { runInference() }
        }
    }

    func revealCapture(_ index: RawCaptureIndex) {
        Task {
            if let folder = try? await store.folder(index) { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        }
    }

    func revealStorage() { NSWorkspace.shared.open(root) }

    func export(day: Date?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Export here"
        panel.message = "Choose a folder for the raw screenshots, OCR, metadata and JSONL manifest."
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                self.exporting = true
                defer { self.exporting = false }
                do {
                    let indices = try await self.store.list(day: day.map { RawCaptureJSON.day($0) })
                    guard !indices.isEmpty else { self.status = "No captures to export"; return }
                    var folders: [URL] = []
                    for index in indices { folders.append(try await self.store.folder(index)) }
                    let exported = try await Task.detached(priority: .utility) { try RawCaptureStore.export(folders: folders, destination: destination) }.value
                    self.status = "Exported \(indices.count) raw captures"
                    NSWorkspace.shared.activateFileViewerSelecting([exported])
                } catch { self.status = "Export failed. Original captures are unchanged." }
            }
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
