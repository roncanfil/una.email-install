#!/bin/bash

# UNA.Email Configuration Generator

set -e

echo "=== UNA.Email Installation ==="
echo "This script will install and configure una.email for your domain"
echo ""

# Function to validate domain format
validate_domain() {
    local domain=$1
    if [[ ! $domain =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        echo "❌ Invalid domain format: $domain"
        return 1
    fi
    return 0
}

# Get domain from user
read -p "Enter your domain (e.g., example.com): " DOMAIN

# Validate domain
if ! validate_domain "$DOMAIN"; then
    echo "Please enter a valid domain name"
    exit 1
fi

echo ""
echo "✅ Domain validated: $DOMAIN"
echo ""

# Create .env file if it doesn't exist
if [ ! -f .env ]; then
    echo "Creating .env file..."
    cat > .env << EOF
# UNA.Email Configuration
DOMAIN=$DOMAIN
DB_PASSWORD=una_email_password
NODE_ENV=production
IMAGE_TAG=latest
EOF
    echo "✅ Created .env file"
else
    echo "📝 Updating existing .env file..."
    # Update DOMAIN in existing .env file
    if grep -q "^DOMAIN=" .env; then
        # Use sed with different options for macOS compatibility
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s/^DOMAIN=.*/DOMAIN=$DOMAIN/" .env
        else
            sed -i "s/^DOMAIN=.*/DOMAIN=$DOMAIN/" .env
        fi
    else
        echo "DOMAIN=$DOMAIN" >> .env
    fi
    echo "✅ Updated .env file"
fi

echo ""

# Generate Postfix configuration templates
echo "📧 Using Postfix configuration templates..."

# Check if templates exist
if [ ! -f mail/main.cf.template ] || [ ! -f mail/transport.template ] || [ ! -f mail/virtual.template ]; then
    echo "❌ Error: Template files not found. Please ensure mail/main.cf.template, mail/transport.template, and mail/virtual.template exist."
    exit 1
fi

echo "✅ Found Postfix configuration templates"

# Generate actual configuration files
echo "📝 Generating configuration files for domain: $DOMAIN"

# Generate main.cf
sed "s/\${DOMAIN}/$DOMAIN/g" mail/main.cf.template > mail/main.cf
echo "✅ Generated mail/main.cf"

# Generate transport
sed "s/\${DOMAIN}/$DOMAIN/g" mail/transport.template > mail/transport
echo "✅ Generated mail/transport"

# Generate virtual
sed "s/\${DOMAIN}/$DOMAIN/g" mail/virtual.template > mail/virtual
echo "✅ Generated mail/virtual"

echo ""
echo "=== Configuration Complete ==="
echo ""
echo "📋 DNS Configuration Required:"
echo "   A record: mail.$DOMAIN → YOUR_SERVER_IP"
echo "   MX record: $DOMAIN → 10 mail.$DOMAIN"
echo ""
echo "🚀 Next steps:"
echo "   1. Configure your DNS records (see above)"
echo "   2. Run: docker compose up -d"
echo "   3. Access web interface at: http://YOUR_SERVER_IP"
echo ""
echo "📧 Test email: Send to any@$DOMAIN"
echo ""
echo "✅ UNA.Email is now configured for domain: $DOMAIN" 