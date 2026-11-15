## `dl.yychuiyan.com` 证书自动续期

工作流：`.github/workflows/renew-dl-certificate.yml`

每月 1 日检查一次线上证书；剩余有效期低于 45 天才执行续期。手动运行
`Renew dl.yychuiyan.com certificate` 时可以勾选 `force` 强制换证。

流程：

1. 使用 Let's Encrypt DNS-01 签发 `dl.yychuiyan.com` 证书。
2. 通过腾讯云 SSL API 上传证书。
3. 部署到腾讯 CDN 的现有 `cdn` 实例。
4. 轮询线上证书 SHA-256 指纹，确认 CDN 已生效。
5. 从 SideStore 清单读取当前 IPA URL，并执行真实 Range 下载。

旧证书不会被自动删除，部署失败时可以继续提供回滚能力。

### GitHub Secrets

在 `yychuiyan/firepick` 仓库的 `Settings → Secrets and variables → Actions`
添加：

```text
CLOUDFLARE_API_TOKEN
TENCENTCLOUD_SECRET_ID
TENCENTCLOUD_SECRET_KEY
```

Cloudflare API Token 只授权：

```text
Zone / Zone / Read
Zone / DNS / Edit
Zone Resources: yychuiyan.com
```

腾讯云子账号建议只授予 SSL 证书的上传和部署权限。最小 CAM 策略示例：

```json
{
  "version": "2.0",
  "statement": [
    {
      "effect": "allow",
      "action": [
        "ssl:UploadCertificate",
        "ssl:DeployCertificateInstance"
      ],
      "resource": ["*"]
    }
  ]
}
```

不要把凭据写入仓库、README、工作流文件或本地脚本。GitHub Actions 运行器是
临时的，证书私钥只存在于单次任务目录中。

配置好 Secrets 后，在 Actions 中手动运行一次工作流，并勾选 `force` 验证完整
发布链路。成功后可保持每月自动检查。
