# 拾萤用户配置手册

本文面向安装和使用拾萤的 iPhone/iPad 用户。开发、构建和发布配置见仓库
根目录的 `README.md`。

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

支持两种添加方式。

添加成功的仓库 URL 会作为“配置地址”保存在设置页，可以像 FongMi Android
一样在最近使用的配置地址之间切换或删除。配置地址负责整套配置，加载后再由
管理页选择具体点播站点。

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
- 完整 JPEG 末尾带有 `标记**Base64(JSON)` 的 TVBox 图片封装配置
- 文本以 `#EXTM3U` 开头
- TXT 包含 `#genre#`

以下地址通常无效：

- GitHub 仓库网页
- 单部影片详情接口
- `api.php/provide/vod` 单接口
- 要求 Cookie、登录或交互验证的页面
- 只返回普通图片、但图片末尾没有 TVBox 配置的防盗链地址

如果提示“加载到的是网页”或“加载到的是图片”，请改用 Raw 地址。

如果地址是带多个配置入口的导航页，拾萤会尝试用浏览器方式打开，并自动提取
页面中的 JSON、M3U、TXT 或 TVBox 配置链接。提取失败时，请从页面手动复制
原始配置直链。

## 5. 管理和切换点播源

设置首页顶部显示当前配置地址。点击地址会展开最近使用过的配置：

- 列表最高 280pt
- 源较多时内部滚动
- 设置页只显示配置地址，不展开配置内部站点
- 点击配置地址会重新载入该地址中的全部点播站点
- 点击删除只移除配置历史，不会删除收藏和观看记录
- 进入点播页后，点击标题下方的“切换点播源”选择具体站点

中文域名会按用户输入显示，例如 `http://www.饭太硬.net/tv`；网络请求仍使用
等价的 Punycode 域名。

点播源选择页支持：

- 搜索名称、标识或地址
- 查看运行时路径和 API
- 选择当前点播源

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

## 8. Android Bridge（已下线设置入口）

日常使用**不需要** Android Bridge。iOS 本机可运行：

- HTTP / XML / JSON 点播源
- CatVod QuickJS `.js` 源（`OnDeviceJavaScriptHost`）
- M3U / TXT 直播源

设置页已移除 Bridge 配对。以下类型当前不可用，请改用本机 HTTP/JS
或自建 iOS 配置仓：

- Java `csp_` / JAR
- Python / Node.js
- Thunder / BD-J / 动态原生模块
- 依赖 Android 侧代理的复杂 `proxy://` 流

## 9. 播放和投屏

- HLS、MP4 等通常使用 AVPlayer。
- MKV、ISO、M2TS 等优先使用 MPV。
- 支持源提供的 HTTP Header、外挂字幕、记忆播放位置和倍速。
- 下载支持暂停、重试和断点续传。
- DLNA 投屏需要同一局域网内可发现的 MediaRenderer。

设置页和独立页面支持：

- 播放引擎：自动、AVPlayer、MPV
- 海报尺寸：紧凑、标准、大图
- 点击“默认显示弹幕”进入独立弹幕设置页，可调整开关、透明度、大小和速度
- 恢复弹幕默认值
- 查看当前缓存占用并清理网络和临时缓存，不删除收藏、历史、源配置或下载文件
- 收藏和最近观看分别进入独立页面

点播页搜索按钮右侧提供最近观看入口。打开搜索弹窗时会显示持久化的历史查询，
点击“管理”后可多选并批量删除；点击历史查询可以直接重新搜索。

设置页不显示顶部大标题；底部显示当前安装包的版本号和构建号。

## 10. 签名到期时间

设置页底部显示：

- 当前签名到期日期和时间
- 剩余有效天数或小时
- 到期、临近到期和正常状态颜色

SideStore 自动续签并重新安装 App 后，描述文件会更新。重新进入设置页时，
拾萤会重新读取 `embedded.mobileprovision` 并显示新的到期时间。

如果显示“未找到签名描述文件”，通常说明当前运行的是未签名开发构建，
或 SideStore 尚未完成重签名安装。

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

确认 URL 是原始 JSON、M3U 或 TXT 直链。返回网页、BMP、PNG、JPEG 等
内容时都不是有效配置。

### 复杂源提示运行时不可用

检查：

- Android Bridge 是否运行
- iPhone 与 Android 是否在同一 Wi-Fi
- Python/Node.js 运行时是否已安装

### 电视没有节目单

检查直播源是否包含 EPG/XMLTV 地址，并确认 EPG 地址可公开访问。

### 不显示签名到期时间

请从 SideStore 安装并重签名后的 IPA 中打开设置页。未签名开发包的 App
Bundle 不包含 `embedded.mobileprovision`。
