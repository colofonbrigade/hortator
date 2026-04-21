#!/bin/bash
set -e

# --- SSH authorized keys (for Hortator -> worker SSH access) ---
if [ -f /home/worker/.ssh/mounted_authorized_keys ]; then
  cp /home/worker/.ssh/mounted_authorized_keys /home/worker/.ssh/authorized_keys
  chown worker:worker /home/worker/.ssh/authorized_keys
  chmod 600 /home/worker/.ssh/authorized_keys
fi

# --- SSH private key (for worker -> GitHub git operations) ---
if [ -f /home/worker/.ssh/mounted_id ]; then
  cp /home/worker/.ssh/mounted_id /home/worker/.ssh/id_ed25519
  chown worker:worker /home/worker/.ssh/id_ed25519
  chmod 600 /home/worker/.ssh/id_ed25519
fi

chmod 700 /home/worker/.ssh

# Add github.com to known_hosts so git clone doesn't prompt
ssh-keyscan -t ed25519 github.com >> /home/worker/.ssh/known_hosts 2>/dev/null || true
chown worker:worker /home/worker/.ssh/known_hosts

# --- Claude credentials ---
if [ -d /home/worker/.claude-mount ]; then
  cp -r /home/worker/.claude-mount/. /home/worker/.claude/ 2>/dev/null || true
  chown -R worker:worker /home/worker/.claude
fi

# --- GitHub token credential helper for HTTPS clones ---
if [ -n "$GITHUB_TOKEN" ]; then
  su - worker -c 'git config --global credential.helper "!f() { echo password=\$GITHUB_TOKEN; }; f"'
  su - worker -c "gh auth status" 2>/dev/null \
    && echo "[hortator] gh CLI authenticated" \
    || echo "[hortator] WARNING: gh auth failed (GITHUB_TOKEN may be invalid)"
else
  echo "[hortator] WARNING: GITHUB_TOKEN not set; gh CLI and HTTPS git will not authenticate"
fi

# Start sshd in foreground
exec /usr/sbin/sshd -D -e
