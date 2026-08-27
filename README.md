# Baton

**把桌面上的 Agent 对话，接力到你的 iPhone。**

Baton 是一个通用的 iOS Agent Companion。它让用户不离开正在使用的 Web 应用，也能用手机加入同一段 Agent Conversation：桌面继续承担复杂业务、文档、数据与工作区；手机则成为随手可用、更适合语音输入的对话端。

它不是浏览器镜像，也不绑定某一家模型、Agent 框架或业务系统。

```text
Web 应用 ── Baton Companion Profile 服务端 ── Baton iPhone App
完整业务界面          同一段会话的唯一事实源              语音优先的随身客户端
```

## 它解决什么问题

许多 AI 应用最适合在电脑上完成工作：看表格、操作业务系统、阅读文档、管理复杂任务。但在聊天框里持续打字并不总是最高效，尤其是思考、补充背景或快速追问的时候。

Baton 将这两种设备各自擅长的部分组合起来：

- 在 Web 保留完整的产品能力与当前业务上下文；
- 用 iPhone 扫描二维码，加入**当前这段**对话；
- 在手机上本地语音转文字、编辑后发送；
- 两端实时看到同一份历史、流式回复和会话状态；
- 任一端结束会话，所有已加入设备都会安全退出。

用户获得的是更自然的输入方式；接入 Baton 的 Web 产品则不必为移动端重新实现整套业务 UI 或把模型密钥交给 App。

## 使用体验

1. 用户在支持 Baton 的 Web 页面点击“接力到手机”。
2. 页面生成一次性的动态二维码。
3. 用户用 Baton 扫码，Web 页面确认这台设备。
4. 手机立即进入该 Conversation，可语音输入或文本输入。
5. Web 与手机作为平级客户端持续同步；服务端始终拥有会话事实。

扫码本身不等于授权。二维码只包含短期发现地址，最终加入必须由原 Web 会话确认，适合把手机接入已有的企业 Web、Agent Workspace 或内部系统。

## 当前能力

- 动态二维码配对与网页确认
- 同一会话的文本聊天、Markdown 与流式回复
- 停止生成、断线恢复与跨端结束会话
- iOS 相机扫码；Simulator 支持粘贴配对地址
- iOS 本地 Speech-to-Text：转写后可编辑，再作为普通文本发送

当前刻意不做图片/文件、Tool UI、Agent action approval、推送、位置与生成式 UI。Baton 的核心是先把“跨设备接力同一段对话”做到可靠。

## 面向接入方

任何已有 Web/Agent 服务都可以接入 Baton，而无需采用特定模型或 Agent 框架。服务端负责既有登录、权限、Conversation、Agent 运行时和事件日志；Baton 只定义：

- 服务发现与二维码配对
- 设备确认与会话级凭据
- Conversation 快照、消息、SSE 与恢复
- 设备撤销和共享会话结束

协议详见 [BATON_SPEC.md](BATON_SPEC.md)，Java Web 服务接入说明见 [JAVA_INTEGRATION.md](JAVA_INTEGRATION.md)。AG-UI 可以在服务端作为可选适配层使用，但不会成为 iOS 的对外传输协议。

### 文档导航

| 如果你想… | 请阅读 |
| --- | --- |
| 了解 Baton 的产品定位与体验 | 本 README |
| 实现任意服务端或客户端的协议互通 | [BATON_SPEC.md](BATON_SPEC.md) |
| 将 Baton 接入现有 Java Web/Agent 服务 | [JAVA_INTEGRATION.md](JAVA_INTEGRATION.md) |
| 在本地体验或调试 fixture | [mock_server/README.md](mock_server/README.md) |

## 快速体验

仓库附带了一个轻量的 Python fixture，用来体验完整的 Web ↔ iPhone 接力流程；它不是生产后端。

```sh
python3 mock_server/mock_server.py
```

然后在浏览器打开 [http://127.0.0.1:8787/](http://127.0.0.1:8787/)。页面可生成二维码、确认手机并作为另一端聊天客户端。iOS Simulator 可直接连接；真机局域网体验、可选 OpenAI-compatible 模型回复和 fixture 细节见 [mock_server/README.md](mock_server/README.md)。

用 Xcode 打开 `Baton.xcodeproj` 后，即可在 Simulator 或已配置的真机运行。Debug 仅为本地开发放行回环与私有局域网 HTTP；正式部署必须使用 HTTPS。

## 安全原则

- 服务端是 Conversation 的唯一事实源，Web 与 iPhone 不直接交换消息。
- QR 不包含 token、历史或永久凭据；设备加入由 Web 明确确认。
- 会话凭据与待发送消息仅保存在 iOS Keychain。
- 语音音频仅在 iPhone 本地识别；只有用户编辑后的文本会发送给服务端。
- 模型 API Key、Cookie、token 和 `device_proof` 不进入 App、二维码、代码或日志。
