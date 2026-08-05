import Foundation

let clipboardSnapshotMaximumBytes = 128 * 1024 * 1024
let clipboardSnapshotMaximumItems = 32
let clipboardSnapshotMaximumRepresentations = 128

struct ClipboardSnapshotStatistics: Equatable {
    let bytes: Int
    let items: Int
    let representations: Int
}

struct ClipboardSnapshotLimitError: Error {
    let statistics: ClipboardSnapshotStatistics
}

struct ClipboardSnapshotBudget {
    private(set) var bytes = 0
    private(set) var items = 0
    private(set) var representations = 0

    mutating func addItem() throws {
        items += 1
        try validate()
    }

    mutating func addRepresentation(
        byteCount: Int
    ) throws {
        representations += 1

        if
            byteCount < 0
            || byteCount
                > clipboardSnapshotMaximumBytes - bytes
        {
            bytes = clipboardSnapshotMaximumBytes + 1
            throw limitError()
        }

        bytes += byteCount
        try validate()
    }

    var statistics: ClipboardSnapshotStatistics {
        ClipboardSnapshotStatistics(
            bytes: bytes,
            items: items,
            representations: representations
        )
    }

    private func validate() throws {
        guard
            bytes <= clipboardSnapshotMaximumBytes,
            items <= clipboardSnapshotMaximumItems,
            representations
                <= clipboardSnapshotMaximumRepresentations
        else {
            throw limitError()
        }
    }

    private func limitError() -> ClipboardSnapshotLimitError {
        ClipboardSnapshotLimitError(
            statistics: statistics
        )
    }
}

struct ClipboardRestoreResult: Equatable {
    let restored: Bool
    let skippedBecauseChanged: Bool
}

struct PasteApplicationTracker {
    private let originalValue: String
    private let requiredStableObservations: Int
    private var lastChangedValue: String?
    private var stableObservationCount = 0

    private(set) var observedChange = false

    init(
        originalValue: String,
        requiredStableObservations: Int
    ) {
        self.originalValue = originalValue
        self.requiredStableObservations = max(
            1,
            requiredStableObservations
        )
    }

    mutating func observe(
        _ currentValue: String?
    ) -> Bool {
        guard
            let currentValue,
            currentValue != originalValue
        else {
            lastChangedValue = nil
            stableObservationCount = 0
            return false
        }

        observedChange = true

        if currentValue == lastChangedValue {
            stableObservationCount += 1
        } else {
            lastChangedValue = currentValue
            stableObservationCount = 1
        }

        return stableObservationCount
            >= requiredStableObservations
    }
}

final class ClipboardTransactionCoordinator {
    private var expectedTemporaryChangeCount: Int?
    private var finished = false

    func recordTemporaryChange(
        changeCount: Int
    ) {
        guard !finished else {
            return
        }

        expectedTemporaryChangeCount = changeCount
    }

    func ownsTemporaryState(
        currentChangeCount: Int
    ) -> Bool {
        guard
            let expectedTemporaryChangeCount
        else {
            return true
        }

        return currentChangeCount
            == expectedTemporaryChangeCount
    }

    func finish(
        currentChangeCount: Int,
        shouldRestore: Bool = true,
        restore: () -> Bool
    ) -> ClipboardRestoreResult {
        guard !finished else {
            return ClipboardRestoreResult(
                restored: false,
                skippedBecauseChanged: false
            )
        }

        finished = true

        guard
            shouldRestore,
            let expectedTemporaryChangeCount
        else {
            return ClipboardRestoreResult(
                restored: false,
                skippedBecauseChanged: false
            )
        }

        guard
            currentChangeCount
                == expectedTemporaryChangeCount
        else {
            return ClipboardRestoreResult(
                restored: false,
                skippedBecauseChanged: true
            )
        }

        return ClipboardRestoreResult(
            restored: restore(),
            skippedBecauseChanged: false
        )
    }
}

final class TerminationRequestState {
    private let lock = NSLock()
    private var requestedSignal: Int32?

    func request(signal: Int32) {
        lock.lock()

        if requestedSignal == nil {
            requestedSignal = signal
        }

        lock.unlock()
    }

    func currentSignal() -> Int32? {
        lock.lock()
        let signal = requestedSignal
        lock.unlock()
        return signal
    }
}
