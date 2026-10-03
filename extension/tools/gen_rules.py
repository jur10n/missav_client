#!/usr/bin/env python3
"""从安卓端 lib/main.dart 的 _adDomains 生成扩展的 rules.json。

单一事实来源是 main.dart：改广告域名黑名单只需要改那边，
然后在本目录跑 `python tools/gen_rules.py` 重新生成。
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAIN_DART = ROOT.parent / "lib" / "main.dart"
OUT = ROOT / "rules.json"

RESOURCE_TYPES = [
    "main_frame", "sub_frame", "stylesheet", "script", "image", "font",
    "object", "xmlhttprequest", "ping", "media", "websocket", "other",
]


def main() -> int:
    src = MAIN_DART.read_text(encoding="utf-8")
    m = re.search(r"const _adDomains = <String>\[(.*?)\];", src, re.S)
    if not m:
        print("ERROR: _adDomains not found in main.dart", file=sys.stderr)
        return 1

    # 只抽单引号字符串字面量，天然跳过注释，保留顺序，去重
    seen: dict[str, int] = {}
    for token in re.findall(r"'([^']+)'", m.group(1)):
        if not token:
            continue
        seen.setdefault(token, len(seen) + 1)

    rules = [
        {
            "id": rid,
            "priority": 1,
            "action": {"type": "block"},
            "condition": {
                # DNR urlFilter 默认子串匹配、不区分大小写，
                # 与安卓端 ContentBlocker 的 '.*domain.*' 等价
                "urlFilter": domain,
                "resourceTypes": RESOURCE_TYPES,
            },
        }
        for domain, rid in seen.items()
    ]

    OUT.write_text(json.dumps(rules, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"OK: {len(rules)} rules -> {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
