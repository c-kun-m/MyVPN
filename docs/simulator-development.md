# 模拟器开发与验证

本轮交付对应计划前四步：拆分系统依赖、模拟器模式、基础界面、自动化验证。真实 iPhone、开发者签名和服务器验收仍按 `phase1-validation.md` 执行。

## 运行模式

| 构建目标 | 实现与数据 |
| --- | --- |
| iOS Simulator + Debug | 自动使用模拟后端；所有页面显示模拟标识；身份、配置和诊断只保存在当前进程内存中 |
| iPhone + Debug / Release | 使用系统 VPN、Keychain 与 App Group；不包含模拟后端类型，不因系统操作失败而切换为模拟连接 |
| iOS Simulator + Release | 使用真实系统接口，不提供模拟模式；不作为 VPN 运行验收环境 |

模拟模式不会创建系统 VPN 配置、改变路由、读取真实 Keychain 或连接示例服务器。实验公钥不能用于部署；退出进程后实验身份与配置清除。它与真实模式共用配置校验、连接控制器和 SwiftUI 界面。

Apple 关于 Network Extension 在模拟器上的限制及替代测试方式：[Apple Developer Forums](https://developer.apple.com/forums/thread/46004)。模拟测试不能证明 VPN 实际连通、密钥共享权限或无泄漏。

## 在 Mac 上操作

选择 NPV scheme、Debug 和 `NPV Validation` 模拟器运行 App。默认场景是正常连接。

1. 在“配置”页面生成实验身份，点击“添加服务器”。
2. 点击“填入模拟示例”，或手动填写合法配置；保存。
3. 在“连接”页面点击“模拟连接”，观察状态与统计；点击“断开连接”。
4. “诊断”页面保留本次运行最近 30 条操作类型与时间，不保存配置、密钥或业务内容。
5. 首页“开发场景”可选择正常连接、连接超时、启动失败、保存被拒绝、密钥不可读取、启动但无握手、连接后恢复。切换前先断开。

连接超时沿用真实控制器的 30 秒等待期限，断开确认期限是 10 秒。恢复场景模拟系统状态，未实现新的自动重连策略。统计每 3 秒刷新；App 退到后台会清除显示的采样并丢弃旧回复。

## 通过 SSH 自动验证

在 Mac 项目目录执行：

```sh
export PATH="/usr/local/go/bin:$PATH"
python3 scripts/bootstrap.py
bash scripts/check_simulator.sh
```

默认选择唯一名为 `NPV Validation` 的可用模拟器；也可明确指定已有设备：

```sh
xcrun simctl list devices available
NPV_SIMULATOR_UDID=4E8084CB-DDA8-4206-83C7-6CCE1A19FFB6 bash scripts/check_simulator.sh
```

脚本使用当前已安装的平台与固定依赖，不安装新运行包。它会执行核心、Python、Apple 身份、控制器和 UI 测试，导出截图附件，再构建 iOS Debug / Release，并检查 Release App 符号中没有模拟后端。每次输出到新的 `artifacts/simulator-时间.随机后缀/`，包含 `.xcresult`、日志、截图及二进制检查结果。脚本启动的模拟器会在结束时关闭，原本已启动的模拟器保持启动。

如果只运行部分检查，可以使用 Xcode 的测试筛选参数。真机 `NetworkPathTests` 不在此入口的选择范围内，不能因此记为通过。

SSH 可以执行这些操作和获取截图；手动点击模拟器需要访问 Mac 的图形桌面。

## 实现边界

- `TunnelServices.swift`：VPN、身份、诊断存储接口，以及可替换的超时调度器。
- `SystemTunnelBackend.swift`：系统 VPN 配置、状态通知、启动／停止及有界统计请求。
- `SimulatedServices.swift`：仅在 Debug 模拟器编译的实验后端，取消操作会取消延迟任务并使旧回调失效。
- `AppServices.swift`：按编译目标组装实现，真实操作失败不会回退为模拟实现。
- `TunnelController.swift`：两种模式共用的门禁、状态、身份检查、配置复核、超时和统计过期处理。
- `ControllerTests.swift`：通过可控时钟和替代系统接口验证操作竞态、失败与数据隔离。
- `SimulatorFlowTests.swift`：真实启动 App，操作生成身份、配置、编辑、连接／取消及错误流程；截图保存在测试结果内。

实际测试次数与构建结果以 `test-report.md` 为准。尚未完成的真机联网、安全、性能及发布验收继续单独记录。
