import Testing
@testable import FirepickCore

struct SourceRouterTests {
    private let router = SourceRouter()

    @Test
    func routesHTTPAndExtendedSourcesOnDevice() {
        for type in [0, 1, 4] {
            let site = SiteConfiguration(key: "http", name: "HTTP", type: type, api: "https://example.com/api")
            let route = router.route(site)
            #expect(route.runtime == .http)
            #expect(route.execution == .onDevice)
        }
    }

    @Test
    func routesCatVodRuntimes() {
        let cases: [(String, Int, ProviderRuntime, ProviderExecution)] = [
            ("./spider.js", 3, .quickJS, .onDevice),
            ("./spider.py", 3, .python, .bridge),
            ("node:https://example.com/index.js", 3, .nodeJS, .bridge),
            ("csp_Demo", 3, .java, .bridge),
        ]

        for (api, type, runtime, execution) in cases {
            let route = router.route(.init(key: api, name: api, type: type, api: api))
            #expect(route.runtime == runtime)
            #expect(route.execution == execution)
        }
    }
}

