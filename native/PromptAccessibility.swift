import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - Constants

private let helperVersion = "0.1.0"

private let knownCursorBundleIdentifiers: Set<String> = [
    "com.todesktop.230313mzl4w4u92"
]

private let selectAllKeyCode: CGKeyCode = 0   // Physical A key.
private let copyKeyCode: CGKeyCode = 8        // Physical C key.
private let pasteKeyCode: CGKeyCode = 9       // Physical V key.
private let rightArrowKeyCode: CGKeyCode = 124
private let focusAttempts = 20
private let focusRetryDelay: TimeInterval = 0.1
private let pasteVerificationTimeout: TimeInterval = 3.0

// MARK: - Input models

private struct ReplaceRequest: Decodable {
    let expectedOriginalText: String
    let replacementText: String
    let restoreClipboard: Bool?
}

// MARK: - Internal models

private struct FocusedTextArea {
    let element: AXUIElement
    let application: NSRunningApplication
    let text: String
}

private struct PasteboardRepresentation {
    let type: NSPasteboard.PasteboardType
    let data: Data
}

private struct PasteboardItemSnapshot {
    let representations: [PasteboardRepresentation]
}

private struct ClipboardRestoreResult {
    let restored: Bool
    let skippedBecauseChanged: Bool
}

// MARK: - JSON output

private func writeJSON(_ object: Any) {
    do {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )

        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        FileHandle.standardError.write(
            Data("Failed to serialize JSON: \(error)\n".utf8)
        )
        exit(70)
    }
}

private func fail(
    code: String,
    message: String,
    status: Int32 = 1,
    details: [String: Any] = [:]
) -> Never {
    var payload: [String: Any] = [
        "ok": false,
        "error": code,
        "message": message
    ]

    for (key, value) in details {
        payload[key] = value
    }

    writeJSON(payload)
    exit(status)
}

// MARK: - General utilities

private func parseDelay(_ arguments: [String]) -> TimeInterval {
    guard arguments.count >= 3 else {
        return 0
    }

    guard let delay = TimeInterval(arguments[2]), delay >= 0 else {
        fail(
            code: "invalid_delay",
            message: "Delay must be a non-negative number.",
            status: 64
        )
    }

    return delay
}

private func waitIfNeeded(_ delay: TimeInterval) {
    guard delay > 0 else {
        return
    }

    FileHandle.standardError.write(
        Data(
            "Waiting \(delay) seconds. Focus the Codex composer now…\n".utf8
        )
    )

    Thread.sleep(forTimeInterval: delay)
}

private func utf16Length(_ text: String) -> Int {
    (text as NSString).length
}

// MARK: - Accessibility permission

private func requestAccessibilityPermission() -> Bool {
    let options = [
        "AXTrustedCheckOptionPrompt": true
    ] as CFDictionary

    return AXIsProcessTrustedWithOptions(options)
}

private func requireAccessibilityPermission() {
    guard AXIsProcessTrusted() else {
        fail(
            code: "accessibility_permission_required",
            message: """
            Accessibility permission is not granted. Enable Warp or the helper \
            under System Settings → Privacy & Security → Accessibility.
            """,
            status: 77
        )
    }
}

// MARK: - AX attribute helpers

private func copyAttribute(
    _ element: AXUIElement,
    _ attribute: CFString
) -> (value: CFTypeRef?, error: AXError) {
    var value: CFTypeRef?

    let error = AXUIElementCopyAttributeValue(
        element,
        attribute,
        &value
    )

    return (value, error)
}

private func stringAttribute(
    _ element: AXUIElement,
    _ attribute: CFString
) -> String? {
    let result = copyAttribute(element, attribute)

    guard
        result.error == .success,
        let rawValue = result.value
    else {
        return nil
    }

    if let string = rawValue as? String {
        return string
    }

    if let attributedString = rawValue as? NSAttributedString {
        return attributedString.string
    }

    return nil
}

private func boolAttribute(
    _ element: AXUIElement,
    _ attribute: CFString
) -> Bool? {
    let result = copyAttribute(element, attribute)

    guard
        result.error == .success,
        let rawValue = result.value
    else {
        return nil
    }

    return rawValue as? Bool
}


private func integerAttribute(
    _ element: AXUIElement,
    _ attribute: CFString
) -> Int? {
    let result = copyAttribute(element, attribute)

    guard
        result.error == .success,
        let rawValue = result.value
    else {
        return nil
    }

    if let number = rawValue as? NSNumber {
        return number.intValue
    }

    return nil
}

