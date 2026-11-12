# Implementation status

Updated 2026-11-12.

## FongMi-compatible functionality

- CatVod configuration import, multi-depot selection, AES-CBC decoding and
  lenient JSON normalization
- Direct HTTP/XML/JSON providers on iOS
- QuickJS, Java/JAR, Python and Node.js providers through Firepick Bridge
- TLS pairing, QR pairing payloads, pinned Bridge transport, persisted
  credentials, stable Bridge port `9443`, config upload and isolated sessions
- CatVod `proxy://` URL rewriting, streamed Bridge proxy responses, loopback
  player proxy with Range/HEAD forwarding and LAN-accessible proxy URLs
- AVPlayer plus MPVKit-GPL playback, including Matroska/ISO-capable format
  routing, HTTP headers, resume position and external subtitles
- Downloads with pause/retry, chunked Range resume, persisted metadata, local
  file import and offline playback
- XML/JSON/plain-text danmaku parsing and synchronized player overlay
- DLNA MediaRenderer discovery and AVTransport casting
- Dynamic live `lives.api/ext/jar` sources, global spider inheritance, M3U/TXT
  refresh, per-channel HTTP headers and channel-level EPG
- XMLTV timezone parsing, missing-stop inference, multi-source cache and
  current/next programme display
- Source-aware history/favorites storage with database migration

## Verification on 2026-11-12

- Swift Package: 47 tests in 14 suites passed
- iPhone 17 Pro / iOS 26 simulator: clean Debug build, install and launch
- iPad Pro 11-inch (M4) / iOS 26 simulator: install and HLS playback verified
- MPVKit-GPL: MKV video and embedded subtitle rendering verified in the iPhone
  simulator without UIKit background-layer assertions
- Android Bridge: `:app:assembleDebug` successful; API 36 emulator reports
  QuickJS, Java, Python and Node.js runtimes available
- TVAPP real sources: Gao config (298 sites), Youhun live (7,083 channels),
  IPTV M3U (430 channels), Mao config (162 sites) and XYQ config (48 sites)
- iOS -> Bridge end-to-end: bundled configuration and token persisted, Java
  `csp_New6v` and Python `TangDou_Spider` home/category content rendered
- Live + EPG end-to-end: IPTV M3U loaded with 12 groups, then 7,551 XMLTV
  programmes and current/next programme rows

See [verification-2026-11-12.md](verification-2026-11-12.md) for commands and
known external failures.

## Remaining acceptance work

- SideStore seven-day physical-device renewal cannot run while the connected
  iPhone is unavailable to `devicectl`; simulator coverage does not replace it.
- A physical DLNA renderer was not available during this run. Discovery and
  SOAP casting are implemented and covered by build-level checks, but network
  interoperability still needs a real TV.
- Individual public TVAPP source endpoints can change or return `403`; this is
  source availability, not a provider-runtime failure.
- A physical iPhone/iPad release build should repeat MPV PiP, hardware decode,
  background audio and local-network permission checks.

## Verification commands

```bash
swift test --package-path Packages/FirepickKit

xcodebuild \
  -project Firepick.xcodeproj \
  -scheme Firepick \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/firepick-ios-derived \
  -clonedSourcePackagesDirPath "$PWD/Packages/FirepickKit/.build" \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  build

env ANDROID_HOME=/opt/homebrew/share/android-commandlinetools \
  ANDROID_SDK_ROOT=/opt/homebrew/share/android-commandlinetools \
  ./gradlew :app:assembleDebug
```

