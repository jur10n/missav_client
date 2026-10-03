'use strict';

const DEFAULTS = { enabled: true, ad: 1, prog: 1, probe: 0 };
const KEYS = ['enabled', 'ad', 'prog'];

function render(settings) {
  for (const k of KEYS) {
    const el = document.getElementById(k);
    if (el) el.checked = settings[k] !== false && settings[k] !== 0;
  }
  document.body.classList.toggle('off', settings.enabled === false);
}

document.addEventListener('DOMContentLoaded', function () {
  chrome.storage.local.get(DEFAULTS, render);

  for (const k of KEYS) {
    const el = document.getElementById(k);
    if (!el) continue;
    el.addEventListener('change', function () {
      const patch = {};
      // enabled/ad/prog 在 clean.js 里按真值判断，这里统一存 0/1
      patch[k] = el.checked ? 1 : 0;
      chrome.storage.local.set(patch);
    });
  }
});
