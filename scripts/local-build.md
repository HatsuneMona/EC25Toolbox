# 本机 CLT 构建与音频回归

适用于当前仅安装 Command Line Tools 的 macOS 26 / Apple Silicon 环境。恢复基线为上游 27.1 加 Claude 的 EC20 USB 序列号音频定位修复及 SwiftUI 编译兼容修改。源码与构建产物均从仓库根目录解析，仓库可以移动。

```sh
zsh scripts/local-audio-tests.zsh
zsh scripts/local-build.zsh
zsh scripts/local-package.zsh
```

- `local-audio-tests.zsh` 执行 `ModuleAudioTopologyTests.swift` 中的 18 个测试。CLT 未提供 XCTest，脚本编译随附的轻量断言兼容模块；此运行方式仅覆盖音频拓扑测试。完整测试套件应在安装 Xcode 的环境运行。
- `local-build.zsh` 使用本机 `xcrun` 选择的 macOS SDK，直接编译 C、协议模块和 Swift 主程序。输出位于 `.build/local-clt/manual/EC25Toolbox`。同一仓库请勿并行执行此脚本，编译期间应停止源码写入。
- `local-package.zsh` 默认从 `/Applications/EC25 Toolbox.app` 复制 27.1 的图标、已编译资源及辅助程序，覆盖本次主程序和仓库中的资源，生成 `dist/EC25 Toolbox.app` 并进行本地签名验证。也可通过第一个参数传入保留的 27.1 App。已有输出会拒绝覆盖，请先移走旧产物。
- 打包脚本不安装或启动应用。请在通话结束后按实施步骤备份并替换安装，再验证双向音频。

当前 CLT 的 SwiftPM manifest 运行库与接口不匹配，原构建方式曾无法求值 Package.swift，因此保留直接 swiftc 构建入口。完整 Xcode 环境仍可使用上游 SwiftPM / 打包流程。
