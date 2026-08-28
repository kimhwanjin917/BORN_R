#!/usr/bin/env python
"""PreToolUse guard: Salesforce deploy 명령을 감지해 항상 사용자 확인(ask)을 요구한다.

목적: 로컬이 org보다 낡은 상태에서 실수로 배포해 팀원 작업을 덮어쓰는 참사 방지.
매칭되지 않으면 아무것도 출력하지 않고 종료 -> 정상 권한 흐름 유지.
"""
import sys, json, re

# Windows 콘솔 기본 인코딩(cp949)에서도 한글/이모지 JSON을 깨지지 않게 출력
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

cmd = ""
ti = data.get("tool_input") or {}
if isinstance(ti, dict):
    cmd = ti.get("command") or ""
name = data.get("tool_name") or ""
haystack = "{} {}".format(cmd, name)

# sf project deploy / sfdx force:source|mdapi:deploy|push / mcp deploy_metadata
pattern = r"sf\s+project\s+deploy|sfdx\s+force:(source|mdapi):(deploy|push)|deploy_metadata"

if re.search(pattern, haystack, re.IGNORECASE):
    reason = (
        "⚠️ 배포(deploy) 명령 감지 — "
        "로컬이 org보다 낡았을 수 있습니다. "
        "팀원 작업을 덮어쓸 위험!\n"
        "배포 전 반드시 확인:\n"
        "  1) sf project retrieve 로 org 최신 상태를 로컬에 받았는가\n"
        "  2) 충돌(conflict) 검증을 마쳤는가\n"
        "확실하지 않으면 배포를 취소하세요."
    )
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "ask",
            "permissionDecisionReason": reason,
        }
    }, ensure_ascii=False))

sys.exit(0)
