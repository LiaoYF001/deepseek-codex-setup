---
name: check-deepseek-models
description: 检查 DeepSeek 官方最新模型、账号可用模型及 MixAgents Broker 当前路线，比较别名版本、价格和能力；仅在用户明确要求切换模型时更新个人全局路线。
---

# 检查 DeepSeek 模型

面向本机当前 Windows 用户的所有 Codex 任务。默认只检查、比较和报告；不自动切换模型，不创建定时任务，不发起推理请求。后续明确的“切换到某模型”指令即为更新授权，无需再次确认。

## 检查

1. 解析个人 Broker 配置路径：优先使用当前进程 `MIXAGENTS_BROKER_CONFIG`，必须是绝对路径；未设置时使用 `%APPDATA%\MixAgents\broker.json`。读取 `defaultRoute`、对应路线和用户指定的 DeepSeek 路线，报告当前 API 模型名。不要读取或输出无关凭据。配置不存在时仍可报告官方模型信息，并说明尚未配置 Broker。
2. 使用当前可用浏览工具或无凭据的 HTTPS 请求，现场核对以下官方页面，必要时跟进页面中的最新公告链接：
   - [当前模型与价格](https://api-docs.deepseek.com/quick_start/pricing)
   - [更新记录](https://api-docs.deepseek.com/updates)
   - [Responses API 与 Codex 配置](https://api-docs.deepseek.com/guides/responses_api)
   - [模型列表接口说明](https://api-docs.deepseek.com/api/list-models)
3. 使用 PowerShell 7.2 或以上（推荐 7.4 或以上）执行本技能的 `scripts/check_models.ps1`，不传参数。通过脚本所在目录解析路径，勿依赖当前任务目录。优先使用系统可用的 `pwsh`；若不存在，检查以 `$env:USERPROFILE` 为根目录的 `.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe` 是否存在，或通过 Codex 运行时依赖查询工具获取路径。仅执行实际存在且版本为 7.2 或以上的 PowerShell；都不可用时先安装 PowerShell 7.4 或以上。

   该固定入口只请求 `GET https://api.deepseek.com/models`，不跟随重定向。它从当前用户环境读取 `MIXAGENTS_BROKER_CREDENTIALS_JSON` 的 `DEEPSEEK_API_KEY`，并将实际 Windows SID 与个人 `%APPDATA%\MixAgents\credential-owner.json` 的 `ownerSid` 核对。仅返回经过校验的模型 ID 或固定错误代码。凭据映射可能被控制器的 shell 过滤规则隐藏，这是预期行为。不要转而读取项目中的密钥文本、输出环境变量、传入密钥或改写检查入口。
4. 按官方**当前模型表和公告中的明确日期/版本映射**判断最新模型。`/models` 只能证明账号可见的 ID，不能证明发布日期、Responses 兼容性或别名对应版本。不要按名称排序猜版本，也不要让历史公告覆盖当前官方模型表。分别列出稳定版与实验版；无法确认的映射、价格或兼容性明确标为“未确认”。

报告检查时间（含时区）、配置路径及路线、API 名称与实际版本、账号可见候选，以及适用的上下文长度、输入缓存命中/未命中价格、输出价格（币种和每百万 token 单位）、工具调用/Responses 支持。附本次实际访问的来源；文档矛盾或页面不可用时写明缺口，保留当前配置。

别名可能随服务商更新自动指向新版：报告“API 名称未变、实际版本已更新”与“需要改 API 名称”两种情况。默认给出选择建议，不把价格更高或版本号更大的候选自动当作最佳选择。

## 用户明确要求切换时

用户可使用 API ID、清楚对应的展示名称，或引用最近对话中已唯一选定的候选；已有明确选择与切换授权时直接执行。若“切换到最新/推荐模型”仍可能指 Flash、Pro 等多个候选，先报告选择与差异，待目标明确后再修改，勿自行猜测。

先完成上述检查。只有目标 ID 在账号列表中、当前官方文档明确支持该模型通过 Responses API 工作、并且上下文/必要参数已核实后才修改配置。有冲突、认证失败或兼容性无法确认时停止修改，说明具体阻碍。

运行 `scripts/set_route_model.ps1`，传入现有路线名 `-Route`、已核实目标 `-Model`、刚读取的旧模型 `-ExpectedModel`，以及实际审阅的官方兼容性文档 URL `-CompatibilityEvidenceUrl`。仅在文档要求不同上下文长度时增加 `-ContextWindow`。证据 URL 是审阅记录参数，脚本不会以“URL 看起来正确”替代文档内容审查；脚本会重新查询账号模型列表。

脚本仅支持 DeepSeek 官方 `baseUrl` 路线，保留 `defaultRoute`、其他路线、权限、目录、凭据引用和无关字段。对同一配置路径的助手调用使用跨进程互斥锁，从首次读取持续到验证或回滚；另一个助手正在更新时返回 `CONFIG_BUSY`。原子替换前再次比较原文件哈希；写后验证失败时，仅在当前文件仍为本次写入的确切内容时恢复原内容。检测到外部编辑则保留该编辑并返回 `CONFIG_CONFLICT_AFTER_WRITE`，备份仍可供人工恢复。普通编辑器不遵循该互斥锁，哈希检查与替换之间仍有极短竞争窗口，因此更新期间应避免同时编辑该配置。若官方要求改变模型/上下文以外的参数，不运行该助手，先说明具体兼容性差异并按用户已授权范围进行最小变更与同等备份验证。

成功后报告旧/新模型、是否调整上下文、备份路径和结果。配置供该用户的后续任务使用；已启动的 Broker 进程可能持有旧配置，应新建任务或重启 Codex 后使用 `$broker`。不要声称已验证模型推理或跨任务加载，除非实际完成相应验证。
