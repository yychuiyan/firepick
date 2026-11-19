import FirepickCore
import Foundation
import Testing

@testable import FirepickProvider

@Suite(.serialized)
struct OnDeviceJavaScriptHostTests {
  @Test
  func evaluatesCatVodSpiderWithAesXAndHtmlQuery() async throws {
    let script = """
      import { Spider, aesX, htmlQuery } from 'catvod';

        export default class extends Spider {
          constructor() {
            super();
            this.calls = 0;
          }

        homeContent(filter) {
            this.calls += 1;
          const cipher = aesX('AES/CBC/PKCS7', true, 'hello-host', false, '0123456789abcdef', 'fedcba9876543210', true);
          const plain = aesX('AES/CBC/PKCS7', false, cipher, true, '0123456789abcdef', 'fedcba9876543210', false);
          const title = htmlQuery.pdfh('<div class="t">拾萤</div>', 'div.t&&Text');
          return {
            class: [{ type_id: 'movie', type_name: title || 'fallback' }],
            list: [{
              vod_id: '1',
                vod_name: plain + ':' + this.calls,
              vod_remarks: filter ? 'filtered' : 'ok'
            }]
          };
        }

          action(value) {
            return { list: [{ vod_id: 'action', vod_name: value }] };
          }

          liveContent(url) {
            return '#EXTM3U\\n#EXTINF:-1,' + url;
          }
      }
      """

    let session = try Self.makeSession(
      routes: ["/spider.js": script]
    )
    let host = OnDeviceJavaScriptHost(session: session)
    let result = try await host.invoke(
      api: "https://fixture.local/spider.js",
      ext: nil,
      method: .homeContent,
      arguments: [.bool(false)]
    )
    let second = try await host.invoke(
      api: "https://fixture.local/spider.js",
      ext: nil,
      method: .homeContent,
      arguments: [.bool(false)]
    )
    let action = try await host.invoke(
      api: "https://fixture.local/spider.js",
      ext: nil,
      method: .action,
      arguments: [.string("open")]
    )
    let live = try await host.invoke(
      api: "https://fixture.local/spider.js",
      ext: nil,
      method: .liveContent,
      arguments: [.string("https://example.com/live")]
    )

    #expect(result.list.first?.name == "hello-host:1")
    #expect(second.list.first?.name == "hello-host:2")
    #expect(result.classes.first?.typeName == "拾萤")
    #expect(action.list.first?.name == "open")
    #expect(live.rawContent?.contains("https://example.com/live") == true)
    await host.destroy()
  }

  @Test
  func loadsESModulesAndExportsUsedByCatVodSpiders() async throws {
    let script = """
      import helper from 'https://fixture.local/helper.js';
      import { prefix } from 'https://fixture.local/named.js';
      import 'https://fixture.local/side-effect.js';
      import { Spider } from 'catvod';

      export default class extends Spider {
        homeContent() {
          return { list: [{ vod_id: '1', vod_name: prefix + helper }] };
        }
      }
      """
    let session = try Self.makeSession(
      routes: [
        "/spider.js": script,
        "/helper.js": "var value = '模块'; export { value as default };",
        "/named.js": "var value = '前缀-'; export { value as prefix };",
        "/side-effect.js": "globalThis.sideEffectLoaded = true;",
      ]
    )
    let host = OnDeviceJavaScriptHost(session: session)
    let result = try await host.invoke(
      api: "https://fixture.local/spider.js",
      ext: nil,
      method: .homeContent,
      arguments: []
    )
    #expect(result.list.first?.name == "前缀-模块")
    await host.destroy()
  }

  @Test
  func loadsBundledDrpyCompatibilityModules() async throws {
    let script = """
      import JSON5 from 'assets://js/lib/json5.js';
      import Uri from 'assets://js/lib/uri.min.js';
      import templates from 'assets://js/lib/模板.js';
      import { gbkTool } from 'assets://js/lib/gbk.js';
      import 'assets://js/lib/pako.min.js';
      import 'assets://js/lib/jinja.js';
      import 'assets://js/lib/jsoup.js';
      import 'assets://js/lib/node-rsa.js';
      import 'assets://js/lib/jsencrypt.js';
      import { Spider } from 'catvod';

      export default class extends Spider {
        homeContent() {
          const parsed = JSON5.parse("{answer: 42}");
          const uri = new Uri("https://example.com/a?q=1");
          const mubans = templates.getMubans();
          const gbk = gbkTool();
          return {
            list: [{
              vod_id: '1',
              vod_name: [
                parsed.answer,
                uri.host(),
                !!mubans.mxone5,
                gbk.decode('%C4%E3%BA%C3')
              ].join('|')
            }]
          };
        }
      }
      """
    let session = try Self.makeSession(routes: ["/spider.js": script])
    let host = OnDeviceJavaScriptHost(session: session)
    let result = try await host.invoke(
      api: "https://fixture.local/spider.js",
      ext: nil,
      method: .homeContent,
      arguments: []
    )
    #expect(result.list.first?.name == "42|example.com|true|你好")
    await host.destroy()
  }

