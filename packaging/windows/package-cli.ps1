# Builds the standalone CLI zip from zig-out/bin.
param(
    [string]$Version,
    [string]$Arch = "x86_64"
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

if (-not $Version) {
    $zon = Get-Content (Join-Path $repo "build.zig.zon") -Raw
    if ($zon -match '\.version\s*=\s*"([^"]+)"') {
        $Version = $Matches[1]
    } else {
        throw "could not read .version from build.zig.zon"
    }
}

$stage = Join-Path $repo "zig-out\stage\windows-cli"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item (Join-Path $repo "zig-out\bin\kocr.exe") $stage
Copy-Item (Join-Path $repo "README.md") $stage
Copy-Item (Join-Path $repo "LICENSE") $stage

$out_dir = Join-Path $repo "zig-out\bundle\windows"
New-Item -ItemType Directory -Force -Path $out_dir | Out-Null
$name = "kocr-cli-$Version-windows-$Arch.zip"
$path = Join-Path $out_dir $name
if (Test-Path $path) { Remove-Item $path -Force }
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $path
Remove-Item -Recurse -Force $stage

$stream = [IO.File]::OpenRead($path)
try {
    $sha = [Security.Cryptography.SHA256]::Create()
    $hash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace("-", "").ToLowerInvariant()
} finally {
    $stream.Dispose()
}
[IO.File]::WriteAllText("$path.sha256", "$hash  $name`n")
Write-Output $path
