import Foundation

enum RawCaptureStoreTests {
    static func run() async {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let root = temporary.appendingPathComponent("raw")
            let store = RawCaptureStore(root: root)
            let stamp = Date(timeIntervalSince1970: 1_789_000_000)
            let record = RawObservation(id: UUID(), requestedAt: stamp, capturedAt: stamp,
                localTimestamp: "2026-09-08T09:32:00.000+10:00", timeZoneIdentifier: "Australia/Melbourne",
                utcOffsetSeconds: 36000, intervalSeconds: 7, idleSeconds: 125,
                appName: "Synthetic Editor", bundleIdentifier: "test.synthetic", processID: 123,
                executablePath: "/Applications/Synthetic Editor.app/Contents/MacOS/Editor", windowID: 42,
                windowTitle: "Synthetic notes", windowBounds: RawRect(CGRect(x: 10, y: 20, width: 800, height: 600)),
                imageWidth: 1600, imageHeight: 1200, osVersion: "Synthetic OS", documentURL: "file:///synthetic/notes.txt",
                focusedElementRole: "AXTextArea", frontmostAtCompletion: true)
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5xkAAAAASUVORK5CYII=")!
            let index = try await store.save(record, png: png)
            let folder = try await store.folder(index)
            let pending = try await store.list()
            TestSupport.expectEqual(pending.count, 1)
            TestSupport.expectEqual(pending[0].ocrStatus, "pending")
            let original = try Data(contentsOf: folder.appendingPathComponent("screenshot.png"))
            TestSupport.expectEqual(original, png)
            let literal = "helo   wrld\ncontact: person@example.test\n/Users/synthetic/private.txt\npassword=fictional"
            let ocr = RawOCR(status: "complete", text: literal,
                             lines: [RawOCRLine(text: literal, confidence: 0.1, boundingBox: RawRect(CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)))])
            let updated = try await store.saveOCR(ocr, index: index)
            let restored = try await store.read(updated)
            TestSupport.expectEqual(restored.ocr.text, literal)
            TestSupport.expectEqual(restored.ocr.languageCorrection, false)
            TestSupport.expectEqual(restored.ocr.lines[0].confidence, 0.1)
            TestSupport.expectEqual(restored.documentURL, record.documentURL)
            TestSupport.expectEqual(restored.intervalSeconds, 7)
            let beforeInference = try Data(contentsOf: folder.appendingPathComponent("observation.json"))
            _ = try await store.saveInference(RawInference(status: "failed", error: "Synthetic model failure"), index: updated)
            let afterInference = try Data(contentsOf: folder.appendingPathComponent("observation.json"))
            TestSupport.expectEqual(beforeInference, afterInference)
            let export = try RawCaptureStore.export(folders: [folder], destination: temporary)
            let exportedCapture = export.appendingPathComponent("captures/\(record.id.uuidString)")
            let exportedPNG = try Data(contentsOf: exportedCapture.appendingPathComponent("screenshot.png"))
            let exportedOCR = try String(contentsOf: exportedCapture.appendingPathComponent("ocr.txt"), encoding: .utf8)
            TestSupport.expectEqual(exportedPNG, png)
            TestSupport.expectEqual(exportedOCR, literal)
            let manifest = try String(contentsOf: export.appendingPathComponent("manifest.jsonl"), encoding: .utf8)
            let lines = manifest.split(separator: "\n")
            TestSupport.expectEqual(lines.count, 1)
            let json = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
            TestSupport.expectEqual(json["screenshot"] as? String, "captures/\(record.id.uuidString)/screenshot.png")
            let exportedRecord = json["observation"] as! [String: Any]
            TestSupport.expectEqual((exportedRecord["ocr"] as! [String: Any])["text"] as? String, literal)
            let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
            TestSupport.expectEqual(mode?.intValue, 0o700)
            var malicious = index
            malicious.relativePath = "../../outside"
            var rejected = false
            do { _ = try await store.folder(malicious) } catch { rejected = true }
            TestSupport.expectEqual(rejected, true)
            print("Raw capture save/OCR/export round-trip passed")
        } catch { fatalError("Synthetic raw export test failed: \(error)") }
    }
}