private func rangeAttribute(
    _ element: AXUIElement,
    _ attribute: CFString
) -> CFRange? {
    let result = copyAttribute(element, attribute)

    guard
        result.error == .success,
        let rawValue = result.value,
        CFGetTypeID(rawValue) == AXValueGetTypeID()
    else {
        return nil
    }

    let axValue = rawValue as! AXValue
    var range = CFRange()

    guard AXValueGetValue(
        axValue,
        .cfRange,
        &range
    ) else {
        return nil
    }

    return range
}

private func elementAttribute(
    _ element: AXUIElement,
    _ attribute: CFString
) -> AXUIElement? {
    let result = copyAttribute(element, attribute)

    guard
        result.error == .success,
        let rawValue = result.value
    else {
        return nil
    }

    guard
        CFGetTypeID(rawValue)
            == AXUIElementGetTypeID()
    else {
        return nil
    }

    return (rawValue as! AXUIElement)
}

private func isAttributeSettable(
    _ element: AXUIElement,
    _ attribute: CFString
) -> Bool {
    var settable = DarwinBoolean(false)

    let error = AXUIElementIsAttributeSettable(
        element,
        attribute,
        &settable
    )

    return error == .success && settable.boolValue
}

// MARK: - Cursor identification

private func isCursorApplication(
    _ application: NSRunningApplication
) -> Bool {
    let name = application.localizedName ?? ""
    let bundleIdentifier = application.bundleIdentifier ?? ""

    return name.caseInsensitiveCompare("Cursor") == .orderedSame
        || knownCursorBundleIdentifiers.contains(bundleIdentifier)
}

private func applicationMetadata(
    _ application: NSRunningApplication
) -> [String: Any] {
    [
        "applicationName": application.localizedName ?? NSNull(),
        "bundleIdentifier": application.bundleIdentifier ?? NSNull(),
        "pid": Int(application.processIdentifier)
    ]
}

// MARK: - Focused text-area discovery

private struct ComposerCandidate {
    let element: AXUIElement
    let score: Int
    let reasons: [String]
    let frame: CGRect?
}

private let maximumWindowTraversalDepth = 24
private let maximumWindowTraversalNodes = 4_000
private let minimumComposerScore = 150
private let minimumComposerScoreMargin = 45

private func elementArrayAttribute(
    _ element: AXUIElement,
    _ attribute: CFString
) -> [AXUIElement] {
    let result = copyAttribute(element, attribute)

    guard
        result.error == .success,
        let rawValue = result.value
    else {
        return []
    }

    return rawValue as? [AXUIElement] ?? []
}

private func pointAttribute(
    _ element: AXUIElement,
    _ attribute: CFString
) -> CGPoint? {
    let result = copyAttribute(
        element,
        attribute
    )

    guard
        result.error == .success,
        let rawValue = result.value,
        CFGetTypeID(rawValue)
            == AXValueGetTypeID()
    else {
        return nil
    }

    let axValue = rawValue as! AXValue

    guard
        AXValueGetType(axValue) == .cgPoint
    else {
        return nil
    }

    var point = CGPoint.zero

    guard AXValueGetValue(
        axValue,
        .cgPoint,
        &point
    ) else {
        return nil
    }

    return point
}

private func sizeAttribute(
    _ element: AXUIElement,
    _ attribute: CFString
) -> CGSize? {
    let result = copyAttribute(
        element,
        attribute
    )

    guard
        result.error == .success,
        let rawValue = result.value,
        CFGetTypeID(rawValue)
            == AXValueGetTypeID()
    else {
        return nil
    }

    let axValue = rawValue as! AXValue

    guard
        AXValueGetType(axValue) == .cgSize
    else {
        return nil
    }

    var size = CGSize.zero

    guard AXValueGetValue(
        axValue,
        .cgSize,
        &size
    ) else {
        return nil
    }

    return size
}

private func elementFrame(
    _ element: AXUIElement
) -> CGRect? {
    guard
        let position = pointAttribute(
            element,
            kAXPositionAttribute as CFString
        ),
        let size = sizeAttribute(
            element,
            kAXSizeAttribute as CFString
        )
    else {
        return nil
    }

    return CGRect(
        origin: position,
        size: size
    )
}

private func nearestWritableTextArea(
    from focusedElement: AXUIElement
) -> AXUIElement? {
    var current: AXUIElement? = focusedElement

    // In most Cursor builds, the focused element is the AXTextArea itself.
    // Parent traversal handles nested Chromium accessibility nodes.
    for _ in 0...5 {
        guard let element = current else {
            return nil
        }

        let role = stringAttribute(
            element,
            kAXRoleAttribute as CFString
        )

        let hasReadableValue =
            stringAttribute(
                element,
                kAXValueAttribute as CFString
            ) != nil

        let selectionIsSettable =
            isAttributeSettable(
                element,
                kAXSelectedTextRangeAttribute as CFString
            )

        if
            role == kAXTextAreaRole as String,
            hasReadableValue,
            selectionIsSettable
        {
            return element
        }

        current = elementAttribute(
            element,
            kAXParentAttribute as CFString
        )
    }

    return nil
}

