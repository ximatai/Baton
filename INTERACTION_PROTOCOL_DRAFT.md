# Baton 交互选择协议草案

> **状态：** 已作为 Companion Profile 1.2 的首版实现依据；精确 wire
> contract 以 `BATON_SPEC.md` 为准。
>
> **目的：** 让 Agent 在对话中给出可点选的下一步，同时保持 Baton 的基本边界：服务端是唯一事实源，客户端不执行任意动作，用户消息仍由用户明确发出。

## 结论与范围

将“选择题”分为两种语义，而不是一个容易被误用的布尔开关：

| 类型 | 用户是否可自由输入 | 点击选项的效果 | 适用场景 |
| --- | --- | --- |
| `suggestions`（建议选择） | 可以 | 点选即发送一个结构化选择回答 | “总结当前结论”“继续排查网络”等快捷追问 |
| `selection_required`（必答选择） | 不可以，直到问题解决 | 提交一个结构化选择回答 | Agent 必须获得明确分支，例如“生产 / 预发布” |

首版只支持**单选**。不包含多选、自由填写“其他”、表单、嵌套问卷、URL 跳转、工具执行或客户端自动发送。

### 内化的确认 / 取消

“确认 / 取消”是必答选择最常见的形态，首版应把它内化为
`selection_required` 的一个标准**呈现变体**，而不是另起一套确认协议：

```json
{
  "type": "selection",
  "interaction_id": "sel_01J...",
  "prompt": "确认结束这段对话吗？",
  "input_policy": "selection_required",
  "presentation": "confirmation",
  "options": [
    { "id": "confirm", "label": "确认" },
    { "id": "cancel", "label": "取消" }
  ]
}
```

`presentation: "confirmation"` 只改变 UI：客户端以一对明确的确认 / 取消按钮
呈现，取消为次要操作；底层仍是同一个 `selection_response`。该变体必须同时满足：

- 仅允许 `input_policy: "selection_required"`；
- 选项恰好为 `confirm` 与 `cancel`，顺序固定为确认在前、取消在后；
- `cancel` 仅表示用户拒绝这一次 Agent 提议，**不是** Baton 的 `run cancel`、结束
  Conversation、删除本地副本或其他客户端命令；
- 选择本身也不授予服务端操作权限。服务端收到 `confirm` 后仍必须按原有业务权限、
  幂等和事务规则决定能否执行后续动作。

这让普通确认无需为每个 Agent 重复设计卡片，同时保留一个关键安全边界：Baton
确认的是用户对 Agent 问题的回答，不是对任意客户端动作的授权。

## 内容模型

Agent 通过 completed assistant message 的 `content` 数组附带选择项；它与文字同属一条可回放的聊天记录，而不是短暂的 UI 指令。

```json
{
  "type": "selection",
  "interaction_id": "sel_01J...",
  "prompt": "请选择排查范围",
  "input_policy": "selection_required",
  "options": [
    { "id": "network", "label": "网络连接" },
    { "id": "device", "label": "设备状态" }
  ]
}
```

字段约束：

- `interaction_id` 为服务端生成的、Conversation 内唯一的 opaque ID；不包含业务数据。
- `prompt` 与 `label` 仅按现有纯文本 / Markdown 渲染规则展示，绝不解释为 HTML、命令或 URL。
- `options` 在首版为 2–8 项；每项 `id` 在 interaction 内唯一且不可变，`label` 是给人看的文本。
- `input_policy` 只能是 `free_text_allowed` 或 `selection_required`。前者即 `suggestions`；为减少 wire 语义，协议中只保留这一个字段，不再另设 `required` 布尔值。

建议选择示例：

```json
{
  "type": "selection",
  "interaction_id": "sel_01J...",
  "prompt": "你也可以继续这样问：",
  "input_policy": "free_text_allowed",
  "options": [
    { "id": "summary", "label": "总结当前结论" },
    { "id": "next", "label": "给出下一步计划" }
  ]
}
```

`free_text_allowed` 的点选也发送下文定义的 `selection_response`，而不是把
`label` 填入输入框。这使建议与必答共用相同的消息、回放、幂等和 Agent
处理路径；唯一差别是建议模式绝不阻塞普通文本。`interaction_id` 用于将
回答关联到该选择卡片，服务端不得因它阻塞其他文本消息。

## 必答选择的状态与回答

