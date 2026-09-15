# 便携资产验证

验证汇总见 `results.json`，资产 SHA-256 见 `assets.sha256`。记录均移除了本机路径与身份信息：`model-test-results.json`（54 项断言）、`workspace-preflight-results.json`（28 个场景）及 `windows-launcher-results.json`（25 个场景）。

使用 PowerShell 7.2 或以上（推荐 7.4 或以上），在支持目录联接和 NTFS 权限的 Windows 本地目录解压后执行：

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<解压目录>\validation\test-skills.ps1"
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<解压目录>\validation\test-workspace-preflight.ps1"
```

脚本通过自身目录定位 `assets`，不依赖安装用户或当前任务目录。`-ExecutionPolicy Bypass` 只作用于该次进程，不更改系统执行策略。

## 模型检查与切换

54 项断言覆盖读取不改配置、Local/Domain 与 Entra SID、身份不匹配与非法 SID、脱敏错误、无效响应、单路线变更与原内容备份、失败回滚、并发更新锁，以及检测到外部编辑后的保留行为。测试使用模拟身份、模拟 API 返回和临时配置，不读取真实用户凭据，不发起网络请求，不修改用户 Broker 配置。测试中的 SID 和 `sk-unit-test-only-no-provider-secret` 均为固定模拟数据。原有进程配置覆盖变量会恢复。

## 目录授权预检查

28 个场景覆盖精确目录合并、原字段和备份保留、重复执行无写入、祖先覆盖、相似兄弟目录边界、Windows 目录联接规范化、缺失或空的 roots 初始化、无效配置、已删除/无法访问的旧目录保留、磁盘根与用户目录拒绝、不可访问目录、隔离的环境变量与 APPDATA 配置选择，以及并发新增目录不丢失。

所有配置、备份和权限变更都限于本测试生成的 fixture 目录。测试仅获取当前用户目录和身份来验证拒绝条件或设置 fixture ACL，不读取真实配置或密钥、不调用 Broker、不启动模型。结束时先单独移除测试目录联接，再清理已验证位于验证目录内的 fixture；不会沿用户目录联接进行递归删除。可分享的预检查结果只保留测试名称、状态和计数。

## Windows 启动器与沙箱

`windows-launcher-results.json` 记录隔离安装测试：仅更新 `codexBin`、保留原始配置备份、重复安装无写入、固定的 Broker 0.1.1 启动参数、拒绝附加权限覆盖、退出码和标准输入输出、中文安装目录、默认 APPDATA、环境覆盖、PATH 和 npm 平台包发现，以及无效配置/路径/程序的失败行为。这些测试用假工作程序进行，不读取真实凭据，不启动外部模型。

`windows-sandbox-results.json` 使用实际 Codex 0.154.0-alpha.6.2 与本机回环模拟接口，分别证明只读读取成功、工作区写入与本地命令成功、只读写入被拒绝。三项均未请求宿主审批；没有外部模型请求，未初始化 elevated 沙箱，也未修改主机已有沙箱状态。

`windows-install-results.json` 记录本机实际安装检查：仅 `codexBin` 变化、主配置不变、启动器版本查询成功，重复运行没有写入。这些检查与真实 DeepSeek 调用分开记录。

## 静态检查与验证边界

两个技能通过 `skill-creator` 的 `quick_validate.py`；四个技能脚本、两个测试脚本及 Windows 安装脚本通过 PowerShell 语法解析，Node 启动器通过语法检查。资产扫描检查源用户路径、密钥模式和禁止打包的文件；扫描未读取真实密钥。新增目录预检查 helper 与个人技能同步，委派技能增加 Windows 故障停止规则，`agents/openai.yaml` 保留，模型检查技能的便携实现保持原样。

这些结果证明便携资产和本机离线逻辑通过检查，不代表其他实体机器已经完成安装。真实 DeepSeek 验收记录及范围见配置指南第 7.4 节；目标机器仍须按指南完成安装、重启、新任务发现和连接加载验证。
