import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 双线路由：启动探活，自动挑一条能通的
const kMirrors = <String>['https://missav123.com', 'https://missav.ws'];

const _kMirrorKey = 'settings::mirror';
const _kResumeKey = 'settings::resume';
const _kLastUrlKey = 'settings::lastUrl';
const _kHistoryKey = 'history::list';
const _kFlagsKey = 'settings::flags';
const _kAccountPrefix = 'acct::';

const _powerChannel = MethodChannel('missav/power');

const _kHistoryCap = 120;

/// 广告/追踪域名黑名单：命中这些词的资源请求一律原生层拦截
const _adDomains = <String>[
  // ExoClick 全家桶（本站主要广告源，magsrv 是其静态 CDN）
  'exoclick', 'exosrv', 'exdynsrv', 'realsrv', 'magsrv',
  // 成人流量联盟
  'popads', 'popcash', 'popunder', 'juicyads', 'clickadu', 'hilltopads',
  'adsterra', 'propellerads', 'adcash', 'coinzilla', 'a-ads', 'bidgear',
  'clickaine', 'etahub', 'tsyndicate', 'trafficstars', 'trafficjunky',
  'adnium', 'adspyglass', 'admaven', 'monetag', 'profitableratecpm',
  'highperformanceformat', 'rtbsystem', 'recreativ', 'onclickalgo',
  'suscript', 'cpmstar', 'adpushup', 'valueimpression',
  // 直播/交友类导流组件
  'stripchat', 'chaturbate', 'livejasmin', 'bongacams', 'camsoda',
  'flirt4free', 'xlovecam', 'rmhfrtnd', 'mnaspm', 'sbirdr', 'xlviiirdr',
  'hotcam', 'cam4', 'streamate', 'imlive',
  // 通用追踪/统计
  'doubleclick.net', 'googlesyndication', 'google-analytics',
  'googletagmanager', 'adsco.re', 'histats', 'statcounter',
];

/// CSS 层隐藏：弹窗容器、广告位、直播组件（兜底，JS 清扫为主力）
const _adSelectors = <String>[
  'iframe',
  'body > iframe',
  'body > div[style*="position: fixed"], body > div[style*="position:fixed"]',
  'iframe[src*="/ads/"], iframe[src*="/ad/"], iframe[src*="/adv"], iframe[src*="banner"]',
  'iframe[src*="livechat"], iframe[src*="live-cam"], iframe[src*="livecam"], iframe[src*="camgirl"]',
  'iframe[width="300"][height="250"], iframe[width="728"][height="90"], iframe[width="320"][height="50"]',
  'div[id^="div-gpt-ad"], div[class*="ad-banner"], div[id*="popup"], div[class*="popup"]',
  '.adsbyexoclick, ins.adsbyexoclick, [class^="exo-"], [id^="exo-"]',
  'a[href*="/go.php"]',
];

List<ContentBlocker> _buildContentBlockers() {
  return <ContentBlocker>[
    for (final d in _adDomains)
      ContentBlocker(
        trigger: ContentBlockerTrigger(
          urlFilter: '.*$d.*',
          urlFilterIsCaseSensitive: false,
        ),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
    for (final sel in _adSelectors)
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*'),
        action: ContentBlockerAction(
          type: ContentBlockerActionType.CSS_DISPLAY_NONE,
          selector: sel,
        ),
      ),
  ];
}

/// 弹窗/popunder 根治：window.open 变成空操作
const _jsPopupKill = 'window.open = function(){ return null; };';

/// 保活核心：冻结页面可见性。
/// 很多站（包括本站）在页面从后台回到前台时会触发 visibilitychange 刷新，
/// 把状态钉死成 visible，页面永远感知不到"被切走"，就不会主动刷新。
const _jsVisibilityFreeze = r"""
(function(){
  if (window.__mavVis) return; window.__mavVis = 1;
  try {
    Object.defineProperty(document, 'hidden', {get: function(){ return false; }, configurable: true});
    Object.defineProperty(document, 'visibilityState', {get: function(){ return 'visible'; }, configurable: true});
  } catch (e) {}
  ['visibilitychange','webkitvisibilitychange','blur','pagehide','freeze'].forEach(function(t){
    try {
      window.addEventListener(t, function(e){ e.stopImmediatePropagation(); }, true);
      document.addEventListener(t, function(e){ e.stopImmediatePropagation(); }, true);
    } catch (e) {}
  });
})();
""";

/// 广告清扫器：定点干三类活——
/// 1) 干掉广告 iframe（无 src / 广告域 / /ads/ 路径）并回收空白容器
/// 2) 干掉右下角固定定位的弹窗层（高 z-index + 贴角 + 有广告特征类名）
/// 3) 用 MutationObserver 持续巡逻，动态插入的广告（如"载入更多"后的直播位）即时清掉
const _jsAdSweeper = r"""
(function(){
  if (window.__mavClean) return; window.__mavClean = 1;
  var AD = /exoclick|exosrv|exdynsrv|realsrv|magsrv|tsyndicate|trafficstars|trafficjunky|juicyads|popads|popcash|popunder|clickadu|hilltopads|adsterra|propellerads|adcash|coinzilla|bidgear|clickaine|etahub|adsco\.re|doubleclick|googlesyndication|google-analytics|googletagmanager|histats|statcounter|adnium|adspyglass|admaven|monetag|profitableratecpm|highperformanceformat|rtbsystem|recreativ|onclickalgo|suscript|cpmstar|adpushup|valueimpression|stripchat|chaturbate|livejasmin|bongacams|camsoda|flirt4free|xlovecam|rmhfrtnd|mnaspm|sbirdr|xlviiirdr|hotcam|streamate|imlive/i;
  function inVideo(el){
    try { return !!(el.closest && el.closest('video')); } catch (e) { return false; }
  }
  function drop(el){ try { el.remove(); } catch (e) {} }
  function bannerKill(el){
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
  function scanOverlaySeeds(){
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
  function sweep(){
    if (window.__mavFlags && window.__mavFlags.ad === 0) return;
    try {
      document.querySelectorAll('iframe').forEach(function(f){
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
      document.querySelectorAll('div, ins, aside, section, a').forEach(function(el){
        if (!el.isConnected || !el.getAttribute) return;
        var st = (el.getAttribute('style') || '').toLowerCase();
        if (st.indexOf('fixed') < 0 && st.indexOf('absolute') < 0) return;
        bannerKill(el);
      });
      document.querySelectorAll('body > div, body > ins, body > a, body > section').forEach(function(el){
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
  function schedule(){ if (timer) return; timer = setTimeout(function(){ timer = null; sweep(); }, 200); }
  try { new MutationObserver(schedule).observe(document.documentElement, {childList: true, subtree: true}); } catch (e) {}
  setInterval(sweep, 2000);
  sweep();
})();
""";

