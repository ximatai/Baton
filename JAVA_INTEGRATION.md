# Java Web 接入指南（Baton Companion Profile 1.2）

> **受众：已有 Java Web/Agent 服务的接入维护者。** 这是一份实现指南；完整 wire contract 以 [BATON_SPEC.md](BATON_SPEC.md) 为准，产品介绍见 [README.md](README.md)。

Baton 的本地 Python 服务是协议测试靶场，不是生产后端；Java 服务继续拥有现有登录态、Conversation、Agent 运行时和业务权限。本文只描述当前 [BATON_SPEC.md](BATON_SPEC.md) 已定义的 V1.1 行为，不要求引入某个 Java 框架、SDK 或 Agent 框架。

## 边界与职责

| 部件 | 负责 | 不负责 |
| --- | --- | --- |
| Java Web / 业务服务 | 复用现有用户会话和权限，创建/批准 pairing；绑定 Conversation；持久化消息与事件；调用现有 Agent | 不把 LM Studio 或任何模型密钥交给 iOS |
| Baton iOS | 扫描 discovery URL，生成并保管 `device_proof`，提交加入请求，等待网页决定；缓存、发送文本、消费/恢复 SSE；本地语音转文字 | 不批准自己的 pairing；不直连 Agent 或模型服务 |
| Companion Profile | 定义发现、配对、设备凭据、Conversation API、事件 envelope、游标和能力声明 | 不定义模型 API、业务登录、工具协议或 Agent-to-Agent 协议 |
| AG-UI adapter（可选） | 将现有 Agent 的 V1 AG-UI 事件映射为 Baton event drafts | 不改变 iOS wire format，不替代 pairing、授权或事件日志 |

服务器是 Conversation 的唯一事实源。Web 与 Baton 是同一会话的平级客户端，客户端之间不直接传递消息。

## Capabilities

Discovery document 内的 `capabilities` 只是服务端对当前 Conversation
的能力声明，不是设备协商、也不授予权限。`text: true` 为 V1.1 必填；
`markdown`、`streaming`、`image`、`content_append` 仅在服务真正支持时声明。`conversation_end`
默认 `false`；仅当服务允许 Baton 发起共享 Conversation 的结束操作时才声明为 `true`，Baton
不会因为服务存在 `:end` endpoint 而自行展示结束操作；服务端仍须自行鉴权。`image` 只表示
服务会下发可读取的静态图片内容项，不是上传协商或设备权限。iOS 的本地语音能力
不需要也不应在 V1.1 回传。未来若要支持 camera/file/approval 等双向能力，
必须另行定义协商、授权与降级语义，不能把未知字段视为已经协商成功。

V1.2 的 `selection: true` 表示服务可提供受限的单选交互。Baton 在 join
body 中声明 `client_capabilities.selection_interaction: true`；这是设备渲染能力，
不是权限。服务端只可在兼容策略允许时下发 `selection_required`，否则退化为普通
文本问题。`free_text_allowed` 与必答选择都通过现有 messages endpoint 提交
`selection_response`；服务端必须持久化状态、原子校验第一条有效回答，并以 snapshot
的 `selection_states` 和 SSE `selection.resolved` / `selection.cancelled` 使重连和多设备一致。

## 配对与浏览器授权

生产 Java 服务应按以下状态机实现：

```text
manual: created -- device joins --> pending -- web allows --> approved -- first claim --> consumed
                                  |              \\ web denies --> rejected
auto:   created -- device joins -----------------> approved -- first claim --> consumed
   +---------------------------------------------- expires --> expired
```

