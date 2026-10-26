# 第三方依赖

## WireGuardKit / wireguard-apple

- 上游：https://git.zx2c4.com/wireguard-apple/
- 官方镜像：https://github.com/WireGuard/wireguard-apple
- 固定提交：`2fec12a6e1f6e3460b6ee483aa00ad29cddadab1`
- 标签：`1.0.16-27`
- 许可证：MIT，完整许可文本见 `licenses/WireGuard-Apple.txt`。

Go bridge 的 `go.mod` 和 `go.sum` 在上述固定源码中，包含 wireguard-go、golang.org/x/sys、x/crypto 等传递依赖。
其完整许可证应在正式分发前随实际构建依赖清单一起复核和纳入制品。
此固定提交的 Go 依赖年代较早，**尚未做漏洞扫描与生产安全评估**。本轮已通过 Xcode 26.3／Go 1.27.3 的 iOS 与模拟器构建，结果见测试报告；固定提交和编译成功不代表没有漏洞或适合生产。
此项目未修改上游的加密协议和实现，也没有把上游 UI 复制成自己的产品。
构建时允许两处兼容修正：将上游 `Package.swift` 首行 Swift tools 版本从 5.3 修正为 5.5，以匹配其声明的平台 API；在 `WireGuardKitC.h` 中显式引用 `sys/types.h`，提供新版 SDK 要求的 BSD 类型声明。每次构建核对固定提交、这两个文件的完整预期内容以及其余文件改动，不接受任意 vendor 补丁。

## 测试工具

- openstep-parser 2.0.3：Windows/Linux 使用的工程解析器，MIT 许可证，需要 Python 3.10+；仅存在于本机测试缓存，不进入 App。Mac 使用系统 `plutil`。
- Swift 6.0.3 Linux：本次跨平台核心编译测试工具链，下载自 swift.org，并验证 Swift 6.x 官方发布签名。不是 iOS SDK。
- Python unittest：用于独立 fixture 协议测试。
