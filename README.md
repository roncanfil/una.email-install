# UNA Email - Self-Hosted Email Server

UNA Email is a self-hosted email solution for families and small teams. Run your own email server with a modern web interface.

## Requirements

- A VPS (Vultr, DigitalOcean, Linode, etc.) with Ubuntu or CentOS
- A domain name you control
- Docker and Docker Compose installed

## Quick Start

### 1. Prepare Your Server

**Sort out port 25.** There are two directions and they are not the same
problem.

- **Inbound 25 — required, always.** Your MX record points at this server, so
  nothing can be delivered to you unless the provider allows inbound
  connections on port 25. Open a support ticket asking them to "remove the SMTP
  block on port 25", and after approval do a full Stop/Start from their control
  panel. You also want correct reverse DNS (PTR) for the IP and a HELO name
  that matches it.
- **Outbound 25 — optional, if you use a relay.** Many providers will not
  unblock outbound 25 at all, and a fresh IP is often blocklisted even when they
  do. Set `SMTP_RELAY_PROVIDER` (Amazon SES or any SMTP host) and UNA sends over
  587 or 465 instead. The installer offers to set this up for you; you can also
  add it to `.env` later.

A relay never replaces inbound 25. It only changes where your outgoing mail
leaves from.

### 2. Install UNA Email

```bash
git clone https://github.com/roncanfil/una.email-install.git
cd una.email-install
./install.sh
```

The installer will:
- Configure firewall automatically (if firewalld or ufw is active)
- Ask for your domain, your two subdomains (below), and a database password
- Ask whether outbound mail should go through Amazon SES (optional — skipping it
  leaves UNA delivering directly, and writes the keys commented out so they are
  easy to find later)
- Generate an `RSPAMD_PASSWORD` for you (you are not asked for one) and write
  it to `.env`
- Pull and start all Docker containers
- Apply the database migrations
- Generate personalized DNS instructions

#### The two hostnames

The installer asks for two subdomains, and they do different jobs. Both have a
default you can accept by pressing enter.

| Prompt | Key | Default | What it is |
|---|---|---|---|
| Subdomain for the mail server | `SMTP_SUBDOMAIN` | `mail` | The server's SMTP identity: the MX target, the name Postfix gives in HELO, and the name reverse DNS must return. |
| Subdomain for web access | `WEB_SUBDOMAIN` | `webmail` | Where you sign in. Nginx's `server_name`, and nothing else. |

**The SMTP one is the one that matters.** Whatever you choose, four records have
to agree on it: the MX, its A record, the PTR record you set at your VPS
provider, and Postfix's HELO name (which UNA sets from this value for you). A
PTR that does not match is the most common reason a self-hosted server lands in
spam.

`mail` is the default because every provider's reverse-DNS documentation and
every deliverability checker assumes it. `mx` and `smtp` are the other
conventional choices — the label itself earns no deliverability points, so this
is a readability decision, not a technical one. Pick it at install time: changing
it later means moving the MX, PTR, SPF, DKIM-for-bounces and TLSA records
together.

The web one is cosmetic. You can give both prompts the same answer, and then one
host serves SMTP on port 25 and HTTPS on port 443 — one A record, one name on
the certificate. That was the only arrangement UNA supported before these became
two settings.

Either way `./renew-ssl.sh` issues **one certificate covering both names**. It
has to: the same certificate file is served by Nginx on 443 and copied into
Postfix for STARTTLS on 25, and a certificate that does not name the MX host
fails the name check for any sender doing MTA-STS or strict verification.

#### Configuration (`.env`)

`install.sh` writes `.env` for you; `.env.example` is the tracked template that
documents every key. Two of them are secrets and are never committed:

| Key | What it is |
|-----|------------|
| `SMTP_SUBDOMAIN` | The mail server's hostname, `mail` by default. See [The two hostnames](#the-two-hostnames). |
| `WEB_SUBDOMAIN` | The webmail hostname, `webmail` by default. Called `MAIL_SUBDOMAIN` before these were split; that spelling is still read as a fallback, so an older `.env` keeps working. |
| `DB_PASSWORD` | Postgres password for the `una_email` role |
| `RSPAMD_PASSWORD` | Rspamd controller password. **Required** -- `docker compose` refuses to start without it. It guards the controller on :11334 (`/stat`, `/learnspam`, `/learnham`, the web UI), which the Rspamd image otherwise leaves on its default `q1`, and the web app uses the same value to teach the Bayes classifier when you report spam. |

