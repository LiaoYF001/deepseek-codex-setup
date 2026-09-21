# Codex + DeepSeek 全局配置

Windows 个人级配置指南和可迁移配置包，让同一用户的 Codex 项目使用 DeepSeek 子代理。

当前配置包修订版：**2026.09.21**。已安装旧版的机器可按指南第 6.4–6.6 节升级。

- [阅读完整配置指南](deepseek-codex-setup/配置指南.md)
- [下载完整配置包](DeepSeek-Codex-全局配置包.zip?raw=true)
- [查看配套技能和配置模板](deepseek-codex-setup/assets/)
- [查看离线验证记录](deepseek-codex-setup/validation/README.md)

## 包含内容

- MixAgents Broker 安装、个人配置、凭据导入与重启验证步骤。
- `check-deepseek-models`：检查官方最新模型，得到明确选择后切换。
- `delegate-deepseek`：适合时主动建议委派，得到同意后执行；主代理可直接登记任务所需、且自身有权访问的具体启动目录，并限定读写与命令范围。
- `ensure_workspace.ps1`：首次 Broker 工具调用前检查目录，按需合并、备份，处理连接缓存。
- Windows 专用启动器：解决 Broker 独立进程缺少 Windows 沙箱设置、普通读取被自动拒绝的问题，保留任务读写限制和宿主审批。
- 主代理默认显式选择 Broker 最高支持档 `workspace-write`，明确只读任务仍选 `read-only`；网络共享和外网材料按需由主代理准备后交接，避免无效的额外权限申请。
- 旧版升级、`workspace_approval_declined` 排查、实际沙箱权限边界及恢复方法。
- 模型检查与切换、目录预检查、Windows 启动器和沙箱的隔离验证记录。

最低 PowerShell 版本为 7.2，推荐 7.4 或更新版本。解压配置包后，按指南从准备工作开始配置。

配置包不包含 API Key、本机身份绑定、登录文件或个人配置备份。目标机器需要本地设置凭据，并完成指南第 7 节验证。

2026-09-15 已在新连接的两个独立测试目录中，通过真实 DeepSeek 读取、文件写入和本地计算验收，4 次命令均正常退出。只读模式阻止写入另由离线沙箱测试验证。原有读写限制和宿主审批保留；安装后需要完全重启 Codex，使旧连接加载修复。

## 完整性

`DeepSeek-Codex-全局配置包.zip` 的 SHA-256：

```text
d33a5d22430702a62e2a874dbee0697273b2cdb93602a9f2d4d91bedeaafde9a
```

本版权限与网络交接核对日期：2026-09-21；模型资料仍标明原 2026-09-12 核对日期。新增本地交接测试不调用外部模型。默认可写不等于完整系统或网络访问，Broker 0.1.1 没有完整访问开关。官方模型别名、版本和依赖要求可能变化，详见指南中的来源及模型检查技能。

## 上游项目

Broker 插件通过 [Utopia-V/mixagents](https://github.com/Utopia-V/mixagents) 官方市场安装；本仓库保存配置文档与个人技能配套文件。
