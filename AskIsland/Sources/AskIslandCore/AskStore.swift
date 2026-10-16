import Foundation

/// Owns pending requests. The app UI only reads `pending` and calls `resolve`;
/// nothing else holds request state.
@MainActor
public final class AskStore: ObservableObject {
    @Published public private(set) var pending: [AskRequest] = []

    private var continuations: [String: CheckedContinuation<AskResponse, Never>] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]
    private var notifyTasks: [String: Task<Void, Never>] = [:]

    public init() {}

    /// Submits a request. If `id` is empty, generates a UUID string.
    /// Suspends until resolved, timed out, or cancelled.
    /// A second submit with an id already pending returns `.dismissed` immediately.
    /// `.notify` appends to pending, returns `.dismissed` immediately, and auto-removes after 15 s.
    public func submit(_ request: AskRequest) async -> AskResponse {
        var req = request
        if req.id.isEmpty {
            req.id = UUID().uuidString
        }

        if pending.contains(where: { $0.id == req.id }) {
            return AskResponse(id: req.id, status: .dismissed)
        }

        if req.kind == .notify {
            pending.append(req)
            let id = req.id
            let task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                self?.removePendingIfPresent(id: id)
            }
            notifyTasks[id] = task
            return AskResponse(id: req.id, status: .dismissed)
        }

        pending.append(req)

        if let timeout = req.timeoutSeconds, timeout > 0 {
            let id = req.id
            let task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                self?.handleTimeout(id: id)
            }
            timeoutTasks[id] = task
        }

        return await withCheckedContinuation { continuation in
            continuations[req.id] = continuation
        }
    }

    /// Removes and resumes the waiter; unknown id is a no-op;
    /// the response id is forced to the request id.
    public func resolve(_ id: String, _ response: AskResponse) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else {
            return
        }
        pending.remove(at: index)
        timeoutTasks.removeValue(forKey: id)?.cancel()
        notifyTasks.removeValue(forKey: id)?.cancel()

        var res = response
        res.id = id
        if let cont = continuations.removeValue(forKey: id) {
            cont.resume(returning: res)
        }
    }

    /// Removes without a response to anyone who cares (waiter gets `.dismissed`).
    public func cancel(_ id: String) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else {
            return
        }
        pending.remove(at: index)
        timeoutTasks.removeValue(forKey: id)?.cancel()
        notifyTasks.removeValue(forKey: id)?.cancel()

        if let cont = continuations.removeValue(forKey: id) {
            cont.resume(returning: AskResponse(id: id, status: .dismissed))
        }
    }

    private func handleTimeout(id: String) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else {
            return
        }
        pending.remove(at: index)
        timeoutTasks.removeValue(forKey: id)?.cancel()
        if let cont = continuations.removeValue(forKey: id) {
            cont.resume(returning: AskResponse(id: id, status: .timeout))
        }
    }

    private func removePendingIfPresent(id: String) {
        if let index = pending.firstIndex(where: { $0.id == id }) {
            pending.remove(at: index)
        }
        notifyTasks.removeValue(forKey: id)?.cancel()
    }
}
