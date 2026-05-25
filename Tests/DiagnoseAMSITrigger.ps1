# Tests/DiagnoseAMSITrigger.ps1
# Binary-searches Amnesiac.ps1 to locate every AMSI-flagging line or range.
# Calls AmsiScanString directly — content is scanned but NEVER executed.
# Run from repo root or any directory.

Set-Location 'C:\Users\localuser\Downloads\Amnesiac-main\Amnesiac-main'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class AmsiDiag {
    [DllImport("amsi.dll", CharSet=CharSet.Unicode)]
    public static extern int AmsiInitialize(string app, out IntPtr ctx);
    [DllImport("amsi.dll")]
    public static extern void AmsiUninitialize(IntPtr ctx);
    [DllImport("amsi.dll")]
    public static extern int AmsiOpenSession(IntPtr ctx, out IntPtr session);
    [DllImport("amsi.dll")]
    public static extern void AmsiCloseSession(IntPtr ctx, IntPtr session);
    [DllImport("amsi.dll", CharSet=CharSet.Unicode)]
    public static extern int AmsiScanString(IntPtr ctx, string str, string name, IntPtr session, out int result);
    public static bool IsMalware(int r) { return r >= 32768; }
}
'@

$ctx  = [IntPtr]::Zero
$sess = [IntPtr]::Zero
if ([AmsiDiag]::AmsiInitialize('AmsiDiag', [ref]$ctx) -ne 0) {
    Write-Host '[-] AmsiInitialize failed — AMSI may be patched in this process already.' -ForegroundColor Red; exit 1
}
if ([AmsiDiag]::AmsiOpenSession($ctx, [ref]$sess) -ne 0) {
    Write-Host '[-] AmsiOpenSession failed.' -ForegroundColor Red; exit 1
}

function Invoke-AmsiScan([string]$text) {
    $r = 0
    $null = [AmsiDiag]::AmsiScanString($ctx, $text, 'scan', $sess, [ref]$r)
    return [AmsiDiag]::IsMalware($r)
}

$target = '.\Amnesiac.ps1'
$lines  = Get-Content $target
Write-Host "[*] Loaded $($lines.Count) lines from $target" -ForegroundColor Cyan

# Verify the full file actually flags before spending time searching
if (-not (Invoke-AmsiScan ($lines -join "`n"))) {
    Write-Host ''
    Write-Host '[?] Full file is NOT flagged by AMSI in this session.' -ForegroundColor Yellow
    Write-Host '    Possible reasons:' -ForegroundColor Yellow
    Write-Host '      - AMSI is already patched in this PowerShell process' -ForegroundColor Yellow
    Write-Host '      - Detection is behavioral (triggers on execution, not string scan)' -ForegroundColor Yellow
    Write-Host '      - Defender definitions changed since the block occurred' -ForegroundColor Yellow
    [AmsiDiag]::AmsiCloseSession($ctx, $sess); [AmsiDiag]::AmsiUninitialize($ctx)
    exit 0
}

Write-Host '[!] Full file flags AMSI. Binary-searching for trigger(s)...' -ForegroundColor Red
Write-Host ''

$triggers = [System.Collections.Generic.List[hashtable]]::new()

# Precondition: lines[$lo..$hi] is already known to flag AMSI.
# Finds the minimum sub-range(s) responsible and appends to $triggers.
function Search-Range([int]$lo, [int]$hi) {
    if ($lo -eq $hi) {
        $preview = $lines[$lo]
        if ($preview.Length -gt 120) { $preview = $preview.Substring(0, 120) + '...' }
        $triggers.Add(@{ Lo = $lo; Hi = $hi; Type = 'single' })
        Write-Host "  [TRIGGER] Line $($lo+1): $preview" -ForegroundColor Red
        return
    }

    $mid = [math]::Floor(($lo + $hi) / 2)
    $firstFlags  = Invoke-AmsiScan (($lines[$lo..$mid])     -join "`n")
    $secondFlags = Invoke-AmsiScan (($lines[($mid+1)..$hi]) -join "`n")

    if ($firstFlags)  { Search-Range $lo       $mid  }
    if ($secondFlags) { Search-Range ($mid + 1) $hi   }

    if (-not $firstFlags -and -not $secondFlags) {
        # Neither half flags alone — signature spans the boundary
        $triggers.Add(@{ Lo = $lo; Hi = $hi; Type = 'multipart' })
        Write-Host "  [TRIGGER] Multi-part signature: lines $($lo+1)-$($hi+1) (neither half flags alone)" -ForegroundColor Yellow
    }
}

Search-Range 0 ($lines.Count - 1)

[AmsiDiag]::AmsiCloseSession($ctx, $sess)
[AmsiDiag]::AmsiUninitialize($ctx)

Write-Host ''
if ($triggers.Count -eq 0) {
    Write-Host '[?] Could not isolate a trigger — may require execution context (behavioral detection).' -ForegroundColor Yellow
} else {
    Write-Host "[+] $($triggers.Count) trigger(s) found:" -ForegroundColor Green
    foreach ($t in $triggers) {
        if ($t.Type -eq 'single') {
            Write-Host "  Line $($t.Lo + 1)  [$($t.Type)]" -ForegroundColor Yellow
        } else {
            Write-Host "  Lines $($t.Lo + 1)-$($t.Hi + 1)  [$($t.Type)]" -ForegroundColor Yellow
            Write-Host '  Tip: narrow further by commenting out lines in that range and re-running.' -ForegroundColor Cyan
        }
    }
    Write-Host ''
    Write-Host 'Next step: fix or obfuscate the flagged content, then re-run this script to confirm clean.' -ForegroundColor Cyan
}
