import Foundation
import AppKit
import ApplicationServices

// MARK: - Constants

private enum AXAttribute {
    static let focusedUIElement = "AXFocusedUIElement"
    static let role = "AXRole"
    static let subrole = "AXSubrole"
    static let title = "AXTitle"
    static let description = "AXDescription"
    static let identifier = "AXIdentifier"
    static let help = "AXHelp"
    static let value = "AXValue"
    static let parent = "AXParent"
    static let children = "AXChildren"
    static let enabled = "AXEnabled"
    static let focused = "AXFocused"
    static let selectedText = "AXSelectedText"
    static let selectedTextRange = "AXSelectedTextRange"
}

private let textRoles: Set<String> = [
    "AXTextArea",
    "AXTextField",
    "AXComboBox",
    "AXSearchField"
]

// MARK: - Models

private struct Candidate {
    let element: AXUIElement
    let origin: String
    let score: Int
    let role: String?
    let value: String
    let valueSettable: Bool
}

// MARK: - Basic utilities

private func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

private func printJSON(_ object: Any) {
    do {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )

        guard let output = String(data: data, encoding: .utf8) else {
            fail("Could not encode JSON output.")
        }

        print(output)
    } catch {
        fail("Could not serialize JSON: \(error)")
    }
}

private func preview(_ value: String, limit: Int = 240) -> String {
    let escaped = value
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\t", with: "\\t")

    guard escaped.count > limit else {
        return escaped
    }

    return String(escaped.prefix(limit)) + "…"
}

private func parseDelay(_ arguments: [String]) -> TimeInterval {
    guard arguments.count >= 3 else {
        return 0
    }

    guard let delay = TimeInterval(arguments[2]), delay >= 0 else {
        fail("Delay must be a non-negative number.")
    }

    return delay
}

private func waitIfNeeded(_ delay: TimeInterval) {
    guard delay > 0 else {
        return
    }

    FileHandle.standardError.write(
        Data("Waiting \(delay) seconds. Focus the Codex prompt field now…\n".utf8)
    )

    Thread.sleep(forTimeInterval: delay)
}

// MARK: - Accessibility permission

private func requestAccessibilityPermission() -> Bool {
    // The string is the value represented by kAXTrustedCheckOptionPrompt.
    let options = [
        "AXTrustedCheckOptionPrompt": true
    ] as CFDictionary

    return AXIsProcessTrustedWithOptions(options)
}

private func requireAccessibilityPermission() {
    guard AXIsProcessTrusted() else {
        fail(
            """
            Accessibility permission has not been granted.

            Open:
              System Settings → Privacy & Security → Accessibility

            Enable this probe, Terminal, or both, and then run the command again.
            """,
            code: 77
        )
    }
}

// MARK: - AX attribute access

private func copyAttribute(
    _ element: AXUIElement,
    _ attribute: String
) -> CFTypeRef? {
    var rawValue: CFTypeRef?

    let error = AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &rawValue
    )

    guard error == .success else {
        return nil
    }

    return rawValue
}

private func stringAttribute(
    _ element: AXUIElement,
    _ attribute: String
) -> String? {
    guard let rawValue = copyAttribute(element, attribute) else {
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
    _ attribute: String
) -> Bool? {
    copyAttribute(element, attribute) as? Bool
}

private func elementAttribute(
    _ element: AXUIElement,
    _ attribute: String
) -> AXUIElement? {
    guard let rawValue = copyAttribute(element, attribute) else {
        return nil
    }

    return rawValue as! AXUIElement
}

private func elementArrayAttribute(
    _ element: AXUIElement,
    _ attribute: String
) -> [AXUIElement] {
    guard let rawValue = copyAttribute(element, attribute) else {
        return []
    }

    return rawValue as? [AXUIElement] ?? []
}

private func attributeNames(_ element: AXUIElement) -> [String] {
    var rawNames: CFArray?

    let error = AXUIElementCopyAttributeNames(element, &rawNames)

    guard
        error == .success,
        let names = rawNames as? [String]
    else {
        return []
    }

    return names.sorted()
}

private func isAttributeSettable(
    _ element: AXUIElement,
    _ attribute: String
) -> Bool {
    var settable = DarwinBoolean(false)

    let error = AXUIElementIsAttributeSettable(
        element,
        attribute as CFString,
        &settable
    )

    return error == .success && settable.boolValue
}

// MARK: - Process and element information

private func processInformation(
    for element: AXUIElement
) -> [String: Any] {
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)

    var result: [String: Any] = [
        "pid": Int(pid)
    ]

    if let app = NSRunningApplication(processIdentifier: pid) {
        if let name = app.localizedName {
            result["appName"] = name
        }

        if let bundleIdentifier = app.bundleIdentifier {
            result["bundleIdentifier"] = bundleIdentifier
        }
    }

    return result
}

