import ApplicationServices
import XCTest
@testable import WindowBoard

final class WindowMatchingTests: XCTestCase {
    func testBestExpectedFrontWindowRejectsDifferentAppAndUsesMatchingCandidate() {
        let unrelatedWindow = window(
            id: "unrelated",
            title: "Other",
            bundleIdentifier: "com.example.Other"
        )
        let matchingWindow = window(
            id: "matching",
            title: "Expected",
            bundleIdentifier: "com.example.Editor"
        )

        let resolved = WindowMatching.bestExpectedFrontWindow(
            in: [unrelatedWindow, matchingWindow],
            expectedBundleIdentifier: "com.example.Editor",
            expectedAppName: "Editor"
        )

        XCTAssertEqual(resolved?.id, matchingWindow.id)
    }

    func testSwitchDoesNotStartAutomaticRecoveryWhenRestoreMissingIsDisabled() async {
        let reference = savedReference(title: "Missing")
        let workspace = makeWorkspace(name: "No Recovery", windows: [reference])
        let service = FakeWorkspaceWindowService(windows: [])
        let session = makeSession(workspaces: [workspace], service: service)
        let storedWorkspace = try! XCTUnwrap(session.workspaceStore.workspaces.first { $0.name == workspace.name })

        session.switchWorkspace(
            id: storedWorkspace.id,
            boardOrigin: .zero,
            source: .mainWindow,
            followMode: .none,
            windowCache: []
        )

        await waitForWorkspaceSwitch(session)

        XCTAssertTrue(service.openedReferences.isEmpty)
        XCTAssertTrue(service.activatedReferences.isEmpty)
        XCTAssertTrue(session.isUnavailable(reference.id))
    }

    func testSwitchDefersAutomaticRecoveryUntilAfterInitialResolution() async {
        let reference = savedReference(title: "Recovered")
        let workspace = makeWorkspace(name: "Deferred Recovery", windows: [reference])
        let recoveredWindow = window(id: "recovered-window", title: "Recovered")
        let service = FakeWorkspaceWindowService(windows: [])
        service.listWindowsResponses = [[], [recoveredWindow]]
        service.openSavedReferenceResult = true
        let session = makeSession(
            workspaces: [workspace],
            service: service,
            restoreMissingWindowsOnSwitch: true
        )
        let storedWorkspace = try! XCTUnwrap(session.workspaceStore.workspaces.first { $0.name == workspace.name })

        session.switchWorkspace(
            id: storedWorkspace.id,
            boardOrigin: .zero,
            source: .mainWindow,
            followMode: .none,
            windowCache: []
        )

        await wait {
            !session.isLoadingWorkspace &&
                !session.isApplyingWorkspaceWindows &&
                !session.isReconnecting(reference.id) &&
                session.attachedWindows.first?.window.id == recoveredWindow.id
        }

        XCTAssertEqual(service.openedReferences.map(\.id), [reference.id])
        XCTAssertFalse(session.isUnavailable(reference.id))
    }

    func testSwitchWorkspaceUsesSavedOriginForStatusItemWithCachedWindow() async {
        let reference = savedReference(title: "Saved", origin: CGPoint(x: 480, y: 320))
        let workspace = makeWorkspace(name: "Status", windows: [reference])
        let liveWindow = window(id: "saved-window", title: "Saved", position: CGPoint(x: 40, y: 50))
        let service = FakeWorkspaceWindowService(windows: [liveWindow])
        let session = makeSession(workspaces: [workspace], service: service)
        let storedWorkspace = try! XCTUnwrap(session.workspaceStore.workspaces.first { $0.name == workspace.name })

        session.switchWorkspace(
            id: storedWorkspace.id,
            boardOrigin: CGPoint(x: 10, y: 10),
            source: .statusItem,
            followMode: .none,
            windowCache: [liveWindow]
        )

        await waitForWorkspaceSwitch(session)

        XCTAssertEqual(session.activeWorkspaceID, storedWorkspace.id)
        XCTAssertEqual(session.attachedWindows.first?.lastWindowOrigin, CGPoint(x: 480, y: 320))
        XCTAssertEqual(service.positions[liveWindow.id], CGPoint(x: 480, y: 320))
        XCTAssertFalse(session.isUnavailable(reference.id))
    }

