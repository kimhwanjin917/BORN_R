#!/usr/bin/env python
"""UserPromptSubmit hook: 매 프롬프트마다 AGENTS.md 규칙을 상기시키고,
작업 시작 전 'AGENTS.md를 확인했다'고 사용자에게 먼저 밝히도록 지시한다.
"""
import sys, json

# Windows 콘솔 기본 인코딩(cp949)에서도 한글 JSON을 깨지지 않게 출력
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

# stdin(프롬프트 JSON)은 사용하지 않지만 파이프를 비워 준다
try:
    sys.stdin.read()
except Exception:
    pass

context = (
    "이 프로젝트에는 팀 공용 규칙 파일 AGENTS.md가 있다. "
    "파일 수정·명령 실행 등 실제 작업을 시작하기 전에, "
    "먼저 사용자에게 한국어로 'AGENTS.md 규칙을 확인했습니다'라고 짧게 밝히고 진행하라. "
    "특히 배포는 raw `sf project deploy` 금지, 반드시 scripts/safe-deploy.ps1 경유. "
    "org-우선 충돌 검증 없이 낡은 로컬을 배포해 팀원 작업을 덮어써서는 안 된다."
)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": context,
    }
}, ensure_ascii=False))

sys.exit(0)
