# Builds the Windows installer from zig-out/bin. Inno Setup 6 or 7 must be installed.
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

$innoArch = switch ($Arch) {
    "x86_64" { "x64compatible" }
    "arm64" { "arm64" }
    default { throw "unsupported arch: $Arch" }
}

$iscc = Get-ChildItem `
    "${env:ProgramFiles}\Inno Setup *\ISCC.exe", `
    "${env:ProgramFiles(x86)}\Inno Setup *\ISCC.exe" `
    -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $iscc) { throw "ISCC.exe not found; install Inno Setup" }

$stage_root = Join-Path $repo "zig-out\stage"
$stage = Join-Path $stage_root "windows"
if (Test-Path $stage_root) { Remove-Item -Recurse -Force $stage_root }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item (Join-Path $repo "zig-out\bin\kocr.exe") $stage
Copy-Item (Join-Path $repo "zig-out\bin\kocr-gui.exe") $stage
Copy-Item (Join-Path $repo "README.md") $stage
Copy-Item (Join-Path $repo "LICENSE") $stage

$env:VERSION = $Version
$env:ARCH = $innoArch
$env:OUT_ARCH = $Arch
& $iscc.FullName (Join-Path $PSScriptRoot "kocr.iss")
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$name = "kocr-$Version-windows-$Arch-setup.exe"
$path = Join-Path $repo "zig-out\bundle\windows\$name"
$stream = [IO.File]::OpenRead($path)
try {
    $sha = [Security.Cryptography.SHA256]::Create()
    $hash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace("-", "").ToLowerInvariant()
} finally {
    $stream.Dispose()
}
[IO.File]::WriteAllText("$path.sha256", "$hash  $name`n")
Remove-Item -Recurse -Force $stage_root
Write-Output $path
