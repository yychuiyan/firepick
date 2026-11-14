# 拾萤 Firepick

[拾萤用户配置手册](docs/user-configuration.md)

拾萤是一个面向 iPhone 与 iPad 的 CatVod/TVBox 兼容影音客户端。日常以 iOS 本机 HTTP、XML、JSON 与 CatVod JS 源为主；仓库仍保留 Android Bridge 工程，但 App 设置中已不再提供配对入口。

项目同时包含：

- iOS SwiftUI 客户端
- Android Firepick Bridge
- 双端 `/v1` 通信协议
- SideStore 未签名 IPA 打包与 COS 发布脚本
- FongMi/TV、CatVodSpider、QuickJS 和 MPV 的固定版本上游补丁

> 本仓库只提供客户端和运行时桥接实现，不附带影视内容、账号、付费凭据或第三方接口授权。使用者应自行确认数据源和媒体内容的合法性。

## 当前版本

当前公开发布版本：

```text
Version: 0.1.29
Build:   30
SHA-256: c7dd092063131b3f1c4c84e57d58f5168f2d30dde9ba84dcab4b9da7bc5d8ac9
```

SideStore 更新源：

```text
https://firepick-1302621537.cos.ap-shanghai.myqcloud.com/firepick/firepick.json
```

当前 IPA 下载地址：

```text
https://dl.yychuiyan.com/firepick/Firepick-0.1.29.ipa
```

## 功能概览

| 模块      | 当前能力                                                                             |
| --------- | ------------------------------------------------------------------------------------ |
| 点播      | CatVod/TVBox 配置、HTTP/XML/JSON/JS、分类、筛选、详情、剧集、搜索、换源              |
| 源管理    | 设置页只管理配置地址；点播页选择配置内部的点播源                                     |
| 直播/电视 | JSON、M3U、TXT 直播源，频道分组、频道头、XMLTV EPG                                   |
| 播放      | AVPlayer；MPVKit-GPL 支持 MKV、ISO、M2TS、字幕和续播                                 |
| 代理      | `proxy://` 解析、Android Bridge Range/HEAD 转发、iOS 回环代理                        |
| 线路      | 多配置地址、测速、禁用；禁用当前线路时改用下一条可用线路                             |
| 弹幕      | XML、JSON、纯文本解析，同步叠加，透明度、大小和速度设置                              |
| 设置      | 当前连接下拉、播放引擎、海报尺寸、弹幕设置、缓存占用、版本号、扩展连接、签名到期时间 |
| 媒体库    | 收藏、最近观看                                                                       |
| 局域网    | Android Bridge TLS 二维码配对、DLNA                                                  |
| 分发      | SideStore source、未签名 IPA、COS 和自定义域名发布                                   |

## 目录结构

```text
apps/ios/Firepick/                 iOS SwiftUI 应用
apps/bridge/                       Android Firepick Bridge
Packages/FirepickKit/              Swift Package
  Sources/FirepickCore/            配置、数据模型、数据库、代理
  Sources/FirepickProvider/        HTTP/XML/JSON/QuickJS Provider
  Sources/FirepickBridge/          Android Bridge 客户端
  Sources/FirepickPlayback/        AVPlayer、MPV、弹幕、DLNA
protocol/                          OpenAPI、JSON Schema 和契约夹具
scripts/                           构建、验证、打包和 COS 发布脚本
docs/                              安装、兼容性、验证和协议文档
vendor/upstream.lock               固定版本上游仓库
vendor/patches/                    FongMi 运行时补丁
third_party/                       bootstrap 生成，不提交
artifacts/                         IPA、发布清单，不提交
```

## Source 类型说明

项目中存在两种不同的“源”，不要混淆：

| 名称             | 作用                           | 添加位置             |
| ---------------- | ------------------------------ | -------------------- |
| SideStore Source | 安装和更新拾萤 IPA             | SideStore → Sources  |
| Firepick 点播源  | 提供影视分类、详情、剧集和搜索 | 拾萤 → 设置 → 点播源 |

