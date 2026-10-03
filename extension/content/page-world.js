/*
 * MissAV Clean — page-world 补丁（运行在页面主世界 MAIN world）
 *
 * 与安卓端 lib/main.dart 的 UserScript 一一对应，六段 JS 原样移植：
 *   _jsFlagsLoader      特性开关读取（扩展版：每 2s 轮询一次，支持运行中切换）
 *   _jsPopupKill        window.open 空操作（popunder 根治）
 *   _jsVisibilityFreeze 冻结页面可见性（防切后台刷新）
 *   _jsAdSweeper        广告清扫器（iframe/横幅/直播位 + MutationObserver 巡逻）
 *   _jsVideoProgress    续播进度（localStorage 按页面路径存取）
 *   _jsDomProbe         DOM 探针（__mavFlags.probe 打开时输出 MAVDUMP，用于写新规则）
 *
 * 开关来源：localStorage.__mav_flags（由 clean.js 从 chrome.storage 桥接写入）。
 * 这些补丁必须跑在主世界：window.open 覆写和 document.hidden 重定义
 * 在隔离世界（isolated world）里只改得到副本，拦不住页面自己的脚本。
 */
(function () {
  'use strict';
  if (window.__mavExtLoaded) return;
  window.__mavExtLoaded = 1;

  /// 开关读取（原 _jsFlagsLoader + 轮询升级）
  function loadFlags() {
    try {
      window.__mavFlags = JSON.parse(localStorage.getItem('__mav_flags') || '{}');
    } catch (e) {
      window.__mavFlags = {};
    }
  }
  loadFlags();
  setInterval(loadFlags, 2000);

  /// 弹窗/popunder 根治（原 _jsPopupKill）
  window.open = function () { return null; };

  /// 保活核心：冻结页面可见性（原 _jsVisibilityFreeze）
  (function () {
    if (window.__mavVis) return; window.__mavVis = 1;
    try {
      Object.defineProperty(document, 'hidden', { get: function () { return false; }, configurable: true });
      Object.defineProperty(document, 'visibilityState', { get: function () { return 'visible'; }, configurable: true });
    } catch (e) {}
    ['visibilitychange', 'webkitvisibilitychange', 'blur', 'pagehide', 'freeze'].forEach(function (t) {
      try { window.addEventListener(t, function (e) { e.stopImmediatePropagation(); }, true); } catch (e) {}
      try { document.addEventListener(t, function (e) { e.stopImmediatePropagation(); }, true); } catch (e) {}
    });
  })();

  /// 广告清扫器（原 _jsAdSweeper）
  (function () {
    if (window.__mavClean) return; window.__mavClean = 1;
    var AD = /exoclick|exosrv|exdynsrv|realsrv|magsrv|tsyndicate|trafficstars|trafficjunky|juicyads|popads|popcash|popunder|clickadu|hilltopads|adsterra|propellerads|adcash|coinzilla|bidgear|clickaine|etahub|adsco\.re|doubleclick|googlesyndication|google-analytics|googletagmanager|histats|statcounter|adnium|adspyglass|admaven|monetag|profitableratecpm|highperformanceformat|rtbsystem|recreativ|onclickalgo|suscript|cpmstar|adpushup|valueimpression|stripchat|chaturbate|livejasmin|bongacams|camsoda|flirt4free|xlovecam|rmhfrtnd|mnaspm|sbirdr|xlviiirdr|hotcam|streamate|imlive/i;
    function inVideo(el) {
      try { return !!(el.closest && el.closest('video')); } catch (e) { return false; }
    }
    function drop(el) { try { el.remove(); } catch (e) {} }
    function bannerKill(el) {
      if (!el.isConnected) return;
      var cs; try { cs = getComputedStyle(el); } catch (e) { return; }
      if (cs.position !== 'fixed' && cs.position !== 'absolute') return;
      if (el.querySelector('video') || el.querySelector('input') || el.querySelector('form')) return;
      if (el.closest && el.closest('.plyr,.vjs,#player')) return;
      var r = el.getBoundingClientRect();
      if (r.width < 120 || r.height < 40 || r.height > innerHeight * 0.6) return;
      var hasImg = !!el.querySelector('img');
      var hasClose = false;
      var kids = el.querySelectorAll('*');
      for (var k = 0; k < kids.length; k++) {
        var tx = (kids[k].textContent || '').trim();
        if (tx.length <= 2 && (tx === '×' || tx === '✕' || tx === 'X' || tx === 'x')) { hasClose = true; break; }
        if (/close/i.test(String(kids[k].className || ''))) { hasClose = true; break; }
      }
      var z = parseInt(cs.zIndex, 10) || 0;
      var bottomZone = r.top > innerHeight * 0.5;
      if (!((hasClose && (bottomZone || z >= 100)) || (bottomZone && z >= 100 && hasImg))) return;
      drop(el);
    }
    function scanOverlaySeeds() {
      var seeds = document.querySelectorAll('img, button, [role="button"], [aria-label], [title]');
      for (var i = 0; i < seeds.length; i++) {
        var node = seeds[i].parentElement;
        for (var depth = 0; node && node !== document.body && depth < 7; depth++, node = node.parentElement) {
          var cs; try { cs = getComputedStyle(node); } catch (e) { continue; }
          if (cs.position !== 'fixed' && cs.position !== 'absolute') continue;
          if (node.querySelector('video') || node.querySelector('input') || node.querySelector('form') || (node.closest && node.closest('.plyr,.vjs,#player'))) break;
          var r = node.getBoundingClientRect();
          if (r.width < 120 || r.height < 40 || r.height > innerHeight * 0.7 || r.width > innerWidth * 1.1) continue;
          var close = node.querySelector('[aria-label*="close" i],[title*="close" i],[data-close],button,[role="button"]');
          if (!close) {
            var kids = node.querySelectorAll('*');
            for (var k = 0; k < kids.length; k++) {
              var tx = (kids[k].textContent || '').trim();
              if (tx === '×' || tx === '✕' || tx === 'X' || tx === 'x') { close = kids[k]; break; }
            }
          }
          var z = parseInt(cs.zIndex, 10) || 0;
          var bottom = r.bottom > innerHeight * 0.5;
          var hasImg = !!node.querySelector('img') || cs.backgroundImage !== 'none';
          if (hasImg && (close || (bottom && z >= 10))) { drop(node); break; }
        }
      }
    }
    function sweep() {
      if (window.__mavFlags && window.__mavFlags.ad === 0) return;
      try {
        document.querySelectorAll('iframe').forEach(function (f) {
          if (inVideo(f)) return;
          var p = f.parentElement;
          drop(f);
          if (p && p !== document.body && !p.querySelector('video') && (p.textContent || '').trim().length < 40) drop(p);
        });
        var nodes = document.querySelectorAll('div, section, aside, a');
        for (var i = 0; i < nodes.length; i++) {
          var el = nodes[i];
          if (!el.isConnected || inVideo(el) || el.querySelector('video')) continue;
          var text = (el.innerText || '').trim();
          if (text.length > 700 || text.length < 4) continue;
          var imgs = el.querySelectorAll('img');
          var lives = (text.match(/\bLIVE\b/g) || []).length;
          if (lives >= 1 && imgs.length >= 1 && imgs.length <= 8 && el.querySelectorAll('a, button').length <= 16) {
            drop(el);
            continue;
          }
          if (el.tagName === 'A' && imgs.length === 1) {
            var href = el.getAttribute('href') || '';
            var host = location.hostname.replace(/^www\./, '');
            var external = href.indexOf('http') === 0 && href.indexOf(host) < 0;
            var promo = external || /\/go\.php|\/ads?\/|affiliate|幻想|出片/.test(href + text);
            var r = el.getBoundingClientRect();
            if (promo && r.width > 140 && r.height > 140 && text.length < 80) drop(el);
          }
        }
        scanOverlaySeeds();
        document.querySelectorAll('div, ins, aside, section, a').forEach(function (el) {
          if (!el.isConnected || !el.getAttribute) return;
          var st = (el.getAttribute('style') || '').toLowerCase();
          if (st.indexOf('fixed') < 0 && st.indexOf('absolute') < 0) return;
          bannerKill(el);
        });
        document.querySelectorAll('body > div, body > ins, body > a, body > section').forEach(function (el) {
          if (inVideo(el)) return;
          var cs; try { cs = getComputedStyle(el); } catch (e) { return; }
          if (cs.position !== 'fixed' && cs.position !== 'absolute') return;
          var r = el.getBoundingClientRect();
          var z = parseInt(cs.zIndex, 10) || 0;
          var idc = String((el.id || '') + ' ' + (typeof el.className === 'string' ? el.className : ''));
          var adish = /(ad|ads|banner|popup|popunder|sponsor|overlay|live)/i.test(idc);
          if (r.width > 40 && r.height > 40 && (adish || (cs.position === 'fixed' && z >= 400 && r.right > innerWidth - 300 && r.bottom > innerHeight - 300))) drop(el);
        });
      } catch (e) {}
    }
    var timer = null;
    function schedule() { if (timer) return; timer = setTimeout(function () { timer = null; sweep(); }, 200); }
    try { new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true }); } catch (e) {}
    setInterval(sweep, 2000);
    sweep();
  })();

  /// 续播（原 _jsVideoProgress）
  (function () {
    if (window.__mavProg) return; window.__mavProg = 1;
    function key() { return '__mav_pos:' + location.pathname; }
    var done = false;
    function tryRestore() {
      if (window.__mavFlags && window.__mavFlags.prog === 0) { done = true; return; }
      if (done) return;
      var v = document.querySelector('video');
      if (!v) return;
      var t = parseFloat(localStorage.getItem(key()) || '0');
      if (!(t > 10)) { done = true; return; }
      function doSeek() {
        try {
          if (v.duration && t < v.duration - 20) { v.currentTime = t; }
          done = true;
        } catch (e) { done = true; }
      }
      if (v.readyState >= 1) doSeek();
      else v.addEventListener('loadedmetadata', doSeek, { once: true });
      setTimeout(function () { done = true; }, 15000);
    }
    var tries = 0;
    var iv = setInterval(function () { tryRestore(); if (done || ++tries > 60) clearInterval(iv); }, 1000);
    setInterval(function () {
      if (window.__mavFlags && window.__mavFlags.prog === 0) return;
      var v = document.querySelector('video');
      try {
        if (v && !isNaN(v.currentTime)) {
          if (v.duration && v.duration - v.currentTime < 30) {
            localStorage.removeItem(key()); // 看到结尾了，清掉进度
          } else if (v.currentTime > 10) {
            localStorage.setItem(key(), String(v.currentTime));
          }
        }
      } catch (e) {}
    }, 5000);
  })();

  /// DOM 探针（原 _jsDomProbe，扩展版默认关闭，__mavFlags.probe 打开才跑）
  (function () {
    setTimeout(function () {
      if (!window.__mavFlags || !window.__mavFlags.probe) return;
      try {
        var out = [];
        document.querySelectorAll('body div, body ins, body a, body section, body aside').forEach(function (el) {
          var cs; try { cs = getComputedStyle(el); } catch (e) { return; }
          if (cs.position !== 'fixed' && cs.position !== 'absolute') return;
          var r = el.getBoundingClientRect();
          if (r.width < 80 || r.height < 30) return;
          if (el.querySelector('video') || el.querySelector('input')) return;
          var html = el.outerHTML.replace(/\s+/g, ' ').slice(0, 450);
          out.push('POS=' + cs.position + ' Z=' + (parseInt(cs.zIndex, 10) || 0) +
            ' RECT=' + Math.round(r.width) + 'x' + Math.round(r.height) + '@' +
            Math.round(r.top) + ',' + Math.round(r.left) + ' :: ' + html);
        });
        console.log('MAVDUMP_BEGIN n=' + out.length);
        out.slice(0, 12).forEach(function (s) { console.log('MAVDUMP: ' + s); });
        console.log('MAVDUMP_END');
      } catch (e) { console.log('MAVDUMP_ERR ' + e); }
    }, 4000);
  })();
})();
