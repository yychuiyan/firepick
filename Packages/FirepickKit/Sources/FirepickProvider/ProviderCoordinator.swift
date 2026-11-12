import Foundation
import FirepickCore

public actor ProviderCoordinator {
    private let router: SourceRouter
    private let preferBridgeForQuickJS: Bool
    private let bridgeFactory: @Sendable (SiteConfiguration) throws -> any SourceProvider
    private var providers: [String: any SourceProvider] = [:]

    public init(
        router: SourceRouter = .init(),
        preferBridgeForQuickJS: Bool = false,
        bridgeFactory: @escaping @Sendable (SiteConfiguration) throws -> any SourceProvider
    ) {
        self.router = router
        self.preferBridgeForQuickJS = preferBridgeForQuickJS
        self.bridgeFactory = bridgeFactory
    }

    public func provider(for site: SiteConfiguration) throws -> any SourceProvider {
        if let provider = providers[site.key] {
            return provider
        }

        let route = router.route(site)
        let provider: any SourceProvider
        switch route.execution {
        case .onDevice where route.runtime == .http:
            provider = try HTTPProvider(site: site)
        case .onDevice where route.runtime == .quickJS && preferBridgeForQuickJS:
            provider = try bridgeFactory(site)
        case .onDevice where route.runtime == .quickJS:
            throw FirepickError.unsupported("QuickJS 内核尚未链接")
        case .bridge:
            provider = try bridgeFactory(site)
        case .onDevice, .unsupported:
            throw FirepickError.unsupported(route.reason)
        }

        providers[site.key] = provider
        return provider
    }

    public func search(
        sites: [SiteConfiguration],
        keyword: String,
        quick: Bool = false,
        timeout: Duration = .seconds(5),
        maxConcurrent: Int = 8
    ) async -> [String: Result<MediaResult, Error>] {
        enum Event: Sendable {
            case result(String, Result<MediaResult, Error>)
            case timeout
        }

        let eligible = sites.filter { site in
            site.isSearchable && (!quick || site.isQuickSearch)
        }
        guard !eligible.isEmpty else { return [:] }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let gate = ConcurrencyGate(limit: max(1, maxConcurrent))
        let results = await withTaskGroup(of: Event.self) { group in
            for site in eligible {
                group.addTask {
                    await gate.acquire()
                    guard !Task.isCancelled else {
                        await gate.release()
                        return .result(
                            site.key,
                            .failure(CancellationError())
                        )
                    }
                    do {
                        let result = try await self.provider(for: site)
                            .searchContent(keyword: keyword, quick: quick, page: 1)
                        await gate.release()
                        await self.closeSession(for: site.key)
                        return .result(
                            site.key,
                            .success(Self.rankAndLimit(result, keyword: keyword))
                        )
                    } catch {
                        await gate.release()
                        await self.closeSession(for: site.key)
                        return .result(site.key, .failure(error))
                    }
                }
            }
            group.addTask {
                let remaining = clock.now.duration(to: deadline)
                if remaining > .zero {
                    try? await Task.sleep(for: remaining)
                }
                return .timeout
            }

            var values: [Event] = []
            for await event in group {
                if case .timeout = event {
                    group.cancelAll()
                    break
                }
                values.append(event)
                if values.count == eligible.count {
                    group.cancelAll()
                    break
                }
            }
            return values
        }

        await closeAllSessions()
        var output: [String: Result<MediaResult, Error>] = [:]
        for event in results {
            guard case let .result(key, result) = event else { continue }
            output[key] = result
        }
        return output
    }

    private func closeSession(for key: String) async {
        guard let provider = providers.removeValue(forKey: key),
              let closable = provider as? any SessionClosingProvider else {
            return
        }
        await closable.closeSession()
    }

    private func closeAllSessions() async {
        for provider in providers.values {
            guard let closable = provider as? any SessionClosingProvider else {
                continue
            }
            await closable.closeSession()
        }
        providers.removeAll()
    }

    public func invalidate(sourceKey: String? = nil) async {
        let removed: [any SourceProvider]
        if let sourceKey {
            removed = providers.removeValue(forKey: sourceKey).map { [$0] } ?? []
        } else {
            removed = Array(providers.values)
            providers.removeAll()
        }
        for provider in removed {
            if let closable = provider as? any SessionClosingProvider {
                await closable.closeSession()
            }
        }
    }

    private static func rankAndLimit(_ input: MediaResult, keyword: String) -> MediaResult {
        let normalized = keyword
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        func score(_ item: MediaItem) -> Int {
            let name = item.name.lowercased()
            if name == normalized { return 2 }
            if name.contains(normalized) { return 1 }
            return 0
        }
        var result = input
        result.list = Array(
            result.list
                .enumerated()
                .sorted {
                    let left = score($0.element)
                    let right = score($1.element)
                    return left == right ? $0.offset < $1.offset : left > right
                }
                .map(\.element)
                .prefix(50)
        )
        return result
    }
}

private actor ConcurrencyGate {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}

