#!/bin/bash
set -ex

echo "=== UNA Email Mail Server Starting ==="

# Configure Postfix (skip if SKIP_CONFIG is set)
if [ "$SKIP_CONFIG" != "true" ]; then
    echo "Configuring Postfix..."
    postconf -e "myhostname = mail.${DOMAIN:-example.com}"
    postconf -e "mydomain = ${DOMAIN:-example.com}"
    postconf -e "myorigin = ${DOMAIN:-example.com}"

    # Create transport map
    echo "@${DOMAIN:-example.com} una-email-handler:" > /etc/postfix/transport
    postmap /etc/postfix/transport

    # Create virtual alias file
    touch /etc/postfix/virtual
    postmap /etc/postfix/virtual
else
    echo "Using mounted config files with domain substitution"
    # Process the main.cf template using sed
    sed "s/\${DOMAIN}/${DOMAIN}/g" /etc/postfix/main.cf.template > /etc/postfix/main.cf
    
    # Ensure virtual file is mapped (no transport file needed)
    postmap /etc/postfix/virtual
fi

# Fix permissions - corrected for proper postfix ownership
chown root:root /var/spool/postfix/
chown -R postfix:postdrop /var/spool/postfix/maildrop
chown postfix:postdrop /var/spool/postfix/public

# Set ownership for existing directories only
for dir in private active bounce corrupt defer deferred flush incoming trace; do
    if [ -d "/var/spool/postfix/$dir" ]; then
        chown postfix:postdrop "/var/spool/postfix/$dir"
    fi
done

# Fix pid directory ownership specifically
chown root:root /var/spool/postfix/pid

chown -R postfix:postfix /var/lib/postfix

# Create rsyslog directory
mkdir -p /var/run/rsyslog

# Start Node.js API server
echo "Starting Node.js API server..."
node /app/api-server.js &
API_PID=$!
echo "API server started with PID: $API_PID"

# Give API server time to start
sleep 3

# Start Postfix
echo "Starting Postfix..."
postfix stop 2>/dev/null || true
sleep 2
postfix start
sleep 3

# Verify postfix is running
if ! postfix status > /dev/null 2>&1; then
    echo "ERROR: Postfix failed to start"
    exit 1
fi

# Start auto-processor
echo "Starting auto-processor..."
chmod +x /auto-process.sh
/auto-process.sh &
AUTO_PROCESSOR_PID=$!
echo "Auto-processor started with PID: $AUTO_PROCESSOR_PID"

echo "=== UNA Mail Server is ready! ==="
echo "Domain: ${DOMAIN}"
echo "Postfix is running and auto-processor is active"

# Keep container alive and monitor processes
echo "Entering monitoring loop..."
while true; do
    echo "All services running - $(date)"
    sleep 30
done 