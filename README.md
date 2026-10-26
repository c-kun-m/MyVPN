# NPV · iOS 安全隧道实验客户端

第一阶段实现：原生 iOS App + Packet Tunnel 扩展 + WireGuardKit。
目前已完成源码、Xcode 工程和未签名 iOS 构建，主 App、隧道扩展与 Go bridge 已编译链接成功。Mac／iOS 模拟器上共 60 项自动化测试通过。**尚未完成真实 iPhone 签名、与远端服务器联调及泄漏测试；不能当作已验收或生产可用的 VPN。**

## 已实现

- 单服务器配置、系统 VPN 授权、连接与断开、真实系统状态同步。
- CryptoKit 生成 Curve25519 设备身份，Keychain 保存私钥；只展示和分享公钥。
- App 与扩展通过专用 Keychain 访问组共享身份，通过持久引用读取密钥。
- 配置在主 App 和扩展两端校验，强制同时配置 IPv4/IPv6、指定 DNS、双栈默认路由。
- WireGuardKit 接口集成、固定源码依赖及 Go bridge 构建步骤。
- 有界 IPC，只向 UI 返回收发计数、握手时间和采样时间；不返回原始运行配置。
- 基础错误日志、启动超时、前台统计；没有“VPN 图标出现即已安全”的提示。
- 39 项核心自动化测试、2 项已在 iOS 模拟器通过的身份测试、6 项待显式启用的真机网络测试。

本阶段不包含自动重连策略、分流、多协议、远程订阅、HTTPS 解密和生产安全认证。`includeAllNetworks` 是候选系统策略，具体故障行为仍需按真机矩阵验收。

## 目录

| 路径 | 内容 |
| --- | --- |
| `NPV.xcodeproj` | 主 App、隧道扩展、托管 XCTest 的可打开工程 |
| `Sources/Core` | 无 Apple SDK 依赖的配置、安全校验、状态和 IPC 模型 |
| `Sources/AppleShared` | Keychain、App Group、脱敏错误记录 |
| `Sources/App` | SwiftUI 界面和系统 VPN 控制器 |
| `Sources/Tunnel` | WireGuard 配置转换、Packet Tunnel Provider |
| `Tests/CoreTests` | Linux/macOS 上实际运行的核心测试 |
| `Tests/AppleTests` | 身份向量测试和真机 DNS/TCP/UDP 测试 |
| `lab` | 自有测试网关上的受限 DNS／TCP／UDP fixture |
| `scripts` | 固定依赖获取、工程生成、检查和测试入口 |
| `docs/phase1-validation.md` | 真机与网关准备、联调步骤和验收证据 |
| `docs/test-report.md` | 已执行测试、结果、限制和剩余工作 |

## 在 Mac 上构建

需要支持 iOS 18 的 Xcode（16 或以上）、命令行工具、Python 3、Git 和 Go。
官方 Go 安装器默认安装到 `/usr/local/go`。非交互 SSH 会话可能没有加载它的 PATH；可在当前会话执行 `export PATH="/usr/local/go/bin:$PATH"`。工程的 Go 构建脚本已包含这个路径。
Go bridge 使用上游构建逻辑，并在私有 GOROOT 副本中应用同等语义的连续时钟修改（旧上游 diff 的上下文已不适配较新 Go）。修改只允许三个经过识别的符号位置，未知源码布局会报错。仍必须验证所选 Go/Xcode 组合；旧版上游的依赖不能直接认定为生产合格，详见依赖说明。

通过 GitHub 同步到 Mac：

```sh
mkdir -p ~/Developer
git clone https://github.com/c-kun-m/MyVPN.git ~/Developer/MyVPN
cd ~/Developer/MyVPN
```

已有此目录时，在目录中执行 `git pull --ff-only` 更新。只通过 SSH 也可以执行下方的自动化测试及未签名编译；安装到 iPhone 仍需要设备配对和开发签名。

```sh
python3 scripts/bootstrap.py
cp Config/Local.xcconfig.example Config/Local.xcconfig
open NPV.xcodeproj
```

在 `Config/Local.xcconfig` 填入自己的 Team ID 和 Bundle ID 前缀。
主 App、扩展需要一致的团队、App Group 和 Keychain 访问组；签名配置必须允许 Network Extensions 的 `packet-tunnel-provider`。
选择 NPV scheme 和真实 iPhone，开启设备开发者模式后 Build/Run。主 App 与扩展都要成功签名。
不要将开发者证书私钥、服务器 SSH 私钥或密码放到项目中。

第一阶段只支持一个自己的 VPN 配置；重复配置会提示处理，不会自动修改其他 VPN 应用。

## 首次配置

1. 打开 App，生成设备密钥，将显示的**公钥**登记到自有测试网关。
2. 按服务器实际配置填写 endpoint、服务器公钥、本机 IPv4/IPv6 隧道地址和 DNS。
3. 保存并通过 iOS 系统 VPN 授权，然后连接。
4. 查看“隧道已启动”和统计中的成功握手，接着按验证文档执行实网测试。

配置中的 `10.77.0.2/32`、`fd77::2/128` 和 `10.77.0.1` 是实验示例，不是已经部署的服务。
服务器须配置转发、所需的路由/NAT、设备授权和防火墙；此仓库不会自动修改或购买任何服务器。
服务器公钥必须经可信渠道获得。更改服务器公钥前需断开连接。

私钥采用 `AfterFirstUnlockThisDeviceOnly`：重启后首次解锁前不可读取。VPN 配置和共享文件不含私钥。
若已保存配置引用的身份丢失，客户端不会自动生成替代私钥；需要显式重新登记新身份。

## 本地测试

```sh
# Windows/Linux：Python 3.10+，安装检查器到项目缓存；Mac 使用系统 plutil，无需此安装
python3 -m pip install --target .build-support/python openstep-parser==2.0.3
python3 scripts/check_project.py

# Swift 6 工具链，Linux 或 Mac；Apple 源文件只有语法检查
bash scripts/test_core.sh

# fixture 协议和本机 IPv4/IPv6 socket 测试，不经过 VPN
python3 -m unittest discover -s lab -p 'test_*.py' -v
python3 -m unittest discover -s scripts -p 'test_*.py' -v

# 仅在 Mac 上：核心测试 + 未签名 iOS 编译
bash scripts/check_macos.sh
```

原始输出保存在本机 `artifacts/`（忽略提交）。当前工具链的未签名 iOS 编译与两项身份测试已通过；签名、Keychain 跨进程访问和真机网络行为仍须验证。
不要将跳过的真机测试记为通过。

## 依赖与证据

WireGuardKit 固定为官方仓库镜像的 `2fec12a6e1f6e3460b6ee483aa00ad29cddadab1`；`scripts/dependencies.json` 是锁定记录。
`Vendor/` 是可重新获取的忽略目录，`bootstrap.py` 会检查源码提交和本地改动，不覆盖不同版本。只允许两处兼容修改：将上游 `Package.swift` 的 Swift tools 声明从 5.3 修正为 5.5，以及在 `WireGuardKitC.h` 中显式引用 `sys/types.h`，以适配新版 SDK 的 C 模块类型检查。其他改动会阻止构建。
源码许可证和工程资料见 `THIRD_PARTY_NOTICES.md`。Xcode 项目由标准库 Python 脚本生成，可重复生成；修改结构后执行 `python3 scripts/generate_project.py`。

正式发布前仍须进行上游依赖更新与漏洞评估、正式签名及发布构建、真机矩阵、泄漏测试、独立安全审查以及发布资格核验。
