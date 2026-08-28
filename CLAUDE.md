# BORN_R 프로젝트 지침

> **⛔ 작업 시작 전 반드시 [AGENTS.md](AGENTS.md)를 먼저 읽고 그 규칙을 따를 것.**
> AGENTS.md가 팀 공용 작업·배포 규칙의 원본(canonical)이며, 아래 내용과 충돌하면 AGENTS.md가 우선한다.

## 🚨 배포(deploy) 안전 규칙 — 최우선

**로컬(git)이 org보다 낡은 상태에서 org로 배포하면 팀원 작업이 사라지는 대참사가 발생한다.**
production org를 팀원 5명이 직접 사용하며, Salesforce 배포는 파일 단위 덮어쓰기이기 때문이다.

**작업·배포 규칙 전문은 [AGENTS.md](AGENTS.md)를 따른다.** 핵심 요약:

1. 배포 전 반드시 org를 먼저 최신화(retrieve)하고 충돌을 검증한다 (AGENTS.md 3단계).
2. **배포는 오직 `scripts/safe-deploy.ps1`로만 한다. raw `sf project deploy` 직접 실행 금지.**
   - `pwsh scripts/safe-deploy.ps1 -Metadata ApexClass:X,ApexClass:XTest`
   - 이 래퍼가 org 현재본을 다시 받아 3-way(ORG/BASE=git HEAD/LOCAL) 비교로 제3자 변경을 감지하면 배포를 **기계적으로 중단**한다.
3. 사용자가 "배포해"라고만 해도, 최신화·충돌검증·명시 승인이 없으면 **먼저 되묻는다.**

### 기술적 안전장치 (이미 설정됨, 우회 금지)
- `scripts/safe-deploy.ps1`: org-우선 3-way 충돌 차단 배포 래퍼 (근본 방어).
- `.claude/settings.json` (팀 공유, committed): deploy 계열 명령을 `ask`로 격리 + PreToolUse hook 등록.
- `.claude/hooks/deploy-guard.py`: deploy 명령 감지 시 경고 + 사용자 확인 강제.
- `.claude/settings.local.json`: 개인 allow 목록 (gitignore, 커밋 안 됨).
