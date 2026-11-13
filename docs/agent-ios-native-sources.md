# Agent handbook: iOS native HTTP / JS sources (no Bridge)

Hand this file to Codex or any later agent. Do not rely on chat history.

## Goal (one line)

Firepick iOS runs **HTTP + CatVod JS spiders on-device**. Android Bridge is optional legacy only. Do **not** chase 饭太硬/王二小 Java JAR parity without Bridge.

## Phase status

| Phase | Status | Notes |
| --- | --- | --- |
| 1. HTTP-first UX / no Bridge false alarms | Done | `AppModel` only auto-selects on-device sites; picker splits 本机 / 需安卓 |
| 2. Full on-device CatVod JS host | Done (JSC) | Reused JSContext, ES imports, `assets://` helpers, lifecycle and `net.req` buffers |
| 3. Example warehouse + COS notes | Done | `docs/examples/ios-sources.example.json` |
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
2. Optional: link QuickJS-NG C for closer FongMi parity
3. Optionally strip remaining Bridge modules / env-only test hooks if product permanently drops Android
