# CI's Windows build, on GitHub's own windows-11-arm runner (free for a
# public repository), natively: swift.org's Swift for Windows at the release
# isomer pins, installed here (pinned by SHA-256), and the runner image's own
# Visual Studio (ARM64 MSVC) and Windows SDK, so nothing of Microsoft's is
# redistributed (tools/windows/README.md). Built only, not run: Windows is
# tier 2. The recipe a Windows machine has always built with
# (tools/proof/proof.py's), with LLVM's llvm-lib as MSVC's lib.exe (below):
# Bazel in MSVC's environment (vcvarsall arm64),
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
    $swiftPaths = @($paths.Split(';') | Where-Object { $_ -and $_ -match '\\Swift\\' } | Select-Object -Unique)
    if (-not $swiftPaths) { throw 'windows_build: Swift added nothing to PATH' }
    # The Swift runtime's DLLs (swiftCore.dll and the rest), which the tools
    # Bazel builds for itself load when they run (protoc-gen-swift, the macro
    # plugins): the arm64 installer's runtime is in Runtimes\<version>\usr\bin,
    # not always on the PATH it sets.
    $swiftRoot = if ($sdkroot -match '^(.*\\Swift)\\Platforms\\') { $Matches[1] } else { Join-Path $env:LOCALAPPDATA 'Programs\Swift' }
    $runtime = Get-ChildItem -Recurse -Filter swiftCore.dll -Path (Join-Path $swiftRoot 'Runtimes') -ErrorAction SilentlyContinue |
        Where-Object { $_.DirectoryName -match '\\usr\\bin$' } | Select-Object -First 1
    if (-not $runtime) { throw "windows_build: no Swift runtime (swiftCore.dll) under $swiftRoot\Runtimes" }
    if ($swiftPaths -notcontains $runtime.DirectoryName) { $swiftPaths = @($runtime.DirectoryName) + $swiftPaths }
    "Swift on PATH: $($swiftPaths -join '; ')"
    # And in System32, which Windows searches whatever a process's
    # environment: rules_swift's SwiftProtocGen action runs protoc, and so
    # protoc-gen-swift, with no environment at all (actions.run with no env
    # and no use_default_shell_env), so no PATH finds the runtime for it, and
    # it ends 0xC0000135 (a DLL not found). This runner is the job's alone
    # and goes with it; the fix that lasts is rules_swift's, the action run
    # with the default shell environment.
    # Only what System32 lacks: the runtime's folder also carries the VC
    # runtime (msvcp140.dll and the rest), whose system copies stay.
    $system32 = Join-Path $env:SystemRoot 'System32'
    Get-ChildItem (Join-Path $runtime.DirectoryName '*.dll') | Where-Object { -not (Test-Path (Join-Path $system32 $_.Name)) } |
        ForEach-Object { Copy-Item $_.FullName $system32 }
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
# Visual Studio as Bazel takes it (BAZEL_VC), with LLVM's llvm-lib as its
# lib.exe: MSVC's lib.exe and link.exe can't open a path past 260
# characters even with LongPathsEnabled (they aren't long-path aware), and
# Bazel's object paths for some exec tools' archives (swift-syntax's,
# swift-protobuf's) reach 283 from C:/b/<hash>/execroot/_main; llvm-lib
# opens them (both checked on this runner), and makes archives MSVC's
# link.exe reads. rules_cc takes the archiver from BAZEL_VC's
# Tools\MSVC\<version>\bin\HostX64\arm64, so C:\v mirrors the install by
# junctions but for that folder, copied with lib.exe replaced. (LLVM's whole
# toolchain, rules_cc's USE_CLANG_CL, failed: rules_swift's tools pass
# clang-cl a flag it rejects, and its ARM64 backend fails on upb's code.)
$version = (Get-ChildItem (Join-Path $vs 'VC\Tools\MSVC') | Sort-Object Name | Select-Object -Last 1).Name
$llvmLib = Join-Path $vs 'VC\Tools\Llvm\ARM64\bin\llvm-lib.exe'
if (-not (Test-Path $llvmLib)) { $llvmLib = 'C:\Program Files\LLVM\bin\llvm-lib.exe' }
if (-not (Test-Path $llvmLib)) { throw 'windows_build: no llvm-lib on this runner' }
$mirror = 'C:\v'
# mirror <from> <to> <the child left out>: every other child of <from> in
# <to>, a folder by a junction, a file copied.
function mirror($from, $to, $skip) {
    New-Item -ItemType Directory -Force $to | Out-Null
    foreach ($child in Get-ChildItem -Force $from) {
        if ($child.Name -eq $skip) { continue }
        $target = Join-Path $to $child.Name
        if (Test-Path $target) { continue }
        if ($child.PSIsContainer) { New-Item -ItemType Junction -Path $target -Target $child.FullName | Out-Null }
        else { Copy-Item $child.FullName $target }
    }
}
$tools = "VC\Tools\MSVC\$version\bin\HostX64\arm64"
if (-not (Test-Path (Join-Path $mirror "$tools\lib.exe"))) {
    mirror $vs $mirror 'VC'
    mirror (Join-Path $vs 'VC') (Join-Path $mirror 'VC') 'Tools'
    mirror (Join-Path $vs 'VC\Tools') (Join-Path $mirror 'VC\Tools') 'MSVC'
    mirror (Join-Path $vs 'VC\Tools\MSVC') (Join-Path $mirror 'VC\Tools\MSVC') $version
    mirror (Join-Path $vs "VC\Tools\MSVC\$version") (Join-Path $mirror "VC\Tools\MSVC\$version") 'bin'
    mirror (Join-Path $vs "VC\Tools\MSVC\$version\bin") (Join-Path $mirror "VC\Tools\MSVC\$version\bin") 'HostX64'
    mirror (Join-Path $vs "VC\Tools\MSVC\$version\bin\HostX64") (Join-Path $mirror "VC\Tools\MSVC\$version\bin\HostX64") 'arm64'
    Copy-Item -Recurse (Join-Path $vs $tools) (Join-Path $mirror $tools)
    Copy-Item -Force $llvmLib (Join-Path $mirror "$tools\lib.exe")
}
$env:BAZEL_VC = Join-Path $mirror 'VC'
$vcvars = Join-Path $mirror 'VC\Auxiliary\Build\vcvarsall.bat'
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
             'WindowsSDKVersion', 'VCToolsInstallDir', 'VCINSTALLDIR', 'VSINSTALLDIR', 'BAZEL_VC') |
    ForEach-Object { "--repo_env=$_" }
