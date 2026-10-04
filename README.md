# amy

跨设备局域网文件传输（LocalSend/AirDrop 风格），Flutter 实现，目标 macOS / iOS / Android。

每台设备同时跑一个 HTTP 服务端（`47777+`），用聊天式会话界面互发文件；
发现走 bonsoir (mDNS) + 子网扫描 + 6 位代码/扫码手动配对。

## 功能

- 附近设备实时发现与在线状态
- 会话式文件收发：发出 → 对方「接受/拒绝」→ 逐文件进度 → 完成后可打开
- 取消（双向同步状态）、历史持久化、记住设备
- 计划发送：定时发出，或等设备上线自动发出（重启不丢）
- Agent 接入：loopback-only HTTP API + `amy_cli` + MCP server（见下）

## 开发

```bash
flutter pub get
flutter run -d macos        # 或 -d <iOS 设备/模拟器>
flutter test && flutter analyze
```

协议/结构：`lib/core/`（protocol、models、discovery、server、engine、
agent_api、files、store、identity），UI 在 `lib/app/`，状态在 `lib/state/`。

## Agent 集成

app 运行时暴露仅 loopback 的 `http://127.0.0.1:<port>/api/v1/agent/*`：

```bash
dart run bin/amy_cli.dart peers
dart run bin/amy_cli.dart send "iPhone 17" ./file.zip
dart run bin/amy_mcp.dart        # stdio MCP server（2025-06-18 协议）
```

详见 [docs/agent-integration.md](docs/agent-integration.md)。

## 平台说明

- macOS：App Sandbox 已开 network.server / downloads / user-selected；
  接收目录 `~/Downloads/amy`。
- iOS：需 `NSLocalNetworkUsageDescription` 权限说明；接收目录在 App
  Documents/Received（Files app 可见）。最低 iOS 16。
- Android：cleartext 局域网传输 + multicast/WiFi 权限；
  接收目录在外部存储 app 专属目录。

当前为局域网明文 HTTP 传输（同一信任网段适用）；校验/加密、后台传输
续跑是后续迭代方向。
