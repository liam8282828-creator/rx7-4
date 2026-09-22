import SwiftUI

struct FilesView: View {
    @Environment(\.appLanguage) private var language
    @State private var apps: [InstalledApp] = []
    @State private var searchText = ""
    @State private var isLoading = false

    private var filteredApps: [InstalledApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AppSearchField(
                    text: $searchText,
                    prompt: language.text("browser.search"),
                    clearLabel: language.text("common.clear")
                )
                Divider()

                List {
                    if isLoading {
                        ProgressView(language.text("browser.loading"))
                            .frame(maxWidth: .infinity)
                            .listRowSeparator(.hidden)
                    } else if apps.isEmpty {
                        emptyState
                            .listRowSeparator(.hidden)
                    } else if filteredApps.isEmpty {
                        searchEmptyState
                            .listRowSeparator(.hidden)
                    } else {
                        Section {
                            ForEach(filteredApps) { app in
                                NavigationLink {
                                    FileBrowserView(
                                        containerPath: app.containerPath,
                                        title: app.displayName,
                                        bundleID: app.bundleID
                                    )
                                } label: {
                                    FilesAppRow(app: app)
                                }
                            }
                        } header: {
                            Text(language.text("browser.apps_count", Int64(filteredApps.count)))
                                .textCase(nil)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle(language.text("tab.files"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        loadApps()
                    } label: {
                        if isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isLoading)
                    .accessibilityLabel(language.text("browser.retry"))
                }
            }
            .onAppear {
                if apps.isEmpty { loadApps() }
            }
        }
        .tint(AppTheme.accent)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                .foregroundStyle(AppTheme.accent)
            Text(language.text("browser.empty"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(language.text("browser.retry"), action: loadApps)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 54)
    }

    private var searchEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                .foregroundStyle(AppTheme.accent)
            Text(language.text("browser.search_empty"))
                .font(.headline)
            Text(language.text("browser.search_apps_empty_message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 54)
    }

    private func loadApps() {
        guard !isLoading else { return }
        isLoading = true
        log("files: app container scan started")

        DispatchQueue.global(qos: .userInitiated).async {
            let metadata = ContainerStore.applicationBundleMetadataCatalog()
            let identified = ContainerStore.applyingBundleMetadata(
                to: ContainerStore.installedAppsFromAPI(),
                catalog: metadata
            )
            let filesystem = ContainerStore.containersFromFilesystem()
            let merged = ContainerDiscoveryMerger.merge(
                enumerated: filesystem,
                identified: identified,
                path: \.containerPath
            )
            let launchServicesIdentifiers = Set(ContainerStore.launchServicesStoreIdentifiers())
            let resolved = ContainerStore.inferUnidentifiedApps(
                in: merged,
                knownApps: identified,
                launchServicesIdentifiers: launchServicesIdentifiers
            )
            let sorted = resolved.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }

            log("files: app container scan finished count=\(sorted.count)")
            DispatchQueue.main.async {
                apps = sorted
                isLoading = false
            }
        }
    }
}

private struct FilesAppRow: View {
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 12) {
            AppRowIcon(systemName: "folder.fill", tint: AppTheme.accent)

            VStack(alignment: .leading, spacing: 3) {
                Text(app.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(app.bundleID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
    }
}