SideStore Source 是应用更新清单；Firepick 点播源是 CatVod/TVBox 配置。

拾萤自建聚合配置可直接在 `设置 → 当前线路` 中添加：

```text
https://dl.yychuiyan.com/firepick/ios-sources.json?v=15
```

它当前是单站「拾萤」聚合七路 AppleCMS 采集接口，外加三组电视源，
覆盖首页、分类、搜索、详情、选集、HLS 播放与直播频道。库名（如「爱奇艺」）
是第三方采集站，不是官方 App；上游接口可能调整或失效，因此不把其内容视为永久内置资源。

---

# 一、本机开发与发布配置

## 1. 已验证环境

本仓库当前测试环境：

| 项目                  | 版本                 |
| --------------------- | -------------------- |
| macOS                 | 15.8，Apple Silicon  |
| Xcode                 | 26.0.1，Build 17A400 |
| Swift                 | 6.2                  |
| iOS Deployment Target | 18.0                 |
| Java                  | OpenJDK 21.0.7       |
| Android compileSdk    | 37                   |
| Android minSdk        | 24                   |
| Android NDK           | 28.2.13676358        |
| MPVKit                | 1.1.0-n9.0.2         |

建议也使用 Apple Silicon Mac。Intel Mac 未纳入当前验证范围。

## 2. 安装基础工具

```bash
brew install xcodegen jq
brew install openjdk@21
brew install --cask android-commandlinetools
```

如果使用腾讯 COS 发布：

```bash
brew install coscli
```

确认命令行工具：

```bash
xcode-select -p
xcodebuild -version
swift --version
xcodegen --version
jq --version
java -version
```

如果系统终端找不到 XcodeGen，可将 Homebrew 路径加入 shell 配置：

```bash
export PATH="/opt/homebrew/bin:$PATH"
```

## 3. 获取代码

```bash
git clone https://github.com/yychuiyan/firepick.git
cd firepick
```

本机开发目录示例：

```text
/Volumes/yycy/GitHub/firepick
```

仓库不会提交以下内容：

- `third_party/`
- `.build/`
- `Packages/FirepickKit/.build/`
- `artifacts/`
- IPA 和 dSYM
- Gradle 与 Android 构建目录
- COS 日志、本地日志和环境变量文件

## 4. 拉取固定版本上游

```bash
make bootstrap
```

该命令根据 `vendor/upstream.lock` 拉取：

- FongMi/TV
- FongMi/CatVodSpider
- FongMi/quickjs
- FongMi/mpv

并应用 `vendor/patches/` 中的运行时补丁。

`third_party/` 是可重复生成的依赖目录，因此不进入 Git。

## 5. Swift 包与 iOS 构建

运行测试：

```bash
make test
```

当前基线为 65 项测试、15 个 suite 全部通过。

生成 Xcode 工程：

```bash
make project
open Firepick.xcodeproj
```

命令行构建 Simulator：

```bash
xcodebuild \
  -project Firepick.xcodeproj \
  -scheme Firepick \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ios-sim \
  -clonedSourcePackagesDirPath Packages/FirepickKit/.build \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  build
```

构建未签名设备 IPA：

```bash
FIREPICK_VERSION=0.1.10 \
FIREPICK_BUILD=11 \
./scripts/package-unsigned-ipa.sh
```

输出：

```text
artifacts/Firepick-unsigned-0.1.10.ipa
artifacts/Firepick-unsigned-0.1.10.ipa.sha256
```

保持以下配置不变，否则 SideStore 更新时可能无法保留数据：

```text
Bundle ID: com.firepick.app
Display Name 基础值: Firepick
中文桌面显示名: 拾萤
```

## 6. Android Bridge 构建

默认 SDK/JDK 路径由 `scripts/build-bridge.sh` 设置：

