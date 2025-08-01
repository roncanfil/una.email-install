#!/bin/bash

# This script is the new entrypoint for the Nginx container.
# It solves the chicken-and-egg problem of needing a certificate before Nginx can start,
# and it correctly handles the Nginx configuration templating.

# Step 1: Perform the environment variable substitution on the Nginx template.
# This creates the final nginx.conf with the correct domain name.
envsubst '$${DOMAIN}' < /etc/nginx/templates/default.conf.template > /etc/nginx/conf.d/default.conf

# Step 2: Run Certbot to obtain or renew the certificate.
# This command will create a temporary Nginx instance to solve the challenge.
# It's more robust than standalone or webroot methods in this context.
# We add `--deploy-hook` to ensure Nginx reloads after a successful renewal.
certbot --nginx \
    --agree-tos --no-eff-email \
    --email ${LETSENCRYPT_EMAIL} \
    -d mail.${DOMAIN} \
    --deploy-hook "nginx -s reload"

# Step 3: Start the main Nginx process.
# This command starts Nginx in the foreground, which is the standard
# for Docker containers. It will now have a valid config and certificate.
echo "Starting Nginx..."
nginx -g 'daemon off;' 