The Rspamd controller is published on **`127.0.0.1:11334` only** -- it is not
reachable from outside the server. The web container talks to it over the
internal Docker network at `http://rspamd:11334`. To open the Rspamd web UI,
tunnel to it: `ssh -L 11334:127.0.0.1:11334 you@yourserver`.

### Tuning the spam filter

UNA's Rspamd configuration — spam thresholds, DKIM signing, rate limits,
greylisting, the Bayes classifier — is built into the `rspamd` image, so there
are no config files to edit here and nothing to re-apply after an update.

To change a default on this install, drop a `.conf` file in
`rspamd/override.d/`. It is mounted into the container, it is not tracked by
git, and it survives every update. Raising the reject threshold, for example,
is `rspamd/override.d/actions.conf`:

```
reject = 20;
add_header = 6;
greylist = 4;
```

An override **replaces** the section it names rather than merging into it, so
restate the whole block, not just the line you are changing. Then:

```bash
docker compose restart rspamd
docker compose exec rspamd rspamadm configtest
docker compose exec rspamd rspamadm configdump actions   # confirm it took
```


### 3. Configure DNS

Open `YOUR_SETUP.md` (generated during install) and add the DNS records at your
registrar. It is written for the subdomains you actually chose, so follow that
file rather than this summary.

With the defaults (`SMTP_SUBDOMAIN=mail`, `WEB_SUBDOMAIN=webmail`):

| Record | Host | Value |
|--------|------|-------|
| A | mail | Your server IP |
| A | webmail | Your server IP |
| MX | @ | mail.yourdomain.com |
| TXT | @ | SPF record |
| TXT | una._domainkey | DKIM record |
| TXT | una._domainkey.mail | The same DKIM record, for bounces |
| TXT | _dmarc | DMARC record |
| PTR | (at VPS provider) | mail.yourdomain.com |

Both A records are required before you ask for a certificate — one certificate
covers both names, and Let's Encrypt validates each of them over port 80. If you
gave both prompts the same answer, there is one A record and one name to
validate.

The PTR record is set at your VPS provider, not your registrar, and it must
return your `SMTP_SUBDOMAIN` hostname.

### 4. Get SSL Certificate

After DNS propagates (5-10 minutes), run:

```bash
./renew-ssl.sh
```

It obtains a certificate if there is none, adds the mail hostname to an existing
certificate that predates the two-hostname split, and otherwise renews. Then it
prints the DANE/TLSA record for `_25._tcp.<your mail hostname>`.

Let's Encrypt allows **5 certificates per domain per week**. A failed attempt
costs nothing, but repeated successful re-issues — reinstalling several times in
a day, say — will exhaust it.

### 5. Access Your Email

Open `https://webmail.yourdomain.com` in your browser (or whichever
`WEB_SUBDOMAIN` you chose).

---

## Maintenance

### Update UNA Email

```bash
./update.sh
```

This will:
- `git pull` this repository, so you get the current compose file and scripts —
  not just the container images
- Add `RSPAMD_PASSWORD` to your `.env` if you do not have one yet
- Upgrade PostgreSQL 15 to 18 if you are still on 15 (see below)
- Backup your database
- Pull latest images
- Run migrations
- Automatically rollback if anything fails

Because it pulls this repository, run it from the checkout you installed from
and leave your local edits out of tracked files. Your `.env` is not tracked and
is never modified except to add a missing `RSPAMD_PASSWORD`.

### Postgres 15 to 18

Installs made before this release store their mail in PostgreSQL 15. This
release runs PostgreSQL 18. There is no in-place upgrade between PostgreSQL
majors, and the official 18 image also mounts a different path, so the data has
to be dumped out of 15 and restored into a fresh 18 volume.

`./update.sh` does this for you. **Run it while your existing stack is still
up**, in this order:

