# Third-party notices

Firepick is designed to reuse or interoperate with the following GPL-compatible
projects:

- FongMi/TV, GPL-3.0
- FongMi/CatVodSpider, GPL-3.0
- FongMi/quickjs (QuickJS-NG fork), MIT
- FongMi/mpv, see upstream mpv/FFmpeg licensing
- MPVKit-GPL 1.1.0-n9.0.2, GPL-3.0 (includes libmpv, FFmpeg, libass,
  libplacebo, MoltenVK and related libraries)
- GRDB.swift, MIT
- SwiftSoup, MIT
- drpy2 compatibility assets bundled under
  `Packages/FirepickKit/Sources/FirepickProvider/Resources`, imported from
  puermilk/aimimang at commit
  `21921e8de8dcfbff19ea27d4c882a2f53289722c` (GPL-3.0 distribution):
  `gbk.js`, `jinja.js`, `json5.js`, `jsoup.js`, `node-rsa.js`,
  `pako.min.js`, `uri.min.js`, and `模板.js`.
- JSEncrypt 3.3.2, MIT, imported from gaotianliuyun/gao as a drpy helper.

The accompanying upstream libraries retain their own licenses: JSON5 (MIT),
URI.js (MIT), jsoup-style helper (drpy distribution), node-rsa (MIT), pako
(MIT AND Zlib), jinja-js (MIT), and JSEncrypt (MIT).

Pinned upstream revisions are recorded in `vendor/upstream.lock`. The Bridge
does not redistribute third-party source-provided binaries. Users are
responsible for ensuring every configured source and the media it exposes is
lawful and authorized.

