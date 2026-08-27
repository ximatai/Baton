# Baton 开发约定

## 边界

- Baton 是服务端 Conversation 的 iOS Companion，不是浏览器镜像；服务端是唯一事实源。
- V1 只做配对、文本/Markdown、SSE、取消/重连和本地语音转文字。
- 协议以 `BATON_SPEC.md` 为准；Java 接入以 `JAVA_INTEGRATION.md` 为准。改 API、SSE、pairing 或凭据生命周期时同步检查这两份文档和 `mock_server/smoke_test.py`。

## 代码结构

```text
App → Features → Core → Apple frameworks / URLSession / Keychain
```

- `Core/Protocol` 是唯一网络信任边界；只在此处处理 HTTPS、同源、Bearer 和 SSE。
- `Core/Conversation` 是纯 reducer；不得依赖 SwiftUI、Keychain 或网络。
- 凭据、proof、outbox 只能放 Keychain。
- QR 扫描器只返回 URL；Speech service 只负责听写；View 不直接访问 Keychain/API。
- 当前单一 `BatonViewModel` 是 V1 协调器。不要提前引入 TCA、多模块、SwiftData 或 DI 框架。

## 安全

- 不读取、打印、提交或写入 API Key、token、`device_proof`、Cookie。
- QR 不含 token；扫码不等于授权，必须经过网页确认。
- Release 仅 HTTPS；HTTP 只允许 Debug 的回环或私有局域网 fixture。
- Markdown 不使用 WebView；HTML 或混合 HTML 按纯文本显示。

## 验证

- 使用 `apply_patch` 编辑、`rg` 搜索；移动 Swift 文件后先构建确认 filesystem-synchronized Xcode 工程已纳入它们。
- 最低要求：`git diff --check` 与 Debug build；网络配置改动还要跑 Release build。
- 修改 reducer、配对、网络或持久化时运行 `BatonTests`；修改 Python fixture 时运行 smoke test。
- mock server 仅是轻量测试 fixture，不要做成生产后端。
