# 第一阶段测试记录

更新日期：2026-10-26（Asia/Shanghai）。状态：**Mac 上 57 项自动化测试通过；iOS 编译被缺失的平台组件阻塞，第一阶段整体验收未完成。**

## 实际环境

- 工作区：`D:\project\npv`，Windows / PowerShell。
- Mac 已通过 SSH 接通：Apple Silicon / macOS 15.6，Xcode 26.3（17C529），Apple Swift 6.2.4，Python 3.9.6。
- `xcodebuild -showsdks` 能列出 iOS 26.2 SDK，但真正构建时目标不可用：`iOS 26.2 is not installed`。SDK 列表不能作为平台组件已完整安装的证明。
- 已安装官方 Go 1.27.3 darwin/arm64，路径 `/usr/local/go`；安装包 SHA-256 与官方记录一致，Google 安装器签名及 Apple 公证校验通过。
- 当前 SSH 会话未发现有效代码签名身份；测试 iPhone 与已授权远端网关尚未确认。
- WSL Ubuntu 22.04，Swift 6.0.3 Linux x86_64 工具链。
- 工具链来自 swift.org，验证了官方 Swift 6.x 发布签名，指纹 `52BB7E3DE28A71BE22EC05FFEF80A866B47A981F`。
- Python 3.12，openstep-parser 2.0.3；Docker 中既有 Go 1.22 镜像只用于源码布局检查。
- 曾尝试拉取 Swift Docker 镜像，下载迟缓后停止；实际 Swift 测试通过已验证签名的 WSL 工具链完成。

## 已执行且通过

| 检查 | 结果 | 能证明的范围 |
| --- | --- | --- |
| `swift test --enable-code-coverage` | Mac 39 项测试，0 失败；此前 Linux 同样通过 | 配置和 endpoint 校验、双栈地址输入边界、IPC 版本/大小、统计去密、操作门禁、连接请求竞态和超时 |
| Apple Swift 源码 `swiftc -frontend -parse` | 通过 | 语法正确；没有 Apple SDK 类型检查和链接 |
| 实际 `.pbxproj` 独立解析与结构检查 | Windows openstep-parser 和 Mac plutil 均通过，76 个对象 | 源文件存在、三个 target、扩展嵌入、测试 host、scheme、权限/Info 一致性、依赖锁定 |
| `python -m unittest discover -s lab` | Mac 9 项测试，0 失败 | fixture 的 DNS/EDNS、拒绝递归、输入限制及本机 TCP/UDP/DNS 的 IPv4/IPv6 socket 行为 |
| `python -m unittest discover -s scripts` | Mac 和 Windows 各 9 项测试，0 失败 | 6 项私有 Go runtime 测试，以及 3 项依赖清单修正、篡改拒绝和固定提交校验测试 |
| Go 1.22 runtime 源码布局检查 | 通过 | 连续时钟转换的三个精确符号位置可识别；不代表当前 Mac Go/iOS bridge 已编译 |
| Mac Go 1.27.3 编译运行检查及 runtime 布局检查 | 通过 | Go 可以编译运行简单程序，连续时钟符号布局可识别；尚未完成 iOS Go bridge 编译链接 |
| Python 编译、Shell 语法 | 通过 | 本机构建辅助脚本基础语法 |

2026-10-26 在 Mac 上合计 **57 项实际执行的自动化测试通过**（39 Swift + 9 fixture + 9 构建工具）；Go 编译运行、结构和语法检查另计。此前 Windows/WSL 的 54 项通过记录仍有效，不与 Mac 重复运行次数相加。
Mac 原始输出保存在项目 `artifacts/` 下的 `swift-tests-macos.log`、`fixture-tests-macos.log`、`build-tool-tests-macos.log`、`go-smoke.log` 和 `ios-build.log`。Windows/WSL 历史输出为 `artifacts/core-tests.log`。日志目录不提交 Git。

## 发现并修正

- 原始 WireGuard 上游 Go 时钟 diff 无法应用到已安装的 Go 1.22 源码；新增只在私有 GOROOT 副本中应用同等符号转换的准备器，未知布局失败退出。
- 原始 UAPI 运行配置可能含私钥；客户端只提取数值统计，测试验证序列化结果不含密钥和 endpoint。
- 停止清理错误可能覆盖真正的启动失败；现保留原始启动错误。
- DNS fixture 需兼容系统解析器的 EDNS 查询；已增加有界 OPT 解析和回归测试。
- 构建阶段显式调用 `/bin/bash`，避免 Windows 创建的脚本没有 Unix executable 位而导致构建失败。
- 连接请求发出后系统可能仍短暂报告未连接；独立跟踪请求，防止提前取消超时或重复启动。新增 8 项核心回归测试，覆盖启动、取消、停止和过期回调。
- 超时取消直接请求系统停止，不受界面当前状态限制；不会将超时本身伪装为系统已断开。该 Apple API 行为仍待真机验证。
- 连接前重新读取系统保存的配置，并检查身份；配置改变时要求先核对。丢弃状态切换前发出的过期统计回复。这两项 Apple 控制器改动目前仅通过语法检查。
- 官方 Go 安装路径没有出现在非交互 SSH 的 PATH 中；构建脚本显式包含 `/usr/local/go/bin`。
- Mac 自带 Python 3.9 无法安装需要 Python 3.10+ 的 openstep-parser 2.0.3；Mac 结构检查改用系统 `plutil`，已实际通过。
- 固定 WireGuard 清单声明 Swift tools 5.3，却使用 5.5 才引入的平台常量；仅修正声明为 5.5，并对完整清单和其余依赖改动进行校验。Xcode 的 Swift 包解析现已通过。

## 尚未执行，不能计为通过

| 项目 | 原因／下一步 |
| --- | --- |
| Xcode iOS SDK 全量编译和 Go bridge 链接 | 已尝试，退出码 70：目标报告缺少 iOS 26.2 平台组件；待补装后重跑 `bash scripts/check_macos.sh` |
| 真机签名、VPN 授权、App Group 与 Keychain | 需要开发者签名及真实 iPhone |
| 2 项 Apple 身份测试 | 已编写，尚未在 Apple SDK 下编译运行 |
| 6 项 iPhone DNS/TCP/UDP/IPv4/IPv6 测试 | 已编写且默认禁用；需要真实隧道和受控网关 fixture |
| 网关外部转发、错误密钥、设备撤销 | 需要已授权的测试服务器与真实手机 |
| 真实外侧抓包与 DNS/IPv6 泄漏验证 | 需要可观察的测试网络；本机 loopback 测试不能替代 |
| UI 渲染、锁屏、网络切换、耗电 | 需要真实 iOS 环境 |
| 上游依赖漏洞评估与工业级发布认证 | 不属于已通过结果；旧上游依赖必须在正式发布前复核 |

2026-10-26：Go 安装与实际编译运行通过；工程已上传 GitHub 并在 Mac 克隆。尚需补齐 Xcode 的 iOS 26.2 平台组件再尝试完整构建；签名、真实 iPhone、已授权测试网关仍是实网验收的前置条件。

第一阶段未标记完成。不能据此报告声称“iOS App 已成功构建”“真机已连通”或“工业级安全已达标”。
