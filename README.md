# Donna maintenance access (VPS)

Narrow maintenance access for the Hermes agent on the Hetzner VPS 188.245.92.13.

What it grants: `status` (read-only report) and `apt` (unattended-upgrade of installed packages).
Force-commanded SSH key, no shell, no docker, no file writes outside /var/log.

Install (as root on the VPS):

    curl -fsSL https://raw.githubusercontent.com/HBHManagement/vps-maint/main/install.sh | bash

Revoke:

    userdel -r hermes-maint; rm -f /etc/sudoers.d/hermes-maint /usr/local/bin/vps-maint.sh /usr/local/bin/vps-maint-shell.sh
