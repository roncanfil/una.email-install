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

1.  Go to your **cloud provider's control panel** (Vultr, AWS, etc.).
2.  Find the network settings for your server's IP address (`YOUR_SERVER_IP`).
3.  Set the **Reverse DNS** (it may be called a `PTR` record) to the hostname you just created: `mail.yourdomain.com`

### C) Request Removal of SMTP Block (Port 25)

**This is the most common point of failure.** Most cloud providers block port 25 by default to prevent spam. You must ask them to remove it.

1.  Open a support ticket with your cloud provider.
2.  Politely request that they **"remove the SMTP block on port 25"** for your server. Explain that you are setting up a personal/business email server.
3.  **Important:** Some providers, like Vultr, require you to perform a full **Stop/Start cycle** from their web panel after the block is removed. A command-line `reboot` is not sufficient.

---

## Step 2: Server Firewall Configuration

Your server's own firewall must be configured to allow mail and web traffic.

1.  Connect to your server via SSH.
2.  Open ports `22` (SSH), `25` (SMTP), and `80` (HTTP for SSL certificate validation).

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

---

## Step 3: Installation

Now, with the environment prepared, we can install the Una.Email software.

```bash
# 1. Clone this repository
git clone https://github.com/roncanfil/una.email-install.git
cd una.email-install

# 2. Run the interactive installation script
./install.sh

# 3. Follow the prompts
#    - Enter your domain name (e.g., yourdomain.com)
#    - Enter your email address (for SSL certificate notifications)
```

---

## Step 4: Launch and Secure the Application

This is a two-step process. We first launch the services (Nginx will start with a temporary, self-signed certificate), and then we run Certbot to obtain a real SSL certificate.

```bash
# Step 4a: Launch all services.
# Nginx will start up using a temporary "dummy" certificate.
# Your browser will show a security warning at this stage - this is expected.
docker compose up -d

# Step 4b: Obtain the real SSL certificate.
# This command runs the certbot container, which will replace the dummy
# certificate with a valid one from Let's Encrypt.
docker compose run --rm certbot certonly --webroot --webroot-path=/var/www/certbot --email ${LETSENCRYPT_EMAIL} --agree-tos --no-eff-email -d mail.${DOMAIN}

# Step 4c: Restart Nginx to load the real certificate.
docker compose restart nginx
```

Your application is now live and secure.

---

## Step 5: Final DNS Record (MX)

Now that your server is running and secure, you can tell the world to send email to it.

1.  Go back to your DNS management panel.
2.  Create a new **`MX` record**:
    -   **Host/Name:** `@` (or `yourdomain.com`)
    -   **Value/Points to:** `mail.yourdomain.com`
    -   **Priority:** `10`
    -   **TTL:** 1 hour

Your email server is now live and ready to receive email.

---

## Step 6: Configure Automatic SSL Renewal

The `renew-ssl.sh` script included in this repository will automatically renew your certificate and restart Nginx.

**Note on Renewals:** The `certbot renew` command is intelligent. It will check your certificate's expiration date and will **only** attempt a renewal if the certificate is within 30 days of expiring. The cron job runs daily to ensure that when the time comes, it will reliably renew.

To set up the automation:

1.  **Open the system's crontab editor:**
    ```bash
    sudo crontab -e
    ```

2.  **Add this line to the bottom of the file.** This will run the script every night at 2:30 AM.
    ```
    30 2 * * * /path/to/your/una.email-install/renew-ssl.sh > /dev/null 2>&1
    ```
    *(Remember to replace `/path/to/your/una.email-install` with the actual absolute path to the directory where you cloned the repository).*

---

## Usage & Troubleshooting

-   **Web Interface**: Access via `https://mail.yourdomain.com`
-   **Check Startup/SSL Logs**: `docker compose logs nginx`
-   **Test Email**: Send an email from an external account (like Gmail) to any address at your domain (e.g., `hello@yourdomain.com`).

**Troubleshooting Commands:**
```
```