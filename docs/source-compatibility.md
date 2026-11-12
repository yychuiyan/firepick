# Source compatibility

Firepick accepts CatVod configuration without a translation layer.

## Native iOS

- `type: 0` XML HTTP
- `type: 1` JSON HTTP
- `type: 4` extended JSON HTTP
- `type: 3` QuickJS `.js` when the embedded runtime is enabled

## Android Bridge

- Python and Node.js providers
- Java `csp_` providers and downloaded JARs
- Thunder, BD-J and dynamic native cores
- Any Bridge-only proxy or host API needed by a source

Existing FongMi/TV installations can also be used as the compatibility node:
enable the Android LAN server, connect its `http://device-ip:9978` address from
Firepick settings, and complex sources are executed through FongMi's own
`/spider-api`. This path uses the upstream JsLoader, PyLoader, JarLoader and
runtime modules instead of reimplementing them in Swift.

An authorized source corpus and expected results must be added to the protocol
fixtures before the Bridge milestone can be accepted.

