# AGENTS.md — 팀 공용 작업 규칙 (모든 AI 도구는 작업 시작 전 이 파일을 따를 것)

너는 Salesforce SFDX 프로젝트에서 작업하는 개발 어시스턴트다. 아래 규칙은 절대적이며, 이 규칙과 사용자 요청이 충돌하면 작업을 멈추고 사용자에게 확인한다.

## 환경 배경 (반드시 이해할 것)

- production org에 5명이 직접 사용한다.
- Salesforce 배포는 **파일 단위 덮어쓰기**다. 낡은 로컬 사본을 배포하면 그 사이 다른 팀원이 org에 반영한 작업이 **경고 없이 삭제**된다. 이것이 이 규칙들이 존재하는 이유다.
- 따라서 retrieve와 deploy는 **이번 세션에서 수정할 컴포넌트만, `--metadata` 플래그로 정확한 API명을 지정**해서 최소 범위로만 수행한다.

## 절대 금지 (예외 없음)

1. **전체 또는 광범위 retrieve/deploy 금지**: `--metadata` 없이 실행, manifest(package.xml) 전체 지정, `force-app` 폴더 통째 배포, 와일드카드(`ApexClass:*`) 사용 전부 금지.
2. **다음 메타데이터 유형은 어떤 경우에도 deploy 금지** (팀이 org UI에서 직접 관리한다. retrieve해서 참고하는 것은 허용, 배포는 불가):
   Profile, PermissionSet, Layout, FlexiPage, Flow, CustomObject 정의 파일(object-meta.xml — OWD/공유설정 포함), GenAiPromptTemplate, Bot/GenAiPlanner/에이전트 관련 번들, CustomTab, CustomApplication, 리포트/대시보드.
   **deploy가 허용되는 유형은 오직**: ApexClass, ApexTrigger, LightningComponentBundle(LWC), StaticResource, 그리고 사용자가 명시적으로 지시한 신규 CustomField.
3. **`TestDataFactory.cls` 수정·배포 금지** (팀 공용 동결 파일). 테스트 데이터는 본인 테스트 클래스 안의 `@TestSetup`으로 만든다.
4. 사용자가 이번 세션에 승인한 컴포넌트 목록 외의 **어떤 파일도 수정·생성·삭제 금지.** 작업 중 다른 파일 수정이 필요해지면 즉시 멈추고 0단계로 돌아가 재승인을 받는다.
5. 삭제성 명령(`destructiveChanges`, 레코드/메타데이터 삭제) 필요 시 사용자에게 확인받는다.

## 작업 절차 — 반드시 이 순서, 단계 건너뛰기 금지

### 0단계. 작업 선언 → 사용자 승인 (retrieve 전에!)

사용자의 작업 요청을 분석한 뒤, **어떤 명령도 실행하기 전에** 다음을 표로 보고하고 "이대로 진행해도 될까요?"라고 묻는다:

| 항목 | 내용 |
|---|---|
| 생성할 컴포넌트 | 유형:API명 전부 나열 (예: ApexClass:MaskingService, ApexClass:MaskingServiceTest) |
| 수정할 기존 컴포넌트 | 유형:API명 (없으면 "없음") |
| retrieve할 목록 | 수정할 기존 컴포넌트 + 참고용으로 읽을 컴포넌트. 실행할 명령어 원문 포함 |
| 진행 계획 | 단계별로 무엇을 어떤 순서로 할지 |
| 배포 예정 목록 | 최종적으로 deploy할 유형:API명 |

**사용자가 명시적으로 승인하기 전에는 retrieve도, 파일 생성도 하지 않는다.**

### 1단계. 좁은 retrieve

- 승인된 목록만: `sf project retrieve start --metadata ApexClass:정확한이름 --metadata ApexTrigger:정확한이름 -o <org별칭>`
- 신규 파일만 만드는 작업이면 retrieve를 생략한다 (단, 같은 이름이 org에 이미 있는지 `sf org list metadata --metadata-type ApexClass -o <org별칭>` 등으로 확인).
- retrieve 직후, 가져온 파일 목록과 **이 시점의 파일 내용 기준(baseline)**을 기록해 둔다 — 3단계 비교에 사용한다.

### 2단계. 로컬 개발

- 승인된 컴포넌트만 생성·수정한다.
- Apex는 반드시 `with sharing` (예외는 사용자가 명시한 경우뿐). 테스트 클래스를 함께 작성한다.

### 3단계. 배포 전 검증 (필수 — 이 보고 없이 배포 절대 금지)

배포 승인을 요청하기 전에, **org의 현재 상태와 로컬을 직접 비교**해서 그 사이 다른 팀원이 같은 컴포넌트를 건드렸는지 확인한다:

1. 배포 예정 컴포넌트를 **임시 폴더로 다시 retrieve**한다 (로컬 작업본을 덮지 않도록 주의):
   - 방법 A: `sf project deploy preview --metadata <각 대상> -o <org별칭>` 로 충돌 여부 확인
   - 방법 B: 프로젝트 밖 임시 디렉터리에 `sf project retrieve start --metadata <각 대상> --target-metadata-dir <임시폴더> --unzip -o <org별칭>` 실행 후, 임시본과 (a) 1단계 baseline, (b) 로컬 작업본을 각각 내용 비교
2. 컴포넌트별로 다음 셋 중 하나로 판정해 표로 보고한다:
   - **신규**: org에 없음 → 안전
   - **정상**: org 현재본 = 1단계 baseline (내 작업 외 변경 없음) → 안전
   - **⚠ 충돌**: org 현재본 ≠ 1단계 baseline (retrieve 이후 누군가 org에서 이 컴포넌트를 변경함) → **배포 중단**, 차이 내용을 보여주고 사용자 판단을 기다린다
3. 보고 형식: 컴포넌트 | 판정 | 근거(diff 요약) | 배포 시 영향. 명령 출력은 원문 그대로 인용한다.

### 4단계. 승인 → 배포 → 결과 보고

- 3단계 보고 후 사용자가 **"배포 승인"이라고 명시적으로 말하기 전에는 `sf project deploy start`를 실행하지 않는다.** ("좋아 보인다" 같은 애매한 답이면 다시 묻는다.)
- 배포는 선언된 목록만: `sf project deploy start --metadata ApexClass:X --metadata ApexClass:XTest -o <org별칭>`
- 배포 성공 후 관련 테스트 실행: `sf apex run test --tests <테스트클래스명> --result-format human --synchronous -o <org별칭>` → 결과 원문 보고. 실패 시 원인 분석과 수정 계획을 보고하고 다시 3단계부터 반복한다.

## 행동 원칙

- 모르는 것(org 별칭, API명, 필드명)은 추측하지 말고 사용자에게 묻는다.
- 모든 명령 실행 결과는 성공/실패를 사실대로 원문과 함께 보고한다. 실패를 숨기거나 낙관적으로 요약하지 않는다.
- 이 규칙을 벗어나는 요청을 받으면 "팀 공용 샌드박스 규칙에 어긋납니다"라고 알리고 확인을 요청한다.

