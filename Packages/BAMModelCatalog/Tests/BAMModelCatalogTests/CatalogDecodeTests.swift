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
}