private func elementSummary(
    _ element: AXUIElement,
    includeAttributes: Bool = false
) -> [String: Any] {
    var result = processInformation(for: element)

    if let role = stringAttribute(element, AXAttribute.role) {
        result["role"] = role
    }

    if let subrole = stringAttribute(element, AXAttribute.subrole) {
        result["subrole"] = subrole
    }

    if let title = stringAttribute(element, AXAttribute.title), !title.isEmpty {
        result["title"] = title
    }

    if let description = stringAttribute(
        element,
        AXAttribute.description
    ), !description.isEmpty {
        result["description"] = description
    }

    if let identifier = stringAttribute(
        element,
        AXAttribute.identifier
    ), !identifier.isEmpty {
        result["identifier"] = identifier
    }

    if let help = stringAttribute(element, AXAttribute.help), !help.isEmpty {
        result["help"] = help
    }

    if let enabled = boolAttribute(element, AXAttribute.enabled) {
        result["enabled"] = enabled
    }

    if let focused = boolAttribute(element, AXAttribute.focused) {
        result["focused"] = focused
    }

    if let value = stringAttribute(element, AXAttribute.value) {
        result["valueLength"] = value.count
        result["valuePreview"] = preview(value)
    }

    result["valueSettable"] = isAttributeSettable(
        element,
        AXAttribute.value
    )

    result["selectedTextSettable"] = isAttributeSettable(
        element,
        AXAttribute.selectedText
    )

    result["selectedTextRangeSettable"] = isAttributeSettable(
        element,
        AXAttribute.selectedTextRange
    )

    if includeAttributes {
        result["attributes"] = attributeNames(element)
    }

    return result
}

// MARK: - Focused element discovery

private func focusedElement() -> AXUIElement {
    let maximumAttempts = 20
    let retryDelay: TimeInterval = 0.1
    var diagnostics: [String] = []

    for attempt in 1...maximumAttempts {
        // First try the system-wide focused accessibility element.
        let systemWideElement = AXUIElementCreateSystemWide()
        var rawFocusedElement: CFTypeRef?

        let systemWideError = AXUIElementCopyAttributeValue(
            systemWideElement,
            AXAttribute.focusedUIElement as CFString,
            &rawFocusedElement
        )

        if systemWideError == .success,
           let rawFocusedElement {
            return rawFocusedElement as! AXUIElement
        }

        diagnostics.append(
            "attempt \(attempt): system-wide AXError=\(systemWideError.rawValue)"
        )

        // Fall back to the focused element of the frontmost application.
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication {
            let applicationElement = AXUIElementCreateApplication(
                frontmostApplication.processIdentifier
            )

            rawFocusedElement = nil

            let applicationError = AXUIElementCopyAttributeValue(
                applicationElement,
                AXAttribute.focusedUIElement as CFString,
                &rawFocusedElement
            )

            if applicationError == .success,
               let rawFocusedElement {
                return rawFocusedElement as! AXUIElement
            }

            let applicationName =
                frontmostApplication.localizedName ?? "<unknown>"

            let bundleIdentifier =
                frontmostApplication.bundleIdentifier ?? "<unknown>"

            diagnostics.append(
                "attempt \(attempt): app=\(applicationName), " +
                "bundle=\(bundleIdentifier), " +
                "AXError=\(applicationError.rawValue)"
            )
        } else {
            diagnostics.append(
                "attempt \(attempt): no frontmost application"
            )
        }

        Thread.sleep(forTimeInterval: retryDelay)
    }

    let recentDiagnostics = diagnostics
        .suffix(12)
        .joined(separator: "\n  ")

    fail(
        """
        Could not obtain the focused accessibility element after \
        \(maximumAttempts) attempts.

        Recent diagnostics:
          \(recentDiagnostics)
        """
    )
}

