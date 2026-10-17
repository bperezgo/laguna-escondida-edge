#requires -RunAsAdministrator
<#
  request-update.ps1 -- ask laguna-updater to apply the staged release, without the app.

  The fallback for when the POS itself is broken: writes the same state\update-requested.json
  the admin banner would (docs\UPDATE_PROTOCOL.md). The updater picks it up within 10 seconds.

  Run:  .\scripts\request-update.ps1
#>
$ErrorActionPreference = 'Stop'
$StateDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'state'
$availFile = Join-Path $StateDir 'update-available.json'
if (-not (Test-Path $availFile)) { throw 'No update is staged (state\update-available.json is missing).' }
$avail = Get-Content $availFile -Raw -Encoding UTF8 | ConvertFrom-Json

$req = [ordered]@{ version = "$($avail.version)"; requested_by = "console:$env:USERNAME"; requested_at = (Get-Date).ToString('o') }
$path = Join-Path $StateDir 'update-requested.json'
[IO.File]::WriteAllText("$path.tmp", ($req | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
Move-Item "$path.tmp" $path -Force
Write-Host "Requested update to $($avail.version). Follow it in logs\updater.out.log." -ForegroundColor Green
