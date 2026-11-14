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

首次进入拾萤且没有当前线路时，请到设置添加配置地址：

```text
设置 → 添加线路
```

也可以进入：

```text
设置 → 已添加的线路 → 线路详情
设置 → 点播源管理
```

添加成功的仓库 URL 会作为「线路」保存在本机。点进线路可预览播放源并测速，
再点「切换到此线路」才会载入；列表里不会误触切换。线路负责整套配置，加载后
再由「点播源管理」或点播页标题旁的「源」选择具体站点。

### 从配置地址添加

粘贴 CatVod/TVBox 完整配置直链，例如：

```text
https://raw.githubusercontent.com/gaotianliuyun/gao/master/js.json
```

拾萤自建的聚合配置地址：

```text
https://dl.yychuiyan.com/firepick/ios-sources.json?v=12
```

该地址提供一个聚合点播站「拾萤」（当前使用一路 AppleCMS 采集接口）
和三组电视源，可直接验证首页、分类、搜索、详情、选集、HLS 播放与频道直播。
显示名里的「爱奇艺」是采集库名称，不是正版平台官方接口。上游采集接口和
直播频道可能临时失效，不承诺长期固定内容；维护时可替换 `DEFAULT_PROVIDERS`
并 bump `firepick-cms.js?v=`，不必反复重装 App。

### 添加线路

在「设置 → 线路管理」添加上面的配置地址。点播源页只列出当前线路里的源，用来切换；不再提供「从配置地址添加」或「手动添加点播源」。

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

设置「线路与源」分组显示：

- 当前线路友好名 + 中间省略的地址 + 最近测速
- 「已添加的线路」：中间省略、延迟徽章；点行进详情预览播放源，不直接切换
- 「添加线路」子页粘贴配置直链
- 「点播源管理」：隐藏/编辑站点、从 URL 加源

删除线路不会删除收藏和观看记录。点播页标题旁「源」可切换本机点播源。

中文域名会按用户输入显示，例如 `http://www.饭太硬.net/tv`；网络请求仍使用
等价的 Punycode 域名。

## 6. 搜索

点播顶栏放大镜进入搜索。默认只查当前点播源；可在
`设置 → 播放设置 → 搜索包含全部本机源` 打开多源并行搜索。

无点播源时搜索按钮不可用。返回点播再进搜索会保留上次关键词与结果；点导航栏
「清除」才清空。

## 7. 电视/直播

底部「电视」有直播源时**直接进入播放画面**（恢复上次频道，否则首组首台），
不以整页频道列表为主界面。播放中可：

- 单击显隐 HUD；上下滑切台
- 「选台」半屏面板：分组 /「我的」收藏 / 搜台
- 「节目单」看 EPG；「线路」切换备用 URL
- 切到其他 Tab 会暂停直播以省流量

无直播源时显示空态并引导去设置。下拉或选台面板「刷新」可更新 M3U/EPG。

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
- MKV、ISO、M2TS 等优先使用 MPV；播放中菜单可临时切换引擎。
- 单击显隐控制栏，双击播放/暂停；左右滑快进快退，左半屏竖滑调亮度，右半屏竖滑调音量。
- 支持续播提示、外挂字幕（MPV 原生轨 / AV 叠加解析）、弹幕开关、本次无痕、倍速。
- 无网时顶部显示「网络不可用」横幅，可重试或关闭。
- 「智能去广」开启后可在菜单标记片头结束/片尾开始；播放中出现「跳过片头」。
- 后台播放关：切到后台会暂停；开：按系统音频会话尽量续播。
- DLNA 投屏需同一局域网。

设置结构：

- **线路与源**：当前线路、已添加线路（可禁用）、添加线路、点播源管理
- **播放设置**：引擎 / 输出 / 解码 / 智能去广 / 后台播放 / 无痕 / 多源搜索 /
  缓冲 / 字幕特效 / 海报尺寸；并可进入弹幕设置
- **存储与关于**：清理缓存（不删收藏、历史或源配置）

点播顶栏从右到左为：**最近观看 | 收藏 | 搜索**。收藏与最近观看为海报网格，
支持清空。首页有观看记录时显示「继续观看」横滑行。

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
