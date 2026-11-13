# Verification report: 2026-11-13

## Automated

- `swift test --package-path Packages/FirepickKit`: 61 tests in 15 suites pass.
- iOS Simulator Debug build: `BUILD SUCCEEDED`.
- Unsigned `0.1.24` (build `25`) Release device build succeeds.
- IPA ZIP integrity passes and contains the standard `Payload/` layout.
- Bundled and source copies of `firepick-cms.js` have the same SHA-256.

## Source and simulator acceptance

The published configuration is:

```text
https://dl.yychuiyan.com/firepick/ios-sources.json?v=11
```

The source probe reports:

- 1 on-device CatVod JavaScript site
- 3 live entries
- 5 VOD menu categories and 36 deduplicated home items
- 60 items in the unfiltered TV category, 24 filtered anime items and
  8 filtered US action movies
- 2 deduplicated search results for `庆余年`
- a direct HLS playback URL
- 4 / 12 / 40 live groups with 120 / 426 / 1160 channels

The iPhone and iPad simulators both display the aggregate home grid. The
source probe confirms `homeContent classes=5 list=36` from the active iqiyi
AppleCMS provider. A separate multi-provider configuration switched its
category request to the selected `dytt` provider. Both simulator layouts show
the new home, filter and configuration-update UI. Simulator playback rendered
video with a valid 46:14 timeline, and the live page rendered a working CCTV
stream with its channel shelf.

## Install artifact

```text
artifacts/Firepick-unsigned-0.1.24.ipa
SHA-256: 0af35cb5f515e93f69f176d91ca43e75187de5096fd9abca8ba7dd088c3a9428
```

Physical-device SideStore signing and seven-day renewal remain separate
preflight checks.
