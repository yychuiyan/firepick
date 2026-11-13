# Verification report: 2026-11-13

## Automated

- `swift test --package-path Packages/FirepickKit`: 61 tests in 15 suites pass.
- iOS Simulator Debug build: `BUILD SUCCEEDED`.
- Unsigned `0.1.23` (build `24`) Release device build succeeds.
- IPA ZIP integrity passes and contains the standard `Payload/` layout.
- Bundled and source copies of `firepick-cms.js` have the same SHA-256.

## Source and simulator acceptance

The published configuration is:

```text
https://dl.yychuiyan.com/firepick/ios-sources.json?v=10
```

The source probe reports:

- 1 on-device CatVod JavaScript site
- 3 live entries
- 5 VOD menu categories and 60 deduplicated home items
- 46 items in the unfiltered TV category and 7 items with the
  `剧情 + 大陆` filter
- 36 deduplicated search results for `庆余年`
- a direct HLS playback URL
- 4 / 12 / 40 live groups with 120 / 426 / 1160 channels

The iPhone and iPad simulators both display the aggregate home grid. The
source probe confirms `homeContent classes=5 list=60` and HTTP 200 responses
from the 24-provider whitelist. A separate provider probe passed 24 of 28
candidates; the four dead or non-searchable candidates are excluded. Both
simulator layouts show the new home, filter and configuration-update UI.

## Install artifact

```text
artifacts/Firepick-unsigned-0.1.23.ipa
SHA-256: c4f8b8075e7f7e575447ac67878d131ecd424c8aec178d819f6f0ffcc824a593
```

Physical-device SideStore signing and seven-day renewal remain separate
preflight checks.
