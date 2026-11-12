# 拾萤 Firepick

拾萤是一个面向 iPhone 与 iPad 的 CatVod/TVBox 兼容影音客户端。它既可以在
iOS 本机执行 HTTP、XML、JSON 和 QuickJS 源，也可以通过局域网 Android
Bridge 或现有 FongMi/TV 服务运行 Java/JAR、Python、Node.js 等复杂 Provider。

项目同时包含：

- iOS SwiftUI 客户端
- Android Firepick Bridge
- 双端 `/v1` 通信协议
- SideStore 未签名 IPA 打包与 COS 发布脚本
- FongMi/TV、CatVodSpider、QuickJS 和 MPV 的固定版本上游补丁

> 本仓库只提供客户端和运行时桥接实现，不附带影视内容、账号、付费凭据或
> 第三方接口授权。使用者应自行确认数据源和媒体内容的合法性。

## 当前版本

当前公开发布版本：

```text
Version: 0.1.6
Build:   7
SHA-256: a7e2e10934abeae99c5cdcd4cf0476c547186071405eeb542de8c789a90191ae
```

SideStore 更新源：

```text
https://firepick-1302621537.cos.ap-shanghai.myqcloud.com/firepick/firepick.json
```

当前 IPA 下载地址：

```text
https://dl.yychuiyan.com/firepick/Firepick-0.1.6.ipa
```

## 功能概览

| 模块 | 当前能力 |
| --- | --- |
| 点播 | CatVod/TVBox 配置、分类、筛选、详情、剧集、搜索、换源 |
| 源管理 | URL 添加、手动添加、修改、删除、隐藏、切换、测试 |
| 直播/电视 | JSON、M3U、TXT 直播源，频道分组、频道头、XMLTV EPG |
| 播放 | AVPlayer；MPVKit-GPL 支持 MKV、ISO、M2TS、字幕和续播 |
| 代理 | `proxy://` 解析、Android Bridge Range/HEAD 转发、iOS 回环代理 |
| 下载 | 分块下载、暂停、重试、断点续传、持久化和离线播放 |
| 弹幕 | XML、JSON、纯文本解析及同步叠加 |
| 媒体库 | 收藏、最近观看、下载与本地文件 |
| 局域网 | Android Bridge TLS 配对、FongMi LAN 服务、DLNA、网页遥控 |
| 分发 | SideStore source、未签名 IPA、COS 和自定义域名发布 |

## 目录结构

```text
apps/ios/Firepick/                 iOS SwiftUI 应用
apps/bridge/                       Android Firepick Bridge
Packages/FirepickKit/              Swift Package
  Sources/FirepickCore/            配置、数据模型、数据库、代理
  Sources/FirepickProvider/        HTTP/XML/JSON/QuickJS Provider
  Sources/FirepickBridge/          Android Bridge 与 FongMi 客户端
  Sources/FirepickPlayback/        AVPlayer、MPV、下载、弹幕、DLNA
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

| 名称 | 作用 | 添加位置 |
| --- | --- | --- |
| SideStore Source | 安装和更新拾萤 IPA | SideStore → Sources |
| Firepick 点播源 | 提供影视分类、详情、剧集和搜索 | 拾萤 → 设置 → 点播源 |

SideStore Source 是应用更新清单；Firepick 点播源是 CatVod/TVBox 配置。

---

# 一、本机开发与发布配置

## 1. 已验证环境

本仓库当前测试环境：

| 项目 | 版本 |
| --- | --- |
| macOS | 15.8，Apple Silicon |
| Xcode | 26.0.1，Build 17A400 |
| Swift | 6.2 |
| iOS Deployment Target | 18.0 |
| Java | OpenJDK 21.0.7 |
| Android compileSdk | 37 |
| Android minSdk | 24 |
| Android NDK | 28.2.13676358 |
| MPVKit | 1.1.0-n9.0.2 |

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

当前基线为 43 项测试、13 个 suite 全部通过。

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
FIREPICK_VERSION=0.1.7 \
FIREPICK_BUILD=8 \
./scripts/package-unsigned-ipa.sh
```

输出：