1. 已认证的 Web 页面调用 `POST /v1/baton/pairings`，将 pairing 绑定到当前用户、浏览器会话和选定 Conversation。生成至少 256 bit 的高熵 `pairing_id`，有效期不超过 60 秒，并返回 QR URL、approval URL、`approval_mode` 和过期时间。`approval_mode` 缺省为 `manual`；只有服务端在自身权限与 Conversation 策略允许时才能设为 `auto`。
2. QR 只包含绝对的 HTTP 或 HTTPS discovery URL；不得放 bearer token、Conversation 历史或永久凭据。服务端自行选择 transport，V1.1 要求 discovery 中的 endpoint 与 QR origin 完全同源（scheme、host、port）。HTTP 已被协议支持以兼容既有内网/遗留系统，但 Baton 会持续标记为未加密；服务方必须自行评估该网络不能提供传输保密性与完整性的风险，客户端不会静默升级或降级。
3. iOS 读取 discovery 后调用 join，提交 `device_id`、展示名和仅本地持有的 `device_proof`。服务只接受一个设备请求：`manual` 转为 `pending`，`auto` 必须在同一事务中直接转为 `approved`。
4. `manual` 时，Java Web 在已有登录会话下展示设备名称，用户明确允许或拒绝。创建和批准均必须遵循现有 Web 的 CSRF 防护（同站 Cookie、CSRF token/header、Origin/Referer 校验等按现有应用规则实现）。`auto` 不经过这一页，但不是“无安全性”：有效期内 QR 本身成为加入该 Conversation 的短期能力，只有服务端明确认可该风险的受控场景才可启用。不能让 iOS 参数、discovery 字段或前端页面越权选择 `auto`；Mock 的无登录 HTML 表单仅用于本地测试。
5. iOS 用 `X-Baton-Device-Proof` 轮询 status。批准后首次 claim 签发 Conversation-scoped、绑定设备的短期 Bearer token（规范建议 24 小时）；proof 绑定的重试在 pairing 仍有效时返回同一 token。拒绝或过期永不签发 token。

Java 服务应使 `manual` approval 具有服务端授权检查和一次性状态转换，防止任意知道 URL 的人批准 pairing；`auto` 的启用条件同样必须由服务端授权与策略决定。配对过期、拒绝、重复设备请求、错误 proof 都应是明确的终态/错误，而不是静默成功。

## Endpoint 契约

完整字段以 [BATON_SPEC.md](BATON_SPEC.md) 为准；以下说明调用方、最小语义和当前错误行为。JSON 错误统一形如 `{"error":{"code":"...","message":"..."}}`，message 可面向用户，code 才用于程序判断。

