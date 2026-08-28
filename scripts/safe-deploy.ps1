<#
.SYNOPSIS
    org-우선 충돌 차단 배포 래퍼. 낡은 로컬로 팀원 작업을 덮어쓰는 것을 기계적으로 불가능하게 만든다.

.DESCRIPTION
    AGENTS.md 3단계(배포 전 검증)를 자동화한다.
    배포 직전에 org의 "현재본"을 임시 프로젝트로 다시 받아, 배포 대상 컴포넌트마다 3-way 비교를 한다:
        ORG   = 지금 org에 있는 내용
        BASE  = git HEAD (내 baseline)
        LOCAL = 내 로컬 작업본(배포하려는 내용)
    판정:
        ORG == BASE   -> org가 내 baseline 그대로 = 아무도 안 건드림 -> 안전
        ORG == LOCAL  -> 배포해도 org 내용 안 바뀜(내가 이미 org와 동일) -> 안전
        그 외         -> retrieve 이후 제3자가 org에서 이 컴포넌트를 바꿈 -> 충돌 -> 배포 중단
    충돌이 하나라도 있으면 배포하지 않고 종료(exit 2). 낡은 로컬 배포가 원천 차단된다.

.PARAMETER Metadata
    배포할 컴포넌트. 유형:API명 형식. 여러 개 반복 지정. 예: ApexClass:Foo, ApexClass:FooTest

.PARAMETER TargetOrg
    org 별칭. 생략 시 sf 기본 target-org 사용.

.PARAMETER AcknowledgeOrgChanges
    충돌이 감지돼도 배포를 강행. 자동이 아닌, 사람이 org 변경을 직접 검토·병합했다고 명시적으로 선언하는 안전밸브.
    (AGENTS.md상 이 경우 사용자에게 diff를 보이고 명시 승인을 받아야 함.)

.PARAMETER SelfTest
    org 없이 3-way 판정 로직만 합성 데이터로 검증하고 종료.

.EXAMPLE
    pwsh scripts/safe-deploy.ps1 -Metadata ApexClass:MaskingService,ApexClass:MaskingServiceTest
#>
[CmdletBinding()]
param(
    [string[]] $Metadata,
    [string]   $TargetOrg,
    [switch]   $AcknowledgeOrgChanges,
    [switch]   $SelfTest
)

$ErrorActionPreference = 'Stop'

# 배포 허용 유형 (AGENTS.md 절대 금지 #2). 그 외 유형은 기계적으로 차단.
$AllowedTypes = @('ApexClass','ApexTrigger','LightningComponentBundle','StaticResource','CustomField')

