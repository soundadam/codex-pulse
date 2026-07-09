import Foundation

public protocol ThreadDiscoveryService: Sendable {
    func listThreads(limit: Int, cwdFilters: [String]) async throws -> [CodexThreadRef]
}
