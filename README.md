# Baton

[中文](README.md) · [English](README.en.md)

**让任何已有的 Web Agent 系统，多一个可语音输入的 iPhone 客户端。**

## 从一个真实场景开始

越来越多的网站、企业应用和 Agent Workspace 都提供了 Agent 对话窗口。
但电脑打字并不总是最方便：当你想补充背景、连续追问或边走边说时，手机语音
通常更自然。与此同时，为每一个 Agent 服务开发或安装一个独立 App，又成本高、
重复，并且容易让会话上下文分裂。

Baton 通过一组标准化的 **Companion Profile** 协议解决这个问题。只要服务
提供者接入协议，并在当前 Web 会话展示二维码，用户就能使用同一款 Baton App
加入不同 Agent 服务中的当前对话。

它解决的不是“把 Web 缩小到手机”，而是：**让手机安全加入桌面上已经在进行的
那段 Agent 对话，成为更自然的语音输入端。** Baton 不是新的 Agent 后端、
不是统一中间平台，也不替代现有 Web 产品。

接入 Baton 后，原有系统仍然拥有用户、权限、业务数据、Conversation、Agent 和
模型调用；它只需要在自身服务端实现一小组 Baton endpoint，并在当前 Web 会话中
展示二维码。Baton App 扫码后成为这段 Conversation 的第二个客户端：消息实时
同步，网页原有的业务界面与功能不受影响。

这带来三个直接优势：

- **保留现有投入**：不替换 Web、Agent、模型或权限体系，也不重做完整移动端；
- **不丢上下文**：Web 与 iPhone 看到的是服务端拥有的同一段 Conversation；
- **发挥设备所长**：电脑继续做复杂工作，iPhone 用本地语音转文字完成高频输入。

```text
                     你的既有 Web / Agent 服务
┌───────────────────────────────────────────────────────────────┐
│ 登录与权限 · 业务数据 · Conversation · Agent · 模型 / Tools     │
│                                                               │
│ Web UI ── 配对二维码 / Baton Companion Profile ── 事件日志     │
└───────────────────────┬───────────────────────────────────────┘
                        │ 同一服务端、同一段会话
              ┌─────────┴─────────┐
              ▼                   ▼
          原有 Web 客户端       Baton iPhone App
          完整业务工作台        语音优先的随身输入端
```

换句话说：**Baton 不搬走系统，也不复制系统；它把已有系统中“当前正在进行的
Agent 对话”安全地接力到手机。** 服务端仍是唯一事实源，Web 与 iPhone 是
平级客户端，彼此不直接传递消息。

### Baton 不做什么

- 不托管你的用户、业务数据、Conversation 或模型 API Key；
- 不要求替换现有 Agent 框架、模型供应商或 Web 技术栈；
- 不镜像浏览器画面，也不试图在手机重建完整的业务 UI；
- 不充当 Web 与手机之间的第三方消息中继服务。

## 使用流程

1. 用户在支持 Baton 的 Web 页面打开一段 Agent 对话并展示二维码。
2. 用户用 Baton 扫码，申请加入**当前这段** Conversation。
3. 默认由网页确认设备；受控场景可由服务端选择自动批准。
4. 手机进入同一段对话，可本地语音转文字、编辑并发送。
5. Web 与手机作为平级客户端持续同步；服务端始终拥有会话事实。

扫码本身不等于授权。二维码只包含短期发现地址；无论采用网页确认还是服务端自动批准，手机都必须用本机 `device_proof` 领取会话凭据。这样既能把手机接入已有的企业 Web、Agent Workspace 或内部系统，又不会把模型密钥交给 App。

## 当前能力

- 动态二维码配对；默认网页确认，服务端可选自动批准
- 保存并切换多个已加入会话；列表可探测会话可用状态
- 同一会话的文本聊天、Markdown 与流式回复
- 停止生成、断线恢复与共享会话结束
- iOS 相机扫码；Simulator 的 Debug 版本支持本地演示服务
- iOS 本地 Speech-to-Text：转写后可编辑，再作为普通文本发送

