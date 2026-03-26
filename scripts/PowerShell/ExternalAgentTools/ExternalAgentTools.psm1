function Invoke-ExternalAgent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter()]
        [Alias("Args")]
        [string[]]$ArgumentList,

        [string]$LogFile = "agent-output.log"
    )

    # Normalize arguments
    $argsString = switch ($ArgumentList) {
        $null { "" }
        { $_ -is [string] } { $_ }
        { $_ -is [array] } { $_ -join " " }
        default { $_.ToString() }
    }

    Write-Host "Executing command: $Command $argsString"

    # Prepare process start info
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Command
    $psi.Arguments = $argsString
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
        param($sender, $args)
        if ($args.Data) {
            Write-Host $args.Data
            $logWriter.WriteLine((Add-Timestamp $args.Data "OUT"))
            $logWriter.Flush()
        }
    })

    $proc.add_ErrorDataReceived({
        param($sender, $args)
        if ($args.Data) {
            Write-Host $args.Data -ForegroundColor Red
            $logWriter.WriteLine((Add-Timestamp $args.Data "ERR"))
            $logWriter.Flush()
        }
    })

    $proc.Start()
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()
    $proc.WaitForExit()

    $logWriter.Close()

    return $proc.ExitCode
}

Export-ModuleMember -Function Invoke-ExternalAgent
