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

## Wrapper to ensure handler has DB env and stable DOMAIN/port
DOM_BAKE="${DOMAIN:-}"
if [ -z "$DOM_BAKE" ]; then
  DOM_BAKE="$(postconf -h mydomain 2>/dev/null | tr -d '\r' || true)"
fi
cat > /app/run-handler.sh <<'WRAP'
#!/bin/sh
export DB_HOST="postgres"
export DB_USER="una_email"
export DB_PASSWORD="${DB_PASSWORD:-una_email_password}"
export DB_NAME="una_email"
unset DB_PORT
export DOMAIN="__DOM__"
echo "[ENV] DOMAIN=$DOMAIN DB_HOST=$DB_HOST DB_PORT=${DB_PORT:-unset} ARGV=$*" >> /tmp/handler-debug.log
exec /usr/local/bin/node /app/handler.js "$@"
WRAP
sed -i "s/__DOM__/$DOM_BAKE/" /app/run-handler.sh
chmod +x /app/run-handler.sh

# Ensure TLS certs are in chroot-safe location if present
mkdir -p /etc/postfix/tls || true
if [ -f "/etc/letsencrypt/live/mail.${DOMAIN}/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/mail.${DOMAIN}/privkey.pem" ]; then
  cp -f "/etc/letsencrypt/live/mail.${DOMAIN}/fullchain.pem" /etc/postfix/tls/fullchain.pem || true
  cp -f "/etc/letsencrypt/live/mail.${DOMAIN}/privkey.pem" /etc/postfix/tls/privkey.pem || true
  chown root:postfix /etc/postfix/tls/privkey.pem || true
  chmod 640 /etc/postfix/tls/privkey.pem || true
fi

# Provide entropy for TLS and ensure tlsmgr is present
command -v rngd >/dev/null 2>&1 && rngd -r /dev/urandom || true
grep -q '^tlsmgr\s\+unix' /etc/postfix/master.cf || echo 'tlsmgr    unix  -       -       n       1000?   1       tlsmgr' >> /etc/postfix/master.cf

# Ensure maillog goes to a path usable if chrooted
mkdir -p /var/spool/postfix/dev
ln -snf /proc/1/fd/1 /var/spool/postfix/dev/stdout
ln -snf /proc/1/fd/2 /var/spool/postfix/dev/stderr
postconf -e maillog_file=/var/spool/postfix/dev/stdout || true

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