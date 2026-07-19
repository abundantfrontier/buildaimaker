import BAMCore
import Foundation

/// Loads and queries the living model catalog (`Catalog/models.json`).
public struct ModelCatalog: Sendable {
    public let document: CatalogDocument

    public init(document: CatalogDocument) {
        self.document = document
    }

    public var entries: [CatalogEntry] { document.models }

    public func entry(sourceKey: String) -> CatalogEntry? {
        document.models.first { $0.sourceKey == sourceKey }
    }

    public func entries(archFamily: String) -> [CatalogEntry] {
        document.models.filter { $0.archFamily == archFamily }
    }

    /// Offline fixture catalog entry, if present in the living list.
    public var fixtureEntry: CatalogEntry? {
        document.models.first { $0.isFixture || $0.sourceKey == FixtureModel.sourceKey }
    }

    /// Non-fixture (downloadable / production) catalog entries.
    public var nonFixtureEntries: [CatalogEntry] {
        document.models.filter { !$0.isFixture }
    }

    // MARK: - Loading

    /// Decodes a catalog document from raw JSON data.
    ///
    /// Rejects unsupported `schemaVersion` and entries with empty/whitespace
    /// `sourceKey`, `license`, or `chatTemplateId` (`BAM_SCHEMA_INVALID`).
    public static func decode(_ data: Data) throws -> ModelCatalog {
        let decoder = JSONDecoder()
        do {
            let document = try decoder.decode(CatalogDocument.self, from: data)
            guard document.schemaVersion == 1 else {
                throw BAMError(
                    code: .schemaInvalid,
                    message: "Unsupported catalog schemaVersion \(document.schemaVersion)"
                )
            }
            try validateEntries(document.models)
            return ModelCatalog(document: document)
        } catch let error as BAMError {
            throw error
        } catch {
            throw BAMError(
                code: .schemaInvalid,
                message: "Catalog JSON decode failed: \(error.localizedDescription)"
            )
        }
    }

    /// Loads catalog JSON from a file URL.
    public static func load(from url: URL) throws -> ModelCatalog {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BAMError(
                code: .modelNotFound,
                message: "Could not read catalog at \(url.path): \(error.localizedDescription)"
            )
        }
        return try decode(data)
    }

    /// URL of the `models.json` resource embedded in the `BAMModelCatalog` module bundle.
    public static var bundledResourceURL: URL? {
        Bundle.module.url(forResource: "models", withExtension: "json")
    }

    /// Loads the catalog embedded in the `BAMModelCatalog` module bundle.
    public static func loadBundled() throws -> ModelCatalog {
        try loadBundled(from: .module)
    }

    /// Loads catalog JSON from an explicit resource bundle (tests / alternate hosts).
    public static func loadBundled(from bundle: Bundle) throws -> ModelCatalog {
        let url: URL?
        if bundle == .module {
            url = bundledResourceURL
        } else {
            url = bundle.url(forResource: "models", withExtension: "json")
        }
        guard let url else {
            throw BAMError(
                code: .modelNotFound,
                message: "Bundled Catalog/models.json not found in module resources"
            )
        }
        return try load(from: url)
    }

    // MARK: - Validation

    private static func validateEntries(_ entries: [CatalogEntry]) throws {
        for (index, entry) in entries.enumerated() {
            if entry.sourceKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw BAMError(
                    code: .schemaInvalid,
                    message: "Catalog entry[\(index)] has empty sourceKey"
                )
            }
            if entry.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw BAMError(
                    code: .schemaInvalid,
                    message: "Catalog entry[\(index)] has empty license (SPDX required)"
                )
            }
            if entry.chatTemplateId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw BAMError(
                    code: .schemaInvalid,
                    message: "Catalog entry[\(index)] has empty chatTemplateId"
                )
            }
        }
    }
}
