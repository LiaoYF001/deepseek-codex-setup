# 便携资产验证

验证结果见 `results.json`，资产 SHA-256 见 `assets.sha256`。

使用 PowerShell 7.2 或以上（推荐 7.4 或以上）在任意目录执行：

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<解压目录>\validation\test-skills.ps1"
```

脚本通过自身目录定位 `assets`，使用模拟身份、模拟 API 返回和临时配置。它不读取真实用户凭据，不发送网络请求，不修改用户 Broker 配置。测试创建的临时目录在验证完成后清理；原有进程配置覆盖变量会恢复。

54 项断言覆盖：读取不改配置、Local/Domain 与 Entra SID、身份不匹配与非法 SID、脱敏错误、无效响应、单路线变更与原内容备份、失败回滚、并发更新锁及检测到外部编辑后的保留行为。测试中的 SID 和 `sk-unit-test-only-no-provider-secret` 均为固定模拟数据。

资产内两个技能已通过 `skill-creator` 的 `quick_validate.py`，三个技能脚本及离线测试脚本通过 PowerShell 语法解析。另扫描确认资产不含原机器用户名、盘符绝对路径、实际 SID 或 API Key。

与已安装技能相比，仅便携副本作了三项改进：PowerShell 路径按当前机器查找；最低版本明确为 7.2（推荐 7.4 或以上），满足模块所用 .NET API 的要求；用户 SID 由 Windows 标准解析器验证后精确比对，兼容不同 Windows 账户形式。源机器已安装技能未改动。

这些结果说明资产与离线逻辑验证通过；在目标机器上仍应按配置手册完成安装后检查与重启验证。
