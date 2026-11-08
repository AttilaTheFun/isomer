# The Windows Storybook's test stories on GitHub's own windows-11-arm runner
# (free for a public repository): the app CI's container built for Windows on
# Arm (tools/ci/container_build.sh: the .exe, the Swift runtime's DLLs and the
# Storybook's assets), run natively, as tools/ci/windows_test.sh runs it under
# Wine in a container. One launch, the stories switched through
# ISO_STORYBOOK_CONTROL; each pictured by the app's window (DWM's frame of
# it) once two pictures in a row agree, and checked for having drawn
# something; the pictures kept in <out>.
#
#   pwsh tools/ci/hosted_windows_test.ps1 <app dir> <out dir>
param(
    [Parameter(Mandatory = $true)][string]$App,
    [Parameter(Mandatory = $true)][string]$Out
)
$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "../..")
$App = (Resolve-Path $App).Path
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$stories = Select-String -Path (Join-Path $root "examples/tests/platforms/stories.bzl") -Pattern '^\s*"([a-z]+\.[a-z]+)",$' |
    ForEach-Object { $_.Matches[0].Groups[1].Value }
if (-not $stories) { throw "hosted_windows_test: no stories" }

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Frame {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out Rect rect, int size);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    public static Rect Of(IntPtr hwnd) {
        Rect rect;
        // DWMWA_EXTENDED_FRAME_BOUNDS: the window as drawn, without its shadow.
        DwmGetWindowAttribute(hwnd, 9, out rect, Marshal.SizeOf(typeof(Rect)));
        return rect;
    }
}
"@
[Frame]::SetProcessDPIAware() | Out-Null

# The assets by the app's runfiles paths, as windows_test.sh lays them out.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("isomer-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
$manifest = Join-Path $work "manifest"
Get-ChildItem -Recurse -File -Path (Join-Path $App "assets") -Filter *.png | ForEach-Object {
    $relative = $_.FullName.Substring($App.Length + 1).Replace('\', '/')
    "storybook/$relative $($_.FullName)"
} | Set-Content -Path $manifest
$control = Join-Path $work "control"
Set-Content -Path $control -Value $stories[0] -NoNewline

$env:RUNFILES_MANIFEST_FILE = $manifest
$env:ISO_STORYBOOK_CONTROL = $control
$exe = Get-ChildItem -Path $App -Filter *.exe | Select-Object -First 1
$process = Start-Process -FilePath $exe.FullName -WorkingDirectory $App -PassThru `
    -RedirectStandardOutput (Join-Path $Out "storybook.log") -RedirectStandardError (Join-Path $Out "storybook.err.log")

function Shoot([string]$path) {
    $process.Refresh()
    $hwnd = $process.MainWindowHandle
    if ($hwnd -eq [IntPtr]::Zero) { return $false }
    [Frame]::SetForegroundWindow($hwnd) | Out-Null
    $rect = [Frame]::Of($hwnd)
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -le 0 -or $height -le 0) { return $false }
    $bitmap = New-Object System.Drawing.Bitmap $width, $height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose()
    $bitmap.Dispose()
    return $true
}

# Two pictures in a row alike, at most a few more tries.
function Steady([string]$path) {
    for ($try = 0; -not (Shoot $path); $try++) {
        if ($try -ge 5) { return $false }
        Start-Sleep -Seconds 2
    }
    for ($i = 0; $i -lt 5; $i++) {
        Start-Sleep -Seconds 2
        $again = "$path.again.png"
        if (-not (Shoot $again)) { continue }
        if ((Get-FileHash $path).Hash -eq (Get-FileHash $again).Hash) { Remove-Item $again; return $true }
        Move-Item -Force $again $path
    }
    return $true
}

# Its window, once it has one.
for ($i = 0; $i -lt 60 -and $process.MainWindowHandle -eq [IntPtr]::Zero; $i++) {
    Start-Sleep -Seconds 1
    $process.Refresh()
    if ($process.HasExited) { break }
}
$failures = 0
foreach ($story in $stories) {
    Set-Content -Path $control -Value $story -NoNewline
    $shown = ""
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Path "$control.shown") { $shown = (Get-Content "$control.shown" -Raw).Trim() }
        if ($shown -eq $story) { break }
    }
    Start-Sleep -Seconds 2
    $path = Join-Path $Out "windows-$story.png"
    # A picture of almost nothing (one colour compresses to a few KB): nothing drawn.
    if ($shown -eq $story -and (Steady $path) -and (Get-Item $path).Length -gt 20000) {
        Write-Output "hosted_windows_test: windows $story"
    } else {
        Write-Output "hosted_windows_test: windows ${story}: nothing drawn (shown: $shown)"
        $failures++
    }
}
if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
Remove-Item -Recurse -Force $work
Write-Output "hosted_windows_test: $($stories.Count) pictures, $failures failed"
exit ([int]($failures -ne 0))
