import XCTest
import ZIPFoundation
@testable import Strand

final class FileExportZipTests: XCTestCase {

    func testZipDataRoundTripsTwoEntries() throws {
        let entries = [
            FileExport.BundleEntry(name: "report.txt", data: Data("hello report".utf8)),
            FileExport.BundleEntry(name: "meta.json", data: Data("{\"schema\":1}".utf8)),
        ]
        let zipURL = try XCTUnwrap(FileExport.zipData(entries: entries, baseName: "test-bundle"))
        addTeardownBlock { try? FileManager.default.removeItem(at: zipURL) }

        // The file exists and is non-empty.
        XCTAssertTrue(FileManager.default.fileExists(atPath: zipURL.path))
        let size = (try FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0)

        // Read it back: both entries present with the right bytes.
        let archive = try Archive(url: zipURL, accessMode: .read)
        let report = try XCTUnwrap(archive["report.txt"])
        var out = Data()
        _ = try archive.extract(report) { out.append($0) }
        XCTAssertEqual(String(data: out, encoding: .utf8), "hello report")
        XCTAssertNotNil(archive["meta.json"])
    }

    func testZipDataEmptyEntriesReturnsNil() {
        XCTAssertNil(FileExport.zipData(entries: [], baseName: "empty"))
    }
}
