# Which archivers on this Windows runner open an input whose full path is
# longer than MAX_PATH (260), as Bazel's object paths for some exec tools are
# (swift-syntax's and swift-protobuf's, 268 to 283 characters from
# C:/b/<hash>/execroot/_main). A diagnosis for tools/ci/windows_build.ps1:
# each candidate archives one object at such a path, given relative to a
# working folder as Bazel gives it, and says whether it could.
#
#   tools/ci/windows_paths_probe.ps1
$ErrorActionPreference = 'Continue'
"LongPathsEnabled: $((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem').LongPathsEnabled)"
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$installs = & $vswhere -all -products * -property installationPath
"Visual Studio: $($installs -join '; ')"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath
$msvc = Get-ChildItem (Join-Path $vs 'VC\Tools\MSVC') | Sort-Object Name | Select-Object -Last 1
"MSVC: $($msvc.FullName)"

# An object to archive: one function, compiled by the ARM64-hosted compiler.
# As deep as Bazel's execution root was (C:/b/<hash>/execroot/_main).
$work = 'C:\b\c57rdinz\execroot\_main'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Content "$work\t.c" 'int iso_probe(void) { return 1; }'
$cl = Join-Path $msvc.FullName 'bin\HostARM64\arm64\cl.exe'
if (-not (Test-Path $cl)) { $cl = Join-Path $msvc.FullName 'bin\HostX64\arm64\cl.exe' }
# cl needs MSVC's environment (INCLUDE); a C file with no includes needs none.
Push-Location $work
& $cl /nologo /c t.c /Fot.obj | Out-Host
Pop-Location
if (-not (Test-Path "$work\t.obj")) { "no object compiled: the probe can't go on"; return }

# The same object deep enough that the full path is about 285 characters,
# its path relative to $work (Bazel's execution root) as Bazel's are.
$relative = 'bazel-out\arm64_windows-opt-exec\bin\external\rules_swift_package_manager++swift_deps+swiftpkg_swift_protobuf\SwiftProtobufPluginLibrary.rspm.__impl_objs\Sources\SwiftProtobufPluginLibrary\Google_Protobuf_Compiler_CodeGeneratorResponse+Extensions.swift.o'
$deep = Join-Path $work $relative
New-Item -ItemType Directory -Force (Split-Path $deep) | Out-Null
Copy-Item "$work\t.obj" $deep
"full path: $($deep.Length) characters (relative $($relative.Length))"

$candidates = [ordered]@{
    'MSVC HostX64 lib.exe'   = Join-Path $msvc.FullName 'bin\HostX64\arm64\lib.exe'
    'MSVC HostARM64 lib.exe' = Join-Path $msvc.FullName 'bin\HostARM64\arm64\lib.exe'
    'MSVC HostARM64 link.exe /lib' = Join-Path $msvc.FullName 'bin\HostARM64\arm64\link.exe'
    'LLVM llvm-lib.exe'      = 'C:\Program Files\LLVM\bin\llvm-lib.exe'
    'VS LLVM llvm-lib.exe'   = Join-Path $vs 'VC\Tools\Llvm\ARM64\bin\llvm-lib.exe'
}
foreach ($name in $candidates.Keys) {
    $tool = $candidates[$name]
    if (-not (Test-Path $tool)) { "${name}: not here ($tool)"; continue }
    Remove-Item "$work\out.lib" -ErrorAction SilentlyContinue
    Push-Location $work
    $arguments = if ($name -like '*link.exe*') { @('/lib', '/nologo', '/OUT:out.lib', $relative) } else { @('/nologo', '/OUT:out.lib', $relative) }
    $output = & $tool @arguments 2>&1 | Out-String
    $status = $LASTEXITCODE
    Pop-Location
    $made = Test-Path "$work\out.lib"
    "${name}: exit $status, archive made: $made $(if (-not $made) { '- ' + $output.Trim() })"
}
