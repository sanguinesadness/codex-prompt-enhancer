import AppKit
import ApplicationServices
import Foundation

private let maximumNodes = 5_000
private let maximumDepth = 28
private let maximumResults = 300

private struct QueueEntry {
    let element: AXUIElement
    let depth: Int
}

private func copyAttribute(
    _ element: AXUIElement,
    _ attribute: CFString
) -> CFTypeRef? {
    var value: CFTypeRef?

    let error = AXUIElementCopyAttributeValue(
        element,
        attribute,
        &value
    )

    guard error == .success else {
        return nil
    }

    return value
}

private func stringAttribute(
    _ element: AXUIElement,
    _ attribute: CFString
) -> String? {
    guard let value = copyAttribute(
        element,
        attribute
    ) else {
        return nil
    }

    if let string = value as? String {
        return string
    }

    if let url = value as? URL {
        return url.absoluteString
    }

    return nil
}

private func elementAttribute(
    _ element: AXUIElement,
    _ attribute: CFString
) -> AXUIElement? {
    guard let value = copyAttribute(
        element,
        attribute
    ) else {
        return nil
    }

    guard
        CFGetTypeID(value)
            == AXUIElementGetTypeID()
    else {
        return nil
    }

    return unsafeBitCast(
        value,
        to: AXUIElement.self
    )
}

private func elementArrayAttribute(
    _ element: AXUIElement,
    _ attribute: CFString
) -> [AXUIElement] {
    guard let value = copyAttribute(
        element,
        attribute
    ) else {
        return []
    }

    return value as? [AXUIElement] ?? []
}