```bash
cd una.email-install
docker compose ps          # confirm your containers are running
./update.sh                # pulls this repo, then upgrades Postgres, then updates
```

`update.sh` pulls the new files first and then performs the upgrade, so your
old PostgreSQL 15 container is still the one running when the dump is taken —
which is what the upgrade needs. If your stack is **down** when you start, the
script will stop and tell you to bring the old one up first:

```bash
git stash                       # keep the new files for later
git checkout 3246e1d            # the last PostgreSQL 15 release
docker compose up -d postgres
git checkout main && git stash pop
./update.sh
```

Your PostgreSQL 15 volume is **never written to**. The upgrade dumps from it
and restores onto a new `postgres_data_18` volume, so the old data stays
exactly as it was and a rollback is always available.

#### Rollback

If something goes wrong after the upgrade, set the `postgres` service in
`docker-compose.yml` back to:

```yaml
    image: postgres:15-alpine
    volumes:
      - postgres_data:/var/lib/postgresql/data
```

and run `docker compose up -d postgres`. (Checking out the previous release
with `git checkout 3246e1d` does the same thing and also restores the rest of
the old configuration.)

Once you are confident the upgrade worked, reclaim the old volume:

```bash
docker volume rm unaemail-install_postgres_data
```

You can also rehearse the upgrade without touching anything — it restores into
a throwaway volume, compares row counts, and destroys it again:

```bash
./scripts/upgrade-postgres.sh --dry-run
```

### Renew SSL Certificate

SSL auto-renewal is handled by cron. Set it up:

```bash
sudo crontab -e
# Add this line:
30 2 * * * /path/to/una.email-install/renew-ssl.sh --cron > /dev/null 2>&1
```

`--cron` is the quiet mode: it acts only when something actually needs renewing.
Without the flag the script runs its interactive path and prints on every run.

Or run manually: `./renew-ssl.sh`

### Reinstall from scratch

`./update.sh` is what you want for a new version — it keeps your mail and can
roll back. Reinstall only when the install is genuinely broken or you want the
data gone.

**This destroys every message, account and attachment.** Back up first if any of
it matters:

```bash
cd ~/una.email-install
docker compose exec -T postgres pg_dump -U una_email una_email \
  | gzip > ~/una-db-backup-$(date +%F).sql.gz
docker run --rm -v "$(docker volume ls -q | grep attachments_data | head -1)":/data \
  -v "$HOME":/backup alpine tar czf /backup/una-attachments-$(date +%F).tar.gz -C /data .
```

Then tear the stack down. Container and volume names are matched by pattern
rather than listed, so this also catches an older install whose names differ:

```bash
cd ~/una.email-install && docker compose down -v --remove-orphans

docker ps -aq --filter "name=una-" | xargs -r docker rm -f

# The Postgres 15 volume must go too — pg-guard refuses to start a fresh
# Postgres 18 while a populated 15 volume is still present.
docker volume ls -q | grep -iE 'una|postgres_data|rspamd_data|redis_data|clamav_data|attachments' \
  | xargs -r docker volume rm -f

docker network ls -q --filter "name=una" | xargs -r docker network rm
docker images -q 'ghcr.io/roncanfil/una.email/*' | xargs -r docker rmi -f
docker image prune -af

# Takes .env, the DKIM keys, the certificates and YOUR_SETUP.md with it
cd ~ && rm -rf ~/una.email-install
```

Confirm nothing survived, then install as in [Quick Start](#quick-start):

```bash
docker ps -a && docker volume ls && docker images
```

Two things to expect on a fresh install:

- **The DKIM key is new**, so the `una._domainkey` TXT record (and the
  `una._domainkey.<mail hostname>` copy) must be replaced with the value in the
  new `YOUR_SETUP.md`. Mail signed with the old key in DNS will fail DKIM.
- **The certificate is re-issued**, which spends one of your 5 per domain per
  week. Reinstalling repeatedly in one week will hit that limit.

Everything else — MX, A, SPF, DMARC, PTR — is unchanged if the IP and the
subdomains are the same.

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
| **rspamd** | Spam filtering + DKIM signing. Ships with UNA's configuration built in; see [Tuning the spam filter](#tuning-the-spam-filter). |
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
