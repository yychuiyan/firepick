# Agent handbook: iOS native HTTP / JS sources (no Bridge)

Hand this file to Codex or any later agent. Do not rely on chat history.

## Goal (one line)

Firepick iOS runs **HTTP + CatVod JS spiders on-device**. Android Bridge is optional legacy only. Do **not** chase 饭太硬/王二小 Java JAR parity without Bridge.

## Phase status

| Phase | Status | Notes |
| --- | --- | --- |
| 1. HTTP-first UX / no Bridge false alarms | Done | `AppModel` only auto-selects on-device sites; picker splits 本机 / 需安卓 |
| 2. Full on-device CatVod JS host | Done (JSC) | Reused JSContext, ES imports, `assets://` helpers, lifecycle and `net.req` buffers |
| 3. Curated warehouse + COS notes | Done | `sources/ios-sources.json` + `sources/firepick-cms.js` |
| 4. drpy helper compatibility modules | Done | JSON5, URI, node-rsa, pako, gbk, jinja, jsoup, mJSEncrypt |
| Bridge Settings UI | Done | Pairing entry removed from iOS Settings |

## Architecture

```text
Config URL (COS / any HTTPS JSON)
  -> AppModel.applyConfiguration
  -> selectPendingInitialSite (HTTP first, then JS)
  -> ProviderCoordinator
       HTTP  -> HTTPProvider
       JS    -> QuickJSProvider(OnDeviceJavaScriptHost)  // JavaScriptCore
       Java  -> unsupported unless Bridge still paired
```

## File map

| Area | Path |
| --- | --- |
| Auto site + labels | `apps/ios/Firepick/AppModel.swift` (`isOnDeviceCapable`, `onDeviceSites`, `selectSite`, `makeCoordinator`) |
| Picker | `apps/ios/Firepick/SourcePickerView.swift` |
| Empty states | `apps/ios/Firepick/BrowseView.swift` |
| Coordinator | `Packages/FirepickKit/Sources/FirepickProvider/ProviderCoordinator.swift` (`quickJSFactory`) |
| JS host | `Packages/FirepickKit/Sources/FirepickProvider/OnDeviceJavaScriptHost.swift` |
| HTML helpers | `Packages/FirepickKit/Sources/FirepickProvider/CatVodHTMLQuery.swift` |
| Crypto | `Packages/FirepickKit/Sources/FirepickProvider/CatVodCrypto.swift` |
| Provider shim | `Packages/FirepickKit/Sources/FirepickProvider/QuickJSProvider.swift` |
| Smoke fixture | `protocol/fixtures/quickjs-smoke.js` |
| Warehouse template | `docs/examples/ios-sources.example.json` |

## Host capabilities (implemented)

- Spider lifecycle: init / home / category / detail / search / player / action / live / destroy
- `import { … } from 'catvod'` rewritten to `requireCatvod()`
- `net.req` / global `req(url, options)` → Promise `{ code, headers, content, url }`
- Globals / module: `pdfh` `pd` `pdfa` `pdfl`, `local`, `link` / `joinUrl`, `page`
- Crypto (FongMi `Crypto` parity): `aesX` `desX` `rsaX` `md5X` `sha256X` `randomX` + base64
- Async spider methods (Promise) awaited
- Persistent Spider instance and `init` state across home/category/detail/search/player
- Static ES imports, `assets://` modules, built-in cheerio/crypto-js, anonymous default classes
- `action`, `liveContent`, `destroy` wired through QuickJSProvider
- CatVod `buffer` modes 0/1/2/3, params, string/byte/JSON/form bodies
- Bundled drpy helper modules: JSON5, URI.js, node-rsa, pako, GBK, jinja,
  jsoup-style helper, template catalog, JSEncrypt

## Host gaps (do not claim done)

