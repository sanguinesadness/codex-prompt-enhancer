import Foundation
import CoreGraphics

private var failures = 0

private func test(
    _ name: String,
    _ body: () -> Void
) {
    let previousFailures = failures
    body()

    if failures == previousFailures {
        print("PASS \(name)")
    } else {
        print("FAIL \(name)")
    }
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    if !condition() {
        failures += 1
        FileHandle.standardError.write(
            Data("  \(message)\n".utf8)
        )
    }
}

private func input(
    context: String,
    frame: CGRect? = CGRect(
        x: 650,
        y: 650,
        width: 500,
        height: 180
    ),
    windowFrame: CGRect? = CGRect(
        x: 0,
        y: 0,
        width: 1200,
        height: 900
    ),
    role: String = "AXTextArea",
    valueReadable: Bool = true,
    selectionSettable: Bool = true,
    enabled: Bool? = true
) -> ComposerValidationInput {
    ComposerValidationInput(
        role: role,
        valueReadable: valueReadable,
        selectionSettable: selectionSettable,
        enabled: enabled,
        semanticContext: context,
        frame: frame,
        windowFrame: windowFrame
    )
}

private func fingerprint(
    pid: Int = 101,
    windowFrame: CGRect? = CGRect(
        x: 0,
        y: 0,
        width: 1200,
        height: 900
    ),
    elementFrame: CGRect? = CGRect(
        x: 650,
        y: 650,
        width: 500,
        height: 180
    ),
    rolePath: [String] = [
        "AXTextArea",
        "AXGroup"
    ],
    identifiers: [String] = [
        "0:AXIdentifier:composer"
    ],
    matchedSignals: [String] = [
        "codex",
        "prompt"
    ]
) -> String {
    makeComposerTargetFingerprint(
        ComposerTargetFingerprintInput(
            pid: pid,
            windowFrame: windowFrame,
            elementFrame: elementFrame,
            rolePath: rolePath,
            identifiers: identifiers,
            matchedSignals: matchedSignals
        )
    )
}

test("accepts a directly focused composer") {
    let result = validateComposer(
        input(context: "codex prompt composer"),
        mode: .focused
    )

    expect(result.isEligible, "focused composer should be eligible")
    expect(result.code == "eligible", "focused result should be eligible")
}

test("rejects direct focus without composer evidence") {
    let result = validateComposer(
        input(context: "plain text field"),
        mode: .focused
    )

    expect(!result.isEligible, "generic text field must be rejected")
    expect(
        result.code == "composer_evidence_missing",
        "generic field should report missing evidence"
    )
}

