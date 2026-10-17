<#
  build-artifacts.ps1 -- build the APP artifacts LOCALLY from the sibling app repos into
  artifacts\. For a single-site install this is simpler than CI/release downloads.

    * edge-node  -> artifacts\edge-node\edge-node.exe   (Go; migrations embedded in the binary)
    * next       -> artifacts\next\server.js (+ .next\static, public, minimal node_modules)

  Off-the-shelf binaries (Caddy, Node, Postgres) come from scripts\fetch-artifacts.ps1, not here.

  DEVELOPER FALLBACK: production boxes install CI-built GitHub Releases with
  scripts\fetch-artifacts.ps1. Use this only to run unreleased code.

  Run:  .\scripts\build-artifacts.ps1                         # build both
        .\scripts\build-artifacts.ps1 -Only edge-node         # just one
        .\scripts\build-artifacts.ps1 -BackendRepo C:\src\be -FrontendRepo C:\src\fe

  Pre-reqs on the build box: Go and pnpm on PATH (Node is bundled separately for runtime).
#>
[CmdletBinding()]
param(
  [ValidateSet('edge-node','next')]
  [string[]] $Only = @('edge-node','next'),

  # Source repos. Default: siblings of this repo's parent folder.
  [string] $BackendRepo,
  [string] $FrontendRepo,

  # Baked into the Next build; used server-side only.
  [string] $BackendApiUrl = 'http://127.0.0.1:8080/api'
)

$ErrorActionPreference = 'Stop'
$Root      = Split-Path -Parent $PSScriptRoot
$Artifacts = Join-Path $Root 'artifacts'
$Parent    = Split-Path -Parent $Root
if (-not $BackendRepo)  { $BackendRepo  = Join-Path $Parent 'laguna-escondida-backend' }
if (-not $FrontendRepo) { $FrontendRepo = Join-Path $Parent 'laguna-escondida-frontend' }

function Want($n) { $Only -contains $n }
function Step($m) { Write-Host ("`n==> " + $m) -ForegroundColor Cyan }

# Through cmd so PowerShell 5.1 doesn't turn native stderr into a terminating error.
function Run($cmdLine, $what) {
  & cmd /c "$cmdLine 2>&1" | ForEach-Object { Write-Host $_ }
  if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE)" }
}

# `next build` standalone needs symlinks: elevation or Developer Mode. Checked directly because
# a New-Item symlink probe fails under Developer Mode even though Node's symlink works.
function Test-SymlinkCapability {
  $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if ($elevated) { return $true }
  $dev = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
  return ($dev -eq 1)
}
function GitSha($repo) {
  try { $s = (& git -C $repo rev-parse --short HEAD 2>$null); if ($LASTEXITCODE -eq 0) { return $s.Trim() } } catch {}
  return 'unknown'
}
function Read-DotEnv($path) {
  $map = [ordered]@{}
  if (-not (Test-Path $path)) { return $map }
  foreach ($line in Get-Content $path) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith('#')) { continue }
    $kv = $t -split '=', 2
    if ($kv.Count -eq 2) { $map[$kv[0].Trim()] = $kv[1].Trim() }
  }
  return $map
}
# "local-<sha>" never matches a pinned tag, so fetch-artifacts.ps1 replaces it on its next run.
function Stamp($key, $sha) {
  Set-Content (Join-Path (Join-Path $Artifacts $key) 'RELEASE') "local-$sha" -Encoding ascii
}

# --- edge-node (Go) ----------------------------------------------------------------
if (Want 'edge-node') {
  Step "Building edge-node.exe (Go) from $BackendRepo"
  if (-not (Test-Path (Join-Path $BackendRepo 'cmd\main.go'))) {
    throw "Backend repo not found at $BackendRepo (expected cmd\main.go). Pass -BackendRepo."
  }
  if (-not (Get-Command go -ErrorAction SilentlyContinue)) { throw "Go is not on PATH." }

  $dest = Join-Path $Artifacts 'edge-node'
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  $out  = Join-Path $dest 'edge-node.exe'

  Push-Location $BackendRepo
  try {
    $env:CGO_ENABLED = '0'; $env:GOOS = 'windows'; $env:GOARCH = 'amd64'
    # Reported by /api/edge/status.
    $ver = "local-$(GitSha $BackendRepo)"
    & go build -ldflags "-s -w -X laguna-escondida/backend/internal/platform/buildinfo.Version=$ver" -o $out ./cmd
    if ($LASTEXITCODE -ne 0) { throw "go build failed ($LASTEXITCODE)" }
  } finally {
    Pop-Location
    Remove-Item Env:\CGO_ENABLED, Env:\GOOS, Env:\GOARCH -ErrorAction SilentlyContinue
  }
  $sha = GitSha $BackendRepo
  Stamp 'edge-node' $sha
  Write-Host "  -> $out  (sha $sha)" -ForegroundColor Green
  Write-Host "  Migrations are embedded in the binary; nothing else to copy." -ForegroundColor DarkGray
}

