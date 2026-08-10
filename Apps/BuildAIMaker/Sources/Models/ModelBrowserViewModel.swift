import Foundation
import SwiftUI
import BAMCore
import BAMModelCatalog
import BAMRunnersMLX

/// Model Source Connector: search popular hubs + custom URL, download into models/base.
@MainActor
final class ModelBrowserViewModel: ObservableObject {
    @Published var location: ModelSourceLocation = .mlxCommunity {
        didSet {
            if oldValue != location {
                query = location.defaultQuery
                // Auto-refresh listing when switching source.
                if location != .custom {
                    search(reset: true)
                }
            }
        }
    }
    @Published var query: String = ModelSourceLocation.mlxCommunity.defaultQuery
    @Published var customURL: String = ""
    /// Unfiltered hub results (before memory filter).
    @Published private(set) var rawResults: [ModelRemoteListing] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false
    @Published private(set) var isInstalling = false
    @Published var installingSourceKey: String?
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var useLiveSearch: Bool = true
    @Published var hfToken: String = ""
    @Published private(set) var hasStoredToken: Bool = false
    /// True when results came from live HF (vs offline curated).
    @Published private(set) var resultsAreLive: Bool = false
    /// Unified memory (GB) from `ProcessInfo.physicalMemory`.
    @Published private(set) var availableUnifiedGB: Int = 0
    @Published var memoryFilter: ModelMemoryFilter = .fitsThisMac {
        didSet { updateStatusAfterFilter() }
    }
    /// Prefer 4-bit (and similar) quants when size is known.
    @Published var preferFourBit: Bool = true {
        didSet { updateStatusAfterFilter() }
    }

    private let liveSearchClient: HuggingFaceModelSourceSearchClient
    private let staticSearchClient: StaticModelSourceSearchClient
    private let tokenStore: any HFTokenStore
    private let modelsBaseURL: URL
    private var nextSkip: Int = 0
    private let pageSize = 100

    /// Results after memory / quant filters (what the list shows).
    var results: [ModelRemoteListing] {
        filtered(rawResults)
    }

    var hiddenByFilterCount: Int {
        max(0, rawResults.count - results.count)
    }

    init(
        modelsBaseURL: URL = LibraryPaths.modelsBase,
        tokenStore: any HFTokenStore = KeychainHFTokenStore()
    ) {
        self.modelsBaseURL = modelsBaseURL
        self.tokenStore = tokenStore
        self.liveSearchClient = HuggingFaceModelSourceSearchClient()
        self.staticSearchClient = StaticModelSourceSearchClient()
        let gb = HardwareFitGate.probeAvailableUnifiedGB()
        self.availableUnifiedGB = gb
        self.memoryFilter = ModelMemoryFilter.recommended(forAvailableGB: gb)
        loadTokenField()
    }

    func refreshMemoryProbe() {
        availableUnifiedGB = HardwareFitGate.probeAvailableUnifiedGB()
        updateStatusAfterFilter()
    }

    private func loadTokenField() {
        let token = (try? tokenStore.loadToken()) ?? nil
        if let token, !token.isEmpty {
            hasStoredToken = true
            hfToken = ""
        } else {
            hasStoredToken = false
        }
    }

