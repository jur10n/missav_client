/*
 * MissAV Clean — 隔离世界脚本（isolated world）
 *
 * 两个职责：
 * 1. CSS 层隐藏：对应安卓端 ContentBlocker 的 CSS_DISPLAY_NONE 规则，
 *    选择器列表与 main.dart 的 _adSelectors 保持一致。
 * 2. 开关桥接：popup 写 chrome.storage → 这里监听变化 →
 *    注入/移除 <style> + 写 localStorage.__mav_flags → 页面主世界脚本生效。
 *
 * 广告域名的网络层拦截由 rules.json（declarativeNetRequest）完成，
 * 对应安卓端 ContentBlocker 的 BLOCK 规则，见 tools/gen_rules.py。
 */
(function () {
  'use strict';

  const STYLE_ID = 'mav-clean-css';

  // 与安卓端 main.dart 的 _adSelectors 保持一致（兜底隐藏，JS 清扫为主力）
  const SELECTORS = [
    'iframe',
    'body > iframe',
    'body > div[style*="position: fixed"], body > div[style*="position:fixed"]',
    'iframe[src*="/ads/"], iframe[src*="/ad/"], iframe[src*="/adv"], iframe[src*="banner"]',
    'iframe[src*="livechat"], iframe[src*="live-cam"], iframe[src*="livecam"], iframe[src*="camgirl"]',
    'iframe[width="300"][height="250"], iframe[width="728"][height="90"], iframe[width="320"][height="50"]',
    'div[id^="div-gpt-ad"], div[class*="ad-banner"], div[id*="popup"], div[class*="popup"]',
    '.adsbyexoclick, ins.adsbyexoclick, [class^="exo-"], [id^="exo-"]',
    'a[href*="/go.php"]'
  ];

  const cssText = SELECTORS.map(function (s) { return s + '{display:none !important;}'; }).join('\n');

  function ensureStyle() {
    let el = document.getElementById(STYLE_ID);
    if (!el) {
      el = document.createElement('style');
      el.id = STYLE_ID;
      // document_start 阶段 head 还没生成，挂到 documentElement 上
      (document.head || document.documentElement).appendChild(el);
    }
    return el;
  }

  function apply() {
    // popup 统一存 0/1，这里一律用 !! 归一化，别用 !== false（漏数字 0）
    chrome.storage.local.get({ enabled: 1, ad: 1, prog: 1, probe: 0 }, function (s) {
      const on = !!s.enabled;
      const old = document.getElementById(STYLE_ID);
      if (old) old.remove();
      if (on && s.ad) ensureStyle().textContent = cssText;
      const flags = on
        ? { ad: s.ad ? 1 : 0, prog: s.prog ? 1 : 0, probe: s.probe ? 1 : 0 }
        : { ad: 0, prog: 0, probe: 0 };
      try { localStorage.setItem('__mav_flags', JSON.stringify(flags)); } catch (e) {}
    });
  }

  apply();
  if (chrome.storage.onChanged) {
    chrome.storage.onChanged.addListener(function (changes, area) {
      if (area === 'local') apply();
    });
  }
})();
