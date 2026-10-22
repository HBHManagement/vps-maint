#!/bin/bash
# ============================================================================
#  Donna Maintenance Access + vollautomatische Updates — als root auf dem VPS.
#
#  Teil 1 (Zugang, eng):
#   1. User hermes-maint, Login-Shell = Wrapper, der nur vps-maint.sh startet
#   2. Aktionen: status | apt | diag   (diag liest ausschliesslich)
#   3. sudoers: hermes-maint darf NUR apt-get/apt/dpkg
#   4. EIN SSH-Key, forced command, Log unter /var/log/vps-maint.log
#
#  Teil 2 (Automatik, damit niemand mehr von Hand patcht):
#   5. /etc/apt/apt.conf.d/20auto-upgrades       taeglich Listen + unattended-upgrade
#   6. /etc/apt/apt.conf.d/51-donna-auto.conf    Security UND normale Updates,
#                                                Reboot 04:30 UTC nur wenn noetig
#   7. apt-daily-upgrade.timer auf 03:00 UTC (05:00 MESZ)
#
#  Rueckgaengig: userdel -r hermes-maint
#                rm -f /etc/sudoers.d/hermes-maint /usr/local/bin/vps-maint*.sh
#                rm -f /etc/apt/apt.conf.d/51-donna-auto.conf
# ============================================================================
set -euo pipefail

PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMJLn6AIYYIKE9jY5bN/M6sFL8qd7tuit4CC3+sfeqG1 hermes-maint@vps'
LOG=/var/log/vps-maint.log

[ "$(id -u)" -eq 0 ] || { echo "Als root ausfuehren."; exit 1; }

# ---------------------------------------------------------------- maint script
cat > /usr/local/bin/vps-maint.sh <<'MAINT'
#!/bin/bash
# vps-maint.sh — Aktionen: status | apt | diag (diag liest nur)
set -uo pipefail
LOG=/var/log/vps-maint.log
say() { printf '%s\n' "$*" | tee -a "$LOG"; }

case "${1:-status}" in
  status)
    say "=== $(date -Is) status ==="
    say "uptime: $(uptime -p)"
    say "kernel: $(uname -r)"
    say "disk: $(df -h / | awk 'NR==2{print $5" used, "$4" free"}')"
    say "ram: $(free -m | awk 'NR==2{printf "%sMB used of %sMB", $3, $2}')"
    pend=$(sudo /usr/bin/apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true)
    say "updates pending: $pend"
    [ -f /var/run/reboot-required ] && say "reboot required: YES" || say "reboot required: no"
    say "---"
    ;;
  diag)
    say "=== $(date -Is) diag (nur lesen) ==="
    say "--- 20auto-upgrades ---"
    if [ -r /etc/apt/apt.conf.d/20auto-upgrades ]; then
      grep -Ev '^[[:space:]]*(//|$)' /etc/apt/apt.conf.d/20auto-upgrades || say "(leer)"
    else say "FEHLT"; fi
    say "--- 51-donna-auto.conf ---"
    if [ -r /etc/apt/apt.conf.d/51-donna-auto.conf ]; then
      grep -Ev '^[[:space:]]*(//|$)' /etc/apt/apt.conf.d/51-donna-auto.conf
    else say "FEHLT"; fi
    say "--- Automatic-Reboot (50unattended-upgrades) ---"
    grep -E '^[^/]*Unattended-Upgrade::Automatic-Reboot' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null || say "(kein aktiver Eintrag)"
    say "--- Timer ---"
    systemctl list-timers apt-daily-upgrade.timer --no-pager 2>/dev/null | sed -n '1,3p' || say "(kein Timer)"
    say "--- letzte unattended-upgrades Laeufe ---"
    if [ -r /var/log/unattended-upgrades/unattended-upgrades.log ]; then
      tail -n 12 /var/log/unattended-upgrades/unattended-upgrades.log
    else say "(kein Log, Automatik lief nie)"; fi
    say "---"
    ;;
  apt)
    say "=== $(date -Is) apt upgrade start ==="
    export DEBIAN_FRONTEND=noninteractive
    sudo /usr/bin/apt-get update -qq
    sudo /usr/bin/apt-get -y -o Dpkg::Options::=--force-confold upgrade
    say "upgrade rc=$?"
    sudo /usr/bin/apt-get -y -o Dpkg::Options::=--force-confold autoremove
    pend=$(sudo /usr/bin/apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true)
    say "updates pending after: $pend"
    [ -f /var/run/reboot-required ] && say "reboot required: YES" || say "reboot required: no"
    say "---"
    ;;
  *)
    say "unbekannte aktion: ${1:-}"
    exit 2
    ;;
