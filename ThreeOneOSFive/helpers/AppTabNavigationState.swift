import Foundation

enum AppSection: Int, CaseIterable, Identifiable {
    case home
    case files
    case patches
    case cleaner

    var id: Int { rawValue }
}

struct AppTabNavigationState: Equatable {
    private(set) var selectedTab: Int

    init(selectedTab: Int = AppSection.home.rawValue) {
        self.selectedTab = selectedTab
    }

    mutating func select(_ tab: Int) {
        selectedTab = tab
    }

}

struct FileBrowserDestination: Hashable {
    let containerPath: String
    let startPath: String
    let title: String
    let bundleID: String?
}
