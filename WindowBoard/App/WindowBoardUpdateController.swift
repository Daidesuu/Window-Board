import AppKit
import Foundation
import Sparkle

@MainActor
final class WindowBoardUpdateController: NSObject {
    private var updaterController: SPUStandardUpdaterController?

    override init() {
        super.init()

        guard SparkleUpdateConfiguration.load() != nil else { return }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        guard let updaterController else {
            let alert = NSAlert()
            alert.messageText = "Software updates are not configured."
            alert.informativeText = "Set SPARKLE_FEED_URL and SPARKLE_PUBLIC_ED_KEY before publishing updates."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        updaterController.checkForUpdates(nil)
    }
}

private struct SparkleUpdateConfiguration {
    static func load(bundle: Bundle = .main) -> (feedURL: URL, publicKey: String)? {
        guard let feedURLString = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feedURLString.isEmpty,
              !feedURLString.contains("$("),
              let feedURL = URL(string: feedURLString),
              feedURL.scheme?.lowercased() == "https",
              let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !publicKey.isEmpty,
              !publicKey.contains("$(") else {
            return nil
        }
        return (feedURL, publicKey)
    }
}
