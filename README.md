# MissAV Client

第三方 MissAV 网页客户端（Flutter / Android + 浏览器扩展）。基于 WebView 的轻量壳应用，内置广告拦截、双线路切换、账号收藏直达、全屏播放旋转等增强功能；`extension/` 目录提供同款净化体验的 Chrome/Edge 浏览器扩展版。

> **免责声明**：本项目仅供学习交流与技术研究所用，与 MissAV 官方无关；相关内容仅面向成年人，使用前请了解并遵守您所在地区的法律法规。请勿用于任何商业用途。

## 功能

- **广告拦截（三层）**
  - 域名层：40+ 广告/追踪域名原生拦截（ExoClick 系、直播导流组件等）
  - CSS 层：弹窗容器、广告位、直播组件直接隐藏
  - 脚本层：MutationObserver 实时清扫动态插入的广告 iframe、插播卡片、弹窗横幅（结构化识别，不依赖广告文案）
- **双线路切换**：missav123.com / missav.ws 启动探活自动选线，手动切换保留当前路径
- **Cookie 保活**：自动落盘不清除；收藏页 400 自愈（自动压缩膨胀 cookie 并重试）
- **账号收藏**：顶栏 ⭐ 一键触发站内真实收藏（视频页 / 女优页，2 秒节流防连点），底栏直达账号收藏列表（女优 / 影片）
- **观看记录 + 近期常看**：自动记录观看历史，按女优 / 影片聚合常看内容，一键跳转官方观看历史
- **全屏旋转**：全屏播放自动横屏，播放器内一键切换横竖屏，退出还原进入前状态（相对旋转标记，不与系统自动旋转冲突）
- **手势返回**：左滑返回上一页，全屏先退播放，首页连滑两次退出
- **保活**：冻结页面可见性防止切后台刷新、退后台自动暂停视频、可申请忽略电池优化
- **数据管理**：观看记录 / 账号快照 / 播放进度的查看与清除，辅助功能全部带开关

## 构建

```bash
# 环境要求：Flutter 3.x stable + Android SDK（minSdk 24）
flutter doctor
flutter pub get
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

国内网络建议配置镜像：

```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
```

## 浏览器扩展（web 端）

安卓端同款净化的浏览器移植，见 [extension/README.md](extension/README.md)：

- 广告域名网络层拦截（declarativeNetRequest，与安卓端同一份黑名单，`tools/gen_rules.py` 从 `lib/main.dart` 生成）
- 弹窗横幅清扫 + popunder 根治 + 防切后台刷新 + 续播进度（六段 UserScript 原样移植）
- Chrome 111+ / Edge，开发者模式直接加载，无需构建

## 技术要点

- `flutter_inappwebview`：ContentBlocker 域名拦截 + UserScript 注入（可见性冻结 / 广告清扫 / 手势 / 续播）
- 收藏触发：页面内打分制模糊匹配站内收藏控件（精确文案 + 心形图标 + 按钮标签），导航型链接一律排除
- 播放续播：`localStorage` 按页面路径存取进度，重进自动回跳
- 已知坑：`setWebContentsDebuggingEnabled(true)` 在部分华为设备上会卡死启动（本项目已移除该调用）

## License

[MIT](LICENSE)

## 演示视频

- 🎬 [App 功能演示（72 秒）](https://raw.githubusercontent.com/jur10n/missav_client/main/demo/missav-app-demo.mp4) — 无广告首页 / 视频播放页 / 收藏菜单 / 观看记录 / 设置中心，点击直接用浏览器播放
- 🎬 [仓库页演示](https://raw.githubusercontent.com/jur10n/missav_client/main/demo/missav-client-demo.mp4)
- 或从 [Releases](https://github.com/jur10n/missav_client/releases) 页面下载
