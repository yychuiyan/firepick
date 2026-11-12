import Foundation

public enum ProviderRuntime: String, Codable, CaseIterable, Sendable {
    case http
    case quickJS
    case python
    case nodeJS
    case java
    case thunder
    case bdj
    case nativeCore
}

public enum ProviderExecution: String, Codable, Sendable {
    case onDevice
    case bridge
    case unsupported
}

public struct ProviderRoute: Equatable, Sendable {
    public let runtime: ProviderRuntime
    public let execution: ProviderExecution
    public let reason: String

    public init(runtime: ProviderRuntime, execution: ProviderExecution, reason: String) {
        self.runtime = runtime
        self.execution = execution
        self.reason = reason
    }
}

public struct SourceRouter: Sendable {
    public init() {}

    public func route(_ site: SiteConfiguration) -> ProviderRoute {
        let api = site.api.lowercased()
        if api.hasPrefix("node:") {
            return .init(runtime: .nodeJS, execution: .bridge, reason: "Node.js source")
        }
        if api.hasSuffix(".js") || api.contains(".js?") {
            return .init(runtime: .quickJS, execution: .onDevice, reason: "QuickJS source")
        }
        if api.hasSuffix(".py") || api.contains(".py?") {
            return .init(runtime: .python, execution: .bridge, reason: "Python source")
        }
        if api.hasPrefix("csp_") || (site.effectiveType == 3 && !api.isEmpty) {
            return .init(runtime: .java, execution: .bridge, reason: "Java CatVod source")
        }
        switch site.effectiveType {
        case 0, 1, 4:
            return .init(runtime: .http, execution: .onDevice, reason: "HTTP source")
        default:
            return .init(runtime: .java, execution: .bridge, reason: "Legacy type-3 source")
        }
    }
}

