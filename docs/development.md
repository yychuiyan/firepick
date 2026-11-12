# Development

## Repositories

The project is a monorepo. Upstream GPL sources are fetched into ignored
`third_party/` directories at revisions pinned in `vendor/upstream.lock`.

## iOS

```bash
make test
make project
```

Select a Personal Team in Xcode before running on a device. Keep the bundle ID
stable so SideStore re-signing preserves application data.

## Source routing

`SourceRouter` is the single authority for deciding whether a Provider runs in
the iOS process or through the Android Bridge. UI code must not inspect API
strings or duplicate this routing logic.

## Bridge protocol

All Bridge calls use `/v1`. The OpenAPI document in `protocol/openapi.yaml` is
the contract for both Swift and Android. New fields are additive; breaking
changes require a new protocol prefix.

