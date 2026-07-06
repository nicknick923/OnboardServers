#Requires -RunAsAdministrator
# Onboards this Windows machine into the Tom SSH CA.

$Tom = "nick@tom"
$Name = $env:COMPUTERNAME.ToLower()

$defaultIfIndex = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
	Sort-Object RouteMetric | Select-Object -First 1).InterfaceIndex
$IP = (Get-NetIPAddress -InterfaceIndex $defaultIfIndex -AddressFamily IPv4).IPAddress

$ErrorActionPreference = 'Stop'

$TOM_USER_CA_PUB = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINC9Khi3GLlzHOFlzZVLE1xJXhEN5qPCW3gCSAdHVm7g Tom User CA"
$TOM_HOST_CA_PUB = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMBobXiJCfE3mb3niwj4ynngKK2NSUuTeEhW+Q8UWq7F Tom Host CA"

$SSH_SYS_DIR  = "C:\ProgramData\ssh"
$USER_SSH_DIR = "$env:USERPROFILE\.ssh"
$SSHD_CONFIG  = "$SSH_SYS_DIR\sshd_config"
$utf8         = [System.Text.UTF8Encoding]::new($false)

# Upserts a global sshd_config directive, always before the first Match block.
function Set-SshdDirective([string]$Path, [string]$Name, [string]$Value) {
    $lines = [System.IO.File]::ReadAllLines($Path, $utf8)
    $lines = @($lines | Where-Object { $_ -notmatch "^\s*$Name\s" })
    $matchIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*Match\b') { $matchIdx = $i; break }
    }
    $entry = "$Name $Value"
    if ($matchIdx -ge 0) {
        $lines = @($lines[0..($matchIdx - 1)]) + $entry + @($lines[$matchIdx..($lines.Count - 1)])
    } else {
        $lines = $lines + $entry
    }
    [System.IO.File]::WriteAllLines($Path, $lines, $utf8)
}

Write-Host ""
Write-Host "=== SSH CA Onboarding: $Name ($IP) ===" -ForegroundColor Cyan
Write-Host ""

# --- 0. Install OpenSSH Client and Server if missing ---
Write-Host "[0/6] Checking OpenSSH prerequisites..."

function Install-OpenSSHCap([string]$CapName) {
    $cap = Get-WindowsCapability -Online -Name $CapName
    if ($cap.State -ne 'Installed') {
        Write-Host "  Installing $CapName ..."
        Add-WindowsCapability -Online -Name $CapName | Out-Null
        Write-Host "  Done."
    } else {
        Write-Host "  $CapName already installed."
    }
}

Install-OpenSSHCap 'OpenSSH.Client~~~~0.0.1.0'
Install-OpenSSHCap 'OpenSSH.Server~~~~0.0.1.0'

# Repair sshd_config from any previous partial run before starting sshd
if (Test-Path $SSHD_CONFIG) {
    $cfgText = [System.IO.File]::ReadAllText($SSHD_CONFIG, $utf8)
    if ($cfgText -match 'TrustedUserCAKeys') {
        Set-SshdDirective $SSHD_CONFIG 'TrustedUserCAKeys' "$SSH_SYS_DIR\tom_user_ca.pub"
    }
    $hostCert = "$SSH_SYS_DIR\ssh_host_ed25519_key-cert.pub"
    if ($cfgText -match 'HostCertificate') {
        if (Test-Path $hostCert) {
            Set-SshdDirective $SSHD_CONFIG 'HostCertificate' $hostCert
        } else {
            $cleaned = [System.IO.File]::ReadAllLines($SSHD_CONFIG, $utf8) |
                       Where-Object { $_ -notmatch '^\s*HostCertificate\s' }
            [System.IO.File]::WriteAllLines($SSHD_CONFIG, @($cleaned), $utf8)
        }
    }
}

# Ensure sshd and ssh-agent are running and set to auto-start
foreach ($svc in 'sshd', 'ssh-agent') {
    Set-Service $svc -StartupType Automatic
    if ((Get-Service $svc).Status -ne 'Running') {
        try {
            Start-Service $svc
            Write-Host "  Started $svc."
        } catch {
            Write-Host "  Failed to start $svc. Recent event log:" -ForegroundColor Red
            Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 10 -ErrorAction SilentlyContinue |
                ForEach-Object { Write-Host "  [$($_.TimeCreated)] $($_.Message)" }
            Get-EventLog -LogName System -Source sshd -Newest 5 -ErrorAction SilentlyContinue |
                ForEach-Object { Write-Host "  [$($_.TimeGenerated)] $($_.Message)" }
            throw $_
        }
    }
}

