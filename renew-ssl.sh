#!/bin/bash

# This script is designed to be run as a cron job to automatically renew
# the Let's Encrypt SSL certificate for your Una.Email installation.
# It uses the certbot container to renew the certificate and then tells
# the nginx container to gracefully reload its configuration to use the new cert.

# Navigate to the script's directory to ensure docker-compose commands work correctly.
cd "$(dirname "$0")"

# Step 1: Run the Certbot renewal command.
# The `renew` command will check the certificate's expiration date and
# only attempt renewal if it's within the 30-day window.
# The `--rm` flag automatically cleans up the container after it exits.
echo "Attempting to renew SSL certificate..."
docker compose run --rm certbot renew

# Step 2: Reload the Nginx configuration.
# This command tells Nginx to gracefully reload its configuration, which
# will pick up the new SSL certificate if it was successfully renewed.
# This does not cause any downtime.
echo "Reloading Nginx configuration..."
docker compose exec nginx nginx -s reload

echo "SSL renewal process complete." 