`selection_required` 是服务端 Conversation 状态，不能仅依赖客户端记忆。每个 snapshot 必须带回未解决的 interaction；SSE 中的创建、解决、取消均须作为持久化事件，确保重新进入会话、断网恢复和多设备观看时结果一致。

首版每个 Conversation 同时最多有一个未解决的必答 interaction。其生命周期为：

```text
open -- first valid response --> answered
  |-- agent cancel/replace ----> cancelled / superseded
  `-- optional explicit expiry -> expired
```

选择回答仍走现有 `POST /v1/baton/conversations/{id}/messages`，复用 UUID `client_message_id` 的幂等语义：

```json
{
  "client_message_id": "11EF7D8E-...",
  "content": [{
    "type": "selection_response",
    "interaction_id": "sel_01J...",
    "option_id": "network"
  }]
}
```

服务端在同一事务中验证 interaction 仍为 `open`、`option_id` 合法且调用方有发送权限；随后创建一条可回放的 user message、解决 interaction，并追加相应的持久化事件。并发设备中第一条有效回答获胜；同一 `client_message_id` 重试返回原结果，其他回答返回 `409 selection_resolved`。普通文本在有未解决必答题时返回 `409 selection_required`，因此约束不依赖 iOS UI。建议选择不会触发该限制：用户可先后点选建议、自由输入，二者都是普通的 Conversation 消息。

`cancelled`、`superseded` 或 `expired` 后恢复普通输入。若服务确有时限需求，必须在 interaction 中显式给出 `expires_at`；客户端不得自行推断或倒计时后擅自解除约束。

## 客户端呈现

- 选择卡片内嵌在提出问题的 assistant message 下方，随聊天历史持久展示；不使用脱离上下文的全局弹窗或 sheet。
- 两种模式使用同一张紧凑选择卡片：点选一个选项即发送；发送期间禁用重复点选，失败后可显式重试。`presentation: "confirmation"` 则使用统一的确认 / 取消按钮，不额外弹出系统确认框。
- 建议选择不影响 composer，用户仍可同时自由输入。
- 必答选择仅额外禁用 composer，并在输入区附近显示简短提示“请先完成选择”；不使用全局弹窗或额外确认步骤。
- 离线、连接中断或发送进行中时，必答卡片禁用；恢复连接后可再次提交。失败不是终态：只要 snapshot/SSE 尚显示 `open`，用户可以显式重试。
- 其他设备完成选择后，SSE/snapshot 将卡片更新为已选择状态；不得保留可提交的旧按钮。

## 兼容与安全边界

当前 V1.1 discovery `capabilities` 是**服务端声明**，不是设备能力协商。因此，在有旧客户端的环境中，服务端不能仅凭一个新 content item 就下发必答选择：旧 Baton 会将其视为未知内容，无法完成该会话。

建议分两步发布：

1. 先发布 `free_text_allowed`。不支持的客户端可将未知项忽略，Agent 同时保留普通文字提问；该能力只提升体验，不改变自由文本的发送许可。
2. 后发布 `selection_required`。先定义并实现配对时的 per-device capability 声明，例如 `selection_interaction: true`；服务端只向明确支持它的当前设备创建必答 interaction，否则退化为普通文本问题。多设备 Conversation 要以仍可访问的设备能力和服务端产品策略决定是否允许打开必答题，不能假设所有已配对设备都已升级。

服务端始终负责鉴权、选项合法性、原子解决与降级；客户端只渲染受限文本和提交用户选择。不得把 `option_id` 映射为客户端代码、深链、URL、工具调用或权限请求。

## 实施顺序与验收

1. 将该草案评审为正式版本扩展，确定 snapshot/SSE 的精确字段与事件名，并同步更新 `BATON_SPEC.md`、`JAVA_INTEGRATION.md`、mock fixture 及 smoke test。
2. 先实现建议选择：mock 与 reducer 覆盖 snapshot/SSE 重放、点选即发送、幂等重试、自由输入和旧客户端降级。
3. 再实现设备能力协商和必答选择：覆盖幂等重试、两设备竞争、断网恢复、取消/替换、过期和旧客户端回退。
4. 真机验证：进入 → 返回列表 → 重进、杀进程离线重启、网络切换，以及同一 Conversation 的两台已配对设备。

验收结果应保证：选择卡片不会因重连丢失；建议项点选即发送且永不阻塞文字输入；必答项不能被旧 UI 或并发请求绕过；任何不支持的设备都能以普通文本继续对话。
