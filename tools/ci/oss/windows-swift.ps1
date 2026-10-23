# Isomer's Windows build base for oss: Visual Studio's C++ build tools (ARM64
# and x64 MSVC, the Windows 11 SDK) and swift.org's toolchain at the version
# isomer pins, and Python 3, on top of a dev base (Git, Bazelisk). Built on the oss server:
#   oss image build windows swift-6.3.2 --from=dev --script=tools/ci/oss/windows-swift.ps1
# A stopgap: hermetic toolchains are to replace it.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$swift = '6.3.2'

function Run($file, $arguments) {
    $p = Start-Process -FilePath $file -ArgumentList $arguments -Wait -PassThru
    # 3010: done, a restart wanted (the base is restarted before it's sealed).
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "$file exited $($p.ExitCode)" }
}

Write-Output 'Visual Studio Build Tools'
$vs = "$env:TEMP\vs_buildtools.exe"
Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_buildtools.exe' -OutFile $vs
Run $vs @('--quiet', '--wait', '--norestart', '--nocache',
          '--add', 'Microsoft.VisualStudio.Component.VC.Tools.ARM64',
          '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
          '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.22621')

Write-Output "Swift $swift"
$exe = "$env:TEMP\swift-$swift.exe"
Invoke-WebRequest -Uri "https://download.swift.org/swift-$swift-release/windows10-arm64/swift-$swift-RELEASE/swift-$swift-RELEASE-windows10-arm64.exe" -OutFile $exe
Run $exe @('/quiet', '/norestart')
Remove-Item $vs, $exe -Force

# Python 3: rules_swift's Windows autoconfiguration reads the Swift SDK's
# Info.plist with it.
Write-Output 'Python 3'
winget install --id Python.Python.3.12 --silent --scope machine --accept-package-agreements --accept-source-agreements

# What a new session sees (the installers change the machine's and runner's PATH).
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
swift --version
