<#
  build-artifacts.ps1 -- build the APP artifacts LOCALLY from the sibling app repos into
  artifacts\. For a single-site install this is simpler than CI/release downloads.

    * edge-node  -> artifacts\edge-node\edge-node.exe   (Go; migrations embedded in the binary)
    * next       -> artifacts\next\server.js (+ .next\static, public, minimal node_modules)

  Off-the-shelf binaries (Caddy, Node, Postgres) come from scripts\fetch-artifacts.ps1, not here.

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

  # Baked into the Next build. Read SERVER-SIDE by Next to reach the local Go backend
  # (see ai-plan\EDGE_WINDOWS_SERVICES_PLAN.md §2.1 -- the tablet never uses this).
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

# Run a command line via cmd so its stderr is merged INSIDE cmd (2>&1), not wrapped by
# PowerShell 5.1 as a terminating NativeCommandError. Inherited $env:* are visible to the
# child. Throws on a non-zero exit using the real exit code.
function Run($cmdLine, $what) {
  & cmd /c "$cmdLine 2>&1" | ForEach-Object { Write-Host $_ }
  if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE)" }
}

# Can `next build` create the symlink its standalone packer needs (node_modules\next)?
# On Windows that requires EITHER an elevated process OR Developer Mode (Node's fs.symlink
# passes SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE, which Developer Mode honors).
# NOTE: we check Developer Mode / elevation directly -- a raw PowerShell New-Item
# -ItemType SymbolicLink does NOT pass the unprivileged flag, so it would false-negative
# under Developer Mode even though the actual build succeeds.
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
# Parse a KEY=VALUE .env file (ignoring blanks and #comments) into an ordered map. Used to load
# per-box NEXT_PUBLIC_* build-time vars from env\next.env. Mirrors the box.env parser in install.ps1.
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
# Record what we built into versions.json (traceability for a single-site install).
function Stamp($key, $sha) {
  $vf = Join-Path $Root 'versions.json'
  $v  = Get-Content $vf -Raw | ConvertFrom-Json
  $v.artifacts.$key.version = $sha
  ($v | ConvertTo-Json -Depth 10) | Set-Content $vf -Encoding utf8
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
    # CGO off => static build, no gcc needed (matches the repo's Dockerfile). GOOS/GOARCH
    # default to the host (windows/amd64) but we set them explicitly for determinism.
    $env:CGO_ENABLED = '0'; $env:GOOS = 'windows'; $env:GOARCH = 'amd64'
    & go build -ldflags '-s -w' -o $out ./cmd
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
  # Guard: without standalone output there is no server.js to ship.
  if ((Get-Content $cfgPath -Raw) -notmatch "output:\s*[`"']standalone[`"']") {
    throw "next.config.js does not set output: 'standalone'. Enable it in the frontend repo first."
  }
  # Preflight: Next's standalone packer creates a symlink (node_modules\next) -- Windows
  # blocks that without Developer Mode or elevation. Fail fast with the remedy rather than
  # after a multi-minute build.
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
  if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }   # clean rebuild: never leave stale chunks
  New-Item -ItemType Directory -Force -Path $dest | Out-Null

  # Per-box NEXT_PUBLIC_* the CLIENT bundle reads (e.g. NEXT_PUBLIC_ORDER_ACTION_PIN) are
  # inlined at BUILD time, so they must be in the environment for `pnpm build` — setting them
  # only in services\next.xml (runtime) never reaches the browser. Source them from env\next.env
  # (gitignored; copy env\next.env.example). Missing file => none applied (build still works).
  $frontendEnvFile = Join-Path $Root 'env\next.env'
  $frontendEnv     = Read-DotEnv $frontendEnvFile
  if ($frontendEnv.Count) {
    # Log KEYS ONLY — values may be secret-ish (a PIN) and must not land in build logs.
    Write-Host ("  Frontend build env from env\next.env: " + (($frontendEnv.Keys) -join ', ')) -ForegroundColor DarkGray
  } else {
    Write-Warning "env\next.env not found (or empty). No per-box NEXT_PUBLIC_* inlined (e.g. NEXT_PUBLIC_ORDER_ACTION_PIN). Copy env\next.env.example if the app needs them."
  }

  Push-Location $FrontendRepo
  try {
    $env:NEXT_PUBLIC_API_URL = $BackendApiUrl   # inlined at build time (server-only usage)
    $env:NODE_ENV = 'production'
    # Apply every key from env\next.env verbatim (adding a new NEXT_PUBLIC_* needs no change here).
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

  # 1) Copy the whole standalone tree (server.js, .next\server, node_modules incl. the .pnpm
  #    store) into all-real directories. pnpm's store defeats Copy-Item (access denied),
  #    verbatim symlinks (un-stat-able at runtime), and fs.cpSync dereference (store has a
  #    symlink cycle -> stack overflow). copy-standalone.js resolves links to real dirs with
  #    cycle detection. Top-level package links are fixed in step 2 as junctions.
  & node (Join-Path $PSScriptRoot 'copy-standalone.js') $standalone $dest
  if ($LASTEXITCODE -ne 0) { throw "copying standalone tree failed (copy-standalone.js exit $LASTEXITCODE)" }

  # 2) Repair top-level packages. pnpm makes them (next, react, ...) symlinks into its .pnpm
  #    store; step 1 turned them into DETACHED real dirs, severing them from their .pnpm
  #    siblings (e.g. styled-jsx) and breaking resolution. Replace each with a JUNCTION into the
  #    bundle's OWN .pnpm. Junctions need no privilege and Node follows them fine at runtime
  #    (unlike the store's symlinks, which EPERM). NOTE: junctions store an ABSOLUTE target, so
  #    build the artifact at its final install location (do not build then move artifacts\next).
  if (Test-Path $srcNm) {
    $dstNmAbs = (Resolve-Path $dstNm).Path
    foreach ($lnk in @(Get-ChildItem $srcNm -Force | Where-Object { $_.LinkType })) {
      $t = $lnk.Target; if ($t -is [array]) { $t = $t[0] }
      # pnpm emits the target as either absolute (...\node_modules\.pnpm\<pkg>\...) or relative
      # (.pnpm\<pkg>\...). Anchor on '.pnpm\' either way and keep the rest as the local path.
      $i = $t.IndexOf('.pnpm\')
      if ($i -lt 0) { Write-Warning "node_modules\$($lnk.Name): link target not in .pnpm ($t) -- left as copied"; continue }
      $localTarget = Join-Path $dstNmAbs $t.Substring($i)       # .pnpm\<pkg>\node_modules\<pkg>
      $linkPath    = Join-Path $dstNm $lnk.Name
      if (-not (Test-Path $localTarget))      { throw "node_modules\$($lnk.Name): target missing in bundle: $localTarget" }
      if ($linkPath -notlike "$dstNmAbs\*")   { throw "refusing to modify $linkPath (outside bundle)" }
      if (Test-Path $linkPath) { Remove-Item $linkPath -Recurse -Force }
      New-Item -ItemType Junction -Path $linkPath -Target $localTarget | Out-Null
    }
  }

  # 3) static assets + public are NOT in the standalone output -- place them next to server.js
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
