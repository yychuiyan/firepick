import FirepickBridge
import FirepickCore
import FirepickProvider
import Foundation

@main
struct SourceProbe {
    static func main() async {
        var urls = Array(CommandLine.arguments.dropFirst())
        let invoke = urls.contains("--invoke")
        urls.removeAll { $0 == "--invoke" }
        guard !urls.isEmpty else {
            print("Usage: firepick-source-probe [--invoke] <config-url> [...]")
            exit(2)
        }

        for rawURL in urls {
            await probe(rawURL, invoke: invoke)
        }
    }

    private static func probe(_ rawURL: String, invoke: Bool) async {
        print("SOURCE \(rawURL)")
        guard let url = URL(string: rawURL) else {
            print("  RESULT invalid-url")
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                print("  RESULT invalid-response")
                return
            }
            print("  HTTP \(http.statusCode) bytes=\(data.count) type=\(http.mimeType ?? "-")")
            let normalized = try ConfigurationDecoder.normalize(data)
            let detected = try ConfigurationDetector.detect(normalized)

            switch detected {
            case let .depot(document):
                print("  RESULT depot count=\(document.urls.count)")
                for depot in document.urls {
                    print("    \(depot.name) -> \(depot.url)")
                }

            case let .live(name, groups):
                let channels = groups.reduce(0) { $0 + $1.channels.count }
                print("  RESULT live name=\(name) groups=\(groups.count) channels=\(channels)")

            case let .vod(configuration):
                let router = SourceRouter()
                let routes = Dictionary(
                    grouping: configuration.sites,
                    by: { router.route($0).runtime.rawValue }
                )
                let routeSummary = routes
                    .map { "\($0.key)=\($0.value.count)" }
                    .sorted()
                    .joined(separator: ",")
                print("  RESULT vod sites=\(configuration.sites.count) lives=\(configuration.lives?.count ?? 0) routes=\(routeSummary)")

                for site in configuration.sites.prefix(12) {
                    let route = router.route(site)
                    print("    \(site.name) [\(route.runtime.rawValue)/\(route.execution.rawValue)] \(site.api)")
                }

                if invoke {
                    let httpSite = configuration.sites.first {
                        SourceRouter().route($0).runtime == .http
                    }
                    try await invokeFirstHTTP(site: httpSite, baseURL: url)
                }
            }
        } catch {
            print("  RESULT error \(String(reflecting: error))")
        }
    }

    private static func invokeFirstHTTP(site: SiteConfiguration?, baseURL: URL) async throws {
        guard let site else { return }
        let router = SourceRouter()
        guard router.route(site).runtime == .http else {
            print("  INVOKE skipped; first site is \(router.route(site).runtime.rawValue)")
            return
        }
        var resolved = site
        if resolved.api.hasPrefix("."),
           let url = URL(string: resolved.api, relativeTo: baseURL) {
            resolved.api = url.absoluteURL.absoluteString
        }

        let provider = try HTTPProvider(site: resolved)
        let home = try await provider.homeContent()
        print("  INVOKE home classes=\(home.classes.count) items=\(home.list.count)")
        guard site.isSearchable else {
            print("  INVOKE search skipped")
            try await invokePlayback(provider: provider, home: home)
            return
        }
        let keyword = home.list.first?.name ?? "测试"
        let search = try await provider.searchContent(keyword: keyword, quick: false, page: 1)
        print("  INVOKE search keyword=\(keyword) items=\(search.list.count)")
        try await invokePlayback(provider: provider, home: home)
    }

    private static func invokePlayback(
        provider: HTTPProvider,
        home: MediaResult
    ) async throws {
        guard let item = home.list.first else {
            print("  PLAYBACK skipped; home has no item")
            return
        }
        let detail = try await provider.detailContent(id: item.vodId)
        guard let vod = detail.list.first else {
            print("  PLAYBACK skipped; detail has no item")
            return
        }
        let lines = EpisodeParser.lines(playFrom: vod.playFrom, playURL: vod.playURL)
        guard let line = lines.first, let episode = line.episodes.first else {
            print("  PLAYBACK skipped; detail has no episode")
            return
        }
        let play = try await provider.playerContent(
            flag: line.name,
            id: episode.value,
            vipFlags: []
        )
        let url = play.url?.playbackURL ?? play.playUrl ?? ""
        print("  PLAYBACK item=\(vod.name) line=\(line.name) episode=\(episode.name) URL=\(url)")
    }
}

