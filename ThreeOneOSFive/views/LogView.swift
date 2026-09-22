import SwiftUI

struct LogView: View {
    @ObservedObject var appLog = AppLog.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appLanguage) private var language
    @State private var copied = false
    @State private var filterText = ""
    @State private var showClearConfirmation = false

    private var filteredEntries: [String] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return appLog.entries }
        return appLog.entries.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var shareText: String {
        var lines: [String] = []
        lines.append("External Log")
        lines.append("iOS \(AppInfo.osVersion) (\(AppInfo.osBuild)) — \(AppInfo.machineName)")
        lines.append("Generated: \(Date())")
        lines.append("")
        lines.append(contentsOf: appLog.entries)
        return lines.joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            Group {
                if appLog.entries.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "apple.terminal")
                            .font(.system(size: AppTheme.emptyIconSize, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(language.text("logs.empty_title"))
                            .font(.title3.bold())
                        Text(language.text("logs.empty_message"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(32)
                } else if filteredEntries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: AppTheme.emptyIconSize, weight: .medium))
                            .foregroundStyle(AppTheme.accent)
                        Text(language.text("logs.filtered_empty"))
                            .font(.headline)
                        Text(language.text("logs.filtered_empty_message"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(32)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(filteredEntries.enumerated()), id: \.offset) { index, entry in
                                    VStack(spacing: 0) {
                                        HStack(alignment: .top, spacing: 10) {
                                            Text(String(format: "%03d", index + 1))
                                                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                                                .foregroundStyle(AppTheme.accent)
                                                .frame(width: 28, alignment: .trailing)

                                            Text(entry)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(.primary)
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .padding(.vertical, 11)

                                        if index < filteredEntries.count - 1 {
                                            Divider()
                                        }
                                    }
                                    .id(index)
                                    .accessibilityLabel(language.text("accessibility.log_entry", Int64(index + 1), entry))
                                }
                            }
                            .padding(AppTheme.pageInset)
                            .background(AppTheme.consoleBackground)
                        }
                        .onChange(of: appLog.entries.count) { count in
                            guard count > 0, let lastIndex = filteredEntries.indices.last else { return }
                            if reduceMotion {
                                proxy.scrollTo(lastIndex, anchor: .bottom)
                            } else {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(lastIndex, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
            .background(AppTheme.consoleBackground.ignoresSafeArea())
            .safeAreaInset(edge: .top, spacing: 0) {
                AppSearchField(
                    text: $filterText,
                    prompt: language.text("logs.search"),
                    clearLabel: language.text("common.clear")
                )
            }
            .navigationTitle(language.text("logs.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(language.text("logs.clear"), role: .destructive) {
                        showClearConfirmation = true
                    }
                        .disabled(appLog.entries.isEmpty)
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        UIPasteboard.general.string = shareText
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(appLog.entries.isEmpty)
                    .accessibilityLabel(language.text("logs.copy"))

                    ShareLink(item: shareText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(appLog.entries.isEmpty)
                    .accessibilityLabel(language.text("logs.share"))

                    Button(language.text("common.done")) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog(
                language.text("logs.clear_confirm_title"),
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button(language.text("logs.clear"), role: .destructive) {
                    appLog.entries.removeAll()
                    filterText = ""
                }
                Button(language.text("common.cancel"), role: .cancel) {}
            } message: {
                Text(language.text("logs.clear_confirm_message"))
            }
        }
    }
}
