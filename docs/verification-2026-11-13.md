# Verification report: 2026-11-13

## Automated

- `swift test --package-path Packages/FirepickKit`: 62 tests in 16 suites pass.
- iOS Simulator Debug build: `BUILD SUCCEEDED`.
- Unsigned `0.1.21` (build `22`) Release device build succeeds.
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
- 5 VOD menu categories and 60 home items
- 54 search results for `庆余年`
- a direct HLS playback URL
- 4 / 12 / 40 live groups with 120 / 426 / 1160 channels

The iPhone and iPad simulators both display the aggregate home grid. The
simulator log confirms `homeContent classes=5 list=60` and HTTP 200 responses
from all five configured AppleCMS providers. The TV tab displays CCTV channel
groups. Both AVPlayer and MPV auto-play checks rendered actual video from the
selected HLS episode without the progress-range crash or stale MPV surface
error.

## Install artifact

```text
artifacts/Firepick-unsigned-0.1.21.ipa
SHA-256: 20c5231e05f00ddf9a5b62b7205691005408e66319e1359e7d90d19c47a980b4
```

Physical-device SideStore signing and seven-day renewal remain separate
preflight checks.
