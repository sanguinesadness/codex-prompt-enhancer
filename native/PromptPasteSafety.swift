import Foundation

enum SerializedPromptVerificationMode: String {
    case exact
    case referenceWhitespaceNormalized =
        "reference_whitespace_normalized"
}

struct SerializedPromptVerificationResult: Equatable {
    let mode: SerializedPromptVerificationMode
    let referenceWhitespaceNormalizationCount: Int
}

struct PasteUndoTracker {
    private(set) var pasteEventsIssued = 0
    private(set) var undoCount = 0
    private(set) var lastObservedRenderedValue: String

    init(initialRenderedValue: String) {
        lastObservedRenderedValue = initialRenderedValue
    }

    mutating func recordPasteEvent() {
        pasteEventsIssued += 1
    }

    mutating func recordObservedRenderedValue(
        _ value: String
    ) {
        lastObservedRenderedValue = value
    }

    func mayBeginRollback(
        sameTarget: Bool,
        currentRenderedValue: String?
    ) -> Bool {
        sameTarget
            && pasteEventsIssued > 0
            && currentRenderedValue
                == lastObservedRenderedValue
    }

    var canUndo: Bool {
        undoCount < pasteEventsIssued
    }

    mutating func recordUndo() -> Bool {
        guard canUndo else {
            return false
        }

        undoCount += 1
        return true
    }
}

func verifySerializedPrompt(
    expected: String,
    actual: String
) -> SerializedPromptVerificationResult? {
    if expected == actual {
        return SerializedPromptVerificationResult(
            mode: .exact,
            referenceWhitespaceNormalizationCount: 0
        )
    }

    let expectedReferences = parseLocalReferences(expected)
    let actualReferences = parseLocalReferences(actual)

    guard
        !expectedReferences.isEmpty,
        expectedReferences.count == actualReferences.count,
        zip(expectedReferences, actualReferences).allSatisfy({
            $0.raw == $1.raw
        })
    else {
        return nil
    }

    let expectedSegments = textSegments(
        in: expected,
        around: expectedReferences
    )
    let actualSegments = textSegments(
        in: actual,
        around: actualReferences
    )
    var normalizationCount = 0

    for index in expectedSegments.indices {
        guard let segmentCount = compareSegment(
            expected: expectedSegments[index],
            actual: actualSegments[index],
            allowLeadingSpace: index > 0,
            allowTrailingSpace:
                index < expectedReferences.count
        ) else {
            return nil
        }

        normalizationCount += segmentCount
    }

    guard normalizationCount > 0 else {
        return nil
    }

    return SerializedPromptVerificationResult(
        mode: .referenceWhitespaceNormalized,
        referenceWhitespaceNormalizationCount:
            normalizationCount
    )
}

private struct LocalReference {
    let range: Range<String.Index>
    let raw: String
}

private func parseLocalReferences(
    _ text: String
) -> [LocalReference] {
    var references: [LocalReference] = []
    var cursor = text.startIndex

    while cursor < text.endIndex {
        guard text[cursor] == "[" else {
            cursor = text.index(after: cursor)
            continue
        }

        guard let labelEnd = findBalancedClosingIndex(
            in: text,
            start: cursor,
            opening: "[",
            closing: "]"
        ) else {
            cursor = text.index(after: cursor)
            continue
        }

        let openingDestination = text.index(after: labelEnd)

        guard
            openingDestination < text.endIndex,
            text[openingDestination] == "(",
            let destinationEnd = findBalancedClosingIndex(
                in: text,
                start: openingDestination,
                opening: "(",
                closing: ")"
            )
        else {
            cursor = text.index(after: cursor)
            continue
        }

        let destinationStart = text.index(
            after: openingDestination
        )
        let destination = String(
            text[destinationStart..<destinationEnd]
        ).trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard isLocalReferenceDestination(destination) else {
            cursor = text.index(after: cursor)
            continue
        }

        let endExclusive = text.index(after: destinationEnd)
        let range = cursor..<endExclusive
        references.append(
            LocalReference(
                range: range,
                raw: String(text[range])
            )
        )
        cursor = endExclusive
    }

    return references
}

private func findBalancedClosingIndex(
    in text: String,
    start: String.Index,
    opening: Character,
    closing: Character
) -> String.Index? {
    var depth = 0
    var cursor = start

    while cursor < text.endIndex {
        let character = text[cursor]

        if character == "\\" {
            cursor = text.index(after: cursor)

            if cursor < text.endIndex {
                cursor = text.index(after: cursor)
            }

            continue
        }

        if character == opening {
            depth += 1
        } else if character == closing {
            depth -= 1

            if depth == 0 {
                return cursor
            }
        }

        cursor = text.index(after: cursor)
    }

    return nil
}

private func isLocalReferenceDestination(
    _ destination: String
) -> Bool {
    let unwrapped: String

    if
        destination.hasPrefix("<"),
        destination.hasSuffix(">")
    {
        unwrapped = String(destination.dropFirst().dropLast())
    } else {
        unwrapped = destination
    }

    return unwrapped.hasPrefix("/")
        || unwrapped.hasPrefix("file:///")
}

private func textSegments(
    in text: String,
    around references: [LocalReference]
) -> [String] {
    var segments: [String] = []
    var cursor = text.startIndex

    for reference in references {
        segments.append(String(text[cursor..<reference.range.lowerBound]))
        cursor = reference.range.upperBound
    }

    segments.append(String(text[cursor..<text.endIndex]))
    return segments
}

private func compareSegment(
    expected: String,
    actual: String,
    allowLeadingSpace: Bool,
    allowTrailingSpace: Bool
) -> Int? {
    if expected == actual {
        return 0
    }

    var candidate = actual
    var normalizationCount = 0

    if
        allowLeadingSpace,
        expected.first.map({ !$0.isWhitespace }) ?? true,
        candidate.first == " "
    {
        candidate.removeFirst()
        normalizationCount += 1
    }

    if
        allowTrailingSpace,
        expected.last.map({ !$0.isWhitespace }) ?? true,
        candidate.last == " "
    {
        candidate.removeLast()
        normalizationCount += 1
    }

    return candidate == expected
        ? normalizationCount
        : nil
}
