import Foundation

struct RawRect: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    init(_ rect: CGRect) { x = rect.origin.x; y = rect.origin.y; width = rect.width; height = rect.height }
}

struct RawOCRLine: Codable {
    var text: String
    var confidence: Float
    var boundingBox: RawRect
}

struct RawOCR: Codable {
    var engine = "Apple Vision"
    var languageCorrection = false
    var status = "pending"
    var text = ""
    var lines: [RawOCRLine] = []
    var error: String?
}

struct RawObservation: Codable, Identifiable {
    var schemaVersion = 1
    var id: UUID
    var requestedAt: Date
    var capturedAt: Date
    var localTimestamp: String
    var timeZoneIdentifier: String
    var utcOffsetSeconds: Int
    var intervalSeconds: Double
    var idleSeconds: Double?
    var appName: String
    var bundleIdentifier: String?
    var processID: Int32
    var executablePath: String?
    var windowID: UInt32
    var windowTitle: String
    var windowBounds: RawRect
    var imageWidth: Int
    var imageHeight: Int
    var osVersion: String
    var documentURL: String?
    var focusedElementRole: String?
    var frontmostAtCompletion: Bool
    var ocr = RawOCR()
}

struct RawInference: Codable {
    var model = JournalLocalModel.model
    var status: String
    var completedAt: Date?
    var summary: String?
    var category: String?
    var confidence: String?
    var error: String?
    var rawOCRCharacterCount: Int?
    var modelInputCharacterLimit = 18000
    var modelInputTruncated: Bool?
}

struct RawCaptureIndex: Codable, Identifiable {
    var id: UUID
    var capturedAt: Date
    var day: String
    var appName: String
    var relativePath: String
    var summary = ""
    var ocrStatus = "pending"
    var inferenceStatus = "pending"
}

enum RawCaptureJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestamp(date, timeZone: TimeZone(secondsFromGMT: 0)!))
        }
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: value) else { throw CocoaError(.coderReadCorrupt) }
            return date
        }
        return decoder
    }
    static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try encoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

