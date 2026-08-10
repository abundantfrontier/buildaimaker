import XCTest
import BAMCore
@testable import BAMModelCatalog

final class ModelSourceConnectorTests: XCTestCase {
    func testNormalizeBareRepoId() throws {
        let r = try ModelSourceURLNormalizer.resolve("mlx-community/Qwen2.5-1.5B-Instruct-4bit")
        XCTAssertTrue(r.isHuggingFace)
        XCTAssertEqual(r.sourceKey, "mlx-community/Qwen2.5-1.5B-Instruct-4bit")
        XCTAssertEqual(r.pageURL, "https://huggingface.co/mlx-community/Qwen2.5-1.5B-Instruct-4bit")
    }

    func testNormalizeHuggingFaceURL() throws {
        let r = try ModelSourceURLNormalizer.resolve(
            "https://huggingface.co/mlx-community/Qwen2.5-0.5B-Instruct-4bit/tree/main"
        )
        XCTAssertTrue(r.isHuggingFace)
        XCTAssertEqual(r.sourceKey, "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
    }

    func testNormalizeHfCoShortHost() throws {
        let r = try ModelSourceURLNormalizer.resolve("https://hf.co/org/model-name")
        XCTAssertEqual(r.sourceKey, "org/model-name")
        XCTAssertTrue(r.isHuggingFace)
    }

    func testNormalizeEmptyThrows() {
        XCTAssertThrowsError(try ModelSourceURLNormalizer.resolve("  ")) { error in
            XCTAssertEqual((error as? BAMError)?.code, .schemaInvalid)
        }
    }

    func testNormalizeCustomHTTPS() throws {
        let r = try ModelSourceURLNormalizer.resolve("https://example.com/weights/my-model/")
        XCTAssertFalse(r.isHuggingFace)
        XCTAssertNotNil(r.customResolveBaseURL)
        XCTAssertFalse(r.sourceKey.isEmpty)
    }

    func testDecodeHFSearchJSON() throws {
        let json = """
        [
          {
            "id": "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            "modelId": "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            "downloads": 12000,
            "likes": 42,
            "tags": ["mlx", "text-generation"],
            "pipeline_tag": "text-generation"
          }
        ]
        """.data(using: .utf8)!
        let rows = try HuggingFaceModelSourceSearchClient.decodeListings(
            data: json,
            location: .mlxCommunity
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].sourceKey, "mlx-community/Qwen2.5-1.5B-Instruct-4bit")
        XCTAssertEqual(rows[0].downloads, 12000)
        XCTAssertEqual(rows[0].author, "mlx-community")
        XCTAssertTrue(rows[0].tags.contains("mlx"))
    }

    func testStaticSearchFiltersQwen() async throws {
        let client = StaticModelSourceSearchClient()
        let page = try await client.search(
            location: .qwenMLX,
            query: "",
            limit: 20,
            skip: 0,
            token: nil
        )
        XCTAssertFalse(page.listings.isEmpty)
        XCTAssertTrue(page.listings.allSatisfy { $0.sourceKey.localizedCaseInsensitiveContains("qwen") })
    }

    func testStaticSearchQuery() async throws {
        let client = StaticModelSourceSearchClient()
        let page = try await client.search(
            location: .mlxCommunity,
            query: "Phi",
            limit: 10,
            skip: 0,
            token: nil
        )
        XCTAssertEqual(page.listings.count, 1)
        XCTAssertTrue(page.listings[0].sourceKey.contains("Phi"))
    }

    func testStaticSearchPagination() async throws {
        let client = StaticModelSourceSearchClient()
        let first = try await client.search(
            location: .huggingFaceMLX,
            query: "",
            limit: 2,
            skip: 0,
            token: nil
        )
        XCTAssertEqual(first.listings.count, 2)
        XCTAssertTrue(first.hasMore)
        let second = try await client.search(
            location: .huggingFaceMLX,
            query: "",
            limit: 2,
            skip: 2,
            token: nil
        )
        XCTAssertFalse(second.listings.isEmpty)
        XCTAssertNotEqual(first.listings.first?.sourceKey, second.listings.first?.sourceKey)
    }

    func testPopularPicksNonEmpty() {
        XCTAssertGreaterThanOrEqual(ModelSourcePopularPicks.listings.count, 3)
    }

    func testInstallDirectoryNameForRemote() {
        XCTAssertEqual(
            ModelInstallService.installDirectoryName(forSourceKey: "mlx-community/Qwen2.5-1.5B-Instruct-4bit"),
            "mlx-community--Qwen2.5-1.5B-Instruct-4bit"
        )
    }

    // MARK: - Memory / size hints

    func testParseParamAndQuantFromName() {
        let hints = ModelSizeEstimator.estimate(
            sourceKey: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            name: "Qwen2.5 1.5B Instruct"
        )
        XCTAssertEqual(hints.paramCountB ?? -1, 1.5, accuracy: 0.01)
        XCTAssertEqual(hints.quantBits, 4)
        XCTAssertNotNil(hints.estimatedInferenceGB)
        XCTAssertLessThan(hints.estimatedInferenceGB!, 4)
    }

    func testParse7B8bit() {
        let hints = ModelSizeEstimator.estimate(
            sourceKey: "mlx-community/Qwen2.5-7B-Instruct-8bit"
        )
        XCTAssertEqual(hints.paramCountB ?? -1, 7, accuracy: 0.01)
        XCTAssertEqual(hints.quantBits, 8)
        XCTAssertGreaterThan(hints.estimatedInferenceGB ?? 0, 5)
    }

    func testMemoryFilterFitsThisMac() {
        let small = ModelSizeEstimator.estimate(sourceKey: "org/Qwen2.5-0.5B-Instruct-4bit")
        let huge = ModelSizeEstimator.estimate(sourceKey: "org/Llama-3.3-70B-Instruct-4bit")
        XCTAssertTrue(ModelMemoryFilter.fitsThisMac.allows(hints: small, availableUnifiedGB: 16))
        XCTAssertFalse(ModelMemoryFilter.fitsThisMac.allows(hints: huge, availableUnifiedGB: 16))
        XCTAssertTrue(ModelMemoryFilter.showAll.allows(hints: huge, availableUnifiedGB: 16))
        XCTAssertTrue(ModelMemoryFilter.upTo3B.allows(hints: small, availableUnifiedGB: 8))
        XCTAssertFalse(ModelMemoryFilter.upTo3B.allows(hints: huge, availableUnifiedGB: 64))
    }

    func testRecommendedFilterByMacRAM() {
        XCTAssertEqual(ModelMemoryFilter.recommended(forAvailableGB: 8), .upTo1B)
        XCTAssertEqual(ModelMemoryFilter.recommended(forAvailableGB: 16), .upTo3B)
        XCTAssertEqual(ModelMemoryFilter.recommended(forAvailableGB: 32), .fitsThisMac)
    }
}
