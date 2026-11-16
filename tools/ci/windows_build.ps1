# CI's Windows build, on GitHub's own windows-11-arm runner (free for a
# public repository), natively: swift.org's Swift for Windows at the release
# isomer pins, installed here (pinned by SHA-256), and the runner image's own
# Visual Studio (ARM64 MSVC) and Windows SDK, so nothing of Microsoft's is
# redistributed (tools/windows/README.md). Built only, not run: Windows is
# tier 2. The recipe a Windows machine has always built with
# (tools/proof/proof.py's): Bazel in MSVC's environment (vcvarsall arm64),
# BAZEL_SH Git's bash and Git's usr\bin ahead of System32 (rules_swift_package_manager
# runs find, cp and od; tools/patches/rules_swift_package_manager_windows.patch
# in the examples), and --repo_env for SDKROOT, PATH and MSVC's variables
# (repository rules see nothing else). Bazel's startup options and caches
# are tools/ci/ci_bazel.sh's (ISOMER_BAZEL_ROOT=C:/b: short paths).
#
#   tools/ci/windows_build.ps1 setup                      # Swift installed, its SDKROOT and PATH for the job's later steps
#   tools/ci/windows_build.ps1 <bazel command> '<arg>'…   # a Bazel command in the examples
#
# No param block: Bazel's arguments pass through as they are ($args), each
# quoted by the caller ('--keep_going'), as PowerShell would take a bare
# --name for a parameter of its own.
$Bazel = @($args)
$SetUp = $Bazel.Count -eq 1 -and $Bazel[0] -eq 'setup'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# The Swift every other platform builds with (MODULE.bazel's swift.toolchain).
$Swift = '6.4.2'
$Installer = "https://download.swift.org/swift-$Swift-release/windows10-arm64/swift-$Swift-RELEASE/swift-$Swift-RELEASE-windows10-arm64.exe"
$Sha256 = 'e4e5fdb6ca88b18ac430fbce3de35dd80e2249a84a484a02272d82d89f2c7969'

if ($SetUp) {
    $exe = Join-Path $env:RUNNER_TEMP "swift-$Swift.exe"
    Invoke-WebRequest -Uri $Installer -OutFile $exe
    $found = (Get-FileHash -Algorithm SHA256 $exe).Hash.ToLowerInvariant()
    if ($found -ne $Sha256) { throw "windows_build: Swift's installer is $found, not the pinned $Sha256" }
    $p = Start-Process -FilePath $exe -ArgumentList @('/quiet', '/norestart') -Wait -PassThru
    # 3010: installed, a restart wanted (not for a build).
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "windows_build: Swift's installer exited $($p.ExitCode)" }
    Remove-Item $exe -Force
    # What the installer set, for the job's later steps (a step's
    # environment is the job's, not the machine's).
    $sdkroot = [Environment]::GetEnvironmentVariable('SDKROOT', 'User')
    if (-not $sdkroot) { $sdkroot = [Environment]::GetEnvironmentVariable('SDKROOT', 'Machine') }
    if (-not $sdkroot) { throw 'windows_build: no SDKROOT after Swift was installed' }
    "SDKROOT=$sdkroot" | Add-Content $env:GITHUB_ENV
    $paths = @([Environment]::GetEnvironmentVariable('Path', 'User'), [Environment]::GetEnvironmentVariable('Path', 'Machine')) -join ';'
    $swiftPaths = $paths.Split(';') | Where-Object { $_ -and $_ -match '\\Swift\\' } | Select-Object -Unique
    if (-not $swiftPaths) { throw 'windows_build: Swift added nothing to PATH' }
    $swiftPaths | Add-Content $env:GITHUB_PATH
    $env:Path = ($swiftPaths -join ';') + ';' + $env:Path
    $env:SDKROOT = $sdkroot
    swift --version
    exit 0
}

if ($Bazel.Count -eq 0) { throw "usage: tools/ci/windows_build.ps1 setup | <bazel command> '<arg>'…" }
# MSVC's environment for ARM64, from the image's Visual Studio.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath
if (-not $vs) { throw 'windows_build: no Visual Studio with ARM64 MSVC on this runner' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvarsall.bat'
cmd /c "`"$vcvars`" arm64 >nul && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($Matches[1])" -Value $Matches[2] }
}
if (-not $env:VCToolsInstallDir) { throw 'windows_build: vcvarsall arm64 set no MSVC environment' }
$git = 'C:\Program Files\Git'
$env:BAZEL_SH = "$git\bin\bash.exe"
# Git's usr\bin just ahead of System32: its find, cp and od before Windows'
# own, MSVC's link.exe still ahead of Git's link.
$env:Path = $env:Path -replace '(?i)C:\\Windows\\system32;', "$git\usr\bin;C:\Windows\system32;"
if ($env:Path -notmatch [regex]::Escape("$git\usr\bin")) { $env:Path = "$env:Path;$git\usr\bin" }
$repoEnv = @('SDKROOT', 'PATH', 'INCLUDE', 'LIB', 'LIBPATH', 'UniversalCRTSdkDir', 'UCRTVersion', 'WindowsSdkDir',
             'WindowsSDKVersion', 'VCToolsInstallDir', 'VCINSTALLDIR', 'VSINSTALLDIR') | ForEach-Object { "--repo_env=$_" }
# Bazelisk, so .bazelversion is honoured (the image's `bazel` may be a
# release of its own).
$bazelisk = (Get-Command bazelisk -ErrorAction SilentlyContinue)
$tool = if ($bazelisk) { 'bazelisk' } else { 'bazel' }
Push-Location (Join-Path $PSScriptRoot '..\..\examples')
try {
    $command = $Bazel[0]
    $rest = @($Bazel | Select-Object -Skip 1)
    & $tool $command @repoEnv @rest
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
