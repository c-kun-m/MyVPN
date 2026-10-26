# 第三方依赖

## WireGuardKit / wireguard-apple

- 上游：https://git.zx2c4.com/wireguard-apple/
- 官方镜像：https://github.com/WireGuard/wireguard-apple
- 固定提交：`2fec12a6e1f6e3460b6ee483aa00ad29cddadab1`
- 标签：`1.0.16-27`
- 许可证：MIT，完整许可文本见 `licenses/WireGuard-Apple.txt`。

Go bridge 的 `go.mod` 和 `go.sum` 在上述固定源码中，包含 wireguard-go、golang.org/x/sys、x/crypto 等传递依赖。
其完整许可证应在正式分发前随实际构建依赖清单一起复核和纳入制品。
此固定提交的 Go 依赖年代较早，**尚未做漏洞扫描及当前 Apple SDK／Go 工具链兼容性认证**；固定提交提高可复现性，不代表没有漏洞或适合生产。
此项目未修改上游的加密协议和实现，也没有把上游 UI 复制成自己的产品。

## 测试工具

- openstep-parser 2.0.3：用于独立解析实际 Xcode 工程，BSD 类许可证；仅存在于本机测试缓存，不进入 App。
- Swift 6.0.3 Linux：本次跨平台核心编译测试工具链，下载自 swift.org，并验证 Swift 6.x 官方发布签名。不是 iOS SDK。
- Python unittest：用于独立 fixture 协议测试。
