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
    // Optional so older text-only inference exports still decode.
    var inputMode: String?
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

    func save(_ record: RawObservation) throws -> RawCaptureIndex {
        let day = RawCaptureJSON.day(record.capturedAt)
        let directory = root.appendingPathComponent(day)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        if let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage,
           available < 512 * 1024 * 1024 { throw CocoaError(.fileWriteOutOfSpace) }
        let staging = directory.appendingPathComponent("." + record.id.uuidString)
        let final = directory.appendingPathComponent(record.id.uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let index = RawCaptureIndex(id: record.id, capturedAt: record.capturedAt, day: day, appName: record.appName, relativePath: "\(day)/\(record.id.uuidString)", ocrStatus: record.ocr.status)
        try RawCaptureJSON.write(record, to: staging.appendingPathComponent("observation.json"))
        guard FileManager.default.createFile(atPath: staging.appendingPathComponent("ocr.txt").path, contents: Data(record.ocr.text.utf8), attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
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

    // Migration removes only app-owned screenshot files; all text remains intact.
    func removePersistedScreenshots() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return }
        for case let file as URL in files where file.lastPathComponent == "screenshot.png" {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    func rawText(day: Date, timeZone: TimeZone = .current) throws -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let indices = try list().filter { calendar.isDate($0.capturedAt, inSameDayAs: day) }
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = timeZone
        date.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.locale = .current
        time.timeZone = timeZone
        time.dateFormat = "h:mm:ss a zzz (XXXXX)"
        var blocks = ["Git for Work (Den) — \(date.string(from: day)) — \(timeZone.identifier)\n\(indices.count) screenshots taken; images are not retained."]
        for index in indices {
            let record = try read(index)
            let inference = try JSONSerialization.jsonObject(with: Data(contentsOf: folder(index).appendingPathComponent("inference.json")))
            let observation = try JSONSerialization.jsonObject(with: RawCaptureJSON.encoder().encode(record))
            let json = try JSONSerialization.data(withJSONObject: ["observation": observation, "inference": inference], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            blocks.append("\(time.string(from: record.capturedAt)) — \(record.appName)\nWindow: \(record.windowTitle)\n\nRAW OCR:\n\(record.ocr.text)\n\nRAW METADATA + INFERENCE:\n\(String(decoding: json, as: UTF8.self))")
        }
        return blocks.joined(separator: "\n\n---\n\n")
    }
}
