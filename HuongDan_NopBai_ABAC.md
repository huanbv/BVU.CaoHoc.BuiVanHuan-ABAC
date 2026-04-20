# Hướng dẫn sử dụng bộ tài liệu ABAC

## 1) Danh sách file đã chuẩn bị

| File | Mô tả |
|---|---|
| TieuLuan_ABAC_HoSoQuocGia.md | Tiểu luận hoàn chỉnh 3 chương (Markdown) |
| ABAC_System_Prototype.sql | Script CSDL PostgreSQL: 10 bảng, 8 policy, triggers, views, 10 test cases |
| abac_demo/app.py | Flask API backend (PEP + PDP) |
| abac_demo/abac_engine.py | Python ABAC engine (PDP layer) |
| abac_demo/database.py | Module kết nối PostgreSQL |
| abac_demo/templates/index.html | Giao diện web demo 4 tab |
| abac_demo/requirements.txt | Python dependencies |
| abac_demo/Dockerfile | Docker image cho Flask app |
| abac_demo/docker-compose.yml | Docker Compose (PostgreSQL + Flask) |

## 2) Cách đưa nội dung vào mẫu FORM của thầy

1. Mở file `FORM_TIỂU LUẬN-RÚT GỌN.docx`.
2. Giữ nguyên trang bìa, thông tin môn học, định dạng Heading (Heading 1 = Chương, Heading 2 = mục 1.1, Heading 3 = mục 1.1.1).
3. Copy nội dung từ file `TieuLuan_ABAC_HoSoQuocGia.md` vào phần thân bài.
4. Cập nhật: Họ tên, MSSV, Lớp, Giảng viên hướng dẫn.
5. Chèn hình ảnh:
   - Sơ đồ kiến trúc PEP/PDP/PIP/PAP (copy từ mô tả ASCII hoặc vẽ bằng draw.io).
   - Ảnh chụp giao diện web demo (chạy hệ thống → screenshot 4 tab).
   - Bảng kết quả test case (screenshot từ web hoặc từ psql).
6. Menu → References → Table of Contents → Update cập nhật mục lục.

## 3) Cách chạy demo — Cách 1: Docker (Nhanh nhất)

Yêu cầu: Docker Desktop đã cài.

```powershell
# Vào thư mục abac_demo
cd abac_demo

# Khởi chạy PostgreSQL + Flask
docker-compose up --build

# Mở trình duyệt
# http://localhost:5000
```

Hệ thống tự động:
- Tạo database `abac_demo`
- Chạy script SQL khởi tạo schema + dữ liệu mẫu
- Khởi động Flask API tại port 5000

## 4) Cách chạy demo — Cách 2: Thủ công (Không dùng Docker)

### Bước 1: Cài PostgreSQL
- Tải PostgreSQL 14+ từ https://www.postgresql.org/download/
- Tạo database mới:
```sql
CREATE DATABASE abac_demo;
```

### Bước 2: Nạp script SQL
```powershell
psql -U postgres -d abac_demo -f ABAC_System_Prototype.sql
```

### Bước 3: Cài Python dependencies
```powershell
cd abac_demo
pip install -r requirements.txt
```

### Bước 4: Chạy Flask app
```powershell
# Thiết lập biến môi trường (nếu khác mặc định)
$env:DB_HOST="localhost"
$env:DB_PORT="5432"
$env:DB_NAME="abac_demo"
$env:DB_USER="postgres"
$env:DB_PASSWORD="postgres"

python app.py
```

### Bước 5: Mở trình duyệt
```
http://localhost:5000
```

## 5) Cách chạy demo — Cách 3: Chỉ chạy SQL (Không cần Python)

Nếu chỉ cần demo trên psql hoặc pgAdmin:

```powershell
psql -U postgres -d abac_demo -f ABAC_System_Prototype.sql
```

Script sẽ tự động chạy 10 test cases ở cuối file và hiển thị kết quả. Có thể chạy thêm:

```sql
-- Xem audit trail
SELECT * FROM v_audit_trail;

-- Xem thống kê user
SELECT * FROM v_user_access_stats;

-- Xem policy hit
SELECT * FROM v_policy_hit_stats;

-- Xem phát hiện bất thường
SELECT * FROM v_anomaly_detection;

-- Test thêm trường hợp mới
SELECT * FROM request_access(1, 1, 'read', 'high', 'internal', 10, NULL, 'normal');
```

## 6) Giao diện web demo — 4 tab chính

| Tab | Mô tả |
|---|---|
| **Kiểm tra truy cập** | Chọn user/resource/action/env → nhấn kiểm tra → xem PERMIT/DENY + lý do + policy ID + trace ID |
| **Người dùng & Tài nguyên** | Xem danh sách users với thuộc tính mở rộng, resources với cấp mật |
| **Chính sách** | Xem 8 policy + conditions, bật/tắt policy trực tiếp |
| **Nhật ký kiểm toán** | Xem log, thống kê permit/deny, phát hiện bất thường |

## 7) Gợi ý trình bày khi bảo vệ

1. **Mở đầu (2 phút)**: Nêu lý do RBAC không đủ cho dữ liệu nhạy cảm liên ngành.
2. **Lý thuyết (3 phút)**: Giải thích 4 nhóm thuộc tính ABAC + bảng so sánh DAC/MAC/RBAC/ABAC.
3. **Thiết kế (5 phút)**: Trình bày kiến trúc PEP/PDP/PIP/PAP + ERD + tập chính sách.
4. **Demo trực tiếp (5 phút)**:
   - Mở tab "Kiểm tra truy cập" → chạy TC01 (PERMIT) → TC02 (DENY do thiết bị).
   - Mở tab "Chính sách" → tắt policy P2 → chạy lại TC02 → giờ PERMIT.
   - Mở tab "Nhật ký" → cho thấy log chi tiết.
5. **Kết luận (2 phút)**: Nhấn mạnh ABAC linh hoạt, kiểm toán tốt, mở rộng cho liên ngành.
