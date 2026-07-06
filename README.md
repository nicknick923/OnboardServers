# SSH CA Onboarding Scripts

Two scripts that fully automate adding a new machine to the Tom SSH CA trust network — trusting the user CA, trusting the host CA, generating a key, signing both keys on Tom, deploying the certs, and restarting sshd.

**Prerequisites for either script:**
- Network access to Tom (`nick@tom`)
- The Tom user CA and host CA passphrases (stored in password manager)

---

## New Linux/Ubuntu server

Run from **Frank (Git Bash)**. Agent forwarding (`-A`) lets the new server reach Tom for signing.

```bash
ssh -A root@<newip> 'bash <(curl -fsSL https://raw.githubusercontent.com/nicknick923/OnboardServers/main/onboard-new-server.sh)'
```

**What to expect:**
1. One password prompt to connect to Tom (ControlMaster keeps it open for all transfers)
2. Prompted for the **host CA passphrase**, then the **user CA passphrase**
3. Certs are deployed, sshd restarts, temp files on Tom are cleaned up

Verify afterwards:
```bash
ssh root@<newip> 'echo ok'
```

---

## New Windows machine

Run in an **elevated PowerShell window** (Run as Administrator) on the machine being onboarded.

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; irm https://raw.githubusercontent.com/nicknick923/OnboardServers/main/onboard.ps1 | iex
```

**What to expect:**
1. OpenSSH Client and Server installed if missing
2. Multiple prompts for Tom credentials (Windows OpenSSH lacks ControlMaster)
3. Prompted for the **host CA passphrase**, then the **user CA passphrase**
4. Certs deployed, sshd config updated and restarted

Verify from Frank afterwards:
```powershell
ssh <user>@<newip> 'echo ok'
```

---

## Other docs

| Scenario | Doc |
|----------|-----|
| Adding a new Linux server manually (step-by-step) | [`docs/add-new-server.md`](docs/add-new-server.md) |
| Giving a new device (laptop, phone) SSH access | [`docs/add-new-admin-device.md`](docs/add-new-admin-device.md) |
| iPhone setup via Termius | [`docs/iphone-termius-setup.md`](docs/iphone-termius-setup.md) |
