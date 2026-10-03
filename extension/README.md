# MissAV Clean（浏览器扩展）

安卓客户端同款净化体验的浏览器移植版：广告域名拦截、弹窗横幅清扫、popunder 根治、防切后台刷新、续播进度。原生 JS，无需构建工具。

## 安装（Chrome / Edge，开发者模式加载）

1. 打开 `chrome://extensions`（Edge 是 `edge://extensions`）
2. 右上角开启「开发者模式」
3. 点「加载已解压的扩展程序」，选择本 `extension/` 目录
4. 打开 [missav123.com](https://missav123.com) 或 [missav.ws](https://missav.ws)，工具栏图标可开关各项功能

> Firefox：需 128+（依赖 `world: "MAIN"` 内容脚本）。加载时把 `manifest.json` 里 `background.service_worker` 改为 `"background": {"scripts": ["background.js"]}`，其余不用动。

## 功能与实现对照（安卓端 → 扩展）

| 安卓端（lib/main.dart） | 扩展端 | 说明 |
|---|---|---|
| ContentBlocker BLOCK（`_adDomains`） | `rules.json`（declarativeNetRequest，57 条） | 网络层拦截，含 main_frame（popunder 跳转直接断掉） |
| ContentBlocker CSS_DISPLAY_NONE（`_adSelectors`） | `content/clean.js` 注入 `<style>` | CSS 兜底隐藏 |
| `_jsPopupKill` | `content/page-world.js` | window.open 空操作 |
| `_jsVisibilityFreeze` | `content/page-world.js` | 冻结页面可见性，防切后台刷新 |
| `_jsAdSweeper` | `content/page-world.js` | MutationObserver 清扫动态广告 |
| `_jsVideoProgress` | `content/page-world.js` | localStorage 续播 |
| `_jsDomProbe` | `content/page-world.js` | 控制台输出 MAVDUMP，用于写新规则（默认关） |
| `_jsGestures`（左滑返回/旋转按钮） | 不移植 | 桌面端无此需求，属 Flutter 通道逻辑 |

### 为什么分两个 world

- **page-world.js 跑在页面主世界（MAIN world）**：`window.open = function(){}` 和重定义 `document.hidden` 在隔离世界只改得到副本，拦不住页面自己的脚本，所以必须进主世界。要求 Chrome 111+ / Firefox 128+。
- **clean.js 跑在隔离世界**：负责 CSS 注入和开关桥接（`chrome.storage` → `localStorage.__mav_flags` → 主世界脚本 2 秒内生效），只有隔离世界能碰扩展 API。

## 维护

**改广告域名黑名单**：只改根目录 `lib/main.dart` 的 `_adDomains`（单一事实来源），然后重新生成：

```bash
cd extension
python tools/gen_rules.py   # 需要 Python 3，无需第三方库
```

**改图标**：`python tools/gen_icons.py`（需要 Pillow）

**调试横幅规则**：popup 里暂未开放探针开关时，在站点控制台执行：

```js
localStorage.__mav_flags = JSON.stringify({ad:1, prog:1, probe:1});
```

刷新页面，4 秒后控制台 grep `MAVDUMP` 拿到弹窗层的真实结构，据此往 `_adSelectors` / sweeper 里加精确规则（与安卓端同一套调试手法）。

## 已知边界

- CSS 规则里 `iframe { display: none }` 是安卓端原样移植：本站播放器是页面内 `<video>`，iframe 全是广告位；若站点将来引入合法 iframe（如评论组件），把该条从 `clean.js` 的 `SELECTORS` 里去掉即可。
- 开关状态存 `chrome.storage.local`，各站点不互通账号数据（本来也不需要）。
