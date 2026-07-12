<div align="center">
  <img src="Assets/logo.gif" width="112" alt="KimiCodeBar Logo">
  <h1>KimiCodeBar</h1>
  <p>
    <img src="https://img.shields.io/badge/-Kimi%E7%A4%BE%E5%8C%BA%E7%89%88-orange" alt="Kimi社区版">
    <a href="https://www.apple.com/macos"><img src="https://img.shields.io/badge/macOS-333333?logo=apple&logoColor=white" alt="macOS"></a>
    <a href="https://github.com/xifandev/KimiCodeBar/releases"><img src="https://img.shields.io/badge/version-1.0.0-333333" alt="Version"></a>
    <a href="LICENSE"><img src="https://img.shields.io/github/license/xifandev/KimiCodeBar" alt="License"></a>
  </p>
</div>

**KimiCodeBar** 是为 [Kimi Code](https://www.kimi.com/code) 打造的用量实时监控小工具，采用HTTP协议查询，在菜单中极简轻量化运行。


## 运行效果

![菜单栏显示](Assets/menu-bar.png)

![展开面板](Assets/panel.png)

## 特性

- **用量监控** — 菜单栏直观显示当前用量等信息
- **新版本提醒** — 检测新版本并提示更新
- **极简轻量化** — 采用HTTP协议轮询，无任何运行负载
- **隐私安全** — Key设备本地存储，不上传云端，代码全部开源

## 安装使用

### 直接下载（推荐）

1. 下载 Releases 中的最新版本
2. 解压后将 `KimiCodeBar.app` 拖入「应用程序」文件夹
3. 首次打开时，系统会提示「无法验证开发者」，请点击「取消」
4. 打开「系统设置 → 隐私与安全性」，在「安全性」中找到「已阻止使用 KimiCodeBar.app」，点击「仍要打开」

> 由于本应用未使用 Apple Developer ID 签名，macOS Gatekeeper 会拦截首次启动。上述步骤只需执行一次。

### 自行编译

```bash
git clone https://github.com/xifandev/KimiCodeBar.git
cd KimiCodeBar
open macOS/KimiCodeBar.xcodeproj
```

使用 Xcode 选择你的 Mac，点击 Run 即可。


## 隐私说明

- API Key 保存在本地设备的 `NSUserDefaults`（`~/Library/Preferences/com.kimicodebar.app.plist`）中
- 不上传到任何第三方服务器
- 所有网络请求均直接发往 Kimi 官方 API（`api.kimi.com`）

## 技术栈

- Swift
- SwiftUI
- AppKit（MenuBarExtra）

## 许可证

[MIT](LICENSE)
