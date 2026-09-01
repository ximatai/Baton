# Baton 维护者约定

> **受众：仓库维护者与编码 agent。** 这是内部工程约定，不是产品介绍或第三方接入文档。
> 产品定位见 `README.md`；对外协议见 `BATON_SPEC.md`；Java 服务接入见 `JAVA_INTEGRATION.md`。

## 边界

- Baton 是服务端 Conversation 的 iOS Companion，不是浏览器镜像；服务端是唯一事实源。
- V1.1 只做配对、文本/Markdown、服务端受控静态图片展示、SSE、取消/重连和本地语音转文字；不做图片/相机/文件输入。
- 协议以 `BATON_SPEC.md` 为准；Java 接入以 `JAVA_INTEGRATION.md` 为准。改 API、SSE、pairing 或凭据生命周期时同步检查这两份文档和 `mock_server/smoke_test.py`。

## 代码结构

```text
clients/ios/Baton: App → Features → Core → Apple frameworks / URLSession / Keychain
```

- `clients/ios` 是当前唯一已实现的客户端；Android 与鸿蒙目录只保留跨端接入边界，不得复制 iOS 实现或创建未使用的共享层。
- 所有客户端共同遵循根目录的 `BATON_SPEC.md`；mock fixture 仍在根目录 `mock_server/`，与任一移动端无关。

- `Core/Protocol` 是唯一网络信任边界；只在此处处理 HTTP(S)、同源、Bearer 和 SSE。
- `Core/Conversation` 是纯 reducer；不得依赖 SwiftUI、Keychain 或网络。
- 凭据与 proof 只能放 Keychain。
- QR 扫描器只返回 URL；Speech service 只负责听写；View 不直接访问 Keychain/API。
- 图片仅由 `Core/Protocol` 以同源 Bearer 请求；禁止重定向和 URLSession/URLCache 持久化。已配对 Conversation 的已确认快照与已下载媒体可按 `media_id` 存入 App 私有、文件保护且不参与备份的会话副本；移除配对、凭据失效或会话撤销时必须删除该副本。凭据、proof 与 Cookie 绝不进入该目录。
- 当前单一 `BatonViewModel` 是 V1 协调器。不要提前引入 TCA、多模块、SwiftData 或 DI 框架。

## 安全

- 不读取、打印、提交或写入 API Key、token、`device_proof`、Cookie。
- QR 不含 token；默认 manual pairing 必须经过网页确认。auto 只能由服务端策略启用；客户端不得自行跳过 proof-bound claim。
- 服务端可自行选择 HTTP 或 HTTPS；只接受绝对、同源的 HTTP(S) endpoint，绝不静默升级/降级。HTTP 必须在 UI 持续标记为未加密；服务方自行评估其网络风险。
- Markdown 不使用 WebView；HTML 或混合 HTML 按纯文本显示。

## 验证

- 使用 `apply_patch` 编辑、`rg` 搜索；移动 Swift 文件后先构建确认 filesystem-synchronized Xcode 工程已纳入它们。
- 最低要求：`git diff --check` 与 Debug build；网络配置改动还要跑 Release build。
- 修改 reducer、配对、网络或持久化时运行 `BatonTests`；修改 Python fixture 时运行 smoke test。
- mock server 仅是轻量测试 fixture，不要做成生产后端。
