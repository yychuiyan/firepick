# Verification report: 2026-11-14 · v21

## Automated

- `swift test --package-path Packages/FirepickKit`: 66 tests in 16 suites pass.
- iOS Simulator Debug build: `BUILD SUCCEEDED`.
- Bundled and source copies of `firepick-cms.js` and `cms-candidates.json`
  are byte-identical.
- The Swift fallback pool matches the JavaScript `DEFAULT_PROVIDERS` order.

## Source acceptance

The local `v21` source probe reports:

- one on-device QuickJS site (`拾萤精选`)
- 5 menu categories and 16 first-screen items
- 74 deduplicated search items for `庆余年`
- a direct HLS playback URL
- 4 / 12 / 40 live groups with 120 / 430 / 1160 channels

The iPhone Simulator renders the updated home grid and plays the first live
channel in portrait with video and the 卫视 shelf selected. Fullscreen and
cross-device live handoff remain part of physical-device acceptance.

## Release scope

- ten-host active CMS pool with persisted in-app speed testing
- 52-host bundled candidate catalog and remote refresh fallback
- play-first detail flow with complete-episode source ranking and automatic
  failover
- manual source-station switching remains available from the current source
  capsule
- live mirror merging by channel name, AVPlayer video-plane detection, MPV
  fallback, shelf memory and cross-tab audio cleanup
- 4K/2K/1080P resolution gating and automatic weak-network degradation
- background danmaku and cloud ad-skip resolution after first frame

## Install artifact

```text
artifacts/Firepick-unsigned-0.1.30.ipa
SHA-256: 3442a86b97b8e5a0185e56f31296c258f7db7125c03f3945536b6d68470c52d6
```

## Public release

- SideStore manifest reports `0.1.30` (build `31`).
- A complete public IPA download matches the local SHA-256 exactly.
- Public `ios-sources.json?v=21` points to `firepick-cms.js?v=21`; the downloaded
  script hash matches the repository copy
  (`7a63747811bee59350dc32b4e29d04835ffe1ec92344e0d90d44532e92cba8cc`).
- The public `cms-candidates.json` contains 52 providers.
- Manifest, versioned icon and custom-domain IPA URLs resolve successfully.
