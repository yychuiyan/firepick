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
    let searchKeyword: String?
    if let index = urls.firstIndex(of: "--search"), index + 1 < urls.count {
      searchKeyword = urls[index + 1]
      urls.removeSubrange(index...index + 1)
    } else {
      searchKeyword = nil
    }
    let siteKey: String?
    if let index = urls.firstIndex(of: "--site"), index + 1 < urls.count {
      siteKey = urls[index + 1]
      urls.removeSubrange(index...index + 1)
    } else {
      siteKey = nil
    }
    guard !urls.isEmpty else {
      print(
        "Usage: firepick-source-probe [--invoke] [--search <keyword>] [--site <key>] <config-url> [...]"
      )
      exit(2)
    }

    for rawURL in urls {
      await probe(
        rawURL,
        invoke: invoke,
        searchKeyword: searchKeyword,
        siteKey: siteKey
      )
    }
  }

  private static func probe(
    _ rawURL: String,
    invoke: Bool,
    searchKeyword: String?,
    siteKey: String?
  ) async {
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
      case .depot(let document):
        print("  RESULT depot count=\(document.urls.count)")
        for depot in document.urls {
          print("    \(depot.name) -> \(depot.url)")
        }

      case .live(let name, let groups):
        let channels = groups.reduce(0) { $0 + $1.channels.count }
        print("  RESULT live name=\(name) groups=\(groups.count) channels=\(channels)")

      case .vod(let configuration):
        let router = SourceRouter()
        let routes = Dictionary(
          grouping: configuration.sites,
          by: { router.route($0).runtime.rawValue }
        )
        let routeSummary =
          routes
          .map { "\($0.key)=\($0.value.count)" }
          .sorted()
          .joined(separator: ",")
        print(
          "  RESULT vod sites=\(configuration.sites.count) lives=\(configuration.lives?.count ?? 0) routes=\(routeSummary)"
        )

        for site in configuration.sites.prefix(12) {
          let route = router.route(site)
          print(
            "    \(site.name) [\(route.runtime.rawValue)/\(route.execution.rawValue)] \(site.api)")
        }

        if invoke {
          try await invokeFirstOnDevice(
            configuration: configuration,
            baseURL: url,
            searchKeyword: searchKeyword,
            siteKey: siteKey
          )
        }
      }
    } catch {
      print("  RESULT error \(String(reflecting: error))")
    }
  }

  private static func invokeFirstOnDevice(
    configuration: VodConfiguration,
    baseURL: URL,
    searchKeyword: String?,
    siteKey: String?
  ) async throws {
    let site =
      siteKey.flatMap { key in
        configuration.sites.first { $0.key == key }
      }
      ?? configuration.sites.first {
        let route = SourceRouter().route($0)
        return route.execution == .onDevice && route.runtime == .http
      }
      ?? configuration.sites.first {
        let route = SourceRouter().route($0)
        return route.execution == .onDevice && route.runtime == .quickJS
      }
    guard let site else { return }
    let router = SourceRouter()
    var resolved = site
    if resolved.api.hasPrefix("."),
      let url = URL(string: resolved.api, relativeTo: baseURL)
    {
      resolved.api = url.absoluteURL.absoluteString
    }
    if case .string(let ext)? = resolved.ext {
      let value = ext.components(separatedBy: "$$$").map { component in
        guard component.hasPrefix("."),
          let url = URL(string: component, relativeTo: baseURL)
        else {
          return component
        }
        return url.absoluteURL.absoluteString
      }.joined(separator: "$$$")
      resolved.ext = .string(value)
    }

    let provider: any SourceProvider
    if router.route(resolved).runtime == .http {
      provider = try HTTPProvider(site: resolved)
    } else {
      provider = QuickJSProvider(
        site: resolved,
        host: OnDeviceJavaScriptHost(baseURL: baseURL)
      )
    }
    let home = try await provider.homeContent()
    print("  INVOKE \(resolved.name) home classes=\(home.classes.count) items=\(home.list.count)")
    guard site.isSearchable || searchKeyword != nil else {
      print("  INVOKE search skipped")
      if let provider = provider as? HTTPProvider {
        try await invokePlayback(provider: provider, home: home)
      }
      return
    }
    let keyword = searchKeyword ?? home.list.first?.name ?? "测试"
    let search = try await provider.searchContent(keyword: keyword, quick: false, page: 1)
    print("  INVOKE search keyword=\(keyword) items=\(search.list.count)")
    if let provider = provider as? HTTPProvider {
      try await invokePlayback(provider: provider, home: home)
    }
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