private func pointAttribute(
    _ element: AXUIElement,
    _ attribute: CFString
) -> CGPoint? {
    guard let value = copyAttribute(
        element,
        attribute
    ) else {
        return nil
    }

    guard
        CFGetTypeID(value)
            == AXValueGetTypeID()
    else {
        return nil
    }

    let axValue = unsafeBitCast(
        value,
        to: AXValue.self
    )

    guard AXValueGetType(axValue) == .cgPoint else {
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
    guard let value = copyAttribute(
        element,
        attribute
    ) else {
        return nil
    }

    guard
        CFGetTypeID(value)
            == AXValueGetTypeID()
    else {
        return nil
    }

    let axValue = unsafeBitCast(
        value,
        to: AXValue.self
    )

    guard AXValueGetType(axValue) == .cgSize else {
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

private func frame(
    of element: AXUIElement
) -> CGRect? {
    guard
        let position = pointAttribute(
            element,
            "AXPosition" as CFString
        ),
        let size = sizeAttribute(
            element,
            "AXSize" as CFString
        )
    else {
        return nil
    }

    return CGRect(
        origin: position,
        size: size
    )
}

private func nearestTextArea(
    from focusedElement: AXUIElement
) -> AXUIElement? {
    var current: AXUIElement? =
        focusedElement

    for _ in 0..<8 {
        guard let element = current else {
            return nil
        }

        if stringAttribute(
            element,
            "AXRole" as CFString
        ) == "AXTextArea" {
            return element
        }

        current = elementAttribute(
            element,
            "AXParent" as CFString
        )
    }

    return nil
}

private func traversalChildren(
    of element: AXUIElement
) -> [AXUIElement] {
    let attributes: [CFString] = [
        "AXChildren" as CFString,
        "AXContents" as CFString,
        "AXVisibleChildren" as CFString
    ]

    var result: [AXUIElement] = []
    var seen = Set<CFHashCode>()

    for attribute in attributes {
        for child in elementArrayAttribute(
            element,
            attribute
        ) {
            let hash = CFHash(child)

            if seen.insert(hash).inserted {
                result.append(child)
            }
        }
    }

    return result
}

private func truncated(
    _ value: String,
    maximumLength: Int = 600
) -> String {
    if value.count <= maximumLength {
        return value
    }

    return String(
        value.prefix(maximumLength)
    ) + "…"
}

private func metadata(
    for element: AXUIElement,
    redactValue: Bool
) -> [String: String] {
    let attributes: [
        (name: String, attribute: CFString)
    ] = [
        ("role", "AXRole" as CFString),
        ("subrole", "AXSubrole" as CFString),
        (
            "roleDescription",
            "AXRoleDescription" as CFString
        ),
        ("title", "AXTitle" as CFString),
        (
            "description",
            "AXDescription" as CFString
        ),
        (
            "identifier",
            "AXIdentifier" as CFString
        ),
        (
            "domIdentifier",
            "AXDOMIdentifier" as CFString
        ),
        ("help", "AXHelp" as CFString),
        (
            "placeholder",
            "AXPlaceholderValue" as CFString
        ),
        ("url", "AXURL" as CFString),
        ("filename", "AXFilename" as CFString),
        ("document", "AXDocument" as CFString),
        ("value", "AXValue" as CFString)
    ]

    var result: [String: String] = [:]

    for entry in attributes {
        if redactValue && entry.name == "value" {
            result["value"] = "<redacted-text-area>"
            continue
        }

        guard
            let value = stringAttribute(
                element,
                entry.attribute
            ),
            !value.isEmpty
        else {
            continue
        }

        result[entry.name] = truncated(value)
    }

    return result
}

private func frameDictionary(
    _ rectangle: CGRect
) -> [String: Double] {
    return [
        "x": Double(rectangle.origin.x),
        "y": Double(rectangle.origin.y),
        "width": Double(rectangle.width),
        "height": Double(rectangle.height)
    ]
}

private func printJSON(
    _ object: [String: Any],
    exitCode: Int32
) -> Never {
    do {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [
                .prettyPrinted,
                .sortedKeys
            ]
        )

        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(
            Data("\n".utf8)
        )
    } catch {
        FileHandle.standardError.write(
            Data(
                "Failed to encode JSON: \(error)\n"
                    .utf8
            )
        )
    }

    exit(exitCode)
}

private func fail(
    code: String,
    message: String
) -> Never {
    printJSON(
        [
            "ok": false,
            "error": code,
            "message": message
        ],
        exitCode: 1
    )
}

private func isCursorApplication(
    _ application: NSRunningApplication
) -> Bool {
    let name = (
        application.localizedName ?? ""
    ).lowercased()

    let bundleIdentifier = (
        application.bundleIdentifier ?? ""
    ).lowercased()

    return (
        name.contains("cursor")
        || bundleIdentifier.contains("cursor")
        || bundleIdentifier.contains(
            "todesktop.230313mzl4w4u92"
        )
    )
}

private func main() -> Never {
    guard AXIsProcessTrusted() else {
        fail(
            code: "accessibility_permission_required",
            message:
                "Accessibility permission is required."
        )
    }

    let delay = CommandLine.arguments.count >= 2
        ? Double(CommandLine.arguments[1]) ?? 3
        : 3

    FileHandle.standardError.write(
        Data(
            """
            Focus the Cursor Codex composer now. \
            Probe starts in \(delay) seconds.\n
            """.utf8
        )
    )

    Thread.sleep(
        forTimeInterval: delay
    )

    guard
        let application =
            NSWorkspace.shared.frontmostApplication,
        isCursorApplication(application)
    else {
        fail(
            code: "cursor_not_frontmost",
            message:
                "Cursor was not the frontmost application."
        )
    }

    let applicationElement =
        AXUIElementCreateApplication(
            application.processIdentifier
        )

    guard
        let focusedElement = elementAttribute(
            applicationElement,
            "AXFocusedUIElement" as CFString
        )
    else {
        fail(
            code: "focused_element_missing",
            message:
                "Cursor exposed no focused accessibility element."
        )
    }

    let focusedRole = stringAttribute(
        focusedElement,
        "AXRole" as CFString
    ) ?? "<unknown>"

    guard let composer = nearestTextArea(
        from: focusedElement
    ) else {
        fail(
            code: "composer_not_focused",
            message:
                "Place the caret inside the Codex composer before the delay ends. Focused role: \(focusedRole)"
        )
    }

    guard let composerFrame = frame(
        of: composer
    ) else {
        fail(
            code: "composer_frame_missing",
            message:
                "The focused composer exposes no position or size."
        )
    }

    guard let focusedWindow = elementAttribute(
        applicationElement,
        "AXFocusedWindow" as CFString
    ) else {
        fail(
            code: "focused_window_missing",
            message:
                "Cursor exposed no focused window."
        )
    }

    let inspectionRegion =
        composerFrame.insetBy(
            dx: -100,
            dy: -320
        )

    let interestingRoles: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXCell",
        "AXGroup",
        "AXImage",
        "AXLink",
        "AXList",
        "AXPopUpButton",
        "AXScrollArea",
        "AXStaticText",
        "AXTextArea",
        "AXTextField"
    ]

    var queue: [QueueEntry] = [
        QueueEntry(
            element: focusedWindow,
            depth: 0
        )
    ]

    var queueIndex = 0
    var nodesScanned = 0
    var visited = Set<CFHashCode>()
    var results: [[String: Any]] = []

    while
        queueIndex < queue.count,
        nodesScanned < maximumNodes,
        results.count < maximumResults
    {
        let entry = queue[queueIndex]
        queueIndex += 1

        let hash = CFHash(entry.element)

        guard visited.insert(hash).inserted else {
            continue
        }

        nodesScanned += 1

        let elementFrame = frame(
            of: entry.element
        )

        let elementMetadata = metadata(
            for: entry.element,
            redactValue:
                CFEqual(entry.element, composer)
        )

        let role =
            elementMetadata["role"]
            ?? "<unknown>"

        let isNearComposer =
            elementFrame?.intersects(
                inspectionRegion
            ) == true

        let hasSemanticMetadata =
            elementMetadata.keys.contains {
                $0 != "role"
                && $0 != "subrole"
                && $0 != "roleDescription"
            }

        if
            isNearComposer,
            (
                interestingRoles.contains(role)
                || hasSemanticMetadata
            )
        {
            var item: [String: Any] = [
                "depth": entry.depth,
                "metadata": elementMetadata
            ]

            if let elementFrame {
                item["frame"] =
                    frameDictionary(elementFrame)
            }

            item["isComposer"] =
                CFEqual(entry.element, composer)

            results.append(item)
        }

        guard entry.depth < maximumDepth else {
            continue
        }

        for child in traversalChildren(
            of: entry.element
        ) {
            queue.append(
                QueueEntry(
                    element: child,
                    depth: entry.depth + 1
                )
            )
        }
    }

    printJSON(
        [
            "ok": true,
            "applicationName":
                application.localizedName ?? "",
            "bundleIdentifier":
                application.bundleIdentifier ?? "",
            "focusedRole": focusedRole,
            "composerFrame":
                frameDictionary(composerFrame),
            "inspectionRegion":
                frameDictionary(inspectionRegion),
            "nodesScanned": nodesScanned,
            "elements": results
        ],
        exitCode: 0
    )
}

main()
