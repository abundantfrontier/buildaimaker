import XCTest
@testable import BAMCharacterStudio

final class CorpusBuilderTests: XCTestCase {
    func testBuildProducesJSONLAndExamples() {
        let builder = CorpusBuilder()
        let result = builder.build(
            name: "Zorp",
            species: "alien visitor",
            vibe: "polite",
            paste: """
            - Comes from the twin moons
            - Collects interesting questions
            Zorp greets strangers carefully. Home is a quiet station.
            """,
            styleTags: [.formal, .questions],
            riffExtra: 0
        )
        XCTAssertEqual(result.bible.name, "Zorp")
        XCTAssertFalse(result.examples.isEmpty)
        XCTAssertGreaterThan(result.rowCount, 2)
        XCTAssertTrue(result.jsonl.contains("\"role\":\"system\""))
        XCTAssertTrue(result.jsonl.contains("Zorp"))
        // Each non-empty line should parse as JSON
        let lines = result.jsonl.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            let data = Data(line.utf8)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        }
    }

    func testRiffIncreasesCount() {
        let builder = CorpusBuilder()
        let base = builder.build(
            name: "Bolt",
            species: "robot",
            vibe: "curt",
            paste: "I process tasks. I avoid small talk.",
            styleTags: [.robotCurt],
            riffExtra: 0
        )
        let riffed = builder.riff(result: base, extra: 3)
        XCTAssertEqual(riffed.rowCount, base.rowCount + 3)
    }

    func testEmptyNameFallback() {
        let result = CorpusBuilder().build(
            name: "  ",
            species: "",
            vibe: "",
            paste: "",
            styleTags: [],
            riffExtra: 0
        )
        XCTAssertEqual(result.bible.name, "Unnamed")
        XCTAssertFalse(result.examples.isEmpty)
    }
}