    func testLayoutWriteFailureDoesNotMarkLiveWindowUnavailable() async {
        let reference = savedReference(title: "Live", origin: CGPoint(x: 320, y: 220))
        let workspace = makeWorkspace(name: "Live", windows: [reference])
        let liveWindow = window(id: "live-window", title: "Live", position: CGPoint(x: 10, y: 10))
        let service = FakeWorkspaceWindowService(windows: [liveWindow])
        service.positionWriteFailureIDs = [liveWindow.id]
        let session = makeSession(workspaces: [workspace], service: service)
        let storedWorkspace = try! XCTUnwrap(session.workspaceStore.workspaces.first { $0.name == workspace.name })

        session.switchWorkspace(
            id: storedWorkspace.id,
            boardOrigin: .zero,
            source: .mainWindow,
            followMode: .none,
            windowCache: [liveWindow]
        )

        await waitForWorkspaceSwitch(session)

        XCTAssertEqual(session.attachedWindows.map(\.window.id), [liveWindow.id])
        XCTAssertFalse(session.isUnavailable(reference.id))
    }

    func testSwitchWorkspaceKeepsUnresolvedReferenceAttachedAsUnavailable() async {
        let reference = savedReference(title: "Missing", origin: CGPoint(x: 240, y: 180))
        let workspace = makeWorkspace(name: "Missing", windows: [reference])
        let session = makeSession(
            workspaces: [workspace],
            service: FakeWorkspaceWindowService(windows: [])
        )
        let storedWorkspace = try! XCTUnwrap(session.workspaceStore.workspaces.first { $0.name == workspace.name })

        session.switchWorkspace(
            id: storedWorkspace.id,
            boardOrigin: .zero,
            source: .mainWindow,
            followMode: .none,
            windowCache: []
        )

        await waitForWorkspaceSwitch(session)

        XCTAssertEqual(session.attachedWindows.count, 1)
        XCTAssertEqual(session.attachedWindows.first?.id, reference.id)
        XCTAssertEqual(session.attachedWindows.first?.window.pid, 0)
        XCTAssertTrue(session.isUnavailable(reference.id))
    }

    func testMinimizeUnattachedProtectsAttachedAndPermanentWindows() async {
        let attached = window(id: "attached", title: "Attached", bundleIdentifier: "com.example.attached")
        let permanent = window(id: "permanent", title: "Permanent", bundleIdentifier: "com.example.permanent")
        let other = window(id: "other", title: "Other", bundleIdentifier: "com.example.other")
        let service = FakeWorkspaceWindowService(windows: [attached, permanent, other])
        let session = makeSession(service: service)
        session.attachedWindows = [
            AttachedWindow(
                window: attached,
                lastBoardOrigin: .zero,
                lastWindowOrigin: CGPoint(x: 20, y: 20),
                lastAppliedOrigin: nil,
                pendingReleaseOrigin: nil
            )
        ]
        session.neverMinimizeWindows = [NeverMinimizeWindow(window: permanent)]

        session.minimizeUnattachedWindows(
            knownWindows: [attached, permanent, other],
            refreshWindowList: false
        )

        await waitForMinimization(session)

        XCTAssertFalse(service.minimizedWindowIDs.contains(attached.id))
        XCTAssertFalse(service.minimizedWindowIDs.contains(permanent.id))
        XCTAssertTrue(service.minimizedWindowIDs.contains(other.id))
        XCTAssertEqual(session.minimizedWindows.map(\.id), [other.id])
    }

    func testRestoreKeepsOnlyWindowsThatCouldNotBeRestored() async {
        let restored = window(id: "restored", title: "Restored")
        let failed = window(id: "failed", title: "Failed")
        let service = FakeWorkspaceWindowService(windows: [restored, failed])
        service.minimizedWindowIDs = [restored.id, failed.id]
        service.minimizeWriteFailureIDs = [failed.id]
        let session = makeSession(service: service)
        session.minimizedWindows = [restored, failed]

        session.restoreMinimizedWindows()

        await waitForRestore(session)

        XCTAssertFalse(service.minimizedWindowIDs.contains(restored.id))
        XCTAssertTrue(service.minimizedWindowIDs.contains(failed.id))
        XCTAssertEqual(session.minimizedWindows.map(\.id), [failed.id])
    }