| 操作 | Endpoint | 调用方与语义 | 典型错误 |
| --- | --- | --- | --- |
| 创建 pairing | `POST /v1/baton/pairings` | Web；创建 Conversation-bound 短期邀请并返回 `pairing_id`、`qr_url`、`approval_url`、`approval_mode`、`expires_at`；`approval_mode` 默认 `manual`，服务端可选 `auto` | 输入无效或不允许的 mode 时 `400/403` |
| Discovery | `GET /.well-known/baton/pair/{pairingId}` | Baton；只返回服务、Conversation、同源 endpoint 和 capabilities，不授予权限 | 未知 `404 pairing_not_found`；过期 `410 pairing_expired` |
| 加入请求 | `POST /v1/baton/pairings/{id}/requests` | Baton；JSON 提交 `device_id`、`device_name`、`device_proof`；成功为 `202` 并返回 `request_id`、绝对同源且可由手机直接访问的 `poll_url`；manual 为 pending，auto 原子进入 approved | 字段/低熵 proof `400 invalid_device`；已有请求/非 created `409 pairing_not_available`；未知/过期同上 |
| 状态/claim | `GET /v1/baton/pairings/{id}/requests/{requestId}` | Baton；必须带 `X-Baton-Device-Proof`；pending 返回重试间隔，approved 返回 token，rejected 返回终态 | proof 不符 `403 invalid_device_proof`；请求不存在 `404 request_not_found`；不可用 `409 pairing_not_available` |
| 决定 pairing | `POST /v1/baton/pairings/{id}/approval` | Web；仅 manual，现有登录和 CSRF 保护下提交 `{ "decision": "approved"\|"rejected" }` | 无效决定 `400 invalid_decision`；非 pending/auto `409 pairing_not_pending`；未登录/无权由现有 Web 授权层拒绝 |
| 快照 | `GET /v1/baton/conversations/{id}` | Baton；Bearer token；原子返回元数据、有上限的初始历史、必填 `event_cursor` 与可选 `active_runs`，缓存不是事实源 | 无/错 token `401 invalid_token`；未知 Conversation `404 conversation_not_found` |
| 发送 | `POST /v1/baton/conversations/{id}/messages` | Baton；Bearer token；文本消息必须含 UUID `client_message_id`；相同 id 重试返回原消息，不重复创建 | `401 invalid_token`、`404 conversation_not_found`、`400 invalid_message` |
| 读取图片 | `GET image.url` | Baton；Bearer token；仅读取消息 `content[]` 中同源的静态图片 | `401 invalid_token`、`404` 或服务定义的媒体错误 |
| 事件流 | `GET /v1/baton/conversations/{id}/events` | Baton；Bearer token 的 SSE；将 snapshot 的 `event_cursor.id` 放入 `Last-Event-ID` 恢复 | `401 invalid_token`、`404 conversation_not_found`；游标不可恢复时发送 `conversation.resync` |
| 停止 | `POST /v1/baton/conversations/{id}/runs/{runId}:cancel` | Baton；Bearer token；异步请求取消活动 run；仅 `run.cancelled` 代表终态 | `401 invalid_token`、`404 run_not_found` |
| 结束对话 | `POST /v1/baton/conversations/{id}:end` | Web 或 Baton；Bearer/现有 Web 会话均须有服务自身 `conversation:close` 权限，且带 `Idempotency-Key` UUID；服务端原子结束共享 Conversation | 无权 `403 conversation_close_forbidden`；未知 `404 conversation_not_found`；同 key 重试 `200` 原结果 |
| 断开/撤销 | `DELETE /v1/baton/devices/{deviceId}/sessions/{id}` | Baton；Bearer token；撤销该设备会话并立即阻止后续访问 | `401 invalid_token`；未知资源按服务现有错误映射 |

发送响应首创消息时为 `201`，幂等重试为 `200`。快照与 `event_cursor` 必须由同一个事务/锁内读取：`event_cursor` 至少含 `{ "id": "evt_…", "sequence": 487 }`，并表示该快照已包含的最后一个事件位置。iOS 随后以此 `id` 打开 SSE，服务只回放 sequence 更大的已持久化 envelope。没有 `Last-Event-ID` 的新订阅从当前 tail 开始，不得暗中把整段事件历史推送给客户端。

## 服务端图片内容

服务可在按时间顺序的消息 `content[]` 中下发 `{ "type": "image", "media_id", "url", "mime_type", "width", "height", "alt" }`，并在 discovery 声明 `"image": true`。`media_id` 必须是服务内唯一、opaque、指向不可变 media rendition 的稳定身份；`url` 只是 Baton iOS 的读取地址，必须与 Conversation endpoint 精确同源、不得包含 token。Baton 会带现有 Bearer header 请求它且拒绝重定向。只支持静态 `image/jpeg`、`image/png`、`image/webp`，响应 MIME 必须与 `mime_type` 一致，单项不超过 12 MiB / 2500 万解码像素。不得把图片 bytes 写入 snapshot、SSE、日志或 `content` JSON，也不得借此增加上传、文件或外链图床接口。Baton 会把已接受的 Conversation 快照和已下载媒体按会话、`media_id` 保存为私有离线副本；这不依赖 `Cache-Control`，也不使用 URLSession/URLCache。副本受 iOS 文件保护、不会备份，并在设备移除配对、`401 invalid_token` 或会话撤销时删除；不得在其中写入 Bearer、`device_proof` 或 Web 凭据。单个媒体的 `404/410` 只显示附件不可用。

Web、桌面端不得获得或复用 Baton device Bearer。它们以现有 Cookie/SSO/网关会话通过服务自有 bridge/resolver 读取同一 `media_id`；该接口不属于 Baton 规范，且不得把任一 Web 会话专属 URL 写进 Baton snapshot 或 SSE。

