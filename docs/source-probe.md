# Source compatibility probe

Use the local probe to classify TVAPP source links without launching the app:

```bash
swift run --package-path Packages/FirepickKit firepick-source-probe \
  https://example.com/config.json
```

Pass `--invoke` to run a home request and search against the first HTTP site.

## 2026-11-12 results

| Source | Result |
| --- | --- |
| `gaotianliuyun/gao/js.json` | 298 sites: 227 QuickJS, 71 Java; 2 live entries |
| `yoursmile66/TVBox/XC.json` | AES-CBC decoded; 91 sites: 90 Java, 1 QuickJS; 1 live entry |
| `xyq254245/xyqonlinerule/XYQTVBox.json` | 48 sites: 1 HTTP, 39 Java, 8 QuickJS; 3 live entries |
| `maoystv/6/000.json` | 162 sites: 13 HTTP, 30 Java, 85 Python, 34 QuickJS; 10 live entries |
| `live.zbds.top/tv/iptv4.m3u` | 12 groups, 427 channels |
| `live.zbds.top/tv/iptv4.txt` | 12 groups, 550 channels |
| `suxuang/myIPTV/ipv4.m3u` | 40 groups, 1225 channels |

The probe supports plain JSON, comments, trailing commas, prefixed Base64,
legacy `2423` AES-CBC, multi-depot JSON, M3U and TXT.

