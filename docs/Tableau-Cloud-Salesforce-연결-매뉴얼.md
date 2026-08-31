# Tableau Cloud (무료) + Salesforce 연결 매뉴얼

> Tableau Desktop 없이, REST API만으로 Salesforce 데이터를 Tableau Cloud에 연결하는 절차
>
> 전제: Tableau Cloud 무료 체험판, Salesforce org 접속 가능

---

## 전체 구조

```
Salesforce org ←─ (Salesforce 커넥터, OAuth) ─→ Tableau Cloud 데이터 원본(추출)
                                                        ↑
                                                   REST API로 게시
                                                        │
로컬 PC:  데이터 원본 정의(.tds XML)  ──→  데이터 원본
          워크북 정의(.twb XML)       ──→  워크북 + 대시보드
```

핵심 흐름: **로컬에서 XML 작성 → REST API로 서버에 게시 → OAuth 수동 연결 → 추출 실행**

---

## 1. 사전 준비

### 1-1. Tableau Cloud 가입

1. https://www.tableau.com/products/cloud 에서 무료 체험 신청
2. 사이트 URL 확인 — 예: `prod-kr-a.online.tableau.com`
3. 로그인 → **내 계정 설정**에서 역할이 `Creator` 이상인지 확인
   - Creator 이상이어야 REST API 전 기능 사용 가능

### 1-2. 개인 액세스 토큰(PAT) 발급

1. Tableau Cloud → 우측 상단 프로필 → **내 계정 설정**
2. **개인용 액세스 토큰** → 토큰 이름 입력 → **새 토큰 만들기**
3. **토큰 시크릿이 표시되면 즉시 복사** — 다시 볼 수 없음

기록해둘 정보:

| 항목 | 예시 | 확인 위치 |
|---|---|---|
| 사이트 URL | `prod-kr-a.online.tableau.com` | 브라우저 주소창 |
| 사이트 ID (contentUrl) | URL 경로에서 확인 | 로그인 후 URL |
| 토큰 이름 | `my-token` | 직접 지정 |
| 토큰 시크릿 | 발급 시 1회 표시 | 복사해서 보관 |

### 1-3. Salesforce org 정보 확인

| 항목 | 확인 위치 |
|---|---|
| 내 도메인 서버 주소 | Salesforce → 설정 → 회사 정보 → 내 도메인 |
| 사용자명 (이메일) | Tableau에서 OAuth 인증에 쓸 계정 |

---

## 2. REST 인증

모든 Tableau REST 호출의 시작점. PAT로 세션 토큰을 받는다.

### 요청

```
POST https://{사이트URL}/api/3.22/auth/signin
Content-Type: application/json
```

```json
{
  "credentials": {
    "personalAccessTokenName": "{토큰이름}",
    "personalAccessTokenSecret": "{토큰시크릿}",
    "site": {
      "contentUrl": "{사이트ID}"
    }
  }
}
```

### 응답에서 추출할 값

| 값 | JSON 경로 | 용도 |
|---|---|---|
| 세션 토큰 | `credentials.token` | 이후 모든 호출의 `X-Tableau-Auth` 헤더 |
| 사이트 ID | `credentials.site.id` | REST URL 경로에 사용 |
| 사용자 ID | `credentials.user.id` | 소유자 지정 시 필요 |

> 세션 토큰은 약 2시간 유효. 만료되면(401 응답) 다시 signin 호출.

### PowerShell 예시

```powershell
$body = @{
  credentials = @{
    personalAccessTokenName   = "토큰이름"
    personalAccessTokenSecret = "토큰시크릿"
    site = @{ contentUrl = "사이트ID" }
  }
} | ConvertTo-Json -Depth 3

$resp = Invoke-RestMethod -Uri "https://$server/api/3.22/auth/signin" `
  -Method POST -ContentType 'application/json' -Body $body

$token  = $resp.credentials.token      # 이후 X-Tableau-Auth 헤더에 사용
$siteId = $resp.credentials.site.id
```

---

## 3. 데이터 원본(.tds) 작성 & 게시

### .tds란?

Tableau 데이터 원본 정의 파일. 실제 데이터는 없고 **"어디에서 어떻게 가져올지"** 만 기술하는 XML.

### XML 구조

```xml
<?xml version='1.0' encoding='utf-8'?>
<datasource formatted-name='{데이터원본이름}' inline='true' version='18.1'>
  <connection class='salesforce'
              server='{내도메인}.my.salesforce.com'
              authentication='auth-oauth'
              username='{SF사용자명}'>

    <relation join='left' type='join'>
      <clause type='join'>
        <expression op='='>
          <expression op='[Opportunity].[OwnerId]' />
          <expression op='[User].[Id]' />
        </expression>
      </clause>
      <relation type='table' name='Opportunity' table='Opportunity' />
      <relation type='table' name='User' table='User' />
    </relation>

  </connection>
