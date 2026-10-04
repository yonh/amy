---
name: amy-send-file
description: 通过本机运行的 amy app 在局域网设备间发送/接收文件（列设备、立即发送、计划发送、接受传入文件）。当用户要求把文件发到另一台设备、接收文件、或管理 amy 传输时使用。
---

# amy-send-file

操作本机运行中的 amy（局域网文件传输 app）。要求 amy 正在本机运行；它把 agent API 开在 `http://127.0.0.1:<port>/api/v1/agent/*`，端口写在 `~/.amy/endpoint.json`。

## 用法

在 amy 仓库根目录执行（`dart run bin/amy_cli.dart`）：

```bash
dart run bin/amy_cli.dart peers                          # 设备列表（别名/指纹/在线）
dart run bin/amy_cli.dart send "<设备别名或指纹前缀>" <文件...>   # 立即发送并等待最终结果
dart run bin/amy_cli.dart plan "<设备>" <文件...> [--at ISO|--online]  # 计划发送
dart run bin/amy_cli.dart plans                          # 计划列表
dart run bin/amy_cli.dart unplan <id>                    # 取消计划
dart run bin/amy_cli.dart offers                         # 待确认的传入文件
dart run bin/amy_cli.dart answer <id> accept|decline     # 接受/拒绝传入
dart run bin/amy_cli.dart status <messageId>             # 查一次传输
```

## 注意

- 发送是「请求-接受」语义：发送后接收端要点「接受」；也可用 `offers` + `answer` 在接收端处理。
- 文件字节先经 `/api/v1/agent/stage` 暂存到 app 目录（macOS 沙盒无法直读任意路径），CLI 自动处理。
- 接收的文件落在 amy 的接收目录（`GET /api/v1/agent/identity` 的 `downloads` 字段）。
- 若报「找不到运行中的 amy」：先启动 amy app。
