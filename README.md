# Una.Email - Installation Repository

This repository contains everything you need to deploy Una.Email on your own server.

## Quick Start

```bash
# 1. Clone this repository
git clone https://github.com/roncanfil/una.email-install.git
cd una.email-install

# 2. Run the installation script
./install.sh

# 3. Enter your domain when prompted
# Example: mydomain.com

# 4. Deploy
docker compose up -d
```

## What This Does

The `install.sh` script will:
- ✅ Ask for your domain name
- ✅ Generate Postfix configuration files
- ✅ Create a `.env` file with your settings
- ✅ Show you the required DNS records

## DNS Configuration Required

After running the setup script, add these DNS records:

```
# A record for webmail interface
mail.yourdomain.com    A    YOUR_SERVER_IP

# MX record for email delivery  
yourdomain.com         MX   10 mail.yourdomain.com
```

## Access Your Una.Email

- **Web Interface**: `http://YOUR_SERVER_IP`
- **Test Email**: Send to `any@yourdomain.com`

## Troubleshooting

```bash
# Check container status
docker compose ps

# View logs
docker compose logs -f

# Restart services
docker compose restart
``` 