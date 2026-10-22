#!/bin/bash
# ============================================================================
#  Donna Maintenance Access — einmalig als root auf dem VPS ausfuehren.
#
#  Was es macht:
#   1. legt User hermes-maint an (Login-Shell = Wrapper, der nur vps-maint.sh startet)
#   2. schreibt /usr/local/bin/vps-maint.sh (Allowlist: status | apt)
#   3. sudoers: hermes-maint darf NUR apt-get/Debian-Frontend aufrufen
#   4. traegt EINEN SSH-Key ein, der nur dieses Script starten kann
#   5. legt ein Log an: /var/log/vps-maint.log
#
#  Was es NICHT macht: kein Docker-Zugriff, kein rm, kein Editieren von Configs,
#  kein Schreiben ausserhalb von /var/log und den apt-Verzeichnissen.
#  Rueckgaengig: userdel -r hermes-maint; rm /etc/sudoers.d/hermes-maint \
#                /usr/local/bin/vps-maint.sh /usr/local/bin/vps-maint-shell.sh
# ============================================================================
set -euo pipefail

PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMJLn6AIYYIKE9jY5bN/M6sFL8qd7tuit4CC3+sfeqG1 hermes-maint@vps'
LOG=/var/log/vps-maint.log

[ "$(id -u)" -eq 0 ] || { echo "Als root ausfuehren."; exit 1; }

# ---------------------------------------------------------------- maint script
cat > /usr/local/bin/vps-maint.sh <<'MAINT'
#!/bin/bash
# vps-maint.sh — genau zwei Aktionen: status | apt
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
    pend=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true)
    say "updates pending: $pend"
    [ -f /var/run/reboot-required ] && say "reboot required: YES" || say "reboot required: no"
    say "---"
    ;;
  apt)
    say "=== $(date -Is) apt upgrade start ==="
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get -y -o Dpkg::Options::=--force-confold upgrade
    say "upgrade rc=$?"
    apt-get -y -o Dpkg::Options::=--force-confold autoremove
    pend=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true)
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
touch "$LOG"; chmod 644 "$LOG"

echo "OK. Donna hat jetzt engen Wartungs-Zugriff: status | apt (sudo nur apt-get)."
echo "Test: ssh -i hermes-maint hermes-maint@188.245.92.13 status"
