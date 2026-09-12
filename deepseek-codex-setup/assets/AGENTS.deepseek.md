<!-- BEGIN personal-deepseek-delegation -->
## DeepSeek 子代理委派偏好（本用户的所有任务）

作为主代理处理明显较长的文档/日志/代码上下文，或简单、重复、可清楚验收的批量工作时，主动评估 DeepSeek 委派是否有收益，并加载个人 `$delegate-deepseek` 技能。只在值得委派时提出具体建议，避免为小任务反复询问。

主动提出的委派必须先说明子任务、需要交给 DeepSeek 的材料、预期结果及读写范围，取得用户同意后再发起外部模型调用。用户明确要求使用 DeepSeek，或给出包含具体任务的 `$broker` 调用，即是该任务的调用授权；已批准范围内的必要补充与继续执行不重复请求。未回复或拒绝不等于授权，继续可独立完成的本地工作。

用户同意委派后，由主代理批准具体文件路径和命令范围：分析任务默认 `read-only`，确需修改的已授权任务可选 `workspace-write`。要求工作代理遇到范围外操作先报告，主代理审查结果、改动和必要验证。权限上限不代表每次调用都获准写入；Codex 的运行时权限审批仍由宿主处理。

使用当前任务目录及其已有目录授权，不绑定安装目录。遵循 `$delegate-deepseek` 和已安装 `$mixagents-broker:broker` 的详细流程。`$check-deepseek-models` 仍默认只检查候选，明确选择后才切换模型。
<!-- END personal-deepseek-delegation -->
