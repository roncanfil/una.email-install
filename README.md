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
- Ask for your domain, subdomain, and database password
- Generate an `RSPAMD_PASSWORD` for you (you are not asked for one) and write
  it to `.env`
- Pull and start all Docker containers
- Apply the database migrations
- Generate personalized DNS instructions

#### Configuration (`.env`)

`install.sh` writes `.env` for you; `.env.example` is the tracked template that
documents every key. Two of them are secrets and are never committed:

| Key | What it is |
|-----|------------|
| `DB_PASSWORD` | Postgres password for the `una_email` role |
| `RSPAMD_PASSWORD` | Rspamd controller password. **Required** -- `docker compose` refuses to start without it. It guards the controller on :11334 (`/stat`, `/learnspam`, `/learnham`, the web UI), which the Rspamd image otherwise leaves on its default `q1`, and the web app uses the same value to teach the Bayes classifier when you report spam. |

The Rspamd controller is published on **`127.0.0.1:11334` only** -- it is not
reachable from outside the server. The web container talks to it over the
internal Docker network at `http://rspamd:11334`. To open the Rspamd web UI,
tunnel to it: `ssh -L 11334:127.0.0.1:11334 you@yourserver`.

### 3. Configure DNS

Open `YOUR_SETUP.md` (generated during install) and add the DNS records at your registrar.

**Required records:**
| Record | Host | Value |
|--------|------|-------|
| A | mail | Your server IP |
| MX | @ | mail.yourdomain.com |
| TXT | @ | SPF record |
| TXT | una._domainkey | DKIM record |
| TXT | _dmarc | DMARC record |
| PTR | (at VPS provider) | mail.yourdomain.com |

### 4. Get SSL Certificate

After DNS propagates (5-10 minutes), run:

```bash
./renew-ssl.sh --force
```

### 5. Access Your Email

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

UNA Email runs 8 long-lived Docker containers, plus one that runs at startup
and exits:

| Service | Purpose |
|---------|---------|
| **postgres** | Database (PostgreSQL 18) |
| **postfix** | Mail server (SMTP) |
| **rspamd** | Spam filtering + DKIM signing |
| **redis** | Backing store for Rspamd statistics, rate limits and greylisting |
| **clamav** | Antivirus scanning of inbound attachments |
| **nginx** | Web server + SSL termination |
| **certbot** | SSL certificate management |
| **web** | Next.js web interface |
| *pg-guard* | Runs once at startup and exits. Refuses to let PostgreSQL 18 start against an empty data volume while an old PostgreSQL 15 volume still holds your mail -- see [Postgres 15 to 18](#postgres-15-to-18). |

---

## Support

- Documentation: https://una.email/docs
- Support: support@una.email
