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

test("accepts direct focus without semantic evidence") {
    let result = validateComposer(
        input(context: ""),
        mode: .focused
    )

    expect(result.isEligible, "focused selectable text area should pass")
    expect(
        result.code == "eligible",
        "focused structural validation should be sufficient"
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

test("accepts clipboard snapshot limits exactly") {
    var byteBudget = ClipboardSnapshotBudget()

    do {
        try byteBudget.addItem()
        try byteBudget.addRepresentation(
            byteCount: clipboardSnapshotMaximumBytes
        )
        expect(
            byteBudget.statistics.bytes
                == clipboardSnapshotMaximumBytes,
            "exact byte limit should pass"
        )
    } catch {
        expect(false, "exact byte limit must not throw")
    }

    var itemBudget = ClipboardSnapshotBudget()
    var representationBudget =
        ClipboardSnapshotBudget()

    do {
        for _ in 0..<clipboardSnapshotMaximumItems {
            try itemBudget.addItem()
        }
        for _ in 0..<clipboardSnapshotMaximumRepresentations {
            try representationBudget.addRepresentation(
                byteCount: 0
            )
        }
    } catch {
        expect(false, "exact count limits must not throw")
    }
}

test("rejects every clipboard snapshot overflow") {
    var byteBudget = ClipboardSnapshotBudget()
    var itemBudget = ClipboardSnapshotBudget()
    var representationBudget =
        ClipboardSnapshotBudget()

    expect(
        {
            do {
                try byteBudget.addRepresentation(
                    byteCount:
                        clipboardSnapshotMaximumBytes + 1
                )
                return false
            } catch {
                return true
            }
        }(),
        "byte overflow must fail"
    )

    expect(
        {
            do {
                for _ in 0...clipboardSnapshotMaximumItems {
                    try itemBudget.addItem()
                }
                return false
            } catch {
                return true
            }
        }(),
        "item overflow must fail"
    )

    expect(
        {
            do {
                for _ in 0...clipboardSnapshotMaximumRepresentations {
                    try representationBudget.addRepresentation(
                        byteCount: 0
                    )
                }
                return false
            } catch {
                return true
            }
        }(),
        "representation overflow must fail"
    )
}

test("tracks empty and multi-item clipboard snapshots") {
    let empty = ClipboardSnapshotBudget()
    var multiple = ClipboardSnapshotBudget()

    do {
        try multiple.addItem()
        try multiple.addRepresentation(byteCount: 4)
        try multiple.addItem()
        try multiple.addRepresentation(byteCount: 6)
        try multiple.addRepresentation(byteCount: 8)
    } catch {
        expect(false, "small multi-item snapshot must pass")
    }

    expect(
        empty.statistics
            == ClipboardSnapshotStatistics(
                bytes: 0,
                items: 0,
                representations: 0
            ),
        "empty snapshot statistics should be zero"
    )
    expect(
        multiple.statistics
            == ClipboardSnapshotStatistics(
                bytes: 18,
                items: 2,
                representations: 3
            ),
        "multi-item statistics should include all data"
    )
}

test("centralizes clipboard restoration once") {
    for path in ["success", "failure"] {
        let coordinator =
            ClipboardTransactionCoordinator()
        var restoreCount = 0

        coordinator.recordTemporaryChange(
            changeCount: 12
        )
        let first = coordinator.finish(
            currentChangeCount: 12
        ) {
            restoreCount += 1
            return true
        }
        let second = coordinator.finish(
            currentChangeCount: 12
        ) {
            restoreCount += 1
            return true
        }

        expect(first.restored, "\(path) cleanup should restore")
        expect(
            !second.restored,
            "\(path) cleanup must not restore twice"
        )
        expect(
            restoreCount == 1,
            "\(path) cleanup should run once"
        )
    }
}

test("preserves concurrent clipboard changes") {
    let coordinator =
        ClipboardTransactionCoordinator()
    var restored = false

    coordinator.recordTemporaryChange(
        changeCount: 21
    )
    let result = coordinator.finish(
        currentChangeCount: 22
    ) {
        restored = true
        return true
    }

    expect(!restored, "concurrent change must prevent restore")
    expect(!result.restored, "concurrent change is not restored")
    expect(
        result.skippedBecauseChanged,
        "concurrent change should be reported"
    )
}

test("detects clipboard ownership changes before mutation") {
    let coordinator =
        ClipboardTransactionCoordinator()

    expect(
        coordinator.ownsTemporaryState(
            currentChangeCount: 1
        ),
        "capture-only transaction should not claim clipboard ownership"
    )
    coordinator.recordTemporaryChange(
        changeCount: 4
    )
    expect(
        coordinator.ownsTemporaryState(
            currentChangeCount: 4
        ),
        "matching helper change should remain owned"
    )
    expect(
        !coordinator.ownsTemporaryState(
            currentChangeCount: 5
        ),
        "newer clipboard change should revoke ownership"
    )
}

test("records the first cooperative termination request") {
    let state = TerminationRequestState()

    expect(
        state.currentSignal() == nil,
        "termination should begin clear"
    )
    state.request(signal: 15)
    state.request(signal: 2)
    expect(
        state.currentSignal() == 15,
        "first termination signal should win"
    )
}

if failures > 0 {
    FileHandle.standardError.write(
        Data("\(failures) native test assertion(s) failed.\n".utf8)
    )
    exit(1)
}

print("All native safety tests passed.")
