#!/usr/bin/env node

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// Configuration
const PRIVATE_KEY_PATH = './private_key.pem';
const LICENSE_OUTPUT_PATH = './LICENSE.key';

// Load private key
function loadPrivateKey() {
  try {
    return fs.readFileSync(PRIVATE_KEY_PATH, 'utf8');
  } catch (error) {
    console.error('❌ Error loading private key:', error.message);
    console.error('Make sure private_key.pem exists in the current directory');
    process.exit(1);
  }
}

// Generate license with cryptographic signature
function generateLicense(licensedTo, domain, expiresDate) {
  const privateKey = loadPrivateKey();
  
  // License data (without signature)
  const licenseData = {
    licensed_to: licensedTo,
    domain: domain,
    expires: expiresDate  // YYYY-MM-DD format
  };
  
  // Create signature
  const dataToSign = JSON.stringify(licenseData);
  const sign = crypto.createSign('SHA256');
  sign.update(dataToSign);
  const signature = sign.sign(privateKey, 'base64');
  
  // Complete license
  const completeLicense = {
    ...licenseData,
    signature: signature
  };
  
  return completeLicense;
}

// Save license to file
function saveLicense(license, outputPath) {
  try {
    fs.writeFileSync(outputPath, JSON.stringify(license, null, 2));
    console.log(`✅ License saved to: ${outputPath}`);
  } catch (error) {
    console.error('❌ Error saving license:', error.message);
    process.exit(1);
  }
}

// Validate input
function validateInput(licensedTo, domain, expiresDate) {
  if (!licensedTo || !domain || !expiresDate) {
    console.error('❌ Missing required parameters');
    console.error('Usage: node generate-license.js <email> <domain> <expires>');
    console.error('Example: node generate-license.js admin@example.com mail.example.com 2025-12-31');
    process.exit(1);
  }
  
  // Validate email format
  const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  if (!emailRegex.test(licensedTo)) {
    console.error('❌ Invalid email format:', licensedTo);
    process.exit(1);
  }
  
  // Validate domain format
  const domainRegex = /^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/;
  if (!domainRegex.test(domain)) {
    console.error('❌ Invalid domain format:', domain);
    process.exit(1);
  }
  
  // Validate date format
  const dateRegex = /^\d{4}-\d{2}-\d{2}$/;
  if (!dateRegex.test(expiresDate)) {
    console.error('❌ Invalid date format. Use YYYY-MM-DD:', expiresDate);
    process.exit(1);
  }
  
  // Check if date is in the future
  const expiryDate = new Date(expiresDate);
  const now = new Date();
  if (expiryDate <= now) {
    console.error('❌ Expiry date must be in the future:', expiresDate);
    process.exit(1);
  }
}

// Main function
function main() {
  const args = process.argv.slice(2);
  
  if (args.length !== 3) {
    console.log('🔐 UNA License Generator');
    console.log('========================');
    console.log('');
    console.log('Usage: node generate-license.js <email> <domain> <expires>');
    console.log('');
    console.log('Parameters:');
    console.log('  email   - Customer email address');
    console.log('  domain  - Domain for license (e.g., mail.example.com)');
    console.log('  expires - Expiry date (YYYY-MM-DD)');
    console.log('');
    console.log('Examples:');
    console.log('  node generate-license.js admin@example.com mail.example.com 2025-12-31');
    console.log('  node generate-license.js john@mydomain.com mydomain.com 2026-01-15');
    console.log('');
    console.log('Output: LICENSE.key file in current directory');
    process.exit(1);
  }
  
  const [licensedTo, domain, expiresDate] = args;
  
  console.log('🔐 UNA License Generator');
  console.log('========================');
  console.log('');
  
  // Validate input
  validateInput(licensedTo, domain, expiresDate);
  
  console.log('📋 License Details:');
  console.log(`   Email: ${licensedTo}`);
  console.log(`   Domain: ${domain}`);
  console.log(`   Expires: ${expiresDate}`);
  console.log('');
  
  // Generate license
  console.log('🔑 Generating license...');
  const license = generateLicense(licensedTo, domain, expiresDate);
  
  // Save license
  saveLicense(license, LICENSE_OUTPUT_PATH);
  
  console.log('');
  console.log('📄 License Content:');
  console.log(JSON.stringify(license, null, 2));
  console.log('');
  console.log('✅ License generation complete!');
  console.log('');
  console.log('Next steps:');
  console.log('1. Copy LICENSE.key to your UNA installation');
  console.log('2. Run ./install.sh to deploy');
  console.log('3. Access UNA at http://' + domain + ':3000');
}

// Run if called directly
if (require.main === module) {
  main();
}

module.exports = { generateLicense, validateInput }; 