    func testNewerSwitchRemainsActiveWhenPreviousResolutionFinishesLater() async {
        let firstReference = savedReference(title: "First")
        let secondReference = savedReference(title: "Second")
        let firstWorkspace = makeWorkspace(name: "First", windows: [firstReference])
        let secondWorkspace = makeWorkspace(name: "Second", windows: [secondReference])
        let secondWindow = window(id: "second-window", title: "Second")
        let service = FakeWorkspaceWindowService(windows: [secondWindow])
        service.listWindowsDelay = 0.05
        let session = makeSession(workspaces: [firstWorkspace, secondWorkspace], service: service)
        let storedFirstWorkspace = try! XCTUnwrap(session.workspaceStore.workspaces.first { $0.name == firstWorkspace.name })
        let storedSecondWorkspace = try! XCTUnwrap(session.workspaceStore.workspaces.first { $0.name == secondWorkspace.name })

        session.switchWorkspace(
            id: storedFirstWorkspace.id,
            boardOrigin: .zero,
            source: .mainWindow,
            followMode: .none,
            windowCache: []
        )
        session.switchWorkspace(
            id: storedSecondWorkspace.id,
            boardOrigin: .zero,
            source: .mainWindow,
            followMode: .none,
            windowCache: []
        )

        await waitForWorkspaceSwitch(session)

        XCTAssertEqual(session.activeWorkspaceID, storedSecondWorkspace.id)
        XCTAssertEqual(session.selectedWorkspaceID, storedSecondWorkspace.id)
        XCTAssertEqual(session.attachedWindows.map(\.window.id), [secondWindow.id])
    }

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

    func testRecoveryResolverUsesSavedReferenceMatchingWhenAvailable() {
        let reference = savedReference(title: "Saved", documentURL: "file:///saved")
        let original = window(id: "original", title: "Original", documentURL: "file:///original")
        let documentMatch = window(id: "document", title: "Different", documentURL: "file:///saved")
        let originalMatch = window(id: "original-match", title: "Original", documentURL: "file:///other")

        let replacement = AttachedWindowRecoveryResolver.replacementWindow(
            savedReference: reference,
            originalWindow: original,
            candidates: [originalMatch, documentMatch]
        )

        XCTAssertEqual(replacement?.id, documentMatch.id)
    }

    func testRecoveryResolverFallsBackToOriginalWindowMatchingWithoutSavedReference() {
        let original = window(id: "original", title: "Original", documentURL: "file:///original")
        let documentMatch = window(id: "document", title: "Different", documentURL: "file:///original")
        let titleMatch = window(id: "title", title: "Original", documentURL: "file:///other")

        let replacement = AttachedWindowRecoveryResolver.replacementWindow(
            savedReference: nil,
            originalWindow: original,
            candidates: [titleMatch, documentMatch]
        )

        XCTAssertEqual(replacement?.id, documentMatch.id)
    }

    func testRecoveryResolverFailureIssuePrefersReopenThenActivation() {
        XCTAssertEqual(
            AttachedWindowRecoveryResolver.failureIssue(
                didReopen: true,
                didActivateApplication: true
            ),
            .openedButNotMatched
        )
        XCTAssertEqual(
            AttachedWindowRecoveryResolver.failureIssue(
                didReopen: false,
                didActivateApplication: true
            ),
            .activatedButNotMatched
        )
        XCTAssertEqual(
            AttachedWindowRecoveryResolver.failureIssue(
                didReopen: false,
                didActivateApplication: false
            ),
            .couldNotOpen
        )
    }

    func testApplicationWindowCatalogMergesWithoutDuplicateIDsAndSortsByDisplayName() {
        let catalog = ApplicationWindowCatalog()
        let cached = window(id: "cached", title: "Zulu")
        let duplicate = window(id: "cached", title: "Updated")
        let added = window(id: "added", title: "Alpha")

        let merged = catalog.merging([duplicate, added], into: [cached])

        XCTAssertEqual(merged.map(\.id), [added.id, cached.id])
        XCTAssertEqual(merged.first(where: { $0.id == cached.id })?.title, cached.title)
    }