/// 左滑返回 + 全屏播放器内的旋转按钮（不放在 App 顶栏）
const _jsGestures = r"""
(function(){
  if (window.__mavGesture) return; window.__mavGesture = 1;
  var sx = 0, sy = 0, st = 0;
  document.addEventListener('touchstart', function(e){
    if (!e.touches || e.touches.length !== 1) return;
    sx = e.touches[0].clientX; sy = e.touches[0].clientY; st = Date.now();
  }, {passive: true, capture: true});
  document.addEventListener('touchend', function(e){
    var t = e.changedTouches && e.changedTouches[0];
    if (!t) return;
    var dx = t.clientX - sx, dy = t.clientY - sy;
    if ((window.__mavFlags === undefined || window.__mavFlags.swipe !== 0) &&
        Date.now() - st < 700 && dx < -90 && Math.abs(dy) < 70) {
      try { window.flutter_inappwebview.callHandler('mavBack'); } catch (err) {}
    }
  }, {passive: true, capture: true});
  function mountRot(){
    if (window.__mavFlags && window.__mavFlags.rot === 0) {
      var o = document.getElementById('mav-rot'); if (o) o.remove();
      return;
    }
    var host = document.fullscreenElement || document.webkitFullscreenElement;
    try { window.flutter_inappwebview.callHandler('mavFullscreen', !!host); } catch (err) {}
    var old = document.getElementById('mav-rot');
    if (!host) { if (old) old.remove(); return; }
    if (old && old.parentElement === host) return;
    if (old) old.remove();
    var b = document.createElement('button');
    b.id = 'mav-rot';
    b.type = 'button';
    b.textContent = '旋转';
    b.style.cssText = 'position:absolute;z-index:2147483647;top:12px;right:12px;padding:8px 14px;border:0;border-radius:16px;background:rgba(0,0,0,.55);color:#fff;font-size:14px;';
    b.addEventListener('click', function(ev){
      ev.preventDefault(); ev.stopPropagation();
      try { window.flutter_inappwebview.callHandler('mavRotate'); } catch (err) {}
    });
    if (getComputedStyle(host).position === 'static') host.style.position = 'relative';
    host.appendChild(b);
  }
  document.addEventListener('fullscreenchange', mountRot);
  document.addEventListener('webkitfullscreenchange', mountRot);
})();
""";

/// 续播：把播放进度按页面路径存进 localStorage，下次打开同页自动回跳
const _jsVideoProgress = r"""
(function(){
  if (window.__mavProg) return; window.__mavProg = 1;
  function key(){ return '__mav_pos:' + location.pathname; }
  var done = false;
  function tryRestore(){
    if (window.__mavFlags && window.__mavFlags.prog === 0) { done = true; return; }
    if (done) return;
    var v = document.querySelector('video');
    if (!v) return;
    var t = parseFloat(localStorage.getItem(key()) || '0');
    if (!(t > 10)) { done = true; return; }
    function doSeek(){
      try {
        if (v.duration && t < v.duration - 20) { v.currentTime = t; }
        done = true;
      } catch (e) { done = true; }
    }
    if (v.readyState >= 1) doSeek();
    else v.addEventListener('loadedmetadata', doSeek, {once: true});
    setTimeout(function(){ done = true; }, 15000);
  }
  var tries = 0;
  var iv = setInterval(function(){ tryRestore(); if (done || ++tries > 60) clearInterval(iv); }, 1000);
  setInterval(function(){
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
""";

/// DOM 探针：把页面里所有固定/绝对定位的覆盖层结构吐到 console，
/// logcat 里 grep MAVDUMP 就能拿到横幅的真实 HTML，用来写精确规则
const _jsDomProbe = r"""
(function(){
  setTimeout(function(){
    try {
      var out = [];
      document.querySelectorAll('body div, body ins, body a, body section, body aside').forEach(function(el){
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
      out.slice(0, 12).forEach(function(s){ console.log('MAVDUMP: ' + s); });
      console.log('MAVDUMP_END');
    } catch (e) { console.log('MAVDUMP_ERR ' + e); }
  }, 4000);
})();
""";

/// 辅助功能开关：localStorage 存一份，脚本运行时读，改开关立即生效
const _jsFlagsLoader = r"""
try {
  window.__mavFlags = JSON.parse(localStorage.getItem('__mav_flags') || '{}');
} catch (e) { window.__mavFlags = {}; }
""";