    func saveTokenFromField() {
        errorMessage = nil
        do {
            let trimmed = hfToken.trimmingCharacters(in: .whitespacesAndNewlines)
            try tokenStore.saveToken(trimmed.isEmpty ? nil : trimmed)
            hasStoredToken = !(try tokenStore.loadToken() ?? "").isEmpty
            statusMessage = hasStoredToken ? "HF token saved to Keychain." : "HF token cleared."
            hfToken = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Offline curated shortlist only (explicit button).
    func showPopularPicks() {
        rawResults = ModelSourcePopularPicks.listings.filter { listing in
            switch location {
            case .qwenMLX:
                return listing.sourceKey.localizedCaseInsensitiveContains("qwen")
            case .mlxCommunity, .huggingFaceMLX, .custom:
                return true
            }
        }
        hasMore = false
        nextSkip = 0
        resultsAreLive = false
        errorMessage = nil
        updateStatusAfterFilter()
    }

    private func filtered(_ rows: [ModelRemoteListing]) -> [ModelRemoteListing] {
        rows.filter { listing in
            let hints = listing.sizeHints
            guard memoryFilter.allows(hints: hints, availableUnifiedGB: availableUnifiedGB) else {
                return false
            }
            if preferFourBit, let q = hints.quantBits, q > 5 {
                // Soft prefer: still allow if unknown; hide 8/16-bit when we know size.
                return false
            }
            return true
        }
    }

    private func updateStatusAfterFilter() {
        let shown = results.count
        let raw = rawResults.count
        let hidden = max(0, raw - shown)
        let mem = "\(availableUnifiedGB) GB unified"
        if raw == 0 {
            return
        }
        var msg = "\(shown) shown"
        if hidden > 0 {
            msg += " · \(hidden) hidden by memory filter"
        }
        msg += " · Mac \(mem) · filter: \(memoryFilter.title)"
        if preferFourBit {
            msg += " · prefer ≤5-bit"
        }
        if resultsAreLive {
            msg += " · Live HF"
        }
        statusMessage = msg
    }

    /// Live (or static) search. `reset` clears prior pages; false appends for Load more.
    func search(reset: Bool = true) {
        if location == .custom {
            resolveCustomToResults()
            return
        }

        if reset {
            isSearching = true
            nextSkip = 0
            hasMore = false
        } else {
            isLoadingMore = true
        }
        errorMessage = nil
        statusMessage = useLiveSearch
            ? (reset ? "Searching Hugging Face…" : "Loading more…")
            : "Filtering offline picks…"

        let loc = location
        let q = query
        let live = useLiveSearch
        let token = (try? tokenStore.loadToken()) ?? nil
        let skip = reset ? 0 : nextSkip
        let limit = loc.preferredPageSize

        Task {
            defer {
                isSearching = false
                isLoadingMore = false
            }
            do {
                let client: any ModelSourceSearchClient = live ? liveSearchClient : staticSearchClient
                let page = try await client.search(
                    location: loc,
                    query: q,
                    limit: limit,
                    skip: skip,
                    token: token
                )
                if reset {
                    rawResults = page.listings
                } else {
                    var seen = Set(rawResults.map(\.sourceKey))
                    var merged = rawResults
                    for row in page.listings where !seen.contains(row.sourceKey) {
                        seen.insert(row.sourceKey)
                        merged.append(row)
                    }
                    rawResults = merged
                }
                hasMore = page.hasMore
                nextSkip = skip + page.listings.count
                resultsAreLive = live
                if page.listings.isEmpty && reset {
                    statusMessage = "No models found. Clear the search box or try another location."
                } else {
                    updateStatusAfterFilter()
                }
            } catch {
                if reset {
                    let fallback = try? await staticSearchClient.search(
                        location: loc,
                        query: q,
                        limit: limit,
                        skip: 0,
                        token: nil
                    )
                    rawResults = fallback?.listings ?? ModelSourcePopularPicks.listings
                    hasMore = false
                    nextSkip = 0
                    resultsAreLive = false
                }
                errorMessage = (error as? BAMError)?.errorDescription
                    ?? error.localizedDescription
                statusMessage = "Live search failed — showing offline picks."
                updateStatusAfterFilter()
            }
        }
    }

    func loadMore() {
        guard hasMore, !isSearching, !isLoadingMore else { return }
        search(reset: false)
    }

    private func resolveCustomToResults() {
        errorMessage = nil
        hasMore = false
        resultsAreLive = false
        let raw = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            errorMessage = "Paste a HF repo id (org/name) or https://huggingface.co/… URL."
            rawResults = []
            return
        }
        do {
            let resolved = try ModelSourceURLNormalizer.resolve(raw)
            let listing = ModelRemoteListing(
                sourceKey: resolved.sourceKey,
                name: resolved.sourceKey.split(separator: "/").last.map(String.init) ?? resolved.sourceKey,
                author: resolved.sourceKey.split(separator: "/").first.map(String.init),
                tags: resolved.isHuggingFace ? ["huggingface"] : ["custom"],
                pageURL: resolved.pageURL,
                sourceLocation: .custom
            )
            rawResults = [listing]
            statusMessage = resolved.isHuggingFace
                ? "Ready to download \(resolved.sourceKey) from Hugging Face."
                : "Parsed custom location (HF download required for install)."
            updateStatusAfterFilter()
        } catch {
            rawResults = []
            errorMessage = (error as? BAMError)?.errorDescription ?? error.localizedDescription
        }
    }

    func install(_ listing: ModelRemoteListing) {
        guard !isInstalling else { return }
        isInstalling = true
        installingSourceKey = listing.sourceKey
        errorMessage = nil
        statusMessage = "Downloading \(listing.sourceKey)… (multi-GB models can take a while)"

        let tokenStore = self.tokenStore
        let modelsBase = modelsBaseURL

        Task {
            defer {
                isInstalling = false
                installingSourceKey = nil
            }
            do {
                let service = ModelInstallService(
                    modelsBaseURL: modelsBase,
                    hfHubDownloadEnabled: true,
                    tokenStore: tokenStore,
                    hubClient: URLSessionHFHubClient()
                )
                let result = try await service.installFromRemoteListing(listing)
                statusMessage = result.alreadyPresent
                    ? "Reinstalled at \(result.modelRecord.localPath)"
                    : "Installed at \(result.modelRecord.localPath)"
                OnboardingStore().markCompleted(.installFixture)
            } catch {
                errorMessage = (error as? BAMError)?.errorDescription ?? error.localizedDescription
                statusMessage = "Download failed."
            }
        }
    }

    func installCustom() {
        resolveCustomToResults()
        guard let first = rawResults.first else { return }
        install(first)
    }

    /// Fit badge for a listing relative to this Mac.
    func fitLabel(for listing: ModelRemoteListing) -> (text: String, ok: Bool) {
        let hints = listing.sizeHints
        guard let need = hints.estimatedInferenceGB else {
            return ("size ?", true)
        }
        let usable = Double(max(0, availableUnifiedGB - 4))
        if need <= usable * 0.5 {
            return (String(format: "OK ~%.1f GB", need), true)
        }
        if need <= usable {
            return (String(format: "Tight ~%.1f GB", need), true)
        }
        return (String(format: "Heavy ~%.1f GB", need), false)
    }
}