private func semanticContext(
    for element: AXUIElement,
    maximumDepth: Int = 7
) -> String {
    let semanticAttributes: [CFString] = [
        "AXTitle" as CFString,
        "AXDescription" as CFString,
        "AXIdentifier" as CFString,
        "AXHelp" as CFString,
        "AXPlaceholderValue" as CFString,
        "AXDOMIdentifier" as CFString
    ]

    var parts: [String] = []
    var current: AXUIElement? = element

    for _ in 0...maximumDepth {
        guard let currentElement = current else {
            break
        }

        for attribute in semanticAttributes {
            if
                let value = stringAttribute(
                    currentElement,
                    attribute
                ),
                !value.isEmpty
            {
                parts.append(value)
            }
        }

        current = elementAttribute(
            currentElement,
            kAXParentAttribute as CFString
        )
    }

    return parts
        .joined(separator: " ")
        .lowercased()
}

private func makeComposerCandidate(
    element: AXUIElement,
    windowFrame: CGRect?
) -> ComposerCandidate? {
    guard
        stringAttribute(
            element,
            kAXRoleAttribute as CFString
        ) == kAXTextAreaRole as String
    else {
        return nil
    }

    // Do not require AXSelectedTextRange to be
    // settable here. Chromium may expose it as
    // non-settable while another control has focus.
    guard let value = stringAttribute(
        element,
        kAXValueAttribute as CFString
    ) else {
        return nil
    }

    var score = 60
    var reasons = [
        "text-area",
        "readable-value"
    ]

    if isAttributeSettable(
        element,
        kAXSelectedTextRangeAttribute as CFString
    ) {
        score += 20
        reasons.append("selection-settable")
    }

    if isAttributeSettable(
        element,
        kAXValueAttribute as CFString
    ) {
        score += 30
        reasons.append("value-settable")
    }

    if boolAttribute(
        element,
        kAXEnabledAttribute as CFString
    ) != false {
        score += 10
        reasons.append("enabled")
    }

    if !value
        .trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        .isEmpty
    {
        score += 25
        reasons.append("non-empty")
    }

    let context = semanticContext(
        for: element
    )

    let positiveSignals: [
        (keyword: String, points: Int)
    ] = [
        ("codex", 350),
        ("chatgpt", 260),
        ("composer", 180),
        ("prompt", 140),
        ("message", 80),
        ("chat", 70),
        ("ask", 40)
    ]

    for signal in positiveSignals {
        if context.contains(signal.keyword) {
            score += signal.points
            reasons.append(signal.keyword)
        }
    }

    let negativeSignals: [
        (keyword: String, points: Int)
    ] = [
        ("monaco", 300),
        ("terminal", 260),
        ("quickinput", 220),
        ("editor", 190),
        ("search", 180),
        ("find", 150),
        ("output", 150),
        ("debug", 140),
        ("rename", 130),
        ("scm", 110)
    ]

    for signal in negativeSignals {
        if context.contains(signal.keyword) {
            score -= signal.points
            reasons.append(
                "not-\(signal.keyword)"
            )
        }
    }

    let frame = elementFrame(element)

    if
        let frame,
        let windowFrame,
        windowFrame.width > 0,
        windowFrame.height > 0
    {
        let relativeMidX =
            (
                frame.midX
                - windowFrame.minX
            )
            / windowFrame.width

        let relativeBottom =
            (
                frame.maxY
                - windowFrame.minY
            )
            / windowFrame.height

        // A chat composer normally sits near the
        // bottom of a sidebar or chat panel.
        if relativeBottom >= 0.72 {
            score += 120
            reasons.append("near-bottom")
        } else if relativeBottom >= 0.55 {
            score += 40
            reasons.append("lower-half")
        }

        // Codex can be docked on either side.
        if
            relativeMidX <= 0.45
            || relativeMidX >= 0.55
        {
            score += 35
            reasons.append("side-panel")
        }

        if
            frame.height >= 24
            && frame.height <= 320
        {
            score += 60
            reasons.append("composer-height")
        } else if frame.height > 500 {
            score -= 200
            reasons.append("too-tall")
        }

        if
            frame.width >= 250
            && frame.width <= 950
        {
            score += 30
            reasons.append("composer-width")
        } else if frame.width > 1_100 {
            score -= 80
            reasons.append("too-wide")
        }
    }

    return ComposerCandidate(
        element: element,
        score: score,
        reasons: reasons,
        frame: frame
    )
}

