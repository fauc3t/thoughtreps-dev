import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class StatsModel {
    private(set) var snapshot: ThoughtStats.Snapshot?

    func refresh(container: ModelContainer, now: Date, calendar: Calendar) async {
        let work = Task.detached {
            ThoughtStats.compute(container: container, now: now, calendar: calendar)
        }
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled else { return }
        snapshot = result
    }
}
