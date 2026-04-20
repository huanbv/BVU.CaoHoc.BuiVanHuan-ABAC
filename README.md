# ABAC - Hệ thống kiểm soát truy cập dựa trên thuộc tính

## Đề tài
**Thiết kế mô hình phân quyền dựa trên thuộc tính (ABAC) kiểm soát truy cập cho hệ thống hồ sơ dữ liệu nhạy cảm cấp quốc gia**

Tiểu luận môn Cơ sở dữ liệu nâng cao — Trường Đại học Bà Rịa - Vũng Tàu.

## Cấu trúc dự án

```
├── ABAC_System_Prototype.sql   # Script CSDL PostgreSQL (10 bảng, hàm PL/pgSQL, trigger, view)
├── HuongDan_NopBai_ABAC.md     # Hướng dẫn triển khai chi tiết
├── abac_demo/
│   ├── app.py                  # Flask API backend (PEP)
│   ├── abac_engine.py          # Python ABAC engine (PDP)
│   ├── database.py             # PostgreSQL connection module
│   ├── requirements.txt        # Python dependencies
│   ├── Dockerfile              # Docker image cho Flask app
│   ├── docker-compose.yml      # Docker Compose (PostgreSQL + Flask)
│   └── templates/
│       └── index.html          # Giao diện web demo (4 tab)
```

## Kiến trúc hệ thống

- **PEP** (Policy Enforcement Point): Flask middleware
- **PDP** (Policy Decision Point): PL/pgSQL + Python engine
- **PIP** (Policy Information Point): PostgreSQL tables
- **PAP** (Policy Administration Point): Web UI

## Chạy nhanh với Docker

```bash
cd abac_demo

# Khởi chạy PostgreSQL + Flask
docker-compose up --build -d

# Mở giao diện web
# http://localhost:5000
```

## Chạy thủ công

### 1. PostgreSQL
```bash
# Tạo database
createdb abac_demo

# Import schema + dữ liệu mẫu
psql -d abac_demo -f ABAC_System_Prototype.sql
```

### 2. Flask API
```bash
cd abac_demo
pip install -r requirements.txt

# Cấu hình kết nối DB (tùy chọn)
export DB_HOST=localhost
export DB_PORT=5432
export DB_NAME=abac_demo
export DB_USER=postgres
export DB_PASSWORD=postgres

# Chạy
python app.py
```

Mở http://localhost:5000 để truy cập giao diện demo.

## Tính năng demo

- **Access Check**: Kiểm tra quyền truy cập với 10 test case mẫu
- **Users & Resources**: Xem danh sách người dùng, tài nguyên, thuộc tính
- **Policies**: Xem/bật/tắt 8 chính sách ABAC
- **Audit Log**: Nhật ký kiểm toán với thống kê

## Chính sách ABAC mẫu

| # | Chính sách | Effect | Priority |
|---|-----------|--------|----------|
| P1 | Deny: Người dùng không hoạt động | DENY | 100 |
| P2 | Deny: Thiết bị không tin cậy | DENY | 95 |
| P3 | Deny: External + dữ liệu tối mật | DENY | 90 |
| P4 | Deny: Ngoài giờ hành chính | DENY | 85 |
| P5 | Deny: Mức đe dọa an ninh critical | DENY | 80 |
| P6 | Permit: Cùng cơ quan, đủ cấp | PERMIT | 50 |
| P7 | Permit: Liên ngành có grant | PERMIT | 45 |
| P8 | Permit: Break-glass khẩn cấp | PERMIT | 30 |

## Công nghệ

- PostgreSQL 14+ (PL/pgSQL, JSONB)
- Python 3.11 + Flask 3.1
- HTML5 / CSS3 / JavaScript
- Docker + Docker Compose