服务在 discovery 声明 `"content_append": true` 后，可持久化发送 `message.content.appended`：仅面向已完成 assistant message，`data` 必含 `message_id` 和非空的完整 image `content[]`，按顺序末尾追加。该 event 沿用正常 `id`/`sequence` 回放与去重；非法内容或不存在/非 completed assistant 的目标必须使客户端 resync。不得实现替换、插入、删除、客户端发起 append 或上传。

Join 响应里的 `poll_url` 必须是完整的绝对 URL（含 scheme 和 host），与 discovery / join 的**服务对外 origin** 完全相同，并可由发起请求的 iPhone 直接访问；不得返回 `/v1/...` 这样的相对路径。它只可含 request id，不能含 token 或 `device_proof`，领取仍需 `X-Baton-Device-Proof`。在反向代理或 TLS 终止之后，Java 服务必须使用受信任部署配置确定 canonical external origin（包括所选的 `http` 或 `https` scheme），不能直接信任任意 `Host` 或 `X-Forwarded-*` 请求头来拼 URL。相对、跨 origin 或不可访问的 `poll_url` 是契约失败，Baton 会在 join 阶段拒绝它。

V1.1 不提供移动端历史分页。snapshot 的 `messages` 必须以时间正序一次返回完整初始窗口：最多最新 200 条完整消息、且序列化文本总量最多 1 MiB，先达到任一边界即截断旧消息。超限返回 `history_truncated: true`，不得返回半条消息、不得返回 `next_cursor`；旧历史仍由现有 Web 产品负责。snapshot 可省略 `active_runs`，客户端按空数组处理；提供时它必须与 history/cursor 同一事务读取，形状为 `[{"run_id":"run_…","status":"running","message_id":"msg_…"}]`，其中 `message_id` 可省略，且只列非终态 run。iOS 用 `run_id` 在重连后恢复 Stop。

SSE event id 按 Conversation 严格递增，事件至少保留 24 小时；响应固定为 `200 Content-Type: text/event-stream; charset=utf-8` 与 `Cache-Control: no-cache`，并按部署栈关闭代理缓冲。每个持久化事件都以 UTF-8 的 `id:`、与 envelope `type` 相同的 `event:`、JSON `data:` 和空行标准 framing 发送；心跳可用 SSE comment，不得伪装 Baton event。HTTP 失败必须返回 JSON，不能先写半截 SSE。不要把 AG-UI 原始事件名直接暴露给 iOS。

若 `Last-Event-ID` 未知或超过 retention，**不得从头回放**：仅向该连接发送一个完整的 `conversation.resync` envelope，`data.reason` 为 `cursor_unknown_or_expired`，其 id/sequence 复用当前最新保留游标。它不写入 Conversation event log；客户端必须重新取 snapshot 并以新的 `event_cursor` 继续。每个 Baton envelope（包括非持久化的 `conversation.resync`）都必须带正整数 `sequence`。服务端在每次回放/直播中按连续 `sequence` 发出所有 retained envelope，不能有意跳号。客户端保存最后已接受的 `{id, sequence}`：**只有 id 与 sequence 都相同的 exact duplicate 才可忽略**；旧或同序但 id 不同、同一 id 却对应不同 sequence、任何其他非递增 sequence，以及 `sequence > previous + 1` 都是连续性损坏，客户端停止应用流并取新 snapshot。snapshot 的 `event_cursor` 是必填的原子边界，不能为空 id 或非正 sequence；客户端不得以首个 SSE event 建立 cursor。运输断线、格式/MIME 不符与该 gap 走同一 resync 路径。

cancel 的 `202 cancellation_requested` 只代表服务已接受请求；执行器应保证流式 assistant 消息先收到 `message.completed { status: "cancelled" }`，再且仅再一次发送 `run.cancelled`。重复取消同一终态 run 可返回其现有 terminal status，但不能重复发布终态事件。

## 结束 Conversation：事务与权限边界

