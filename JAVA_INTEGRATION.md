# Java Web 接入指南（Baton Companion Profile 1.0）

本文面向已有 Java Web/Agent 服务的维护者。Baton 的本地 Python 服务是协议测试靶场，不是生产后端；Java 服务继续拥有现有登录态、Conversation、Agent 运行时和业务权限。本文只描述当前 [BATON_SPEC.md](BATON_SPEC.md) 已定义的 V1 行为，不要求引入某个 Java 框架、SDK 或 Agent 框架。

## 边界与职责

| 部件 | 负责 | 不负责 |
| --- | --- | --- |
| Java Web / 业务服务 | 复用现有用户会话和权限，创建/批准 pairing；绑定 Conversation；持久化消息与事件；调用现有 Agent | 不把 LM Studio 或任何模型密钥交给 iOS |
| Baton iOS | 扫描 discovery URL，生成并保管 `device_proof`，提交加入请求，等待网页决定；缓存、发送文本、消费/恢复 SSE；本地语音转文字 | 不批准自己的 pairing；不直连 Agent 或模型服务 |
| Companion Profile | 定义发现、配对、设备凭据、Conversation API、事件 envelope、游标和能力声明 | 不定义模型 API、业务登录、工具协议或 Agent-to-Agent 协议 |
| AG-UI adapter（可选） | 将现有 Agent 的 V1 AG-UI 事件映射为 Baton event drafts | 不改变 iOS wire format，不替代 pairing、授权或事件日志 |

服务器是 Conversation 的唯一事实源。Web 与 Baton 是同一会话的平级客户端，客户端之间不直接传递消息。

## 配对与浏览器授权

生产 Java 服务应按以下状态机实现：

```text
created -- device joins --> pending -- web allows --> approved -- first claim --> consumed
   |                           |              \\ web denies --> rejected
   +---------------------------+---------------------- expires --> expired
```

1. 已认证的 Web 页面调用 `POST /v1/baton/pairings`，将 pairing 绑定到当前用户、浏览器会话和选定 Conversation。生成至少 256 bit 的高熵 `pairing_id`，有效期不超过 60 秒，并返回 QR URL、approval URL 和过期时间。
2. QR 只包含同源 HTTPS discovery URL；不得放 bearer token、Conversation 历史或永久凭据。V1 要求 discovery 中的 endpoint 与 QR origin 同源。
3. iOS 读取 discovery 后调用 join，提交 `device_id`、展示名和仅本地持有的 `device_proof`。服务只接受一个设备请求，状态转为 `pending`。
4. Java Web 在已有登录会话下展示设备名称，用户明确允许或拒绝。创建和批准均必须遵循现有 Web 的 CSRF 防护（同站 Cookie、CSRF token/header、Origin/Referer 校验等按现有应用规则实现）。不能把“扫描二维码”视为浏览器授权；Mock 的无登录 HTML 表单仅用于本地测试。
5. iOS 用 `X-Baton-Device-Proof` 轮询 status。批准后首次 claim 签发 Conversation-scoped、绑定设备的短期 Bearer token（规范建议 24 小时）；proof 绑定的重试在 pairing 仍有效时返回同一 token。拒绝或过期永不签发 token。

Java 服务应使 approval 具有服务端授权检查和一次性状态转换，防止任意知道 URL 的人批准 pairing。配对过期、拒绝、重复设备请求、错误 proof 都应是明确的终态/错误，而不是静默成功。

## Endpoint 契约

完整字段以 [BATON_SPEC.md](BATON_SPEC.md) 为准；以下说明调用方、最小语义和当前错误行为。JSON 错误统一形如 `{"error":{"code":"...","message":"..."}}`，message 可面向用户，code 才用于程序判断。

