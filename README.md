# 开屏广告走开

一个面向 iOS App 的开屏广告辅助跳过插件。插件通过 UIKit 视图节点和启动阶段的严格“跳过”文字扫描来尝试跳过开屏广告，不需要修改宿主 App 的源码。

## 功能

- 启动阶段严格扫描“跳过”“跳过广告”“Skip”等原生按钮文字。
- 支持通过“添加节点”选择可点击控件、文字节点和点击手势节点。
- 保存节点的类名、文字、尺寸、可访问性标识和屏幕锚点，页面布局变化后重新匹配。
- 优先派发控件事件和点击手势；严格文字命中后才尝试当前节点位置。
- 截图模板可用于手动测试，不参与自动开屏跳过。
- 清理常见的更新、通知、评分和青少年模式弹窗，不处理支付、删除和退出登录类弹窗。
- 支持全程监听，处理中途出现的广告或弹窗。
- 设置面板支持添加节点、截图模板、选择删除、测试和清除自定义项目。
- 自动检查 GitHub Tag，有新版本时提醒，不会自动下载、替换或重新注入 dylib。

## 防误触

开屏阶段不会进行固定坐标盲点点击。应用启动或回到前台后，等待约 1 秒开始严格文字扫描，持续约 12 秒；同时按已保存节点重新遍历视图树。

普通新窗口、键盘窗口和系统窗口出现时，不会重新启动一轮高频盲点点击。只有应用启动和回到前台时才会启动新的检查会话。

```mermaid
flowchart LR
    A[启动或回到前台] --> B[等待约 1 秒]
    B --> C[严格扫描跳过原生文字]
    A --> D[重新匹配已保存视图节点]
    C -->|命中| E[派发节点动作]
    D -->|命中| E
```

## 设置

设置面板通过启动提示或三指长按打开。设置只对当前注入的应用生效。

“功能开关”默认收起，目前包含：

- **弹窗清理**：关闭常见的更新、通知和评分弹窗。
- **全程监听**：使用已保存节点处理使用过程中后来出现的目标。

自动检查更新和三指长按默认开启，不单独显示开关，状态会写在设置面板底部的小字中。

## 安装

### 侧载注入

1. 从 [v0.0.5 Release](https://github.com/susu123oss/adgo/releases/tag/v0.0.5) 下载 `SplashAway.dylib`。
2. 注入目标 App 前，先移除旧的 `AdSkip.dylib`、`SplashAway.dylib` 或 `广告走开.dylib`，避免多个版本同时加载。
3. 注入后彻底结束目标 App，再重新打开。
4. 通过启动提示或三指长按进入设置，确认插件已经加载。

### 本地构建

项目使用 Theos 构建，目标架构为 `arm64` 和 `arm64e`：

```sh
make package
```

构建完成后：

- `dist/开屏广告走开.dylib`：侧载注入使用的双架构 dylib。
- `packages/`：本地构建的 deb 包，仅用于本地安装或测试。

## 在线更新

插件每天最多检查一次公开的 GitHub Tag：

```text
https://api.github.com/repos/susu123oss/adgo/tags?per_page=20
```

只有形如 `v0.0.5` 的稳定三段式 Tag 会参与版本比较。发现更新后，点击“在线更新”会打开对应的 GitHub Release 页面；插件不会在后台下载或替换自身。

## 发布

版本号需要同时更新以下位置：

- `control` 中的 `Version`。
- `Tweak.x` 中的 `kASVersion`。
- `CHANGELOG.md` 中对应的版本标题。

推送包含 `release/` dylib 和更新日志的提交后，`.github/workflows/release.yml` 会创建或更新对应的 GitHub Release。正式发版时只上传 dylib，不上传 deb 或 zip。

## 项目文件

```text
Tweak.x                       插件实现
Makefile                      Theos 构建配置
SplashAway.plist              动态库过滤配置
control                       deb 包元数据
CHANGELOG.md                  更新日志
.github/workflows/release.yml GitHub Release 工作流
release/                      GitHub Release 使用的 dylib
```
