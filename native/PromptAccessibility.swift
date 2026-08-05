import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

// MARK: - Constants

private let helperVersion = "__CODEX_PROMPT_ENHANCER_VERSION__"

private let knownCursorBundleIdentifiers: Set<String> = [
    "com.todesktop.230313mzl4w4u92"
]

private let selectAllKeyCode: CGKeyCode = 0   // Physical A key.
private let copyKeyCode: CGKeyCode = 8        // Physical C key.
private let pasteKeyCode: CGKeyCode = 9       // Physical V key.
private let undoKeyCode: CGKeyCode = 6        // Physical Z key.
private let rightArrowKeyCode: CGKeyCode = 124
private let focusAttempts = 20
private let focusRetryDelay: TimeInterval = 0.1
private let pasteVerificationTimeout: TimeInterval = 3.0
private let pasteApplicationTimeout: TimeInterval = 5.0
private let pasteApplicationPollDelay: TimeInterval = 0.05
private let pasteStableObservationCount = 3
private let maximumPasteChunkUtf16Length = 1_800
private let maximumPasteChunkCount = 32

// MARK: - Input models

private struct ReplaceRequest: Decodable {
    let expectedOriginalText: String
    let expectedTargetFingerprint: String
    let replacementText: String
    let replacementChunks: [PasteChunkRequest]
    let restoreClipboard: Bool?
}

private enum PasteChunkBoundaryKind: String, Decodable {
    case paragraph
    case line
    case whitespace
    case end
}

private struct PasteChunkRequest: Decodable {
    let text: String
    let boundaryKind: PasteChunkBoundaryKind
}

// MARK: - Internal models

private struct FocusedTextArea {
    let element: AXUIElement
    let application: NSRunningApplication
    let text: String
    let targetFingerprint: String
    let selectionMode: ComposerSelectionMode
}

private struct PasteboardRepresentation {
    let type: NSPasteboard.PasteboardType
    let data: Data
}

private struct PasteboardItemSnapshot {
    let representations: [PasteboardRepresentation]
}

private struct ClipboardCaptureResult {
    let snapshots: [PasteboardItemSnapshot]
    let statistics: ClipboardSnapshotStatistics
}

private struct HelperCommandError: Error {
    let code: String
    let message: String
    let status: Int32
    let details: [String: Any]

    init(
        code: String,
        message: String,
        status: Int32 = 1,
        details: [String: Any] = [:]
    ) {
        self.code = code
        self.message = message
        self.status = status
        self.details = details
    }
}

private struct PromptRollbackResult {
    let attempted: Bool
    let verified: Bool
    let undoCount: Int
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

private func fail(
    _ error: HelperCommandError,
    additionalDetails: [String: Any] = [:]
) -> Never {
    var details = error.details

    for (key, value) in additionalDetails {
        details[key] = value
    }

    fail(
        code: error.code,
        message: error.message,
        status: error.status,
        details: details
    )
}

// MARK: - Cooperative termination

private final class CooperativeSignalMonitor {
    private let terminationSource: DispatchSourceSignal
    private let interruptSource: DispatchSourceSignal