    func testApplicationWindowCatalogMergingEmptyInputStillSortsCachedWindows() {
        let catalog = ApplicationWindowCatalog()
        let second = window(id: "second", title: "Beta")
        let first = window(id: "first", title: "Alpha")

        XCTAssertEqual(
            catalog.merging([], into: [second, first]).map(\.id),
            [first.id, second.id]
        )
    }

    func testRecoveryCoordinatorReturnsAlreadyConnectedForLiveWindow() async {
        let original = window(id: "live", title: "Live", position: CGPoint(x: 220, y: 180))
        let service = FakeWorkspaceWindowService(windows: [original])
        let coordinator = makeRecoveryCoordinator(service: service)

        let result = await coordinator.recover(
            AttachedWindowRecoveryRequest(
                originalWindow: original,
                savedReference: nil,
                shouldTryMinimizedRestore: false
            )
        )

        guard case let .alreadyConnected(position) = result else {
            return XCTFail("Expected an already-connected result.")
        }
        XCTAssertEqual(position, CGPoint(x: 220, y: 180))
    }

    func testRecoveryCoordinatorRestoresMinimizedOriginalWindow() async {
        let original = window(id: "minimized", title: "Minimized")
        let service = FakeWorkspaceWindowService(windows: [original])
        service.minimizedWindowIDs.insert(original.id)
        let coordinator = makeRecoveryCoordinator(service: service)

        let result = await coordinator.recover(
            AttachedWindowRecoveryRequest(
                originalWindow: original,
                savedReference: nil,
                shouldTryMinimizedRestore: true
            )
        )

        guard case .restoredOriginal = result else {
            return XCTFail("Expected the minimized original window to be restored.")
        }
        XCTAssertFalse(service.minimizedWindowIDs.contains(original.id))
    }

    func testRecoveryCoordinatorReconnectsUsingSavedReference() async {
        let original = window(id: "stale", title: "Old", position: nil)
        let replacement = window(id: "replacement", title: "Saved")
        let reference = savedReference(title: "Saved")
        let service = FakeWorkspaceWindowService(windows: [replacement])
        service.openSavedReferenceResult = true
        let coordinator = makeRecoveryCoordinator(service: service)

        let result = await coordinator.recover(
            AttachedWindowRecoveryRequest(
                originalWindow: original,
                savedReference: reference,
                shouldTryMinimizedRestore: false
            )
        )

        guard case let .reconnected(window, discoveredWindows) = result else {
            return XCTFail("Expected a reconnected result.")
        }
        XCTAssertEqual(window.id, replacement.id)
        XCTAssertEqual(discoveredWindows.map(\.id), [replacement.id])
        XCTAssertEqual(service.openedReferences.count, 1)
    }

    func testRecoveryCoordinatorReportsActivationWithoutMatch() async {
        let original = window(id: "missing", title: "Missing", position: nil)
        let service = FakeWorkspaceWindowService(windows: [])
        service.activateOrOpenApplicationResult = true
        let coordinator = makeRecoveryCoordinator(service: service)

        let result = await coordinator.recover(
            AttachedWindowRecoveryRequest(
                originalWindow: original,
                savedReference: nil,
                shouldTryMinimizedRestore: false
            )
        )

        guard case let .notMatched(issue, discoveredWindows) = result else {
            return XCTFail("Expected a not-matched result.")
        }
        XCTAssertEqual(issue, .activatedButNotMatched)
        XCTAssertTrue(discoveredWindows.isEmpty)
    }

    func testRecoveryCoordinatorFindsExpectedVisibleFrontWindow() async {
        let expected = window(id: "front", title: "Front")
        let service = FakeWorkspaceWindowService(windows: [expected])
        service.frontmostVisibleWindow = expected
        let coordinator = makeRecoveryCoordinator(service: service)

        let result = await coordinator.findFrontWindow(
            application: nil,
            expectedBundleIdentifier: expected.bundleIdentifier,
            expectedAppName: expected.appName
        )

        guard case let .matched(window, position, size) = result else {
            return XCTFail("Expected the visible front window to match.")
        }
        XCTAssertEqual(window.id, expected.id)
        XCTAssertEqual(position, expected.position)
        XCTAssertEqual(size, CGSize(width: 800, height: 600))
    }

