# 第一阶段：Mac 构建与真机验收

这份文档描述待执行的验收，不是已通过证明。实际执行结果见 `test-report.md`。

## 开始前

准备可接入的 Mac/Xcode、能够签名的开发者账号、开发者模式开启的 iPhone，以及获得授权的测试网关。
请通过自己的安全渠道安装开发者签名、SSH 密钥，不向聊天或仓库提供私钥。
可以先用学校网络内的 Linux 实验机完成链路验证，再在获准的云测试环境复现。

记录：Mac 型号、Xcode/SDK 版本、Go 版本、iPhone 型号、iOS 版本、网络类型和网关系统版本。
所有操作先在测试设备和实验网络执行，特别是 DNS fixture 会有意只解析两个实验域名。

## 1. 获取依赖与构建

```sh
python3 scripts/bootstrap.py
python3 scripts/check_project.py
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

填写 Team ID 和唯一 Bundle ID 前缀。主 App 与扩展需要相同的 App Group 和 Keychain 访问组；生成的 Info.plist 与 entitlements 通过 xcconfig 使用同一组值。
确认 Xcode 真机签名包含 `packet-tunnel-provider`，不要以模拟器签名检查代替真实设备权限。

```sh
bash scripts/check_macos.sh
```

该脚本只做核心测试和未签名 iOS 编译。然后在 Xcode 中选择 NPV scheme 和真实 iPhone，Build/Run，分别核对 App 和扩展签名。
Go bridge 首次构建会在 DerivedData 中复制安装的 GOROOT，再应用上游连续时钟修改；未知符号布局会拒绝构建。不得为通过构建而跳过此检查。
结构检查在 Mac 使用系统 `plutil`，无需额外 Python 包。`bootstrap.py` 只允许固定上游清单的 Swift tools 5.3 → 5.5 修正和 `WireGuardKitC.h` 中的 `sys/types.h` 引用；其他依赖改动会阻止构建。当前 SDK 的实际编译结果和限制见 `test-report.md`。

### SSH 环境中的平台匹配错误

如果 Xcode 报告 `iOS ... is not installed`，先核对实际安装版本和 SDK 对应关系：

```sh
xcrun --sdk iphoneos --show-sdk-build-version
xcrun simctl list runtimes
xcrun simctl runtime match list
xcodebuild -project NPV.xcodeproj -scheme NPV -showdestinations
```

2026-10-26 的实测环境是 Xcode 26.3、iOS 26.2 SDK `23C57`。原先只有候选发布版运行包 `23C52`，且匹配表没有为这个 SDK 选到已安装运行包。以下操作安装正式包并修正映射后，`Any iOS Device` 恢复可用，未签名 iOS 构建通过：

```sh
xcodebuild -downloadPlatform iOS -buildVersion 23C54 -architectureVariant arm64
xcrun simctl runtime match set iphoneos26.2 23C54 --sdkBuild 23C57
```

这些构建号仅对应上述环境。升级 Xcode 后应重新核对版本；需要恢复该 SDK 的默认匹配时执行：

```sh
xcrun simctl runtime match set iphoneos26.2 --default --sdkBuild 23C57
```

Go 命令行下载依赖可能没有继承 macOS 的系统代理。使用代理的环境应给当前构建命令设置实际的 `HTTPS_PROXY`／`HTTP_PROXY` 地址；依赖仍通过固定 `go.sum` 和 Go 默认校验机制验证。

## 2. 设备身份与网关参数

App 内生成身份，复制显示的设备公钥到网关的 peer 配置。示意（不是可以直接执行的完整网关配置）：

```ini
[Interface]
# 网关私钥由网关自己生成并保存在其受保护配置中
ListenPort = 51820

[Peer]
PublicKey = <从手机显示的公钥>
AllowedIPs = 10.77.0.2/32, fd77::2/128
```

在网关的 WireGuard 接口配置 `10.77.0.1/24`、`fd77::1/64`。
手机配置：对应 endpoint 和可信服务器公钥，`10.77.0.2/32`、`fd77::2/128`。
服务器 peer 的 AllowedIPs 只绑定该设备的源地址，不能误填手机端的默认路由。

要访问更远的目标，需要网关的 IPv4/IPv6 转发、回程路由或适当 NAT，以及限制访问范围的防火墙。
本项目不提供绕过既有网络规则的自动脚本，也不会自动修改真实网关配置。
先验证手机到隧道接口的通信，再验证网关到目标服务的转发；两者分别记录结果。

## 3. 只运行身份测试

在 Xcode Test Navigator 中运行 `IdentityTests` 两项测试：RFC 7748 公钥向量及错误私钥长度。

也可以通过 SSH 在已安装的模拟器上运行。先用 `-showdestinations` 确认实际设备名称；以下名称对应本次创建的测试设备：

```sh
xcodebuild -project NPV.xcodeproj -scheme NPV \
  -destination 'platform=iOS Simulator,name=NPV Validation,OS=26.2' \
  -derivedDataPath DerivedData -parallel-testing-enabled NO \
  -only-testing:NPVAppleTests/IdentityTests CODE_SIGNING_ALLOWED=NO test
