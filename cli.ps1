[CmdletBinding()]
param(
    [ValidateSet("install", "uninstall")]
    [string]$Action = "install",
    [string]$Version = $env:KOCR_VERSION,
    [string]$InstallDir = $env:KOCR_INSTALL_DIR
)

$ErrorActionPreference = "Stop"
$Repo = "KercyDing/kocr"

if (-not $InstallDir) {
    $InstallDir = Join-Path $env:LOCALAPPDATA "kocr\bin"
}
$Binary = Join-Path $InstallDir "kocr.exe"

function Resolve-Target {
    switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        "X64" { "x86_64-pc-windows-msvc" }
        "Arm64" { "aarch64-pc-windows-msvc" }
        default {
            throw "unsupported architecture: $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)"
        }
    }
}

function Resolve-Tag {
    if ($Version) {
        if ($Version.StartsWith("v")) { return $Version }
        return "v$Version"
    }
    return (Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest").tag_name
}

function Update-UserPath([string]$Directory) {
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @($current -split ";" | Where-Object { $_ })
    if ($parts -contains $Directory) {
        return
    }
    $updated = (($parts + $Directory) -join ";")
    [Environment]::SetEnvironmentVariable("Path", $updated, "User")
    Write-Host "Added $Directory to the user PATH; restart your terminal."
}

function Install-Kocr {
    $tag = Resolve-Tag
    $packageVersion = $tag.TrimStart("v")
    $target = Resolve-Target
    $asset = "kocr-$packageVersion-$target.zip"
    $base = "https://github.com/$Repo/releases/download/$tag"
    $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("kocr-" + [guid]::NewGuid())

    New-Item -ItemType Directory -Path $temporary | Out-Null
    try {
        $archive = Join-Path $temporary $asset
        Invoke-WebRequest "$base/$asset" -OutFile $archive -UseBasicParsing
        Invoke-WebRequest "$base/$asset.sha256" -OutFile "$archive.sha256" -UseBasicParsing

        $expected = ((Get-Content "$archive.sha256" -Raw).Trim() -split "\s+")[0].ToLower()
        $actual = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLower()
        if ($expected -ne $actual) {
            throw "release checksum does not match"
        }

        $extract = Join-Path $temporary "extract"
        Expand-Archive $archive -DestinationPath $extract -Force
        $binary = Get-ChildItem $extract -Recurse -Filter "kocr.exe" | Select-Object -First 1
        if (-not $binary) {
            throw "kocr.exe was not found in the release archive"
        }

        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
        Copy-Item $binary.FullName $Binary -Force
        Update-UserPath $InstallDir

        Write-Host "Installed kocr to $Binary"
        Write-Host "Install a model with: kocr install 1"
    }
    finally {
        Remove-Item $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Uninstall-Kocr {
    Remove-Item $Binary -Force -ErrorAction SilentlyContinue

    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @($current -split ";" | Where-Object { $_ -and $_ -ne $InstallDir })
    [Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), "User")

    Write-Host "Uninstalled kocr"
}

switch ($Action) {
    "install" { Install-Kocr }
    "uninstall" { Uninstall-Kocr }
}
