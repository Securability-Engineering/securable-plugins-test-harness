function Invoke-ExternalAgent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter()]
        [Alias("Args")]
        [string[]]$ArgumentList,

        [string]$WorkingDirectory,

        [string]$LogFile = "agent-output.log"
    )

    # Normalize arguments to a single string
    $argsString = if ($ArgumentList) { $ArgumentList -join " " } else { "" }

    # Resolve command to an executable that CreateProcess can launch.
    # PowerShell's Get-Command may return .ps1 or .bat/.cmd shims that
    # System.Diagnostics.Process (UseShellExecute=false) cannot start directly.
    $resolved = Get-Command $Command -ErrorAction SilentlyContinue
    if ($resolved) {
        $src = $resolved.Source
        $ext = [System.IO.Path]::GetExtension($src).ToLowerInvariant()
        switch ($ext) {
            '.ps1' {
                # Launch via the current PowerShell host
                $pwsh = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
                $argsString = "-NoProfile -ExecutionPolicy Bypass -File `"$src`" $argsString"
                $Command = $pwsh
            }
            { $_ -in '.bat', '.cmd' } {
                $argsString = "/c `"$src`" $argsString"
                $Command = "cmd.exe"
            }
            default {
                $Command = $src   # use fully-qualified path
            }
        }
    }

    Write-Host "Executing command: $Command $argsString"

    # Prepare process start info
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Command
    $psi.Arguments = $argsString
    if ($WorkingDirectory) {
        $psi.WorkingDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkingDirectory)
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    $logWriter = [System.IO.StreamWriter]::new($LogFile, $true)

    function Add-Timestamp {
        param([string]$Line, [string]$Stream)
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Stream] $Line"
    }

    # Handlers — both streams write to the same log
    $proc.add_OutputDataReceived({
        param($sender, $eventArgs)
        if ($eventArgs.Data) {
            Write-Host $eventArgs.Data
            $logWriter.WriteLine((Add-Timestamp $eventArgs.Data "OUT"))
            $logWriter.Flush()
        }
    })

    $proc.add_ErrorDataReceived({
        param($sender, $eventArgs)
        if ($eventArgs.Data) {
            Write-Host $eventArgs.Data -ForegroundColor Red
            $logWriter.WriteLine((Add-Timestamp $eventArgs.Data "ERR"))
            $logWriter.Flush()
        }
    })

    $proc.Start()
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()
    $proc.WaitForExit()

    $logWriter.Close()

    Write-Host "Command exited with code $($proc.ExitCode)"

    return $proc.ExitCode
}

Export-ModuleMember -Function Invoke-ExternalAgent
