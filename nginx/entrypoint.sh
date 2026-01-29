#!/bin/bash

# This is the definitive entrypoint script for the Nginx container.
# Its only job is to create a dummy certificate if one doesn't exist,
# ensuring Nginx can start successfully on the first run.

# Default MAIL_SUBDOMAIN to 'mail' if not set
MAIL_SUBDOMAIN="${MAIL_SUBDOMAIN:-mail}"

# Step 1: Create a dummy certificate if one doesn't already exist.
if [ ! -f /etc/letsencrypt/live/${MAIL_SUBDOMAIN}.${DOMAIN}/fullchain.pem ]; then
    echo "Creating dummy certificate for Nginx to start..."
    mkdir -p /etc/letsencrypt/live/${MAIL_SUBDOMAIN}.${DOMAIN}/
    openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
        -keyout /etc/letsencrypt/live/${MAIL_SUBDOMAIN}.${DOMAIN}/privkey.pem \
        -out /etc/letsencrypt/live/${MAIL_SUBDOMAIN}.${DOMAIN}/fullchain.pem \
        -subj "/CN=localhost"
fi

# Step 2: Substitute the domain name into the Nginx config template.
envsubst '$DOMAIN $MAIL_SUBDOMAIN' < /etc/nginx/templates/default.conf.template > /etc/nginx/conf.d/default.conf

# Step 3: Start Nginx.
# It will start with the dummy cert on first run, and the real cert on subsequent runs.
nginx -g 'daemon off;' 