```text
artifacts/Firepick-unsigned-0.1.7.ipa
artifacts/Firepick-unsigned-0.1.7.ipa.sha256
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

Android 设备安装 Bridge 后：

1. 将 Android 与 iOS 设备接入同一局域网。
2. 打开拾萤 Bridge，等待状态显示“运行中”。
3. 在 Bridge 页面按需安装 Python、Node.js、Thunder、BD-J 运行时。
4. 在 iOS 拾萤的“设置 → Android Bridge”扫码或粘贴配对 URI。

Bridge 内置：

- QuickJS
- Java/JAR CatVod Provider
- TLS 证书固定
- 一次性配对码
- 设备 Bearer Token
- 配置 SHA-256 校验
- 独立 Provider 会话

## 7. 使用现有 FongMi/TV 服务

如果已有 FongMi/TV Android 设备，也可以不安装 Firepick Bridge：

1. 在 FongMi/TV 中启用局域网服务。
2. 确认 Android 设备 IP。
3. 在 iOS 拾萤中打开“设置 → FongMi Android 服务”。
4. 填写：

```text
http://<Android-IP>:9978
```

5. 点击“连接现有 FongMi/TV”。

适用于 Java、Python、QuickJS、JAR、Thunder、BD-J 和动态原生扩展等
复杂运行时。

## 8. 源配置诊断工具

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
- Legacy `2423` AES-CBC 配置
- M3U
- TXT
- 直播 JSON

GitHub 网页地址不是配置。必须使用 Raw、原始 JSON 或直链。

## 9. 本机数据与敏感信息

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
- FongMi 私有 Token
- 私人签名证书或私钥

## 10. COS 发布配置

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
FIREPICK_BUILD=8 \
FIREPICK_RELEASE_NOTES="本次更新说明" \
FIREPICK_IPA_BASE_URL="https://dl.yychuiyan.com/firepick" \
FIREPICK_CURL_DOH_URL="https://223.5.5.5/dns-query" \
./scripts/publish-cos-release.sh \
  0.1.7 \
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

- 每次发布增加 `MARKETING_VERSION`。
- 同一版本重新构建时仍应增加 `CURRENT_PROJECT_VERSION`。
- 不复用旧版本号发布不同代码。
- 不改变 `com.firepick.app`。

---

# 二、用户配置手册

## 1. 安装 SideStore

每位用户必须使用自己的 Apple ID。不要把同一个签名账号共享给多人。

如果 SideStore 或 LocalDevVPN 在当前 App Store 区域不可用，可以合法切换到
有下载权限的区域完成 App Store 下载，安装后再切回自己的常用账号。

每台设备需要：

1. 安装 LocalDevVPN。
2. 使用 USB 连接 Mac 并在设备上选择“信任”。
3. 打开官方 iloader。
4. 使用该设备用户自己的 Apple ID 安装 SideStore Stable。
5. 在“设置 → 通用 → VPN 与设备管理”中信任开发者。
6. 在“设置 → 隐私与安全性”中开启 Developer Mode，并重启设备。
7. 连接 LocalDevVPN。
8. 打开 SideStore，使用同一个 Apple ID 登录。
9. 在 My Apps 中刷新一次 SideStore。

免费 Personal Team 签名通常约 7 天有效。建议一直保持 LocalDevVPN 为
`Connected`，并定期打开 SideStore 检查续签。

## 2. 添加 SideStore 更新源

打开 SideStore：

1. 进入 `Sources`。
2. 点击 `+`。
3. 添加：

```text
https://firepick-1302621537.cos.ap-shanghai.myqcloud.com/firepick/firepick.json
```

4. 刷新 Source。
5. 进入 `Browse`，找到“拾萤 Firepick”。
6. 点击安装。

之后有新版本时，在 SideStore 刷新并点击 Update。更新时不要卸载旧版本，
否则应用数据可能丢失。

## 3. 添加 Firepick 点播源

首次进入拾萤且没有当前源时，设置页会显示“输入点播配置地址”。

也可以进入：

```text
设置 → 点播源 → 管理已添加的点播源
```

支持两种添加方式：

### 从配置地址添加

粘贴 CatVod/TVBox 完整配置直链，例如：

```text
https://raw.githubusercontent.com/gaotianliuyun/gao/master/js.json
```

### 手动添加单个源

填写：

- 源标识 `key`
- 显示名称
- 类型 `0/1/2/3/4`
- API 地址
- 可选 JAR 地址

单个源适合手动维护 HTTP/XML/JSON 接口；完整配置适合一次导入多个站点。

## 4. 判断配置地址是否有效

有效配置通常满足以下之一：

- JSON 对象包含 `sites`
- JSON 对象包含 `urls`
- JSON 对象包含 `lives`
- JSON 数组是直播分组
- 文本以 `#EXTM3U` 开头
- TXT 包含 `#genre#`

以下地址通常无效：

- GitHub 仓库网页
- 单部影片详情接口
- `api.php/provide/vod` 单接口
- 要求 Cookie、登录或交互验证的页面
- 含防盗链且无法直接下载的页面

如果提示“加载到的是网页”，请改用 Raw 地址。

## 5. 管理和切换点播源

设置首页顶部显示当前源。点击当前源会展开源列表：

- 列表最高 280pt
- 源较多时内部滚动
- 点击源立即切换
- 点播页标题和运行时描述自动更新

完整管理页支持：

- 添加
- 修改
- 隐藏/显示
- 删除
- 切换
- 测试当前源
- 查看运行时统计和源诊断

