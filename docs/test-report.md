# 第一阶段测试记录

更新日期：2026-10-26（Asia/Shanghai）。状态：**本轮模拟器开发计划前四步完成；未签名 iOS Debug / Release 构建通过，共 84 项自动化测试通过。第一阶段真机与实网验收未完成。**

## 实际环境

- 工作区：`D:\project\npv`，Windows / PowerShell。
- Mac 已通过 SSH 接通：Apple Silicon / macOS 15.6，Xcode 26.3（17C529），Apple Swift 6.2.4，Python 3.9.6。
- iOS 26.2 SDK `23C57`；已安装正式运行包 `23C54`，并为该 SDK 显式设置匹配关系。`Any iOS Device` 与 iOS 模拟器现均可用。
- Apple 身份、控制器与 UI 测试使用独立的 `NPV Validation` iPhone 17 模拟器、iOS 26.2；最终确认设备处于 Shutdown 状态。
- 已安装官方 Go 1.27.3 darwin/arm64，路径 `/usr/local/go`；安装包 SHA-256 与官方记录一致，Google 安装器签名及 Apple 公证校验通过。
- 此前签名检查未发现有效代码签名身份；测试 iPhone 与已授权远端网关尚未确认。本轮使用未签名构建。
- WSL Ubuntu 22.04，Swift 6.0.3 Linux x86_64 工具链。
- 工具链来自 swift.org，验证了官方 Swift 6.x 发布签名，指纹 `52BB7E3DE28A71BE22EC05FFEF80A866B47A981F`。
- Python 3.12，openstep-parser 2.0.3；Docker 中既有 Go 1.22 镜像只用于源码布局检查。
- 曾尝试拉取 Swift Docker 镜像，下载迟缓后停止；实际 Swift 测试通过已验证签名的 WSL 工具链完成。

## 已执行且通过

| 检查 | 结果 | 能证明的范围 |
| --- | --- | --- |
| `swift test --enable-code-coverage` | Mac 39 项测试，0 失败；此前 Linux 同样通过 | 配置和 endpoint 校验、双栈地址输入边界、IPC 版本/大小、统计去密、操作门禁、连接请求竞态和超时 |
| Apple Swift 源码 `swiftc -frontend -parse` | 历史检查通过 | 仅证明语法；本轮进一步通过完整 iOS SDK 编译，见下方 |
| 实际 `.pbxproj` 独立解析与结构检查 | Windows openstep-parser 和 Mac plutil 均通过，100 个对象 | 源文件存在、四个 target、扩展嵌入、单元/UI 测试宿主与 scheme、权限/Info 一致性、依赖锁定 |
| `python -m unittest discover -s lab` | Mac 9 项测试，0 失败 | fixture 的 DNS/EDNS、拒绝递归、输入限制及本机 TCP/UDP/DNS 的 IPv4/IPv6 socket 行为 |
| `python -m unittest discover -s scripts` | Mac 和 Windows 各 10 项测试，0 失败 | 6 项私有 Go runtime 测试，以及 4 项依赖修正、文件篡改拒绝、全量验证后写入和固定提交校验测试 |
| Go 1.22 runtime 源码布局检查 | 通过 | 连续时钟转换的三个精确符号位置可识别；不代表当前 Mac Go/iOS bridge 已编译 |
| Mac Go 1.27.3 编译运行检查及 runtime 布局检查 | 通过 | Go 可以编译运行简单程序，连续时钟符号布局可识别 |
| Xcode `generic/platform=iOS`，`CODE_SIGNING_ALLOWED=NO build` | Debug / Release 均 `BUILD SUCCEEDED` | 主 App、Packet Tunnel 扩展、WireGuardKit 和 Go bridge 的 iOS arm64 编译、链接及扩展嵌入；不包含真机签名与运行 |
| iOS 模拟器 `NPVAppleTests/IdentityTests` | `TEST SUCCEEDED`，2 项测试，0 失败 | CryptoKit Curve25519 公钥符合 RFC 7748 向量，异常长度私钥被拒绝；未验证真实 Keychain 共享或隧道 |
| iOS 模拟器 `NPVAppleTests/ControllerTests` | 17 项通过 | 共用控制器的首次配置、失败恢复、重复连接、取消、可控时钟超时、身份缺失、配置变化、后台采样及过期回复；包括模拟后端取消后的延迟结果验证 |
| iOS 模拟器 `NPVUITests/SimulatorFlowTests` | 7 条流程通过 | 实际启动 App，操作生成身份、保存与键盘编辑配置、连接/取消、输入错误、授权拒绝、启动失败、密钥恢复、无握手展示 |
| `bash scripts/check_simulator.sh` | 完整入口退出码 0 | 自动选择模拟器、执行测试、导出截图、构建 Debug / Release；Release 符号中未发现模拟后端类型 |
| Python 编译、Shell 语法 | 通过 | 本机构建辅助脚本基础语法 |

2026-10-26 在 Mac／iOS 模拟器上合计 **84 项不同的自动化测试通过**（39 Swift 核心 + 9 fixture + 10 构建工具 + 2 Apple 身份 + 17 控制器 + 7 UI）；编译、结构和语法检查另计。重复运行不累加，未运行的六项真实网络测试不计入。

统一脚本本次在 Mac 输出到 `artifacts/simulator-20261026-185727.BDp3Yd/`：包含 83 项测试的日志、`Simulator.xcresult`、截图及两种 iOS 构建证据。随后补充的第 17 项控制器测试在 `artifacts/SimulatorFollowup.xcresult` 通过；同轮增强的键盘编辑 UI 检查最初因 SwiftUI 合并无障碍标签而失败。改为保存后重新打开编辑页核对字段值后，于 19:14 的 `artifacts/SimulatorEditValidation.xcresult` 复测通过（退出码 0）。这次只修正测试断言，App 源码与已通过的 Debug / Release 构建一致。

