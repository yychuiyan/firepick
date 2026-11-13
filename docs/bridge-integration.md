# Bridge runtime integration

Firepick Bridge 通过 `/v1` 协议向 iOS 暴露隔离的 CatVod Provider 会话。
Swift 与 Android 的公共契约位于 `protocol/openapi.yaml` 和 JSON Schema。

## 运行模型

1. iOS 上传完整配置，Android 计算并校验 SHA-256。
2. iOS 为一次 Provider 工作流创建独立 Bridge Session。
3. Bridge 按 Session 加载对应站点和运行时。
4. Provider 调用结果以统一 JSON Envelope 返回。
5. `proxy://` 流转换为带 Session Token 的范围代理 URL。
6. Session 超时、取消或服务关闭时释放运行时资源。

## Android 运行时

- QuickJS：内置运行时
- Java/JAR：内置 CatVod Provider
- Python：FongMi runtime module，按需安装
- Node.js：FongMi runtime module，按需安装
- Thunder：FongMi runtime module，按需安装
- BD-J：FongMi runtime module，按需安装

运行时安装包 URL、版本、大小和 SHA-256 固定在
`apps/bridge/app/src/main/assets/runtime-catalog.json`。

## TLS 与认证

- Bridge 启动时生成自签名 TLS 身份
- iOS 固定证书 SHA-256 指纹
- 首次配对使用一次性配对码
- 后续请求使用设备 Bearer Token
- 每个 Token 只保存 SHA-256 摘要
- 支持一次性撤销全部设备

## 上游运行时

Bridge 复用固定版本的 FongMi CatVodSpider、QuickJS 和运行时模块，但不要求
安装完整 FongMi/TV 客户端。

## 兼容性路由

| Provider | iOS 本机 | Firepick Bridge |
| --- | --- | --- |
| HTTP/XML/JSON | 是 | 是 |
| QuickJS / CatVod `.js` | 是（JavaScriptCore 宿主，见 `OnDeviceJavaScriptHost`） | 可选 |
| Java `csp_` / JAR | 否 | 是（遗留） |
| Python `.py` | 否 | 需安装运行时 |
| Node.js `node:` | 否 | 需安装运行时 |
| Thunder / BD-J / Native | 否 | 需安装运行时 |

产品默认走本机 HTTP/JS；Agent 接手说明见 [agent-ios-native-sources.md](agent-ios-native-sources.md)。

所有 UI 只通过 `SourceRouter` 消费路由结果，不直接判断 API 字符串。
