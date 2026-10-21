#requires -RunAsAdministrator
<#
  update.ps1 -- swap ONE service to a freshly-built/fetched artifact with minimal downtime.

  App services (edge-node, next) install the GitHub Release pinned in versions.json via
  fetch-artifacts.ps1 (sha256-verified). The download + verify happens BEFORE the service is
  stopped, so downtime is only the swap. -FromSource rebuilds from the sibling repos with
  build-artifacts.ps1 instead (developer fallback). Infra services (caddy, postgres, alloy)
  are re-fetched via fetch-artifacts.ps1.

  Usage:  .\scripts\update.ps1 -Service next
          .\scripts\update.ps1 -Service edge-node
          .\scripts\update.ps1 -Service edge-node -FromSource
          .\scripts\update.ps1 -Service alloy
#>
param(
  [Parameter(Mandatory)]
  [ValidateSet('edge-node','next','caddy','postgres','alloy')]
  [string] $Service,
  [switch] $FromSource
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$exe  = Join-Path (Join-Path $Root 'services') "$Service.exe"
if (-not (Test-Path $exe)) { throw "$Service is not installed. Run install.ps1 first." }

$isApp   = $Service -in 'edge-node','next'
$fetch   = Join-Path $PSScriptRoot 'fetch-artifacts.ps1'
if ($isApp -and -not $FromSource) {
  # Fail here (checksum, bad pin, no network) while the service is still running.
  Write-Host "Downloading + verifying the $Service release ..."
  & $fetch -Only $Service -DownloadOnly
}

# Stopping a service also stops its running dependents (caddy -> next -> edge-node -> postgres),
# and starting it does not bring them back. Stop them explicitly, dependents first, and
# restart everything that was running afterwards, in dependency order.
$startOrder = 'postgres','edge-node','next','caddy'
$i = [array]::IndexOf($startOrder, $Service)
$chain = if ($i -ge 0) { @($startOrder[$i..($startOrder.Count - 1)]) } else { @($Service) }
$wasRunning = @($chain | Where-Object { (Get-Service "laguna-$_" -ErrorAction SilentlyContinue).Status -eq 'Running' })
[array]::Reverse($chain)
foreach ($name in $chain) {
  $svc = Get-Service "laguna-$name" -ErrorAction SilentlyContinue
  if (-not $svc -or $svc.Status -eq 'Stopped') { continue }
  Write-Host "Stopping laguna-$name ..."
  & sc.exe stop "laguna-$name" | Out-Null
  $svc.WaitForStatus('Stopped', (New-TimeSpan -Seconds 30))
}

if ($isApp -and $FromSource) {
  Write-Host "Rebuilding $Service from source ..."
  & (Join-Path $PSScriptRoot 'build-artifacts.ps1') -Only $Service
} elseif ($isApp) {
  Write-Host "Installing the staged $Service release ..."
  & $fetch -Only $Service -Force
} else {
  Write-Host "Re-fetching $Service binary ..."
  & $fetch -Only $Service -Force
}

# edge-node reads its config from a .env next to the exe; refresh it in case it changed.
if ($Service -eq 'edge-node') {
  $envSrc = Join-Path $Root 'env\edge-node.env'
  if (Test-Path $envSrc) { Copy-Item $envSrc (Join-Path $Root 'artifacts\edge-node\.env') -Force }
}

# Alloy reads alloy\config.alloy live, but its per-box settings are MACHINE env vars that
# only install.ps1 writes. Validate the config here; re-run install.ps1 to apply env edits.
if ($Service -eq 'alloy') {
  & (Join-Path $Root 'artifacts\alloy\alloy.exe') validate --stability.level=public-preview (Join-Path $Root 'alloy\config.alloy') | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "alloy\config.alloy failed validation; not restarting the sidecar." }
}

foreach ($name in $startOrder + @('alloy')) {
  if ($name -ne $Service -and $wasRunning -notcontains $name) { continue }
  Write-Host "Starting laguna-$name ..."
  Start-Service "laguna-$name"
}
Write-Host "Updated $Service."
