<#
  verify-install.ps1 -- automated "is the box serving?" check after an install or update.
  The scripted subset of docs\VALIDATION.md, bottom-up so the first failure names the layer:

    1. every laguna-* service is Running
    2. edge-node answers /api/edge/status in edge mode, running the pinned release
    3. Next answers on 127.0.0.1:3000
    4. Caddy serves HTTPS on LAGUNA_LAN_IP (and LAGUNA_LAN_HOST, if set) with a cert this box
       trusts, redirects are relative (no localhost:3000 leak), and :80 redirects to https

  Exits non-zero on the first failing layer. Used by .github\workflows\install-smoke.yml on a
  Windows runner, and safe to run on a real box (read-only).

  Run:  .\scripts\verify-install.ps1
        .\scripts\verify-install.ps1 -TimeoutSeconds 300     # slow first boot (migrations)
        .\scripts\verify-install.ps1 -ExpectedVersion v1.1.17  # after a rollback
#>
[CmdletBinding()]
param(
  # How long to wait for each layer to come up (edge-node runs migrations on first boot).
  [int] $TimeoutSeconds = 180,
  # The edge-node version that must be running. Default: the versions.json pin.
  [string] $ExpectedVersion,
  # Skip the version check (e.g. back on a local build after a rollback).
  [switch] $AnyVersion
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$script:failures = 0

function Step($m) { Write-Host ("`n==> " + $m) -ForegroundColor Cyan }
function Pass($m) { Write-Host "  ok   $m" -ForegroundColor Green }
function Fail($m) { Write-Host "  FAIL $m" -ForegroundColor Red; $script:failures++ }

# Retry a scriptblock until it returns $true or the timeout passes.
function Wait-Until([scriptblock] $probe, [int] $seconds = $TimeoutSeconds) {
  $deadline = (Get-Date).AddSeconds($seconds)
  do {
    try { if (& $probe) { return $true } } catch {}
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  return $false
}

# curl.exe (not the PowerShell alias): returns "<http_code> <redirect_url>". --ssl-no-revoke
# because Caddy's internal CA publishes no CRL/OCSP endpoint, which Schannel would otherwise
# treat as a failure. No -k: the cert must chain to a root this box trusts.
function Get-Http([string] $url, [string[]] $extra = @()) {
  $out = & curl.exe -s -o NUL --max-time 10 --ssl-no-revoke @extra -w '%{http_code} %{redirect_url}' $url 2>&1
  return "$out".Trim()
}

function Stop-OnFailure($layer) {
  if ($script:failures) {
    Write-Host "`n$layer failed -- stopping here. Check logs\ for that service." -ForegroundColor Red
    exit 1
  }
}

# --- box identity -----------------------------------------------------------------
$box = @{}
foreach ($line in Get-Content (Join-Path $Root 'env\box.env')) {
  $t = $line.Trim()
  if (-not $t -or $t.StartsWith('#')) { continue }
  $kv = $t -split '=', 2
  if ($kv.Count -eq 2) { $box[$kv[0].Trim()] = $kv[1].Trim() }
}
$LanIp   = $box['LAGUNA_LAN_IP']
$LanHost = if ($box['LAGUNA_LAN_HOST']) { ($box['LAGUNA_LAN_HOST'] -split ',')[0].Trim() } else { $null }
$pins    = (Get-Content (Join-Path $Root 'versions.json') -Raw | ConvertFrom-Json).artifacts

# --- 1. services --------------------------------------------------------------------
Step "Services"
$expected = 'laguna-postgres','laguna-edge-node','laguna-next','laguna-caddy'
foreach ($opt in 'laguna-alloy','laguna-updater') {
  if (Get-Service $opt -ErrorAction SilentlyContinue) { $expected += $opt }
}
foreach ($svc in $expected) {
  $ok = Wait-Until { (Get-Service $svc -ErrorAction SilentlyContinue).Status -eq 'Running' } 60
  if ($ok) { Pass "$svc Running" } else { Fail "$svc is '$((Get-Service $svc -ErrorAction SilentlyContinue).Status)'" }
}
Stop-OnFailure 'Services'

# --- 2. edge-node -------------------------------------------------------------------
Step "edge-node (127.0.0.1:8080)"
$status = $null
$ok = Wait-Until { $script:status = Invoke-RestMethod http://127.0.0.1:8080/api/edge/status -TimeoutSec 5; $true }
if (-not $ok) {
  Fail "/api/edge/status did not answer within ${TimeoutSeconds}s"
} else {
  Pass "/api/edge/status answers (online=$($status.online), pending_sync_ops=$($status.pending_sync_ops))"
  if ($status.mode -eq 'edge') { Pass "mode = edge" } else { Fail "mode = '$($status.mode)', expected edge" }

  $installed = $null
  $relFile = Join-Path $Root 'artifacts\edge-node\RELEASE'
  if (Test-Path $relFile) { $installed = (Get-Content $relFile -Raw).Trim() }
  $want = if ($ExpectedVersion) { $ExpectedVersion } else { "$($pins.'edge-node'.version)" }
  if ($AnyVersion) {
    Write-Host "  note version = $($status.version) (not checked: -AnyVersion)" -ForegroundColor Yellow
  } elseif ($installed -like 'local-*') {
    Write-Host "  note local build installed ($installed); not checking against versions.json" -ForegroundColor Yellow
  } elseif ($status.version -eq $want) {
    Pass "version = $($status.version) (expected)"
  } else {
    Fail "version = '$($status.version)', expected '$want'"
  }
}
Stop-OnFailure 'edge-node'

# --- 3. next --------------------------------------------------------------------------
Step "next (127.0.0.1:3000)"
$ok = Wait-Until { (Get-Http 'http://127.0.0.1:3000/favicon.ico') -like '200*' }
if ($ok) { Pass "serves static files" } else { Fail "http://127.0.0.1:3000/favicon.ico -> $(Get-Http 'http://127.0.0.1:3000/favicon.ico')" }
Stop-OnFailure 'next'

# --- 4. caddy (LAN HTTPS) -------------------------------------------------------------
Step "caddy (https://$LanIp$(if ($LanHost) { " and https://$LanHost" }))"
$targets = @(@{ name = $LanIp; url = "https://$LanIp"; extra = @() })
if ($LanHost) {
  # --resolve: test the hostname's cert/SAN without depending on the LAN's DNS.
  $targets += @{ name = $LanHost; url = "https://$LanHost"; extra = @('--resolve', "${LanHost}:443:$LanIp") }
}
foreach ($t in $targets) {
  $ok = Wait-Until { (Get-Http "$($t.url)/favicon.ico" $t.extra) -like '200*' } 60
  if ($ok) { Pass "$($t.name): HTTPS 200 with a trusted cert" }
  else { Fail "$($t.name): $($t.url)/favicon.ico -> '$(Get-Http "$($t.url)/favicon.ico" $t.extra)' (000 = TLS/connection failure)" }

  $r = (Get-Http "$($t.url)/" $t.extra) -split ' ', 2
  $code = [int]$r[0]
  if ($code -ge 200 -and $code -lt 400) { Pass "$($t.name): GET / -> $code" } else { Fail "$($t.name): GET / -> $code" }
  if ($r.Count -gt 1 -and $r[1] -match 'localhost:3000') {
    Fail "$($t.name): redirect leaks the internal origin ($($r[1])) -- Caddyfile header_down rewrite"
  } elseif ($r.Count -gt 1 -and $r[1]) {
    Pass "$($t.name): redirect stays on the public host ($($r[1]))"
  }
}
$r = (Get-Http "http://$LanIp/") -split ' ', 2
if ([int]$r[0] -ge 300 -and [int]$r[0] -lt 400 -and $r[1] -like 'https://*') { Pass "http://$LanIp -> $($r[1])" }
else { Fail "http://$LanIp/ -> '$($r -join ' ')', expected a redirect to https" }
Stop-OnFailure 'caddy'

Write-Host "`nAll checks passed." -ForegroundColor Green
