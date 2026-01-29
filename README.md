# UNA Email - Self-Hosted Email Server

UNA Email is a self-hosted email solution for families and small teams. Run your own email server with a modern web interface.

## Requirements

- A VPS (Vultr, DigitalOcean, Linode, etc.) with Ubuntu or CentOS
- A domain name you control
- Docker and Docker Compose installed

## Quick Start

### 1. Prepare Your Server

**Request SMTP unblocking** (most important step!)
- Open a support ticket with your VPS provider
- Ask them to "remove the SMTP block on port 25"
- After approval, do a full Stop/Start from their control panel

### 2. Install UNA Email

```bash
git clone https://github.com/roncanfil/una.email-install.git
cd una.email-install
./install.sh
```

The installer will:
- Configure firewall automatically (if firewalld or ufw is active)
- Ask for your domain, email, and database password
- Pull and start all Docker containers
- Set up the database
- Request SSL certificate

### 3. Configure DNS

After installation, open `YOUR_SETUP.md` for personalized DNS instructions. This file contains all the exact records you need to add.

**Summary of required DNS records:**
| Record | Host | Value |
|--------|------|-------|
| A | mail | Your server IP |
| MX | @ | mail.yourdomain.com |
| TXT | @ | SPF record |
| TXT | una._domainkey | DKIM record |
| TXT | _dmarc | DMARC record |
| PTR | (at VPS provider) | mail.yourdomain.com |

### 4. Access Your Email

Open `https://mail.yourdomain.com` in your browser.

---

## Maintenance

### Update UNA Email

```bash
./update.sh
```

This will:
- Backup your database
- Pull latest images
- Run migrations
- Automatically rollback if anything fails

### Renew SSL Certificate

SSL auto-renewal is handled by cron. Set it up:

```bash
sudo crontab -e
# Add this line:
30 2 * * * /path/to/una.email-install/renew-ssl.sh > /dev/null 2>&1
```

Or run manually: `./renew-ssl.sh`

---

## Troubleshooting

### Check service status
```bash
docker compose ps
```

### View logs
```bash
docker compose logs -f postfix    # Mail server
docker compose logs -f web        # Web interface
docker compose logs -f rspamd     # Spam filter
```

### Restart services
```bash
docker compose restart
```

### Test SMTP connectivity
```bash
telnet mail.yourdomain.com 25
```

---

## Architecture

UNA Email runs 6 Docker containers:

| Service | Purpose |
|---------|---------|
| **postgres** | Database |
| **postfix** | Mail server (SMTP) |
| **rspamd** | Spam filtering + DKIM signing |
| **nginx** | Web server + SSL termination |
| **certbot** | SSL certificate management |
| **web** | Next.js web interface |

---

## Support

- Documentation: https://una.email/docs
- Support: support@una.email