# Bazelisk, so .bazelversion is honoured (the image's `bazel` may be a
# release of its own).
$bazelisk = (Get-Command bazelisk -ErrorAction SilentlyContinue)
$tool = if ($bazelisk) { 'bazelisk' } else { 'bazel' }
Push-Location (Join-Path $PSScriptRoot '..\..\examples')
try {
    $command = $Bazel[0]
    $rest = @($Bazel | Select-Object -Skip 1)
    & $tool $command @repoEnv @rest
    $status = $LASTEXITCODE
    if ($status -ne 0) {
        # What a tool Bazel built for itself can't load, if one couldn't run
        # (0xC0000135, a DLL not found): each DLL it names, found on PATH or
        # not.
        $bin = (& $tool info @repoEnv bazel-bin 2> $null | Select-Object -Last 1)
        $execBin = $bin -replace '-fastbuild[^/\\]*', '-opt-exec'
        foreach ($exe in Get-ChildItem -Recurse -Filter 'protoc-gen-swift*.exe' -Path (Join-Path $execBin 'external') -ErrorAction SilentlyContinue) {
            "$($exe.FullName) loads:"
            $dumpbin = Join-Path $env:VCToolsInstallDir 'bin\HostX64\arm64\dumpbin.exe'
            & $dumpbin /nologo /dependents $exe.FullName | Where-Object { $_ -match '^\s+\S+\.dll\s*$' } | ForEach-Object {
                $dll = $_.Trim()
                $found = (Get-Command $dll -ErrorAction SilentlyContinue | Select-Object -First 1).Source
                "  $dll -> $(if ($found) { $found } else { 'NOT FOUND on PATH' })"
            }
        }
    }
    exit $status
} finally {
    Pop-Location
}
