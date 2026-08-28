# Baton Clients

每个客户端都是同一服务端 Conversation 的平级客户端，遵循仓库根目录的
[`BATON_SPEC.md`](../BATON_SPEC.md)。客户端不承载业务权限、Conversation
事实或模型密钥。

| 平台 | 状态 | 入口 |
| --- | --- | --- |
| iOS | 已实现 | [`ios/`](ios/) |
| Android | 预留 | [`android/`](android/) |
| HarmonyOS | 预留 | [`harmony/`](harmony/) |

新增平台时，应先实现协议发现、配对、会话凭据、快照、SSE 和文本消息主链路；
平台能力（例如本地语音转文字）放在各自目录内，不抽象成未经验证的跨端共享层。