    func testBoardFollowPlannerAppliesXDeltaAndInvertsYDelta() {
        let attached = AttachedWindow(
            window: window(id: "follow", title: "Follow"),
            lastBoardOrigin: CGPoint(x: 100, y: 100),
            lastWindowOrigin: CGPoint(x: 400, y: 300),
            lastAppliedOrigin: CGPoint(x: 400, y: 300),
            pendingReleaseOrigin: nil
        )

        let update = BoardFollowPlanner.updates(
            for: CGPoint(x: 125, y: 140),
            attachedWindows: [attached],
            unavailableAttachmentIDs: []
        ).first

        XCTAssertEqual(update?.targetOrigin, CGPoint(x: 425, y: 260))
    }

    func testBoardFollowPlannerOnlyUpdatesBaselineForUnavailableWindow() {
        let attached = AttachedWindow(
            window: window(id: "unavailable", title: "Unavailable"),
            lastBoardOrigin: .zero,
            lastWindowOrigin: CGPoint(x: 300, y: 200),
            lastAppliedOrigin: CGPoint(x: 300, y: 200),
            pendingReleaseOrigin: nil
        )

        let update = BoardFollowPlanner.updates(
            for: CGPoint(x: 40, y: 30),
            attachedWindows: [attached],
            unavailableAttachmentIDs: [attached.id]
        ).first

        XCTAssertEqual(update?.boardOrigin, CGPoint(x: 40, y: 30))
        XCTAssertNil(update?.targetOrigin)
    }

    func testBoardFollowPlannerSkipsSubpointMove() {
        let attached = AttachedWindow(
            window: window(id: "small", title: "Small"),
            lastBoardOrigin: .zero,
            lastWindowOrigin: CGPoint(x: 200, y: 200),
            lastAppliedOrigin: CGPoint(x: 200.5, y: 199.5),
            pendingReleaseOrigin: nil
        )

        let update = BoardFollowPlanner.updates(
            for: CGPoint(x: 0.5, y: 0.5),
            attachedWindows: [attached],
            unavailableAttachmentIDs: []
        ).first

        XCTAssertNil(update?.targetOrigin)
    }

    func testBoardFollowPlannerMovesAtExactlyOnePointAndPreservesOrder() {
        let first = AttachedWindow(
            window: window(id: "first-follow", title: "First"),
            lastBoardOrigin: .zero,
            lastWindowOrigin: CGPoint(x: 100, y: 100),
            lastAppliedOrigin: CGPoint(x: 100, y: 100),
            pendingReleaseOrigin: nil
        )
        let second = AttachedWindow(
            window: window(id: "second-follow", title: "Second"),
            lastBoardOrigin: .zero,
            lastWindowOrigin: CGPoint(x: 200, y: 200),
            lastAppliedOrigin: CGPoint(x: 200, y: 200),
            pendingReleaseOrigin: nil
        )

        let updates = BoardFollowPlanner.updates(
            for: CGPoint(x: 1, y: 0),
            attachedWindows: [first, second],
            unavailableAttachmentIDs: []
        )

        XCTAssertEqual(updates.map(\.attachmentID), [first.id, second.id])
        XCTAssertEqual(updates[0].targetOrigin, CGPoint(x: 101, y: 100))
        XCTAssertEqual(updates[1].targetOrigin, CGPoint(x: 201, y: 200))
    }