```

该命令只运行两项身份测试。真实 Keychain 访问组、VPN 授权及网络行为按后续真机步骤验证。
默认禁用的 `NetworkPathTests` 不应因此被计为通过。
另外人工检查：退出并重启 App、锁屏后设备公钥保持一致，系统 VPN 配置／App Group 文件及日志中没有私钥。
重启但尚未首次解锁时 Keychain 不可读属于已定义边界，不应偷偷生成替代身份。

## 4. 启动可控协议 fixture

将 `lab/probe_server.py` 放到自己的测试网关，确保上述两个 WireGuard 接口地址存在。
防火墙仅允许已授权的实验 peer 通过 WireGuard 接口访问 DNS/UDP 53、TCP 8080、UDP 9000。
fixture 不应该通过公网网卡开放。

```sh
# DNS 53 是低端口；在自己管理的实验网关上按既有权限方式启动。
sudo python3 probe_server.py --ipv4 10.77.0.1 --ipv6 fd77::1
```

该进程只监听显式给定的私有 IP，拒绝全网卡绑定，且不执行 DNS 递归。
`npv-v4.test` 只返回实验 A 地址，`npv-v6.test` 只返回实验 AAAA 地址。
TCP/UDP 只回显不超过 128 字节的 `NPV/1 <随机标记>` 测试消息，不采集业务内容。
实验结束 Ctrl-C 停止；它不是生产 DNS 服务。

## 5. 执行六项真机网络测试

1. 手机 DNS 临时设为 `10.77.0.1`，保存配置后连接 NPV。
2. 先确认系统显示隧道已启动、服务器只登记了正确设备公钥。
3. Xcode → Edit Scheme → Test → Arguments，启用预设的 `NPV_RUN_NETWORK_TESTS=1` 环境变量；当前 scheme 的 Test 不沿用 Run 参数。
4. 选择真实 iPhone，运行 `NetworkPathTests`。
5. 保留 `.xcresult`、开始结束时间、两端抓包及服务器握手计数。
6. 关闭该测试环境变量，恢复手机实际需要的 DNS，停止 fixture。

六项测试分别是 TCP/IPv4、TCP/IPv6、UDP/IPv4、UDP/IPv6、系统解析 A 后 TCP、系统解析 AAAA 后 TCP。
每项要求返回本次请求的随机标记；无有效 NPV 系统连接时显式失败，未启用实验变量时跳过。
当前测试地址固定为上述示例。改变实验网段时必须同步修改测试代码，不能误测其他设备。

这些只证明“手机经隧道到网关实验服务”的通路，不证明完整公网转发、无泄漏、可靠重连或生产安全。
另用自有外部 HTTP/HTTPS/UDP 测试目标验证网关转发和返回路径，记录真实出口 IPv4/IPv6。
普通公网目标不能代替确定支持 IPv6 的测试目标。

## 6. 否定用例与外侧抓包

| 用例 | 期望与证据 |
| --- | --- |
| 错误服务器公钥 | 无成功的新握手、实验 nonce 无响应；不能只看 VPN 图标 |
| 网关删除手机 peer | 后续实验请求失败；恢复授权前不出现成功响应 |
| 网关停止隧道服务 | 请求失败，采集手机所在网络外侧的数据包 |
| 删除／拒绝系统 VPN 授权 | App 显示对应系统错误，没有虚假成功 |
| 启动后系统暂未更新状态、连续点击连接 | 等待请求期间不重复启动，30 秒未确认时发出停止请求并报告超时 |
| 连接过程中断开、快速连接与停止 | 停止取代待完成的连接请求，旧定时器和旧统计回复不影响当前连接 |
| 系统保存的服务器配置变化 | 再次连接前载入新配置并提示核对，不能用旧身份校验结果启动新配置 |
| 配置错误 IPv6／DNS | 输入校验拒绝格式错误；语义不可达时由实验检测揭示 |
| App 退后台与锁屏 | 记录扩展存活、数据通路和身份状态，不推断永久保活 |

通过 Mac RVI、可控 Wi-Fi 网关外侧抓包与服务端隧道内抓包关联同一轮实验。
RVI 可能包含隧道内部视角；内部看到测试明文不代表公网泄漏。
外侧应看到发往隧道 endpoint 的加密报文，不能看到预期被保护的测试 nonce 或意外的明文 DNS 请求。
服务器通路及系统允许的例外分开记录。没有抓到报文也不能独自证明安全，应结合正向连通测试。

## 完成条件

- Mac 构建与真实设备签名通过。
- 设备身份生成、持久化、两进程读取通过。
- 连接、断开、错误报告和基础日志通过。
- 受控六项网络测试及网关外部转发测试通过。
- 错误密钥和撤销设备测试通过，抓包证明本轮测试走了预期路径。
- 更新测试报告，附环境、时间、实际结果和剩余限制。

任何一项尚未执行，第一阶段的整体验收就仍然未完成。
