# Quitty 打包与公证指南 (Packaging & Notarization Guide)

为了确保用户下载 Quitty 后能直接运行（不弹出“无法验证开发者”或“恶意软件”警告），请遵循以下流程。

## 1. 环境准备

在开始打包前，请确保你拥有以下信息：
- **Apple ID**: 你的开发者账号邮箱。
- **App-Specific Password**: 专用密码。需在 [appleid.apple.com](https://appleid.apple.com) 生成（格式类似 `xxxx-xxxx-xxxx-xxxx`）。
- **Team ID**: `E3237SRTMX` (已配置在脚本中)。
- **Certificate**: 确保 Xcode 中已安装 **Developer ID Application** 证书。

## 2. 自动化工具

项目根目录下已准备好两个关键文件：
- `package.sh`: 全自动执行 编译 -> 导出 -> 打包 DMG -> 公证 -> 订合。
- `ExportOptions.plist`: 导出配置。

## 3. 执行打包

在终端运行以下命令：

```bash
# 1. 设置临时环境变量 (推荐，不在脚本中硬编码安全信息)
export APPLE_ID="你的AppleID邮箱"
export APPLE_PASSWORD="你的App专用密码"

# 2. 运行脚本
./package.sh
```

## 4. 关键步骤说明

1.  **Archiving & Exporting**: 脚本使用 `Release` 配置进行编译，并自动开启 `Hardened Runtime`（公证必需）。
2.  **DMG Creation**: 将 `.app` 放入 DMG，并自动添加 `/Applications` 快捷方式链接。
3.  **Notarization (公证)**: 脚本会上传 DMG 到 Apple 服务器。此过程通常需要 1-5 分钟，脚本会自动等待。
4.  **Stapling (订合)**: 公证通过后，脚本会自动执行 `stapler`。这一步非常关键，它能让用户在离线状态下也能通过初步的安全检查。

## 5. 常见问题排查

- **公证失败 (Invalid)**: 
  如果你收到邮件说公证失败，可以使用脚本输出的 `Submission ID` 查看详情：
  ```bash
  xcrun notarytool log <SUBMISSION_ID> --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "E3237SRTMX"
  ```
- **证书错误**: 
  如果提示找不到 `Developer ID Application` 证书，请在 Xcode -> Settings -> Accounts -> Manage Certificates 中添加。
- **权限问题**: 
  如果 `package.sh` 无法运行，执行：`chmod +x package.sh`。

---
*上次更新时间: 2026-03-17*

## 未来展望：自动升级与 GitHub 自动发布

当你准备好进一步完善发布流程时，可以考虑以下两个方案：

### 1. 自动升级 (Sparkle Framework)
- **目的**: 让应用检测新版本并弹窗提示用户一键更新。
- **关键步骤**:
    - 集成 [Sparkle](https://sparkle-project.org/) SDK (推荐使用 SPM)。
    - 配置 `Appcast.xml` (RSS 订阅源) 用于描述更新内容和下载链接。
    - 生成 EdDSA 签名密钥对，确保升级包安全。
    - 在 GitHub Pages 上托管这个 `Appcast.xml`。

### 2. 自动分发 (GitHub Actions CI/CD)
- **目的**: 每次推送 Tag 时，GitHub 自动打包、公证并创建 Release。
- **关键步骤**:
    - 创建 `.github/workflows/release.yml`。
    - 在 GitHub Secrets 中存储 `APPLE_ID`、`APPLE_PASSWORD` 和 Base64 后的 `.p12` 证书文件。
    - 脚本会自动分发 `.dmg` 至 GitHub Releases。

