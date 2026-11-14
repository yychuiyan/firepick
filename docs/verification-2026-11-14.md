# Verification report: 2026-11-14

## Automated

- `swift test --package-path Packages/FirepickKit`: 65 tests in 15 suites pass.
- iOS Simulator Debug build: `BUILD SUCCEEDED`.
- Unsigned `0.1.29` (build `30`) Release device build succeeds.
- IPA ZIP integrity passes and contains the standard `Payload/` layout.
- Bundled and source copies of `firepick-cms.js` have the same SHA-256.

## Performance acceptance

The release moves live playlist loading to the first visit to the TV tab and
caches parsed groups for subsequent launches. Routine warehouse refresh and
category prefetch run after the first home paint. Cold home skips uncached
Douban title matching and continues with CMS results.

Covers are decoded at display size through ImageIO. Disk reads, thumbnail
decoding and cache writes run off the main actor; duplicate requests are
coalesced and global image concurrency is limited to eight. Existing full-size
poster files are downsampled and migrated to the new cache keys. The custom
thumbnail cache is capped at 256 MB with oldest-entry eviction.

iPhone Simulator observations with the published source:

- Persisted-config cold start displayed home data in about four seconds.
- First visible covers began rendering in the same interval; the visible grid
  completed after slow-host requests timed out or resolved.
- Entering the TV tab loaded and displayed live groups successfully.
- The generated poster cache contained 36-164 KB thumbnail files instead of
  multi-megabyte full-size copies.

## Install artifact

```text
artifacts/Firepick-unsigned-0.1.29.ipa
SHA-256: c7dd092063131b3f1c4c84e57d58f5168f2d30dde9ba84dcab4b9da7bc5d8ac9
```

## Public release

- SideStore manifest reports `0.1.29` (build `30`).
- A complete download from the public custom-domain IPA URL matched the local
  SHA-256 exactly.
- The public `ios-sources.json?v=15` points at
  `firepick-cms.js?v=15`; the downloaded script hash matches the repository
  copy (`8520838b714cfb97ed3385e93b06ea38319ae45aa5c8f2095647b53f84cc72d1`).
- The public manifest, IPA ranged GET and versioned icon URL all resolve.
- The iPhone Simulator loads the published `v15` source and renders the
  aggregate home grid.

Physical-device SideStore signing and seven-day renewal remain separate
preflight checks.
