import Foundation
import Observation

@MainActor
@Observable
final class AppStoreUpdateChecker {
    enum State: Equatable { case unavailable, checking, current, available, failed }
    private(set) var state: State = .unavailable

    var updateAvailable: Bool {
        state == .available && validUntil.map { now() < $0 } == true
    }

    // A successful lookup lasts a day; failures wait an hour. This avoids requests on every
    // screen appearance and stays far below Apple's approximate 20/minute guidance (not an SLA).
    private static let successLifetime: TimeInterval = 24 * 60 * 60
    private static let failureRetry: TimeInterval = 60 * 60
    @ObservationIgnored private let context: AppStoreUpdateContext
    @ObservationIgnored private let cache: AppStoreUpdateCache
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let installationAllowed: () async -> Bool
    @ObservationIgnored private let storefront: () async -> String?
    @ObservationIgnored private let lookup: (String) async throws -> Data
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var expirationTask: Task<Void, Never>?
    @ObservationIgnored private var storefrontTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var country: String?
    @ObservationIgnored private var hasReadCountry = false
    @ObservationIgnored private var validUntil: Date?

    init(context: AppStoreUpdateContext, cache: AppStoreUpdateCache,
         now: @escaping () -> Date = Date.init,
         installationAllowed: @escaping () async -> Bool,
         storefront: @escaping () async -> String?,
         lookup: @escaping (String) async throws -> Data) {
        self.context = context
        self.cache = cache
        self.now = now
        self.installationAllowed = installationAllowed
        self.storefront = storefront
        self.lookup = lookup
    }

    deinit {
        task?.cancel()
        expirationTask?.cancel()
        storefrontTask?.cancel()
    }

    /// Starts work and returns immediately to the caller. Repeated calls join the same task,
    /// including while StoreKit is reading the installation or storefront.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        startCheck(readCountry: storefront)
    }

    func observeStorefronts(_ changes: AsyncStream<String?>) {
        guard storefrontTask == nil else { return }
        storefrontTask = Task { [weak self] in
            for await code in changes {
                guard !Task.isCancelled else { return }
                self?.storefrontChanged(to: code)
            }
        }
    }

    func storefrontChanged(to code: String?) {
        let next = AppStoreCountry.lookupCode(code)
        guard !hasReadCountry || country != next else { return }
        generation += 1
        task?.cancel()
        task = nil
        expirationTask?.cancel()
        state = .unavailable
        validUntil = nil
        country = next
        hasReadCountry = true
        cache.save(nil)
        _ = startCheck { code }
    }

    private func startCheck(readCountry: @escaping () async -> String?) -> Task<Void, Never> {
        if let task { return task }
        let requestedGeneration = generation
        let checking = Task { [weak self] in
            guard let self else { return }
            await self.check(readCountry: readCountry, generation: requestedGeneration)
            if self.generation == requestedGeneration { self.task = nil }
        }
        task = checking
        return checking
    }

    private func check(readCountry: () async -> String?, generation requestedGeneration: Int) async {
        let nextCountry = AppStoreCountry.lookupCode(await readCountry())
        guard generation == requestedGeneration, !Task.isCancelled else { return }
        if hasReadCountry && country != nextCountry { cache.save(nil) }
        country = nextCountry
        hasReadCountry = true
        state = .unavailable
        validUntil = nil
        expirationTask?.cancel()
        guard let country else {
            cache.save(nil)
            return
        }
        let allowed = await installationAllowed()
        guard generation == requestedGeneration, !Task.isCancelled else { return }
        guard allowed else {
            cache.save(nil)
            return
        }

        let date = now()
        if let entry = cache.load(), entry.country == country, entry.context == context,
           date >= entry.checkedAt {
            let age = date.timeIntervalSince(entry.checkedAt)
            if let payload = entry.payload, age < Self.successLifetime,
               let available = try? context.hasUpdate(in: payload, country: country) {
                apply(available: available, checkedAt: entry.checkedAt)
                return
            }
            if entry.payload == nil, age < Self.failureRetry {
                state = .failed
                return
            }
        }
        // Drop expired or mismatched entries before the network starts. An error must never
        // resurrect a previous prompt or be described as an up-to-date result.
        cache.save(nil)
        state = .checking
        do {
            let payload = try await lookup(country)
            try Task.checkCancellation()
            guard generation == requestedGeneration else { return }
            let available = try context.hasUpdate(in: payload, country: country)
            let checkedAt = now()
            cache.save(.init(country: country, context: context, checkedAt: checkedAt, payload: payload))
            apply(available: available, checkedAt: checkedAt)
        } catch {
            guard generation == requestedGeneration else { return }
            state = .failed
            if !Task.isCancelled, (error as? URLError)?.code != .cancelled, !(error is CancellationError) {
                cache.save(.init(country: country, context: context, checkedAt: now(), payload: nil))
            }
        }
    }

    private func apply(available: Bool, checkedAt: Date) {
        state = available ? .available : .current
        let deadline = checkedAt.addingTimeInterval(Self.successLifetime)
        validUntil = deadline
        expirationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSince(self?.now() ?? deadline)))) }
            catch { return }
            self?.validUntil = nil
            self?.state = .unavailable
        }
    }
}
