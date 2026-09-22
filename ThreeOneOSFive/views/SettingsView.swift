import SwiftUI
import Foundation

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @State private var now = Date()

    private let licenseCreatedAtKey = "ExternalLicenseCreatedAt"
    private let licenseDuration: TimeInterval = 24.0 * 60.0 * 60.0

    var body: some View {
        NavigationStack {
            Form {
                Section(language.text("settings.license")) {
                    Text("Key information: BORED")
                        .font(.body.weight(.semibold))
                    LabeledContent(
                        language.text("settings.key_created"),
                        value: licenseCreatedDate.formatted(
                            Date.FormatStyle()
                                .month(.wide)
                                .day()
                                .year()
                                .locale(Locale(identifier: "en_US_POSIX"))
                        )
                    )
                    LabeledContent(
                        language.text("settings.key_duration"),
                        value: language.text("settings.key_duration_value")
                    )
                    LabeledContent(
                        language.text("settings.key_days_remaining"),
                        value: daysRemainingText
                    )
                    LabeledContent(
                        language.text("settings.key_time_remaining"),
                        value: timeRemainingText
                    )
                        .foregroundStyle(isLicenseActive ? .secondary : .red)
                }

                Section(language.text("common.device")) {
                    LabeledContent(language.text("dashboard.hardware_model"), value: AppInfo.displayMachineName)
                    LabeledContent(language.text("settings.ios_version"), value: "\(AppInfo.osVersion) (\(AppInfo.osBuild))")
                }

                Section {
                    if let supportURL = URL(string: "https://linktr.ee/llenoderencor") {
                        Link(destination: supportURL) {
                            Label(language.text("settings.support"), systemImage: "lifepreserver.fill")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(AppTheme.accent)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .accessibilityLabel(language.text("accessibility.open_support"))
                    }
                }
            }
            .tint(AppTheme.accent)
            .navigationTitle(language.text("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(language.text("common.done")) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onReceive(
                Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
            ) { currentDate in
                now = currentDate
            }
        }
    }

    private var licenseCreatedDate: Date {
        let stored = UserDefaults.standard.double(forKey: licenseCreatedAtKey)
        if stored > 0 {
            return Date(timeIntervalSince1970: stored)
        }
        let currentDate = Date()
        UserDefaults.standard.set(currentDate.timeIntervalSince1970, forKey: licenseCreatedAtKey)
        return currentDate
    }

    private var licenseSecondsRemaining: TimeInterval {
        max(0, licenseDuration - now.timeIntervalSince(licenseCreatedDate))
    }

    private var isLicenseActive: Bool {
        licenseSecondsRemaining > 0
    }

    private var daysRemainingText: String {
        let days = isLicenseActive
            ? Int(ceil(licenseSecondsRemaining / licenseDuration))
            : 0
        return "\(days) \(days == 1 ? "day" : "days")"
    }

    private var timeRemainingText: String {
        let totalSeconds = Int(ceil(licenseSecondsRemaining))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