# sshd_config is only created after the first sshd start; wait briefly if needed
if (-not (Test-Path $SSHD_CONFIG)) {
    Write-Host "  Waiting for sshd_config to be generated..."
    $deadline = (Get-Date).AddSeconds(15)
    while (-not (Test-Path $SSHD_CONFIG) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
    }
    if (-not (Test-Path $SSHD_CONFIG)) {
        throw "sshd_config was not created at $SSHD_CONFIG - check OpenSSH Server installation."
    }
}

# --- 1. Trust Tom-signed user certs for incoming connections ---
Write-Host "[1/6] Configuring TrustedUserCAKeys..."
$caFile = "$SSH_SYS_DIR\tom_user_ca.pub"
[System.IO.File]::WriteAllText($caFile, "$TOM_USER_CA_PUB`n", $utf8)
Set-SshdDirective $SSHD_CONFIG 'TrustedUserCAKeys' $caFile

# --- 2. Trust Tom's host CA for outgoing SSH ---
Write-Host "[2/6] Trusting Tom host CA in $SSH_SYS_DIR\ssh_known_hosts..."
$knownHostsFile = "$SSH_SYS_DIR\ssh_known_hosts"
$caEntry = "@cert-authority * $TOM_HOST_CA_PUB"
if (-not (Test-Path $knownHostsFile) -or (Get-Content $knownHostsFile -Raw) -notmatch [regex]::Escape($TOM_HOST_CA_PUB)) {
    [System.IO.File]::AppendAllText($knownHostsFile, "$caEntry`n", $utf8)
}

# --- 3. Generate user key (ed25519) if missing ---
Write-Host "[3/6] Checking user key..."
if (-not (Test-Path $USER_SSH_DIR)) {
    New-Item -ItemType Directory -Path $USER_SSH_DIR | Out-Null
}
$userKey = "$USER_SSH_DIR\id_ed25519"
if (-not (Test-Path $userKey)) {
    & ssh-keygen -t ed25519 -f $userKey -N ''
    Write-Host "      Generated new ed25519 key."
} else {
    Write-Host "      Key already exists."
}

# --- 4. Copy keys to Tom ---
# Windows OpenSSH does not support ControlMaster; each call is a separate connection.
Write-Host "[4/6] Copying keys to Tom (you may be prompted for credentials)..."
$hostPub = "$SSH_SYS_DIR\ssh_host_ed25519_key.pub"
& scp $hostPub "$userKey.pub" "${Tom}:/tmp/"

# --- 5. Sign keys on Tom and retrieve certs ---
Write-Host "[5/6] Signing on Tom (you will be prompted for each CA passphrase)..."
$remoteSign = (
    "ssh-keygen -s ~/.ssh/ca/tom_host_ca -I '$Name' -h " +
    "-n '$Name,$Name.lan,$IP' -V +52w /tmp/ssh_host_ed25519_key.pub && " +
    "ssh-keygen -s ~/.ssh/ca/tom_user_ca -I '$Name' -n nick,root -V +52w /tmp/id_ed25519.pub"
)
& ssh -t $Tom $remoteSign

Write-Host "  Retrieving signed certs..."
& scp "${Tom}:/tmp/ssh_host_ed25519_key-cert.pub" "$SSH_SYS_DIR\ssh_host_ed25519_key-cert.pub"
& scp "${Tom}:/tmp/id_ed25519-cert.pub"           "$USER_SSH_DIR\id_ed25519-cert.pub"
& ssh $Tom "rm -f /tmp/ssh_host_ed25519_key.pub /tmp/ssh_host_ed25519_key-cert.pub /tmp/id_ed25519.pub /tmp/id_ed25519-cert.pub"

Set-SshdDirective $SSHD_CONFIG 'HostCertificate' "$SSH_SYS_DIR\ssh_host_ed25519_key-cert.pub"

# --- 6. Restart sshd ---
Write-Host "[6/6] Restarting sshd..."

$testOut = & "$env:SystemRoot\System32\OpenSSH\sshd.exe" -t 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  sshd config test failed:" -ForegroundColor Red
    $testOut | ForEach-Object { Write-Host "    $_" }
    throw "Fix the sshd_config errors above before restarting."
}

try {
    Restart-Service sshd
} catch {
    Write-Host "  sshd failed to start. Recent event log:" -ForegroundColor Red
    Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 10 -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host "  [$($_.TimeCreated)] $($_.Message)" }
    Get-EventLog -LogName System -Source sshd -Newest 5 -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host "  [$($_.TimeGenerated)] $($_.Message)" }
    throw $_
}

Write-Host ""
Write-Host "=== Done! $Name is fully onboarded. ===" -ForegroundColor Green
Write-Host ""
Write-Host "Verify from another machine:"
Write-Host "  ssh $env:USERNAME@$IP 'echo ok'"
Write-Host ""
Write-Host "Optional - disable password auth (only after verifying cert login works):"
Write-Host "  Add 'PasswordAuthentication no' to $SSHD_CONFIG and restart sshd."
