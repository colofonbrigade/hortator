#!/bin/bash
set -e

# --- SSH authorized keys (for Hortator -> worker SSH access) ---
if [ -f /home/worker/.ssh/mounted_authorized_keys ]; then
  cp /home/worker/.ssh/mounted_authorized_keys /home/worker/.ssh/authorized_keys
  chown worker:worker /home/worker/.ssh/authorized_keys
  chmod 600 /home/worker/.ssh/authorized_keys
fi

chmod 700 /home/worker/.ssh

# Add github.com to known_hosts so git clone doesn't prompt
ssh-keyscan -t ed25519 github.com >> /home/worker/.ssh/known_hosts 2>/dev/null || true
chown worker:worker /home/worker/.ssh/known_hosts

# --- SSH agent forwarding ---
# The host's SSH agent socket is mounted at /ssh-agent. Make it accessible
# to the worker user and set it in /etc/environment so sshd login sessions
# pick it up (sshd doesn't source .bashrc or inherit Docker env vars).
if [ -S /ssh-agent ]; then
  chmod 777 /ssh-agent
  echo 'SSH_AUTH_SOCK=/ssh-agent' >> /etc/environment
  echo 'SSH_AUTH_SOCK=/ssh-agent' >> /home/worker/.ssh/environment
  chown worker:worker /home/worker/.ssh/environment
  echo 'export SSH_AUTH_SOCK=/ssh-agent' >> /home/worker/.bashrc
  echo "[hortator] SSH agent socket forwarded"
else
  echo "[hortator] WARNING: SSH agent socket not available at /ssh-agent"
fi

# --- Claude credentials ---
if [ -d /home/worker/.claude-mount ]; then
  cp -r /home/worker/.claude-mount/. /home/worker/.claude/ 2>/dev/null || true
  chown -R worker:worker /home/worker/.claude
fi

# --- gh CLI token ---
# gh reads GH_TOKEN from the environment. Write it to the worker's SSH
# environment file so sshd sessions (which don't inherit Docker env vars)
# also have it. PermitUserEnvironment is enabled in sshd_config.
if [ -n "$GH_TOKEN" ]; then
  echo "GH_TOKEN=$GH_TOKEN" >> /home/worker/.ssh/environment
  echo "GITHUB_TOKEN=$GH_TOKEN" >> /home/worker/.ssh/environment
  echo "[hortator] GH_TOKEN set for SSH sessions"
else
  echo "[hortator] WARNING: GH_TOKEN not set; gh CLI will not authenticate"
fi

# Start sshd in foreground
exec /usr/sbin/sshd -D -e