esac
MAINT
chmod 755 /usr/local/bin/vps-maint.sh

cat > /usr/local/bin/vps-maint-shell.sh <<'SHELL'
#!/bin/bash
exec /usr/local/bin/vps-maint.sh "${SSH_ORIGINAL_COMMAND:-status}"
SHELL
chmod 755 /usr/local/bin/vps-maint-shell.sh

# ---------------------------------------------------------------- user
id -u hermes-maint >/dev/null 2>&1 || useradd -m -s /usr/local/bin/vps-maint-shell.sh hermes-maint
usermod -s /usr/local/bin/vps-maint-shell.sh hermes-maint

install -d -m 700 -o hermes-maint -g hermes-maint /home/hermes-maint/.ssh
printf 'restrict,command="/usr/local/bin/vps-maint-shell.sh" %s\n' "$PUBKEY" > /home/hermes-maint/.ssh/authorized_keys
chown hermes-maint:hermes-maint /home/hermes-maint/.ssh/authorized_keys
chmod 600 /home/hermes-maint/.ssh/authorized_keys

# ---------------------------------------------------------------- sudoers
printf 'hermes-maint ALL=(root) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt, /usr/bin/dpkg\n' > /etc/sudoers.d/hermes-maint
chmod 440 /etc/sudoers.d/hermes-maint
visudo -cf /etc/sudoers.d/hermes-maint >/dev/null || { echo "sudoers ungueltig, Abbruch"; rm -f /etc/sudoers.d/hermes-maint; exit 1; }

# ---------------------------------------------------------------- log
touch "$LOG"; chown root:hermes-maint "$LOG"; chmod 664 "$LOG"

# ---------------------------------------------------------------- Automatik
echo "== Vollautomatische Updates einrichten =="

printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\nAPT::Periodic::AutocleanInterval "7";\n' \
  > /etc/apt/apt.conf.d/20auto-upgrades

cat > /etc/apt/apt.conf.d/51-donna-auto.conf <<'AUTO'
// Donna: Security- UND normale Updates automatisch, Reboot nur wenn noetig.
Unattended-Upgrade::Origins-Pattern {
        "origin=Ubuntu,codename=${distro_codename},label=Ubuntu";
        "origin=Ubuntu,codename=${distro_codename}-security,label=Ubuntu";
        "origin=Ubuntu,codename=${distro_codename}-updates,label=Ubuntu";
        "origin=UbuntuESM,codename=${distro_codename},label=UbuntuESM";
        "origin=UbuntuESMApps,codename=${distro_codename}-apps-security,label=UbuntuESMApps";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
AUTO
chmod 644 /etc/apt/apt.conf.d/51-donna-auto.conf

if grep -qE '^Unattended-Upgrade::Automatic-Reboot "false";' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null; then
  sed -i 's|^Unattended-Upgrade::Automatic-Reboot "false";|//Unattended-Upgrade::Automatic-Reboot "false"; // Donna: gesteuert in 51-donna-auto.conf|' /etc/apt/apt.conf.d/50unattended-upgrades
fi

install -d /etc/systemd/system/apt-daily-upgrade.timer.d
printf '[Timer]\nOnCalendar=\nOnCalendar=*-*-* 03:00:00\nRandomizedDelaySec=0\n' \
  > /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf
systemctl daemon-reload
systemctl enable --now apt-daily-upgrade.timer >/dev/null 2>&1 || true
systemctl restart apt-daily-upgrade.timer >/dev/null 2>&1 || true

echo "== Fertig =="
echo "Zugang:   ssh -i hermes-maint hermes-maint@188.245.92.13 status | apt | diag"
echo "Automatik: taeglich 03:00 UTC (05:00 MESZ), Reboot 04:30 UTC nur bei Kernel-Update."
