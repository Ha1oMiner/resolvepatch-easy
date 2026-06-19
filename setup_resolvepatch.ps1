# Run as Administrator required
#Requires -RunAsAdministrator

Write-Host "=== ResolvePatch Setup ===" -ForegroundColor Cyan

# ── 1. Check / install rustup ──────────────────────────────────────────────
if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) {
    Write-Host "[*] rustup not found. Installing..." -ForegroundColor Yellow
    $rustupInstaller = "$env:TEMP\rustup-init.exe"
    Invoke-WebRequest "https://win.rustup.rs/x86_64" -OutFile $rustupInstaller
    Start-Process -FilePath $rustupInstaller -ArgumentList "-y" -Wait
    # Reload PATH so rustup/cargo are available
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH", "User")
}

# ── 2. Check / install nightly toolchain ──────────────────────────────────
Write-Host "[*] Checking for Rust nightly..." -ForegroundColor Yellow
$installedToolchains = rustup toolchain list
if ($installedToolchains -notmatch "nightly") {
    Write-Host "[*] Nightly not found. Installing..." -ForegroundColor Yellow
    rustup toolchain install nightly
} else {
    Write-Host "[+] Rust nightly already installed." -ForegroundColor Green
}

# ── 3. Locate resolvepatch-master folder ──────────────────────────────────
Write-Host "[*] Searching for resolvepatch-master folder..." -ForegroundColor Yellow

$searchRoots = @(
    $env:USERPROFILE,
    "C:\",
    "D:\"
)

$projectDir = $null
foreach ($root in $searchRoots) {
    if (-not (Test-Path $root)) { continue }
    $found = Get-ChildItem -Path $root -Recurse -Directory -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -match "resolvepatch" -and (Test-Path "$($_.FullName)\Cargo.toml") } |
             Select-Object -First 1
    if ($found) {
        $projectDir = $found.FullName
        break
    }
}

if (-not $projectDir) {
    Write-Host "[!] Could not find resolvepatch folder. Please enter the full path:" -ForegroundColor Red
    $projectDir = Read-Host "Path"
}

Write-Host "[+] Found project at: $projectDir" -ForegroundColor Green

# ── 4. Find DaVinci Resolve location ──────────────────────────────────────
Write-Host "[*] Looking for Resolve.exe..." -ForegroundColor Yellow

$resolveExe = $null

# Check registry first
$regTypes = @(
    "ResolveBinFile","ResolveDrpFile","ResolveDBKeyFile",
    "ResolveTimelineFile","ResolveTemplateBundle"
)
foreach ($type in $regTypes) {
    $regPath = "HKCU:\Software\Classes\$type\shell\open\command"
    if (Test-Path $regPath) {
        $val = (Get-ItemProperty -Path $regPath)."(default)"
        if ($val) {
            # Strip leading quote and trailing " %1" or similar
            $exePath = $val -replace '^"(.+?)".*$', '$1'
            if (Test-Path $exePath) {
                $resolveExe = $exePath
                break
            }
        }
    }
}

# Fallback: common paths
if (-not $resolveExe) {
    $commonPaths = @(
        "C:\Program Files\Blackmagic Design\DaVinci Resolve\Resolve.exe",
        "D:\DavinciResolve\Resolve.exe",
        "D:\DaVinci Resolve\Resolve.exe",
        "D:\Program Files\Blackmagic Design\DaVinci Resolve\Resolve.exe"
    )
    foreach ($p in $commonPaths) {
        if (Test-Path $p) {
            $resolveExe = $p
            break
        }
    }
}

# Search drives if still not found
if (-not $resolveExe) {
    Write-Host "[*] Searching drives for Resolve.exe (this may take a moment)..." -ForegroundColor Yellow
    foreach ($drive in @("C:\","D:\","E:\")) {
        if (-not (Test-Path $drive)) { continue }
        $found = Get-ChildItem -Path $drive -Recurse -Filter "Resolve.exe" -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($found) {
            $resolveExe = $found.FullName
            break
        }
    }
}

if (-not $resolveExe) {
    Write-Host "[!] Could not find Resolve.exe. Please enter the full path:" -ForegroundColor Red
    $resolveExe = Read-Host "Path (e.g. D:\DavinciResolve\Resolve.exe)"
}

Write-Host "[+] Found Resolve.exe at: $resolveExe" -ForegroundColor Green

# ── 5. Patch main.rs with the correct path ────────────────────────────────
$mainRs = Join-Path $projectDir "src\main.rs"

if (-not (Test-Path $mainRs)) {
    Write-Host "[!] src\main.rs not found in project folder!" -ForegroundColor Red
    exit 1
}

$src = Get-Content $mainRs -Raw

# Escape backslashes for the Rust raw string (r#"..."# doesn't need escaping,
# but we need to escape for PowerShell regex replacement)
$escapedPath = $resolveExe -replace '\\', '\\'

# Replace any existing DEFAULT_PATH value
$src = $src -replace '(?s)(const DEFAULT_PATH: &\x27static str =\s*r#")([^"]*)(";)', "`${1}$resolveExe`${3}"

Set-Content -Path $mainRs -Value $src -NoNewline
Write-Host "[+] main.rs updated with path: $resolveExe" -ForegroundColor Green

# ── 6. Set nightly override for this project ──────────────────────────────
Write-Host "[*] Setting nightly toolchain for project..." -ForegroundColor Yellow
Push-Location $projectDir
rustup override set nightly

# ── 7. Build ───────────────────────────────────────────────────────────────
Write-Host "[*] Building resolvepatch (release)..." -ForegroundColor Yellow
cargo build --release

if ($LASTEXITCODE -ne 0) {
    Write-Host "[!] Build failed!" -ForegroundColor Red
    Pop-Location
    exit 1
}

Write-Host "[+] Build succeeded!" -ForegroundColor Green

# ── 8. Run ─────────────────────────────────────────────────────────────────
$exePath = Join-Path $projectDir "target\release\resolvepatch.exe"
Write-Host "[*] Running resolvepatch..." -ForegroundColor Cyan
Start-Process -FilePath $exePath -Wait

Pop-Location
Write-Host "`n[+] All done!" -ForegroundColor Green