    @MainActor
    func testBoardFollowCoordinatorDebouncesReleaseToLatestOrigin() async {
        let coordinator = BoardFollowCoordinator(releaseIdleDelay: 0.01, autoFrontIdleDelay: 0.01)
        var releasedOrigin: CGPoint?
        var usedImmediateStyle = false

        for origin in [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 40)] {
            coordinator.recordMovement(
                to: origin,
                mode: .onRelease,
                hasAttachedWindows: true,
                currentMode: { .onRelease },
                applySmoothMove: { _ in XCTFail("On Release must not move immediately.") },
                applyReleaseMove: { origin, style in
                    releasedOrigin = origin
                    if case .immediate = style {
                        usedImmediateStyle = true
                    }
                }
            )
        }

        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(releasedOrigin, CGPoint(x: 30, y: 40))
        XCTAssertTrue(usedImmediateStyle)
    }

    @MainActor
    func testBoardFollowCoordinatorUsesAnimatedStyleForAnimatedRelease() async {
        let coordinator = BoardFollowCoordinator(releaseIdleDelay: 0.01, autoFrontIdleDelay: 0.01)
        var usedAnimatedStyle = false

        coordinator.recordMovement(
            to: CGPoint(x: 12, y: 18),
            mode: .animatedRelease,
            hasAttachedWindows: true,
            currentMode: { .animatedRelease },
            applySmoothMove: { _ in XCTFail("Animated Release must not move immediately.") },
            applyReleaseMove: { _, style in
                if case .animated = style {
                    usedAnimatedStyle = true
                }
            }
        )

        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(usedAnimatedStyle)
    }

    private func window(
        id: String = UUID().uuidString,
        title: String,
        bundleIdentifier: String? = "com.example.Editor",
        documentURL: String? = nil,
        windowNumber: CGWindowID? = nil,
        position: CGPoint? = CGPoint(x: 100, y: 100)
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
            position: position
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

    private func makeWorkspace(name: String, windows: [SavedWindowReference]) -> SavedWorkspace {
        SavedWorkspace(
            id: UUID(),
            name: name,
            statusItemSymbolName: nil,
            createdAt: Date(),
            updatedAt: Date(),
            windows: windows
        )
    }

    private func makeRecoveryCoordinator(
        service: FakeWorkspaceWindowService
    ) -> AttachedWindowRecoveryCoordinator {
        AttachedWindowRecoveryCoordinator(
            serviceFactory: { service },
            maximumAttempts: 1,
            shortDelayAttemptLimit: 1,
            shortRetryDelay: .zero,
            longRetryDelay: .zero,
            restoreSettleDelay: .zero
        )
    }

    private func makeSession(
        workspaces: [SavedWorkspace] = [],
        service: FakeWorkspaceWindowService,
        restoreMissingWindowsOnSwitch: Bool = false
    ) -> WorkspaceSessionController {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(restoreMissingWindowsOnSwitch, forKey: "restoreMissingWindowsOnWorkspaceSwitch")
        let store = WorkspaceStore(defaults: defaults)
        for workspace in workspaces {
            _ = store.saveWorkspace(name: workspace.name, windows: workspace.windows)
        }

        return WorkspaceSessionController(
            workspaceStore: store,
            defaults: defaults,
            windowServiceFactory: { service }
        )
    }

    private func waitForWorkspaceSwitch(
        _ session: WorkspaceSessionController,
        timeout: TimeInterval = 2
    ) async {
        await wait(timeout: timeout) {
            !session.isLoadingWorkspace && !session.isApplyingWorkspaceWindows
        }
    }

    private func waitForMinimization(_ session: WorkspaceSessionController) async {
        await wait {
            !session.isMinimizingUnattached
        }
    }

    private func waitForRestore(_ session: WorkspaceSessionController) async {
        await wait {
            !session.isRestoringMinimized
        }
    }

    private func wait(
        timeout: TimeInterval = 2,
        until condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(condition(), "Timed out waiting for asynchronous state to settle.")
    }
}

private final class FakeWorkspaceWindowService: ContentWindowOperating, @unchecked Sendable {
    var windowsToList: [WindowInfo]
    var matchingWindowsByID: [WindowInfo.ID: [WindowInfo]] = [:]
    var positions: [WindowInfo.ID: CGPoint] = [:]
    var sizes: [WindowInfo.ID: CGSize] = [:]
    var minimizedWindowIDs: Set<WindowInfo.ID> = []
    var positionReadFailureIDs: Set<WindowInfo.ID> = []
    var positionWriteFailureIDs: Set<WindowInfo.ID> = []
    var sizeReadFailureIDs: Set<WindowInfo.ID> = []
    var sizeWriteFailureIDs: Set<WindowInfo.ID> = []
    var minimizeWriteFailureIDs: Set<WindowInfo.ID> = []
    var listWindowsDelay: TimeInterval = 0
    var listWindowsResponses: [[WindowInfo]] = []
    var openSavedReferenceResult = false
    var activateSavedApplicationResult = false
    var openDocumentResult = false
    var activateOrOpenApplicationResult = false
    var frontmostVisibleWindow: WindowInfo?
    private(set) var openedReferences: [SavedWindowReference] = []
    private(set) var activatedReferences: [SavedWindowReference] = []
    private(set) var raisedWindowIDs: [WindowInfo.ID] = []
    private var listWindowsCallCount = 0

