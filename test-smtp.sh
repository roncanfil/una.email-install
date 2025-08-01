#!/bin/bash

echo "=== SMTP Connection Test ==="
echo "Testing connection to mail.ronaldhenriquez.com on port 25..."

# Test if port 25 is open
echo "1. Testing if port 25 is open..."
nc -zv mail.ronaldhenriquez.com 25

echo ""
echo "2. Testing SMTP greeting..."
echo "QUIT" | nc mail.ronaldhenriquez.com 25

echo ""
echo "3. Testing from localhost..."
echo "QUIT" | nc localhost 25

echo ""
echo "4. Checking if Postfix is running in container..."
docker compose exec postfix postfix status

echo ""
echo "5. Checking Postfix logs..."
docker compose logs postfix | tail -20

echo ""
echo "=== Test Complete ===" 