当前刻意不做图片/文件、Tool UI、Agent action approval、推送、位置与生成式 UI。Baton 的核心是先把“跨设备接力同一段对话”做到可靠。

## 将 Baton 接入已有系统

接入不是把业务系统迁移到 Baton，而是在现有服务上增加一个窄的“第二客户端
接入层”。职责边界如下：

| 既有 Web / Agent 服务继续负责 | Baton 提供 |
| --- | --- |
| 登录、SSO、用户与业务权限 | iOS Companion App 与扫码体验 |
| 业务数据、页面、工作区和工具 UI | 一次性设备接入与本地语音转文字 |
| Conversation、消息持久化、Agent run 与模型调用 | 会话快照、SSE、凭据与恢复的互操作契约 |
| 哪个用户可加入、撤销或结束会话 | 对等客户端的消息展示和文本发送 |

因此，一个已有 Java Web、Node 服务或任意 Agent runtime 的产品，不必接入
新的模型网关或改造完整移动端，只需把自己的 Conversation 映射到 Baton 的：

- 服务发现与二维码配对；
- 设备确认与会话级凭据；
- Conversation 快照、消息、SSE 与恢复；
- 设备撤销和共享会话结束。

协议详见 [BATON_SPEC.md](BATON_SPEC.md)，Java Web 服务接入说明见 [JAVA_INTEGRATION.md](JAVA_INTEGRATION.md)。AG-UI 可以在服务端作为可选适配层使用，但不会成为 iOS 的对外传输协议。

### 文档导航

| 如果你想… | 请阅读 |
| --- | --- |
| 了解 Baton 的产品定位与体验 | 本 README |
| 实现任意服务端或客户端的协议互通 | [BATON_SPEC.md](BATON_SPEC.md) |
| 将 Baton 接入现有 Java Web/Agent 服务 | [JAVA_INTEGRATION.md](JAVA_INTEGRATION.md) |
| 在本地体验或调试 fixture | [mock_server/README.md](mock_server/README.md) |
| 了解各客户端的仓库边界 | [clients/README.md](clients/README.md) |

## 快速体验

仓库附带了一个轻量的 Python fixture，用来体验完整的 Web ↔ iPhone 接力流程；它不是生产后端。

```sh
python3 mock_server/mock_server.py
```

然后在浏览器打开 [http://127.0.0.1:8787/](http://127.0.0.1:8787/)。页面可生成二维码、确认手机并作为另一端聊天客户端。真机局域网体验、Simulator 的 Debug 演示连接、可选 OpenAI-compatible 模型回复和 fixture 细节见 [mock_server/README.md](mock_server/README.md)。

用 Xcode 打开 `clients/ios/Baton.xcodeproj` 后，即可在 Simulator 或已配置的真机运行。扫码需要真机相机；Simulator 的 Debug 版本保留了本地演示连接入口。Baton 跟随接入服务的 HTTP 或 HTTPS origin；HTTP 会在 App 内持续标记为“未加密”，适合服务方认可风险的内网或遗留部署。HTTPS 仍是面向互联网或不受控网络的强烈建议，而不是接入 Baton 的前置改造条件。

## 安全原则

- 服务端是 Conversation 的唯一事实源，Web 与 iPhone 不直接交换消息。
- QR 不包含 token、历史或永久凭据；设备加入默认由 Web 确认，自动批准只能由服务端在受控场景启用。
- 会话凭据与待发送消息仅保存在 iOS Keychain。
- 语音音频仅在 iPhone 本地识别；只有用户编辑后的文本会发送给服务端。
- 模型 API Key、Cookie、token 和 `device_proof` 不进入 App、二维码、代码或日志。
- HTTP 可用于兼容既有服务，但不能提供传输保密性或完整性；Baton 会明确提示，网络边界仍由服务部署方负责。

## 开源许可

Baton 采用 [MIT License](LICENSE) 开源。
