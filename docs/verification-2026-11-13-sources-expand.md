# Verification: VOD source expand (2026-11-13)

## Change

- `firepick-cms.js` providers: 5 → **22** (LunaTV jin18 candidates + local probe)
- Search: batch size 8, 8s timeout, title dedupe, light adult-keyword filter
- Published COS `firepick/sources/firepick-cms.js` (`?v=7`) and the versioned
  configuration URL `firepick/ios-sources.json?v=7`
- Bundle resource copy SHA matches `sources/firepick-cms.js`

## Probe

```bash
node scripts/probe-cms-providers.mjs
# Passed 22/28 → sources/providers.whitelist.json

swift run --package-path Packages/FirepickKit firepick-source-probe \
  --invoke --search '庆余年' --site firepick_cms \
  'https://dl.yychuiyan.com/firepick/ios-sources.json?v=7'
```

Result for `庆余年`: home `classes=5 items=58`, search `items=36` (deduped), direct HLS playback OK.

## Ops

Re-run `node scripts/probe-cms-providers.mjs` when sources go stale, refresh
`DEFAULT_PROVIDERS`, bump `?v=`, re-upload COS.