补充日志为 `artifacts/simulator-followup.log`、`artifacts/simulator-edit-validation.log`，最终编辑流程截图位于 `artifacts/simulator-edit-screenshots/`。首次配置、连接、校验错误、诊断和无握手截图已经人工查看。日志、截图与构建产物不提交 Git。

## 本轮交付范围

- 分离 VPN、身份、诊断存储与超时调度接口，真实和模拟后端共用连接控制器。
- Debug 模拟器自动采用明确标识的模拟模式；实验身份和配置只驻留进程内存，不访问真实 Keychain、App Group 或 VPN 配置。
- 完成连接、配置、诊断页面及开发场景选择；支持字段定位、保存失败保留表单、后台清除统计和有界操作记录。
- 增加可通过 SSH 运行的自动验证入口与截图导出；真实设备的 Debug / Release 都使用系统实现，失败不会转为模拟成功。
- 运行方式和边界见 `simulator-development.md`。这些结果不证明实际 VPN 路由、系统签名权限、Keychain 共享或泄漏防护。

## 发现并修正

- 原始 WireGuard 上游 Go 时钟 diff 无法应用到已安装的 Go 1.22 源码；新增只在私有 GOROOT 副本中应用同等符号转换的准备器，未知布局失败退出。
- 原始 UAPI 运行配置可能含私钥；客户端只提取数值统计，测试验证序列化结果不含密钥和 endpoint。
- 停止清理错误可能覆盖真正的启动失败；现保留原始启动错误。
- DNS fixture 需兼容系统解析器的 EDNS 查询；已增加有界 OPT 解析和回归测试。
- 构建阶段显式调用 `/bin/bash`，避免 Windows 创建的脚本没有 Unix executable 位而导致构建失败。
- 连接请求发出后系统可能仍短暂报告未连接；独立跟踪请求，防止提前取消超时或重复启动。新增 8 项核心回归测试，覆盖启动、取消、停止和过期回调。
- 超时取消直接请求系统停止，不受界面当前状态限制；不会将超时本身伪装为系统已断开。该 Apple API 行为仍待真机验证。
- 连接前重新读取系统保存的配置，并检查身份；配置改变时要求先核对。丢弃状态切换前发出的过期统计回复。这两项改动已通过 iOS 编译，实际系统状态行为仍待真机验收。
- 官方 Go 安装路径没有出现在非交互 SSH 的 PATH 中；构建脚本显式包含 `/usr/local/go/bin`。
- Mac 自带 Python 3.9 无法安装需要 Python 3.10+ 的 openstep-parser 2.0.3；Mac 结构检查改用系统 `plutil`，已实际通过。
- 固定 WireGuard 清单声明 Swift tools 5.3，却使用 5.5 才引入的平台常量；仅修正声明为 5.5，并对完整清单和其余依赖改动进行校验。Xcode 的 Swift 包解析现已通过。
- 安装的 iOS 26.2 候选运行包 `23C52` 没有与当前 SDK 匹配；经授权安装正式运行包 `23C54` 并设置 `23C57 → 23C54` 对应关系。原来的平台不可用错误消失。操作与回退命令见验收文档。
- 新版 SDK 的显式 C 模块检查要求头文件自行引用 BSD 类型；补充 `WireGuardKitC.h` 的 `sys/types.h` 引用，并对完整预期内容进行校验。Windows 端 Git 源文件读取显式使用 UTF-8。
- 调试目标曾同时请求 x86_64／arm64，而 Swift 包只构建所选模拟器架构；Debug 配置设置 `ONLY_ACTIVE_ARCH=YES` 后，模拟器构建与身份测试通过。
- Go 依赖直连官方模块服务超时；本次构建通过 Mac 已配置的本机代理下载，保留固定 `go.sum` 与默认依赖校验机制。

已补齐 iPad 支持的界面方向声明，仍未进行 iPad UI 验收。AppIntents 元数据提取跳过及 Apple 测试框架不剥离签名二进制的提示未导致构建或测试失败。

## 尚未完成，不能计为通过

| 项目 | 原因／下一步 |
| --- | --- |
| 真机签名、VPN 授权、App Group 与 Keychain | 需要开发者签名及真实 iPhone |
| 6 项 iPhone DNS/TCP/UDP/IPv4/IPv6 测试 | 已编写且默认禁用；需要真实隧道和受控网关 fixture |
| 网关外部转发、错误密钥、设备撤销 | 需要已授权的测试服务器与真实手机 |
| 真实外侧抓包与 DNS/IPv6 泄漏验证 | 需要可观察的测试网络；本机 loopback 测试不能替代 |
| 真机/iPad UI、锁屏、网络切换、耗电 | iPhone 模拟器基础 UI 已验证；这些设备和实际运行行为仍待验收 |
| 上游依赖漏洞评估与工业级发布认证 | 不属于已通过结果；旧上游依赖必须在正式发布前复核 |

2026-10-26：Xcode 平台匹配与编译兼容问题已修复，未签名 iOS 构建和模拟器身份测试通过。签名、真实 iPhone、已授权测试网关仍是实网验收的前置条件。

第一阶段未标记整体验收完成。可以报告“未签名 iOS App 已成功构建”；不能报告“真机已连通”或“工业级安全已达标”。