`POST /v1/baton/conversations/{id}:end` 不是清空 UI，也不是删除历史的快捷方式。它必须走 Java 服务既有的 Conversation 授权：只有拥有 `conversation:close` 的 Web 用户或 Baton device session 可以调用；已认证但权限不足固定返回 `403 conversation_close_forbidden`。请求必须携带 `Idempotency-Key` UUID，并在 Conversation 范围内持久化该 key 与最终结果。

首次成功的事务按同一提交边界完成：标记 Conversation closed；使所有 active device session/token 失效；使所有 created/pending/approved-but-unclaimed pairing 失效；对 active run 设置不可再写入的 fence；追加 **唯一一条** 已持久化的 `conversation.closed` envelope。事务提交后才广播该事件，随后关闭已有 SSE 连接。对外部模型的取消是 best effort，不得阻塞 close：任何在 fence 之后返回的 delta、completed、failed 或新消息都必须丢弃，且 `conversation.closed` 之后绝不可再写入事件。

同一 `Idempotency-Key` 的网络重试返回第一次的 `200` 结果，不重复广播或撤销；为支持这个唯一重试，服务可仅对该已完成的 key 验证原调用者身份，不能把一般已撤销 token 重新激活。其余被撤销 session 的后续请求一律 `401 session_revoked`。若请求在关闭边界前已通过鉴权、但到业务执行时发现已关闭，返回 `410 conversation_closed`。已关闭 Conversation 永不 reset/reopen；用户再次开始时，必须创建新 `conversation_id`，重新建立事件序列和 pairing，绝不复用旧 Conversation 的 id 或 sequence。

`conversation.closed` 是客户端最终状态：Web 和 iOS 都删除本地会话凭据并回到可发起新 pairing 的界面。不要要求客户端等待 `run.cancelled`；关闭事件已覆盖任何 in-flight run。

## `device_proof` 与 token 安全

- `device_proof` 由 iOS 用系统安全随机源生成，至少 256 bit；只放请求体和 `X-Baton-Device-Proof` header，绝不放 QR、discovery、URL、HTML 或日志。
- Java 服务将 proof 与 pairing request 绑定，比较时使用常数时间比较；持久化实现应避免明文长期保存（至少按服务现有 secret 保护策略加密或保存不可逆摘要），并限制读取权限。日志、追踪、异常内容必须脱敏。
- 一个 pairing 只接受一个设备请求。首次成功 claim 后标记 `consumed`；同一 proof 在邀请仍有效时可以安全重试并得到相同 token，其他 proof 永远不能领取。
- access token 只代表一个 Conversation 和一个设备，存活期短（规范建议 24 小时），只放在 Bearer header 传输；不放 query string、HTML 或事件数据。HTTPS 强烈推荐。若现有服务选择 HTTP，Baton 仍会互通但会持续标记未加密；该网络中的 token 与会话流量不具备传输保密性或完整性，服务方必须承担并限制此风险。当前协议没有规定 refresh endpoint，不要擅自把 refresh token 变成 V1.1 必需接口。
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

写入顺序必须是：Agent 事件 → adapter draft → 服务端补充序号并持久化 → SSE 发布。这样断线客户端能用 `Last-Event-ID` 回放，且不会出现“已发给在线客户端、重连后却没有”的事件。未知、tool、reasoning、state、custom 和非文本 AG-UI V1 事件可记录诊断并忽略，不得强迫 iOS 理解它们。

## Java/Servlet 实现建议

- 在 Servlet/Spring MVC 等 HTTP 层，将 Web caller（Cookie/session）与 Baton caller（Bearer + proof）分成不同的认证过滤路径；不要用一个宽松的匿名规则覆盖 approval。
- SSE 响应使用 `text/event-stream`、禁用会破坏长连接的缓存，并在空闲期间发送 heartbeat；断开后释放订阅资源。事件发布应在事务提交/事件日志成功后进行。重连游标只可查询保留的 event log，不能把任意未知 id 解释为 sequence 0。
- 用数据库或现有持久化层保存 pairing、设备会话、消息幂等键和 Conversation event log；Python Mock 的内存结构只作为行为参考。
- 对 `client_message_id` 建 Conversation 范围内唯一约束或等价的幂等机制；发送重试必须返回原 server message。
- 在服务已有的事务、授权、限流、审计和脱敏设施中实现上述边界。不要为了接入 Baton 引入新的用户体系或让 Java 服务代管模型密钥。

