# Verification report: 2026-11-13

## Automated

- `swift test --package-path Packages/FirepickKit`: 65 tests in 15 suites pass.
- iOS Simulator Debug build: `BUILD SUCCEEDED`.
- Unsigned `0.1.28` (build `29`) Release device build succeeds.
- IPA ZIP integrity passes and contains the standard `Payload/` layout.
- Bundled and source copies of `firepick-cms.js` have the same SHA-256.

## Source and simulator acceptance

The published configuration is:

```text
https://dl.yychuiyan.com/firepick/ios-sources.json?v=14
```

The source probe reports:

- 1 on-device CatVod JavaScript site
- 3 live entries
- 5 VOD menu categories and 24+ deduplicated home items across warm runs
- 60 items in the unfiltered TV category, 24 filtered anime items and
  8 filtered US action movies
- 64 deduplicated search results for `三体`
- a direct HLS playback URL
- 4 / 12 / 40 live groups with 120 / 429 / 1160 channels

The iPhone Simulator displays the aggregate home grid and corrected sticky
header. The source probe confirms `homeContent classes=5` with 24+ items
across seven AppleCMS providers; search returns 64 items. Settings
shows seven collection stations. Simulator playback rendered video with a
valid episode timeline.

The `0.1.28` release prefers the bundled official aggregator, auto-updates
versioned warehouse URLs, restores a remote line when a loopback warehouse is
unavailable, and hands off playback position when switching collection stations.
It also adds Bilibili/弹弹play danmaku matching, configurable danmaku display
areas, HLS ad-range detection, near-end resume handling, and a clean public HLS
playback acceptance run.

## Install artifact

```text
artifacts/Firepick-unsigned-0.1.28.ipa
SHA-256: e5352f70857d28c039b0b7c0a8a9c62c7bf1d6a7d8f319db6d5fa71991281dba
```

Physical-device SideStore signing and seven-day renewal remain separate
preflight checks.
