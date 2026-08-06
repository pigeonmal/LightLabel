import Foundation
import XCTest

@testable import LightLabel

enum TestSupport {
    static var fixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    static func fixture(_ name: String) throws -> String {
        try String(contentsOf: fixturesURL.appendingPathComponent(name), encoding: .utf8)
    }

    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LightLabelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func writeFixture(_ name: String, to url: URL) throws {
        try fixture(name).write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeTinyPNG(to url: URL) throws {
        let encoded = try fixture("tiny.png.base64")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        try data.write(to: url, options: .atomic)
    }

    static func removeTemporaryDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