```bash
export ANDROID_HOME="/opt/homebrew/share/android-commandlinetools"
export JAVA_HOME="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
make build-bridge
```

输出：

```text
apps/bridge/app/build/outputs/apk/debug/app-debug.apk
```

Bridge 默认端口：

```text
9443
```

当前产品路径以 iOS 本机 HTTP / CatVod JS 为主，**设置页已不再提供 Bridge 配对入口**。
Android Bridge 工程仍保留在仓库中供实验/诊断，日常自用不需配对。

## 7. 源配置诊断工具

不启动 App，直接检测源 URL：

```bash
swift run --package-path Packages/FirepickKit firepick-source-probe \
  https://example.com/config.json
```

执行首个 HTTP 源的首页和搜索请求：

```bash
swift run --package-path Packages/FirepickKit firepick-source-probe \
  --invoke \
  https://example.com/config.json
```

支持：

- 普通 CatVod/TVBox JSON
- 多仓 `urls`
- JSON 行注释和分段注释
- Windows CRLF
- Base64 前缀配置
- JPEG 末尾 `标记**Base64(JSON)` 图片封装配置
- Legacy `2423` AES-CBC 配置
- M3U
- TXT
- 直播 JSON

GitHub 网页地址不是配置。必须使用 Raw、原始 JSON 或直链。

## 8. 本机数据与敏感信息

以下文件不应提交：

```text
~/.cos.yaml
.env
.env.*
coscli.log
coscli_output/
artifacts/
```

`~/.cos.yaml` 建议权限：

```bash
chmod 600 ~/.cos.yaml
```

不要在 README、Issue、聊天记录或脚本中写入：

- COS SecretId
- COS SecretKey
- Apple ID 密码
- SideStore 配对文件
- Bridge Bearer Token
- 私人签名证书或私钥

## 9. COS 发布配置

当前部署：

```text
Bucket: firepick-1302621537
Region: ap-shanghai
Source base: https://firepick-1302621537.cos.ap-shanghai.myqcloud.com/firepick
IPA base:    https://dl.yychuiyan.com/firepick
```

腾讯 COS 默认域名会拒绝公开下载 `.ipa`，因此：

- `firepick.json` 和图标可以继续使用 COS 默认域名
- IPA 必须使用绑定到 COS 的自定义域名
- 发布验证必须执行真实 GET，不能只做 HEAD

发布命令：

```bash
FIREPICK_BUILD=11 \
FIREPICK_RELEASE_NOTES="本次更新说明" \
FIREPICK_IPA_BASE_URL="https://dl.yychuiyan.com/firepick" \
FIREPICK_CURL_DOH_URL="https://223.5.5.5/dns-query" \
./scripts/publish-cos-release.sh \
  0.1.10 \
  firepick-1302621537 \
  ap-shanghai
```

`FIREPICK_IPA_BASE_URL` 必须包含 `/firepick` 路径。

脚本会：

1. 构建 Release iOS App。
2. 生成未签名 IPA。
3. 校验 ZIP 结构和 SHA-256。
4. 复制 1024×1024 图标。
5. 生成 `firepick.json`。
6. 上传 IPA、图标和源清单。
7. 验证公开 JSON、IPA 分段下载和图标。

版本规则：

- 后续补丁版本依次使用 `0.1.10`、`0.1.11`、`0.1.12`、`0.1.13`、`0.1.14`、`0.1.15`、`0.1.16`、`0.1.17`、`0.1.18`、`0.1.19`、`0.1.20`、`0.1.21`、`0.1.22`、`0.1.23`、`0.1.24`、`0.1.25`、`0.1.26`、`0.1.27`、`0.1.28`、`0.1.29`，不跳到 `0.2.0`。
- 每次发布增加 `MARKETING_VERSION`。
- 同一版本重新构建时仍应增加 `CURRENT_PROJECT_VERSION`。
- 不复用旧版本号发布不同代码。
- 不改变 `com.firepick.app`。

---