</datasource>
```

핵심 속성:

| 속성 | 값 | 설명 |
|---|---|---|
| `class` | `salesforce` | Salesforce 커넥터 사용 |
| `authentication` | `auth-oauth` | OAuth 인증 (비밀번호 방식 아님) |
| `server` | 내 도메인 주소 | Salesforce org URL |
| `<relation>` | 중첩 구조 | 오브젝트 간 JOIN 관계 정의 |

> 테이블을 여러 개 조인할 때는 `<relation join='left'>` 안에 중첩해서 추가.

### REST로 게시

```
POST https://{서버}/api/3.22/sites/{siteId}/datasources?overwrite=true
Content-Type: multipart/mixed; boundary=boundary-string
X-Tableau-Auth: {세션토큰}
```

```
--boundary-string
Content-Disposition: name="request_payload"
Content-Type: text/xml

<tsRequest>
  <datasource name="{데이터원본이름}">
    <project id="{프로젝트ID}" />
  </datasource>
</tsRequest>

--boundary-string
Content-Disposition: name="tableau_datasource"; filename="{파일명}.tds"
Content-Type: application/octet-stream

{.tds 파일 내용 전체}

--boundary-string--
```

### 게시 확인

```
GET https://{서버}/api/3.22/sites/{siteId}/datasources
X-Tableau-Auth: {세션토큰}
```

응답에서 데이터 원본 이름이 보이면 성공.

---

## 4. Salesforce OAuth 자격증명 연결 (**유일한 수동 단계**)

> Salesforce는 OAuth 방식이라 REST API로 자격증명을 자동 설정할 수 없다.
> **이 단계만 사람이 웹 브라우저에서 직접 해야 한다.**

1. Tableau Cloud 웹 → **탐색** → **데이터 원본** → 방금 게시한 데이터 원본 클릭
2. **"자격증명이 필요합니다"** 경고 확인
3. **연결 편집** (또는 `⋯` 메뉴 → 연결) 클릭
4. 인증 타입: **OAuth로 로그인** 선택
5. Salesforce 로그인 팝업 → 해당 org 계정/비밀번호 입력 → **허용**
6. 연결 상태가 **녹색 체크**로 바뀌면 완료

> 데이터 원본이 여러 개면 **각각** 같은 작업 반복.

---

## 5. 추출(Extract) 새로고침

OAuth 연결 완료 후, 추출을 한 번 실행해야 실제 데이터가 채워진다.

### REST로 실행

```
POST https://{서버}/api/3.22/sites/{siteId}/datasources/{datasourceId}/refresh
X-Tableau-Auth: {세션토큰}
```

### 웹 UI에서 실행

데이터 원본 페이지 → **지금 새로고침** 클릭

> 데이터 양에 따라 수초~수분 소요. **작업** 메뉴에서 진행 상태 확인.

---

## 6. 워크북(.twb) 작성 & 게시

### .twb란?

Tableau 워크북 파일. 시트(차트), 대시보드 레이아웃, 필터, 서식을 담는 XML.
Tableau Desktop 없이 만들려면 XML을 직접 작성해야 한다.

### 핵심: 게시된 데이터 원본 참조 (sqlproxy)

워크북 안에 데이터를 직접 넣지 않고, **서버에 이미 올린 데이터 원본을 참조**한다.

```xml
<datasource caption='{데이터원본이름}' inline='true' name='sqlproxy.{고유ID}'>
  <connection class='sqlproxy'
              dbname='https://{서버}/#/site/{사이트}/datasources/{datasourceId}'
              server=''
              tablename='[sqlproxy]'
              username='' />