源标识在修改时保持不可变，以保护收藏、历史和当前源关联。

## 6. 搜索

搜索默认只查询当前点播源，不依赖配置中的 `searchable` 标记。

如果没有选择点播源，搜索按钮不可用；请先在设置中添加并选择源。

## 7. 电视/直播

底部“电视”页支持：

- 直播分组切换
- M3U/TXT 频道
- 频道 Logo 和编号
- XMLTV 当前节目与下一档
- 下拉刷新直播源和 EPG

直播配置示例：

```text
https://live.zbds.top/tv/iptv4.m3u
```

## 8. Android Bridge 配对

1. 保持 Android 与 iPhone/iPad 在同一 Wi-Fi。
2. 打开 Android“拾萤 Bridge”。
3. 确认状态为“运行中”。
4. 在 iPhone 上进入：

```text
设置 → Android Bridge
```

5. 点击“扫描 Bridge 二维码”。
6. 允许相机和本地网络访问。
7. 扫描 Android 页面上的二维码。

也可以复制 Android 页面显示的 `firepick://pair?...` URI，在 iOS 中粘贴后
点击“配对 Bridge”。

Bridge 离线时，HTTP/XML/JSON 源仍可由 iOS 本机运行；Java、Python、
Node.js、JAR 等复杂源将不可用。

## 9. FongMi/TV 遥控

连接 FongMi/TV 服务后，可以进入：

```text
设置 → FongMi Android 服务 → 遥控当前 FongMi 播放
```

支持读取播放状态、暂停、继续、快进、快退等操作。Android 和 iOS 必须
在同一局域网，且地址和端口可达。

## 10. 播放、下载和投屏

- HLS、MP4 等通常使用 AVPlayer。
- MKV、ISO、M2TS 等优先使用 MPV。
- 支持源提供的 HTTP Header、外挂字幕、记忆播放位置和倍速。
- 下载支持暂停、重试和断点续传。
- 本地下载可在“设置 → 媒体库 → 下载与本地文件”中找到。
- DLNA 投屏需要同一局域网内可发现的 MediaRenderer。

## 11. 数据保存位置

iOS 应用沙盒内主要保存：

```text
Library/Application Support/Firepick/configuration.json
Library/Application Support/Firepick/Firepick.sqlite
Library/Application Support/Firepick/Downloads/downloads.json
```

Bridge 凭据保存在 Keychain。普通 SideStore 更新不会清除应用容器数据。

## 12. 常见问题

### SideStore 登录出现 `-80045`

通常是 Anisette 身份或客户端配置问题：

1. 关闭 On-Device Anisette。
2. 切换 SideStore Anisette Server。
3. 关闭自动轮换。
4. Fetch 并保存 Remote Server Sync overrides。
5. Reset `adi.pb`。
6. 重启 SideStore 后重新登录。

### SideStore 安装出现 `NSURLErrorDomain -1102`

SideStore 会把 IPA 下载 HTTP 403 映射成该错误。检查：

- IPA 是否通过自定义域名下载
- GET 是否返回 200/206
- COS 默认域名是否触发 `DownloadForbidden`

### 配置显示“无法识别”

先确认使用直链，再用本地 probe：

```bash
swift run --package-path Packages/FirepickKit firepick-source-probe \
  "<配置地址>"
```

### 复杂源提示运行时不可用

检查：

- Android Bridge 是否运行
- iPhone 与 Android 是否在同一 Wi-Fi
- Python/Node.js 运行时是否已安装
- FongMi/TV 局域网服务是否已开启

### 电视没有节目单

检查直播源是否包含 EPG/XMLTV 地址，并确认 EPG 地址可公开访问。

---

# 三、测试与验收

完整本机验证：

```bash
make verify
```

该命令会执行：

- Swift 包测试
- iOS 设备目标 Swift 编译
- iOS Simulator 构建
- Android Bridge Debug APK 构建

只运行测试：

```bash
swift test --package-path Packages/FirepickKit
```

真机还需验证：

- SideStore 七天续签
- 本地网络权限
- MPV 硬解
- 画中画
- 后台音频
- DLNA 局域网互操作
- Android Bridge 与 FongMi/TV 实际播放链路

---

# 四、上游与许可

本项目以 `GPL-3.0-only` 发布，详见 `LICENSE` 和 `NOTICE.md`。

固定版本上游记录在 `vendor/upstream.lock`。不要直接修改
`third_party/` 中的代码；需要变更时，新增或调整 `vendor/patches/` 并在
独立提交中说明原因。

参考项目：

- [FongMi/TV](https://github.com/FongMi/TV)
- [FongMi/Release](https://github.com/FongMi/Release)
- [FongMi/CatVodSpider](https://github.com/FongMi/CatVodSpider)
- [youhunwl/TVAPP](https://github.com/youhunwl/TVAPP)
