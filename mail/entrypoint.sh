#!/bin/bash
set -euo pipefail
set -x

echo "=== UNA Email Mail Server Starting ==="

if [ "${SKIP_CONFIG:-false}" != "true" ]; then
  echo "Configuring Postfix..."
  postconf -e "myhostname = mail.${DOMAIN:-example.com}"
  postconf -e "mydomain = ${DOMAIN:-example.com}"
  postconf -e "myorigin = ${DOMAIN:-example.com}"
  echo "@${DOMAIN:-example.com} una-email-handler:" > /etc/postfix/transport
  postmap /etc/postfix/transport
  touch /etc/postfix/virtual
  postmap /etc/postfix/virtual
else
  echo "Using mounted config files with domain substitution"
  sed "s/\${DOMAIN}/${DOMAIN}/g" /etc/postfix/main.cf.template > /etc/postfix/main.cf
  if [ -f "/etc/postfix/transport.template" ]; then
    echo "Generating /etc/postfix/transport from template"
    sed "s/\${DOMAIN}/${DOMAIN}/g" /etc/postfix/transport.template > /etc/postfix/transport
    postmap /etc/postfix/transport
  else
    echo "No transport.template found. Creating a catch-all transport map for domain ${DOMAIN}"
    {
      echo "${DOMAIN}          una-email-handler:"
      echo ".${DOMAIN}         una-email-handler:"
      echo "*                  una-email-handler:"
    } > /etc/postfix/transport
    postmap /etc/postfix/transport
  fi
  touch /etc/postfix/virtual
  postmap /etc/postfix/virtual
fi

# Permissions
chown root:root /var/spool/postfix/ || true
chown -R postfix:postdrop /var/spool/postfix/maildrop || true
chown postfix:postdrop /var/spool/postfix/public || true
for dir in private active bounce corrupt defer deferred flush incoming trace; do
  [ -d "/var/spool/postfix/$dir" ] && chown postfix:postdrop "/var/spool/postfix/$dir"
done
chown root:root /var/spool/postfix/pid || true
chown -R postfix:postfix /var/lib/postfix || true
mkdir -p /var/run/rsyslog

# Start API server
echo "Starting Node.js API server..."
node /app/api-server.js &
sleep 2

# Wrapper to ensure handler has DB env even when run by pipe as postfix user
cat > /app/run-handler.sh <<WRAP
#!/bin/sh
export DB_HOST="${DB_HOST:-postgres}"
export DB_USER="${DB_USER:-una_email}"
export DB_PASSWORD="${DB_PASSWORD:-una_email_password}"
export DB_NAME="${DB_NAME:-una_email}"
export DB_PORT="${DB_PORT:-5432}"
exec /usr/local/bin/node /app/handler.js "$@"
WRAP
chmod +x /app/run-handler.sh

# Ensure debug log file is writable
touch /tmp/handler-debug.log || true
chmod 666 /tmp/handler-debug.log || true

# Start Postfix
echo "Starting Postfix..."
postfix stop 2>/dev/null || true
sleep 1
postfix start
sleep 2
postfix status >/dev/null 2>&1 || { echo "ERROR: Postfix failed to start"; exit 1; }

# Start auto-processor (safe no-op with direct pipe)
echo "Starting auto-processor..."
chmod +x /auto-process.sh || true
/bin/chmod +x /app/deliver-to-maildrop || true
/auto-process.sh &

echo "=== UNA Mail Server is ready! ==="
echo "Domain: ${DOMAIN}"
echo "Postfix is running and auto-processor is active"

while true; do
  echo "All services running - $(date)"
  sleep 30
done