import Foundation

enum TreeBrowserDisplayMode: String, CaseIterable, Identifiable {
    case list
    case icons

    var id: Self { self }
}
