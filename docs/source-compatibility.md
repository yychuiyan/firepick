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

Complex sources are executed by Firepick Bridge. The Bridge uses the pinned
FongMi CatVodSpider, JsLoader, PyLoader, JarLoader and runtime modules without
requiring a separately configured FongMi/TV LAN server.

An authorized source corpus and expected results must be added to the protocol
fixtures before the Bridge milestone can be accepted.