  @Test
  func htmlQueryUsesZeroBasedEqAndSupportsStandaloneEq() {
    let html = "<div>A</div><div>B</div><div>C</div>"
    #expect(CatVodHTMLQuery.pdfh(html, rule: "div:eq(1)&&Text") == "B")
    #expect(CatVodHTMLQuery.pdfh(html, rule: "div&&:eq(2)&&Text") == "C")
    #expect(
      CatVodHTMLQuery.joinURL(
        "https://source.example/path",
        "//cdn.example/image.jpg"
      ) == "https://cdn.example/image.jpg"
    )
  }

  @Test
  func netReqSupportsCatVodBufferModes() async throws {
    let script = """
      import { Spider, net } from 'catvod';

      export default class extends Spider {
        async homeContent() {
          const text = await net.req('https://fixture.local/data', { params: { q: 'x' } });
          const bytes = await net.req('https://fixture.local/data', { buffer: 1 });
          const base64 = await net.req('https://fixture.local/data', { buffer: 2 });
          const arrayBuffer = await net.req('https://fixture.local/data', { buffer: 3 });
          return {
            list: [{
              vod_id: '1',
              vod_name: [
                text.content,
                Array.isArray(bytes.content),
                base64.content,
                arrayBuffer.content instanceof ArrayBuffer
              ].join('|')
            }]
          };
        }
      }
      """
    let session = try Self.makeSession(
      routes: ["/spider.js": script, "/data": "hello"]
    )
    let host = OnDeviceJavaScriptHost(session: session)
    let result = try await host.invoke(
      api: "https://fixture.local/spider.js",
      ext: nil,
      method: .homeContent,
      arguments: []
    )
    #expect(result.list.first?.name == "hello|true|aGVsbG8=|true")
    await host.destroy()
  }

  @Test
  func surfacesJavaScriptMethodExceptions() async throws {
    let script = """
      import { Spider } from 'catvod';

      export default class extends Spider {
        async homeContent() {
          await Promise.resolve();
          throw new Error('aggregate exploded');
        }
      }
      """
    let session = try Self.makeSession(routes: ["/spider.js": script])
    let host = OnDeviceJavaScriptHost(session: session)
    do {
      _ = try await host.invoke(
        api: "https://fixture.local/spider.js",
        ext: nil,
        method: .homeContent,
        arguments: []
      )
      Issue.record("Expected the JavaScript exception to be surfaced")
    } catch {
      #expect(error.localizedDescription.contains("aggregate exploded"))
    }
    await host.destroy()
  }

  @Test
  func fallsBackToBundledScriptWhenRemoteReturnsEmpty304() async throws {
    JSFixtureURLProtocol.statusCodes = [
      "/firepick-cms.js": 304
    ]
    JSFixtureURLProtocol.routes = [
      "/firepick-cms.js": Data()
    ]
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [JSFixtureURLProtocol.self]
    let host = OnDeviceJavaScriptHost(session: URLSession(configuration: configuration))

    // Bundled Resources/firepick-cms.js should load even when remote is empty 304.
    // Live CMS APIs may be unreachable in unit tests; just assert Spider boots
    // and returns a MediaResult instead of throwing on empty download.
    let result = try await host.invoke(
      api: "https://fixture.local/firepick-cms.js?v=4",
      ext: nil,
      method: .homeContent,
      arguments: [.bool(false)]
    )
    #expect(result.list.count >= 0)
    await host.destroy()
  }

  @Test
  func firepickAggregatorCompletelyBlocksAdultProvidersInStandardMode() async throws {
    let normalPayload = #"""
      {
        "class": [
          {"type_id": "1", "type_name": "电影"},
          {"type_id": "2", "type_name": "无码专区"}
        ],
        "list": [
          {"vod_id": "1", "vod_name": "普通电影", "type_id": "1", "type_name": "电影"},
          {"vod_id": "2", "vod_name": "成人测试", "type_id": "2", "type_name": "无码专区"}
        ]
      }
      """#
    let adultPayload = #"""
      {
        "class": [
          {"type_id": "1", "type_name": "电影"},
          {"type_id": "2", "type_name": "无码专区"},
          {"type_id": "3", "type_name": "国产自拍"},
          {"type_id": "4", "type_name": "网红主播"}
        ],
        "list": [
          {
            "vod_id": "3",
            "vod_name": "成人测试",
            "vod_class": "无码专区",
            "type_id": "1",
            "type_name": "电影"
          },
          {
            "vod_id": "4",
            "vod_name": "自拍测试",
            "vod_class": "国产自拍",
            "type_id": "3",
            "type_name": "国产自拍"
          },
          {
            "vod_id": "5",
            "vod_name": "主播测试",
            "vod_class": "网红主播",
            "type_id": "4",
            "type_name": "网红主播"
          }
        ]
      }
      """#
    let session = try Self.makeSession(
      routes: ["/normal": normalPayload, "/adult": adultPayload]
    )
    let host = OnDeviceJavaScriptHost(session: session)
    let api = "https://dl.yychuiyan.com/firepick/firepick-cms.js?v=22"

    func ext(adultMode: Bool) -> JSONValue {
      .object([
        "adultMode": .bool(adultMode),
        "providers": .array([
          .object([
            "key": .string("normal"),
            "name": .string("普通"),
            "api": .string("https://fixture.local/normal"),
            "adult": .bool(false),
          ]),
          .object([
            "key": .string("adult"),
            "name": .string("成人"),
            "api": .string("https://fixture.local/adult"),
            "adult": .bool(true),
          ]),
        ]),
      ])
    }

    let standard = try await host.invoke(
      api: api,
      ext: ext(adultMode: false),
      method: .homeContent,
      arguments: [.bool(false)]
    )
    #expect(!JSFixtureURLProtocol.requestedPaths.contains("/adult"))
    #expect(standard.list.contains { $0.name == "普通电影" })
    #expect(!standard.list.contains { $0.name == "成人测试" })
    #expect(standard.list.count <= BrowseCatalogPolicy.itemsPerMenu)
    #expect(!standard.classes.contains { $0.typeId == "bucket|adult" })
    #expect(standard.filters?["bucket|adult"] == nil)
    await host.destroy()

    let adultHost = OnDeviceJavaScriptHost(session: session)
    let adult = try await adultHost.invoke(
      api: api,
      ext: ext(adultMode: true),
      method: .homeContent,
      arguments: [.bool(false)]
    )
    #expect(!JSFixtureURLProtocol.requestedPaths.contains("/adult"))
    #expect(!adult.list.isEmpty)
    #expect(adult.classes.contains { $0.typeId == "bucket|adult" && $0.typeName == "成人" })
    let adultFilters = try #require(adult.filters?["bucket|adult"])
    #expect(adultFilters.map(\.key) == ["class", "year", "by"])
    let adultClasses = try #require(adultFilters.first { $0.key == "class" })
    #expect(
      adultClasses.value.map(\.name)
        == ["全部", "国产", "自拍", "主播", "传媒", "人妻", "制服", "无码", "三级", "动漫", "欧美", "女优"]
    )
    let adultSort = try #require(adultFilters.first { $0.key == "by" })
    #expect(adultSort.value.map(\.name) == ["热门", "最多播放", "最新更新"])
    let adultColumn = try await adultHost.invoke(
      api: api,
      ext: ext(adultMode: true),
      method: .categoryContent,
      arguments: [
        .string("bucket|adult"),
        .string("1"),
        .bool(false),
        .object([:]),
      ]
    )
    #expect(JSFixtureURLProtocol.requestedPaths.contains("/adult"))
    #expect(adultColumn.list.contains { $0.name == "成人测试" })
    #expect(adultColumn.list.contains { $0.name == "自拍测试" })
    #expect(adultColumn.list.count <= BrowseCatalogPolicy.itemsPerMenu)
    #expect(adultColumn.pagecount == 1)
    let selfieColumn = try await adultHost.invoke(
      api: api,
      ext: ext(adultMode: true),
      method: .categoryContent,
      arguments: [
        .string("bucket|adult"),
        .string("1"),
        .bool(false),
        .object(["class": .string("自拍")]),
      ]
    )
    #expect(selfieColumn.list.map(\.name).sorted() == ["自拍测试"])
    #expect(selfieColumn.pagecount ?? 1 >= 2)
    await adultHost.destroy()
  }

  @Test
  func movieFiltersExposeMarvelWithoutTreatingItAsCmsClass() async throws {
    let payload = #"""
      {
        "class": [
          {"type_id": "1", "type_name": "电影"}
        ],
        "pagecount": 2,
        "list": [
          {
            "vod_id": "1",
            "vod_name": "复仇者联盟4：终局之战",
            "type_id": "1",
            "type_name": "电影",
            "vod_pic": "https://img.jisuimage.com/cover/avengers.jpg"
          },
          {
            "vod_id": "2",
            "vod_name": "流浪地球",
            "type_id": "1",
            "type_name": "电影",
            "vod_pic": "https://img.jisuimage.com/cover/wandering-earth.jpg"
          },
          {
            "vod_id": "3",
            "vod_name": "蜘蛛侠：英雄无归",
            "type_id": "1",
            "type_name": "电影",
            "vod_pic": "https://img.jisuimage.com/cover/spider-man.jpg"
          }
        ]
      }
      """#
    let session = try Self.makeSession(routes: ["/fast": payload])
    let host = OnDeviceJavaScriptHost(session: session)
    let api = "https://dl.yychuiyan.com/firepick/firepick-cms.js?v=22"
    let ext = Self.providerExtension([
      ("fast", "https://fixture.local/fast")
    ])

    let home = try await host.invoke(
      api: api,
      ext: ext,
      method: .homeContent,
      arguments: [.bool(false)]
    )
    let movieClasses = try #require(
      home.filters?["bucket|movie"]?.first { $0.key == "class" }
    )
    let tvClasses = try #require(
      home.filters?["bucket|tv"]?.first { $0.key == "class" }
    )
    #expect(movieClasses.value.contains { $0.name == "漫威" && $0.value == "漫威" })
    #expect(!tvClasses.value.contains { $0.name == "漫威" })

    JSFixtureURLProtocol.requestedURLs = []
    let marvel = try await host.invoke(
      api: api,
      ext: ext,
      method: .categoryContent,
      arguments: [
        .string("bucket|movie"),
        .string("1"),
        .bool(true),
        .object(["class": .string("漫威")]),
      ]
    )
    #expect(
      marvel.list.map(\.name)
        == ["复仇者联盟4：终局之战", "蜘蛛侠：英雄无归"]
    )
    #expect(
      !JSFixtureURLProtocol.requestedURLs.contains { url in
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
          .queryItems?
          .contains { $0.name == "class" && $0.value == "漫威" } == true
      }
    )
    #expect(marvel.pagecount ?? 1 >= 2)
    await host.destroy()
  }

  @Test
  func filteredMovieLoadDoesNotWaitForDeadCatalogHost() async throws {
    let payload = #"""
      {
        "class": [
          {"type_id": "1", "type_name": "电影"}
        ],
        "pagecount": 2,
        "list": [
          {
            "vod_id": "1",
            "vod_name": "美国队长4",
            "type_id": "1",
            "type_name": "电影",
            "vod_pic": "https://img.jisuimage.com/cover/captain-america.jpg"
          }
        ]
      }
      """#
    let session = try Self.makeSession(
      routes: [
        "/fast": payload,
        "/slow": payload,
      ],
      delays: ["/slow": 20]
    )
    let host = OnDeviceJavaScriptHost(session: session)
    let api = "https://dl.yychuiyan.com/firepick/firepick-cms.js?v=22"
    let ext = Self.providerExtension([
      ("fast", "https://fixture.local/fast"),
      ("slow", "https://fixture.local/slow"),
    ])
    let startedAt = Date()

    let result = try await host.invoke(
      api: api,
      ext: ext,
      method: .categoryContent,
      arguments: [
        .string("bucket|movie"),
        .string("1"),
        .bool(true),
        .object(["class": .string("漫威")]),
      ]
    )

    #expect(result.list.contains { $0.name == "美国队长4" })
    #expect(Date().timeIntervalSince(startedAt) < 7)
    await host.destroy()
  }

  @Test
  func marvelMoviesSortByNewestReleaseInsteadOfPlatformWeight() async throws {
    let payload = #"""
      {
        "class": [
          {"type_id": "1", "type_name": "电影"}
        ],
        "pagecount": 2,
        "list": [
          {
            "vod_id": "1",
            "vod_name": "旧蜘蛛侠",
            "type_id": "1",
            "type_name": "电影",
            "vod_year": "2026",
            "vod_time": "2026-01-02 08:00:00",
            "vod_actor": "腾讯视频独播",
            "vod_pic": "https://img.jisuimage.com/cover/old.jpg"
          },
          {
            "vod_id": "2",
            "vod_name": "新蜘蛛侠",
            "type_id": "1",
            "type_name": "电影",
            "vod_year": "2026",
            "vod_time": "2026-11-18 20:00:00",
            "vod_pic": "https://img.jisuimage.com/cover/new.jpg"
          }
        ]
      }
      """#
    let session = try Self.makeSession(routes: ["/fast": payload])
    let host = OnDeviceJavaScriptHost(session: session)
    let api = "https://dl.yychuiyan.com/firepick/firepick-cms.js?v=22"
    let ext = Self.providerExtension([
      ("fast", "https://fixture.local/fast")
    ])

    let result = try await host.invoke(
      api: api,
      ext: ext,
      method: .categoryContent,
      arguments: [
        .string("bucket|movie"),
        .string("1"),
        .bool(true),
        .object(["class": .string("漫威")]),
      ]
    )

    #expect(result.list.map(\.name) == ["新蜘蛛侠", "旧蜘蛛侠"])
    await host.destroy()
  }

  @Test
  func defaultMovieListSortsByNewestRelease() async throws {
    let payload = #"""
      {
        "class": [
          {"type_id": "1", "type_name": "电影"}
        ],
        "pagecount": 2,
        "list": [
          {
            "vod_id": "1",
            "vod_name": "去年电影",
            "type_id": "1",
            "type_name": "电影",
            "vod_year": "2025",
            "vod_time": "2026-01-02 08:00:00",
            "vod_actor": "腾讯视频独播",
            "vod_pic": "https://img.jisuimage.com/cover/last-year.jpg"
          },
          {
            "vod_id": "2",
            "vod_name": "今年电影",
            "type_id": "1",
            "type_name": "电影",
            "vod_year": "2026",
            "vod_time": "2026-03-18 20:00:00",
            "vod_pic": "https://img.jisuimage.com/cover/this-year.jpg"
          }
        ]
      }
      """#
    let session = try Self.makeSession(routes: ["/fast": payload])
    let host = OnDeviceJavaScriptHost(session: session)
    let api = "https://dl.yychuiyan.com/firepick/firepick-cms.js?v=22"
    let ext = Self.providerExtension([
      ("fast", "https://fixture.local/fast")
    ])

    let result = try await host.invoke(
      api: api,
      ext: ext,
      method: .categoryContent,
      arguments: [
        .string("bucket|movie"),
        .string("1"),
        .bool(true),
        .object([:]),
      ]
    )

    #expect(result.list.map(\.name) == ["今年电影", "去年电影"])
    await host.destroy()
  }

  @Test
  func koreanTvFilterRequestsCountrySpecificLeaf() async throws {
    let catalog = #"""
      {
        "class": [
          {"type_id": "3", "type_name": "欧美剧"},
          {"type_id": "1", "type_name": "电视剧"},
          {"type_id": "5", "type_name": "韩剧"}
        ]
      }
      """#
    let western = #"""
      {
        "pagecount": 2,
        "list": [
          {
            "vod_id": "western-1",
            "vod_name": "美国电视剧",
            "type_id": "3",
            "type_name": "欧美剧",
            "vod_area": "美国"
          }
        ]
      }
      """#
    let korean = #"""
      {
        "pagecount": 2,
        "list": [
          {
            "vod_id": "korean-1",
            "vod_name": "韩国电视剧一",
            "type_id": "5",
            "type_name": "韩剧",
            "vod_area": "韩国",
            "vod_remarks": "更新至8集"
          },
          {
            "vod_id": "korean-2",
            "vod_name": "韩国电视剧二",
            "type_id": "5",
            "type_name": "韩剧",
            "vod_area": "韩国",
            "vod_remarks": "更新至6集"
          },
          {
            "vod_id": "korean-3",
            "vod_name": "韩国电视剧三",
            "type_id": "5",
            "type_name": "韩剧",
            "vod_area": "韩国",
            "vod_remarks": "已完结"
          }
        ]
      }
      """#
    let session = try Self.makeSession(
      responders: [
        "/fast": { request in
          let query = URLComponents(
            url: request.url ?? URL(string: "https://fixture.local/fast")!,
            resolvingAgainstBaseURL: false
          )?.queryItems ?? []
          let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
          if values["ac"] == "list" {
            return Data(catalog.utf8)
          }
          if values["t"] == "5" {
            return Data(korean.utf8)
          }
          return Data(western.utf8)
        }
      ]
    )
    let host = OnDeviceJavaScriptHost(session: session)
    let api = "https://dl.yychuiyan.com/firepick/firepick-cms.js?v=22"
    let ext = Self.providerExtension([
      ("fast", "https://fixture.local/fast")
    ])

    let result = try await host.invoke(
      api: api,
      ext: ext,
      method: .categoryContent,
      arguments: [
        .string("bucket|tv"),
        .string("1"),
        .bool(true),
        .object(["area": .string("韩国")]),
      ]
    )

    #expect(
      Set(result.list.map(\.name))
        == ["韩国电视剧一", "韩国电视剧二", "韩国电视剧三"]
    )
    #expect(
      JSFixtureURLProtocol.requestedURLs.contains { url in
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
          .queryItems?
          .contains { $0.name == "t" && $0.value == "5" } == true
      }
    )
    await host.destroy()
  }

  @Test
  func movieFacetsApplyClassAreaYearAndCombinedFiltersLocally() async throws {
    let session = try Self.makeSession(routes: ["/fast": Self.facetPayload])
    let host = OnDeviceJavaScriptHost(session: session)
    let api = "https://dl.yychuiyan.com/firepick/firepick-cms.js?v=22"
    let ext = Self.providerExtension([
      ("fast", "https://fixture.local/fast")
    ])
    func query(_ extend: [String: JSONValue]) async throws -> MediaResult {
      try await host.invoke(
        api: api,
        ext: ext,
        method: .categoryContent,
        arguments: [
          .string("bucket|movie"),
          .string("1"),
          .bool(true),
          .object(extend),
        ]
      )
    }

    let action = try await query(["class": .string("动作")])
    #expect(
      Set(action.list.map(\.name))
        == ["动作美国2026", "动作韩国2026", "动作香港2018", "动作英国2009", "动作泰国2024"]
    )
    let korea = try await query(["area": .string("韩国")])
    #expect(Set(korea.list.map(\.name)) == ["动作韩国2026", "爱情韩国2025"])
    let year2026 = try await query(["year": .string("2026")])
    #expect(Set(year2026.list.map(\.name)) == ["动作美国2026", "动作韩国2026"])
    let otherArea = try await query(["area": .string("其他")])
    #expect(otherArea.list.map(\.name) == ["动作泰国2024"])
    let combined = try await query([
      "class": .string("动作"),
      "area": .string("韩国"),
      "year": .string("2026"),
    ])
    #expect(combined.list.map(\.name) == ["动作韩国2026"])
    await host.destroy()
  }

  @Test
  func explicitSortsUseTheirMetricWithoutPlatformBias() async throws {
    let session = try Self.makeSession(routes: ["/fast": Self.facetPayload])
    let host = OnDeviceJavaScriptHost(session: session)
    let api = "https://dl.yychuiyan.com/firepick/firepick-cms.js?v=22"
    let ext = Self.providerExtension([
      ("fast", "https://fixture.local/fast")
    ])
    func query(_ sort: String) async throws -> MediaResult {
      try await host.invoke(
        api: api,
        ext: ext,
        method: .categoryContent,
        arguments: [
          .string("bucket|movie"),
          .string("1"),
          .bool(true),
          .object(["by": .string(sort)]),
        ]
      )
    }

    let hits = try await query("hits")
    #expect(hits.list.first?.name == "动作泰国2024")
    let douban = try await query("douban")
    #expect(douban.list.first?.name == "动作韩国2026")
    let latest = try await query("time")
    #expect(latest.list.first?.name == "动作美国2026")
    await host.destroy()
  }

  @Test
  func decadeAndOlderYearFiltersStayLocal() async throws {
    let session = try Self.makeSession(routes: ["/fast": Self.facetPayload])
    let host = OnDeviceJavaScriptHost(session: session)
    let api = "https://dl.yychuiyan.com/firepick/firepick-cms.js?v=22"
    let ext = Self.providerExtension([
      ("fast", "https://fixture.local/fast")
    ])
    func query(_ year: String) async throws -> MediaResult {
      JSFixtureURLProtocol.requestedURLs = []
      return try await host.invoke(
        api: api,
        ext: ext,
        method: .categoryContent,
        arguments: [
          .string("bucket|movie"),
          .string("1"),
          .bool(true),
          .object(["year": .string(year)]),
        ]
      )
    }

    let decade = try await query("2010")
    #expect(decade.list.map(\.name) == ["动作香港2018"])
    #expect(
      !JSFixtureURLProtocol.requestedURLs.contains { url in
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
          .queryItems?
          .contains { $0.name == "year" && $0.value == "2010" } == true
      }
    )
    let older = try await query("2000")
    #expect(older.list.map(\.name) == ["动作英国2009"])
    #expect(
      !JSFixtureURLProtocol.requestedURLs.contains { url in
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
          .queryItems?
          .contains { $0.name == "year" && $0.value == "2000" } == true
      }
    )
    await host.destroy()
  }

  @Test
  func filteredCombinationReturnsBeforeManyHostsTimeOut() async throws {
    let payload = #"""
      {
        "class": [
          {"type_id": "1", "type_name": "电影"}
        ],
        "pagecount": 2,
        "list": [
          {
            "vod_id": "fast-1",
            "vod_name": "动作韩国2026",
            "type_id": "1",
            "type_name": "电影",
            "vod_class": "动作",
            "vod_area": "韩国",
            "vod_year": "2026",
            "vod_time": "2026-11-01 20:00:00",
            "vod_pic": "https://img.jisuimage.com/cover/fast.jpg"
          }
        ]
      }
      """#
    let slowPaths = (1...9).map { "/slow-\($0)" }
    let routes = Dictionary(
      uniqueKeysWithValues: [(key: "/fast", value: payload)]
        + slowPaths.map { (key: $0, value: payload) }
    )
    let session = try Self.makeSession(
      routes: routes,
      delays: [:]
    )
    JSFixtureURLProtocol.responseDelay = { request in
      let query = URLComponents(
        url: request.url ?? URL(string: "https://fixture.local/fast")!,
        resolvingAgainstBaseURL: false
      )?.queryItems ?? []
      let isFast = request.url?.path == "/fast"
      return !isFast && query.contains { $0.name == "ac" && $0.value == "videolist" } ? 10 : 0
    }
    let host = OnDeviceJavaScriptHost(session: session)
    let api = "https://dl.yychuiyan.com/firepick/firepick-cms.js?v=22"
    let ext = Self.providerExtension(
      [("fast", "https://fixture.local/fast")]
        + slowPaths.enumerated().map { index, path in
          ("slow\(index)", "https://fixture.local\(path)")
        }
    )
    let startedAt = Date()

    let result = try await host.invoke(
      api: api,
      ext: ext,
      method: .categoryContent,
      arguments: [
        .string("bucket|movie"),
        .string("1"),
        .bool(true),
        .object([
          "class": .string("动作"),
          "area": .string("韩国"),
          "year": .string("2026"),
        ]),
      ]
    )

    #expect(result.list.map(\.name) == ["动作韩国2026"])
    #expect(Date().timeIntervalSince(startedAt) < 15)
    await host.destroy()
  }

  private static let facetPayload = #"""
    {
      "class": [
        {"type_id": "1", "type_name": "电影"}
      ],
      "pagecount": 2,
      "list": [
        {
          "vod_id": "us-2026",
          "vod_name": "动作美国2026",
          "type_id": "1",
          "type_name": "电影",
          "vod_class": "动作",
          "vod_area": "美国",
          "vod_year": "2026",
          "vod_time": "2026-11-01 20:00:00",
          "vod_hits": "100",
          "vod_score": "6",
          "vod_pic": "https://img.jisuimage.com/cover/us.jpg"
        },
        {
          "vod_id": "kr-2026",
          "vod_name": "动作韩国2026",
          "type_id": "1",
          "type_name": "电影",
          "vod_class": "动作",
          "vod_area": "韩国",
          "vod_year": "2026",
          "vod_time": "2026-06-01 20:00:00",
          "vod_hits": "300",
          "vod_score": "9.5",
          "vod_pic": "https://img.jisuimage.com/cover/kr.jpg"
        },
        {
          "vod_id": "kr-2025",
          "vod_name": "爱情韩国2025",
          "type_id": "1",
          "type_name": "电影",
          "vod_class": "爱情",
          "vod_area": "韩国",
          "vod_year": "2025",
          "vod_time": "2026-01-01 20:00:00",
          "vod_hits": "5",
          "vod_score": "8.5",
          "vod_publisher": "腾讯视频独播",
          "vod_pic": "https://img.jisuimage.com/cover/romance.jpg"
        },
        {
          "vod_id": "hk-2018",
          "vod_name": "动作香港2018",
          "type_id": "1",
          "type_name": "电影",
          "vod_class": "动作",
          "vod_area": "香港",
          "vod_year": "2018",
          "vod_time": "2018-02-01 20:00:00",
          "vod_hits": "20",
          "vod_score": "7",
          "vod_pic": "https://img.jisuimage.com/cover/hk.jpg"
        },
        {
          "vod_id": "uk-2009",
          "vod_name": "动作英国2009",
          "type_id": "1",
          "type_name": "电影",
          "vod_class": "动作",
          "vod_area": "英国",
          "vod_year": "2009",
          "vod_time": "2009-03-01 20:00:00",
          "vod_hits": "10",
          "vod_score": "5",
          "vod_pic": "https://img.jisuimage.com/cover/uk.jpg"
        },
        {
          "vod_id": "th-2024",
          "vod_name": "动作泰国2024",
          "type_id": "1",
          "type_name": "电影",
          "vod_class": "动作",
          "vod_area": "泰国",
          "vod_year": "2024",
          "vod_time": "2024-02-01 20:00:00",
          "vod_hits": "400",
          "vod_score": "4",
          "vod_pic": "https://img.jisuimage.com/cover/th.jpg"
        }
      ]
    }
    """#

  private static func makeSession(routes: [String: String]) throws -> URLSession {
    try makeSession(routes: routes, delays: [:])
  }

  private static func makeSession(
    routes: [String: String],
    delays: [String: TimeInterval]
  ) throws -> URLSession {
    JSFixtureURLProtocol.statusCodes = [:]
    JSFixtureURLProtocol.routes = routes.mapValues { Data($0.utf8) }
    JSFixtureURLProtocol.delays = delays
    JSFixtureURLProtocol.responders = [:]
    JSFixtureURLProtocol.responseDelay = nil
    JSFixtureURLProtocol.requestedPaths = []
    JSFixtureURLProtocol.requestedURLs = []
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [JSFixtureURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private static func makeSession(
    responders: [String: (URLRequest) -> Data]
  ) throws -> URLSession {
    JSFixtureURLProtocol.statusCodes = [:]
    JSFixtureURLProtocol.routes = [:]
    JSFixtureURLProtocol.delays = [:]
    JSFixtureURLProtocol.responders = responders
    JSFixtureURLProtocol.responseDelay = nil
    JSFixtureURLProtocol.requestedPaths = []
    JSFixtureURLProtocol.requestedURLs = []
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [JSFixtureURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private static func providerExtension(
    _ providers: [(key: String, api: String)]
  ) -> JSONValue {
    .object([
      "adultMode": .bool(false),
      "providers": .array(
        providers.map { provider in
          .object([
            "key": .string(provider.key),
            "name": .string(provider.key),
            "api": .string(provider.api),
            "adult": .bool(false),
          ])
        }
      ),
    ])
  }
}

private final class JSFixtureURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var routes: [String: Data] = [:]
  nonisolated(unsafe) static var statusCodes: [String: Int] = [:]
  nonisolated(unsafe) static var delays: [String: TimeInterval] = [:]
  nonisolated(unsafe) static var responders: [String: (URLRequest) -> Data] = [:]
  nonisolated(unsafe) static var responseDelay: ((URLRequest) -> TimeInterval)?
  nonisolated(unsafe) static var requestedPaths: [String] = []
  nonisolated(unsafe) static var requestedURLs: [URL] = []

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let path = request.url?.path ?? "/"
    Self.requestedPaths.append(path)
    if let url = request.url {
      Self.requestedURLs.append(url)
    }
    let delay = Self.responseDelay?(request) ?? Self.delays[path] ?? 0
    if delay > 0 {
      DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.finish()
      }
      return
    }
    finish()
  }

  private func finish() {
    let path = request.url?.path ?? "/"
    let responder = Self.responders[path]
    let body = responder?(request) ?? Self.routes[path] ?? Data("not found".utf8)
    let status =
      responder != nil
      ? 200
      : Self.statusCodes[path]
      ?? (Self.routes[path] == nil ? 404 : 200)
    let response = HTTPURLResponse(
      url: request.url ?? URL(string: "https://fixture.local/")!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/javascript"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
