[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$server = "prod-kr-a.online.tableau.com"
$contentUrl = "sangyoon0617-2d3b3f4c03"
$sfServer = "trailsignup-6e973b0119b58d.my.salesforce.com"
$sfUser = "pl_hj@aicrm2group3.com"

# --- Step 1: REST Login ---
Write-Host "=== Step 1: Tableau REST Login ==="

$signInJson = '{"credentials":{"personalAccessTokenName":"김환진","personalAccessTokenSecret":"lmM1NxAlSDW3F9AT29vO0w==:3WaEkcDDwd5jRtT2enFnb8vb7rEK7Guj","site":{"contentUrl":"sangyoon0617-2d3b3f4c03"}}}'
$signInBytes = [System.Text.Encoding]::UTF8.GetBytes($signInJson)

try {
    $signInResp = Invoke-WebRequest -Uri "https://$server/api/3.22/auth/signin" `
        -Method POST -ContentType "application/json; charset=utf-8" `
        -Body $signInBytes -UseBasicParsing
} catch {
    Write-Host "Login failed: $($_.Exception.Message)"
    if ($_.Exception.Response) {
        $stream = $_.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $errBody = $reader.ReadToEnd()
        Write-Host $errBody
    }
    exit 1
}

[xml]$signInXml = $signInResp.Content
$token  = $signInXml.tsResponse.credentials.token
$siteId = $signInXml.tsResponse.credentials.site.id
$userId = $signInXml.tsResponse.credentials.user.id

Write-Host "  Token: $($token.Substring(0,20))..."
Write-Host "  Site ID: $siteId"
Write-Host "  User ID: $userId"

$headers = @{ "X-Tableau-Auth" = $token }

# --- Step 2: Get Default Project ---
Write-Host "`n=== Step 2: Get Default Project ==="

$projResp = Invoke-WebRequest -Uri "https://$server/api/3.22/sites/$siteId/projects" `
    -Method GET -Headers $headers -UseBasicParsing
[xml]$projXml = $projResp.Content

$defaultProject = $projXml.tsResponse.projects.project | Where-Object { $_.name -eq "default" }
$projectId = $defaultProject.id
Write-Host "  Project ID: $projectId"

# --- Helper function for multipart publish ---
function Publish-Datasource {
    param($dsName, $tdsContent)

    $boundary = "boundary-tableau-$dsName"

    $reqPayload = "<tsRequest><datasource name=`"$dsName`"><project id=`"$projectId`" /></datasource></tsRequest>"

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("--$boundary")
    [void]$sb.AppendLine('Content-Disposition: name="request_payload"')
    [void]$sb.AppendLine("Content-Type: text/xml")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine($reqPayload)
    [void]$sb.AppendLine("--$boundary")
    [void]$sb.AppendLine("Content-Disposition: name=`"tableau_datasource`"; filename=`"$dsName.tds`"")
    [void]$sb.AppendLine("Content-Type: application/octet-stream")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine($tdsContent)
    [void]$sb.Append("--$boundary--")

    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())

    try {
        $resp = Invoke-WebRequest `
            -Uri "https://$server/api/3.22/sites/$siteId/datasources?overwrite=true" `
            -Method POST `
            -Headers $headers `
            -ContentType "multipart/mixed; boundary=$boundary" `
            -Body $bodyBytes `
            -UseBasicParsing
        [xml]$xml = $resp.Content
        $dsId = $xml.tsResponse.datasource.id
        Write-Host "  $dsName published! ID: $dsId"
        return $dsId
    } catch {
        Write-Host "  ERROR publishing $dsName : $($_.Exception.Message)"
        if ($_.Exception.Response) {
            $stream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            Write-Host $reader.ReadToEnd()
        }
        return $null
    }
}

# --- Step 3: Publish RM_Pipeline (Opportunity + User + Account) ---
Write-Host "`n=== Step 3: Publish RM_Pipeline ==="

$tds1 = @"
<?xml version='1.0' encoding='utf-8'?>
<datasource formatted-name='RM_Pipeline' inline='true' version='18.1'>
  <connection class='salesforce'
              server='$sfServer'
              authentication='auth-oauth'
              username='$sfUser'>
    <relation join='left' type='join'>
      <clause type='join'>
        <expression op='='>
          <expression op='[Opportunity].[AccountId]' />
          <expression op='[Account].[Id]' />
        </expression>
      </clause>
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
      <relation type='table' name='Account' table='Account' />
    </relation>
  </connection>
</datasource>
"@

$dsId1 = Publish-Datasource -dsName "RM_Pipeline" -tdsContent $tds1

# --- Step 4: Publish RM_Activity (Task + User) ---
Write-Host "`n=== Step 4: Publish RM_Activity ==="

$tds2 = @"
<?xml version='1.0' encoding='utf-8'?>
<datasource formatted-name='RM_Activity' inline='true' version='18.1'>
  <connection class='salesforce'
              server='$sfServer'
              authentication='auth-oauth'
              username='$sfUser'>
    <relation join='left' type='join'>
      <clause type='join'>
        <expression op='='>
          <expression op='[Task].[OwnerId]' />
          <expression op='[User].[Id]' />
        </expression>
      </clause>
      <relation type='table' name='Task' table='Task' />
      <relation type='table' name='User' table='User' />
    </relation>
  </connection>
</datasource>
"@

$dsId2 = Publish-Datasource -dsName "RM_Activity" -tdsContent $tds2

# --- Step 5: Verify ---
Write-Host "`n=== Step 5: Verify Published Datasources ==="

$verifyResp = Invoke-WebRequest -Uri "https://$server/api/3.22/sites/$siteId/datasources" `
    -Method GET -Headers $headers -UseBasicParsing
[xml]$verifyXml = $verifyResp.Content

foreach ($ds in $verifyXml.tsResponse.datasources.datasource) {
    Write-Host "  - $($ds.name) (ID: $($ds.id))"
}

# --- Summary ---
Write-Host "`n========================================="
Write-Host "  COMPLETE - Datasources published!"
Write-Host "========================================="
Write-Host ""
Write-Host ">> NEXT: Manual OAuth step (one-time) <<"
Write-Host "1. Open: https://$server/#/site/$contentUrl/datasources"
Write-Host "2. Click 'RM_Pipeline' -> Edit Connection -> Sign in with OAuth -> Salesforce login"
Write-Host "3. Click 'RM_Activity' -> Same steps"
Write-Host "4. Click 'Refresh Now' on each datasource"