    init(windows: [WindowInfo]) {
        windowsToList = windows
        positions = Dictionary(uniqueKeysWithValues: windows.compactMap { window in
            window.position.map { (window.id, $0) }
        })
        sizes = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, CGSize(width: 800, height: 600)) })
    }

    func listWindows() -> [WindowInfo] {
        if listWindowsDelay > 0 {
            Thread.sleep(forTimeInterval: listWindowsDelay)
        }

        if !listWindowsResponses.isEmpty {
            let index = min(listWindowsCallCount, listWindowsResponses.count - 1)
            listWindowsCallCount += 1
            return listWindowsResponses[index]
        }

        return windowsToList
    }

    func windows(matching window: WindowInfo) -> [WindowInfo] {
        matchingWindowsByID[window.id] ?? windowsToList.filter {
            $0.pid == window.pid || $0.bundleIdentifier == window.bundleIdentifier || $0.appName == window.appName
        }
    }

    func position(of window: WindowInfo) throws -> CGPoint {
        guard !positionReadFailureIDs.contains(window.id), let position = positions[window.id] else {
            throw WindowBoardAXError.missingPosition
        }
        return position
    }

    func size(of window: WindowInfo) throws -> CGSize {
        guard !sizeReadFailureIDs.contains(window.id), let size = sizes[window.id] else {
            throw WindowBoardAXError.missingSize
        }
        return size
    }

    func setPosition(_ position: CGPoint, for window: WindowInfo) throws {
        guard !positionWriteFailureIDs.contains(window.id) else {
            throw WindowBoardAXError.missingPosition
        }
        positions[window.id] = position
    }

    func setSize(_ size: CGSize, for window: WindowInfo) throws {
        guard !sizeWriteFailureIDs.contains(window.id) else {
            throw WindowBoardAXError.missingSize
        }
        sizes[window.id] = size
    }

    func isMinimized(_ window: WindowInfo) -> Bool {
        minimizedWindowIDs.contains(window.id)
    }

    func setMinimized(_ minimized: Bool, for window: WindowInfo) throws {
        guard !minimizeWriteFailureIDs.contains(window.id) else {
            throw WindowBoardAXError.missingPosition
        }

        if minimized {
            minimizedWindowIDs.insert(window.id)
        } else {
            minimizedWindowIDs.remove(window.id)
        }
    }

    func raise(_ window: WindowInfo) {
        raisedWindowIDs.append(window.id)
    }

    func openSavedWindowReference(_ reference: SavedWindowReference) -> Bool {
        openedReferences.append(reference)
        return openSavedReferenceResult
    }

    func activateSavedApplication(_ reference: SavedWindowReference) -> Bool {
        activatedReferences.append(reference)
        return activateSavedApplicationResult
    }

    func isTrusted() -> Bool { true }
    func requestAccessPrompt() {}
    func openAccessibilitySettings() {}

    func frontmostWindow(for application: NSRunningApplication) -> WindowInfo? {
        windowsToList.first { $0.pid == application.processIdentifier }
    }

    func frontmostVisibleExternalWindow(excludingProcessID excludedPID: pid_t) -> WindowInfo? {
        frontmostVisibleWindow
    }

    func windows(for application: NSRunningApplication) -> [WindowInfo] {
        windowsToList.filter { $0.pid == application.processIdentifier }
    }

    func title(of window: WindowInfo) -> String? { window.title }
    func raiseWindowOnly(_ window: WindowInfo) {}
    func activateApplication(for window: WindowInfo) {}
    func activateApplication(pid: pid_t) -> Bool { true }

    func openDocument(for window: WindowInfo) -> Bool {
        openDocumentResult
    }

    func activateOrOpenApplication(for window: WindowInfo) -> Bool {
        activateOrOpenApplicationResult
    }

    func focusWindow(_ window: WindowInfo) {}
}
