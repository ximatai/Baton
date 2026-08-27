# Baton

Baton 是一个 iOS Agent Companion：桌面 Web 与 iPhone 是同一个、由服务端拥有的 Agent Conversation 的平级客户端。它不是浏览器镜像。

用户在 Web 端展示动态二维码后，用 Baton 扫码申请加入当前会话；浏览器确认该设备后，手机可查看同一段历史、接收流式消息，并使用 iOS 本地语音转文字后发送普通文本消息。

## V1 能力

- 受浏览器确认保护的二维码配对
- 文本聊天、Markdown、流式输出、停止生成与 SSE 断线恢复
- Keychain 保存设备绑定的会话凭据和待发送消息
- 本地 Speech-to-Text：转写后可编辑再发送
- iOS 相机扫码；Simulator 可粘贴 Pairing URL
- 轻量 Python Companion Profile fixture 和 AG-UI 映射参考

暂不包含图片/文件、Tool UI、Agent action approval、Push、位置、Face ID 确认或生成式 UI。浏览器对**设备配对**的确认属于 V1 必需的安全步骤，不是 Agent action approval。

## 架构

```text
Web client ── Companion Profile server ── Baton for iOS
   full UI        conversation source of truth       voice-first client
```

服务端是 Conversation 的唯一事实源；Web 与 iOS 客户端不直接交换消息。

本仓库的 iOS 代码采用轻量的 Feature + Core 结构：

```text
Baton/
  App/                         根路由与当前 V1 会话协调器
  Features/
    Pairing/                   扫码、粘贴 URL、网页确认等待
    Conversation/              消息列表、输入与连接状态
    Speech/                    系统本地语音转文字
  Core/
    Protocol/                  Companion Profile DTO 与 HTTP/SSE client
    Conversation/              纯事件 reducer
    Persistence/               Keychain 凭据与 outbox
    Presentation/              安全 Markdown 呈现
```

详细协议见 [BATON_SPEC.md](BATON_SPEC.md)，未来 Java 服务接入见 [JAVA_INTEGRATION.md](JAVA_INTEGRATION.md)。

## 本地运行

### iOS App

用 Xcode 打开 `Baton.xcodeproj`，选择 iOS Simulator 或已配置的真机运行。

Debug 仅允许回环或 RFC1918 私有局域网地址的 HTTP，以便连接本地 fixture；Release 只接受 HTTPS。不要把此开发例外扩展到公网地址。

### Python fixture

Python fixture 只用于本地契约验证：内存单会话、无真实登录。默认生成确定性回复；仅在显式传入 OpenAI-compatible 启动参数时，才从当前进程环境读取模型密钥，密钥不会写入仓库、日志或 iOS App。

```sh
python3 mock_server/mock_server.py
python3 mock_server/smoke_test.py
```

默认地址为 `http://127.0.0.1:8787`，可被 iOS Simulator 直接访问。完整配对操作和可选 AG-UI adapter 测试见 [mock_server/README.md](mock_server/README.md)。

## 验证

```sh
# App 构建
xcodebuild -project Baton.xcodeproj -scheme Baton -sdk iphonesimulator \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO

# 单元测试（避免未配置的 UI test 阻塞本地验证）
xcodebuild -project Baton.xcodeproj -scheme Baton \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:BatonTests test CODE_SIGNING_ALLOWED=NO
```

如果本机没有名为 `iPhone 17` 的 Simulator，请在 Xcode 的目的地列表中替换为可用设备。测试覆盖 URL 解析、事件 reducer、幂等 outbox、凭据失效和安全 Markdown 边界。

## 安全与协议边界

- QR 只包含短期 discovery URL，不能包含 token、会话历史或永久凭据。
- 每次 pairing 的 `device_proof` 只保留在 iOS Keychain，并在 status claim 时通过 header 提交。
- 服务端必须对浏览器 pairing 创建/批准使用既有登录态与 CSRF 保护。
- access token、`device_proof`、Cookie 和任何模型 API Key 均不得写入代码、文档、日志或二维码。
- AG-UI 只能作为服务端 Agent 事件的可选适配层；Baton iOS wire format 仍由 Companion Profile 定义。

## 后续方向

下一阶段是使用临时 HTTPS 入口做真机扫码、网页确认、SSE 和本地语音验证。随后再根据真实的“最近服务 / 多会话”产品需求，引入相应的 session repository；不要提前加入 SwiftData、多模块、TCA 或第三方 DI 框架。
