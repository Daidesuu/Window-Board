import ApplicationServices
import XCTest
@testable import WindowBoard

final class WindowMatchingTests: XCTestCase {
    func testBestReplacementPrefersDocumentURLBeforeTitle() {
        let original = window(title: "Report", documentURL: "file:///original")
        let documentMatch = window(id: "document", title: "Different", documentURL: "file:///original")
        let titleMatch = window(id: "title", title: "Report", documentURL: "file:///other")

        XCTAssertEqual(
            WindowMatching.bestReplacement(for: original, in: [titleMatch, documentMatch])?.id,
            documentMatch.id
        )
    }

    func testBestSavedWindowExcludesAlreadyUsedCandidates() {
        let reference = savedReference(title: "Report")
        let usedTitleMatch = window(id: "used", title: "Report")
        let availableFallback = window(id: "available", title: "Other")

        XCTAssertEqual(
            WindowMatching.bestSavedWindow(
                for: reference,
                in: [usedTitleMatch, availableFallback],
                excluding: [usedTitleMatch.id]
            )?.id,
            availableFallback.id
        )
    }

    func testBestSavedWindowSkipsDocumentURLForVisualStudioCode() {
        let reference = savedReference(
            title: "Expected Title",
            bundleIdentifier: "com.microsoft.VSCode",
            documentURL: "file:///workspace-a"
        )
        let documentMatch = window(
            id: "document",
            title: "Different Title",
            bundleIdentifier: "com.microsoft.VSCode",
            documentURL: "file:///workspace-a"
        )
        let titleMatch = window(
            id: "title",
            title: "Expected Title",
            bundleIdentifier: "com.microsoft.VSCode",
            documentURL: "file:///workspace-b"
        )

        XCTAssertEqual(
            WindowMatching.bestSavedWindow(for: reference, in: [documentMatch, titleMatch], excluding: [])?.id,
            titleMatch.id
        )
    }

    func testNeverMinimizeMatchPrefersWindowNumberForSameApp() {
        let saved = NeverMinimizeWindow(
            bundleIdentifier: "com.example.Editor",
            appName: "Editor",
            title: "Untitled",
            documentURLString: "file:///document",
            windowNumber: 42,
            displayName: "Editor - Untitled"
        )
        let sameWindow = window(
            title: "Other",
            bundleIdentifier: "com.example.Editor",
            documentURL: "file:///other",
            windowNumber: 42
        )
        let anotherApp = window(
            id: "other-app",
            title: "Untitled",
            bundleIdentifier: "com.example.Other",
            documentURL: "file:///document",
            windowNumber: 42
        )

        XCTAssertTrue(saved.matches(sameWindow))
        XCTAssertTrue(saved.matches(anotherApp))
    }

    func testSavedReferenceUsesAbsoluteOriginAndValidSize() {
        let reference = savedReference(
            title: "Report",
            origin: CGPoint(x: 480, y: 240),
            size: CGSize(width: 1280, height: 800)
        )

        XCTAssertEqual(reference.targetOrigin(from: CGPoint(x: 20, y: 30), useSavedOrigin: true), CGPoint(x: 480, y: 240))
        XCTAssertEqual(reference.savedSize, CGSize(width: 1280, height: 800))
    }

    func testResolverUsesCachedWindowsWithoutASecondCandidatePass() {
        let first = savedReference(title: "First")
        let second = savedReference(title: "Second")
        let firstWindow = window(id: "first", title: "First")
        let secondWindow = window(id: "second", title: "Second")

        let resolution = WorkspaceWindowResolver.resolve(
            references: [first, second],
            candidates: [firstWindow, secondWindow],
            cachedWindowIDs: [first.id: firstWindow.id, second.id: secondWindow.id]
        )

        XCTAssertEqual(resolution.matches.map(\.window.id), [firstWindow.id, secondWindow.id])
        XCTAssertTrue(resolution.unresolvedReferences.isEmpty)
        XCTAssertEqual(resolution.loadedWindowIDs, [first.id: firstWindow.id, second.id: secondWindow.id])
    }

    func testResolverCompletesUnresolvedReferencesWithASecondCandidatePass() {
        let first = savedReference(title: "First")
        let second = savedReference(title: "Second")
        let firstWindow = window(id: "first", title: "First")
        let secondWindow = window(id: "second", title: "Second")

        let initial = WorkspaceWindowResolver.resolve(
            references: [first, second],
            candidates: [firstWindow],
            cachedWindowIDs: [first.id: firstWindow.id]
        )
        let resolved = WorkspaceWindowResolver.resolve(
            references: initial.unresolvedReferences,
            candidates: [firstWindow, secondWindow],
            cachedWindowIDs: [first.id: firstWindow.id, second.id: secondWindow.id],
            previous: initial
        )

        XCTAssertEqual(resolved.matches.map(\.window.id), [firstWindow.id, secondWindow.id])
        XCTAssertTrue(resolved.unresolvedReferences.isEmpty)
    }

    func testResolverDoesNotReuseOneWindowForMultipleReferences() {
        let first = savedReference(title: "Shared")
        let second = savedReference(title: "Shared")
        let sharedWindow = window(id: "shared", title: "Shared")

        let resolution = WorkspaceWindowResolver.resolve(
            references: [first, second],
            candidates: [sharedWindow],
            cachedWindowIDs: [:]
        )

        XCTAssertEqual(resolution.matches.count, 1)
        XCTAssertEqual(resolution.unresolvedReferences.map(\.id), [second.id])
    }

    func testResolverCreatesSavedOriginPlaceholderForUnresolvedReference() {
        let reference = savedReference(title: "Missing", origin: CGPoint(x: 640, y: 480))

        let placeholders = WorkspaceWindowResolver.placeholderAttachments(
            for: [reference],
            boardOrigin: CGPoint(x: 20, y: 30),
            useSavedOrigin: true
        )

        XCTAssertEqual(placeholders.count, 1)
        XCTAssertEqual(placeholders[0].id, reference.id)
        XCTAssertEqual(placeholders[0].lastWindowOrigin, CGPoint(x: 640, y: 480))
        XCTAssertEqual(placeholders[0].window.pid, 0)
    }

    private func window(
        id: String = UUID().uuidString,
        title: String,
        bundleIdentifier: String? = "com.example.Editor",
        documentURL: String? = nil,
        windowNumber: CGWindowID? = nil
    ) -> WindowInfo {
        WindowInfo(
            id: id,
            appName: "Editor",
            title: title,
            pid: 1,
            bundleIdentifier: bundleIdentifier,
            bundleURL: nil,
            documentURL: documentURL.flatMap(URL.init(string:)),
            axWindow: AXUIElementCreateApplication(1),
            windowNumber: windowNumber,
            position: CGPoint(x: 100, y: 100)
        )
    }

    private func savedReference(
        title: String,
        bundleIdentifier: String? = "com.example.Editor",
        documentURL: String? = nil,
        origin: CGPoint? = nil,
        size: CGSize? = nil
    ) -> SavedWindowReference {
        SavedWindowReference(
            id: UUID(),
            displayName: "Editor - \(title)",
            appName: "Editor",
            title: title,
            bundleIdentifier: bundleIdentifier,
            bundleURLString: nil,
            documentURLString: documentURL,
            workspaceURLString: nil,
            offsetX: 40,
            offsetY: 60,
            originX: origin?.x,
            originY: origin?.y,
            width: size?.width,
            height: size?.height
        )
    }
}