- FongMi QuickJS-NG native binary / identical bytecode
- dialog / WebView / WASM / Web Streams / socket / cache helpers (Bridge-only)
- Perfect hikerview CSS (`:eq` edge cases); improve `CatVodHTMLQuery` when a real spider fails
- Remote helper URLs can themselves return 403; failures are logged and the remaining bundled modules still load

## How to run

```bash
swift test --package-path Packages/FirepickKit --filter ProviderTests
```

Manual:

1. Copy `docs/examples/ios-sources.example.json`, replace APIs with ones you may use.
2. Upload to existing Firepick COS (same bucket as IPA), e.g. `firepick/ios-sources.json`.
3. In app Settings, paste the HTTPS URL — **not** a directory page like `tvbox.clbug.com/user.php`.

The non-production template is published at:

```text
https://firepick-1302621537.cos.ap-shanghai.myqcloud.com/firepick/ios-sources.example.json
```

It intentionally uses `example.com` and is not a usable VOD catalog. Replace it
with authorized endpoints before uploading a real `ios-sources.json`.

The current curated configuration is:

```text
https://dl.yychuiyan.com/firepick/ios-sources.json?v=15
```

Its JavaScript aggregator is:

```text
https://firepick-1302621537.cos.ap-shanghai.myqcloud.com/firepick/sources/firepick-cms.js?v=15
```

Full acceptance probe:

```bash
swift run --package-path Packages/FirepickKit firepick-source-probe \
  --invoke --live --search '庆余年' --site firepick_cms \
  'https://dl.yychuiyan.com/firepick/ios-sources.json?v=15'
```

Expected current shape: one on-device JS site (`拾萤`) backed by seven active
AppleCMS providers (`lzcaiji` / `bfzy` / `subo` / `ffzy_cj` / `jisu` / `dytt` /
`zuid`), synthetic menu buckets, Douban-hot default lists for TV/variety/anime,
non-zero search results for probe keywords, a direct playback URL, and three
parsed live playlists. The larger `sources/providers.whitelist.json` is a
maintenance candidate list, not the active pool. Official app builds prefer the
bundled aggregator; changes to the active provider list require an app release.
Re-probe candidates with `node scripts/probe-cms-providers.mjs` when stale.
The script ranks live hosts and rewrites `DEFAULT_PROVIDERS` in both
`Packages/.../Resources/firepick-cms.js` and `sources/firepick-cms.js`, plus
`AppModel.firepickCMSProviders`.

## Acceptance

- [ ] No Android paired: HTTP site shows home grid
- [x] JS site with CatVod `export default class extends Spider` loads via JSC
- [ ] Pure Java config: no「Android Bridge 不可达」spam; empty/friendly copy + 需安卓 section disabled
- [x] Settings 无 Android Bridge 配对入口

## Forbidden

- Bundling third-party unauthorized VOD catalogs in the app or public docs as defaults
- Re-enabling `preferBridgeForQuickJS: true` as the default product path
- Claiming 饭太硬 Java JAR works on-device
- Restoring Settings → Android Bridge pairing UI without an explicit product decision

## Upstream pins

See `vendor/upstream.lock` (`quickjs_revision`, `catvod_spider_revision`). JS API reference: `third_party/catvod-spider/docs/development.md`.

## Next suggested work

1. Grow `CatVodHTMLQuery` against failing real `.js` spiders
2. Add a compatibility wrapper for drpy2 rule-only sites; do not claim arbitrary
   drpy2 rules work until they have an end-to-end probe
3. Add generic AppleCMS `/share/...` page-to-HLS resolution only when a stable,
   tested URL pattern is known
4. Optional: link QuickJS-NG C for closer FongMi parity
5. Optionally strip remaining Bridge modules / env-only test hooks if product permanently drops Android

## Source reuse policy

Publicly visible code is not automatically licensed for copying. Directly reuse
code only when its license is compatible with this GPL-3.0-only repository and
record the upstream commit in `NOTICE.md`. For repositories without a license,
use them only as behavioral references and implement independently unless the
author grants permission. AGPL-only code must not be merged into this project.
