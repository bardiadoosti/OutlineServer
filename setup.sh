#!/bin/bash

# Exit on error
set -e

echo "--- Outline Shadowsocks + WebSockets Auto-Setup ---"
read -p "Enter your domain (e.g., example.com): " DOMAIN
read -p "Enter your contact email for SSL: " EMAIL
OUTLINE_PORT=17543
WEBROOT="/var/www/html"

# 1. Install Nginx
echo "Installing Nginx..."
apt update && apt install -y nginx-light wget tar python3 python3-dev python3-venv libaugeas-dev gcc

# 2. Initial Nginx Config for Certbot validation
echo "Configuring Nginx for SSL validation..."
cat <<EOF > /etc/nginx/conf.d/$DOMAIN.conf
server {
    listen 80;
    listen [::]:80;

    server_name $DOMAIN;

    root $WEBROOT;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
nginx -s reload

# 3. Install Certbot via venv
echo "Installing Certbot..."
python3 -m venv /opt/certbot/
/opt/certbot/bin/pip install --upgrade pip
/opt/certbot/bin/pip install certbot
ln -sf /opt/certbot/bin/certbot /usr/bin/certbot

# 4. Issue SSL Certificate
echo "Issuing SSL certificate..."
certbot certonly --webroot -w $WEBROOT -d $DOMAIN --email $EMAIL --agree-tos --non-interactive

# 5. Config SSL on Nginx
echo "Config SSL on Nginx..."
cat <<EOF > /etc/nginx/conf.d/$DOMAIN.conf
server {
    listen 80;
    listen [::]:80;
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    root $WEBROOT;
    index index.html index.nginx-debian.html;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
nginx -s reload

# 6. Setup Outline Shadowsocks Server
echo "Downloading and setting up outline-ss-server..."
mkdir -p outline-ss-server
cd outline-ss-server
wget https://github.com/Jigsaw-Code/outline-ss-server/releases/download/v1.9.2/outline-ss-server_1.9.2_linux_x86_64.tar.gz
tar -xf outline-ss-server_1.9.2_linux_x86_64.tar.gz

# Generate random paths and secrets
TCP_PATH=$(head /dev/urandom | tr -dc a-z0-9 | head -c 22)
UDP_PATH=$(head /dev/urandom | tr -dc a-z0-9 | head -c 22)
SECRET=$(head /dev/urandom | tr -dc a-z0-9 | head -c 20)

cat <<EOF > config.yaml
web:
  servers:
    - id: server1
      listen:
        - "127.0.0.1:$OUTLINE_PORT"

services:
  - listeners:
      - type: websocket-stream
        web_server: server1
        path: "/$TCP_PATH"
      - type: websocket-packet
        web_server: server1
        path: "/$UDP_PATH"
    keys:
      - id: '1'
        cipher: chacha20-ietf-poly1305
        secret: $SECRET
EOF

# 7. Final Nginx Configuration (Reverse Proxy + SSL)
echo "Finalizing Nginx configuration..."
cat <<EOF > /etc/nginx/conf.d/$DOMAIN.conf
upstream outline {
    server localhost:$OUTLINE_PORT;
}

server {
    listen 80;
    listen [::]:80;
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    root $WEBROOT;
    index index.html index.nginx-debian.html;
    
    location / {
        try_files \$uri \$uri/ =404;
    }

    location /$TCP_PATH {
        proxy_pass http://outline;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location /$UDP_PATH {
        proxy_pass http://outline;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
systemctl reload nginx

# 8. Create Client YAML Config for web access
echo "Creating client configuration file..."
cat <<EOF > $WEBROOT/config.txt
transport:
  \$type: tcpudp

  tcp:
    \$type: shadowsocks
    endpoint:
      \$type: websocket
      url: wss://$DOMAIN/$TCP_PATH
    cipher: chacha20-ietf-poly1305
    secret: $SECRET

  udp:
    \$type: shadowsocks
    endpoint:
      \$type: websocket
      url: wss://$DOMAIN/$UDP_PATH
    cipher: chacha20-ietf-poly1305
    secret: $SECRET
EOF

# 8. Start the Server (using nohup for persistence)
echo "Starting Outline Server..."
nohup ./outline-ss-server --config config.yaml --replay_history 10000 > server.log 2>&1 &

echo "--------------------------------------------------"
echo "Setup Complete!"
echo "Client Config URL: https://$DOMAIN/config.txt"
echo "Outline Access Key: ssconf://$DOMAIN/config.txt"
echo "--------------------------------------------------"
