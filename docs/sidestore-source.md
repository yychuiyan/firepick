# SideStore update source

SideStore only discovers app updates through a source manifest. An IPA copied
manually will not notify other users about later versions.

## 1. Build a versioned release

Use a new semantic version and build number for every release:

```bash
FIREPICK_BUILD=2 ./scripts/publish-sidestore-source.sh \
  0.1.1 \
  https://downloads.example.com/firepick
```

The script:

- builds a Release device app with `MARKETING_VERSION=0.1.1`
- creates and validates the unsigned IPA
- copies it to `artifacts/sidestore/0.1.1/Firepick-0.1.1.ipa`
- embeds and copies the required 1024×1024 App Store icon
- generates `artifacts/sidestore/0.1.1/firepick.json`
- prints the public URLs users need

Optional release metadata:

```bash
FIREPICK_RELEASE_NOTES="新增下载与弹幕修复" \
FIREPICK_ICON_URL="https://downloads.example.com/firepick/custom-icon.png" \
FIREPICK_IPA_BASE_URL="https://downloads.example.com/firepick" \
FIREPICK_BUILD=3 \
./scripts/publish-sidestore-source.sh 0.1.2 https://downloads.example.com/firepick
```

## 2. Upload all three files

Upload these to the same public HTTPS location:

- `Firepick-<version>.ipa`
- `AppIcon-<version>.png`
- `firepick.json`

The download URL in the manifest is:

```text
<base-url>/Firepick-<version>.ipa
```

The source URL is:

```text
<base-url>/firepick.json
```

Use a host reachable by every user. GitHub Releases work, but a China-accessible
HTTPS/CDN is more reliable. Do not require cookies, authentication or an
interactive browser to download the IPA.

Tencent COS rejects public GET requests for `.ipa` objects served through its
default `*.cos.*.myqcloud.com` domain with `DownloadForbidden`. Keep the source
JSON on the default domain if desired, but serve the IPA through a bound custom
domain and set `FIREPICK_IPA_BASE_URL` to that domain. A `HEAD` request can
still return 200 in this state, so release verification must perform a ranged
GET.

## Tencent COS

Create a COS bucket whose objects can be downloaded anonymously. The
`公有读私有写` bucket ACL is sufficient for SideStore source and IPA downloads.
Do not place SecretId or SecretKey in this repository.

Example bucket and region:

```text
Bucket: firepick-1250000000
Region: ap-guangzhou
Base URL: https://firepick-1250000000.cos.ap-guangzhou.myqcloud.com/firepick
```

Generate the release using that base URL:

```bash
FIREPICK_BUILD=2 \
./scripts/publish-sidestore-source.sh \
  0.1.1 \
  https://firepick-1250000000.cos.ap-guangzhou.myqcloud.com/firepick
```

Upload with the COS console or `coscli`:

```bash
coscli cp \
  artifacts/sidestore/0.1.1/Firepick-0.1.1.ipa \
  cos://firepick-1250000000/firepick/Firepick-0.1.1.ipa

coscli cp \
  artifacts/sidestore/0.1.1/AppIcon-0.1.1.png \
  cos://firepick-1250000000/firepick/AppIcon-0.1.1.png

coscli cp \
  artifacts/sidestore/0.1.1/firepick.json \
  cos://firepick-1250000000/firepick/firepick.json
```

Set object metadata:

| Object | Content-Type | Cache-Control |
| --- | --- | --- |
| `firepick.json` | `application/json; charset=utf-8` | `no-cache, max-age=0` |
| `Firepick-<version>.ipa` | `application/octet-stream` | `public, max-age=31536000, immutable` |
| `AppIcon-<version>.png` | `image/png` | `public, max-age=31536000, immutable` |

The JSON must not be cached for days. The IPA URL contains a version and can be
cached permanently.

Verify anonymous access before inviting users:

```bash
curl -fL \
  https://firepick-1250000000.cos.ap-guangzhou.myqcloud.com/firepick/firepick.json \
  | jq '.apps[0] | {version, downloadURL}'

curl -fIL \
  https://firepick-1250000000.cos.ap-guangzhou.myqcloud.com/firepick/Firepick-0.1.1.ipa

curl -fIL \
  https://firepick-1250000000.cos.ap-guangzhou.myqcloud.com/firepick/AppIcon-0.1.1.png
```

For repeatable releases, the repository also includes a COS publish wrapper:

```bash
FIREPICK_BUILD=2 \
FIREPICK_RELEASE_NOTES="修复播放与 EPG 问题" \
./scripts/publish-cos-release.sh \
  0.1.1 \
  firepick-1250000000 \
  ap-guangzhou
```

It builds, uploads all objects with the required metadata, and verifies the
public JSON, IPA, and icon URLs.

### Deployed source

Current test deployment:

```text
Source: https://firepick-1302621537.cos.ap-shanghai.myqcloud.com/firepick/firepick.json
IPA:    https://dl.yychuiyan.com/firepick/Firepick-0.1.31.ipa
```

The current published app version is `0.1.31` (build `32`) with a required
versioned `iconURL`. The source JSON remains on the COS default domain while
the IPA is served by the custom domain `dl.yychuiyan.com`.

To republish this deployment without rebuilding:

```bash
FIREPICK_REUSE_IPA=1 \
FIREPICK_BUILD=31 \
FIREPICK_IPA_BASE_URL="https://dl.yychuiyan.com/firepick" \
./scripts/publish-cos-release.sh \
  0.1.31 \
  firepick-1302621537 \
  ap-shanghai
```

## 3. Users add the source

Each user adds the JSON source URL once in SideStore:

1. Open SideStore.
2. Open Sources.
3. Tap `+` and enter the `firepick.json` HTTPS URL.
4. Refresh sources.
5. Open Firepick and tap Update when SideStore shows a new version.

Updates are user-confirmed; SideStore does not silently replace the app.
Updating with the same bundle ID `com.firepick.app` and without uninstalling
preserves application data.

## Version rules

- Continue sequential patch versions: `0.1.9`, `0.1.10`, `0.1.11`,
  `0.1.12`, `0.1.13`, `0.1.14`, `0.1.15`, `0.1.16`, `0.1.17`, `0.1.18`,
  `0.1.19`, `0.1.20`, `0.1.21`, `0.1.22`, `0.1.23`, `0.1.24`, `0.1.25`,
  `0.1.26`, `0.1.27`, `0.1.28`, `0.1.29`, `0.1.30`, `0.1.31`,
  without jumping to
  `0.2.0`.
- Increase `MARKETING_VERSION` for every published update.
- Increase `CURRENT_PROJECT_VERSION` even for rebuilds of the same marketing
  version.
- Never reuse an old version number with different code.
- Keep the Bundle ID stable at `com.firepick.app`.