private func traversalChildren(
    of element: AXUIElement
) -> [AXUIElement] {
    let attributes: [CFString] = [
        kAXChildrenAttribute as CFString,
        kAXContentsAttribute as CFString,
        "AXVisibleChildren" as CFString
    ]

    var result: [AXUIElement] = []
    var seenHashes = Set<CFHashCode>()

    for attribute in attributes {
        for child in elementArrayAttribute(
            element,
            attribute
        ) {
            let hash = CFHash(child)

            if seenHashes.insert(hash).inserted {
                result.append(child)
            }
        }
    }

    return result
}

private func collectComposerCandidates(
    from window: AXUIElement
) -> [ComposerCandidate] {
    let windowFrame = elementFrame(window)

    var queue: [
        (element: AXUIElement, depth: Int)
    ] = [
        (window, 0)
    ]

    var queueIndex = 0
    var processedNodes = 0
    var visitedHashes = Set<CFHashCode>()
    var candidates: [ComposerCandidate] = []

    while
        queueIndex < queue.count,
        processedNodes
            < maximumWindowTraversalNodes
    {
        let entry = queue[queueIndex]
        queueIndex += 1

        let elementHash =
            CFHash(entry.element)

        guard visitedHashes
            .insert(elementHash)
            .inserted
        else {
            continue
        }

        processedNodes += 1

        if let candidate =
            makeComposerCandidate(
                element: entry.element,
                windowFrame: windowFrame
            )
        {
            candidates.append(candidate)
        }

        guard
            entry.depth
                < maximumWindowTraversalDepth
        else {
            continue
        }

        for child in traversalChildren(
            of: entry.element
        ) {
            queue.append((
                child,
                entry.depth + 1
            ))
        }
    }

    return candidates.sorted {
        $0.score > $1.score
    }
}

private func candidateDiagnostic(
    _ candidate: ComposerCandidate
) -> String {
    let frameDescription: String

    if let frame = candidate.frame {
        frameDescription = String(
            format:
                "x=%.0f,y=%.0f,w=%.0f,h=%.0f",
            frame.origin.x,
            frame.origin.y,
            frame.width,
            frame.height
        )
    } else {
        frameDescription = "frame=unavailable"
    }

    return [
        "score=\(candidate.score)",
        "reasons=\(candidate.reasons.joined(separator: ","))",
        frameDescription
    ].joined(separator: " ")
}

private func findCodexComposerInFocusedWindow(
    applicationElement: AXUIElement
) -> (
    textArea: AXUIElement?,
    diagnostics: [String]
) {
    let windowResult = copyAttribute(
        applicationElement,
        kAXFocusedWindowAttribute as CFString
    )

    guard
        windowResult.error == .success,
        let rawWindow = windowResult.value,
        CFGetTypeID(rawWindow)
            == AXUIElementGetTypeID()
    else {
        return (
            nil,
            [
                "focused-window error="
                    + String(
                        windowResult.error.rawValue
                    )
            ]
        )
    }

    let focusedWindow =
        rawWindow as! AXUIElement

    let candidates =
        collectComposerCandidates(
            from: focusedWindow
        )

    let diagnostics = candidates
        .prefix(10)
        .map(candidateDiagnostic)

    let eligibleCandidates =
        candidates.filter {
            $0.score >= minimumComposerScore
        }

    guard let bestCandidate =
        eligibleCandidates.first
    else {
        return (
            nil,
            [
                "no eligible Codex composer found; "
                    + "candidateCount="
                    + "\(candidates.count)"
            ] + diagnostics
        )
    }

    if eligibleCandidates.count >= 2 {
        let runnerUp =
            eligibleCandidates[1]

        let margin =
            bestCandidate.score
            - runnerUp.score

        guard
            margin
                >= minimumComposerScoreMargin
        else {
            return (
                nil,
                [
                    "composer search was ambiguous: "
                        + "bestScore="
                        + "\(bestCandidate.score) "
                        + "runnerUpScore="
                        + "\(runnerUp.score) "
                        + "margin=\(margin)"
                ] + diagnostics
            )
        }
    }

    return (
        bestCandidate.element,
        diagnostics
    )
}