private func parentChain(
    from focused: AXUIElement,
    maximumDepth: Int = 8
) -> [(element: AXUIElement, origin: String)] {
    var result: [(AXUIElement, String)] = []
    var current = focused

    for depth in 1...maximumDepth {
        guard let parent = elementAttribute(current, AXAttribute.parent) else {
            break
        }

        result.append((parent, "parent:\(depth)"))
        current = parent
    }

    return result
}

private func descendantElements(
    from root: AXUIElement,
    maximumDepth: Int = 4,
    maximumNodes: Int = 200
) -> [(element: AXUIElement, origin: String)] {
    var result: [(AXUIElement, String)] = []
    var queue: [(AXUIElement, Int, String)] = [(root, 0, "focused")]

    while !queue.isEmpty && result.count < maximumNodes {
        let (element, depth, path) = queue.removeFirst()

        guard depth < maximumDepth else {
            continue
        }

        for (index, child) in elementArrayAttribute(
            element,
            AXAttribute.children
        ).enumerated() {
            let childPath = "\(path)/child:\(index)"
            result.append((child, childPath))

            if result.count >= maximumNodes {
                break
            }

            queue.append((child, depth + 1, childPath))
        }
    }

    return result
}

private func nearbyElements(
    around focused: AXUIElement
) -> [(element: AXUIElement, origin: String)] {
    var result: [(AXUIElement, String)] = [
        (focused, "focused")
    ]

    result.append(contentsOf: parentChain(from: focused))

    // Inspect descendants of the focused element.
    result.append(contentsOf: descendantElements(from: focused))

    // Inspect immediate children of each parent. This may expose attachment
    // chips or a nested editable element next to the focused object.
    for parentEntry in parentChain(from: focused) {
        let children = elementArrayAttribute(
            parentEntry.element,
            AXAttribute.children
        )

        for (index, child) in children.prefix(40).enumerated() {
            result.append((
                child,
                "\(parentEntry.origin)/child:\(index)"
            ))
        }
    }

    return result
}

private func candidateScore(
    origin: String,
    role: String?,
    value: String,
    settable: Bool
) -> Int {
    var score = 0

    if origin == "focused" {
        score += 120
    }

    if settable {
        score += 100
    }

    if let role, textRoles.contains(role) {
        score += 80
    }

    if !value.isEmpty {
        score += 20
    }

    if role == "AXStaticText" {
        score -= 100
    }

    if role == "AXWebArea" {
        score -= 20
    }

    return score
}

private func editableCandidates(
    around focused: AXUIElement
) -> [Candidate] {
    nearbyElements(around: focused)
        .compactMap { entry -> Candidate? in
            guard let value = stringAttribute(
                entry.element,
                AXAttribute.value
            ) else {
                return nil
            }

            let role = stringAttribute(entry.element, AXAttribute.role)
            let settable = isAttributeSettable(
                entry.element,
                AXAttribute.value
            )

            return Candidate(
                element: entry.element,
                origin: entry.origin,
                score: candidateScore(
                    origin: entry.origin,
                    role: role,
                    value: value,
                    settable: settable
                ),
                role: role,
                value: value,
                valueSettable: settable
            )
        }
        .sorted { lhs, rhs in
            lhs.score > rhs.score
        }
}

private func bestCandidate(
    around focused: AXUIElement,
    requireSettable: Bool
) -> Candidate {
    let candidates = editableCandidates(around: focused)

    guard let candidate = candidates.first(where: {
        !requireSettable || $0.valueSettable
    }) else {
        fail(
            requireSettable
                ? "No writable text candidate was found near the focused element."
                : "No readable text candidate was found near the focused element."
        )
    }

    return candidate
}

private func ensureCursorOwnsElement(_ element: AXUIElement) {
    let process = processInformation(for: element)
    let appName = (process["appName"] as? String) ?? ""
    let bundleIdentifier = (process["bundleIdentifier"] as? String) ?? ""

    let looksLikeCursor =
        appName.localizedCaseInsensitiveContains("Cursor")
        || bundleIdentifier.localizedCaseInsensitiveContains("Cursor")

    guard looksLikeCursor else {
        fail(
            """
            Refusing to continue because the focused element does not appear \
            to belong to Cursor.

            Focused application:
              name: \(appName.isEmpty ? "<unknown>" : appName)
              bundle: \(bundleIdentifier.isEmpty ? "<unknown>" : bundleIdentifier)
            """
        )
    }
}