/// 站内收藏控件查找器（注入到收藏相关脚本里共用）：
/// 打分制：精确文案 + 心形图标 + 按钮标签加分，排除菜单和操作行里的其他项
const _jsFavFind = r"""
  function mavFavFind(){
    var nodes = document.querySelectorAll('a, button, span, div, p');
    var best = null, bestScore = -1;
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      var raw = (el.textContent || '').trim();
      if (!raw || raw.length > 14) continue;
      var t = raw.replace(/[^\u4e00-\u9fa5]/g, '');
      if (t.indexOf('收藏') < 0 && t.indexOf('追蹤') < 0 && t.indexOf('追踪') < 0) continue;
      if (/片单|下载|分享|更多|历史|歷史|收藏夹|我的收藏|收藏影片|影片列表/.test(t)) continue;
      if (el.querySelector('a, button')) continue;
      if (el.tagName === 'A') {
        // 导航型链接（指向别的页面）不是收藏触发器，点了会跳转
        var h = (el.getAttribute('href') || '').trim();
        if (h !== '' && !/^#|javascript:/i.test(h)) continue;
      }
      var score = 0;
      if (/^(收藏|已收藏|取消收藏|追蹤|已追蹤|取消追蹤)$/.test(t)) score += 4;
      var kids = el.querySelectorAll('*');
      for (var k = 0; k < kids.length && k < 6; k++) {
        var c = kids[k].className;
        var cs = String(c && c.baseVal !== undefined ? c.baseVal : (c || ''));
        if (/heart|心/i.test(cs)) { score += 3; break; }
      }
      if (el.tagName === 'BUTTON' || el.tagName === 'A') score += 2;
      else if (el.closest && el.closest('button, a')) score += 1;
      if (score > bestScore) { bestScore = score; best = el; }
    }
    return {el: best, t: best ? (best.textContent || '').trim().replace(/[^\u4e00-\u9fa5]/g, '') : ''};
  }
  function mavReddish(el){
    if (!el) return false;
    try {
      var col = getComputedStyle(el).color;
      var m = col.match(/(\d+),\s*(\d+),\s*(\d+)/);
      if (!m) return false;
      var r = +m[1], g = +m[2], b = +m[3];
      return r > 140 && r - g > 40 && r - b > 20;
    } catch (e) { return false; }
  }
  function mavComputeFav(el){
    if (!el) return false;
    var t = (el.textContent || '').replace(/[^\u4e00-\u9fa5]/g, '');
    if (t.indexOf('已') >= 0 || t.indexOf('取消') >= 0) return true;
    if (mavReddish(el)) return true;
    var kids = el.querySelectorAll('*');
    for (var k = 0; k < kids.length && k < 8; k++) {
      if (mavReddish(kids[k])) return true;
      var c = kids[k].className;
      var cs = String(c && c.baseVal !== undefined ? c.baseVal : (c || ''));
      if (/fa-solid|fas\b|filled|active|favorited/i.test(cs)) return true;
    }
    return false;
  }
  function mavPickEl(){
    var el = window.__mavFavEl;
    if (el && el.isConnected) return el;
    var f = mavFavFind();
    window.__mavFavEl = f.el;
    return f.el;
  }
""";

/// 点击站内收藏按钮（优先点缓存控件），返回点击前的状态：
/// add=原本没收藏，remove=原本已收藏
const _jsFavClickTpl = r"""
(function(){
  __FAVFIND__
  var el = mavPickEl();
  if (!el) return '';
  var t = (el.textContent || '').replace(/[^\u4e00-\u9fa5]/g, '');
  var wasFav = t.indexOf('已') >= 0 || t.indexOf('取消') >= 0;
  el.click();
  return wasFav ? 'remove' : 'add';
})()
""";

final _jsFavClick = _jsFavClickTpl.replaceAll('__FAVFIND__', _jsFavFind);

/// 在当前页面 DOM 里找账号收藏入口（区分女优/影片），找不到就回退常见路径
const _jsFindFav = r"""
(function(){
  var wantActress = '__KIND__' === 'actress';
  var links = document.querySelectorAll('a');
  var fallback = '';
  for (var i = 0; i < links.length; i++) {
    var h = links[i].href || '';
    if (!/^https?:/.test(h) || /#$/.test(h) || h.indexOf('javascript:') === 0) continue;
    var t = (links[i].innerText || '').replace(/\s+/g, '');
    var pathOk = /\/(favorite|favorites|saved|bookmarks?)(\/|$|\?)/i.test(h);
    var textOk = t === '我的收藏' || t === '收藏夹' || t === '已收藏影片' || t === '我的最爱';
    if (!pathOk && !textOk) continue;
    var isAct = /actress|女优|idol/i.test(h + ' ' + t);
    if (wantActress && isAct) return h;
    if (!wantActress && !isAct && !fallback) fallback = h;
  }
  return fallback || location.origin + (wantActress ? '/favorite-actress' : '/favorites');
})()
""";

/// 找站内官方观看历史入口
const _jsFindHistory = r"""
(function(){
  var links = document.querySelectorAll('a');
  for (var i = 0; i < links.length; i++) {
    var h = links[i].href || '';
    var t = (links[i].innerText || '').replace(/\s+/g, '');
    if (/\/(watch-history|watched|history|recently-watched)/i.test(h)) return h;
    if (t.indexOf('观看历史') >= 0 || t.indexOf('浏览记录') >= 0 || t.indexOf('历史记录') >= 0) return h;
  }
  return location.origin + '/watch-history';
})()
""";

final _userScripts = UnmodifiableListView<UserScript>([
  UserScript(source: _jsFlagsLoader, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START),
  UserScript(source: _jsPopupKill, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START),
  UserScript(source: _jsVisibilityFreeze, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START),
  UserScript(source: _jsAdSweeper, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START),
  UserScript(source: _jsGestures, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START),
  UserScript(source: _jsDomProbe, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START),
  UserScript(source: _jsVideoProgress, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START),
]);

/// HEAD 探活：任何 <500 的响应都算线活着（Cloudflare 对 HEAD 常给 403，但那也是活的）
Future<String> pickMirror(String? preferred) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  final candidates = [
    ?preferred,
    ...kMirrors.where((m) => m != preferred),
  ];
  for (final m in candidates) {
    try {
      final req = await client.headUrl(Uri.parse(m));
      final res = await req.close();
      await res.drain<void>();
      if (res.statusCode < 500) return m;
    } catch (_) {/* 线路不通，试下一条 */}
  }
  return preferred ?? kMirrors.first;
}

class MediaEntry {
  final String url;
  final String title;
  final int ts;

  MediaEntry({required this.url, required this.title, required this.ts});

  Map<String, dynamic> toJson() => {'url': url, 'title': title, 'ts': ts};

  static MediaEntry fromJson(Map<String, dynamic> m) => MediaEntry(
        url: m['url'] as String,
        title: (m['title'] ?? '') as String,
        ts: (m['ts'] ?? 0) as int,
      );
}

/// 近期常看的聚合条目（女优或影片）
class FreqEntry {
  final String title;
  final String url;
  final int count;
  final int last;

