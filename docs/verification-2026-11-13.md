# Verification report: 2026-11-13

## Automated

- `swift test --package-path Packages/FirepickKit`: 60 tests in 16 suites pass.
- iOS Simulator Debug build: `BUILD SUCCEEDED`.
- Unsigned `0.1.20` (build `21`) Release device build succeeds.
- IPA ZIP integrity passes and contains the standard `Payload/` layout.
- Bundled and source copies of `firepick-cms.js` have the same SHA-256.

## Source and simulator acceptance

The published configuration is:

```text
https://dl.yychuiyan.com/firepick/ios-sources.json
```

The source probe reports:

- 1 on-device CatVod JavaScript site
- 3 live entries
- 155 VOD categories and 100 home items
- 54 search results for `庆余年`
- a direct HLS playback URL
- 4 / 12 / 40 live groups with 120 / 426 / 1160 channels

The iPhone and iPad simulators both display the aggregate home grid. The
simulator log confirms `homeContent classes=155 list=100` and HTTP 200 responses
from all five configured AppleCMS providers. The TV tab displays CCTV channel
groups. A simulator auto-play check rendered actual video from the selected
HLS episode.

## Install artifact

```text
artifacts/Firepick-unsigned-0.1.20.ipa
SHA-256: 0a45374767b4cdff29d40d21cfcd077c1f58ebc9691cf04477731afd9eea6b52
```

Physical-device SideStore signing and seven-day renewal remain separate
preflight checks.
