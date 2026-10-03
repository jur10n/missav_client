/*
 * MissAV Clean — service worker
 * 唯一的活：让 DNR 静态规则集的开关状态跟 chrome.storage 保持同步。
 * （popup 只写 storage；安装、启动、storage 变化时都来这里对齐一次）
 */
'use strict';

const RULESET_ID = 'ad_domains';

function syncRules() {
  // popup 统一存 0/1，用 !! 归一化
  chrome.storage.local.get({ enabled: 1 }, function (s) {
    const update = !s.enabled
      ? { disableRulesetIds: [RULESET_ID] }
      : { enableRulesetIds: [RULESET_ID] };
    chrome.declarativeNetRequest.updateEnabledRulesets(update, function () {
      if (chrome.runtime.lastError) {
        console.warn('[mav-clean] syncRules failed:', chrome.runtime.lastError.message);
      }
    });
  });
}

chrome.runtime.onInstalled.addListener(syncRules);
chrome.runtime.onStartup.addListener(syncRules);
chrome.storage.onChanged.addListener(function (changes, area) {
  if (area === 'local' && changes.enabled) syncRules();
});
