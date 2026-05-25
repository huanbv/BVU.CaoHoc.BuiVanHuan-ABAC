# ABAC Demo - Deploy to VPS (`abac.thehuan.com`)

## 1) DNS

- Add `A` record: `abac.thehuan.com` -> `YOUR_VPS_PUBLIC_IP`
- Wait until DNS resolves correctly before creating SSL cert.

## 2) Prepare VPS (Ubuntu 22.04)

```bash
sudo apt update
sudo apt install -y docker.io docker-compose-plugin nginx certbot python3-certbot-nginx
sudo systemctl enable --now docker
```

## 3) Deploy application

Clone/upload this repository, then run:

```bash
cd /path/to/abac_demo
cat > .env <<'EOF'
POSTGRES_DB=abac_demo
POSTGRES_USER=postgres
POSTGRES_PASSWORD=change_me_to_a_strong_password
EOF

docker compose -f docker-compose.prod.yml up -d --build
docker compose -f docker-compose.prod.yml ps
```

## 4) Configure Nginx

```bash
sudo cp deploy/nginx/abac.thehuan.com.conf /etc/nginx/sites-available/abac.thehuan.com.conf
sudo ln -s /etc/nginx/sites-available/abac.thehuan.com.conf /etc/nginx/sites-enabled/abac.thehuan.com.conf
sudo nginx -t
sudo systemctl reload nginx
```

## 5) Enable HTTPS (Let's Encrypt)

```bash
sudo certbot --nginx -d abac.thehuan.com --redirect -m you@example.com --agree-tos -n
```

Verify:

```bash
curl -I https://abac.thehuan.com
```

## 6) Open firewall (if UFW is enabled)

```bash
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'
sudo ufw enable
```

## 7) Common operations

```bash
# Restart app stack
docker compose -f docker-compose.prod.yml restart

# View app logs
docker compose -f docker-compose.prod.yml logs -f web

# Update after pulling new code
docker compose -f docker-compose.prod.yml up -d --build
```

## 8) Cập nhật nhanh (systemd + Gunicorn, không Docker)

Sau khi clone repo tại `/var/www/abac` và cấu hình `systemctl` unit `abac-demo`, mỗi lần có code mới trên GitHub:

```bash
cd /var/www/abac/abac_demo
sudo chmod +x scripts/deploy_vps_update.sh
# Một lần (tránh lỗi dubious ownership), nếu chưa làm:
# git config --global --add safe.directory /var/www/abac
# Hoặc dùng:
sudo AUTO_SAFE_DIR=1 ./scripts/deploy_vps_update.sh
```

Lần sau chỉ cần:

```bash
cd /var/www/abac/abac_demo
sudo ./scripts/deploy_vps_update.sh
```

Nếu VPS có chỉnh tay file tracked và muốn **bỏ hết** để đồng bộ GitHub: `sudo FORCE_RESTORE=1 ./scripts/deploy_vps_update.sh`.  
Xem đầu file `scripts/deploy_vps_update.sh` để biết đầy đủ biến `DEPLOY_*`, `SKIP_*`.

## Notes

- Production stack binds app to `127.0.0.1:5000`; public access should go through Nginx only.
- `POSTGRES_PASSWORD` must be changed from default before production use.
