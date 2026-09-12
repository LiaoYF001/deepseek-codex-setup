# Codex + DeepSeek 全局配置

Windows 个人级配置指南和可迁移配置包，让同一用户的 Codex 项目使用 DeepSeek 子代理。

- [阅读完整配置指南](deepseek-codex-setup/配置指南.md)
- [下载完整配置包](DeepSeek-Codex-全局配置包.zip?raw=true)
- [查看配套技能和配置模板](deepseek-codex-setup/assets/)
- [查看离线验证记录](deepseek-codex-setup/validation/README.md)

## 包含内容

- MixAgents Broker 安装、个人配置、凭据导入与重启验证步骤。
- `check-deepseek-models`：检查官方最新模型，得到明确选择后切换。
- `delegate-deepseek`：适合时主动建议委派，得到同意后执行；主代理限定范围并验收。
- 故障排查、更新与回退说明，以及 54 项离线验证。

最低 PowerShell 版本为 7.2，推荐 7.4 或更新版本。解压配置包后，按指南从准备工作开始配置。

配置包不包含 API Key、本机身份绑定、登录文件或个人配置备份。目标机器需要本地设置凭据，并完成指南第 7 节验证。验证过程中未执行付费推理。

## 完整性

`DeepSeek-Codex-全局配置包.zip` 的 SHA-256：

```text
beabafdcb1eac6aed914626304eb41c1dade6a6b12d56f548d1d9685ad36a838
```

内容核对日期：2026-09-12。官方模型别名、版本和依赖要求可能变化，详见指南中的来源及模型检查技能。

## 上游项目

Broker 插件通过 [Utopia-V/mixagents](https://github.com/Utopia-V/mixagents) 官方市场安装；本仓库保存配置文档与个人技能配套文件。