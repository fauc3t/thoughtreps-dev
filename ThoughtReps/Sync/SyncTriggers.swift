import Foundation

/// When the engine runs, as logic only (nothing here touches the app lifecycle, `BGTask` or
/// `beginBackgroundTask`): a cycle about 2 s after the last local change, and a check of the server's head
/// every 30 s that runs a cycle only if it moved. `sleep` is injected so tests drive time by hand.
actor SyncTriggers {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    static let defaultDebounce = Duration.seconds(2)
    static let defaultHeadInterval = Duration.seconds(30)

    private let engine: SyncEngine
    private let debounce: Duration
    private let headInterval: Duration
    private let sleep: Sleep
    private var debounceTask: Task<Void, Never>?
    private var headTask: Task<Void, Never>?

    init(
        engine: SyncEngine, debounce: Duration = defaultDebounce, headInterval: Duration = defaultHeadInterval,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.engine = engine
        self.debounce = debounce
        self.headInterval = headInterval
        self.sleep = sleep
    }

    /// Starts the periodic head check and has every accepted enqueue on `state` restart the debounce.
    func start(observing state: SyncState) {
        state.setEnqueueObserver { [weak self] in
            guard let self else { return }
            Task { await self.localChange() }
        }
        guard headTask == nil else { return }
        headTask = Task { [sleep, headInterval, engine] in
            while !Task.isCancelled {
                do { try await sleep(headInterval) } catch { return }
                await engine.syncIfHeadMoved()
            }
        }
    }

    func stop(observing state: SyncState) {
        state.setEnqueueObserver(nil)
        debounceTask?.cancel()
        headTask?.cancel()
        debounceTask = nil
        headTask = nil
    }

    /// A local write happened: run a cycle once nothing more has been written for the debounce interval.
    func localChange() {
        debounceTask?.cancel()
        debounceTask = Task { [sleep, debounce, engine] in
            do { try await sleep(debounce) } catch { return }
            await engine.syncNow()
        }
    }
}
