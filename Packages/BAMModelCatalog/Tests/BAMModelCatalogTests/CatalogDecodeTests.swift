import XCTest
import BAMCore
@testable import BAMModelCatalog

final class CatalogDecodeTests: XCTestCase {
    func testBundledCatalogDecodesQwen25Entries() throws {
        let catalog = try ModelCatalog.loadBundled()

        XCTAssertEqual(catalog.document.schemaVersion, 1)
        XCTAssertEqual(catalog.entries.count, 3)

        let sourceKeys = catalog.entries.map(\.sourceKey)
        XCTAssertEqual(
            sourceKeys,
            [
                "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
                "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
                "mlx-community/Qwen2.5-3B-Instruct-4bit",
            ]
        )

        for entry in catalog.entries {
            XCTAssertEqual(entry.archFamily, "qwen2.5")
            XCTAssertEqual(entry.quantBits, 4)
            XCTAssertEqual(entry.chatTemplateId, "qwen2.5-instruct")
            XCTAssertEqual(entry.license, "Apache-2.0")
            XCTAssertEqual(entry.format, "mlx")
            XCTAssertFalse(entry.license.isEmpty, "license field required")
            XCTAssertGreaterThan(entry.paramCountB, 0)
            XCTAssertGreaterThanOrEqual(entry.minRamGB, 8)
        }

        let mid = try XCTUnwrap(catalog.entry(sourceKey: "mlx-community/Qwen2.5-1.5B-Instruct-4bit"))
        XCTAssertEqual(mid.paramCountB, 1.5)
        XCTAssertEqual(mid.name, "Qwen2.5 Instruct 1.5B")

        let family = catalog.entries(archFamily: "qwen2.5")
        XCTAssertEqual(family.count, 3)
    }

    func testDecodeFromDataRoundTrip() throws {
        let json = """
        {
          "schemaVersion": 1,
          "models": [
            {
              "sourceKey": "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
              "name": "Qwen2.5 Instruct 0.5B",
              "archFamily": "qwen2.5",
              "paramCountB": 0.5,
              "quantBits": 4,
              "minRamGB": 8,
              "chatTemplateId": "qwen2.5-instruct",
              "license": "Apache-2.0",
              "format": "mlx"
            }
          ]
        }
        """.data(using: .utf8)!

        let catalog = try ModelCatalog.decode(json)
        XCTAssertEqual(catalog.entries.count, 1)
        XCTAssertEqual(catalog.entries[0].sourceKey, "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
        XCTAssertEqual(catalog.entries[0].license, "Apache-2.0")
    }

    func testUnsupportedSchemaVersionThrows() {
        let json = """
        {"schemaVersion": 99, "models": []}
        """.data(using: .utf8)!

        XCTAssertThrowsError(try ModelCatalog.decode(json)) { error in
            let bam = error as? BAMError
            XCTAssertEqual(bam?.code, .schemaInvalid)
        }
    }

    func testMalformedJSONThrowsSchemaInvalid() {
        let json = Data("not-json".utf8)
        XCTAssertThrowsError(try ModelCatalog.decode(json)) { error in
            let bam = error as? BAMError
            XCTAssertEqual(bam?.code, .schemaInvalid)
        }
    }

    func testEmptyLicenseRejected() {
        let json = """
        {
          "schemaVersion": 1,
          "models": [
            {
              "sourceKey": "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
              "name": "Qwen2.5 Instruct 0.5B",
              "archFamily": "qwen2.5",
              "paramCountB": 0.5,
              "quantBits": 4,
              "minRamGB": 8,
              "chatTemplateId": "qwen2.5-instruct",
              "license": "   ",
              "format": "mlx"
            }
          ]
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try ModelCatalog.decode(json)) { error in
            let bam = error as? BAMError
            XCTAssertEqual(bam?.code, .schemaInvalid)
            XCTAssertTrue(bam?.message?.contains("license") == true)
        }
    }

    func testEmptySourceKeyRejected() {
        let json = """
        {
          "schemaVersion": 1,
          "models": [
            {
              "sourceKey": "",
              "name": "Broken",
              "archFamily": "qwen2.5",
              "paramCountB": 0.5,
              "quantBits": 4,
              "minRamGB": 8,
              "chatTemplateId": "qwen2.5-instruct",
              "license": "Apache-2.0",
              "format": "mlx"
            }
          ]
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try ModelCatalog.decode(json)) { error in
            let bam = error as? BAMError
            XCTAssertEqual(bam?.code, .schemaInvalid)
            XCTAssertTrue(bam?.message?.contains("sourceKey") == true)
        }
    }

    /// Living list at repo `Catalog/models.json` must match the module resource copy.
    func testLivingCatalogMatchesBundledResource() throws {
        let livingURL = try XCTUnwrap(Self.repoCatalogModelsJSONURL())
        let bundledURL = try XCTUnwrap(ModelCatalog.bundledResourceURL)

        let livingData = try Data(contentsOf: livingURL)
        let bundledData = try Data(contentsOf: bundledURL)

        // Canonicalize via decode so structural drift is caught even if formatting differs.
        let living = try ModelCatalog.decode(livingData)
        let bundled = try ModelCatalog.loadBundled()
        XCTAssertEqual(
            living.document,
            bundled.document,
            "Catalog/models.json must stay in sync with Packages/BAMModelCatalog/.../Resources/models.json"
        )

        // Also require identical file bytes so CI fails on accidental drift.
        XCTAssertEqual(
            livingData,
            bundledData,
            "Catalog/models.json byte content must match bundled Resources/models.json"
        )
    }

    /// Walks up from this test file to find repo-root `Catalog/models.json`.
    private static func repoCatalogModelsJSONURL() -> URL? {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent("Catalog/models.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
