# Firepick Bridge (Android)

Firepick Bridge 是一个前台服务，通过固定 TLS 证书暴露 `/v1` Provider
协议，让 iOS 客户端执行 Android 侧 CatVod 运行时。

## 当前能力

- TLS 证书生成、SHA-256 指纹与客户端证书固定
- 一次性配对码、设备 Bearer Token 和配对撤销
- 配置上传、SHA-256 校验与 Provider 会话隔离
- 健康检查、Provider 调用和代理流接口
- 内置 QuickJS 和 Java/JAR CatVod Provider
- Python、Node.js、Thunder、BD-J 运行时按需安装
- `_firepick._tcp` Bonjour 服务发现
- 固定端口 `9443`

## 构建

要求：

- Android SDK 37
- Android NDK `28.2.13676358`
- JDK 21+

在仓库根目录执行：

```bash
export ANDROID_HOME="/opt/homebrew/share/android-commandlinetools"
export JAVA_HOME="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
make build-bridge
```

或直接：

```bash
cd apps/bridge
./gradlew :app:assembleDebug
```

APK 输出：

```text
apps/bridge/app/build/outputs/apk/debug/app-debug.apk
```

构建依赖仓库根目录中由 `make bootstrap` 生成的固定版本
`third_party/fongmi-tv` 和 `third_party/quickjs`。

## 配对

1. 将 Android 与 iPhone/iPad 接入同一局域网。
2. 打开 Bridge，等待状态显示“运行中”。
3. 在 iOS 拾萤中扫描 Bridge 二维码，或粘贴 `firepick://pair?...` URI。
4. 配对成功后，iOS 会保存设备 Token。

“撤销全部设备配对”会使所有已配对 iOS 客户端失效。
