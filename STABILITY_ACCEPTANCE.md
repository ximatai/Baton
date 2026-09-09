# Baton 稳定性验收清单

> **用途：** 用于每次准备交付或合并涉及会话、配对、缓存、媒体、语音的改动时，执行可重复的自动检查与小范围真机回归。它不替代协议测试；协议变更仍须同步检查 `BATON_SPEC.md`、`JAVA_INTEGRATION.md` 与 `mock_server/smoke_test.py`。

## 当前收口范围

- 多会话列表、置顶、重命名与断开本机访问；
- 认证 snapshot/SSE、发送、取消和会话结束；
- 已配对会话的本地文本/图片副本、离线阅读与删除；
- 语音转文字的长按、取消、编辑与离线禁用；
- 手动配对、自动批准配对和审核演示二维码流程。
- V1.3 相册静态图片选择、草稿缩略图/消息预览、同源暂存上传、`image_ref` 原子提交、取消与显式幂等重试。

## 自动验收

在仓库根目录执行：

```sh
git diff --check
xcodebuild -project clients/ios/Baton.xcodeproj -scheme Baton -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:BatonTests test
xcodebuild -project clients/ios/Baton.xcodeproj -scheme Baton -configuration Debug -destination 'generic/platform=iOS Simulator' build
xcodebuild -project clients/ios/Baton.xcodeproj -scheme Baton -configuration Release -destination 'generic/platform=iOS Simulator' build
python3 mock_server/media_unit_test.py
```

Mock Server 有改动时，以独立终端启动服务后执行：

```sh
python3 mock_server/mock_server.py --review-demo-token local-review-token-1234
BATON_REVIEW_DEMO_TOKEN=local-review-token-1234 python3 mock_server/smoke_test.py
```

另开终端安装图片 fixture 的依赖并启动 V1.3 服务，再运行媒体回归：

```sh
python3 -m pip install -r mock_server/requirements-media.txt
python3 mock_server/mock_server.py --port 8788 --vision
python3 mock_server/media_smoke_test.py http://127.0.0.1:8788
```

自动验收必须通过；不以 UI 测试替代下列真机检查。

## 真机回归

每项记录“通过 / 不通过 / 未测”和复现环境。任何“不通过”都应记录会话状态、网络状态、操作路径和是否可稳定复现；不要记录 token、`device_proof` 或真实消息正文。

| 场景 | 操作 | 通过标准 |
| --- | --- | --- |
| 手动配对 | 扫码、网页批准、进入会话 | 只在批准后保存凭据；取消不会留下可用本地会话 |
| 自动配对/审核演示 | 扫码一次后等待领取，并观察网页生成下一码 | 已扫码设备仍能进入原会话；新二维码不替换已扫码设备的凭据 |
| 会话重入与媒体 | 有两张图片的会话连续执行三次“进入 → 返回列表 → 再进入” | 图片持续可见；不显示“图片无法加载”；服务端无媒体 401/404/5xx |
| 滚动媒体 | 在含多图消息内上下滚动并打开任意图片预览 | 已展示图片不重复加载；缩略图受最大高度约束；预览可横滑同消息图片 |
| 离线阅读 | 已同步后断网、杀掉 App、重新打开同一会话 | 已确认文本与已下载图片可读；编辑区明确不可发送 |
| 恢复在线 | 离线阅读后恢复网络并重新进入会话 | 最新认证 snapshot 覆盖本地副本；不重复消息、不丢失媒体 |
| 移除本机访问 | 在可用和服务端不可用两种状态下从列表移除会话 | 仅删除该会话的 Keychain 凭据与本地副本；其他会话不受影响 |
| 多会话排序 | 至少三段会话，分别置顶、发送/接收消息、返回列表 | 置顶稳定在顶部；只有实际消息交互改变最近顺序；返回列表不触发重排或闪烁 |
| 发送与取消 | 发送一条消息，在服务端流式回复中取消 | 不重复提交；取消后状态收敛；后续重连不复活已取消 run |
| 相册图片输入 | 服务声明 `image_upload` 后选择单图、多图，分别发送图文和纯图；发送前移除或取消草稿，并模拟响应丢失后的显式重试 | 草稿显示缩略图；已提交消息和预览正确显示；上传仅发生在显式发送时并以同源 `image_ref` 提交；取消不留下待发图片；重试不产生重复媒体或消息 |
| 图片后台与保护 | 选图、发送及移除会话后分别切到后台再返回；检查 App 私有临时目录和会话副本 | 未提交图片在发送完成、移除、凭据失效或会话撤销后清理；文件保护与不备份策略符合约定。Simulator 无法暴露完整 `NSFileProtection` 属性，本项必须标记为“跳过”，改由真机确认 |
| 语音输入 | 键盘已弹出时长按输入框，分别松开与上滑取消 | 键盘不因长按主动收起；松开结果可编辑且不自动发送；取消恢复长按前文本 |
| 断开/结束 | 服务端声明可结束与不声明可结束的各一段会话 | 列表不显示“结束”；详情仅在服务端声明时显示；断开提示定位正确且内容简洁 |

## 收口出口条件

1. 自动验收全部通过；
2. 上表中与本次改动相关的真机场景均通过；
3. 不存在已知可稳定复现的崩溃、凭据残留、跨会话数据展示或媒体回放失败；
4. 新增诊断日志、临时开关和测试素材已删除或明确仅限 Debug；
5. `FEATURE_ROADMAP.md` 的状态与本次验收证据一致。

## 当前证据与本次待验项（2026-09-08）

- 完整 `BatonTests`：70 passed / 1 skipped（Simulator `NSFileProtection`）/ 0 failed；定向图片测试：10 passed / 1 skipped / 0 failed。两者分别统计，不合并为一个总数。
- iOS Debug 与 Release build：通过；
- 干净独立 V1.2 fixture 的原 `smoke_test.py`：通过，覆盖审核演示二维码轮换与已扫码设备领取凭据；此前复用脏 Store 的失败已排除，不计入本次结果。
- `media_unit_test.py` 与 `media_smoke_test.py`：通过；
- MR 图片回放：真机已验证“进入 → 返回列表 → 再进入”持续可见；
- 未覆盖项：审核演示的 iPhone 真机扫码与多会话全量回归，留待下一轮交付前执行。
- `vision_lm_integration_test.py`：当前版本以 LM Studio `qwen3.8-27b` 通过真实配对、图片暂存/原子提交、web resolver 无设备凭据读取且字节相等，以及模型识别红/蓝和同图数字 `3`/`8` 追问。fixture 上游响应仍为非流式，仅将完成结果转换为 Baton 增量事件；最近 8 条、32,000 字符和 16 MiB 是资源预算，不是模型 token 预算。
- 临时环境注入的 Swift `LiveFixtureIntegrationTests`：通过真实 `BatonAPIClient` 配对、上传、发送与 snapshot，1 passed / 0 skipped；日志显示 `TEST EXECUTE SUCCEEDED`。两项均为 opt-in 本地检查，不记录凭据或模型回复正文。
- 真机相册、后台切换和 `NSFileProtection` 属性仍待验；Simulator 对完整文件保护属性测试明确跳过。尚未发布或提交。
