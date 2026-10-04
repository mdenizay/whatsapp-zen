import CWACore
import Foundation

struct CoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Swift face of the Go core: JSON commands in, JSON replies and events out.
enum Core {
    private static let queue = DispatchQueue(label: "wacore.calls", qos: .userInitiated, attributes: .concurrent)

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private struct Reply<T: Decodable>: Decodable {
        let error: String?
        let data: T?
    }

    private struct Ignored: Decodable {
        init(from decoder: Decoder) throws {}
    }

    /// The account that calls address unless they name another one. Views only
    /// ever show the active account, so they can rely on this.
    static var active = "main"

    /// Boots the core. Events are delivered to the model on the main thread.
    static func start(dataDir: String) {
        WAStart(dataDir) { ptr in
            guard let ptr else { return }
            let data = Data(bytes: ptr, count: strlen(ptr))
            DispatchQueue.main.async { AppModel.shared.handleEvent(data) }
        }
    }

    private static func raw(_ cmd: String, _ args: [String: Any], _ account: String) throws -> Data {
        var req = args
        req["cmd"] = cmd
        req["account"] = account
        let json = String(decoding: try JSONSerialization.data(withJSONObject: req), as: UTF8.self)
        guard let p = WACall(json) else { throw CoreError(message: "no reply") }
        defer { WAFree(p) }
        return Data(bytes: p, count: strlen(p))
    }

    private static func onQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result(catching: work)) }
        }
    }

    /// Runs a command and decodes its result.
    static func call<T: Decodable>(_ cmd: String, _ args: [String: Any] = [:], account: String? = nil) async throws -> T {
        let account = account ?? active
        return try await onQueue {
            let reply = try decoder.decode(Reply<T>.self, from: try raw(cmd, args, account))
            if let error = reply.error { throw CoreError(message: error) }
            guard let data = reply.data else { throw CoreError(message: "empty reply") }
            return data
        }
    }

    /// Runs a command whose result does not matter.
    static func run(_ cmd: String, _ args: [String: Any] = [:], account: String? = nil) async throws {
        let account = account ?? active
        try await onQueue {
            let reply = try decoder.decode(Reply<Ignored>.self, from: try raw(cmd, args, account))
            if let error = reply.error { throw CoreError(message: error) }
        }
    }

    /// Fire-and-forget variant for commands where failure needs no handling.
    static func fire(_ cmd: String, _ args: [String: Any] = [:], account: String? = nil) {
        let account = account ?? active
        Task { try? await run(cmd, args, account: account) }
    }

    /// The account folders the core knows about. Synchronous; used at launch.
    static func accountIDs() -> [String] {
        guard let data = try? raw("accounts", [:], ""),
              let reply = try? decoder.decode(Reply<[String]>.self, from: data) else { return [] }
        return reply.data ?? []
    }
}