</datasource>
```

| 속성 | 설명 |
|---|---|
| `class='sqlproxy'` | **핵심** — 워크북엔 데이터 없이 서버의 데이터 원본만 참조 |
| `dbname` | 게시된 데이터 원본의 URL |

> `sqlproxy`를 안 쓰고 데이터를 직접 넣으면 웹 업로드 시 연결 불일치로 거부되는 경우가 많다.

### REST로 게시

```
POST https://{서버}/api/3.22/sites/{siteId}/workbooks?overwrite=true&skipConnectionCheck=true
Content-Type: multipart/mixed; boundary=boundary-string
X-Tableau-Auth: {세션토큰}
```

> **`skipConnectionCheck=true` 필수** — 없으면 연결 검사 단계에서 실패하는 경우가 많음.

multipart 구성은 데이터 원본 게시와 동일 패턴 (request_payload XML + .twb 파일).

### twb XML 작성 팁

Tableau Desktop 없이 twb를 만드는 건 문서화가 안 돼 있어서 어렵다.

**추천 방법:** Tableau Public에서 샘플 워크북(예: Superstore)을 다운로드 → .twb 파일을 열어서 구조를 역공학하며 맞춘다.

---

## 7. 확인 & 디버깅

### 서버 렌더링 이미지 확인

```
GET https://{서버}/api/3.22/sites/{siteId}/views/{viewId}/image?resolution=high
X-Tableau-Auth: {세션토큰}
```

PNG가 반환됨 → 차트가 의도대로 그려졌는지 확인.

### 빈 시트 / 수식 오류 진단

```
GET https://{서버}/api/3.22/sites/{siteId}/views/{viewId}/data
X-Tableau-Auth: {세션토큰}
```

CSV가 반환됨. **빈 데이터 = 계산 필드 수식 오류 또는 연결 문제.**

### 수정 사이클

```
1. .twb XML 수정
2. REST로 워크북 재게시 (overwrite=true)
3. REST로 뷰 이미지 다운로드 → 눈으로 확인
→ 문제 있으면 1번으로 반복
```

> 서버 렌더링 PNG와 실제 브라우저 표시가 다를 수 있다 (잘림, 클릭 필터 등).
> 최종 확인은 반드시 **브라우저에서 직접** 열어서 한다.

---

## 자주 걸리는 함정

| # | 증상 | 원인 | 해결 |
|---|---|---|---|
| 1 | 워크북 업로드 시 데이터 원본 거부 | 연결 정보 불일치 | `class='sqlproxy'`로 게시된 데이터 원본 참조 |
| 2 | 게시 시 연결 검사 실패 | 서버가 즉시 연결 확인 시도 | `skipConnectionCheck=true` 파라미터 추가 |
| 3 | twb XML 작성법을 모름 | Desktop이 원래 만들어주는 파일이라 스키마 비공개 | 샘플 워크북 다운 → 역공학 |
| 4 | OAuth 자격증명을 REST로 설정 불가 | Salesforce OAuth 정책상 제한 | 웹 UI에서 수동 연결 (4단계) |
| 5 | 추출 후에도 시트가 비어있음 | 계산 필드 수식 오류 | REST로 뷰 데이터(CSV) 조회해서 진단 |
| 6 | 서버 PNG와 브라우저 화면이 다름 | 렌더링 엔진 차이 | 최종 확인은 브라우저에서 |
| 7 | 401 Unauthorized | 세션 토큰 만료 (약 2시간) | signin 재호출 |
| 8 | API 버전 에러 | 사이트마다 지원 버전 다름 | `GET /api/2.4/serverinfo`로 최신 버전 확인 |

---

## REST API 엔드포인트 요약

| 작업 | 메서드 | 엔드포인트 |
|---|---|---|
| 로그인 | POST | `/api/3.22/auth/signin` |
| 데이터 원본 게시 | POST | `/sites/{siteId}/datasources?overwrite=true` |
| 데이터 원본 목록 | GET | `/sites/{siteId}/datasources` |
| 추출 새로고침 | POST | `/sites/{siteId}/datasources/{id}/refresh` |
| 워크북 게시 | POST | `/sites/{siteId}/workbooks?overwrite=true&skipConnectionCheck=true` |
| 뷰 이미지 | GET | `/sites/{siteId}/views/{viewId}/image` |
| 뷰 데이터 | GET | `/sites/{siteId}/views/{viewId}/data` |
| 서버 정보 | GET | `/api/2.4/serverinfo` |

> 모든 엔드포인트 앞에 `https://{사이트URL}/api/3.22` 붙임 (serverinfo 제외).
> 모든 호출에 `X-Tableau-Auth: {세션토큰}` 헤더 필요 (signin 제외).

---

## 전체 순서 체크리스트

```
□ 1. Tableau Cloud 가입 & Creator 역할 확인
□ 2. 개인 액세스 토큰(PAT) 발급 & 시크릿 보관
□ 3. Salesforce org 내 도메인 주소 & 사용자명 확인
□ 4. REST 로그인 → 세션 토큰 확보
□ 5. 데이터 원본(.tds) XML 작성
□ 6. REST로 데이터 원본 게시
□ 7. [웹 UI] Salesforce OAuth 자격증명 수동 연결  ← 유일한 수동 작업
□ 8. 추출 새로고침 실행
□ 9. 워크북(.twb) XML 작성 (sqlproxy로 데이터 원본 참조)
□ 10. REST로 워크북 게시 (skipConnectionCheck=true)
□ 11. REST로 뷰 이미지 확인 → 문제 시 9번 반복
□ 12. 브라우저에서 최종 확인
```
