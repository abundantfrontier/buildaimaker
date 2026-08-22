import SwiftUI
import BAMCore
import BAMModelCatalog
import BAMResourcesUI

/// Model Source Connector UI: popular hubs, search, custom URL, install into models/base.
struct ModelBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ModelBrowserViewModel()
    var onInstalled: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 780, minHeight: 560)
        .background(BAMColors.detailBackground)
        .onAppear {
            model.refreshMemoryProbe()
            // Live HF list on open — not the tiny curated shortlist.
            model.search(reset: true)
        }
        .onChange(of: model.statusMessage) { _, new in
            if let new, new.contains("Installed at") || new.contains("Reinstalled at") {
                onInstalled?()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("Model Source Connector", systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)
            if model.resultsAreLive {
                Text("Live HF")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.2), in: Capsule())
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private var content: some View {
        HSplitView {
            sourceSidebar
                .frame(minWidth: 200, idealWidth: 230, maxWidth: 280)
            resultsPane
                .frame(minWidth: 480)
        }
    }

    private var sourceSidebar: some View {
        List {
            Section("Locations") {
                ForEach(ModelSourceLocation.allCases) { loc in
                    Button {
                        model.location = loc
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: loc.systemImage)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc.title)
                                    .font(.body.weight(model.location == loc ? .semibold : .regular))
                                    .foregroundStyle(.primary)
                                Text(loc.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(BAMColors.secondaryLabel)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            if model.location == loc {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Auth (optional)") {
                Text("Private or gated models need a Hugging Face token.")
                    .font(.caption2)
                    .foregroundStyle(BAMColors.secondaryLabel)
                SecureField("hf_… token", text: $model.hfToken)
                    .textFieldStyle(.roundedBorder)
                Button("Save token to Keychain") {
                    model.saveTokenFromField()
                }
                .disabled(model.hfToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.hasStoredToken {
                    Label("Token on file", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Section("Tips") {
                Text("Leave search empty to list top downloads (up to 100 per page). Use Load more for the next page. Popular picks is a tiny offline shortlist only.")
                    .font(.caption2)
                    .foregroundStyle(BAMColors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .listStyle(.sidebar)
    }

    private var resultsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            memoryFilterBar
            Divider()
            searchBar
            Divider()
            if let err = model.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
            }
            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            List {
                if model.location == .custom {
                    Section("Custom location") {
                        Text("Paste a Hugging Face repo id or full model page URL.")
                            .font(.caption)
                            .foregroundStyle(BAMColors.secondaryLabel)
                        TextField("mlx-community/Qwen2.5-1.5B-Instruct-4bit", text: $model.customURL)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.search(reset: true) }
                        HStack {
                            Button("Resolve") { model.search(reset: true) }
                            Button("Download") { model.installCustom() }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.isInstalling)
                        }
                    }
                }

                Section {
                    if model.isSearching && model.results.isEmpty {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Loading models from Hugging Face…")
                                .foregroundStyle(BAMColors.secondaryLabel)
                        }
                    } else if model.results.isEmpty {
                        Text("No listings. Clear the search box and press Search, or try another location.")
                            .foregroundStyle(BAMColors.secondaryLabel)
                    } else {
                        ForEach(model.results) { listing in
                            listingRow(listing)
                        }
                        if model.hasMore {
                            HStack {
                                Spacer()
                                Button {
                                    model.loadMore()
                                } label: {
                                    if model.isLoadingMore {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Label("Load more models", systemImage: "arrow.down.circle")
                                    }
                                }
                                .disabled(model.isLoadingMore || model.isSearching)
                                Spacer()
                            }
                            .padding(.vertical, 8)
                        }
                    }
                } header: {
                    Text(model.location == .custom ? "Resolved" : "Results (\(model.results.count))")
                }
            }
            .listStyle(.inset)
        }
    }

    private var memoryFilterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "memorychip")
                    .foregroundStyle(Color.accentColor)
                Text("This Mac: \(model.availableUnifiedGB) GB unified memory")
                    .font(.callout.weight(.semibold))
                Text("(scanned)")
                    .font(.caption2)
                    .foregroundStyle(BAMColors.tertiaryLabel)
                Spacer()
                Button {
                    model.refreshMemoryProbe()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Re-read physical memory")
            }

            HStack(spacing: 8) {
                Text("Size filter")
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                Picker("Memory filter", selection: $model.memoryFilter) {
                    ForEach(ModelMemoryFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 180)
                .help(model.memoryFilter.help)

                Toggle("Prefer 4-bit", isOn: $model.preferFourBit)
                    .toggleStyle(.switch)
                    .help("Hide 8/16-bit variants when quant is known (saves RAM)")

                if model.hiddenByFilterCount > 0 {
                    Text("\(model.hiddenByFilterCount) hidden")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.06))
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            if model.location.supportsSearch {
                TextField("Search (empty = top downloads)…", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.search(reset: true) }
                Toggle("Live HF", isOn: $model.useLiveSearch)
                    .toggleStyle(.switch)
                    .help("Off = curated offline picks only")
                Button {
                    model.search(reset: true)
                } label: {
                    if model.isSearching {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isSearching || model.isInstalling)
            }
            Button("Popular picks") {
                model.showPopularPicks()
            }
            .help("Tiny offline shortlist only")
            Spacer()
        }
        .padding(12)
    }

    private func listingRow(_ listing: ModelRemoteListing) -> some View {
        let hints = listing.sizeHints
        let fit = model.fitLabel(for: listing)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(listing.name)
                    .font(.body.weight(.semibold))
                Text(listing.sourceKey)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(listing.displayAuthor)
                        .font(.caption2)
                    Text(hints.shortLabel)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(BAMColors.separator.opacity(0.35), in: Capsule())
                    Text(fit.text)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background((fit.ok ? Color.green : Color.orange).opacity(0.2), in: Capsule())
                        .foregroundStyle(fit.ok ? .green : .orange)
                    if let d = listing.downloads {
                        Text("↓ \(Self.compact(d))")
                            .font(.caption2)
                    }
                }
                .foregroundStyle(BAMColors.tertiaryLabel)
            }
            Spacer()
            if model.installingSourceKey == listing.sourceKey {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Install") {
                    model.install(listing)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isInstalling)
                .guideHighlight("models.install")
                .help("Download into models/base (network; multi-GB)")
            }
            if let page = listing.pageURL, let url = URL(string: page) {
                Link(destination: url) {
                    Image(systemName: "safari")
                }
                .help("Open on Hugging Face")
            }
        }
        .padding(.vertical, 4)
        .opacity(fit.ok ? 1 : 0.85)
    }

    private var footer: some View {
        HStack {
            Text(
                "Live search lists up to 100 Hugging Face models per page (sorted by downloads). "
                    + "Empty search = widest catalog for that location. Downloads go to Application Support …/models/base."
            )
            .font(.caption2)
            .foregroundStyle(BAMColors.tertiaryLabel)
            Spacer()
            if model.isInstalling {
                ProgressView()
                    .controlSize(.small)
                Text("Installing…")
                    .font(.caption)
            }
        }
        .padding(12)
    }

    private static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