# --- next (Next.js standalone) -----------------------------------------------------
if (Want 'next') {
  Step "Building Next standalone bundle from $FrontendRepo"
  $cfgPath = Join-Path $FrontendRepo 'next.config.js'
  if (-not (Test-Path $cfgPath)) { throw "Frontend repo not found at $FrontendRepo (expected next.config.js). Pass -FrontendRepo." }
  if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) { throw "pnpm is not on PATH." }
  if ((Get-Content $cfgPath -Raw) -notmatch "output:\s*[`"']standalone[`"']") {
    throw "next.config.js does not set output: 'standalone'. Enable it in the frontend repo first."
  }
  if (-not (Test-SymlinkCapability)) {
    throw @'
This process cannot create symbolic links, which "next build" (output: standalone) requires
on Windows. Pick ONE of:
  1. Enable Developer Mode (one-time, recommended) -- then non-elevated builds work.
     Settings > Privacy & security > For developers > Developer Mode = On, or run elevated:
       Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" AllowDevelopmentWithoutDevLicense 1 -Type DWord -Force
  2. Re-run this script from an ELEVATED PowerShell (Run as Administrator).
See ai-plan\EDGE_WINDOWS_SERVICES_PLAN.md (Phase 2, build prerequisites).
'@
  }

  $dest = Join-Path $Artifacts 'next'
  if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $dest | Out-Null

  # Client NEXT_PUBLIC_* vars are inlined at build time; setting them in services\next.xml has no effect.
  $frontendEnvFile = Join-Path $Root 'env\next.env'
  $frontendEnv     = Read-DotEnv $frontendEnvFile
  if ($frontendEnv.Count) {
    # Keys only: values may be secrets.
    Write-Host ("  Frontend build env from env\next.env: " + (($frontendEnv.Keys) -join ', ')) -ForegroundColor DarkGray
  } else {
    Write-Warning "env\next.env not found (or empty). No per-box NEXT_PUBLIC_* inlined (e.g. NEXT_PUBLIC_ORDER_ACTION_PIN). Copy env\next.env.example if the app needs them."
  }

  Push-Location $FrontendRepo
  try {
    $env:NEXT_PUBLIC_API_URL = $BackendApiUrl
    $env:NODE_ENV = 'production'
    foreach ($k in $frontendEnv.Keys) { Set-Item -Path "Env:\$k" -Value $frontendEnv[$k] }
    Step "pnpm install --frozen-lockfile"
    Run "pnpm install --frozen-lockfile" "pnpm install"
    Step "pnpm build"
    Run "pnpm build" "pnpm build"
  } finally {
    Pop-Location
    Remove-Item Env:\NEXT_PUBLIC_API_URL, Env:\NODE_ENV -ErrorAction SilentlyContinue
    foreach ($k in $frontendEnv.Keys) { Remove-Item -Path "Env:\$k" -ErrorAction SilentlyContinue }
  }

  $standalone = Join-Path $FrontendRepo '.next\standalone'
  $static     = Join-Path $FrontendRepo '.next\static'
  $public     = Join-Path $FrontendRepo 'public'
  if (-not (Test-Path (Join-Path $standalone 'server.js'))) {
    throw "Expected $standalone\server.js after build. If it is nested, confirm outputFileTracingRoot = __dirname in next.config.js."
  }

  Step "Assembling artifacts\next"
  $srcNm = Join-Path $standalone 'node_modules'
  $dstNm = Join-Path $dest 'node_modules'

  # 1) Copy the standalone tree into real directories (see copy-standalone.js for why).
  & node (Join-Path $PSScriptRoot 'copy-standalone.js') $standalone $dest
  if ($LASTEXITCODE -ne 0) { throw "copying standalone tree failed (copy-standalone.js exit $LASTEXITCODE)" }

  # 2) Step 1 detached top-level packages from their .pnpm siblings; relink them as junctions.
  #    Junctions store absolute targets, so build artifacts\next in place, never move it.
  if (Test-Path $srcNm) {
    $dstNmAbs = (Resolve-Path $dstNm).Path
    foreach ($lnk in @(Get-ChildItem $srcNm -Force | Where-Object { $_.LinkType })) {
      $t = $lnk.Target; if ($t -is [array]) { $t = $t[0] }
      # Targets may be absolute or relative; anchor on '.pnpm\' either way.
      $i = $t.IndexOf('.pnpm\')
      if ($i -lt 0) { Write-Warning "node_modules\$($lnk.Name): link target not in .pnpm ($t) -- left as copied"; continue }
      $localTarget = Join-Path $dstNmAbs $t.Substring($i)
      $linkPath    = Join-Path $dstNm $lnk.Name
      if (-not (Test-Path $localTarget))      { throw "node_modules\$($lnk.Name): target missing in bundle: $localTarget" }
      if ($linkPath -notlike "$dstNmAbs\*")   { throw "refusing to modify $linkPath (outside bundle)" }
      if (Test-Path $linkPath) { Remove-Item $linkPath -Recurse -Force }
      New-Item -ItemType Junction -Path $linkPath -Target $localTarget | Out-Null
    }
  }

  # 3) Standalone output omits static assets and public\.
  New-Item -ItemType Directory -Force -Path (Join-Path $dest '.next') | Out-Null
  Copy-Item -Path $static -Destination (Join-Path $dest '.next') -Recurse -Force
  if (Test-Path $public) { Copy-Item -Path $public -Destination $dest -Recurse -Force }

  if (-not (Test-Path (Join-Path $dest 'server.js')))            { throw "server.js missing under $dest after assembly." }
  if (-not (Test-Path (Join-Path $dest '.next\static')))         { throw ".next\static missing under $dest after assembly." }
  if (-not (Test-Path (Join-Path $dstNm 'next\package.json')))   { throw "node_modules\next not resolvable under $dest (junction repair failed)." }
  $sha = GitSha $FrontendRepo
  Stamp 'next' $sha
  Write-Host "  -> $dest\server.js  (sha $sha)" -ForegroundColor Green
}

Write-Host "`nDone. Built: $($Only -join ', ')." -ForegroundColor Green
Write-Host "Next: scripts\install.ps1  (first install)  or  scripts\update.ps1 -Service <name>  (swap one)."
