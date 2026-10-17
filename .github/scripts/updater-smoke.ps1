<#
  updater-smoke.ps1 -- CI test of laguna-updater against a locally built, signed release.

  Builds release v9.9.9 from the install root (same app pins, plus one new file), signs its
  manifest with the throwaway key the workflow generated, and checks that the updater:
    - ignores a tampered manifest,
    - stages the signed one and offers it (update-available.json),
    - applies it only once requested, and records installed.json + a success result,
    - then reports itself up to date.
  The laguna-updater service is stopped meanwhile so it cannot race the -Once runs.
#>
param(
  [string] $Root = 'C:\laguna-edge',
  [string] $Work = 'C:\updater-test'
)
$ErrorActionPreference = 'Stop'
$minisign = Join-Path $Root 'artifacts\minisign\minisign.exe'
$state    = Join-Path $Root 'state'
$pub      = Join-Path $Root 'updater\minisign.pub'
$key      = Join-Path $Work 'test.key'
$ver      = 'v9.9.9'

function Check($cond, $what) {
  if (-not $cond) { throw "FAIL: $what" }
  Write-Host "  ok   $what" -ForegroundColor Green
}
function Read-State($name) {
  $f = Join-Path $state $name
  if (Test-Path $f) { return (Get-Content $f -Raw | ConvertFrom-Json) }
  return $null
}
function Invoke-Updater($manifest) {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'updater\laguna-updater.ps1') `
    -Once -ManifestUrl $manifest -PublicKeyFile $pub | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "laguna-updater.ps1 exited $LASTEXITCODE" }
}
function Sha($f) { (Get-FileHash $f -Algorithm SHA256).Hash.ToLower() }

Stop-Service laguna-updater -ErrorAction SilentlyContinue
Remove-Item (Join-Path $state 'update-*.json'), (Join-Path $state 'installed.json') -ErrorAction SilentlyContinue

$pins = Get-Content (Join-Path $Root 'versions.json') -Raw | ConvertFrom-Json
$en = "$($pins.artifacts.'edge-node'.version)"
$nx = "$($pins.artifacts.next.version)"
$enZip = Join-Path $Root "artifacts\.cache\edge-node-windows-amd64-$en.zip"
$nxZip = Join-Path $Root "artifacts\.cache\next-standalone-windows-$nx.zip"
Check ((Test-Path $enZip) -and (Test-Path $nxZip)) "cached app releases $en / $nx"

Write-Host "`n==> Build + sign $ver"
$src = Join-Path $Work 'edge'
if (Test-Path $src) { Remove-Item $src -Recurse -Force }
New-Item -ItemType Directory -Force -Path $src | Out-Null
git -C $env:GITHUB_WORKSPACE archive --format=zip -o (Join-Path $Work 'src.zip') HEAD
Expand-Archive (Join-Path $Work 'src.zip') $src -Force
'written by the updater smoke test' | Set-Content (Join-Path $src 'docs\UPDATER_SMOKE.txt')

$pins | Add-Member appliance_version $ver -Force
$pins.artifacts.'edge-node' | Add-Member sha256 (Sha $enZip) -Force
$pins.artifacts.next        | Add-Member sha256 (Sha $nxZip) -Force
$pins | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $src 'versions.json') -Encoding utf8
$edgeZip = Join-Path $Work "edge-$ver.zip"
Compress-Archive -Path (Join-Path $src '*') -DestinationPath $edgeZip -Force

$manifest = [ordered]@{
  appliance_version = $ver
  published_at      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  components        = [ordered]@{
    edge        = [ordered]@{ tag = $ver; url = $edgeZip; sha256 = (Sha $edgeZip) }
    'edge-node' = [ordered]@{ tag = $en;  url = $enZip;   sha256 = (Sha $enZip) }
    next        = [ordered]@{ tag = $nx;  url = $nxZip;   sha256 = (Sha $nxZip) }
  }
  infra = [ordered]@{ winsw = $pins.winsw; caddy = $pins.caddy; alloy = $pins.alloy; node = $pins.node; postgres = $pins.postgres }
}
$mfile = Join-Path $Work 'manifest.json'
$manifest | ConvertTo-Json -Depth 6 | Set-Content $mfile -Encoding utf8
& $minisign -S -s $key -m $mfile -t "ci $ver" | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'signing failed' }

Write-Host "`n==> A tampered manifest is ignored"
$bad = Join-Path $Work 'tampered\manifest.json'
New-Item -ItemType Directory -Force -Path (Split-Path $bad) | Out-Null
(Get-Content $mfile -Raw).Replace($nx, 'v0.0.1') | Set-Content $bad -Encoding utf8
Copy-Item "$mfile.minisig" "$bad.minisig"
Invoke-Updater $bad
Check (-not (Read-State 'update-available.json')) 'no update offered for a bad signature'

Write-Host "`n==> The signed release is staged and offered"
Invoke-Updater $mfile
$avail = Read-State 'update-available.json'
Check ($avail -and $avail.version -eq $ver) "update-available.json offers $ver"
Check (-not (Test-Path (Join-Path $Root 'docs\UPDATER_SMOKE.txt'))) 'nothing applied without a request'

Write-Host "`n==> Applied on request"
& (Join-Path $Root 'scripts\request-update.ps1')
Invoke-Updater $mfile
$result = Read-State 'update-result.json'
Check ($result -and $result.outcome -eq 'success' -and $result.version -eq $ver) "update-result.json: success $ver ($($result.message))"
Check ((Read-State 'installed.json').version -eq $ver) "installed.json = $ver"
Check (-not (Read-State 'update-available.json')) 'offer cleared'
Check (-not (Read-State 'update-requested.json')) 'request consumed'
Check (Test-Path (Join-Path $Root 'docs\UPDATER_SMOKE.txt')) 'release files copied in'
Check ((Get-Content (Join-Path $Root 'env\edge-node.env') -Raw) -notmatch 'written by the updater') 'per-box env untouched'

Write-Host "`n==> Up to date afterwards"
Invoke-Updater $mfile
Check (-not (Read-State 'update-available.json')) 'no offer for the installed version'

& (Join-Path $Root 'scripts\verify-install.ps1')
if ($LASTEXITCODE -ne 0) { throw 'verify-install failed after the updater apply' }
Start-Service laguna-updater
Write-Host "`nUpdater smoke test passed." -ForegroundColor Green
