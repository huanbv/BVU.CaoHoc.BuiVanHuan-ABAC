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

## Bảo mật (ứng dụng không đăng nhập)

Demo vẫn cho phép mọi người gọi API đọc / kiểm tra PEP; các lớp bù sau giúp giảm lạm dụng và bảo vệ thao tác ghi:

| Biến môi trường | Mục đích |
|------------------|----------|
| **`ABAC_ADMIN_TOKEN`** | Bắt buộc khi bật: mọi `PUT /api/policies/<id>/toggle` phải gửi header `X-Abac-Admin-Token: <token>` hoặc `Authorization: Bearer <token>`. **Nên đặt** trên môi trường công khai. Nếu để trống, server ghi cảnh báo khi khởi động và ai cũng có thể bật/tắt chính sách. |
| **`ABAC_TRUST_PROXY=1`** | Khi chạy sau Nginx, bật để rate limit và log dùng IP thật từ `X-Forwarded-For` (và `ProxyFix` cho URL/scheme). |
| **`ABAC_DEBUG_ERRORS=1`** | Chỉ dùng khi gỡ lỗi: API 500 trả về chi tiết exception. Mặc định tắt — client chỉ thấy thông báo chung. |
| **`ABAC_MAX_BODY_BYTES`** | Giới hạn kích thước body JSON (mặc định 65536). |
| **`ABAC_MAX_SEARCH_LEN`** | Độ dài tối đa tham số `q` trên `/api/users`, `/api/resources` (mặc định 200). |

| **`ABAC_STATS_SINCE_DAYS`** | `/api/audit/stats` — bảng bất thường chỉ tính log có `request_time` trong N ngày (mặc định **90**). Đặt **`0`** để không lọc (có thể rất chậm/treo nếu bảng lớn). |
| **`ABAC_STATS_ANOMALY_MIN_REQUESTS`** | Ngưỡng tối thiểu số request/user để vào bảng anomaly (mặc định **2**). |
| **`ABAC_STATS_ANOMALY_LIMIT`** | Số dòng tối đa trả về (10–500, mặc định **150**). |

Ứng dụng còn: **giới hạn tốc độ theo IP** (Flask-Limiter, bộ nhớ in-process — mỗi worker Gunicorn có bộ đếm riêng), **tiêu đề HTTP** (CSP cơ bản, `X-Frame-Options: DENY`, …), **kiểm tra allowlist** cho payload `/api/access/check`.

Gợi ý thêm tại Nginx: `limit_req` cho `location /api/`, HSTS sau khi có HTTPS, và chỉ mở cổng 80/443. Với nhiều bản ghi `access_requests`, tạo chỉ mục ví dụ `CREATE INDEX IF NOT EXISTS idx_access_requests_time ON access_requests (request_time DESC);` giúp cửa sổ thời gian nhanh hơn.

## Tab Hiệu năng PDP (mục 3.2.2 tiểu luận)

- UI: tab **Hiệu năng PDP** — đo `evaluate_access_dynamic()` thực tế, so 3 kịch bản index, đối chiếu Bảng 10 tiểu luận.
- Bắt buộc **`ABAC_ADMIN_TOKEN`**. Một lần trên VPS (superuser `postgres`):

```bash
cd /var/www/abac/abac_demo
# Ubuntu: phải chạy psql bằng user hệ thống postgres (không chạy psql -U postgres khi đang root)
sudo -u postgres psql -d abac_demo -v ON_ERROR_STOP=1 -f scripts/perf_grants_abac_user.sql
sudo -u postgres psql -d abac_demo -v app_user=abac_user -v ON_ERROR_STOP=1 -f scripts/perf_index_functions.sql
```

(`app_user` = `DB_USER` trong `/etc/abac-app.env`.)
- Biến tùy chọn: `ABAC_PERF_BATCHES` (mặc định 5), `ABAC_PERF_REQUESTS_PER_BATCH` (mặc định 1000).
- **Timeout:** Gunicorn mặc định 30s sẽ cắt benchmark → UI không nhận JSON. Thêm `--timeout 900` vào `ExecStart` (xem `deploy/systemd/abac-demo.service.example`). Nginx: `proxy_read_timeout 900s` cho `/api/performance/` (xem `deploy/nginx/abac.thehuan.com.conf`).
- Quy trình: **Seed preset** → **Chạy benchmark**. Lần đầu thử **100 yêu cầu × 3 đợt × 1 kịch bản** để xác nhận bảng kết quả hiện.

## Tab TPS / P95 (mục 3.2.3 — Bảng 11)

- UI: tab **TPS / P95** — load test `request_access()` (PEP+PDP+ghi request), đo **TPS** và **P95 latency**.
- SQL (một lần):

```bash
sudo -u postgres psql -d abac_demo -v ON_ERROR_STOP=1 -f scripts/loadtest_functions.sql
sudo -u postgres psql -d abac_demo -v ON_ERROR_STOP=1 -f scripts/loadtest_history.sql
```

- CLI trên VPS (tuỳ chọn):

```bash
source venv/bin/activate && set -a && source /etc/abac-app.env && set +a
python scripts/run_loadtest_cli.py --duration 30 --workers 4 --save --note "Bảng 11"
```

- Biến load test: `ABAC_LOADTEST_DURATION_SEC` (30), `ABAC_LOADTEST_WORKERS` (4), `ABAC_LOADTEST_RUN_LIMIT` (10/hour).
- **Ngoại suy Citus (dòng dự báo Bảng 11)** — tính từ kết quả đo `partition`:

| Biến | Mặc định | Ý nghĩa |
|------|----------|---------|
| `ABAC_CITUS_TPS_FACTOR_LO` | 1.5 | Hệ số TPS tối thiểu (× partition TPS) |
| `ABAC_CITUS_TPS_FACTOR_HI` | 2.0 | Hệ số TPS tối đa |
| `ABAC_CITUS_P95_FACTOR_LO` | 0.60 | P95 tối thiểu (= giảm ~40%) |
| `ABAC_CITUS_P95_FACTOR_HI` | 0.70 | P95 tối đa (= giảm ~30%) |

Mẫu đầy đủ: `deploy/abac-app.env.example`. Chỉ block Citus: `deploy/env/citus-forecast.env.snippet`.

Sau `git pull`, trên VPS (một lần hoặc khi thêm biến mới):

```bash
cd /var/www/abac/abac_demo
# Nếu chưa có 4 dòng Citus trong /etc/abac-app.env:
grep -q ABAC_CITUS_TPS_FACTOR_LO /etc/abac-app.env 2>/dev/null || \
  sudo bash -c 'grep -v "^#" deploy/env/citus-forecast.env.snippet | grep -v "^$" >> /etc/abac-app.env'
sudo systemctl restart abac-demo
```

- Nginx: `proxy_read_timeout 900s` cho `/api/loadtest/` (cùng rule với `/api/performance/`).

## Notes

- Production stack binds app to `127.0.0.1:5000`; public access should go through Nginx only.
- `POSTGRES_PASSWORD` must be changed from default before production use.