private func findFocusedTextArea(
    delay: TimeInterval
) -> FocusedTextArea {
    waitIfNeeded(delay)

    var diagnostics: [String] = []

    let fallbackAttempts: Set<Int> = [
        1,
        5,
        10,
        15,
        20
    ]

    for attempt in 1...focusAttempts {
        guard
            let application =
                NSWorkspace.shared
                    .frontmostApplication
        else {
            diagnostics.append(
                "attempt \(attempt): "
                    + "frontmost application unavailable"
            )

            Thread.sleep(
                forTimeInterval:
                    focusRetryDelay
            )

            continue
        }

        guard isCursorApplication(
            application
        ) else {
            diagnostics.append(
                "attempt \(attempt): frontmost app is "
                    + (
                        application.localizedName
                        ?? "<unknown>"
                    )
            )

            Thread.sleep(
                forTimeInterval:
                    focusRetryDelay
            )

            continue
        }

        let applicationElement =
            AXUIElementCreateApplication(
                application.processIdentifier
            )

        let focusedResult = copyAttribute(
            applicationElement,
            kAXFocusedUIElementAttribute
                as CFString
        )

        if
            focusedResult.error == .success,
            let rawFocusedElement =
                focusedResult.value
        {
            let focusedElement =
                rawFocusedElement
                    as! AXUIElement

            if let textArea =
                nearestWritableTextArea(
                    from: focusedElement
                )
            {
                guard let text =
                    stringAttribute(
                        textArea,
                        kAXValueAttribute
                            as CFString
                    )
                else {
                    diagnostics.append(
                        "attempt \(attempt): "
                            + "focused text area has "
                            + "no readable value"
                    )

                    Thread.sleep(
                        forTimeInterval:
                            focusRetryDelay
                    )

                    continue
                }

                return FocusedTextArea(
                    element: textArea,
                    application: application,
                    text: text
                )
            }

            let focusedRole =
                stringAttribute(
                    focusedElement,
                    kAXRoleAttribute
                        as CFString
                )
                ?? "<unknown>"

            diagnostics.append(
                "attempt \(attempt): "
                    + "focused role "
                    + "\(focusedRole) "
                    + "is not a writable AXTextArea"
            )
        } else {
            diagnostics.append(
                "attempt \(attempt): "
                    + "AXFocusedUIElement error="
                    + String(
                        focusedResult.error.rawValue
                    )
            )
        }

        if fallbackAttempts.contains(
            attempt
        ) {
            let fallback =
                findCodexComposerInFocusedWindow(
                    applicationElement:
                        applicationElement
                )

            for line in fallback.diagnostics {
                diagnostics.append(
                    "attempt \(attempt) "
                        + "window-search: "
                        + line
                )
            }

            if let textArea =
                fallback.textArea
            {
                guard let text =
                    stringAttribute(
                        textArea,
                        kAXValueAttribute
                            as CFString
                    )
                else {
                    diagnostics.append(
                        "attempt \(attempt): "
                            + "fallback composer "
                            + "has no readable value"
                    )

                    Thread.sleep(
                        forTimeInterval:
                            focusRetryDelay
                    )

                    continue
                }

                return FocusedTextArea(
                    element: textArea,
                    application: application,
                    text: text
                )
            }
        }

        Thread.sleep(
            forTimeInterval:
                focusRetryDelay
        )
    }

    fail(
        code: "codex_composer_not_found",
        message: """
        Could not safely identify the Codex composer. Ensure Cursor was \
        launched with --force-renderer-accessibility=complete and that a \
        Codex chat with a visible prompt field is open.
        """,
        details: [
            "diagnostics":
                Array(
                    diagnostics.suffix(30)
                )
        ]
    )
}

// MARK: - Composer focus

private func focusTextArea(
    _ textArea: AXUIElement
) {
    if boolAttribute(
        textArea,
        kAXFocusedAttribute as CFString
    ) != true {
        guard isAttributeSettable(
            textArea,
            kAXFocusedAttribute as CFString
        ) else {
            fail(
                code: "composer_focus_not_settable",
                message: """
                The Codex composer is not focused and its AXFocused attribute \
                is not settable.
                """
            )
        }

        let error = AXUIElementSetAttributeValue(
            textArea,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )

        guard error == .success else {
            fail(
                code: "composer_focus_failed",
                message: "Could not focus the Codex composer.",
                details: [
                    "axError": error.rawValue
                ]
            )
        }
    }

    // Allow Chromium to synchronize the accessibility focus with its DOM.
    Thread.sleep(forTimeInterval: 0.1)

    guard boolAttribute(
        textArea,
        kAXFocusedAttribute as CFString
    ) == true else {
        fail(
            code: "composer_focus_verification_failed",
            message: "The Codex composer did not retain focus."
        )
    }
}

// MARK: - Clipboard capture and restoration

private func captureClipboard(
    _ pasteboard: NSPasteboard
) -> [PasteboardItemSnapshot] {
    guard let items = pasteboard.pasteboardItems else {
        return []
    }

    return items.compactMap { item in
        let representations = item.types.compactMap { type
            -> PasteboardRepresentation? in

            guard let data = item.data(forType: type) else {
                return nil
            }

            return PasteboardRepresentation(
                type: type,
                data: data
            )
        }

        guard !representations.isEmpty else {
            return nil
        }

        return PasteboardItemSnapshot(
            representations: representations
        )
    }
}