## 集成验收清单

先运行本地 Python fixture，再用 Java endpoint 替换同一请求序列。以下项目直接对应 `mock_server/smoke_test.py` 覆盖内容：

- [ ] Web 创建短期 pairing，discovery 绑定正确 Conversation，QR 不含 token。
- [ ] manual pairing 未 claim 前访问 Conversation 返回 `401`；扫描只产生 pending 请求；auto pairing 的第一个有效 join 原子进入 approved，仍只能通过 proof-protected claim 获得 token。
- [ ] 一个 pairing 第二次 join 返回 `409`；Web 能看见设备名。
- [ ] Web 明确批准后，错误 proof 返回 `403`，正确 proof 才能 claim。
- [ ] claim 重试返回同一 token；pairing 标记 consumed 且不接受第二台设备。
- [ ] Join 响应的 `poll_url` 为 discovery/join 同源的绝对服务对外 URL；相对 URL、跨 origin URL 以及缺少 scheme/host 的 URL 均被契约测试和 Baton iOS 拒绝。
- [ ] Web 拒绝后 status 返回 rejected，永不返回 token。
- [ ] 过期 pairing 返回 `410 pairing_expired`。
- [ ] 快照可读且带原子 `event_cursor`；最多返回最新 200 条/1 MiB 的完整消息，超限明确 `history_truncated` 而无分页 cursor；active run 存在时给出可选 `active_runs[{run_id,status,message_id?}]`。重复相同 `client_message_id` 不创建重复用户消息（首次 `201`、重试 `200`）。
- [ ] SSE 返回 `text/event-stream; charset=utf-8`，能收到标准 `id/event/data` 格式的 `message.created`、`run.started`、`message.delta`、`message.completed`、`message.content.appended`、`run.completed`；使用 snapshot 的 `Last-Event-ID` 只恢复连续后续事件，未知/过期 cursor 只收到 `conversation.resync` 而非从头重复；客户端遇到 sequence gap 会取新 snapshot。
- [ ] `media_id` 在 snapshot、SSE replay 和后续 snapshot 中不变；append 只追加完整 image 到 completed assistant message，重复 event 不重复渲染。
- [ ] cancel 首次返回已接受，随后按“message cancelled → run.cancelled”获得唯一终态；重复取消不重复发布事件；DELETE 撤销后未来访问被拒绝。
- [ ] 有 `conversation:close` 权限的 Web 可 End；Baton 还必须在 discovery 中获得 `conversation_end: true` 才展示并调用 End。无权固定 `403 conversation_close_forbidden`。End 仅广播一条 `conversation.closed`，使所有 token/未决 pairing 失效，丢弃任何晚到的 Agent 输出；同 `Idempotency-Key` 重试不重复结束。下一段会话使用新 Conversation ID 与新事件序列。
- [ ] AG-UI V1 fixture 映射到上述 Baton 事件；未知 AG-UI 事件只进入诊断，不泄漏到 iOS wire format。
- [ ] 所有 transport、proof、token、Cookie/CSRF 和日志脱敏检查通过；若选择 HTTP，已确认可信网络与 Baton 的未加密提示；LM Studio key 不出现在代码、文档、请求或 iOS 包内。

## V1.1 暂缓

不因 Java 接入提前实现图片上传、相机/文件、Agent action approval（区别于网页确认设备 pairing）、Tool UI、generated UI、location、Face ID confirmation、push notification、WebSocket、账户体系或 Java SDK。除已定义的只读静态 `image` 外，能力声明可保留未来扩展键；服务和 iOS V1.1 只依赖 `text`、`markdown`、`streaming`、`image`、`content_append`、`conversation_end` 及设备端 `on_device_speech_to_text`。