| 操作 | Endpoint | 调用方与语义 | 典型错误 |
| --- | --- | --- | --- |
| 创建 pairing | `POST /v1/baton/pairings` | Web；创建 Conversation-bound 短期邀请并返回 `pairing_id`、`qr_url`、`approval_url`、`expires_at` | 输入无效时 `400` |
| Discovery | `GET /.well-known/baton/pair/{pairingId}` | Baton；只返回服务、Conversation、同源 endpoint 和 capabilities，不授予权限 | 未知 `404 pairing_not_found`；过期 `410 pairing_expired` |
| 加入请求 | `POST /v1/baton/pairings/{id}/requests` | Baton；JSON 提交 `device_id`、`device_name`、`device_proof`；成功为 `202 pending` 并返回 `request_id`、`poll_url` | 字段/低熵 proof `400 invalid_device`；已有请求/非 created `409 pairing_not_available`；未知/过期同上 |
| 状态/claim | `GET /v1/baton/pairings/{id}/requests/{requestId}` | Baton；必须带 `X-Baton-Device-Proof`；pending 返回重试间隔，approved 返回 token，rejected 返回终态 | proof 不符 `403 invalid_device_proof`；请求不存在 `404 request_not_found`；不可用 `409 pairing_not_available` |
| 决定 pairing | `POST /v1/baton/pairings/{id}/approval` | Web；现有登录和 CSRF 保护下提交 `{ "decision": "approved"\|"rejected" }` | 无效决定 `400 invalid_decision`；非 pending `409 pairing_not_pending`；未登录/无权由现有 Web 授权层拒绝 |
| 快照 | `GET /v1/baton/conversations/{id}` | Baton；Bearer token；原子返回元数据、分页历史和 `event_cursor`，缓存不是事实源 | 无/错 token `401 invalid_token`；未知 Conversation `404 conversation_not_found` |
| 发送 | `POST /v1/baton/conversations/{id}/messages` | Baton；Bearer token；文本消息必须含 UUID `client_message_id`；相同 id 重试返回原消息，不重复创建 | `401 invalid_token`、`404 conversation_not_found`、`400 invalid_message` |
| 事件流 | `GET /v1/baton/conversations/{id}/events` | Baton；Bearer token 的 SSE；将 snapshot 的 `event_cursor.id` 放入 `Last-Event-ID` 恢复 | `401 invalid_token`、`404 conversation_not_found`；游标不可恢复时发送 `conversation.resync` |
| 停止 | `POST /v1/baton/conversations/{id}/runs/{runId}:cancel` | Baton；Bearer token；异步请求取消活动 run；仅 `run.cancelled` 代表终态 | `401 invalid_token`、`404 run_not_found` |
| 断开/撤销 | `DELETE /v1/baton/devices/{deviceId}/sessions/{id}` | Baton；Bearer token；撤销该设备会话并立即阻止后续访问 | `401 invalid_token`；未知资源按服务现有错误映射 |

发送响应首创消息时为 `201`，幂等重试为 `200`。快照与 `event_cursor` 必须由同一个事务/锁内读取：`event_cursor` 至少含 `{ "id": "evt_…", "sequence": 487 }`，并表示该快照已包含的最后一个事件位置。iOS 随后以此 `id` 打开 SSE，服务只回放 sequence 更大的已持久化 envelope。没有 `Last-Event-ID` 的新订阅从当前 tail 开始，不得暗中把整段事件历史推送给客户端。

SSE event id 按 Conversation 严格递增，事件至少保留 24 小时；每个持久化事件都使用 `id:`、与 envelope `type` 相同的 `event:` 和 JSON `data:` 标准字段，数据仍包在 Baton envelope 中，不要把 AG-UI 原始事件名直接暴露给 iOS。若 `Last-Event-ID` 未知或超过 retention，**不得从头回放**：仅向该连接发送一个完整的 `conversation.resync` envelope，`data.reason` 为 `cursor_unknown_or_expired`，其 id/sequence 复用当前最新保留游标。它不写入 Conversation event log；客户端必须重新取 snapshot 并以新的 `event_cursor` 继续。

cancel 的 `202 cancellation_requested` 只代表服务已接受请求；执行器应保证流式 assistant 消息先收到 `message.completed { status: "cancelled" }`，再且仅再一次发送 `run.cancelled`。重复取消同一终态 run 可返回其现有 terminal status，但不能重复发布终态事件。

## `device_proof` 与 token 安全

- `device_proof` 由 iOS 用系统安全随机源生成，至少 256 bit；只放请求体和 `X-Baton-Device-Proof` header，绝不放 QR、discovery、URL、HTML 或日志。
- Java 服务将 proof 与 pairing request 绑定，比较时使用常数时间比较；持久化实现应避免明文长期保存（至少按服务现有 secret 保护策略加密或保存不可逆摘要），并限制读取权限。日志、追踪、异常内容必须脱敏。
- 一个 pairing 只接受一个设备请求。首次成功 claim 后标记 `consumed`；同一 proof 在邀请仍有效时可以安全重试并得到相同 token，其他 proof 永远不能领取。
- access token 只代表一个 Conversation 和一个设备，存活期短（规范建议 24 小时），仅通过 HTTPS Bearer header 传输；不放 query string、HTML 或事件数据。当前协议没有规定 refresh endpoint，不要擅自把 refresh token 变成 V1 必需接口。
- Keychain 由 iOS 保存 token。服务端撤销设备时应使该设备的 token/刷新凭据（若服务已有刷新机制）和活动流失效；Java 服务不应依赖客户端主动删除作为安全边界。

