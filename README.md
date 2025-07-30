# UNA - Your Personal Email Empire

**Stop giving away your real email address. Start taking control.**

UNA is a self-hosted email address management system that lets creators, entrepreneurs, and privacy-conscious individuals create unlimited email addresses for their domain - all managed from one beautiful interface.

## The Problem Every Creator Faces

- 📧 **Email Chaos**: Using your main email for everything from newsletter signups to business inquiries
- 🕵️ **Privacy Invasion**: Companies selling your email to spam lists and data brokers  
- 📊 **No Insights**: Can't track which services are sending you emails or selling your data
- 🔒 **Vendor Lock-in**: Stuck with Gmail/Outlook and their limitations
- 💸 **Expensive Solutions**: Paying $10+/month for basic email address services

## The UNA Solution

**One domain. Infinite possibilities. Complete control.**

✅ **Unlimited Email Addresses**: Create `newsletter@yourdomain.com`, `business@yourdomain.com`, `shopping@yourdomain.com` - anything you want  
✅ **Privacy Protection**: Never give out your real email again  
✅ **Spam Control**: Identify which services leak or sell your email  
✅ **Professional Branding**: Use your own domain for everything  
✅ **Self-Hosted**: No monthly fees, no data mining, complete ownership  
✅ **Creator-Friendly**: Perfect for managing multiple projects, brands, and ventures  

## Perfect For:

🎨 **Content Creators** - Separate emails for sponsors, collaborations, fan mail, and platforms  
🚀 **Entrepreneurs** - Different addresses for each business venture or project  
💻 **Developers** - Testing accounts, service signups, and project communications  
🏠 **Self-Hosters** - Complete control over your digital identity  
🔐 **Privacy Advocates** - No more giving BigTech access to your communications  

## Quick Start

```bash
git clone <repository>
cd una

# Configure for your domain (similar to Mailcow's generate_config.sh)
./generate_config.sh

# Generate license (development or production)
cd scripts/generate-license
node generate-license.js admin@yourdomain.com yourdomain.com 2025-12-31

./install.sh
```

**In 5 minutes, you'll have:**
- Unlimited email addresses on your domain
- A beautiful web interface to manage everything
- Complete privacy and control over your emails

## Real-World Use Cases

### Content Creator Setup
```
youtube@yourdomain.com    → YouTube business inquiries
sponsors@yourdomain.com   → Sponsorship opportunities  
fans@yourdomain.com       → Fan mail and feedback
tools@yourdomain.com      → Software and service signups
```

### Entrepreneur Setup  
```
startup1@yourdomain.com   → First venture emails
startup2@yourdomain.com   → Second project  
networking@yourdomain.com → Industry connections
press@yourdomain.com      → Media and PR inquiries
```

### Privacy-First Setup
```
shopping@yourdomain.com   → Online purchases
newsletters@yourdomain.com → Subscriptions  
testing@yourdomain.com    → Service trials
social@yourdomain.com     → Social media accounts
```

## How it Works

1. **🌐 Configure DNS**: Point your domain's MX records to your server (one-time setup)
2. **📧 Use Any Email Address**: Start using `anything@yourdomain.com` immediately  
3. **👀 Monitor Everything**: See all emails in your unified dashboard
4. **🔍 Track & Organize**: Know exactly which services email you and when
5. **🛡️ Stay Protected**: Your real email stays private forever

## Architecture

```
una/
├── mail/          # Postfix + Node.js email handler
├── web/           # Next.js management interface  
├── docker-compose.yml
└── install.sh     # One-click deployment
```

## Why Self-Host Your Email?

**🔒 Privacy**: No one reads your emails except you  
**💰 Cost**: Pay once for your server, use forever  
**⚡ Performance**: No rate limits or restrictions  
**🎨 Customization**: Modify and extend as needed  
**📊 Analytics**: See exactly what's happening with your emails  
**🌍 Independence**: Not dependent on any email service provider  

## Features

- **🎯 Catch-All Email System**: Every possible email address automatically works
- **🖥️ Modern Web Interface**: Beautiful, responsive, mobile-friendly UI
- **💾 Reliable Storage**: PostgreSQL database for all your emails  
- **🐳 Docker-Powered**: Easy deployment and updates
- **⚡ Real-Time Processing**: Emails appear instantly
- **🔍 Advanced Filtering**: Sort and search by any email address
- **📊 Usage Analytics**: See which email addresses get the most email

## Quick Setup Guide

1. **🌐 Domain Setup**: Point your domain's MX records to your server
2. **⚙️ Configuration**: Run `./generate_config.sh` to configure for your domain
3. **🚀 Deploy**: Run `./install.sh` and you're live in minutes
4. **🎉 Start Using**: Visit http://localhost:3000 and create your first email addresses

## Configuration

### Domain Configuration (Required)

Una.Email uses a configuration generator similar to Mailcow's approach:

```bash
./generate_config.sh
```

This script will:
- ✅ Ask for your domain name
- ✅ Validate the domain format
- ✅ Create/update `.env` file
- ✅ Generate Postfix configuration files
- ✅ Show you the required DNS records

### DNS Records Required

After running `./generate_config.sh`, you'll need these DNS records:

```
# A record for webmail interface
mail.yourdomain.com    A    YOUR_SERVER_IP

# MX record for email delivery  
yourdomain.com         MX   10 mail.yourdomain.com
```

## Development

```bash
# Start development environment
docker-compose up -d

# View logs
docker-compose logs -f

# Rebuild after changes
docker-compose build
```

## Join the Email Revolution

Stop being the product. Start being in control.

**UNA** - Your domain, your rules, your privacy.

---

*Built for creators, by a creator. Licensed under MIT.* 