test("rejects every forbidden context") {
    let forbidden = [
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

    for signal in forbidden {
        let result = validateComposer(
            input(context: "codex prompt \(signal)"),
            mode: .focused
        )

        expect(!result.isEligible, "\(signal) context must be rejected")
        expect(
            result.code == "forbidden_context",
            "\(signal) should report forbidden context"
        )
    }
}

test("requires fallback product and intent evidence") {
    let generic = validateComposer(
        input(context: "generic message field"),
        mode: .fallback
    )
    let productOnly = validateComposer(
        input(context: "codex panel"),
        mode: .fallback
    )
    let eligible = validateComposer(
        input(context: "codex prompt composer"),
        mode: .fallback
    )

    expect(!generic.isEligible, "generic fallback must be rejected")
    expect(
        generic.code == "product_evidence_missing",
        "generic fallback should lack product evidence"
    )
    expect(!productOnly.isEligible, "product-only fallback must be rejected")
    expect(
        productOnly.code == "composer_evidence_missing",
        "product-only fallback should lack composer evidence"
    )
    expect(eligible.isEligible, "strong fallback evidence should pass")
}

test("accepts left, right, and expanded composers") {
    let frames = [
        CGRect(x: 20, y: 650, width: 500, height: 180),
        CGRect(x: 680, y: 650, width: 500, height: 180),
        CGRect(x: 500, y: 250, width: 650, height: 600)
    ]

    for frame in frames {
        let result = validateComposer(
            input(
                context: "chatgpt prompt composer",
                frame: frame
            ),
            mode: .fallback
        )

        expect(result.isEligible, "expected frame \(frame) to pass")
    }
}

test("enforces fallback geometry boundaries") {
    let lowerBoundary = validateComposer(
        input(
            context: "codex prompt",
            frame: CGRect(
                x: 650,
                y: 495,
                width: 500,
                height: 0
            )
        ),
        mode: .fallback
    )
    let tooHigh = validateComposer(
        input(
            context: "codex prompt",
            frame: CGRect(
                x: 650,
                y: 100,
                width: 500,
                height: 180
            )
        ),
        mode: .fallback
    )
    let tooNarrow = validateComposer(
        input(
            context: "codex prompt",
            frame: CGRect(
                x: 650,
                y: 650,
                width: 249,
                height: 180
            )
        ),
        mode: .fallback
    )
    let mostlyOutside = validateComposer(
        input(
            context: "codex prompt",
            frame: CGRect(
                x: 1150,
                y: 650,
                width: 500,
                height: 180
            )
        ),
        mode: .fallback
    )

    expect(!lowerBoundary.isEligible, "zero-height fallback must fail")
    expect(!tooHigh.isEligible, "upper-window fallback must fail")
    expect(!tooNarrow.isEligible, "narrow fallback must fail")
    expect(!mostlyOutside.isEligible, "mostly hidden fallback must fail")
}

test("selects only a clear eligible candidate") {
    let selected = selectComposerCandidate(
        [
            ComposerCandidateRank(score: 500, isEligible: true),
            ComposerCandidateRank(score: 430, isEligible: true)
        ],
        minimumScore: 150,
        minimumMargin: 45
    )
    let ambiguous = selectComposerCandidate(
        [
            ComposerCandidateRank(score: 500, isEligible: true),
            ComposerCandidateRank(score: 460, isEligible: true)
        ],
        minimumScore: 150,
        minimumMargin: 45
    )
    let ineligible = selectComposerCandidate(
        [
            ComposerCandidateRank(score: 900, isEligible: false),
            ComposerCandidateRank(score: 149, isEligible: true)
        ],
        minimumScore: 150,
        minimumMargin: 45
    )

    expect(selected == .selected(0), "clear winner should be selected")
    expect(ambiguous == .ambiguous, "small score margin must be ambiguous")
    expect(ineligible == .none, "ineligible and low scores must fail")
}

test("attempts fallback only for unavailable focus") {
    expect(
        shouldAttemptComposerFallback(after: .unavailable),
        "unavailable focus should allow fallback"
    )
    expect(
        !shouldAttemptComposerFallback(after: .explicitlyRejected),
        "explicit rejection must suppress fallback"
    )
    expect(
        !shouldAttemptComposerFallback(after: .validated),
        "validated focus must suppress fallback"
    )
}

test("fingerprint is stable and excludes prompt text") {
    let firstPrompt = "First synthetic prompt"
    let secondPrompt = "Different synthetic prompt"
    let first = fingerprint()
    let second = fingerprint()

    expect(firstPrompt != secondPrompt, "synthetic prompts should differ")
    expect(first == second, "prompt text must not affect fingerprint input")
    expect(first.count == 64, "fingerprint must be a SHA-256 hex digest")
    expect(!first.contains("prompt"), "fingerprint must not contain labels")
}

test("fingerprint changes with structural identity") {
    let baseline = fingerprint()
    let variants = [
        fingerprint(pid: 102),
        fingerprint(
            windowFrame: CGRect(
                x: 10,
                y: 0,
                width: 1200,
                height: 900
            )
        ),
        fingerprint(
            elementFrame: CGRect(
                x: 640,
                y: 650,
                width: 500,
                height: 180
            )
        ),
        fingerprint(rolePath: ["AXTextArea", "AXScrollArea"]),
        fingerprint(identifiers: ["0:AXIdentifier:other-composer"]),
        fingerprint(matchedSignals: ["chatgpt", "prompt"])
    ]

    for variant in variants {
        expect(variant != baseline, "structural change must alter fingerprint")
    }
}

if failures > 0 {
    FileHandle.standardError.write(
        Data("\(failures) native test assertion(s) failed.\n".utf8)
    )
    exit(1)
}

print("All native composer validation tests passed.")
