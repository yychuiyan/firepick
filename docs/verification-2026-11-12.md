# Verification report: 2026-11-12

## Automated

- `swift test --package-path Packages/FirepickKit`: 42 tests, 13 suites, pass.
- Clean iOS simulator Debug build: `BUILD SUCCEEDED`.
- Android Bridge `:app:assembleDebug`: `BUILD SUCCESSFUL`.
- Unsigned SideStore IPA: Release device build pass, ZIP integrity pass,
  standard `Payload/` layout and SHA-256 manifest generated.
- Local proxy contract test verifies authenticated upstream fetch and an
  end-to-end loopback Range response.
- Download contract test verifies chunked transfer, persisted metadata and
  reopening the offline file.

## Real sources

Commands used the source probe and iOS simulator:

```bash
swift run --package-path Packages/FirepickKit firepick-source-probe --invoke \
  https://raw.githubusercontent.com/gaotianliuyun/gao/master/js.json

swift run --package-path Packages/FirepickKit firepick-source-probe \
  https://www.iyouhun.com/tv/zb \
  https://live.zbds.top/tv/iptv4.m3u

swift run --package-path Packages/FirepickKit firepick-source-probe --invoke \
  https://raw.githubusercontent.com/maoystv/6/main/000.json

swift run --package-path Packages/FirepickKit firepick-source-probe --invoke \
  https://raw.githubusercontent.com/xyq254245/xyqonlinerule/main/XYQTVBox.json
```

Gao yielded 298 VOD sites and 2 live entries. Youhun yielded 25 groups / 7,083
channels. IPTV M3U yielded 12 groups / 430 channels. Mao yielded 162 VOD sites
across HTTP, Java, Python and QuickJS. XYQ yielded 48 sites and a playable
AppleCMS HLS result.

## Device matrix

| Target | Result |
| --- | --- |
| iPhone 17 Pro, iOS 26 | Bridge Java/Python UI, MPV MKV, AVPlayer HLS, live EPG |
| iPad Pro 11-inch M4, iOS 26 | Install, launch and AVPlayer HLS playback |
| Android API 36 emulator | Bridge service, pairing, config sync, Java/Python runtime |
| Connected iPhone 14 Pro | Unavailable to `devicectl`; SideStore not runnable |

## Notes

- The first Gao drpy site currently references a remote module that returns
  HTTP 403. Switching to runtime-backed sites confirmed Java and Python work.
- The XYQ AppleCMS media URL returned HTTP 403 from the current region, so HLS
  player verification used a live channel from the TVAPP IPTV source instead.
- DLNA discovery/casting requires a renderer on the same LAN; none was present
  for physical interoperability testing.

