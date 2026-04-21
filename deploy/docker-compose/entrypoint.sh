#!/bin/bash
set -e

# Copy mounted SSH authorized keys if present
if [ -f /home/worker/.ssh/mounted_authorized_keys ]; then
  cp /home/worker/.ssh/mounted_authorized_keys /home/worker/.ssh/authorized_keys
  chown worker:worker /home/worker/.ssh/authorized_keys
  chmod 600 /home/worker/.ssh/authorized_keys
fi

# Copy mounted Claude credentials if present
if [ -d /home/worker/.claude-mount ]; then
  cp -r /home/worker/.claude-mount/. /home/worker/.claude/ 2>/dev/null || true
  chown -R worker:worker /home/worker/.claude
fi

# Fix SSH directory permissions
chmod 700 /home/worker/.ssh

# Start sshd in foreground
exec /usr/sbin/sshd -D -e
