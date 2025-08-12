# Una.Email - Self-Hosted Email Solution

This repository contains the installation and deployment configuration for Una.Email, a self-hosted email solution powered by Postfix, Node.js, and a Next.js web interface.

This guide provides a step-by-step process for a robust, production-ready installation. Please follow the steps in order.

## Requirements

Before you begin, you will need:

-   A server/VPS (e.g., Vultr, DigitalOcean, AWS) running a modern Linux distribution (e.g., CentOS, AlmaLinux, Ubuntu).
-   `git`, `docker`, and `docker-compose` installed on your server.
-   A registered domain name that you will use for your email.
-   Access to your domain's DNS record management panel.

---

## Step 1: Cloud Provider & DNS Setup (Pre-Installation)

These steps are performed in your cloud provider's control panel and your domain registrar's DNS panel. They are critical for email to reach your server.

### A) Point an 'A' Record to Your Server

Your mail server needs a hostname. The standard is `mail.yourdomain.com`.

1.  Go to your DNS management panel.
2.  Create a new **`A` record**:
    -   **Host/Name:** `mail`
    -   **Value/Points to:** `YOUR_SERVER_IP`
    -   **TTL:** 1 hour (or your provider's default)

### B) Set the Reverse DNS (PTR) Record

Email servers check the Reverse DNS (rDNS) to verify the sender's identity. This is critical for not being marked as spam.

1.  Go to your **cloud provider's control panel**.
2.  Find the network settings for your server's IP address (`YOUR_SERVER_IP`).
3.  Set the **Reverse DNS** (it may be called a `PTR` record) to the hostname you just created: `mail.yourdomain.com`

### C) Request Removal of SMTP Block (Port 25)

**This is the most common point of failure.** Most cloud providers block port 25 by default to prevent spam. You must ask them to remove it.

1.  Open a support ticket with your cloud provider.
2.  Politely request that they **"remove the SMTP block on port 25"** for your server. Explain that you are setting up a personal/business email server.
3.  **Important:** Some providers require you to perform a full **Stop/Start cycle** from their web panel after the block is removed. A command-line `reboot` is not sufficient.

---

## Step 2: Server Firewall Configuration

Your server's firewall must be configured to allow the required ports for email and web traffic:

- **22/tcp** (SSH)
- **25/tcp** (SMTP/Email)
- **80/tcp** (HTTP)
- **443/tcp** (HTTPS)

Connect to your server via SSH and configure the firewall:

**On CentOS / AlmaLinux / RHEL (using `firewalld`):**
```bash
sudo firewall-cmd --add-service=ssh --permanent
sudo firewall-cmd --add-port=25/tcp --permanent
sudo firewall-cmd --add-port=80/tcp --permanent
sudo firewall-cmd --add-port=443/tcp --permanent
sudo firewall-cmd --reload
```

**On Ubuntu / Debian (using `ufw`):**
```bash
sudo ufw allow ssh
sudo ufw allow 25/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

### Important Note: Multiple Firewall Layers

**Just so you know:** Depending on your hosting provider, you may have multiple firewall layers to configure. Many cloud providers have their own network-level firewalls in addition to your server's local firewall.

If you're experiencing connectivity issues after configuring your server's firewall:
- Check your cloud provider's control panel for additional firewall/security group settings
- Look for "Network Security," "Firewalls," or "Security Groups" in your provider's interface
- Ensure the same ports (22, 25, 80, 443) are allowed at the network level

Both firewall layers must allow traffic for connections to succeed.

---

## Step 3: One-Click Installation

Now, with the environment prepared, we can install the Una.Email software with a single command.

1. Clone this repository:
```bash
git clone https://github.com/roncanfil/una.email-install.git
cd una.email-install
```

2. Run the one-click installation script:
```bash
./install.sh
```

3. Follow the prompts:
   - Enter your domain name (e.g., yourdomain.com)
   - Enter your email address (for SSL certificate notifications)

**The installation script will automatically:**
- ✅ Generate configuration files
- ✅ Start all Docker services
- ✅ Initialize the database with required tables
- ✅ Create a default email alias (`hello@yourdomain.com`)
- ✅ Obtain SSL certificate from Let's Encrypt
- ✅ Configure secure HTTPS access
 - ✅ Bake the mail domain into the handler runtime so inbound mail stores reliably
 - ✅ Configure Postfix transport and pipe safely (no wildcard, pipe runs as `nobody`)

**Installation typically takes 2-3 minutes.** When complete, your email server will be fully operational and accessible at `https://mail.yourdomain.com`.

---

## Step 4: Final DNS Record (MX)

Now that your server is running and secure, you can tell the world to send email to it.

1.  Go back to your DNS management panel.
2.  Create a new **`MX` record**:
    -   **Host/Name:** `@` (or `yourdomain.com`)
    -   **Value/Points to:** `mail.yourdomain.com`
    -   **Priority:** `10`
    -   **TTL:** 1 hour

Your email server is now live and ready to receive email.

---

## Step 5: Configure Automatic SSL Renewal

The `renew-ssl.sh` script included in this repository will automatically renew your certificate and restart Nginx.

**Note on Renewals:** The `certbot renew` command is intelligent. It will check your certificate's expiration date and will **only** attempt a renewal if the certificate is within 30 days of expiring. The cron job runs daily to ensure that when the time comes, it will reliably renew.

To set up the automation:

1. Open the system's crontab editor:
```bash
sudo crontab -e
```

2. Add this line to run the renewal script every night at 2:30 AM (replace `/path/to/your/una.email-install` with the actual absolute path):
```
30 2 * * * /path/to/your/una.email-install/renew-ssl.sh > /dev/null 2>&1
```

---

## Usage & Troubleshooting

**Web Interface:** Access via `https://mail.yourdomain.com`

**Test Email:** Send an email from an external account (like Gmail) to any address at your domain (e.g., `hello@yourdomain.com`).

### Troubleshooting Commands

Check service status:
```bash
docker compose ps
```

View logs for specific services:
```bash
docker compose logs nginx
docker compose logs postfix
docker compose logs web
docker compose logs certbot
```

Check if emails are being received and processed:
```bash
docker compose logs postfix --tail=50
docker compose logs web --tail=30
```

Test SMTP connectivity:
```bash
telnet mail.yourdomain.com 25
```

Restart services if needed:
```bash
docker compose restart
docker compose restart nginx
docker compose restart postfix
```

### Validation checklist

After install, verify:

```bash
docker compose exec postfix postconf -n | egrep '^(mydestination|transport_maps|virtual_mailbox_domains|virtual_transport|relay_domains|relay_transport|smtpd_use_tls|smtpd_tls_cert_file|smtpd_tls_key_file)'
docker compose exec postfix sed -n '1,50p' /etc/postfix/transport | cat
docker compose exec postfix egrep '^una-email-handler' -A1 /etc/postfix/master.cf | cat
docker compose exec postfix tail -n 50 /tmp/handler-debug.log | tail -n 5
```