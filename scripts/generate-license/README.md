# UNA License Generator

This folder contains everything needed to generate cryptographically signed licenses for UNA customers.

## Files

- `generate-license.js` - Main license generation script
- `private_key.pem` - RSA private key for signing licenses (KEEP SECRET!)
- `public_key.pem` - RSA public key (embedded in UNA for verification)
- `README.md` - This documentation

## Quick Start

```bash
# Generate a license for a customer
node generate-license.js customer@example.com mail.example.com 2025-12-31
```

## Usage

### Basic License Generation

```bash
node generate-license.js <email> <domain> <expires>
```

**Parameters:**
- `email` - Customer's email address
- `domain` - Domain for the license (e.g., `mail.example.com`)
- `expires` - Expiry date in YYYY-MM-DD format

### Examples

```bash
# License for main domain
node generate-license.js admin@company.com company.com 2025-12-31

# License for subdomain
node generate-license.js admin@company.com mail.company.com 2026-06-30

# License for different customer
node generate-license.js john@startup.com startup.com 2025-08-15
```

## Business Workflow

### 1. Customer Purchase
Customer pays $89/year for UNA license

### 2. Generate License
```bash
node generate-license.js customer@domain.com domain.com 2025-12-31
```

### 3. Deliver License
- Email the generated `LICENSE.key` file to customer
- Customer places it in their UNA installation directory

### 4. Customer Deployment
```bash
# Customer runs
./install.sh
```

## Security Features

### Cryptographic Signatures
- **RSA-2048** encryption
- **SHA-256** hashing
- **Tamper-proof** licenses
- **Domain binding** prevents sharing

### Exact Domain Matching
- License for `mail.example.com` only works on `mail.example.com`
- License for `example.com` only works on `example.com`
- **No subdomain abuse** possible

### Input Validation
- Email format validation
- Domain format validation
- Future date requirement
- Required field checking

## File Structure

```
scripts/generate-license/
├── generate-license.js    # Main script
├── private_key.pem        # Private key (SECRET!)
├── public_key.pem         # Public key (safe to share)
└── README.md             # This documentation
```

## Key Management

### Private Key (`private_key.pem`)
- **KEEP SECRET!** Never share or commit to version control
- Used to sign licenses
- If compromised, all licenses become invalid
- Backup securely

### Public Key (`public_key.pem`)
- Safe to share and embed in UNA software
- Used to verify license signatures
- Already embedded in UNA's license validation system

## Output

The script generates a `LICENSE.key` file with:

```json
{
  "licensed_to": "customer@example.com",
  "domain": "mail.example.com",
  "expires": "2025-12-31",
  "signature": "base64_encrypted_signature..."
}
```

## Integration with UNA

The generated license works with UNA's validation system:

1. **License file** placed in UNA root directory
2. **UNA validates** signature using embedded public key
3. **Domain matching** ensures exact domain compliance
4. **Expiration checking** enforces license terms

## Troubleshooting

### "Error loading private key"
- Make sure `private_key.pem` exists in the script directory
- Check file permissions

### "Invalid email format"
- Use valid email format: `user@domain.com`
- No spaces or special characters

### "Invalid domain format"
- Use valid domain format: `example.com` or `mail.example.com`
- No protocols (http://) or ports (:3000)

### "Expiry date must be in the future"
- Use future date in YYYY-MM-DD format
- Example: `2025-12-31`

## Production Setup

### For Sales Website Integration
```javascript
const { generateLicense } = require('./generate-license.js');

// After successful payment
const license = generateLicense(
  customerEmail,
  customerDomain,
  expiryDate
);

// Email license to customer
sendLicenseEmail(customerEmail, license);
```

### For Manual Sales
1. Run script manually for each customer
2. Email LICENSE.key file
3. Provide deployment instructions

## Pricing Model

- **$89/year** per license
- **One license = one domain**
- **Exact domain matching** prevents abuse
- **Automatic expiration** ensures renewals

## Support

For license generation issues:
- Check input validation errors
- Verify private key exists
- Ensure domain format is correct
- Confirm expiry date is in future 