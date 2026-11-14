# Verification report: 2026-11-13

## Automated

- `swift test --package-path Packages/FirepickKit`: 61 tests in 15 suites pass.
- iOS Simulator Debug build: `BUILD SUCCEEDED`.
- Unsigned `0.1.27` (build `28`) Release device build succeeds.
- IPA ZIP integrity passes and contains the standard `Payload/` layout.
- Bundled and source copies of `firepick-cms.js` have the same SHA-256.

## Source and simulator acceptance

The published configuration is:

```text
https://dl.yychuiyan.com/firepick/ios-sources.json?v=13
```

The source probe reports:

- 1 on-device CatVod JavaScript site
- 3 live entries
- 5 VOD menu categories and 30–35 deduplicated home items across warm runs
- 60 items in the unfiltered TV category, 24 filtered anime items and
  8 filtered US action movies
- 60 deduplicated search results for `庆余年`
- a direct HLS playback URL
- 4 / 12 / 40 live groups with 120 / 426 / 1160 channels

The iPhone Simulator displays the aggregate home grid and corrected sticky
header. The source probe confirms `homeContent classes=5` with 30–35 items
across seven AppleCMS providers; search and TV category each return 60 items. Settings
shows seven collection stations. Simulator playback rendered video with a
valid episode timeline.

The `0.1.27` release prefers the bundled official aggregator, auto-updates
versioned warehouse URLs, restores a remote line when a loopback warehouse is
unavailable, and hands off playback position when switching collection stations.

## Install artifact

```text
artifacts/Firepick-unsigned-0.1.27.ipa
SHA-256: 0e804b25e98f6a38982285eea5fd672046d17dacc8d4bd16f308ce9a60963d54
```

Physical-device SideStore signing and seven-day renewal remain separate
preflight checks.
