# 牛虎 TVBox iOS 兼容线路

拾萤提供的精简配置：

```text
https://firepick-1302621537.cos.ap-shanghai.myqcloud.com/firepick/niubihu-ios.json
```

配置生成自 `niubihu1/tvbox` 提交
`e8f569259d7dfa889b3f477258b64897fd35a643`，只保留拾萤 iOS 本机能够运行的源：

- 22 个 HTTP/JSON AppleCMS 采集站
- 1 个独立的 CatVod QuickJS 站点
- 4 个经测活可读取的公网直播列表

Java `csp_`、Python、依赖 `drpy2.min.js + ext 规则` 的站点和
`127.0.0.1:35457` 本地直播源均未包含。

## 添加

在拾萤进入：

```text
设置 → 当前线路 → 添加线路
```

粘贴上面的 HTTPS 地址。

## 资源目录

新增的独有采集主机已写入 `sources/cms-candidates.json` 和 App 内置副本，
并通过 `priority` 字段在资源探测时优先进入候选池。与现有目录同主机的镜像不会重复添加。

## 更新配置

先取得上游 `1.json`，再运行：

```bash
node scripts/build-niubihu-ios-config.mjs /path/to/1.json
swift run --package-path Packages/FirepickKit firepick-source-probe \
  --invoke --live --search '沧元图' \
  'https://firepick-1302621537.cos.ap-shanghai.myqcloud.com/firepick/niubihu-ios.json'
```

生成结果位于 `sources/niubihu-ios.json`。上游仓库未声明代码许可证，
因此拾萤只保存配置 URL 和兼容性结果，不复制其 JS、JAR、图片或运行时。
