$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$logDirectory = 'C:\OmnideckLab'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
Start-Transcript -Path "$logDirectory\provision.log" -Append

try {
    powercfg.exe /change standby-timeout-ac 0 | Out-Null
    powercfg.exe /change monitor-timeout-ac 0 | Out-Null

    $network = Get-NetConnectionProfile -ErrorAction SilentlyContinue
    if ($network) {
        $network | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue
    }

    $serverCapability = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
    if ($serverCapability.State -ne 'Installed') {
        Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
    }

    Set-Service -Name sshd -StartupType Automatic
    if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule `
            -Name 'OpenSSH-Server-In-TCP' `
            -DisplayName 'OpenSSH Server (sshd)' `
            -Enabled True `
            -Direction Inbound `
            -Protocol TCP `
            -Action Allow `
            -LocalPort 22 | Out-Null
    }

    $sshDirectory = Join-Path $env:ProgramData 'ssh'
    New-Item -ItemType Directory -Path $sshDirectory -Force | Out-Null
    $authorizedKeys = Join-Path $sshDirectory 'administrators_authorized_keys'
    Set-Content `
        -Path $authorizedKeys `
        -Encoding ascii `
        -Value 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBtgEDHDtGv8c9hkTV4D2U1RuLha5n1YvfqxlTd5tAqv omnideck-release-lab'
    icacls.exe $authorizedKeys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null

    Start-Service -Name sshd

    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '0'
    Remove-ItemProperty -Path $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue

    New-Item -ItemType File -Path 'C:\omnideck-lab-ready' -Force | Out-Null
}
finally {
    Stop-Transcript
}