## Agent 与 AG-UI 事件接入

现有 Agent 可以继续使用自有运行接口。若采用 AG-UI，Java 侧放一个 adapter：先把 AG-UI V1 子集映射为 Baton event draft，再由 Companion 服务统一补齐 `id`、`sequence`、`occurred_at`，写入 Conversation event log，最后广播/回放 SSE。

当前参考 adapter（`mock_server/agui_adapter.py`）支持：

| AG-UI | Baton |
| --- | --- |
| `MESSAGES_SNAPSHOT` | `conversation.snapshot` |
| `RUN_STARTED` | `run.started` |
| `TEXT_MESSAGE_START` | `message.created` |
| `TEXT_MESSAGE_CONTENT` | `message.delta` |
| `TEXT_MESSAGE_END` | `message.completed` |
| `RUN_FINISHED` | `run.completed` |
| `RUN_ERROR` | `message.failed`，随后失败状态的 `run.completed` |

写入顺序必须是：Agent 事件 → adapter draft → 服务端补充序号并持久化 → SSE 发布。这样断线客户端能用 `Last-Event-ID` 回放，且不会出现“已发给在线客户端、重连后却没有”的事件。未知、tool、reasoning、state、custom 和非文本 AG-UI 事件在 V1 可记录诊断并忽略，不得强迫 iOS 理解它们。

## Java/Servlet 实现建议

- 在 Servlet/Spring MVC 等 HTTP 层，将 Web caller（Cookie/session）与 Baton caller（Bearer + proof）分成不同的认证过滤路径；不要用一个宽松的匿名规则覆盖 approval。
- SSE 响应使用 `text/event-stream`、禁用会破坏长连接的缓存，并在空闲期间发送 heartbeat；断开后释放订阅资源。事件发布应在事务提交/事件日志成功后进行。重连游标只可查询保留的 event log，不能把任意未知 id 解释为 sequence 0。
- 用数据库或现有持久化层保存 pairing、设备会话、消息幂等键和 Conversation event log；Python Mock 的内存结构只作为行为参考。
- 对 `client_message_id` 建 Conversation 范围内唯一约束或等价的幂等机制；发送重试必须返回原 server message。
- 在服务已有的事务、授权、限流、审计和脱敏设施中实现上述边界。不要为了接入 Baton 引入新的用户体系或让 Java 服务代管模型密钥。

## 集成验收清单

先运行本地 Python fixture，再用 Java endpoint 替换同一请求序列。以下项目直接对应 `mock_server/smoke_test.py` 覆盖内容：

- [ ] Web 创建短期 pairing，discovery 绑定正确 Conversation，QR 不含 token。
- [ ] 未 claim 前访问 Conversation 返回 `401`；扫描只产生 pending 请求。
- [ ] 一个 pairing 第二次 join 返回 `409`；Web 能看见设备名。
- [ ] Web 明确批准后，错误 proof 返回 `403`，正确 proof 才能 claim。
- [ ] claim 重试返回同一 token；pairing 标记 consumed 且不接受第二台设备。
- [ ] Web 拒绝后 status 返回 rejected，永不返回 token。
- [ ] 过期 pairing 返回 `410 pairing_expired`。
- [ ] 快照可读且带原子 `event_cursor`；重复相同 `client_message_id` 不创建重复用户消息（首次 `201`、重试 `200`）。
- [ ] SSE 能收到标准 `id/event/data` 格式的 `message.created`、`run.started`、`message.delta`、`message.completed`、`run.completed`；使用 snapshot 的 `Last-Event-ID` 只恢复后续事件，未知/过期 cursor 只收到 `conversation.resync` 而非从头重复。
- [ ] cancel 首次返回已接受，随后按“message cancelled → run.cancelled”获得唯一终态；重复取消不重复发布事件；DELETE 撤销后未来访问被拒绝。
- [ ] AG-UI V1 fixture 映射到上述 Baton 事件；未知 AG-UI 事件只进入诊断，不泄漏到 iOS wire format。
- [ ] 所有 HTTPS、proof、token、Cookie/CSRF 和日志脱敏检查通过；LM Studio key 不出现在代码、文档、请求或 iOS 包内。

## V1 暂缓

不因 Java 接入提前实现图片/相机/文件、Agent action approval（区别于网页确认设备 pairing）、Tool UI、generated UI、location、Face ID confirmation、push notification、WebSocket、账户体系或 Java SDK。能力声明可保留未来扩展键，但服务和 iOS V1 只依赖 `text`、`markdown`、`streaming` 及设备端 `on_device_speech_to_text`。