function Norm($text) {
    if ($null -eq $text) { return $null }
    return ([string]$text -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
}

# 3-way 판정: 'safe-new' | 'safe-unchanged' | 'safe-noop' | 'CONFLICT'
function Get-Verdict($orgText, $baseText, $localText) {
    $o = Norm $orgText; $b = Norm $baseText; $l = Norm $localText
    if ($null -eq $o)  { return 'safe-new' }        # org에 없음 -> 신규 -> 덮어쓸 게 없음
    if ($o -eq $b)     { return 'safe-unchanged' }  # org == baseline -> 제3자 변경 없음
    if ($o -eq $l)     { return 'safe-noop' }       # org == 내 로컬 -> 배포해도 안 바뀜
    return 'CONFLICT'                                # org가 baseline과도 로컬과도 다름 -> 제3자 변경
}

if ($SelfTest) {
    $cases = @(
        @{ n='org==base (아무도 안 건드림)';     o='A'; b='A'; l='B'; exp='safe-unchanged' },
        @{ n='org==local (이미 동일)';           o='B'; b='A'; l='B'; exp='safe-noop' },
        @{ n='org 없음 (신규)';                  o=$null; b=$null; l='B'; exp='safe-new' },
        @{ n='제3자 변경 (충돌)';                o='C'; b='A'; l='B'; exp='CONFLICT' },
        @{ n='내가 안 건드린 파일, org만 변경';  o='C'; b='A'; l='A'; exp='CONFLICT' },
        @{ n='공백만 다름 (정상)';               o="A`r`n"; b='A'; l='B'; exp='safe-unchanged' }
    )
    $fail = 0
    foreach ($c in $cases) {
        $got = Get-Verdict $c.o $c.b $c.l
        $ok  = ($got -eq $c.exp)
        if (-not $ok) { $fail++ }
        "{0}  {1,-28} 기대={2,-14} 실제={3}" -f $(if($ok){'PASS'}else{'FAIL'}), $c.n, $c.exp, $got | Write-Host
    }
    if ($fail -gt 0) { Write-Host "SelfTest 실패 $fail건" -ForegroundColor Red; exit 1 }
    Write-Host "SelfTest 전부 통과" -ForegroundColor Green
    exit 0
}

if (-not $Metadata -or $Metadata.Count -eq 0) {
    Write-Host "사용법: safe-deploy.ps1 -Metadata ApexClass:Foo,ApexClass:FooTest [-TargetOrg born-org]" -ForegroundColor Yellow
    exit 64
}

# repo 루트
$RepoRoot = (& git rev-parse --show-toplevel 2>$null)
if (-not $RepoRoot) { Write-Host "git 저장소가 아닙니다." -ForegroundColor Red; exit 1 }
$RepoRoot = $RepoRoot.Trim()

# org 별칭
if (-not $TargetOrg) {
    $cfg = & sf config get target-org --json | ConvertFrom-Json
    $TargetOrg = $cfg.result[0].value
}
if (-not $TargetOrg) { Write-Host "target-org를 확인할 수 없습니다. -TargetOrg로 지정하세요." -ForegroundColor Red; exit 1 }

# 유형 허용 검사
$badTypes = @()
foreach ($m in $Metadata) {
    $type = ($m -split ':',2)[0].Trim()
    if ($AllowedTypes -notcontains $type) { $badTypes += $m }
}
if ($badTypes.Count -gt 0) {
    Write-Host "배포 금지 유형이 포함됨 (AGENTS.md 규칙): $($badTypes -join ', ')" -ForegroundColor Red
    Write-Host "deploy 허용 유형: $($AllowedTypes -join ', ')" -ForegroundColor Yellow
    exit 3
}

Write-Host "==> org-우선 충돌 검증 (org=$TargetOrg)" -ForegroundColor Cyan
Write-Host "    대상: $($Metadata -join ', ')"

# org 현재본을 임시 source 프로젝트로 retrieve (로컬 작업본을 절대 건드리지 않음)
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("safe-deploy-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
try {
    Copy-Item (Join-Path $RepoRoot 'sfdx-project.json') (Join-Path $TempRoot 'sfdx-project.json')

    # sfdx-project.json 의 packageDirectories 를 임시 프로젝트에도 생성한다.
    # (sf CLI 는 retrieve 전에 이 경로 존재를 검사하므로, 없으면 MissingPackageDirectoryError 로 검증이 실패한다.)
    $pkgDirs = (Get-Content -Raw (Join-Path $RepoRoot 'sfdx-project.json') | ConvertFrom-Json).packageDirectories
    foreach ($pd in $pkgDirs) { New-Item -ItemType Directory -Path (Join-Path $TempRoot $pd.path) -Force | Out-Null }

    $mdArgs = @()
    foreach ($m in $Metadata) { $mdArgs += @('--metadata', $m) }

    Push-Location $TempRoot
    try {
        Write-Host "==> org 현재본 조회 중..." -ForegroundColor Cyan
        $retrieveJson = & sf project retrieve start @mdArgs --target-org $TargetOrg --json
        $retrieve = $retrieveJson | ConvertFrom-Json
        if ($retrieve.status -ne 0) {
            Write-Host "retrieve 실패 — 검증 불가이므로 배포 중단." -ForegroundColor Red
            Write-Host $retrieveJson
            exit 1
        }
    } finally {
        Pop-Location
    }

    # 임시본(=ORG)의 각 파일을 repo baseline(HEAD)/로컬과 3-way 비교
    $tempForceApp = Join-Path $TempRoot 'force-app'
    $conflicts = @()
    $report    = @()

    if (Test-Path $tempForceApp) {
        $orgFiles = Get-ChildItem -Path $tempForceApp -Recurse -File
        foreach ($f in $orgFiles) {
            $rel = $f.FullName.Substring($TempRoot.Length).TrimStart('\','/') -replace '\\','/'
            $orgText = Get-Content -Raw -Encoding UTF8 -LiteralPath $f.FullName

            $localPath = Join-Path $RepoRoot $rel
            $localText = if (Test-Path -LiteralPath $localPath) { Get-Content -Raw -Encoding UTF8 -LiteralPath $localPath } else { $null }

            $baseText = & git -C $RepoRoot show "HEAD:$rel" 2>$null
            if ($LASTEXITCODE -ne 0) { $baseText = $null }
            if ($baseText -is [array]) { $baseText = $baseText -join "`n" }

            $verdict = Get-Verdict $orgText $baseText $localText
            $report += [pscustomobject]@{ File=$rel; Verdict=$verdict }
            if ($verdict -eq 'CONFLICT') { $conflicts += $rel }
        }
    }

    Write-Host ""
    Write-Host "==> 검증 결과" -ForegroundColor Cyan
    foreach ($r in $report) {
        $color = if ($r.Verdict -eq 'CONFLICT') { 'Red' } else { 'Green' }
        Write-Host ("    [{0,-14}] {1}" -f $r.Verdict, $r.File) -ForegroundColor $color
    }

    if ($conflicts.Count -gt 0) {
        Write-Host ""
        Write-Host "🚨 충돌 감지 — retrieve 이후 org에서 다음 컴포넌트가 제3자에 의해 변경됨:" -ForegroundColor Red
        foreach ($c in $conflicts) { Write-Host "    - $c" -ForegroundColor Red }
        Write-Host ""
        Write-Host "지금 배포하면 그 작업을 덮어씁니다. 먼저 org 변경을 retrieve해서 병합하세요:" -ForegroundColor Yellow
        Write-Host "    sf project retrieve start $($mdArgs -join ' ') -o $TargetOrg" -ForegroundColor Yellow
        if (-not $AcknowledgeOrgChanges) {
            Write-Host ""
            Write-Host "배포를 중단합니다. (검토·병합을 마쳤다면 -AcknowledgeOrgChanges 로만 강행 가능)" -ForegroundColor Red
            exit 2
        }
        Write-Host ""
        Write-Host "-AcknowledgeOrgChanges 지정됨 — 사용자가 org 변경 검토를 선언하고 강행합니다." -ForegroundColor Yellow
    }

    # 여기까지 왔으면 안전 — 실제 배포
    Write-Host ""
    Write-Host "==> 충돌 없음. 배포 실행" -ForegroundColor Green
    Push-Location $RepoRoot
    try {
        & sf project deploy start @mdArgs --target-org $TargetOrg
        $deployExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    exit $deployExit
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $TempRoot -ErrorAction SilentlyContinue
}