private func restoreClipboard(
    _ snapshots: [PasteboardItemSnapshot],
    pasteboard: NSPasteboard,
    expectedTemporaryChangeCount: Int
) -> ClipboardRestoreResult {
    // Avoid overwriting a clipboard change made by the user or another app
    // while enhancement was running.
    guard pasteboard.changeCount == expectedTemporaryChangeCount else {
        return ClipboardRestoreResult(
            restored: false,
            skippedBecauseChanged: true
        )
    }

    pasteboard.clearContents()

    guard !snapshots.isEmpty else {
        return ClipboardRestoreResult(
            restored: true,
            skippedBecauseChanged: false
        )
    }

    let restoredItems = snapshots.compactMap {
        snapshot -> NSPasteboardItem? in

        let item = NSPasteboardItem()
        var wroteRepresentation = false

        for representation in snapshot.representations {
            if item.setData(
                representation.data,
                forType: representation.type
            ) {
                wroteRepresentation = true
            }
        }

        return wroteRepresentation ? item : nil
    }

    guard !restoredItems.isEmpty else {
        return ClipboardRestoreResult(
            restored: false,
            skippedBecauseChanged: false
        )
    }

    let success = pasteboard.writeObjects(restoredItems)

    return ClipboardRestoreResult(
        restored: success,
        skippedBecauseChanged: false
    )
}

// MARK: - Keyboard events

private func postKey(
    _ keyCode: CGKeyCode,
    flags: CGEventFlags
) {
    let source = CGEventSource(
        stateID: .hidSystemState
    )

    guard
        let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: true
        ),
        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: false
        )
    else {
        fail(
            code: "keyboard_event_creation_failed",
            message: "Could not create a synthetic keyboard event."
        )
    }

    keyDown.flags = flags
    keyUp.flags = flags

    keyDown.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.025)
    keyUp.post(tap: .cghidEventTap)
}

private func postCommandKey(
    _ keyCode: CGKeyCode
) {
    postKey(
        keyCode,
        flags: .maskCommand
    )
}

private func postCommandA() {
    postCommandKey(selectAllKeyCode)
}

private func postCommandC() {
    postCommandKey(copyKeyCode)
}

private func postCommandV() {
    postCommandKey(pasteKeyCode)
}

private func collapseSelectionToEnd() {
    postKey(
        rightArrowKeyCode,
        flags: CGEventFlags(rawValue: 0)
    )

    Thread.sleep(forTimeInterval: 0.05)
}

private func waitForClipboardCopy(
    pasteboard: NSPasteboard,
    previousChangeCount: Int,
    timeout: TimeInterval = 1.5
) -> String? {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
        if
            pasteboard.changeCount != previousChangeCount,
            let value = pasteboard.string(forType: .string)
        {
            return value
        }

        Thread.sleep(forTimeInterval: 0.025)
    }

    return nil
}

private func copyEntirePromptSerialized(
    from textArea: AXUIElement,
    pasteboard: NSPasteboard
) -> String? {
    focusTextArea(textArea)

    postCommandA()
    Thread.sleep(forTimeInterval: 0.12)

    pasteboard.clearContents()

    let sentinel =
        "__CODEX_PROMPT_COPY_SENTINEL_\(UUID().uuidString)__"

    guard pasteboard.setString(
        sentinel,
        forType: .string
    ) else {
        return nil
    }

    let sentinelChangeCount = pasteboard.changeCount

    postCommandC()

    return waitForClipboardCopy(
        pasteboard: pasteboard,
        previousChangeCount: sentinelChangeCount
    )
}

// MARK: - Paste verification

private func waitForReplacement(
    in textArea: AXUIElement,
    expectedText: String
) -> Bool {
    let deadline = Date().addingTimeInterval(
        pasteVerificationTimeout
    )

    while Date() < deadline {
        if stringAttribute(
            textArea,
            kAXValueAttribute as CFString
        ) == expectedText {
            return true
        }

        Thread.sleep(forTimeInterval: 0.05)
    }

    return false
}

// MARK: - Commands

private func permissionCommand() {
    let trusted = requestAccessibilityPermission()

    writeJSON([
        "ok": true,
        "trusted": trusted,
        "message": trusted
            ? "Accessibility permission is granted."
            : "Accessibility permission has not been granted yet."
    ])
}

private func doctorCommand(delay: TimeInterval) {
    requireAccessibilityPermission()

    let focused = findFocusedTextArea(delay: delay)

    var response: [String: Any] = [
        "ok": true,
        "helperVersion": helperVersion,
        "role": stringAttribute(
            focused.element,
            kAXRoleAttribute as CFString
        ) ?? NSNull(),
        "focused": boolAttribute(
            focused.element,
            kAXFocusedAttribute as CFString
        ) ?? NSNull(),
        "valueReadable": true,
        "selectedTextRangeSettable": isAttributeSettable(
            focused.element,
            kAXSelectedTextRangeAttribute as CFString
        ),
        "textLength": focused.text.count,
        "utf16Length": utf16Length(focused.text),
        "accessibilityCharacterCount": integerAttribute(
            focused.element,
            kAXNumberOfCharactersAttribute as CFString
        ) ?? NSNull()
    ]

    for (key, value) in applicationMetadata(focused.application) {
        response[key] = value
    }

    writeJSON(response)
}

