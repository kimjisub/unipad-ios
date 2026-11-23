import Foundation

nonisolated struct DownloadReceipt: Codable, Sendable {
    let receipt: String
    let expiresAt: Date
}

nonisolated protocol DownloadAccounting: Sendable {
    func issueReceipt(code: String) async -> DownloadReceipt?
    func saved(code: String, receipt: DownloadReceipt, at completion: Date) async
}

/// Stores only completed store downloads. File access and requests run on this actor, away from UI.
actor DownloadAccountingService: DownloadAccounting {
    nonisolated struct Pending: Codable, Sendable {
        let code: String
        let receipt: String
        let completedAt: Date
        let expiresAt: Date
        var attempts: [Date] = []
    }

    typealias Request = @Sendable (String, [String: String]) async -> Data?
    private let file: URL
    private let request: Request
    private let now: @Sendable () -> Date
    private var pending: [Pending] = []
    private var loaded = false
    private var active = false
    private var sending: Task<Void, Never>?
    private let day: TimeInterval = 86_400

    init(file: URL, now: @escaping @Sendable () -> Date = { Date() }, request: @escaping Request) {
        self.file = file
        self.now = now
        self.request = request
    }

    func issueReceipt(code: String) async -> DownloadReceipt? {
        guard let data = await request("issueDownloadReceipt", ["code": code]), !Task.isCancelled,
              let reply = try? JSONDecoder().decode(Issued.self, from: data), reply.status == "issued",
              let receipt = reply.receipt, !receipt.isEmpty, receipt.utf8.count <= 128,
              let milliseconds = reply.expiresAt, milliseconds.isFinite else { return nil }
        let expiry = Date(timeIntervalSince1970: milliseconds / 1_000)
        guard expiry > now() else { return nil }
        return DownloadReceipt(receipt: receipt, expiresAt: expiry)
    }

    func saved(code: String, receipt: DownloadReceipt, at completion: Date) async {
        load()
        guard !pending.contains(where: { $0.receipt == receipt.receipt }) else { return }
        pending.append(Pending(code: code, receipt: receipt.receipt, completedAt: completion,
                                expiresAt: min(receipt.expiresAt, completion.addingTimeInterval(7 * day))))
        prune()
        persist()
        await flush()
    }

    /// Called only by foreground lifecycle events. No timer or background task is registered.
    func setActive(_ value: Bool) async {
        active = value
        if value { await flush() } else { sending?.cancel() }
    }

    func flush() async {
        guard active else { return }
        if let sending { await sending.value; return }
        let task = Task { await drain() }
        sending = task
        await task.value
    }

    private func drain() async {
        defer { sending = nil }
        load()
        prune()
        persist()
        while active && !Task.isCancelled {
            prune()
            let time = now()
            for index in pending.indices {
                pending[index].attempts.removeAll { time.timeIntervalSince($0) >= day }
            }
            guard let index = pending.firstIndex(where: {
                $0.attempts.count < 3 && ($0.attempts.last.map { time.timeIntervalSince($0) >= 60 } ?? true)
            }) else { return }
            let receipt = pending[index].receipt
            // Persist before sending so termination and a lost response cannot reset the rate limit.
            pending[index].attempts.append(time)
            let item = pending[index]
            guard persist() else { return }
            let data = await request("completeDownload", ["code": item.code, "receipt": item.receipt])
            if let data, let response = try? JSONDecoder().decode(Status.self, from: data),
               ["counted", "already_counted", "expired", "invalid"].contains(response.status) {
                pending.removeAll { $0.receipt == receipt }
            }
            prune()
            persist()
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000,
           let data = try? Data(contentsOf: file), let records = try? JSONDecoder().decode([Pending].self, from: data) {
            pending = records
        } else { pending = [] }
        prune()
    }

    private func prune() {
        let time = now()
        pending = Array(pending.filter { $0.expiresAt > time }
            .sorted { $0.completedAt < $1.completedAt }.suffix(1_000))
    }

    @discardableResult private func persist() -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(pending).write(to: file, options: .atomic)
            return true
        } catch {
            // Accounting storage failure never changes the pack or its successful installation.
            return false
        }
    }

    nonisolated private struct Issued: Decodable { let status: String; let receipt: String?; let expiresAt: Double? }
    nonisolated private struct Status: Decodable { let status: String }
}
