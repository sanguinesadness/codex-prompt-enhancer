import Foundation
import CoreGraphics
import CryptoKit

enum ComposerSelectionMode: String {
    case focused
    case fallback
}

struct ComposerValidationInput {
    let role: String
    let valueReadable: Bool
    let selectionSettable: Bool
    let enabled: Bool?
    let semanticContext: String
    let frame: CGRect?
    let windowFrame: CGRect?
}

struct ComposerValidationResult {
    let isEligible: Bool
    let code: String
    let matchedSignals: [String]
}

struct ComposerTargetFingerprintInput {
    let pid: Int
    let windowFrame: CGRect?
    let elementFrame: CGRect?
    let rolePath: [String]
    let identifiers: [String]
    let matchedSignals: [String]
}

enum FocusResolutionState {
    case validated
    case explicitlyRejected
    case unavailable
}

struct ComposerCandidateRank {
    let score: Int
    let isEligible: Bool
}

enum ComposerCandidateSelection: Equatable {
    case none
    case selected(Int)
    case ambiguous
}

private let composerProductSignals = [
    "codex",
    "chatgpt"
]

private let composerIntentSignals = [
    "composer",
    "prompt",
    "message",
    "chat",
    "ask"
]

private let forbiddenComposerSignals = [
    "monaco",
    "terminal",
    "quickinput",
    "editor",
    "search",
    "find",
    "output",
    "debug",
    "rename",
    "scm"
]

func shouldAttemptComposerFallback(
    after state: FocusResolutionState
) -> Bool {
    state == .unavailable
}

func selectComposerCandidate(
    _ candidates: [ComposerCandidateRank],
    minimumScore: Int,
    minimumMargin: Int
) -> ComposerCandidateSelection {
    let eligible = candidates.enumerated().filter {
        $0.element.isEligible
            && $0.element.score >= minimumScore
    }

    guard let best = eligible.first else {
        return .none
    }

    if eligible.count >= 2 {
        let runnerUp = eligible[1]

        guard
            best.element.score
                - runnerUp.element.score
                >= minimumMargin
        else {
            return .ambiguous
        }
    }

    return .selected(best.offset)
}

func validateComposer(
    _ input: ComposerValidationInput,
    mode: ComposerSelectionMode
) -> ComposerValidationResult {
    let context = input.semanticContext.lowercased()
    let productSignals = matchedKeywords(
        composerProductSignals,
        in: context
    )
    let intentSignals = matchedKeywords(
        composerIntentSignals,
        in: context
    )
    let forbiddenSignals = matchedKeywords(
        forbiddenComposerSignals,
        in: context
    )
    let matchedSignals = Array(
        Set(productSignals + intentSignals)
    ).sorted()

    guard input.role == "AXTextArea" else {
        return ComposerValidationResult(
            isEligible: false,
            code: "not_text_area",
            matchedSignals: matchedSignals
        )
    }

    guard input.valueReadable else {
        return ComposerValidationResult(
            isEligible: false,
            code: "value_not_readable",
            matchedSignals: matchedSignals
        )
    }

    guard input.enabled != false else {
        return ComposerValidationResult(
            isEligible: false,
            code: "element_disabled",
            matchedSignals: matchedSignals
        )
    }

    guard forbiddenSignals.isEmpty else {
        return ComposerValidationResult(
            isEligible: false,
            code: "forbidden_context",
            matchedSignals: matchedSignals
        )
    }

    switch mode {
    case .focused:
        guard input.selectionSettable else {
            return ComposerValidationResult(
                isEligible: false,
                code: "selection_not_settable",
                matchedSignals: matchedSignals
            )
        }

    case .fallback:
        guard !productSignals.isEmpty else {
            return ComposerValidationResult(
                isEligible: false,
                code: "product_evidence_missing",
                matchedSignals: matchedSignals
            )
        }

        guard !intentSignals.isEmpty else {
            return ComposerValidationResult(
                isEligible: false,
                code: "composer_evidence_missing",
                matchedSignals: matchedSignals
            )
        }

        guard fallbackGeometryIsEligible(input) else {
            return ComposerValidationResult(
                isEligible: false,
                code: "fallback_geometry_invalid",
                matchedSignals: matchedSignals
            )
        }
    }

    return ComposerValidationResult(
        isEligible: true,
        code: "eligible",
        matchedSignals: matchedSignals
    )
}

func makeComposerTargetFingerprint(
    _ input: ComposerTargetFingerprintInput
) -> String {
    let payload: [String: Any] = [
        "pid": input.pid,
        "windowFrame": roundedFrame(input.windowFrame),
        "elementFrame": roundedFrame(input.elementFrame),
        "rolePath": input.rolePath,
        "identifiers": input.identifiers,
        "matchedSignals": input.matchedSignals.sorted()
    ]

    let data = try! JSONSerialization.data(
        withJSONObject: payload,
        options: [.sortedKeys]
    )
    let digest = SHA256.hash(data: data)

    return digest.map {
        String(format: "%02x", $0)
    }.joined()
}

private func fallbackGeometryIsEligible(
    _ input: ComposerValidationInput
) -> Bool {
    guard
        let frame = input.frame,
        let windowFrame = input.windowFrame,
        frame.width > 0,
        frame.height > 0,
        windowFrame.width > 0,
        windowFrame.height > 0
    else {
        return false
    }

    let intersection = frame.intersection(windowFrame)
    let visibleArea = max(0, intersection.width)
        * max(0, intersection.height)
    let frameArea = frame.width * frame.height

    guard visibleArea / frameArea >= 0.9 else {
        return false
    }

    let relativeBottom = (
        frame.maxY - windowFrame.minY
    ) / windowFrame.height
    let maximumHeight = min(
        700,
        windowFrame.height * 0.75
    )

    return relativeBottom >= 0.55
        && frame.width >= 250
        && frame.height >= 24
        && frame.height <= maximumHeight
}

private func matchedKeywords(
    _ keywords: [String],
    in context: String
) -> [String] {
    keywords.filter { keyword in
        if keyword == "chat" {
            return containsWholeWord(
                keyword,
                in: context
            )
        }

        return context.contains(keyword)
    }
}

private func containsWholeWord(
    _ keyword: String,
    in context: String
) -> Bool {
    context
        .split { character in
            !character.isLetter
                && !character.isNumber
        }
        .contains { token in
            token == Substring(keyword)
        }
}

private func roundedFrame(
    _ frame: CGRect?
) -> [Int] {
    guard let frame else {
        return []
    }

    return [
        Int(frame.origin.x.rounded()),
        Int(frame.origin.y.rounded()),
        Int(frame.width.rounded()),
        Int(frame.height.rounded())
    ]
}