private func readCommand(delay: TimeInterval) {
    requireAccessibilityPermission()

    let focused = findFocusedTextArea(delay: delay)
    let pasteboard = NSPasteboard.general
    let clipboardSnapshots = captureClipboard(pasteboard)

    guard let serializedText = copyEntirePromptSerialized(
        from: focused.element,
        pasteboard: pasteboard
    ) else {
        let restoreResult = restoreClipboard(
            clipboardSnapshots,
            pasteboard: pasteboard,
            expectedTemporaryChangeCount: pasteboard.changeCount
        )

        fail(
            code: "prompt_copy_failed",
            message: """
            Could not copy the complete serialized Codex prompt. Ensure the \
            caret is inside the Codex composer.
            """,
            details: [
                "clipboardRestored": restoreResult.restored
            ]
        )
    }

    let serializedClipboardChangeCount = pasteboard.changeCount

    // Cmd+C leaves the complete prompt selected. Collapse the selection so
    // the composer remains safe and editable after this command.
    collapseSelectionToEnd()

    let clipboardResult = restoreClipboard(
        clipboardSnapshots,
        pasteboard: pasteboard,
        expectedTemporaryChangeCount:
            serializedClipboardChangeCount
    )

    var response: [String: Any] = [
        "ok": true,

        // `text` remains the primary field consumed by the TypeScript
        // extension. It now contains the canonical serialized form.
        "text": serializedText,
        "serializedText": serializedText,
        "renderedText": focused.text,

        "textLength": serializedText.count,
        "serializedTextLength": serializedText.count,
        "renderedTextLength": focused.text.count,

        "serializedUtf16Length": utf16Length(serializedText),
        "renderedUtf16Length": utf16Length(focused.text),

        "role": stringAttribute(
            focused.element,
            kAXRoleAttribute as CFString
        ) ?? NSNull(),

        "clipboardRestored": clipboardResult.restored,
        "clipboardRestoreSkippedBecauseChanged":
            clipboardResult.skippedBecauseChanged
    ]

    for (key, value) in applicationMetadata(focused.application) {
        response[key] = value
    }

    writeJSON(response)
}

