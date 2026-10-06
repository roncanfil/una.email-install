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
| `RELAY_KEY` | Encrypts the outbound relay password stored in the database. **Required** — `docker compose` refuses to start without it. Only used when outbound delivery is configured from Settings → Sending; changing it means re-entering those credentials and affects nothing else. |
| `RSPAMD_PASSWORD` | Rspamd controller password. **Required** -- `docker compose` refuses to start without it. It guards the controller on :11334 (`/stat`, `/learnspam`, `/learnham`, the web UI), which the Rspamd image otherwise leaves on its default `q1`, and the web app uses the same value to teach the Bayes classifier when you report spam. |

The Rspamd controller is published on **`127.0.0.1:11334` only** -- it is not
reachable from outside the server. The web container talks to it over the
internal Docker network at `http://rspamd:11334`. To open the Rspamd web UI,
tunnel to it: `ssh -L 11334:127.0.0.1:11334 you@yourserver`.

### Outbound mail

A fresh install delivers straight to each recipient's mail server on port 25,
and the installer no longer asks about it. That default is right until it is
not: many providers block outbound 25, and a new IP can be on a blocklist
before you ever send from it. When that happens the symptom is mail that
queues and then bounces while every page in UNA still looks healthy.

**Settings → Sending** is where you change it — a diagram of both mail paths,
and a switch to Amazon SES or any other SMTP provider. It applies immediately:
the mail server is reloaded, not restarted, so nothing queued is lost and no
SSH session is involved.

Switching hands DKIM signing to your provider, so their DNS records are what
make your mail pass DMARC from then on. The page lists what to publish before
you switch, and UNA will not claim a record is present — it never queries DNS.
Send a test message afterwards; that is the real confirmation.