// MARK: - Commands

private func permissionCommand() {
    let trusted = requestAccessibilityPermission()

    printJSON([
        "trusted": trusted,
        "message": trusted
            ? "Accessibility permission is granted."
            : "Permission is not granted yet. Enable it in System Settings and run this command again."
    ])
}

private func inspectCommand(delay: TimeInterval) {
    requireAccessibilityPermission()
    waitIfNeeded(delay)

    let focused = focusedElement()
    let candidates = editableCandidates(around: focused)

    let parents = parentChain(from: focused).map { entry in
        var summary = elementSummary(entry.element)
        summary["origin"] = entry.origin
        return summary
    }

    let candidateOutput = candidates.prefix(25).map { candidate in
        var summary = elementSummary(candidate.element)
        summary["origin"] = candidate.origin
        summary["score"] = candidate.score
        return summary
    }

    let parentNeighborhoods = parentChain(
        from: focused,
        maximumDepth: 6
    ).map { entry -> [String: Any] in
        let children = elementArrayAttribute(
            entry.element,
            AXAttribute.children
        )
        .prefix(30)
        .enumerated()
        .map { index, child -> [String: Any] in
            var summary = elementSummary(child)
            summary["origin"] = "\(entry.origin)/child:\(index)"
            return summary
        }

        return [
            "origin": entry.origin,
            "element": elementSummary(entry.element),
            "children": children
        ]
    }

    printJSON([
        "trusted": true,
        "focused": elementSummary(
            focused,
            includeAttributes: true
        ),
        "parents": parents,
        "editableCandidates": candidateOutput,
        "parentNeighborhoods": parentNeighborhoods
    ])
}

private func readCommand(delay: TimeInterval) {
    requireAccessibilityPermission()
    waitIfNeeded(delay)

    let focused = focusedElement()
    ensureCursorOwnsElement(focused)

    let candidate = bestCandidate(
        around: focused,
        requireSettable: false
    )

    FileHandle.standardOutput.write(Data(candidate.value.utf8))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func replaceCommand(delay: TimeInterval) {
    requireAccessibilityPermission()

    let inputData = FileHandle.standardInput.readDataToEndOfFile()

    guard let replacement = String(data: inputData, encoding: .utf8) else {
        fail("Replacement input is not valid UTF-8.")
    }

    guard !replacement.isEmpty else {
        fail("Replacement text must not be empty.")
    }

    waitIfNeeded(delay)

    let focused = focusedElement()
    ensureCursorOwnsElement(focused)

    let candidate = bestCandidate(
        around: focused,
        requireSettable: true
    )

    let setError = AXUIElementSetAttributeValue(
        candidate.element,
        AXAttribute.value as CFString,
        replacement as CFString
    )

    guard setError == .success else {
        fail(
            "AXUIElementSetAttributeValue failed with AXError code \(setError.rawValue)."
        )
    }

    Thread.sleep(forTimeInterval: 0.15)

    let valueAfterReplacement = stringAttribute(
        candidate.element,
        AXAttribute.value
    )

    printJSON([
        "success": valueAfterReplacement == replacement,
        "origin": candidate.origin,
        "role": candidate.role ?? NSNull(),
        "valueSettable": candidate.valueSettable,
        "originalLength": candidate.value.count,
        "replacementLength": replacement.count,
        "readBackMatches": valueAfterReplacement == replacement
    ])
}

private func usage() -> Never {
    fail(
        """
        Usage:
          prompt-accessibility-probe permission
          prompt-accessibility-probe inspect [delay-seconds]
          prompt-accessibility-probe read [delay-seconds]
          prompt-accessibility-probe replace [delay-seconds]

        Examples:
          prompt-accessibility-probe permission
          prompt-accessibility-probe inspect 5
          prompt-accessibility-probe read 5
          printf '%s' 'Replacement text' | prompt-accessibility-probe replace 5
        """,
        code: 64
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
case "permission":
    permissionCommand()

case "inspect":
    inspectCommand(delay: delay)

case "read":
    readCommand(delay: delay)

case "replace":
    replaceCommand(delay: delay)

default:
    usage()
}
