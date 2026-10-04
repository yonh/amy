# Agent 接入 amy

运行中的 amy 暴露一个**仅 loopback** 的 Agent API（`http://127.0.0.1:<port>/api/v1/agent/*`，
非本机来源一律 403）。端口写入 `~/.amy/endpoint.json`，两个客户端都会先读它、再探测 47777+。

| 端点 | 说明 |
| --- | --- |
| `GET /identity` | 本机指纹/别名/端口/接收目录 |
| `GET /peers` | 已知设备 + 在线状态 |
| `POST /stage?name=` | 推送文件字节 → 返回 app 内暂存路径（沙盒安全） |
| `POST /send` `{peer, paths}` | 立即发送（对方在线；接收仍需对方接受） |
| `GET /message?id=` | 传输状态/进度 |
| `GET /offers` / `POST /answer?id=&accept=` | 待确认的传入文件 / 接受或拒绝 |
| `GET` `POST` `DELETE /plans` | 计划发送列表 / 新建 / 取消 |

> macOS 沙盒下 app 读不到任意路径——所以 CLI/MCP 一律先经 `/stage` 把字节
> 推进 app 暂存目录再按路径引用。直接给 `send` 传本机路径在非沙盒平台也可行。

## CLI（skill + 命令行方式）

```bash
dart run bin/amy_cli.dart peers                       # 列设备
dart run bin/amy_cli.dart send "iPhone 17" file.zip   # 发送并等结果
dart run bin/amy_cli.dart plan "iPhone 17" file.zip   # 计划：对方上线即发
dart run bin/amy_cli.dart plan "iPhone 17" f.zip --at 2026-10-05T09:00:00
dart run bin/amy_cli.dart plans                      # 计划列表
dart run bin/amy_cli.dart offers                     # 待确认的传入
dart run bin/amy_cli.dart answer <id> accept         # 代用户接受
```

## MCP server（stdio，协议 2025-06-18）

启动：`dart run bin/amy_mcp.dart`

客户端配置（Claude Desktop / Cursor / Devin 同理）：

```json
{
  "mcpServers": {
    "amy": {
      "command": "dart",
      "args": ["run", "/path/to/amy/bin/amy_mcp.dart"]
    }
  }
}
```

工具：`amy_list_peers`、`amy_send_file`、`amy_plan_send`、`amy_transfer_status`、
`amy_list_plans`、`amy_cancel_plan`、`amy_list_offers`、`amy_answer_offer`。

> 发送是"请求-接受"语义：`send_file`/`plan_send` 发出后，接收端仍需点「接受」
> （或另一头 agent 调 `amy_answer_offer`）。这是有意设计：任何文件落盘前都经人确认。
