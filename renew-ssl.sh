#!/bin/bash

# This script is designed to be run as a cron job to automatically renew
# the Let's Encrypt SSL certificate for your Una.Email installation.

cd "$(dirname "$0")"

# Step 1: Run the Certbot renewal command.
echo "Attempting to renew SSL certificate..."
docker compose run --rm certbot renew

# Step 2: Restart the Nginx container to pick up the new certificate.
echo "Restarting Nginx to apply new certificate..."
docker compose restart nginx

echo "SSL renewal process complete." 