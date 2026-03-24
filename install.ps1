# install.ps1 — Chasm installer for Windows
#
# Usage (PowerShell):
#   irm https://raw.githubusercontent.com/Chasm-lang/Chasm/main/install.ps1 | iex
#
# Or with a custom install dir:
#   $env:CHASM_HOME = "C:\chasm"; irm .../install.ps1 | iex

$ErrorActionPreference = 'Stop'

$Repo      = "Chasm-lang/Chasm"
$InstallDir = if ($env:CHASM_HOME) { $env:CHASM_HOME } else { "$env:LOCALAPPDATA\chasm" }
$BinDir    = "$InstallDir\bin"

# Detect arch
$Arch = if ([System.Environment]::Is64BitOperatingSystem) { "x86_64" } else {
    Write-Error "32-bit Windows is not supported."
    exit 1
}
$OsName = "windows"

# Fetch latest release tag
Write-Host "Fetching latest Chasm release..."
$Release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest"
$Tag     = $Release.tag_name

if (-not $Tag) {
    Write-Error "Could not determine latest release. Check https://github.com/$Repo/releases"
    exit 1
}

$Archive = "chasm-$Tag-$OsName-$Arch.zip"
$Url     = "https://github.com/$Repo/releases/download/$Tag/$Archive"

Write-Host "Installing Chasm $Tag for $OsName-$Arch..."
Write-Host "  from: $Url"
Write-Host "  to:   $InstallDir"

# Download
$Tmp     = [System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid()
New-Item -ItemType Directory -Path $Tmp | Out-Null

try {
    $ZipPath = "$Tmp\$Archive"
    Invoke-WebRequest -Uri $Url -OutFile $ZipPath -UseBasicParsing

    # Extract
    Expand-Archive -Path $ZipPath -DestinationPath $Tmp

    $Extracted = "$Tmp\chasm-$Tag-$OsName-$Arch"

    # Install
    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
    Copy-Item $Extracted $InstallDir -Recurse

} finally {
    Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Chasm $Tag installed to $InstallDir"

# Add BinDir to user PATH if not already present
$UserPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
if ($UserPath -notlike "*$BinDir*") {
    [System.Environment]::SetEnvironmentVariable("PATH", "$UserPath;$BinDir", "User")
    Write-Host "Added $BinDir to your PATH (restart your terminal to use it)."
} else {
    Write-Host "CLI is at $BinDir\chasm.exe"
}

Write-Host ""
Write-Host "Try: chasm run examples\hello\hello.chasm"