actor RawCaptureStore {
    let root: URL
    init(root: URL) { self.root = root }

    func list(day: String? = nil) throws -> [RawCaptureIndex] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let days = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        var result: [RawCaptureIndex] = []
        for directory in days where day == nil || directory.lastPathComponent == day {
            for folder in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                let index = try RawCaptureJSON.decoder().decode(RawCaptureIndex.self, from: Data(contentsOf: folder.appendingPathComponent("index.json")))
                result.append(index)
            }
        }
        return result.sorted { $0.capturedAt < $1.capturedAt }
    }

    func save(_ record: RawObservation, png: Data) throws -> RawCaptureIndex {
        let day = RawCaptureJSON.day(record.capturedAt)
        let directory = root.appendingPathComponent(day)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        if let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage,
           available < max(512 * 1024 * 1024, Int64(png.count) * 2) { throw CocoaError(.fileWriteOutOfSpace) }
        let staging = directory.appendingPathComponent("." + record.id.uuidString)
        let final = directory.appendingPathComponent(record.id.uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        guard FileManager.default.createFile(atPath: staging.appendingPathComponent("screenshot.png").path, contents: png, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        let index = RawCaptureIndex(id: record.id, capturedAt: record.capturedAt, day: day, appName: record.appName, relativePath: "\(day)/\(record.id.uuidString)")
        try RawCaptureJSON.write(record, to: staging.appendingPathComponent("observation.json"))
        try RawCaptureJSON.write(RawInference(status: "pending"), to: staging.appendingPathComponent("inference.json"))
        try RawCaptureJSON.write(index, to: staging.appendingPathComponent("index.json"))
        try FileManager.default.moveItem(at: staging, to: final)
        return index
    }

    func folder(_ index: RawCaptureIndex) throws -> URL {
        // Never trust a path read from an editable local JSON file.
        guard index.relativePath == "\(index.day)/\(index.id.uuidString)",
              index.day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { throw CocoaError(.fileReadInvalidFileName) }
        return root.appendingPathComponent(index.relativePath)
    }

    func read(_ index: RawCaptureIndex) throws -> RawObservation {
        try RawCaptureJSON.decoder().decode(RawObservation.self, from: Data(contentsOf: folder(index).appendingPathComponent("observation.json")))
    }

    func saveOCR(_ ocr: RawOCR, index: RawCaptureIndex) throws -> RawCaptureIndex {
        var record = try read(index)
        record.ocr = ocr
        let directory = try folder(index)
        try RawCaptureJSON.write(record, to: directory.appendingPathComponent("observation.json"))
        try Data(ocr.text.utf8).write(to: directory.appendingPathComponent("ocr.txt"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("ocr.txt").path)
        var updated = index
        updated.ocrStatus = ocr.status
        try RawCaptureJSON.write(updated, to: directory.appendingPathComponent("index.json"))
        return updated
    }

    func saveInference(_ inference: RawInference, index: RawCaptureIndex) throws -> RawCaptureIndex {
        let directory = try folder(index)
        try RawCaptureJSON.write(inference, to: directory.appendingPathComponent("inference.json"))
        var updated = index
        updated.inferenceStatus = inference.status
        updated.summary = inference.summary ?? ""
        try RawCaptureJSON.write(updated, to: directory.appendingPathComponent("index.json"))
        return updated
    }

    // Copies fixed capture IDs, not a moving directory tree. PNGs never change;
    // JSON files are atomic snapshots, and inference remains separate from raw OCR.
    static func export(folders: [URL], destination: URL) throws -> URL {
        let staging = destination.appendingPathComponent(".git-for-work-export-" + UUID().uuidString)
        let final = destination.appendingPathComponent("git-for-work-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let captures = staging.appendingPathComponent("captures")
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let manifest = staging.appendingPathComponent("manifest.jsonl")
        guard FileManager.default.createFile(atPath: manifest.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: manifest)
        defer { try? handle.close() }
        for source in folders {
            let recordData = try Data(contentsOf: source.appendingPathComponent("observation.json"))
            let record = try RawCaptureJSON.decoder().decode(RawObservation.self, from: recordData)
            let inferenceData = try Data(contentsOf: source.appendingPathComponent("inference.json"))
            let target = captures.appendingPathComponent(record.id.uuidString)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: source.appendingPathComponent("screenshot.png"), to: target.appendingPathComponent("screenshot.png"))
            try recordData.write(to: target.appendingPathComponent("observation.json"))
            try inferenceData.write(to: target.appendingPathComponent("inference.json"))
            try Data(record.ocr.text.utf8).write(to: target.appendingPathComponent("ocr.txt"))
            let row: [String: Any] = ["observation": try JSONSerialization.jsonObject(with: recordData),
                                     "inference": try JSONSerialization.jsonObject(with: inferenceData),
                                     "screenshot": "captures/\(record.id.uuidString)/screenshot.png",
                                     "ocr_text": "captures/\(record.id.uuidString)/ocr.txt"]
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: .sortedKeys) + Data([10]))
        }
        try Data("""
        Git for Work (Den) raw export (schema 1)
        manifest.jsonl: one JSON object per capture, oldest first.
        captures/<id>/screenshot.png: original lossless active-window capture.
        observation.json: timestamps, local timezone/offset, app/window/system metadata and literal Apple Vision OCR.
        ocr.txt: literal OCR text, without redaction, language correction or summarization.
        OCR bounding boxes are normalized 0–1 coordinates with a bottom-left origin.
        inference.json: separate local-model interpretation; not ground truth.
        Pending/failed OCR or inference is explicitly marked; screenshots remain exportable.
        Timestamps are ISO 8601. No screenshots or OCR are reconstructed from summaries.
        This export contains the captures selected when Export was clicked. Later captures are not included.
        Raw material can contain private text and credentials visible on screen. Nothing was uploaded.
        """.utf8).write(to: staging.appendingPathComponent("README.txt"))
        try FileManager.default.moveItem(at: staging, to: final)
        return final
    }
}