private func replaceCommand(delay: TimeInterval) {
    requireAccessibilityPermission()

    let inputData = FileHandle.standardInput.readDataToEndOfFile()

    let request: ReplaceRequest

    do {
        request = try JSONDecoder().decode(
            ReplaceRequest.self,
            from: inputData
        )
    } catch {
        fail(
            code: "invalid_replace_request",
            message: """
            Replace expects JSON containing expectedOriginalText, \
            replacementText, and optional restoreClipboard.
            """,
            status: 64,
            details: [
                "decodeError": String(describing: error)
            ]
        )
    }

    guard !request.replacementText.isEmpty else {
        fail(
            code: "empty_replacement",
            message: "Replacement text must not be empty.",
            status: 64
        )
    }

    let focused = findFocusedTextArea(delay: delay)
    let pasteboard = NSPasteboard.general
    let clipboardSnapshots = captureClipboard(pasteboard)

    // AXValue is only the rendered projection and therefore cannot be
    // compared with the serialized Markdown prompt. Verify the canonical
    // prompt through Cursor's own copy pipeline instead.
    guard let copiedOriginalText = copyEntirePromptSerialized(
        from: focused.element,
        pasteboard: pasteboard
    ) else {
        let restoreResult = restoreClipboard(
            clipboardSnapshots,
            pasteboard: pasteboard,
            expectedTemporaryChangeCount: pasteboard.changeCount
        )

        fail(
            code: "original_prompt_copy_failed",
            message: """
            Could not copy the complete serialized Codex prompt. No \
            replacement was performed.
            """,
            details: [
                "clipboardRestored": restoreResult.restored
            ]
        )
    }

    guard copiedOriginalText == request.expectedOriginalText else {
        collapseSelectionToEnd()

        let restoreResult = restoreClipboard(
            clipboardSnapshots,
            pasteboard: pasteboard,
            expectedTemporaryChangeCount: pasteboard.changeCount
        )

        fail(
            code: "stale_prompt",
            message: """
            The serialized Codex prompt changed after it was read. The \
            replacement was cancelled to avoid overwriting newer text.
            """,
            details: [
                "expectedLength": request.expectedOriginalText.count,
                "copiedLength": copiedOriginalText.count,
                "expectedUtf16Length":
                    utf16Length(request.expectedOriginalText),
                "copiedUtf16Length":
                    utf16Length(copiedOriginalText),
                "clipboardRestored": restoreResult.restored
            ]
        )
    }

    // Cmd+C leaves the complete prompt selected. Replace the clipboard with
    // the enhanced serialized prompt and paste through Cursor's normal input
    // pipeline so Markdown references become clickable again.
    pasteboard.clearContents()

    guard pasteboard.setString(
        request.replacementText,
        forType: .string
    ) else {
        collapseSelectionToEnd()

        let restoreResult = restoreClipboard(
            clipboardSnapshots,
            pasteboard: pasteboard,
            expectedTemporaryChangeCount: pasteboard.changeCount
        )

        fail(
            code: "temporary_clipboard_write_failed",
            message: "Could not write replacement text to the clipboard.",
            details: [
                "clipboardRestored": restoreResult.restored
            ]
        )
    }

    postCommandV()

    // Allow the Codex composer to parse pasted Markdown references and
    // reconstruct its internal reference nodes.
    Thread.sleep(forTimeInterval: 0.3)

    // Verify through the same serialized copy representation used for reading.
    guard let copiedReplacementText = copyEntirePromptSerialized(
        from: focused.element,
        pasteboard: pasteboard
    ) else {
        collapseSelectionToEnd()

        let restoreResult = restoreClipboard(
            clipboardSnapshots,
            pasteboard: pasteboard,
            expectedTemporaryChangeCount: pasteboard.changeCount
        )

        fail(
            code: "replacement_copy_failed",
            message: """
            The replacement was pasted, but its serialized form could not be \
            copied for verification.
            """,
            details: [
                "clipboardRestored": restoreResult.restored
            ]
        )
    }

    let replacementVerified =
        copiedReplacementText == request.replacementText

    let verificationClipboardChangeCount = pasteboard.changeCount

    // Leave the caret at the end rather than leaving the complete prompt
    // selected after verification.
    collapseSelectionToEnd()

    let shouldRestoreClipboard = request.restoreClipboard ?? true

    let clipboardResult: ClipboardRestoreResult

    if shouldRestoreClipboard {
        clipboardResult = restoreClipboard(
            clipboardSnapshots,
            pasteboard: pasteboard,
            expectedTemporaryChangeCount:
                verificationClipboardChangeCount
        )
    } else {
        clipboardResult = ClipboardRestoreResult(
            restored: false,
            skippedBecauseChanged: false
        )
    }

    guard replacementVerified else {
        fail(
            code: "paste_verification_failed",
            message: """
            Cursor accepted the pasted prompt, but its serialized value did \
            not exactly match the requested replacement.
            """,
            details: [
                "expectedReplacementLength":
                    request.replacementText.count,
                "copiedReplacementLength":
                    copiedReplacementText.count,
                "expectedReplacementUtf16Length":
                    utf16Length(request.replacementText),
                "copiedReplacementUtf16Length":
                    utf16Length(copiedReplacementText),
                "clipboardRestored": clipboardResult.restored,
                "clipboardRestoreSkippedBecauseChanged":
                    clipboardResult.skippedBecauseChanged
            ]
        )
    }

    var response: [String: Any] = [
        "ok": true,
        "selectionMethod": "command-a-copy-serialized",
        "selectionVerified": true,
        "verificationMethod": "command-a-copy-serialized",
        "replacementVerified": true,
        "originalLength": copiedOriginalText.count,
        "replacementLength": request.replacementText.count,
        "clipboardRestored": clipboardResult.restored,
        "clipboardRestoreSkippedBecauseChanged":
            clipboardResult.skippedBecauseChanged
    ]

    for (key, value) in applicationMetadata(focused.application) {
        response[key] = value
    }

    writeJSON(response)
}

private func usage() -> Never {
    fail(
        code: "usage",
        message: """
        Usage:
          prompt-accessibility-helper version
          prompt-accessibility-helper permission
          prompt-accessibility-helper doctor [delay-seconds]
          prompt-accessibility-helper read [delay-seconds]
          prompt-accessibility-helper replace [delay-seconds]

        replace reads this JSON object from stdin:
          {
            "expectedOriginalText": "...",
            "replacementText": "...",
            "restoreClipboard": true
          }
        """,
        status: 64
    )
}

// MARK: - Entry point

let arguments = CommandLine.arguments

guard arguments.count >= 2 else {
    usage()
}

let command = arguments[1]
let delay = parseDelay(arguments)

switch command {
case "version":
    writeJSON([
        "ok": true,
        "version": helperVersion
    ])

case "permission":
    permissionCommand()

case "doctor":
    doctorCommand(delay: delay)

case "read":
    readCommand(delay: delay)

case "replace":
    replaceCommand(delay: delay)

default:
    usage()
}