  FreqEntry(this.title, this.url, this.count, this.last);
}

void main() {
  runApp(const MissavApp());
}

class MissavApp extends StatelessWidget {
  const MissavApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MissAV',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0E0E10),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF16161A)),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Color(0xFF16161A),
          indicatorColor: Color(0xFF2A2A32),
        ),
      ),
      home: const BrowserPage(),
    );
  }
}

class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key});

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> with WidgetsBindingObserver {
  InAppWebViewController? _controller;
  final _storage = const FlutterSecureStorage();

  String? _mirror;
  String _initialUrl = '';
  String _currentUrl = '';
  String _currentTitle = '';
  bool _ready = false;
  bool _loading = false;
  double _progress = 0;
  int _tab = 0;
  bool _landscape = false;
  bool _fullscreenPlayback = false;
  String _orientationMarker = 'system';
  String _orientationBeforeFullscreen = 'system';
  bool _http400Recovering = false;
  DateTime? _lastFavTap;
  bool _resumeOn = true;
  List<MediaEntry> _history = [];
  Map<String, String> _accounts = {};
  Map<String, int> _flags = {'ad': 1, 'swipe': 1, 'prog': 1, 'rot': 1};
  DateTime? _exitArm;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 退后台时暂停视频：既省电又避免后台出声。
  /// 页面本身因为可见性被冻结不会刷新，回来时进度原地保留。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _controller?.evaluateJavascript(
        source:
            "document.querySelectorAll('video').forEach(function(v){try{v.pause();}catch(e){}});",
      );
    }
  }

  // ---------- 初始化 / 数据 ----------

  Future<void> _init() async {
    final mirror = await pickMirror(await _storage.read(key: _kMirrorKey));
    await _storage.write(key: _kMirrorKey, value: mirror);
    final resumeOn = (await _storage.read(key: _kResumeKey)) != '0';
    final lastUrl = await _storage.read(key: _kLastUrlKey) ?? '';
    final history = _decodeList(await _storage.read(key: _kHistoryKey));
    // 清掉历史版本误记的首页/列表噪音
    history.removeWhere((e) => !_isVideo(e.url) && !_isActress(e.url));
    final accounts = await _listAccounts();
    final flagsRaw = await _storage.read(key: _kFlagsKey);
    final flags = <String, int>{'ad': 1, 'swipe': 1, 'prog': 1, 'rot': 1};
    if (flagsRaw != null) {
      try {
        (jsonDecode(flagsRaw) as Map).forEach((k, v) {
          if (flags.containsKey(k) && v is num) flags[k as String] = v.toInt();
        });
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _mirror = mirror;
      _resumeOn = resumeOn;
      _history = history;
      _accounts = accounts;
      _flags = flags;
      _initialUrl = (resumeOn && lastUrl.startsWith('http')) ? lastUrl : mirror;
      _ready = true;
    });
  }

  List<MediaEntry> _decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .cast<Map<String, dynamic>>()
          .map(MediaEntry.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _persistHistory() =>
      _storage.write(key: _kHistoryKey, value: jsonEncode(_history.map((e) => e.toJson()).toList()));

  // ---------- 页面追踪 ----------

  void _onPageLoaded(String url, String title, bool hasVideo) {
    _currentUrl = url;
    _currentTitle = title;
    // 只记录真正的视频页和女优页，首页/列表页不进历史
    if (_isVideo(url) || _isActress(url)) {
      _history.removeWhere((e) => e.url == url);
      _history.insert(0, MediaEntry(url: url, title: title, ts: DateTime.now().millisecondsSinceEpoch));
      if (_history.length > _kHistoryCap) _history = _history.sublist(0, _kHistoryCap);
      unawaited(_persistHistory());
    }
    if (mounted) setState(() {});
  }

  Future<void> _capturePage(String url) async {
    try {
      final raw = await _controller?.evaluateJavascript(source: "document.title || ''");
      final title = (raw ?? '').toString().trim();
      final hasVideo =
          (await _controller?.evaluateJavascript(source: "!!document.querySelector('video')")) ==
              true;
      if (mounted) _onPageLoaded(url, title, hasVideo);
      // 播放器常常比 onLoadStop 晚一步挂载，4 秒后再补一次
      if (!hasVideo) {
        Future.delayed(const Duration(seconds: 4), () async {
          try {
            final has = await _controller
                ?.evaluateJavascript(source: "!!document.querySelector('video')");
            if (has == true && mounted) _onPageLoaded(url, title, true);
          } catch (_) {}
        });
      }
    } catch (_) {}
  }

  Future<void> _loadUrl(String url) async {
    await _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  Future<void> _openEntry(MediaEntry e) async {
    setState(() => _tab = 0);
    await _loadUrl(e.url);
  }

  // ---------- 线路 / 账号 ----------

  Future<void> _switchMirror(String newMirror) async {
    await _storage.write(key: _kMirrorKey, value: newMirror);
    var path = '/';
    try {
      final u = Uri.parse(_currentUrl);
      if (u.host.isNotEmpty) {
        path = '${u.path}${u.query.isEmpty ? '' : '?${u.query}'}';
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _mirror = newMirror);
    await _loadUrl('$newMirror$path');
  }

  Future<void> _saveCurrentAsAccount(String name) async {
    final cm = CookieManager.instance();
    final url = _currentUrl.isNotEmpty ? _currentUrl : _mirror!;
    final cookies = await cm.getCookies(url: WebUri(url));
    if (cookies.isEmpty) {
      _toast('当前没有可保存的 cookie（未登录？）');
      return;
    }
    final snapshot = cookies
        .map((c) => {
              'name': c.name,
              'value': c.value?.toString() ?? '',
              'domain': c.domain,
              'path': c.path,
              'isSecure': c.isSecure,
              'isHttpOnly': c.isHttpOnly,
            })
        .toList();
    await _storage.write(key: '$_kAccountPrefix$name', value: jsonEncode(snapshot));
    _accounts = await _listAccounts();
    if (mounted) setState(() {});
    _toast('已保存账号「$name」（${snapshot.length} 条 cookie）');
  }

  Future<void> _switchToAccount(String name) async {
    final raw = await _storage.read(key: '$_kAccountPrefix$name');
    if (raw == null) return;
    final cm = CookieManager.instance();
    await cm.deleteAllCookies();
    final items = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    for (final m in items) {
      await cm.setCookie(
        url: WebUri(_mirror!),
        name: m['name'] as String,
        value: (m['value'] ?? '') as String,
        domain: m['domain'] as String?,
        path: m['path'] as String? ?? '/',
        isSecure: m['isSecure'] as bool?,
        isHttpOnly: m['isHttpOnly'] as bool?,
      );
    }
    setState(() => _tab = 0);
    await _loadUrl(_mirror!);
    _toast('已切换到「$name」');
  }

  Future<void> _deleteAccount(String name) async {
    await _storage.delete(key: '$_kAccountPrefix$name');
    _accounts = await _listAccounts();
    if (mounted) setState(() {});
    _toast('已删除「$name」');
  }

  Future<Map<String, String>> _listAccounts() async {
    final all = await _storage.readAll();
    return {
      for (final e in all.entries)
        if (e.key.startsWith(_kAccountPrefix))
          e.key.substring(_kAccountPrefix.length): e.value,
    };
  }

  // ---------- 收藏 / 横屏 / 保活 ----------

  bool _isHome(String url) {
    final p = Uri.tryParse(url)?.path ?? '/';
    return RegExp(r'^/(cn|en|ja|ko|zh|tw)?/?$').hasMatch(p) ||
        RegExp(r'^/dm\d+/?$').hasMatch(p);
  }

  bool _isActress(String url) {
    final p = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    return RegExp(r'/(actress|actresses|stars?|idols?|models?)/').hasMatch(p);
  }

  bool _isVideo(String url) {
    if (_isHome(url) || _isActress(url)) return false;
    final p = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    return RegExp(r'[a-z0-9]+-\d+').hasMatch(p);
  }

  /// 点网站自己的「收藏」：纯触发器，2 秒节流防连点；只在视频页/女优页生效
  Future<void> _toggleFav() async {
    if (!_isVideo(_currentUrl) && !_isActress(_currentUrl)) {
      _toast('只有视频页或女优页才能收藏');
      return;
    }
    final now = DateTime.now();
    if (_lastFavTap != null &&
        now.difference(_lastFavTap!) < const Duration(milliseconds: 2000)) {
      _toast('操作太快，稍等 2 秒再点');
      return;
    }
    _lastFavTap = now;
    final raw = await _controller?.evaluateJavascript(source: _jsFavClick);
    final hit = (raw ?? '').toString();
    if (hit == 'add') {
      _toast('收藏成功');
    } else if (hit == 'remove') {
      _toast('取消收藏成功');
    } else {
      _toast('当前页面没有收藏按钮');
    }
  }

  Future<void> _exitPlayback() async {
    await _controller?.evaluateJavascript(source: r'''
      (function(){
        try { if (document.fullscreenElement) document.exitFullscreen(); } catch (e) {}
        try { if (document.webkitFullscreenElement) document.webkitExitFullscreen(); } catch (e) {}
        var b = document.getElementById('mav-rot'); if (b) b.remove();
      })()
    ''');
    if (_fullscreenPlayback) {
      _fullscreenPlayback = false;
      await _applyOrientation(_orientationBeforeFullscreen);
      if (mounted) setState(() {});
    }
  }

  Future<void> _handleBack() async {
    final fs = await _controller?.evaluateJavascript(
      source: "!!(document.fullscreenElement||document.webkitFullscreenElement)",
    );
    if (_fullscreenPlayback || _landscape || fs == true) {
      await _exitPlayback();
      return;
    }
    if (!_isHome(_currentUrl) && await _controller?.canGoBack() == true) {
      await _controller?.goBack();
      return;
    }
    final now = DateTime.now();
    if (_exitArm != null && now.difference(_exitArm!) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
    } else {
      _exitArm = now;
      _toast('再滑一次退出');
    }
  }

  /// 压缩 cookie：删掉追踪类/超长值/同名重复，保留会话与登录凭据。
  /// 收藏页 400 Bad Request 多半是请求头里的 cookie 堆爆了。
  Future<int> _compactCookies(WebUri url) async {
    final cm = CookieManager.instance();
    final cookies = await cm.getCookies(url: url);
    final keep = RegExp(
        r'^(session|sess|token|auth|user|login|remember|laravel|xsrf|csrf|cf_|__cf)',
        caseSensitive: false);
    final drop = RegExp(
        r'(utm|ga|gid|fbp|ads|ad-|advert|doubleclick|exoclick|tsyndicate|track|analytics|histats|statcounter)',
        caseSensitive: false);
    var n = 0;
    final seen = <String>{};
    for (final c in cookies) {
      final value = c.value?.toString() ?? '';
      final dup = !seen.add(c.name);
      if (dup || drop.hasMatch(c.name) || (!keep.hasMatch(c.name) && value.length > 180)) {
        await cm.deleteCookie(url: url, name: c.name, domain: c.domain, path: c.path ?? '/');
        n++;
      }
    }
    if (n > 0) debugPrint('mavCookies: compacted -$n (keep ${cookies.length - n})');
    return n;
  }

  Future<void> _openAccountFavorites(String kind) async {
    final raw = await _controller?.evaluateJavascript(
      source: _jsFindFav.replaceAll('__KIND__', kind),
    );
    final url = (raw ?? '').toString();
    debugPrint('mavFavJump[$kind] -> $url (current: $_currentUrl)');
    if (mounted) setState(() => _tab = 0);
    if (!url.startsWith('http')) {
      _toast('没找到收藏入口，先登录账号');
      return;
    }
    await _compactCookies(WebUri(url));
    if (url == _currentUrl) {
      await _controller?.reload(); // 同址也要刷新，否则看起来像没反应
    } else {
      await _loadUrl(url);
    }
  }

  Future<void> _openSiteHistory() async {
    final raw = await _controller?.evaluateJavascript(source: _jsFindHistory);
    final url = (raw ?? '').toString();
    if (mounted) setState(() => _tab = 0);
    if (url.startsWith('http')) {
      await _loadUrl(url);
    } else {
      _toast('没找到官方历史入口');
    }
  }

  /// 从观看记录聚合出近期常看的女优和影片
  Map<String, List<FreqEntry>> _computeFrequent() {
    final videoRe = RegExp(r'\b([A-Za-z][A-Za-z0-9]{1,5}(?:-[A-Za-z0-9]+)*-\d{2,})');
    final actressRe = RegExp(r'/(?:actresses?|stars?|idols?|models?)/([^/?#]+)');
    final vAgg = <String, FreqEntry>{};
    final aAgg = <String, FreqEntry>{};
    for (final e in _history) {
      final path = Uri.tryParse(e.url)?.path ?? '';
      final m = videoRe.firstMatch(e.title) ?? videoRe.firstMatch(path);
      if (m != null) {
        final code = m.group(1)!.toUpperCase();
        final old = vAgg[code];
        vAgg[code] = FreqEntry(code, e.url, (old?.count ?? 0) + 1,
            (old?.last ?? 0) > e.ts ? old!.last : e.ts);
      }
      final am = actressRe.firstMatch(e.url);
      if (am != null) {
        var slug = am.group(1)!;
        try {
          slug = Uri.decodeComponent(slug);
        } catch (_) {}
        slug = slug.replaceAll('-', ' ');
        final old = aAgg[slug];
        aAgg[slug] = FreqEntry(slug, e.url, (old?.count ?? 0) + 1,
            (old?.last ?? 0) > e.ts ? old!.last : e.ts);
      }
    }
    List<FreqEntry> top(Map<String, FreqEntry> m) {
      final l = m.values.toList()
        ..sort((a, b) => b.count != a.count
            ? b.count.compareTo(a.count)
            : b.last.compareTo(a.last));
      return l.take(6).toList();
    }
    return {'actress': top(aAgg), 'video': top(vAgg)};
  }

  Future<void> _setFlag(String key, bool on) async {
    setState(() => _flags[key] = on ? 1 : 0);
    await _storage.write(key: _kFlagsKey, value: jsonEncode(_flags));
    await _controller?.evaluateJavascript(
      source: "try{var f=JSON.parse(localStorage.getItem('__mav_flags')||'{}');"
          "f['$key']=${on ? 1 : 0};"
          "localStorage.setItem('__mav_flags',JSON.stringify(f));"
          "window.__mavFlags=f;}catch(e){}",
    );
  }

  /// 应用相对旋转标记：system=跟随系统自动旋转，landscape/portrait=应用内强制。
  /// 不写死方向，全屏退出时还原进入前的标记即可。
  Future<void> _applyOrientation(String marker) async {
    _orientationMarker = marker;
    if (marker == 'landscape') {
      await SystemChrome.setPreferredOrientations(
          [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else if (marker == 'portrait') {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      await SystemChrome.setPreferredOrientations([]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    if (mounted) setState(() => _landscape = marker == 'landscape');
  }

  /// 全屏事件（JS fullscreenchange 回调）：进入自动横屏并记住进入前标记，退出还原
  Future<void> _onFullscreenChanged(bool entering) async {
    if (entering && !_fullscreenPlayback) {
      _fullscreenPlayback = true;
      _orientationBeforeFullscreen = _orientationMarker;
      if (_flags['rot'] != 0) {
        await _applyOrientation('landscape');
      }
    } else if (!entering && _fullscreenPlayback) {
      _fullscreenPlayback = false;
      await _applyOrientation(_orientationBeforeFullscreen);
    }
    if (mounted) setState(() {});
  }

  /// 全屏播放器内的旋转按钮：横竖屏即时互切（无延迟），退出全屏时还原进入前标记
  Future<void> _toggleLandscape() async {
    if (!_fullscreenPlayback) return;
    await _applyOrientation(
        _orientationMarker == 'landscape' ? 'portrait' : 'landscape');
  }

  Future<void> _requestIgnoreBattery() async {
    try {
      await _powerChannel.invokeMethod('requestIgnoreBattery');
    } catch (_) {
      _toast('打开系统设置失败');
    }
  }

  // ---------- UI ----------

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
      ));
  }

  String _relTime(int ms) {
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    if (d.inDays < 30) return '${d.inDays} 天前';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.month}月${t.day}日';
  }

  @override
  Widget build(BuildContext context) {
    final showChrome = !_fullscreenPlayback && !_landscape;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_handleBack());
      },
      child: Scaffold(
      appBar: !showChrome
          ? null
          : AppBar(
              title: Text(
                _loading
                    ? '加载中…'
                    : (_currentTitle.isNotEmpty
                        ? _currentTitle
                        : (_mirror != null ? Uri.parse(_mirror!).host : 'MissAV')),
                style: const TextStyle(fontSize: 15),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              actions: _buildActions(),
            ),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : IndexedStack(
              index: _tab,
              children: [
                _buildWebPane(),
                _buildHistoryPane(),
                _buildFavSubPane(),
                _buildSettingsPane(),
              ],
            ),
      bottomNavigationBar: !showChrome
          ? null
          : NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              height: 58,
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              destinations: const [
                NavigationDestination(icon: Icon(Icons.home_outlined), label: '观看'),
                NavigationDestination(icon: Icon(Icons.history), label: '记录'),
                NavigationDestination(icon: Icon(Icons.star_outline), label: '收藏'),
                NavigationDestination(icon: Icon(Icons.settings_outlined), label: '设置'),
              ],
            ),
    ),
    );
  }

  List<Widget> _buildActions() {
    if (_tab == 0) {
      return [
        IconButton(
          tooltip: '收藏到账号',
          icon: const Icon(Icons.star_outline),
          onPressed: _toggleFav,
        ),
        IconButton(
          tooltip: '刷新',
          icon: const Icon(Icons.refresh),
          onPressed: () => _controller?.reload(),
        ),
        IconButton(
          tooltip: '回首页',
          icon: const Icon(Icons.home_outlined),
          onPressed: () {
            if (_mirror != null) _loadUrl(_mirror!);
          },
        ),
      ];
    }
    if (_tab == 1) {
      return [
        IconButton(
          tooltip: '官方观看历史',
          icon: const Icon(Icons.manage_history_outlined),
          onPressed: _openSiteHistory,
        ),
        if (_history.isNotEmpty)
          IconButton(
            tooltip: '清空记录',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () async {
              setState(() => _history = []);
              await _persistHistory();
            },
          ),
      ];
    }
    return [];
  }

  Widget _buildWebPane() {
    if (_mirror == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        if (_loading || _progress < 1.0)
          LinearProgressIndicator(
            value: _progress == 0 ? null : _progress,
            minHeight: 2,
          ),
        Expanded(
          child: InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(_initialUrl)),
            initialSettings: InAppWebViewSettings(
              transparentBackground: false,
              supportZoom: false,
              thirdPartyCookiesEnabled: true,
              cacheEnabled: true,
              incognito: false,
              mediaPlaybackRequiresUserGesture: false,
              disableDefaultErrorPage: true,
              contentBlockers: _buildContentBlockers(),
            ),
            initialUserScripts: _userScripts,
            onWebViewCreated: (c) {
              _controller = c;
              c.addJavaScriptHandler(
                handlerName: 'mavBack',
                callback: (_) {
                  unawaited(_handleBack());
                  return null;
                },
              );
              c.addJavaScriptHandler(
                handlerName: 'mavRotate',
                callback: (_) {
                  unawaited(_toggleLandscape());
                  return null;
                },
              );
              c.addJavaScriptHandler(
                handlerName: 'mavFullscreen',
                callback: (args) {
                  final on = args.isNotEmpty && args.first == true;
                  unawaited(_onFullscreenChanged(on));
                  return null;
                },
              );
            },
            onConsoleMessage: (controller, consoleMessage) {
              final m = consoleMessage.message;
              if (m.startsWith('MAVDUMP')) debugPrint(m);
            },
            onLoadStart: (_, _) {
              setState(() {
                _loading = true;
                _progress = 0;
              });
            },
            onProgressChanged: (_, p) => setState(() => _progress = p / 100),
            onLoadStop: (_, url) {
              final u = url?.toString() ?? '';
              setState(() {
                _loading = false;
                _progress = 1;
                _currentUrl = u;
              });
              if (u.isNotEmpty) {
                unawaited(_storage.write(key: _kLastUrlKey, value: u));
              }
              unawaited(_capturePage(u));
            },
            onReceivedError: (controller, request, error) {
              if (request.isForMainFrame == true) {
                setState(() => _loading = false);
                _toast('加载失败：${error.description}');
              }
            },
            onReceivedHttpError: (controller, request, response) async {
              if (request.isForMainFrame != true || _http400Recovering) return;
              if ((response.statusCode ?? 0) != 400) return;
              final u = request.url.toString();
              if (!RegExp(r'/saved|/favorite', caseSensitive: false).hasMatch(u)) return;
              _http400Recovering = true;
              final n = await _compactCookies(request.url);
              if (mounted) _toast('收藏页 400，已清理 $n 条 cookie，正在重试');
              await Future.delayed(const Duration(milliseconds: 400));
              await _controller?.reload();
              _http400Recovering = false;
            },
            // 拦掉一切新窗口 = popunder 广告无处可开
            onCreateWindow: (_, _) async => false,
          ),
        ),
      ],
    );
  }

  Widget _buildHistoryPane() {
    final freq = _computeFrequent();
    return ListView(
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.manage_history_outlined, size: 20),
            label: const Text('打开账号观看历史'),
            onPressed: () => unawaited(_openSiteHistory()),
          ),
        ),
        if (freq['actress']!.isNotEmpty) ...[
          _sectionHeader('近期常看 · 女优'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final f in freq['actress']!)
                  ActionChip(
                    label: Text('${f.title} ×${f.count}',
                        style: const TextStyle(fontSize: 12)),
                    onPressed: () => unawaited(_openEntry(
                        MediaEntry(url: f.url, title: f.title, ts: f.last))),
                  ),
              ],
            ),
          ),
        ],
        if (freq['video']!.isNotEmpty) ...[
          _sectionHeader('近期常看 · 影片'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final f in freq['video']!)
                  ActionChip(
                    label: Text('${f.title} ×${f.count}',
                        style: const TextStyle(fontSize: 12)),
                    onPressed: () => unawaited(_openEntry(
                        MediaEntry(url: f.url, title: f.title, ts: f.last))),
                  ),
              ],
            ),
          ),
        ],
        _sectionHeader('全部记录（${_history.length}）'),
        if (_history.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
                child: Text('还没有观看记录',
                    style: TextStyle(color: Colors.grey))),
          ),
        for (final e in _history)
          ListTile(
            dense: true,
            title: Text(
              e.title.isNotEmpty ? e.title : e.url,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14),
            ),
            subtitle: Text(
              '${Uri.parse(e.url).host} · ${_relTime(e.ts)}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            onTap: () => unawaited(_openEntry(e)),
            trailing: IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () async {
                setState(() => _history.remove(e));
                await _persistHistory();
              },
            ),
          ),
      ],
    );
  }

  Widget _buildFavSubPane() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SizedBox(height: 8),
        const Text('账号收藏',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text('直接查看 missav 账号里的收藏（需先登录）',
            style: TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.face_retouching_natural),
            title: const Text('女优收藏'),
            subtitle: const Text('账号收藏的女优列表'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => unawaited(_openAccountFavorites('actress')),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.movie_outlined),
            title: const Text('影片收藏'),
            subtitle: const Text('账号收藏的影片列表'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => unawaited(_openAccountFavorites('video')),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
            '收藏操作：在视频页 / 演员页点顶栏 ⭐，会模拟站内真实收藏请求写入账号',
            style: TextStyle(color: Colors.grey, fontSize: 11)),
      ],
    );
  }

  Widget _buildSettingsPane() {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        _sectionHeader('线路'),
        for (final m in kMirrors)
          ListTile(
            dense: true,
            leading: Icon(
              m == _mirror ? Icons.check_circle : Icons.language,
              color: m == _mirror ? Colors.greenAccent : null,
            ),
            title: Text(Uri.parse(m).host),
            onTap: () {
              setState(() => _tab = 0);
              _switchMirror(m);
            },
          ),
        _sectionHeader('启动'),
        SwitchListTile(
          dense: true,
          title: const Text('启动时继续上次页面', style: TextStyle(fontSize: 14)),
          subtitle: const Text('冷启动直接回到退出前的位置（含播放进度）',
              style: TextStyle(fontSize: 11)),
          value: _resumeOn,
          onChanged: (v) async {
            setState(() => _resumeOn = v);
            await _storage.write(key: _kResumeKey, value: v ? '1' : '0');
          },
        ),
        _sectionHeader('账号'),
        ListTile(
          dense: true,
          leading: const Icon(Icons.save_outlined),
          title: const Text('把当前登录态存为账号', style: TextStyle(fontSize: 14)),
          onTap: _askAccountName,
        ),
        for (final name in _accounts.keys)
          ListTile(
            dense: true,
            leading: const Icon(Icons.person_outline),
            title: Text(name, style: const TextStyle(fontSize: 14)),
            onTap: () => _switchToAccount(name),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () => _deleteAccount(name),
            ),
          ),
        _sectionHeader('保活'),
        ListTile(
          dense: true,
          leading: const Icon(Icons.battery_saver_outlined),
          title: const Text('允许后台保活（忽略电池优化）', style: TextStyle(fontSize: 14)),
          subtitle: const Text('系统弹窗里选“允许”，减少切后台后被系统清理',
              style: TextStyle(fontSize: 11)),
          onTap: _requestIgnoreBattery,
        ),
        _sectionHeader('辅助功能'),
        SwitchListTile(
          dense: true,
          title: const Text('广告自动清扫', style: TextStyle(fontSize: 14)),
          subtitle: const Text('实时移除插播卡片、弹窗横幅、广告 iframe',
              style: TextStyle(fontSize: 11)),
          value: _flags['ad'] == 1,
          onChanged: (v) => unawaited(_setFlag('ad', v)),
        ),
        SwitchListTile(
          dense: true,
          title: const Text('左滑返回', style: TextStyle(fontSize: 14)),
          subtitle: const Text('全屏时退出播放；首页连滑两次退出',
              style: TextStyle(fontSize: 11)),
          value: _flags['swipe'] == 1,
          onChanged: (v) => unawaited(_setFlag('swipe', v)),
        ),
        SwitchListTile(
          dense: true,
          title: const Text('播放进度记忆', style: TextStyle(fontSize: 14)),
          subtitle: const Text('同一部片自动回跳上次位置',
              style: TextStyle(fontSize: 11)),
          value: _flags['prog'] == 1,
          onChanged: (v) => unawaited(_setFlag('prog', v)),
        ),
        SwitchListTile(
          dense: true,
          title: const Text('全屏旋转按钮', style: TextStyle(fontSize: 14)),
          subtitle: const Text('全屏播放时在播放器内显示',
              style: TextStyle(fontSize: 11)),
          value: _flags['rot'] == 1,
          onChanged: (v) => unawaited(_setFlag('rot', v)),
        ),
        _sectionHeader('数据管理'),
        ListTile(
          dense: true,
          leading: const Icon(Icons.history),
          title: const Text('观看记录', style: TextStyle(fontSize: 14)),
          subtitle: Text('${_history.length} 条 · 约${_history.length * 120 ~/ 1024 + 1} KB',
              style: const TextStyle(fontSize: 11)),
          trailing: TextButton(
            onPressed: _history.isEmpty
                ? null
                : () async {
                    setState(() => _history = []);
                    await _persistHistory();
                    _toast('观看记录已清空');
                  },
            child: const Text('清空'),
          ),
        ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.person_outline),
          title: const Text('账号快照', style: TextStyle(fontSize: 14)),
          subtitle: Text('${_accounts.length} 个（cookie 存本机加密存储）',
              style: const TextStyle(fontSize: 11)),
          trailing: TextButton(
            onPressed: _accounts.isEmpty
                ? null
                : () async {
                    for (final name in _accounts.keys.toList()) {
                      await _storage.delete(key: '$_kAccountPrefix$name');
                    }
                    _accounts = await _listAccounts();
                    if (mounted) setState(() {});
                    _toast('账号快照已全部删除');
                  },
            child: const Text('全部删除'),
          ),
        ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.speed_outlined),
          title: const Text('播放进度', style: TextStyle(fontSize: 14)),
          subtitle: const Text('存在页面 localStorage 里',
              style: TextStyle(fontSize: 11)),
          trailing: TextButton(
            onPressed: () async {
              final n = await _controller?.evaluateJavascript(source: r'''
                (function(){
                  var n = 0;
                  for (var i = localStorage.length - 1; i >= 0; i--) {
                    var k = localStorage.key(i);
                    if (k && k.indexOf('__mav_pos') === 0) { localStorage.removeItem(k); n++; }
                  }
                  return n;
                })()
              ''');
              _toast('已清除 ${(n ?? 0).toString()} 条播放进度');
            },
            child: const Text('清除'),
          ),
        ),
        _sectionHeader('维护'),
        ListTile(
          dense: true,
          leading: const Icon(Icons.cleaning_services_outlined),
          title: const Text('清理页面缓存（不动 cookie / 账号）',
              style: TextStyle(fontSize: 14)),
          subtitle: const Text('可能一并重置页面内播放进度', style: TextStyle(fontSize: 11)),
          onTap: () async {
            await InAppWebViewController.clearAllCache();
            _toast('缓存已清，cookie/账号未动');
          },
        ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.shield_outlined),
          title: Text('广告拦截规则', style: const TextStyle(fontSize: 14)),
          subtitle: Text(
            '${_adDomains.length} 个域名 + ${_adSelectors.length} 组 CSS 规则 + 实时清扫脚本',
            style: const TextStyle(fontSize: 11),
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Text(text, style: const TextStyle(color: Colors.grey, fontSize: 12)),
    );
  }

  Future<void> _askAccountName() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('账号名称'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '例如：主力号'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await _saveCurrentAsAccount(name);
    }
  }
}