    init(state: TerminationRequestState) {
        Darwin.signal(SIGTERM, SIG_IGN)
        Darwin.signal(SIGINT, SIG_IGN)

        terminationSource = DispatchSource.makeSignalSource(
            signal: SIGTERM,
            queue: DispatchQueue.global(
                qos: .userInitiated
            )
        )
        interruptSource = DispatchSource.makeSignalSource(
            signal: SIGINT,
            queue: DispatchQueue.global(
                qos: .userInitiated
            )
        )

        terminationSource.setEventHandler {
            state.request(signal: SIGTERM)
        }
        interruptSource.setEventHandler {
            state.request(signal: SIGINT)
        }

        terminationSource.resume()
        interruptSource.resume()
    }
}

private let terminationRequestState =
    TerminationRequestState()
private let cooperativeSignalMonitor =
    CooperativeSignalMonitor(
        state: terminationRequestState
    )

private func terminationSignalName(
    _ signal: Int32
) -> String {
    switch signal {
    case SIGTERM:
        return "SIGTERM"
    case SIGINT:
        return "SIGINT"
    default:
        return "UNKNOWN"
    }
}

private func terminationCheckpoint() throws {
    guard
        let signal =
            terminationRequestState.currentSignal()
    else {
        return
    }

    throw HelperCommandError(
        code: "native_helper_terminated",
        message: """
        The native helper received a termination request and stopped safely.
        """,
        status: 128 + signal,
        details: [
            "signal": terminationSignalName(signal)
        ]
    )
}

private func interruptibleSleep(
    forTimeInterval interval: TimeInterval
) throws {
    let deadline = Date().addingTimeInterval(interval)

    while Date() < deadline {
        try terminationCheckpoint()

        Thread.sleep(
            forTimeInterval: min(
                0.025,
                max(
                    0,
                    deadline.timeIntervalSinceNow
                )
            )
        )
    }

    try terminationCheckpoint()
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
            Accessibility permission is not granted. Enable Cursor or the helper \
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
    let validation: ComposerValidationResult
}

private struct ComposerSemanticMetadata {
    let context: String
    let rolePath: [String]
    let identifiers: [String]
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

private func semanticMetadata(
    for element: AXUIElement,
    maximumDepth: Int = 7
) -> ComposerSemanticMetadata {
    let semanticAttributes: [CFString] = [
        "AXTitle" as CFString,
        "AXDescription" as CFString,
        "AXHelp" as CFString,
        "AXPlaceholderValue" as CFString
    ]
    let identifierAttributes: [CFString] = [
        "AXIdentifier" as CFString,
        "AXDOMIdentifier" as CFString
    ]

    var parts: [String] = []
    var rolePath: [String] = []
    var identifiers: [String] = []
    var current: AXUIElement? = element

    for depth in 0...maximumDepth {
        guard let currentElement = current else {
            break
        }

        if let role = stringAttribute(
            currentElement,
            kAXRoleAttribute as CFString
        ) {
            rolePath.append(role)
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

        for attribute in identifierAttributes {
            if
                let value = stringAttribute(
                    currentElement,
                    attribute
                ),
                !value.isEmpty
            {
                parts.append(value)
                identifiers.append(
                    "\(depth):\(attribute):\(value)"
                )
            }
        }

        current = elementAttribute(
            currentElement,
            kAXParentAttribute as CFString
        )
    }

    return ComposerSemanticMetadata(
        context: parts
            .joined(separator: " ")
            .lowercased(),
        rolePath: rolePath,
        identifiers: identifiers
    )
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

    let metadata = semanticMetadata(
        for: element
    )
    let context = metadata.context

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

    let validation = validateComposer(
        ComposerValidationInput(
            role: kAXTextAreaRole as String,
            valueReadable: true,
            selectionSettable: isAttributeSettable(
                element,
                kAXSelectedTextRangeAttribute as CFString
            ),
            enabled: boolAttribute(
                element,
                kAXEnabledAttribute as CFString
            ),
            semanticContext: context,
            frame: frame,
            windowFrame: windowFrame
        ),
        mode: .fallback
    )

    return ComposerCandidate(
        element: element,
        score: score,
        reasons: reasons,
        frame: frame,
        validation: validation
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
        "validation=\(candidate.validation.code)",
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

    let selection = selectComposerCandidate(
        candidates.map {
            ComposerCandidateRank(
                score: $0.score,
                isEligible: $0.validation.isEligible
            )
        },
        minimumScore: minimumComposerScore,
        minimumMargin: minimumComposerScoreMargin
    )

    switch selection {
    case .none:
        return (
            nil,
            [
                "no eligible Codex composer found; "
                    + "candidateCount="
                    + "\(candidates.count)"
            ] + diagnostics
        )

    case .ambiguous:
        return (
            nil,
            [
                "composer search was ambiguous"
            ] + diagnostics
        )

    case .selected(let index):
        return (
            candidates[index].element,
            diagnostics
        )
    }
}

private func focusedWindowElement(
    applicationElement: AXUIElement
) -> AXUIElement? {
    let result = copyAttribute(
        applicationElement,
        kAXFocusedWindowAttribute as CFString
    )

    guard
        result.error == .success,
        let rawValue = result.value,
        CFGetTypeID(rawValue)
            == AXUIElementGetTypeID()
    else {
        return nil
    }

    return (rawValue as! AXUIElement)
}

private func validatedFocusedTextArea(
    element: AXUIElement,
    application: NSRunningApplication,
    applicationElement: AXUIElement,
    text: String,
    selectionMode: ComposerSelectionMode
) -> FocusedTextArea {
    let metadata = semanticMetadata(
        for: element
    )
    let windowFrame = focusedWindowElement(
        applicationElement: applicationElement
    ).flatMap(elementFrame)
    let frame = elementFrame(element)
    let role = stringAttribute(
        element,
        kAXRoleAttribute as CFString
    ) ?? "<unknown>"
    let validation = validateComposer(
        ComposerValidationInput(
            role: role,
            valueReadable: true,
            selectionSettable: isAttributeSettable(
                element,
                kAXSelectedTextRangeAttribute as CFString
            ),
            enabled: boolAttribute(
                element,
                kAXEnabledAttribute as CFString
            ),
            semanticContext: metadata.context,
            frame: frame,
            windowFrame: windowFrame
        ),
        mode: selectionMode
    )

    guard validation.isEligible else {
        fail(
            code: selectionMode == .focused
                ? "codex_composer_not_focused"
                : "codex_composer_not_found",
            message: selectionMode == .focused
                ? "The focused text field is not the Codex composer."
                : "Could not safely validate the Codex composer.",
            details: [
                "selectionMode": selectionMode.rawValue,
                "validationCode": validation.code
            ]
        )
    }

    let targetFingerprint = makeComposerTargetFingerprint(
        ComposerTargetFingerprintInput(
            pid: Int(application.processIdentifier),
            windowFrame: windowFrame,
            elementFrame: frame,
            rolePath: metadata.rolePath,
            identifiers: metadata.identifiers,
            matchedSignals: validation.matchedSignals
        )
    )

    return FocusedTextArea(
        element: element,
        application: application,
        text: text,
        targetFingerprint: targetFingerprint,
        selectionMode: selectionMode
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

        let focusResolutionState: FocusResolutionState

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

                return validatedFocusedTextArea(
                    element: textArea,
                    application: application,
                    applicationElement: applicationElement,
                    text: text,
                    selectionMode: .focused
                )
            }

            let focusedRole =
                stringAttribute(
                    focusedElement,
                    kAXRoleAttribute
                        as CFString
                )
                ?? "<unknown>"

            fail(
                code: "codex_composer_not_focused",
                message: "The focused control is not the Codex composer.",
                details: [
                    "selectionMode": "focused",
                    "validationCode": "focused_element_not_text_area",
                    "role": focusedRole
                ]
            )
        } else {
            focusResolutionState = .unavailable
            diagnostics.append(
                "attempt \(attempt): "
                    + "AXFocusedUIElement error="
                    + String(
                        focusedResult.error.rawValue
                    )
            )
        }

        if
            shouldAttemptComposerFallback(
                after: focusResolutionState
            ),
            fallbackAttempts.contains(
            attempt
            )
        {
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

                return validatedFocusedTextArea(
                    element: textArea,
                    application: application,
                    applicationElement: applicationElement,
                    text: text,
                    selectionMode: .fallback
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
) throws {
    try terminationCheckpoint()

    if boolAttribute(
        textArea,
        kAXFocusedAttribute as CFString
    ) != true {
        guard isAttributeSettable(
            textArea,
            kAXFocusedAttribute as CFString
        ) else {
            throw HelperCommandError(
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
            throw HelperCommandError(
                code: "composer_focus_failed",
                message: "Could not focus the Codex composer.",
                details: [
                    "axError": error.rawValue
                ]
            )
        }
    }

    // Allow Chromium to synchronize the accessibility focus with its DOM.
    try interruptibleSleep(forTimeInterval: 0.1)

    guard boolAttribute(
        textArea,
        kAXFocusedAttribute as CFString
    ) == true else {
        throw HelperCommandError(
            code: "composer_focus_verification_failed",
            message: "The Codex composer did not retain focus."
        )
    }
}

// MARK: - Clipboard capture and restoration

private func captureClipboard(
    _ pasteboard: NSPasteboard
) throws -> ClipboardCaptureResult {
    guard let items = pasteboard.pasteboardItems else {
        return ClipboardCaptureResult(
            snapshots: [],
            statistics:
                ClipboardSnapshotStatistics(
                    bytes: 0,
                    items: 0,
                    representations: 0
                )
        )
    }

    var budget = ClipboardSnapshotBudget()
    var snapshots: [PasteboardItemSnapshot] = []

    for item in items {
        try budget.addItem()
        var representations: [PasteboardRepresentation] = []

        for type in item.types {
            try terminationCheckpoint()

            guard let data = item.data(forType: type) else {
                continue
            }

            try budget.addRepresentation(
                byteCount: data.count
            )

            representations.append(
                PasteboardRepresentation(
                    type: type,
                    data: data
                )
            )
        }

        if !representations.isEmpty {
            snapshots.append(
                PasteboardItemSnapshot(
                    representations: representations
                )
            )
        }
    }

    return ClipboardCaptureResult(
        snapshots: snapshots,
        statistics: budget.statistics
    )
}

private func restoreClipboardContents(
    _ snapshots: [PasteboardItemSnapshot],
    pasteboard: NSPasteboard
) -> Bool {
    pasteboard.clearContents()

    guard !snapshots.isEmpty else {
        return true
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
        return false
    }

    return pasteboard.writeObjects(restoredItems)
}

private final class ClipboardTransaction {
    let statistics: ClipboardSnapshotStatistics

    private let pasteboard: NSPasteboard
    private let snapshots: [PasteboardItemSnapshot]
    private let coordinator =
        ClipboardTransactionCoordinator()

    init(pasteboard: NSPasteboard) throws {
        self.pasteboard = pasteboard

        do {
            let capture = try captureClipboard(
                pasteboard
            )
            snapshots = capture.snapshots
            statistics = capture.statistics
        } catch let error as ClipboardSnapshotLimitError {
            throw HelperCommandError(
                code: "clipboard_snapshot_limit_exceeded",
                message: """
                Clipboard contents are too large to preserve safely. Nothing \
                was changed.
                """,
                details: clipboardSnapshotDiagnostics(
                    error.statistics
                )
            )
        }
    }

    func recordTemporaryChange() {
        coordinator.recordTemporaryChange(
            changeCount: pasteboard.changeCount
        )
    }

    func requireTemporaryOwnership() throws {
        guard coordinator.ownsTemporaryState(
            currentChangeCount:
                pasteboard.changeCount
        ) else {
            throw HelperCommandError(
                code: "clipboard_changed_during_operation",
                message: """
                The clipboard changed while the native helper was using it. \
                The operation stopped without overwriting the newer \
                clipboard contents.
                """
            )
        }
    }

    func finish(
        shouldRestore: Bool = true
    ) -> ClipboardRestoreResult {
        coordinator.finish(
            currentChangeCount:
                pasteboard.changeCount,
            shouldRestore: shouldRestore
        ) {
            restoreClipboardContents(
                snapshots,
                pasteboard: pasteboard
            )
        }
    }

    var diagnostics: [String: Any] {
        clipboardSnapshotDiagnostics(
            statistics
        )
    }
}

private func clipboardSnapshotDiagnostics(
    _ statistics: ClipboardSnapshotStatistics
) -> [String: Any] {
    [
        "clipboardSnapshotBytes":
            statistics.bytes,
        "clipboardSnapshotItems":
            statistics.items,
        "clipboardSnapshotRepresentations":
            statistics.representations,
        "clipboardSnapshotMaximumBytes":
            clipboardSnapshotMaximumBytes,
        "clipboardSnapshotMaximumItems":
            clipboardSnapshotMaximumItems,
        "clipboardSnapshotMaximumRepresentations":
            clipboardSnapshotMaximumRepresentations
    ]
}

private func finishClipboardTransaction(
    _ transaction: ClipboardTransaction,
    shouldRestore: Bool = true
) -> (
    result: ClipboardRestoreResult,
    details: [String: Any]
) {
    let result = transaction.finish(
        shouldRestore: shouldRestore
    )
    var details = transaction.diagnostics
    details["clipboardRestored"] =
        result.restored
    details[
        "clipboardRestoreSkippedBecauseChanged"
    ] = result.skippedBecauseChanged
    return (result, details)
}

private func fail(
    _ error: HelperCommandError,
    afterFinishing transaction:
        ClipboardTransaction,
    additionalDetails: [String: Any] = [:]
) -> Never {
    let cleanup = finishClipboardTransaction(
        transaction
    )
    var details = cleanup.details

    for (key, value) in additionalDetails {
        details[key] = value
    }

    fail(
        error,
        additionalDetails: details
    )
}

// MARK: - Keyboard events

private func postKey(
    _ keyCode: CGKeyCode,
    flags: CGEventFlags
) throws {
    try terminationCheckpoint()

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
        throw HelperCommandError(
            code: "keyboard_event_creation_failed",
            message: "Could not create a synthetic keyboard event."
        )
    }

    keyDown.flags = flags
    keyUp.flags = flags

    keyDown.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.025)
    keyUp.post(tap: .cghidEventTap)
    try terminationCheckpoint()
}

private func postCommandKey(
    _ keyCode: CGKeyCode
) throws {
    try postKey(
        keyCode,
        flags: .maskCommand
    )
}

private func postCommandA() throws {
    try postCommandKey(selectAllKeyCode)
}

private func postCommandC() throws {
    try postCommandKey(copyKeyCode)
}

private func postCommandV() throws {
    try postCommandKey(pasteKeyCode)
}

private func postCommandZ() throws {
    try postCommandKey(undoKeyCode)
}

private func collapseSelectionToEnd() throws {
    try postKey(
        rightArrowKeyCode,
        flags: CGEventFlags(rawValue: 0)
    )

    try interruptibleSleep(
        forTimeInterval: 0.05
    )
}

private func placeCaretAtComposerEnd(
    _ textArea: AXUIElement
) throws {
    try terminationCheckpoint()

    let characterCount = integerAttribute(
        textArea,
        kAXNumberOfCharactersAttribute as CFString
    ) ?? utf16Length(
        stringAttribute(
            textArea,
            kAXValueAttribute as CFString
        ) ?? ""
    )
    var range = CFRange(
        location: characterCount,
        length: 0
    )

    guard let rangeValue = AXValueCreate(
        .cfRange,
        &range
    ) else {
        throw HelperCommandError(
            code: "composer_caret_position_failed",
            message: "Could not position the Codex composer caret safely."
        )
    }

    let error = AXUIElementSetAttributeValue(
        textArea,
        kAXSelectedTextRangeAttribute as CFString,
        rangeValue
    )

    guard error == .success else {
        throw HelperCommandError(
            code: "composer_caret_position_failed",
            message: "Could not position the Codex composer caret safely.",
            details: [
                "axError": error.rawValue
            ]
        )
    }

    try interruptibleSleep(
        forTimeInterval: 0.05
    )
}

private func waitForClipboardCopy(
    pasteboard: NSPasteboard,
    previousChangeCount: Int,
    transaction: ClipboardTransaction,
    timeout: TimeInterval = 1.5
) throws -> String? {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
        try terminationCheckpoint()

        if
            pasteboard.changeCount != previousChangeCount,
            let value = pasteboard.string(forType: .string)
        {
            transaction.recordTemporaryChange()
            return value
        }

        try interruptibleSleep(
            forTimeInterval: 0.025
        )
    }

    try terminationCheckpoint()
    return nil
}

private func copyEntirePromptSerialized(
    from textArea: AXUIElement,
    pasteboard: NSPasteboard,
    transaction: ClipboardTransaction
) throws -> String? {
    try terminationCheckpoint()
    try focusTextArea(textArea)

    try postCommandA()
    try interruptibleSleep(
        forTimeInterval: 0.12
    )

    try terminationCheckpoint()
    try transaction.requireTemporaryOwnership()
    pasteboard.clearContents()
    transaction.recordTemporaryChange()
    try terminationCheckpoint()

    let sentinel =
        "__CODEX_PROMPT_COPY_SENTINEL_\(UUID().uuidString)__"

    try transaction.requireTemporaryOwnership()
    guard pasteboard.setString(
        sentinel,
        forType: .string
    ) else {
        return nil
    }
    transaction.recordTemporaryChange()
    try terminationCheckpoint()

    let sentinelChangeCount = pasteboard.changeCount

    try postCommandC()

    return try waitForClipboardCopy(
        pasteboard: pasteboard,
        previousChangeCount: sentinelChangeCount,
        transaction: transaction
    )
}

// MARK: - Paste verification

private func waitForReplacement(
    in textArea: AXUIElement,
    expectedText: String
) throws -> Bool {
    let deadline = Date().addingTimeInterval(
        pasteVerificationTimeout
    )

    while Date() < deadline {
        try terminationCheckpoint()

        if stringAttribute(
            textArea,
            kAXValueAttribute as CFString
        ) == expectedText {
            return true
        }

        try interruptibleSleep(
            forTimeInterval: 0.05
        )
    }

    return false
}

private struct PasteApplicationWaitResult {
    let observedChange: Bool
    let stabilized: Bool
}

private struct PasteChunksResult {
    let observedChange: Bool
    let stabilized: Bool
}

private func waitForPasteApplication(
    in textArea: AXUIElement,
    originalRenderedText: String
) throws -> PasteApplicationWaitResult {
    let deadline = Date().addingTimeInterval(
        pasteApplicationTimeout
    )
    var tracker = PasteApplicationTracker(
        originalValue: originalRenderedText,
        requiredStableObservations:
            pasteStableObservationCount
    )

    while Date() < deadline {
        try terminationCheckpoint()

        let currentValue = stringAttribute(
            textArea,
            kAXValueAttribute as CFString
        )

        if tracker.observe(currentValue) {
            return PasteApplicationWaitResult(
                observedChange: true,
                stabilized: true
            )
        }

        try interruptibleSleep(
            forTimeInterval:
                pasteApplicationPollDelay
        )
    }

    try terminationCheckpoint()

    return PasteApplicationWaitResult(
        observedChange: tracker.observedChange,
        stabilized: false
    )
}

private func validatePasteChunks(
    _ chunks: [PasteChunkRequest],
    expectedText: String
) -> [PasteChunkRequest] {
    guard
        !chunks.isEmpty,
        chunks.count <= maximumPasteChunkCount,
        chunks.allSatisfy({
            !$0.text.isEmpty
                && utf16Length($0.text)
                    <= maximumPasteChunkUtf16Length
        }),
        chunks.map(\.text).joined() == expectedText,
        chunks.last?.boundaryKind == .end,
        chunks.dropLast().allSatisfy({
            $0.boundaryKind != .end
        })
    else {
        fail(
            code: "invalid_replace_request",
            message: """
            Replace received invalid serialized paste chunks.
            """,
            status: 64,
            details: [
                "pasteChunkCount": chunks.count,
                "pasteChunkMaximumUtf16Length":
                    maximumPasteChunkUtf16Length
            ]
        )
    }

    return chunks
}

private func pasteSerializedChunks(
    _ chunks: [PasteChunkRequest],
    into textArea: AXUIElement,
    initialRenderedText: String,
    pasteboard: NSPasteboard,
    transaction: ClipboardTransaction,
    undoTracker: inout PasteUndoTracker
) throws -> PasteChunksResult {
    var previousRenderedText = initialRenderedText
    var allChunksStabilized = true

    for (index, chunk) in chunks.enumerated() {
        try terminationCheckpoint()
        try transaction.requireTemporaryOwnership()
        pasteboard.clearContents()
        transaction.recordTemporaryChange()
        try terminationCheckpoint()
        try transaction.requireTemporaryOwnership()

        guard pasteboard.setString(
            chunk.text,
            forType: .string
        ) else {
            throw HelperCommandError(
                code: "temporary_clipboard_write_failed",
                message: """
                Could not write a replacement chunk to the clipboard.
                """,
                details: [
                    "pasteChunkIndex": index + 1,
                    "pasteChunkCount": chunks.count,
                    "pasteChunkBoundaryKind":
                        chunk.boundaryKind.rawValue
                ]
            )
        }

        transaction.recordTemporaryChange()
        try terminationCheckpoint()
        try transaction.requireTemporaryOwnership()
        try postCommandV()
        undoTracker.recordPasteEvent()

        let application =
            try waitForPasteApplication(
                in: textArea,
                originalRenderedText:
                    previousRenderedText
            )

        guard application.observedChange else {
            throw HelperCommandError(
                code: "paste_chunk_not_applied",
                message: """
                Cursor did not apply a serialized prompt chunk as text.
                """,
                details: [
                    "pasteChunkIndex": index + 1,
                    "pasteChunkCount": chunks.count,
                    "pasteChunkUtf16Length":
                        utf16Length(chunk.text),
                    "pasteChunkBoundaryKind":
                        chunk.boundaryKind.rawValue,
                    "pasteApplicationChangeObserved": false,
                    "pasteApplicationStabilized": false,
                    "pasteApplicationTimeoutMilliseconds":
                        Int(
                            pasteApplicationTimeout
                                * 1_000
                        )
                ]
            )
        }

        allChunksStabilized =
            allChunksStabilized
                && application.stabilized

        previousRenderedText = stringAttribute(
            textArea,
            kAXValueAttribute as CFString
        ) ?? previousRenderedText
        undoTracker.recordObservedRenderedValue(
            previousRenderedText
        )

        try placeCaretAtComposerEnd(textArea)
    }

    return PasteChunksResult(
        observedChange: true,
        stabilized: allChunksStabilized
    )
}

private func isSameFocusedTextArea(
    _ focused: FocusedTextArea
) -> Bool {
    let applicationElement = AXUIElementCreateApplication(
        focused.application.processIdentifier
    )
    let focusedResult = copyAttribute(
        applicationElement,
        kAXFocusedUIElementAttribute as CFString
    )

    guard
        focusedResult.error == .success,
        let rawElement = focusedResult.value,
        CFGetTypeID(rawElement)
            == AXUIElementGetTypeID()
    else {
        return false
    }

    let focusedElement = rawElement as! AXUIElement

    guard let textArea = nearestWritableTextArea(
        from: focusedElement
    ) else {
        return false
    }

    return CFEqual(textArea, focused.element)
}

private func undoReplacement(
    expectedOriginalText: String,
    originalRenderedText: String,
    focused: FocusedTextArea,
    pasteboard: NSPasteboard,
    transaction: ClipboardTransaction,
    undoTracker: inout PasteUndoTracker
) -> PromptRollbackResult {
    guard undoTracker.pasteEventsIssued > 0 else {
        return PromptRollbackResult(
            attempted: false,
            verified: true,
            undoCount: 0,
            skippedBecauseChanged: false
        )
    }

    let currentRenderedText = stringAttribute(
        focused.element,
        kAXValueAttribute as CFString
    )

    guard undoTracker.mayBeginRollback(
        sameTarget: isSameFocusedTextArea(focused),
        currentRenderedValue: currentRenderedText
    ) else {
        return PromptRollbackResult(
            attempted: false,
            verified: false,
            undoCount: undoTracker.undoCount,
            skippedBecauseChanged: true
        )
    }

    var expectedRenderedText = currentRenderedText

    do {
        while undoTracker.canUndo {
            guard
                isSameFocusedTextArea(focused),
                stringAttribute(
                    focused.element,
                    kAXValueAttribute as CFString
                ) == expectedRenderedText
            else {
                return PromptRollbackResult(
                    attempted: undoTracker.undoCount > 0,
                    verified: false,
                    undoCount: undoTracker.undoCount,
                    skippedBecauseChanged: true
                )
            }

            let beforeUndo = expectedRenderedText ?? ""
            try postCommandZ()
            _ = undoTracker.recordUndo()

            _ = try waitForPasteApplication(
                in: focused.element,
                originalRenderedText: beforeUndo
            )

            expectedRenderedText = stringAttribute(
                focused.element,
                kAXValueAttribute as CFString
            )

            guard expectedRenderedText == originalRenderedText else {
                continue
            }

            guard let copiedText =
                try copyEntirePromptSerialized(
                    from: focused.element,
                    pasteboard: pasteboard,
                    transaction: transaction
                )
            else {
                return PromptRollbackResult(
                    attempted: true,
                    verified: false,
                    undoCount: undoTracker.undoCount,
                    skippedBecauseChanged: false
                )
            }

            try collapseSelectionToEnd()

            return PromptRollbackResult(
                attempted: true,
                verified: copiedText == expectedOriginalText,
                undoCount: undoTracker.undoCount,
                skippedBecauseChanged: false
            )
        }

        return PromptRollbackResult(
            attempted: undoTracker.undoCount > 0,
            verified: false,
            undoCount: undoTracker.undoCount,
            skippedBecauseChanged: false
        )
    } catch {
        return PromptRollbackResult(
            attempted: undoTracker.undoCount > 0,
            verified: false,
            undoCount: undoTracker.undoCount,
            skippedBecauseChanged: false
        )
    }
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
        "selectionMode": focused.selectionMode.rawValue,
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
    let transaction: ClipboardTransaction

    do {
        transaction = try ClipboardTransaction(
            pasteboard: pasteboard
        )
    } catch let error as HelperCommandError {
        fail(error)
    } catch {
        fail(
            code: "clipboard_snapshot_failed",
            message: "Could not preserve the clipboard safely."
        )
    }

    do {
        guard let serializedText =
            try copyEntirePromptSerialized(
                from: focused.element,
                pasteboard: pasteboard,
                transaction: transaction
            )
        else {
            throw HelperCommandError(
                code: "prompt_copy_failed",
                message: """
                Could not copy the complete serialized Codex prompt. Ensure \
                the caret is inside the Codex composer.
                """
            )
        }

        // Cmd+C leaves the complete prompt selected. Collapse the selection
        // so the composer remains safe and editable after this command.
        try collapseSelectionToEnd()

        let cleanup = finishClipboardTransaction(
            transaction
        )

        var response: [String: Any] = [
            "ok": true,

            // `text` remains the primary field consumed by the TypeScript
            // extension. It now contains the canonical serialized form.
            "text": serializedText,
            "serializedText": serializedText,
            "renderedText": focused.text,
            "targetFingerprint": focused.targetFingerprint,
            "selectionMode": focused.selectionMode.rawValue,

            "textLength": serializedText.count,
            "serializedTextLength": serializedText.count,
            "renderedTextLength": focused.text.count,

            "serializedUtf16Length": utf16Length(serializedText),
            "renderedUtf16Length": utf16Length(focused.text),

            "role": stringAttribute(
                focused.element,
                kAXRoleAttribute as CFString
            ) ?? NSNull()
        ]

        for (key, value) in cleanup.details {
            response[key] = value
        }

        for (key, value) in applicationMetadata(focused.application) {
            response[key] = value
        }

        writeJSON(response)
    } catch let error as HelperCommandError {
        fail(
            error,
            afterFinishing: transaction
        )
    } catch {
        fail(
            HelperCommandError(
                code: "native_helper_failed",
                message: "The native helper failed safely."
            ),
            afterFinishing: transaction
        )
    }
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
            expectedTargetFingerprint, replacementText, replacementChunks, \
            and optional restoreClipboard.
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

    let replacementChunks =
        validatePasteChunks(
            request.replacementChunks,
            expectedText: request.replacementText
        )

    let focused = findFocusedTextArea(delay: delay)
    var undoTracker = PasteUndoTracker(
        initialRenderedValue: focused.text
    )

    guard
        focused.targetFingerprint
            == request.expectedTargetFingerprint
    else {
        fail(
            code: "composer_target_changed",
            message: """
            The validated Codex composer changed after it was read. No \
            clipboard access or replacement was performed.
            """,
            details: [
                "selectionMode": focused.selectionMode.rawValue,
                "validationCode": "target_fingerprint_mismatch"
            ]
        )
    }

    let pasteboard = NSPasteboard.general
    let transaction: ClipboardTransaction

    do {
        transaction = try ClipboardTransaction(
            pasteboard: pasteboard
        )
    } catch let error as HelperCommandError {
        fail(error)
    } catch {
        fail(
            code: "clipboard_snapshot_failed",
            message: "Could not preserve the clipboard safely."
        )
    }

    do {
        // AXValue is only the rendered projection and therefore cannot be
        // compared with the serialized Markdown prompt. Verify the canonical
        // prompt through Cursor's own copy pipeline instead.
        guard let copiedOriginalText =
            try copyEntirePromptSerialized(
                from: focused.element,
                pasteboard: pasteboard,
                transaction: transaction
            )
        else {
            throw HelperCommandError(
                code: "original_prompt_copy_failed",
                message: """
                Could not copy the complete serialized Codex prompt. No \
                replacement was performed.
                """
            )
        }

        guard
            copiedOriginalText
                == request.expectedOriginalText
        else {
            try collapseSelectionToEnd()

            throw HelperCommandError(
                code: "stale_prompt",
                message: """
                The serialized Codex prompt changed after it was read. The \
                replacement was cancelled to avoid overwriting newer text.
                """,
                details: [
                    "expectedLength":
                        request.expectedOriginalText.count,
                    "copiedLength":
                        copiedOriginalText.count,
                    "expectedUtf16Length":
                        utf16Length(
                            request.expectedOriginalText
                        ),
                    "copiedUtf16Length":
                        utf16Length(copiedOriginalText)
                ]
            )
        }

        // Cmd+C leaves the complete prompt selected. Paste bounded chunks so
        // Cursor keeps long content in the text field instead of converting
        // one large paste into a text-file attachment. Local Markdown
        // references remain atomic within their chunks.
        let pasteApplication =
            try pasteSerializedChunks(
                replacementChunks,
                into: focused.element,
                initialRenderedText: focused.text,
                pasteboard: pasteboard,
                transaction: transaction,
                undoTracker: &undoTracker
            )

        try interruptibleSleep(
            forTimeInterval:
                pasteApplicationPollDelay
        )

        // Verify through the same serialized copy representation used for
        // reading.
        guard let copiedReplacementText =
            try copyEntirePromptSerialized(
                from: focused.element,
                pasteboard: pasteboard,
                transaction: transaction
            )
        else {
            try collapseSelectionToEnd()

            throw HelperCommandError(
                code: "replacement_copy_failed",
                message: """
                The replacement was pasted, but its serialized form could \
                not be copied for verification.
                """
            )
        }

        let verification = verifySerializedPrompt(
            expected: request.replacementText,
            actual: copiedReplacementText
        )

        // Leave the caret at the end rather than leaving the complete prompt
        // selected after verification.
        try collapseSelectionToEnd()

        guard let verification else {
            let pasteWasNotApplied =
                copiedReplacementText
                    == request.expectedOriginalText

            throw HelperCommandError(
                code: pasteWasNotApplied
                    ? "paste_not_applied"
                    : "paste_verification_failed",
                message: pasteWasNotApplied
                    ? """
                    Cursor did not apply the enhanced prompt before \
                    verification. The original prompt was preserved.
                    """
                    : """
                    Cursor applied a prompt whose serialized value did not \
                    match the requested replacement safely.
                    """,
                details: [
                    "expectedReplacementLength":
                        request.replacementText.count,
                    "copiedReplacementLength":
                        copiedReplacementText.count,
                    "expectedReplacementUtf16Length":
                        utf16Length(
                            request.replacementText
                        ),
                    "copiedReplacementUtf16Length":
                        utf16Length(
                            copiedReplacementText
                        ),
                    "pasteApplicationChangeObserved":
                        pasteApplication.observedChange,
                    "pasteApplicationStabilized":
                        pasteApplication.stabilized,
                    "pasteApplicationTimeoutMilliseconds":
                        Int(
                            pasteApplicationTimeout
                                * 1_000
                        ),
                    "pasteChunkCount":
                        replacementChunks.count,
                    "pasteEventsIssued":
                        undoTracker.pasteEventsIssued,
                    "verificationMode": "mismatch"
                ]
            )
        }

        let cleanup = finishClipboardTransaction(
            transaction,
            shouldRestore:
                request.restoreClipboard ?? true
        )

        var response: [String: Any] = [
            "ok": true,
            "selectionMethod":
                "command-a-copy-serialized",
            "selectionVerified": true,
            "verificationMethod":
                "command-a-copy-serialized",
            "replacementVerified": true,
            "selectionMode":
                focused.selectionMode.rawValue,
            "originalLength":
                copiedOriginalText.count,
            "replacementLength":
                request.replacementText.count,
            "pasteChunkCount":
                replacementChunks.count,
            "pasteEventsIssued":
                undoTracker.pasteEventsIssued,
            "verificationMode":
                verification.mode.rawValue,
            "referenceWhitespaceNormalizationCount":
                verification.referenceWhitespaceNormalizationCount
        ]

        for (key, value) in cleanup.details {
            response[key] = value
        }

        for (key, value) in applicationMetadata(focused.application) {
            response[key] = value
        }

        writeJSON(response)
    } catch let error as HelperCommandError {
        let rollback = error.code
            == "native_helper_terminated"
            ? PromptRollbackResult(
                attempted: false,
                verified:
                    undoTracker.pasteEventsIssued == 0,
                undoCount: 0,
                skippedBecauseChanged:
                    undoTracker.pasteEventsIssued > 0
            )
            : undoReplacement(
                expectedOriginalText:
                    request.expectedOriginalText,
                originalRenderedText: focused.text,
                focused: focused,
                pasteboard: pasteboard,
                transaction: transaction,
                undoTracker: &undoTracker
            )

        fail(
            error,
            afterFinishing: transaction,
            additionalDetails: [
                "promptRollbackAttempted":
                    rollback.attempted,
                "promptRollbackVerified":
                    rollback.verified,
                "promptRollbackUndoCount":
                    rollback.undoCount,
                "promptRollbackSkippedBecauseChanged":
                    rollback.skippedBecauseChanged,
                "pasteEventsIssued":
                    undoTracker.pasteEventsIssued
            ]
        )
    } catch {
        let rollback = undoReplacement(
            expectedOriginalText:
                request.expectedOriginalText,
            originalRenderedText: focused.text,
            focused: focused,
            pasteboard: pasteboard,
            transaction: transaction,
            undoTracker: &undoTracker
        )

        fail(
            HelperCommandError(
                code: "native_helper_failed",
                message: "The native helper failed safely."
            ),
            afterFinishing: transaction,
            additionalDetails: [
                "promptRollbackAttempted":
                    rollback.attempted,
                "promptRollbackVerified":
                    rollback.verified,
                "promptRollbackUndoCount":
                    rollback.undoCount,
                "promptRollbackSkippedBecauseChanged":
                    rollback.skippedBecauseChanged,
                "pasteEventsIssued":
                    undoTracker.pasteEventsIssued
            ]
        )
    }
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
            "expectedTargetFingerprint": "...",
            "replacementText": "...",
            "replacementChunks": [
              {"text": "...", "boundaryKind": "end"}
            ],
            "restoreClipboard": true
          }
        """,
        status: 64
    )
}

// MARK: - Entry point

_ = cooperativeSignalMonitor

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