`SMTP_RELAY_*` in `.env` still works and takes precedence over anything saved
in the UI, which makes that page read-only. See
[docs/OUTBOUND_RELAY.md](https://github.com/roncanfil/una.email) for the keys.

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

The installer writes your records two ways. The browser one is easier to work
from — every value has a copy button and it remembers which steps you have
finished:

```
http://<your-server-ip>/dns-setup
```

Plain HTTP and a bare IP, deliberately: the records on that page are what make
your hostname resolve and your certificate issuable, so the guide cannot live
behind either of them. Nginx serves it from port 80 on a server with no
certificate yet. Nothing on it is private — the domain, the server's own IP and
a DKIM *public* key are all about to be published in DNS anyway. Once TLS is up
it is also at `https://<web hostname>/dns-setup`.

The path is `/dns-setup` and not `/setup` because the web app owns `/setup` —
that is where a fresh install creates its first admin account.

The same content is on the server as `YOUR_SETUP.md` for reading over SSH. Both
are written for the subdomains you actually chose, so follow them rather than
this summary.

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
- Ask whether to back up your database first (default yes)
- Pull latest images
- Run migrations
- Automatically rollback if anything fails — from that backup

Because it pulls this repository, run it from the checkout you installed from
and leave your local edits out of tracked files. Your `.env` is not tracked and
is never modified except to add a missing `RSPAMD_PASSWORD`.

#### The backup question

The dump the script takes is what it restores from if the migration fails, so
the answer that keeps the update reversible is yes. Say no when the mailbox is
large enough that dumping it is the slow part of an update and you already have
snapshots of your own — a failed migration then stops and waits for you instead
of undoing itself.

Answer it ahead of time when scripting the update:

```bash
UNA_BACKUP=0 ./update.sh    # skip the backup
UNA_BACKUP=1 ./update.sh    # take it, no question asked
```

Run with nothing on a terminal (from cron, say) and no `UNA_BACKUP`, it takes
the backup.

Backups land in `backups/backup_<timestamp>.sql` and are plain `pg_dump` SQL.
To put one back, see **Restore the database** below.

Note what this one is and is not. It exists to undo a failed migration, so it
covers what an update can break: the database. It is not disaster recovery —
your attachments, `.env` and DKIM keys are not in it. That is **Back up
everything**, next.

### Back up everything

```bash
./backup.sh
```

Writes `backups/una-backup_<timestamp>.tar.gz` holding everything that makes
this install *this install*:

| In the archive | Why it has to be |
|---|---|
| `database.sql` | The mail, the accounts, the settings. |
| `attachments.tar` | The attachment files. They live in a Docker volume and have never been inside a `pg_dump`, so a database backup on its own restores rows pointing at files that are not there. |
| `env` | `DOMAIN` and the secrets. `SESSION_SECRET` signs every session, `RELAY_KEY` decrypts the stored relay password, and the `VAPID_*` pair is the identity every existing push subscription was made against. |
| `dkim/` | The private keys whose public half your DNS publishes. Sign with a different key and outbound mail fails DMARC — which breaks delivery without breaking anything you can see. |

Not included, on purpose: **TLS certificates** (re-issue with `./renew-ssl.sh`,
which is quicker than carrying certbot's renewal state between machines) and
**Rspamd's Bayes training** (it lives in the `redis_data` volume and is rebuilt
by using the product; a moved install starts on the shipped rules and relearns).

```bash
./backup.sh --no-compress        # faster, and no bigger, when the bulk is images and PDFs
./backup.sh --output /mnt/backup # somewhere other than backups/
```

> **This archive is the root of your install in one file** — DKIM private keys,
> the database password, the session secret. It is written mode `600` into
> `backups/`, which is gitignored. Copy it the way you would copy a server
> password, and do not leave it anywhere the web server can reach.

### Move to another server

On the old server:

```bash
./backup.sh
```

Copy the archive across, then on the new one — with DNS still pointing at the
old machine, so nothing is lost while you work:

```bash
git clone https://github.com/roncanfil/una.email-install.git
cd una.email-install
./install.sh                                   # same DOMAIN as the old server
./restore.sh una-backup_20260922_181500.tar.gz --with-secrets
./renew-ssl.sh                                 # TLS is not in the archive
```

`--with-secrets` is what makes it a move rather than a copy of the data. It puts
back `SESSION_SECRET`, `RELAY_KEY`, the `VAPID_*` pair and the `dkim/` keys, so
signed-in sessions survive, the relay credentials still decrypt, existing push
subscriptions keep working and your **existing DKIM DNS record still matches** —
no DNS change needed for mail to keep signing.

`DOMAIN`, `DB_PASSWORD` and `RSPAMD_PASSWORD` are always left as the new install
generated them. The database role on a fresh install was created with that
machine's `DB_PASSWORD`, and rewriting `.env` to say something else would stop
the app connecting to the database it had just restored.

Only when the mail looks right on the new machine, repoint your MX and A records.

### Restore the database

```bash
./restore.sh backups/backup_20260922_181500.sql          # a bare dump
./restore.sh backups/una-backup_20260922_181500.tar.gz   # a full archive
```

Takes either a `pg_dump` SQL file or an archive from `./backup.sh`, and works
out which by reading it. A bare dump replaces the database and nothing else; an
archive also replaces the attachment files, and the secrets too when you pass
`--with-secrets`.

Dumps can be gzipped or not — `.sql` and `.sql.gz` both work, and so does one
of `update.sh`'s own backups or one you took yourself.

This is a terminal job rather than a screen in the app on purpose. A dump of a
real mailbox runs to gigabytes, and pushing one through a browser upload means
buffering it, timing out on it, and letting the web container run a `psql` it
has no business running. The app exports; the terminal imports.

**It will ask you to type `restore`.** Every message, account, alias and setting
in the database is replaced. The mail on disk is not touched, but the database
that indexes it is.

What it does, in order:

- reads the file without changing anything — that it really is a `pg_dump`, and
  which PostgreSQL wrote it (a dump from a newer major is refused, because it
  will not go into an older server)
- backs up what is there now, so an unwanted restore is itself reversible — a
  dump for a bare `.sql`, and a full `./backup.sh` archive when files or keys
  are about to be replaced, since a dump alone would not be a way back from that
- stops everything but PostgreSQL, so nothing writes half way through
- **drops and recreates the database.** A plain `pg_dump` contains `CREATE` and
  no `DROP`, so restoring it onto a live database would merge two datasets
  rather than replace one
- restores with `ON_ERROR_STOP`, so a failure is a failure rather than a
  half-populated database reporting success. The output goes to
  `backups/restore_<timestamp>.log`
- brings the stack back up and runs the migrations, because a dump from an
  older release restores an older schema

Options:

```bash
./restore.sh file --check          # inspect it, change nothing
./restore.sh file --with-secrets   # archives only: also restore .env keys and dkim/
./restore.sh file --yes            # no confirmation prompt, for scripts
./restore.sh file --no-backup      # skip the safety backup taken first
```

`--check` is worth running first on a file you did not make yourself, or one
that took a long time to copy: it answers "would this restore?" without
stopping anything.

If the restore fails part-way, the script says so, prints the tail of the log,
and leaves the stack down apart from PostgreSQL — deliberately, since starting
the app against a half-restored database only adds to what has to be undone.
Put back what you had with the pre-restore dump it names:

```bash
./restore.sh backups/pre-restore_20260922_181500.sql
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

UNA Email runs 8 Docker containers:

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

---

## License

UNA is proprietary software, licensed under the [UNA End User License
Agreement](LICENSE), which `install.sh` asks you to accept. Every install is
free to evaluate for 90 days; after that it needs a yearly license key from
<https://license.una.email>, pasted into Settings → License.

UNA checks its license with license.una.email when it starts and once a day,
sending only its install id, mail domain and license key — never mail or user
data. The server needs outbound HTTPS to reach it; an install that cannot
confirm its license for 14 days restricts itself as if the license had
expired.

The container images are public so that anyone can install UNA, but their
contents are not open source: copying, modifying, reverse engineering or
redistributing UNA or any part of its images is not permitted.

---

## Support

- Documentation: https://una.email/docs
- Support: support@una.email
