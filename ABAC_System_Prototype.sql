-- ============================================================================
-- ABAC PROTOTYPE - Hệ thống kiểm soát truy cập dựa trên thuộc tính
-- Dành cho hồ sơ dữ liệu nhạy cảm cấp quốc gia
-- Target DB: PostgreSQL 14+
-- ============================================================================

BEGIN;

-- ============================================================================
-- PHẦN 1: XÓA CÁC ĐỐI TƯỢNG CŨ (NẾU CÓ)
-- ============================================================================
DROP TABLE IF EXISTS audit_logs CASCADE;
DROP TABLE IF EXISTS access_decisions CASCADE;
DROP TABLE IF EXISTS access_requests CASCADE;
DROP TABLE IF EXISTS policy_conditions CASCADE;
DROP TABLE IF EXISTS policies CASCADE;
DROP TABLE IF EXISTS resource_attributes CASCADE;
DROP TABLE IF EXISTS resources CASCADE;
DROP TABLE IF EXISTS user_attributes CASCADE;
DROP TABLE IF EXISTS users CASCADE;
DROP TABLE IF EXISTS agencies CASCADE;

DROP FUNCTION IF EXISTS evaluate_access_dynamic CASCADE;
DROP FUNCTION IF EXISTS request_access CASCADE;
DROP FUNCTION IF EXISTS fn_audit_user_changes CASCADE;
DROP FUNCTION IF EXISTS fn_audit_policy_changes CASCADE;
DROP FUNCTION IF EXISTS fn_prevent_audit_modification CASCADE;

-- ============================================================================
-- PHẦN 2: TẠO BẢNG DỮ LIỆU
-- ============================================================================

-- 2.1 Bảng danh mục cơ quan
CREATE TABLE agencies (
    agency_code VARCHAR(10) PRIMARY KEY,
    agency_name TEXT NOT NULL,
    agency_type TEXT NOT NULL CHECK (agency_type IN ('ministry', 'department', 'provincial', 'special')),
    region TEXT
);

-- 2.2 Bảng người dùng
CREATE TABLE users (
    user_id SERIAL PRIMARY KEY,
    full_name TEXT NOT NULL,
    email TEXT UNIQUE NOT NULL,
    agency_code VARCHAR(10) NOT NULL REFERENCES agencies(agency_code),
    clearance_level INT NOT NULL CHECK (clearance_level BETWEEN 1 AND 5),
    employment_status TEXT NOT NULL CHECK (employment_status IN ('active', 'inactive', 'suspended')),
    position TEXT,
    department TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 2.3 Bảng thuộc tính mở rộng người dùng (EAV)
CREATE TABLE user_attributes (
    attr_id SERIAL PRIMARY KEY,
    user_id INT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    attr_key TEXT NOT NULL,
    attr_value TEXT NOT NULL,
    valid_from TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    valid_to TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_user_attr UNIQUE (user_id, attr_key, valid_from)
);

-- 2.4 Bảng tài nguyên (hồ sơ dữ liệu)
CREATE TABLE resources (
    resource_id SERIAL PRIMARY KEY,
    resource_name TEXT NOT NULL,
    resource_type TEXT NOT NULL CHECK (resource_type IN ('medical', 'judicial', 'financial', 'military', 'diplomatic', 'civil', 'administrative')),
    owner_agency VARCHAR(10) NOT NULL REFERENCES agencies(agency_code),
    classification_level INT NOT NULL CHECK (classification_level BETWEEN 1 AND 5),
    managing_region TEXT,
    record_status TEXT NOT NULL DEFAULT 'active' CHECK (record_status IN ('active', 'archived', 'under_investigation')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 2.5 Bảng thuộc tính mở rộng tài nguyên (EAV)
CREATE TABLE resource_attributes (
    attr_id SERIAL PRIMARY KEY,
    resource_id INT NOT NULL REFERENCES resources(resource_id) ON DELETE CASCADE,
    attr_key TEXT NOT NULL,
    attr_value TEXT NOT NULL,
    CONSTRAINT uq_resource_attr UNIQUE (resource_id, attr_key)
);

-- 2.6 Bảng chính sách ABAC
CREATE TABLE policies (
    policy_id SERIAL PRIMARY KEY,
    policy_name TEXT NOT NULL,
    description TEXT,
    effect TEXT NOT NULL CHECK (effect IN ('permit', 'deny')),
    priority INT NOT NULL,
    target_resource_type TEXT NOT NULL DEFAULT '*',
    target_action TEXT NOT NULL DEFAULT '*',
    is_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 2.7 Bảng điều kiện chính sách
CREATE TABLE policy_conditions (
    condition_id SERIAL PRIMARY KEY,
    policy_id INT NOT NULL REFERENCES policies(policy_id) ON DELETE CASCADE,
    attribute_type TEXT NOT NULL CHECK (attribute_type IN ('subject', 'resource', 'environment', 'action')),
    attribute_key TEXT NOT NULL,
    operator TEXT NOT NULL CHECK (operator IN ('eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'in', 'not_in')),
    compare_value TEXT NOT NULL,
    value_type TEXT NOT NULL DEFAULT 'text' CHECK (value_type IN ('int', 'text', 'boolean', 'list'))
);

-- 2.8 Bảng yêu cầu truy cập
CREATE TABLE access_requests (
    request_id BIGSERIAL PRIMARY KEY,
    request_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    trace_id UUID NOT NULL DEFAULT gen_random_uuid(),
    user_id INT NOT NULL REFERENCES users(user_id),
    resource_id INT NOT NULL REFERENCES resources(resource_id),
    action TEXT NOT NULL,
    env_device_trust TEXT NOT NULL DEFAULT 'medium' CHECK (env_device_trust IN ('high', 'medium', 'low')),
    env_network_zone TEXT NOT NULL DEFAULT 'internal' CHECK (env_network_zone IN ('internal', 'vpn', 'external')),
    env_hour INT NOT NULL CHECK (env_hour BETWEEN 0 AND 23),
    env_ip_address INET,
    env_threat_level TEXT NOT NULL DEFAULT 'normal' CHECK (env_threat_level IN ('normal', 'elevated', 'critical'))
);

-- 2.9 Bảng quyết định truy cập
CREATE TABLE access_decisions (
    decision_id BIGSERIAL PRIMARY KEY,
    request_id BIGINT NOT NULL REFERENCES access_requests(request_id),
    decision_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    decision TEXT NOT NULL CHECK (decision IN ('permit', 'deny')),
    reason TEXT NOT NULL,
    matched_policy_id INT REFERENCES policies(policy_id),
    evaluation_time_ms INT,
    is_break_glass BOOLEAN NOT NULL DEFAULT FALSE
);

-- 2.10 Bảng nhật ký kiểm toán (append-only)
CREATE TABLE audit_logs (
    log_id BIGSERIAL PRIMARY KEY,
    log_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    event_type TEXT NOT NULL CHECK (event_type IN (
        'ACCESS_REQUEST', 'ACCESS_DECISION', 'POLICY_CHANGE',
        'USER_CHANGE', 'BREAK_GLASS', 'ANOMALY_DETECTED'
    )),
    actor_id INT,
    target_table TEXT,
    target_id TEXT,
    action TEXT NOT NULL,
    old_value JSONB,
    new_value JSONB,
    trace_id UUID,
    ip_address INET
);

-- ============================================================================
-- PHẦN 3: TẠO INDEX
-- ============================================================================
CREATE INDEX idx_users_agency ON users(agency_code);
CREATE INDEX idx_users_status ON users(employment_status);
CREATE INDEX idx_user_attrs_user ON user_attributes(user_id);
CREATE INDEX idx_user_attrs_key ON user_attributes(attr_key);
CREATE INDEX idx_user_attrs_valid ON user_attributes(valid_from, valid_to);
CREATE INDEX idx_resources_owner ON resources(owner_agency);
CREATE INDEX idx_resources_type ON resources(resource_type);
CREATE INDEX idx_resources_class ON resources(classification_level);
CREATE INDEX idx_resource_attrs_res ON resource_attributes(resource_id);
CREATE INDEX idx_policies_enabled ON policies(is_enabled, priority DESC);
CREATE INDEX idx_policy_conditions_policy ON policy_conditions(policy_id);
CREATE INDEX idx_access_requests_user ON access_requests(user_id, request_time DESC);
CREATE INDEX idx_access_requests_trace ON access_requests(trace_id);
CREATE INDEX idx_access_decisions_request ON access_decisions(request_id);
CREATE INDEX idx_audit_logs_time ON audit_logs(log_time DESC);
CREATE INDEX idx_audit_logs_event ON audit_logs(event_type);
CREATE INDEX idx_audit_logs_trace ON audit_logs(trace_id);

-- ============================================================================
-- PHẦN 4: TRIGGER BẢO VỆ AUDIT LOG (KHÔNG CHO UPDATE/DELETE)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_prevent_audit_modification()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Audit logs are immutable. UPDATE and DELETE operations are forbidden.';
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_audit_immutable
    BEFORE UPDATE OR DELETE ON audit_logs
    FOR EACH ROW EXECUTE FUNCTION fn_prevent_audit_modification();

-- ============================================================================
-- PHẦN 5: TRIGGER GHI AUDIT KHI THAY ĐỔI USER
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_audit_user_changes()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        INSERT INTO audit_logs (event_type, actor_id, target_table, target_id, action, old_value, new_value)
        VALUES ('USER_CHANGE', NEW.user_id, 'users', NEW.user_id::TEXT, 'UPDATE',
                row_to_json(OLD)::JSONB, row_to_json(NEW)::JSONB);
        NEW.updated_at = NOW();
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_user_audit
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION fn_audit_user_changes();

-- ============================================================================
-- PHẦN 6: TRIGGER GHI AUDIT KHI THAY ĐỔI POLICY
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_audit_policy_changes()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO audit_logs (event_type, target_table, target_id, action, new_value)
        VALUES ('POLICY_CHANGE', 'policies', NEW.policy_id::TEXT, 'INSERT', row_to_json(NEW)::JSONB);
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO audit_logs (event_type, target_table, target_id, action, old_value, new_value)
        VALUES ('POLICY_CHANGE', 'policies', NEW.policy_id::TEXT, 'UPDATE',
                row_to_json(OLD)::JSONB, row_to_json(NEW)::JSONB);
        NEW.updated_at = NOW();
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO audit_logs (event_type, target_table, target_id, action, old_value)
        VALUES ('POLICY_CHANGE', 'policies', OLD.policy_id::TEXT, 'DELETE', row_to_json(OLD)::JSONB);
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$$;

CREATE TRIGGER trg_policy_audit
    BEFORE INSERT OR UPDATE OR DELETE ON policies
    FOR EACH ROW EXECUTE FUNCTION fn_audit_policy_changes();

-- ============================================================================
-- PHẦN 7: HÀM ĐÁNH GIÁ TRUY CẬP ĐỘNG (DYNAMIC POLICY EVALUATION - PDP)
-- ============================================================================
CREATE OR REPLACE FUNCTION evaluate_access_dynamic(
    p_user_id INT,
    p_resource_id INT,
    p_action TEXT,
    p_env_device_trust TEXT DEFAULT 'medium',
    p_env_network_zone TEXT DEFAULT 'internal',
    p_env_hour INT DEFAULT 10,
    p_env_threat_level TEXT DEFAULT 'normal'
)
RETURNS TABLE(decision TEXT, reason TEXT, matched_policy_id INT, evaluation_time_ms INT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_start_time TIMESTAMPTZ;
    v_user users%ROWTYPE;
    v_resource resources%ROWTYPE;
    v_policy RECORD;
    v_condition RECORD;
    v_all_conditions_met BOOLEAN;
    v_actual_value TEXT;
    v_compare_int INT;
    v_actual_int INT;
    v_deny_policy_id INT := NULL;
    v_deny_reason TEXT := NULL;
    v_permit_policy_id INT := NULL;
    v_permit_reason TEXT := NULL;
    v_user_cross_agency TEXT;
    v_user_break_glass TEXT;
    v_elapsed_ms INT;
BEGIN
    v_start_time := clock_timestamp();

    -- Kiểm tra user tồn tại
    SELECT * INTO v_user FROM users WHERE user_id = p_user_id;
    IF NOT FOUND THEN
        v_elapsed_ms := EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start_time)::INT;
        RETURN QUERY SELECT 'deny'::TEXT, 'User not found'::TEXT, NULL::INT, v_elapsed_ms;
        RETURN;
    END IF;

    -- Kiểm tra resource tồn tại
    SELECT * INTO v_resource FROM resources WHERE resource_id = p_resource_id;
    IF NOT FOUND THEN
        v_elapsed_ms := EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start_time)::INT;
        RETURN QUERY SELECT 'deny'::TEXT, 'Resource not found'::TEXT, NULL::INT, v_elapsed_ms;
        RETURN;
    END IF;

    -- Lấy thuộc tính mở rộng (PIP)
    SELECT attr_value INTO v_user_cross_agency
    FROM user_attributes
    WHERE user_id = p_user_id AND attr_key = 'cross_agency_grant'
      AND valid_from <= NOW() AND (valid_to IS NULL OR valid_to > NOW())
    ORDER BY valid_from DESC LIMIT 1;

    SELECT attr_value INTO v_user_break_glass
    FROM user_attributes
    WHERE user_id = p_user_id AND attr_key = 'break_glass_authorized'
      AND valid_from <= NOW() AND (valid_to IS NULL OR valid_to > NOW())
    ORDER BY valid_from DESC LIMIT 1;

    -- Duyệt tất cả policies đang enabled, theo priority giảm dần
    FOR v_policy IN
        SELECT p.policy_id, p.policy_name, p.effect, p.priority, p.target_resource_type, p.target_action
        FROM policies p
        WHERE p.is_enabled = TRUE
        ORDER BY p.priority DESC
    LOOP
        -- Kiểm tra target match
        IF v_policy.target_resource_type <> '*' AND v_policy.target_resource_type <> v_resource.resource_type THEN
            CONTINUE;
        END IF;
        IF v_policy.target_action <> '*' AND v_policy.target_action <> p_action THEN
            CONTINUE;
        END IF;

        -- Kiểm tra tất cả conditions (AND logic)
        v_all_conditions_met := TRUE;

        FOR v_condition IN
            SELECT * FROM policy_conditions WHERE policy_id = v_policy.policy_id
        LOOP
            -- Xác định giá trị thực tế dựa trên attribute_type
            v_actual_value := NULL;

            IF v_condition.attribute_type = 'subject' THEN
                CASE v_condition.attribute_key
                    WHEN 'employment_status' THEN v_actual_value := v_user.employment_status;
                    WHEN 'clearance_level' THEN v_actual_value := v_user.clearance_level::TEXT;
                    WHEN 'agency_code' THEN v_actual_value := v_user.agency_code;
                    WHEN 'cross_agency_grant' THEN v_actual_value := COALESCE(v_user_cross_agency, 'false');
                    WHEN 'break_glass_authorized' THEN v_actual_value := COALESCE(v_user_break_glass, 'false');
                    ELSE
                        SELECT ua.attr_value INTO v_actual_value
                        FROM user_attributes ua
                        WHERE ua.user_id = p_user_id AND ua.attr_key = v_condition.attribute_key
                          AND ua.valid_from <= NOW() AND (ua.valid_to IS NULL OR ua.valid_to > NOW())
                        ORDER BY ua.valid_from DESC LIMIT 1;
                END CASE;

            ELSIF v_condition.attribute_type = 'resource' THEN
                CASE v_condition.attribute_key
                    WHEN 'classification_level' THEN v_actual_value := v_resource.classification_level::TEXT;
                    WHEN 'owner_agency' THEN v_actual_value := v_resource.owner_agency;
                    WHEN 'resource_type' THEN v_actual_value := v_resource.resource_type;
                    WHEN 'record_status' THEN v_actual_value := v_resource.record_status;
                    WHEN 'managing_region' THEN v_actual_value := v_resource.managing_region;
                    ELSE
                        SELECT ra.attr_value INTO v_actual_value
                        FROM resource_attributes ra
                        WHERE ra.resource_id = p_resource_id AND ra.attr_key = v_condition.attribute_key
                        LIMIT 1;
                END CASE;

            ELSIF v_condition.attribute_type = 'environment' THEN
                CASE v_condition.attribute_key
                    WHEN 'device_trust' THEN v_actual_value := p_env_device_trust;
                    WHEN 'network_zone' THEN v_actual_value := p_env_network_zone;
                    WHEN 'hour' THEN v_actual_value := p_env_hour::TEXT;
                    WHEN 'threat_level' THEN v_actual_value := p_env_threat_level;
                END CASE;

            ELSIF v_condition.attribute_type = 'action' THEN
                IF v_condition.attribute_key = 'action' THEN
                    v_actual_value := p_action;
                END IF;
            END IF;

            -- So sánh giá trị
            IF v_actual_value IS NULL THEN
                v_all_conditions_met := FALSE;
                EXIT;
            END IF;

            -- Toán tử so sánh chuỗi và đặc biệt
            -- Đối với subject.clearance_level >= resource.classification_level,
            -- compare_value = 'resource.classification_level' sẽ được thay thế động
            DECLARE
                v_compare TEXT := v_condition.compare_value;
            BEGIN
                -- Xử lý tham chiếu chéo: resource.xxx hoặc subject.xxx
                IF v_compare LIKE 'resource.%' THEN
                    CASE SPLIT_PART(v_compare, '.', 2)
                        WHEN 'classification_level' THEN v_compare := v_resource.classification_level::TEXT;
                        WHEN 'owner_agency' THEN v_compare := v_resource.owner_agency;
                        ELSE v_compare := v_condition.compare_value;
                    END CASE;
                ELSIF v_compare LIKE 'subject.%' THEN
                    CASE SPLIT_PART(v_compare, '.', 2)
                        WHEN 'agency_code' THEN v_compare := v_user.agency_code;
                        WHEN 'clearance_level' THEN v_compare := v_user.clearance_level::TEXT;
                        ELSE v_compare := v_condition.compare_value;
                    END CASE;
                END IF;

                IF v_condition.value_type = 'int' THEN
                    v_actual_int := v_actual_value::INT;
                    v_compare_int := v_compare::INT;
                    CASE v_condition.operator
                        WHEN 'eq' THEN IF v_actual_int <> v_compare_int THEN v_all_conditions_met := FALSE; END IF;
                        WHEN 'neq' THEN IF v_actual_int = v_compare_int THEN v_all_conditions_met := FALSE; END IF;
                        WHEN 'gt' THEN IF v_actual_int <= v_compare_int THEN v_all_conditions_met := FALSE; END IF;
                        WHEN 'gte' THEN IF v_actual_int < v_compare_int THEN v_all_conditions_met := FALSE; END IF;
                        WHEN 'lt' THEN IF v_actual_int >= v_compare_int THEN v_all_conditions_met := FALSE; END IF;
                        WHEN 'lte' THEN IF v_actual_int > v_compare_int THEN v_all_conditions_met := FALSE; END IF;
                        ELSE v_all_conditions_met := FALSE;
                    END CASE;
                ELSIF v_condition.value_type = 'list' THEN
                    CASE v_condition.operator
                        WHEN 'in' THEN
                            IF v_actual_value NOT IN (SELECT unnest(string_to_array(v_compare, ','))) THEN
                                v_all_conditions_met := FALSE;
                            END IF;
                        WHEN 'not_in' THEN
                            IF v_actual_value IN (SELECT unnest(string_to_array(v_compare, ','))) THEN
                                v_all_conditions_met := FALSE;
                            END IF;
                        ELSE v_all_conditions_met := FALSE;
                    END CASE;
                ELSE -- text, boolean
                    CASE v_condition.operator
                        WHEN 'eq' THEN IF v_actual_value <> v_compare THEN v_all_conditions_met := FALSE; END IF;
                        WHEN 'neq' THEN IF v_actual_value = v_compare THEN v_all_conditions_met := FALSE; END IF;
                        ELSE v_all_conditions_met := FALSE;
                    END CASE;
                END IF;
            END;

            IF NOT v_all_conditions_met THEN EXIT; END IF;
        END LOOP;

        -- Nếu tất cả conditions thỏa mãn → policy matched
        IF v_all_conditions_met THEN
            IF v_policy.effect = 'deny' AND v_deny_policy_id IS NULL THEN
                v_deny_policy_id := v_policy.policy_id;
                v_deny_reason := 'Matched DENY policy: ' || v_policy.policy_name;
            ELSIF v_policy.effect = 'permit' AND v_permit_policy_id IS NULL THEN
                v_permit_policy_id := v_policy.policy_id;
                v_permit_reason := 'Matched PERMIT policy: ' || v_policy.policy_name;
            END IF;
        END IF;
    END LOOP;

    v_elapsed_ms := EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start_time)::INT;

    -- Deny-overrides strategy
    IF v_deny_policy_id IS NOT NULL THEN
        RETURN QUERY SELECT 'deny'::TEXT, v_deny_reason, v_deny_policy_id, v_elapsed_ms;
    ELSIF v_permit_policy_id IS NOT NULL THEN
        RETURN QUERY SELECT 'permit'::TEXT, v_permit_reason, v_permit_policy_id, v_elapsed_ms;
    ELSE
        RETURN QUERY SELECT 'deny'::TEXT, 'Default deny: no matching permit policy'::TEXT, NULL::INT, v_elapsed_ms;
    END IF;
END;
$$;

-- ============================================================================
-- PHẦN 8: HÀM REQUEST_ACCESS (PEP - GHI REQUEST + GỌI PDP + GHI DECISION + LOG)
-- ============================================================================
CREATE OR REPLACE FUNCTION request_access(
    p_user_id INT,
    p_resource_id INT,
    p_action TEXT,
    p_env_device_trust TEXT DEFAULT 'medium',
    p_env_network_zone TEXT DEFAULT 'internal',
    p_env_hour INT DEFAULT 10,
    p_env_ip_address INET DEFAULT NULL,
    p_env_threat_level TEXT DEFAULT 'normal'
)
RETURNS TABLE(request_id BIGINT, trace_id UUID, decision TEXT, reason TEXT, matched_policy_id INT, evaluation_time_ms INT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_request_id BIGINT;
    v_trace_id UUID;
    v_decision TEXT;
    v_reason TEXT;
    v_policy_id INT;
    v_eval_ms INT;
    v_is_break_glass BOOLEAN := FALSE;
BEGIN
    -- Ghi access request
    INSERT INTO access_requests (user_id, resource_id, action, env_device_trust, env_network_zone, env_hour, env_ip_address, env_threat_level)
    VALUES (p_user_id, p_resource_id, p_action, p_env_device_trust, p_env_network_zone, p_env_hour, p_env_ip_address, p_env_threat_level)
    RETURNING access_requests.request_id, access_requests.trace_id INTO v_request_id, v_trace_id;

    -- Gọi PDP đánh giá
    SELECT e.decision, e.reason, e.matched_policy_id, e.evaluation_time_ms
    INTO v_decision, v_reason, v_policy_id, v_eval_ms
    FROM evaluate_access_dynamic(p_user_id, p_resource_id, p_action, p_env_device_trust, p_env_network_zone, p_env_hour, p_env_threat_level) e;

    -- Kiểm tra break-glass
    IF v_policy_id IS NOT NULL THEN
        SELECT EXISTS(
            SELECT 1 FROM policies WHERE policy_id = v_policy_id AND policy_name ILIKE '%break%glass%'
        ) INTO v_is_break_glass;
    END IF;

    -- Ghi access decision
    INSERT INTO access_decisions (request_id, decision, reason, matched_policy_id, evaluation_time_ms, is_break_glass)
    VALUES (v_request_id, v_decision, v_reason, v_policy_id, v_eval_ms, v_is_break_glass);

    -- Ghi audit log
    INSERT INTO audit_logs (event_type, actor_id, target_table, target_id, action, new_value, trace_id, ip_address)
    VALUES (
        CASE WHEN v_is_break_glass THEN 'BREAK_GLASS' ELSE 'ACCESS_REQUEST' END,
        p_user_id,
        'resources',
        p_resource_id::TEXT,
        p_action,
        jsonb_build_object(
            'decision', v_decision,
            'reason', v_reason,
            'policy_id', v_policy_id,
            'device_trust', p_env_device_trust,
            'network_zone', p_env_network_zone,
            'hour', p_env_hour,
            'threat_level', p_env_threat_level,
            'eval_ms', v_eval_ms
        ),
        v_trace_id,
        p_env_ip_address
    );

    RETURN QUERY SELECT v_request_id, v_trace_id, v_decision, v_reason, v_policy_id, v_eval_ms;
END;
$$;

-- ============================================================================
-- PHẦN 9: NẠP DỮ LIỆU MẪU
-- ============================================================================

-- 9.1 Cơ quan
INSERT INTO agencies (agency_code, agency_name, agency_type, region) VALUES
('MOH',  'Bo Y te',                    'ministry', 'national'),
('MPS',  'Bo Cong an',                 'ministry', 'national'),
('MOJ',  'Bo Tu phap',                 'ministry', 'national'),
('MOF',  'Bo Tai chinh',               'ministry', 'national'),
('MOD',  'Bo Quoc phong',              'ministry', 'national'),
('MOFA', 'Bo Ngoai giao',              'ministry', 'national'),
('HCMC', 'So Y te TP.HCM',            'provincial', 'south'),
('HN',   'So Cong an Ha Noi',          'provincial', 'north');

-- 9.2 Người dùng
INSERT INTO users (full_name, email, agency_code, clearance_level, employment_status, position, department) VALUES
('Nguyen Van An',    'an.nguyen@moh.gov.vn',   'MOH',  4, 'active',    'Chuyen vien chinh', 'Phong Ho so'),
('Tran Thi Binh',    'binh.tran@moj.gov.vn',   'MOJ',  5, 'active',    'Pho Vu truong',     'Vu Tu phap'),
('Le Van Cuong',     'cuong.le@moh.gov.vn',    'MOH',  3, 'inactive',  'Chuyen vien',       'Phong Ho so'),
('Pham Thi Dao',     'dao.pham@mps.gov.vn',    'MPS',  2, 'active',    'Chuyen vien',       'Phong Nghiep vu'),
('Hoang Van Em',     'em.hoang@mps.gov.vn',    'MPS',  5, 'active',    'Truong phong',      'Phong Dieu tra'),
('Vo Thi Phuong',    'phuong.vo@mof.gov.vn',   'MOF',  3, 'active',    'Kiem toan vien',    'Phong Kiem toan'),
('Dang Van Giap',    'giap.dang@mod.gov.vn',   'MOD',  5, 'active',    'Quan nhan cap cao', 'Phong Tac chien'),
('Ngo Thi Huong',    'huong.ngo@mofa.gov.vn',  'MOFA', 4, 'suspended', 'Tham tan',          'Phong Hop tac');

-- 9.3 Thuộc tính mở rộng người dùng
INSERT INTO user_attributes (user_id, attr_key, attr_value, valid_from, valid_to) VALUES
-- Tran Thi Binh có quyền liên ngành (còn hiệu lực)
(2, 'cross_agency_grant', 'true', '2026-01-01', '2026-12-31'),
-- Hoang Van Em có quyền break-glass
(5, 'break_glass_authorized', 'true', '2026-01-01', NULL),
-- Nguyen Van An có chứng chỉ bảo mật
(1, 'security_certificate', 'CISSP', '2025-06-01', '2028-06-01'),
-- Le Van Cuong quyền liên ngành hết hạn
(3, 'cross_agency_grant', 'true', '2024-01-01', '2025-06-01'),
-- Vo Thi Phuong có quyền xem audit log
(6, 'audit_viewer', 'true', '2026-01-01', NULL);

-- 9.4 Tài nguyên
INSERT INTO resources (resource_name, resource_type, owner_agency, classification_level, managing_region, record_status) VALUES
('Ho so y te quoc gia #1001',              'medical',        'MOH',  3, 'national', 'active'),
('Ho so dieu tra hinh su #2001',           'judicial',       'MPS',  5, 'national', 'under_investigation'),
('Ho so hanh chinh lien nganh #3001',      'administrative', 'MOJ',  2, 'national', 'active'),
('Ho so thue doanh nghiep #4001',          'financial',      'MOF',  3, 'national', 'active'),
('Ho so bi mat quoc phong #5001',          'military',       'MOD',  5, 'national', 'active'),
('Cong ham ngoai giao #6001',              'diplomatic',     'MOFA', 4, 'national', 'active'),
('Ho so benh an TP.HCM #7001',            'medical',        'MOH',  3, 'south',    'active'),
('Ho so dan cu quoc gia #8001',            'civil',          'MPS',  3, 'national', 'active'),
('Bao cao tai chinh mat #9001',            'financial',      'MOF',  4, 'national', 'active'),
('Ho so toi mat an ninh #10001',           'military',       'MOD',  5, 'national', 'active');

-- 9.5 Thuộc tính mở rộng tài nguyên
INSERT INTO resource_attributes (resource_id, attr_key, attr_value) VALUES
(1, 'data_owner_contact', 'dr.nguyen@moh.gov.vn'),
(2, 'case_number', 'CA-2026-00123'),
(5, 'security_compartment', 'DELTA'),
(6, 'diplomatic_level', 'bilateral');

-- ============================================================================
-- PHẦN 10: NẠP CHÍNH SÁCH VÀ ĐIỀU KIỆN
-- ============================================================================

-- P1: Deny - Người dùng không active
INSERT INTO policies (policy_name, description, effect, priority, target_resource_type, target_action)
VALUES ('P1: Deny inactive user', 'Tu choi truy cap neu nguoi dung khong active', 'deny', 100, '*', '*');
INSERT INTO policy_conditions (policy_id, attribute_type, attribute_key, operator, compare_value, value_type)
VALUES (1, 'subject', 'employment_status', 'neq', 'active', 'text');

-- P2: Deny - Thiết bị không tin cậy
INSERT INTO policies (policy_name, description, effect, priority, target_resource_type, target_action)
VALUES ('P2: Deny low-trust device', 'Tu choi truy cap tu thiet bi khong tin cay', 'deny', 95, '*', '*');
INSERT INTO policy_conditions (policy_id, attribute_type, attribute_key, operator, compare_value, value_type)
VALUES (2, 'environment', 'device_trust', 'eq', 'low', 'text');

-- P3: Deny - External network + dữ liệu tối mật (classification >= 4)
INSERT INTO policies (policy_name, description, effect, priority, target_resource_type, target_action)
VALUES ('P3: Deny external access to top-secret', 'Tu choi truy cap tu mang ngoai voi du lieu toi mat', 'deny', 90, '*', '*');
INSERT INTO policy_conditions (policy_id, attribute_type, attribute_key, operator, compare_value, value_type) VALUES
(3, 'environment', 'network_zone', 'eq', 'external', 'text'),
(3, 'resource', 'classification_level', 'gte', '4', 'int');

-- P4: Deny - Ngoài giờ hành chính (hour < 7)
INSERT INTO policies (policy_name, description, effect, priority, target_resource_type, target_action)
VALUES ('P4a: Deny before office hours', 'Tu choi truy cap truoc 7h', 'deny', 85, '*', '*');
INSERT INTO policy_conditions (policy_id, attribute_type, attribute_key, operator, compare_value, value_type)
VALUES (4, 'environment', 'hour', 'lt', '7', 'int');

-- P4b: Deny - Ngoài giờ hành chính (hour > 19)
INSERT INTO policies (policy_name, description, effect, priority, target_resource_type, target_action)
VALUES ('P4b: Deny after office hours', 'Tu choi truy cap sau 19h', 'deny', 84, '*', '*');
INSERT INTO policy_conditions (policy_id, attribute_type, attribute_key, operator, compare_value, value_type)
VALUES (5, 'environment', 'hour', 'gt', '19', 'int');

-- P5: Deny - Mức đe dọa nghiêm trọng + dữ liệu mật
INSERT INTO policies (policy_name, description, effect, priority, target_resource_type, target_action)
VALUES ('P5: Deny on critical threat for classified data', 'Tu choi khi muc de doa nghiem trong', 'deny', 80, '*', '*');
INSERT INTO policy_conditions (policy_id, attribute_type, attribute_key, operator, compare_value, value_type) VALUES
(6, 'environment', 'threat_level', 'eq', 'critical', 'text'),
(6, 'resource', 'classification_level', 'gte', '3', 'int');

-- P6: Permit - Cùng cơ quan + đủ cấp + hành động read/update
INSERT INTO policies (policy_name, description, effect, priority, target_resource_type, target_action)
VALUES ('P6: Permit same agency with clearance', 'Cho phep truy cap cung co quan du cap', 'permit', 50, '*', '*');
INSERT INTO policy_conditions (policy_id, attribute_type, attribute_key, operator, compare_value, value_type) VALUES
(7, 'subject', 'clearance_level', 'gte', 'resource.classification_level', 'int'),
(7, 'subject', 'agency_code', 'eq', 'resource.owner_agency', 'text'),
(7, 'action', 'action', 'in', 'read,update', 'list');

-- P7: Permit - Liên ngành có cross_agency_grant + đủ cấp + read only
INSERT INTO policies (policy_name, description, effect, priority, target_resource_type, target_action)
VALUES ('P7: Permit cross-agency with grant', 'Cho phep truy cap lien nganh co cap quyen', 'permit', 45, '*', 'read');
INSERT INTO policy_conditions (policy_id, attribute_type, attribute_key, operator, compare_value, value_type) VALUES
(8, 'subject', 'clearance_level', 'gte', 'resource.classification_level', 'int'),
(8, 'subject', 'cross_agency_grant', 'eq', 'true', 'text');

-- P8: Permit - Break-glass khẩn cấp
INSERT INTO policies (policy_name, description, effect, priority, target_resource_type, target_action)
VALUES ('P8: Break-glass emergency access', 'Truy cap khan cap co giam sat dac biet', 'permit', 30, '*', 'read');
INSERT INTO policy_conditions (policy_id, attribute_type, attribute_key, operator, compare_value, value_type)
VALUES (9, 'subject', 'break_glass_authorized', 'eq', 'true', 'text');

-- ============================================================================
-- PHẦN 9B: DỮ LIỆU MẪU MỞ RỘNG (~1000 RECORDS)
-- ============================================================================

-- 9B.1 Thêm cơ quan (tổng 14 cơ quan)
INSERT INTO agencies (agency_code, agency_name, agency_type, region) VALUES
('MOST', 'Bo Khoa hoc Cong nghe',     'ministry',    'national'),
('MOET', 'Bo Giao duc Dao tao',       'ministry',    'national'),
('DN',   'So Y te Da Nang',           'provincial',  'central'),
('HP',   'So Cong an Hai Phong',      'provincial',  'north'),
('BG',   'So Tu phap Bac Giang',      'provincial',  'north'),
('CT',   'So Tai chinh Can Tho',      'provincial',  'south');

-- 9B.2 Thêm người dùng (thêm 12 → tổng 20)
INSERT INTO users (full_name, email, agency_code, clearance_level, employment_status, position, department) VALUES
('Do Minh Khoa',      'khoa.do@mps.gov.vn',      'MPS',  4, 'active',    'Pho phong',          'Phong An ninh mang'),
('Bui Thi Lan',       'lan.bui@moh.gov.vn',      'MOH',  3, 'active',    'Chuyen vien',        'Phong Benh truyen nhiem'),
('Nguyen Duc Manh',   'manh.nguyen@mod.gov.vn',  'MOD',  4, 'active',    'Trung ta',           'Phong Tinh bao'),
('Tran Van Nhat',     'nhat.tran@mof.gov.vn',    'MOF',  4, 'active',    'Truong phong',       'Phong Thue'),
('Le Thi Oanh',       'oanh.le@mofa.gov.vn',     'MOFA', 3, 'active',    'Chuyen vien',        'Phong Chau A'),
('Phan Quoc Phong',   'phong.phan@most.gov.vn',  'MOST', 3, 'active',    'Nghien cuu vien',    'Vien Cong nghe'),
('Vu Thi Quyen',      'quyen.vu@moet.gov.vn',    'MOET', 2, 'active',    'Chuyen vien',        'Phong Dao tao'),
('Ha Van Rong',       'rong.ha@hcmc.gov.vn',     'HCMC', 3, 'active',    'Bac si truong',      'Khoa Noi'),
('Ly Thi Son',        'son.ly@hn.gov.vn',        'HN',   4, 'active',    'Dieu tra vien',      'Doi CSHS'),
('Cao Minh Tuan',     'tuan.cao@dn.gov.vn',      'DN',   3, 'active',    'Chuyen vien',        'Phong Nghiep vu'),
('Trinh Van Uy',      'uy.trinh@hp.gov.vn',      'HP',   3, 'suspended', 'Chuyen vien',        'Doi Canh sat'),
('Dinh Thi Van',      'van.dinh@bg.gov.vn',      'BG',   2, 'active',    'Thu ky toa',         'Phong Hinh su');

-- 9B.3 Thêm thuộc tính mở rộng cho users mới
INSERT INTO user_attributes (user_id, attr_key, attr_value, valid_from, valid_to) VALUES
(9,  'cross_agency_grant',    'true',   '2026-03-01', '2026-09-30'),
(11, 'cross_agency_grant',    'true',   '2026-01-01', '2026-06-30'),
(17, 'cross_agency_grant',    'true',   '2026-02-01', '2027-02-01'),
(9,  'security_certificate',  'OSCP',   '2025-01-01', '2028-01-01'),
(12, 'security_certificate',  'CEH',    '2025-03-01', '2028-03-01'),
(7,  'break_glass_authorized','true',   '2026-01-01', NULL),
(11, 'security_certificate',  'CISA',   '2025-09-01', '2028-09-01'),
(15, 'audit_viewer',          'true',   '2026-01-01', NULL);

-- 9B.4 Thêm tài nguyên (thêm 40 → tổng 50)
INSERT INTO resources (resource_name, resource_type, owner_agency, classification_level, managing_region, record_status) VALUES
-- Y tế
('Ho so benh an ung thu #1002',         'medical',    'MOH',  3, 'national', 'active'),
('Ho so tiem chung quoc gia #1003',     'medical',    'MOH',  2, 'national', 'active'),
('Ho so dich te hoc #1004',             'medical',    'MOH',  3, 'national', 'active'),
('Ho so benh nhan HIV #1005',           'medical',    'MOH',  4, 'national', 'active'),
('Ho so benh an Da Nang #1006',         'medical',    'MOH',  3, 'central',  'active'),
('Ho so benh an tam than #1007',        'medical',    'MOH',  3, 'national', 'active'),
('Ho so thuoc dac biet #1008',          'medical',    'MOH',  3, 'national', 'active'),
-- Tư pháp/Hình sự
('Ho so vu an tham nhung #2002',        'judicial',   'MPS',  4, 'national', 'under_investigation'),
('Ho so dieu tra ma tuy #2003',         'judicial',   'MPS',  5, 'national', 'under_investigation'),
('Ho so an tich #2004',                 'judicial',   'MPS',  3, 'national', 'active'),
('Ho so giam dinh phap y #2005',        'judicial',   'MPS',  3, 'national', 'active'),
('Ho so vu an kinh te #2006',           'judicial',   'MPS',  4, 'national', 'active'),
('Ho so vu an Hai Phong #2007',         'judicial',   'MPS',  3, 'north',    'under_investigation'),
-- Hành chính
('Ho so cai cach hanh chinh #3002',     'administrative', 'MOJ', 2, 'national', 'active'),
('Ho so phap che #3003',                'administrative', 'MOJ', 2, 'national', 'active'),
('Ho so bo nhiem can bo #3004',         'administrative', 'MOJ', 3, 'national', 'active'),
-- Tài chính
('Ho so thue ca nhan #4002',            'financial',  'MOF',  3, 'national', 'active'),
('Ho so ngan sach nha nuoc #4003',      'financial',  'MOF',  4, 'national', 'active'),
('Ho so chuyen gia ngoai #4004',        'financial',  'MOF',  3, 'national', 'active'),
('Ho so no cong #4005',                 'financial',  'MOF',  4, 'national', 'active'),
('Bao cao quyet toan #4006',            'financial',  'MOF',  3, 'national', 'active'),
-- Quân sự
('Ho so quan nhan cap tuong #5002',     'military',   'MOD',  5, 'national', 'active'),
('Ho so vu khi trang bi #5003',         'military',   'MOD',  5, 'national', 'active'),
('Ho so huan luyen quan su #5004',      'military',   'MOD',  3, 'national', 'active'),
('Ho so quan khu #5005',                'military',   'MOD',  4, 'national', 'active'),
-- Ngoại giao
('Cong ham Trung Quoc #6002',           'diplomatic', 'MOFA', 4, 'national', 'active'),
('Bao cao hop tac My #6003',            'diplomatic', 'MOFA', 4, 'national', 'active'),
('Ho so vien tro ODA #6004',            'diplomatic', 'MOFA', 3, 'national', 'active'),
('Hiep dinh thuong mai #6005',          'diplomatic', 'MOFA', 4, 'national', 'active'),
-- Dân cư
('Ho so CCCD toan quoc #8002',          'civil',      'MPS',  3, 'national', 'active'),
('Ho so ho khau Ha Noi #8003',          'civil',      'MPS',  2, 'north',    'active'),
('Ho so ket hon ly hon #8004',          'civil',      'MOJ',  2, 'national', 'active'),
('Ho so quoc tich #8005',               'civil',      'MOJ',  3, 'national', 'active'),
('Ho so khai sinh toan quoc #8006',     'civil',      'MOJ',  2, 'national', 'active'),
-- Tỉnh
('Ho so y te Bac Giang #9002',          'medical',    'MOH',  2, 'north',    'active'),
('Ho so dieu tra HP #9003',             'judicial',   'MPS',  3, 'north',    'active'),
('Ho so thue Can Tho #9004',            'financial',  'MOF',  3, 'south',    'active'),
('Ho so giao duc MOET #9005',           'administrative', 'MOET', 2, 'national', 'active'),
('Ho so KHCN du an #9006',              'administrative', 'MOST', 2, 'national', 'active'),
('Ho so benh an Hai Phong #9007',       'medical',    'MOH',  3, 'north',    'active');

-- 9B.5 Thêm thuộc tính mở rộng tài nguyên
INSERT INTO resource_attributes (resource_id, attr_key, attr_value) VALUES
(11, 'data_owner_contact', 'yte.national@moh.gov.vn'),
(14, 'data_owner_contact', 'dichteyhoc@moh.gov.vn'),
(15, 'special_handling', 'encrypted_storage'),
(18, 'case_number', 'CA-2026-TN-001'),
(19, 'case_number', 'CA-2026-MT-002'),
(27, 'data_owner_contact', 'thue@mof.gov.vn'),
(30, 'security_compartment', 'ALPHA'),
(31, 'security_compartment', 'BRAVO'),
(36, 'diplomatic_level', 'multilateral'),
(37, 'diplomatic_level', 'bilateral');

COMMIT;

-- ============================================================================
-- PHẦN 9C: SINH DỮ LIỆU TRUY CẬP MẪU (~200 REQUESTS + DECISIONS + AUDIT LOGS)
-- Sử dụng hàm request_access() để tự động sinh request + decision + audit log
-- ============================================================================

-- === Nhóm 1: Truy cập bình thường trong giờ hành chính (PERMIT expected) ===
-- Nguyen Van An (MOH, CL4) đọc các HS y tế MOH
SELECT request_access(1, 1,  'read', 'high',   'internal', 9,  '10.0.0.1'::INET, 'normal');
SELECT request_access(1, 1,  'read', 'high',   'internal', 10, '10.0.0.1'::INET, 'normal');
SELECT request_access(1, 11, 'read', 'high',   'internal', 11, '10.0.0.1'::INET, 'normal');
SELECT request_access(1, 13, 'read', 'high',   'internal', 14, '10.0.0.1'::INET, 'normal');
SELECT request_access(1, 14, 'read', 'high',   'internal', 15, '10.0.0.1'::INET, 'normal');
SELECT request_access(1, 1,  'update','high',  'internal', 10, '10.0.0.1'::INET, 'normal');
SELECT request_access(1, 16, 'read', 'high',   'internal', 8,  '10.0.0.1'::INET, 'normal');
SELECT request_access(1, 17, 'read', 'high',   'internal', 9,  '10.0.0.1'::INET, 'normal');
SELECT request_access(1, 7,  'read', 'high',   'internal', 10, '10.0.0.1'::INET, 'normal');
SELECT request_access(1, 45, 'read', 'high',   'internal', 11, '10.0.0.1'::INET, 'normal');

-- Bui Thi Lan (MOH, CL3) đọc HS y tế
SELECT request_access(10, 1,  'read', 'high', 'internal', 9,  '10.0.1.10'::INET, 'normal');
SELECT request_access(10, 11, 'read', 'high', 'internal', 10, '10.0.1.10'::INET, 'normal');
SELECT request_access(10, 13, 'read', 'high', 'internal', 14, '10.0.1.10'::INET, 'normal');
SELECT request_access(10, 7,  'read', 'high', 'internal', 15, '10.0.1.10'::INET, 'normal');
SELECT request_access(10, 50, 'read', 'high', 'internal', 16, '10.0.1.10'::INET, 'normal');

-- Hoang Van Em (MPS, CL5) đọc HS điều tra MPS
SELECT request_access(5, 2,  'read', 'high', 'internal', 9,  '10.0.2.5'::INET, 'normal');
SELECT request_access(5, 18, 'read', 'high', 'internal', 10, '10.0.2.5'::INET, 'normal');
SELECT request_access(5, 19, 'read', 'high', 'internal', 11, '10.0.2.5'::INET, 'normal');
SELECT request_access(5, 20, 'read', 'high', 'internal', 14, '10.0.2.5'::INET, 'normal');
SELECT request_access(5, 21, 'read', 'high', 'internal', 15, '10.0.2.5'::INET, 'normal');
SELECT request_access(5, 22, 'read', 'high', 'internal', 16, '10.0.2.5'::INET, 'normal');
SELECT request_access(5, 8,  'read', 'high', 'internal', 9,  '10.0.2.5'::INET, 'normal');
SELECT request_access(5, 40, 'read', 'high', 'internal', 10, '10.0.2.5'::INET, 'normal');
SELECT request_access(5, 41, 'read', 'high', 'internal', 11, '10.0.2.5'::INET, 'normal');
SELECT request_access(5, 2,  'update','high', 'internal', 14, '10.0.2.5'::INET, 'normal');

-- Dang Van Giap (MOD, CL5) đọc HS quân sự
SELECT request_access(7, 5,  'read', 'high', 'internal', 8,  '10.0.3.7'::INET, 'normal');
SELECT request_access(7, 10, 'read', 'high', 'internal', 9,  '10.0.3.7'::INET, 'normal');
SELECT request_access(7, 30, 'read', 'high', 'internal', 10, '10.0.3.7'::INET, 'normal');
SELECT request_access(7, 31, 'read', 'high', 'internal', 11, '10.0.3.7'::INET, 'normal');
SELECT request_access(7, 32, 'read', 'high', 'internal', 14, '10.0.3.7'::INET, 'normal');
SELECT request_access(7, 33, 'read', 'high', 'internal', 15, '10.0.3.7'::INET, 'normal');
SELECT request_access(7, 5,  'update','high', 'internal', 16, '10.0.3.7'::INET, 'normal');

-- Tran Van Nhat (MOF, CL4) đọc HS tài chính
SELECT request_access(12, 4,  'read', 'high', 'internal', 9,  '10.0.4.12'::INET, 'normal');
SELECT request_access(12, 27, 'read', 'high', 'internal', 10, '10.0.4.12'::INET, 'normal');
SELECT request_access(12, 28, 'read', 'high', 'internal', 11, '10.0.4.12'::INET, 'normal');
SELECT request_access(12, 29, 'read', 'high', 'internal', 14, '10.0.4.12'::INET, 'normal');
SELECT request_access(12, 30, 'read', 'high', 'internal', 15, '10.0.4.12'::INET, 'normal');
SELECT request_access(12, 47, 'read', 'high', 'internal', 16, '10.0.4.12'::INET, 'normal');
SELECT request_access(12, 4,  'update','high', 'internal', 10, '10.0.4.12'::INET, 'normal');

-- Do Minh Khoa (MPS, CL4) đọc HS MPS
SELECT request_access(9,  8,  'read', 'high', 'internal', 10, '10.0.2.9'::INET, 'normal');
SELECT request_access(9,  20, 'read', 'high', 'internal', 11, '10.0.2.9'::INET, 'normal');
SELECT request_access(9,  21, 'read', 'high', 'internal', 14, '10.0.2.9'::INET, 'normal');
SELECT request_access(9,  40, 'read', 'high', 'internal', 15, '10.0.2.9'::INET, 'normal');
SELECT request_access(9,  46, 'read', 'high', 'internal', 16, '10.0.2.9'::INET, 'normal');

-- Ly Thi Son (HN, CL4 - provincial) đọc HS MPS qua cross_agency_grant
SELECT request_access(17, 8,  'read', 'high',   'vpn', 10, '172.16.1.17'::INET, 'normal');
SELECT request_access(17, 20, 'read', 'high',   'vpn', 11, '172.16.1.17'::INET, 'normal');
SELECT request_access(17, 40, 'read', 'medium', 'vpn', 14, '172.16.1.17'::INET, 'normal');

-- Nguyen Duc Manh (MOD, CL4) đọc HS quân sự CL3-4
SELECT request_access(11, 32, 'read', 'high', 'internal', 10, '10.0.3.11'::INET, 'normal');
SELECT request_access(11, 33, 'read', 'high', 'internal', 11, '10.0.3.11'::INET, 'normal');
SELECT request_access(11, 5,  'read', 'high', 'internal', 14, '10.0.3.11'::INET, 'normal');

-- Ha Van Rong (HCMC, CL3) đọc HS y tế tỉnh
SELECT request_access(16, 7,  'read', 'high', 'internal', 9,  '10.0.5.16'::INET, 'normal');
SELECT request_access(16, 1,  'read', 'high', 'internal', 10, '10.0.5.16'::INET, 'normal');

-- Ngo Thi Huong (MOFA, CL4) - suspended → luôn DENY
SELECT request_access(8, 6,  'read', 'high', 'internal', 10, '10.0.6.8'::INET, 'normal');
SELECT request_access(8, 34, 'read', 'high', 'internal', 11, '10.0.6.8'::INET, 'normal');
SELECT request_access(8, 35, 'read', 'high', 'internal', 14, '10.0.6.8'::INET, 'normal');
SELECT request_access(8, 36, 'read', 'high', 'internal', 15, '10.0.6.8'::INET, 'normal');
SELECT request_access(8, 37, 'read', 'high', 'internal', 16, '10.0.6.8'::INET, 'normal');

-- === Nhóm 2: Truy cập bị từ chối - thiết bị kém ===
SELECT request_access(1,  1,  'read', 'low', 'internal', 10, '10.0.0.1'::INET,  'normal');
SELECT request_access(5,  2,  'read', 'low', 'internal', 11, '10.0.2.5'::INET,  'normal');
SELECT request_access(7,  5,  'read', 'low', 'internal', 14, '10.0.3.7'::INET,  'normal');
SELECT request_access(12, 4,  'read', 'low', 'internal', 15, '10.0.4.12'::INET, 'normal');
SELECT request_access(10, 1,  'read', 'low', 'internal', 16, '10.0.1.10'::INET, 'normal');
SELECT request_access(9,  8,  'read', 'low', 'internal', 10, '10.0.2.9'::INET,  'normal');
SELECT request_access(16, 7,  'read', 'low', 'internal', 11, '10.0.5.16'::INET, 'normal');

-- === Nhóm 3: Truy cập bị từ chối - ngoài giờ hành chính ===
SELECT request_access(1,  1,  'read', 'high', 'internal', 2,  '10.0.0.1'::INET,  'normal');
SELECT request_access(1,  1,  'read', 'high', 'internal', 3,  '10.0.0.1'::INET,  'normal');
SELECT request_access(5,  2,  'read', 'high', 'internal', 22, '10.0.2.5'::INET,  'normal');
SELECT request_access(5,  18, 'read', 'high', 'internal', 23, '10.0.2.5'::INET,  'normal');
SELECT request_access(7,  5,  'read', 'high', 'internal', 0,  '10.0.3.7'::INET,  'normal');
SELECT request_access(7,  10, 'read', 'high', 'internal', 1,  '10.0.3.7'::INET,  'normal');
SELECT request_access(12, 4,  'read', 'high', 'internal', 21, '10.0.4.12'::INET, 'normal');
SELECT request_access(12, 27, 'read', 'high', 'internal', 22, '10.0.4.12'::INET, 'normal');
SELECT request_access(9,  8,  'read', 'high', 'internal', 5,  '10.0.2.9'::INET,  'normal');
SELECT request_access(10, 1,  'read', 'high', 'internal', 23, '10.0.1.10'::INET, 'normal');

-- === Nhóm 4: Truy cập bị từ chối - cấp bảo mật không đủ ===
-- Pham Thi Dao (MPS, CL2) cố truy cập CL3+
SELECT request_access(4, 2,  'read', 'high', 'internal', 10, '10.0.2.4'::INET, 'normal');
SELECT request_access(4, 18, 'read', 'high', 'internal', 11, '10.0.2.4'::INET, 'normal');
SELECT request_access(4, 19, 'read', 'high', 'internal', 14, '10.0.2.4'::INET, 'normal');
SELECT request_access(4, 8,  'read', 'high', 'internal', 15, '10.0.2.4'::INET, 'normal');
SELECT request_access(4, 20, 'read', 'high', 'internal', 16, '10.0.2.4'::INET, 'normal');
SELECT request_access(4, 40, 'read', 'high', 'internal', 10, '10.0.2.4'::INET, 'normal');
-- Vu Thi Quyen (MOET, CL2) cố truy cập CL3+
SELECT request_access(15, 48, 'read', 'high', 'internal', 10, '10.0.7.15'::INET, 'normal');
SELECT request_access(15, 1,  'read', 'high', 'internal', 11, '10.0.7.15'::INET, 'normal');
-- Dinh Thi Van (BG, CL2)
SELECT request_access(20, 42, 'read', 'high', 'internal', 10, '10.0.8.20'::INET, 'normal');

-- === Nhóm 5: Truy cập bị từ chối - external + tối mật ===
SELECT request_access(7,  5,  'read', 'high', 'external', 10, '203.0.113.7'::INET, 'normal');
SELECT request_access(7,  10, 'read', 'high', 'external', 11, '203.0.113.7'::INET, 'normal');
SELECT request_access(7,  33, 'read', 'high', 'external', 14, '203.0.113.7'::INET, 'normal');
SELECT request_access(5,  2,  'read', 'high', 'external', 10, '203.0.113.5'::INET, 'normal');
SELECT request_access(5,  19, 'read', 'high', 'external', 11, '203.0.113.5'::INET, 'normal');
SELECT request_access(2,  6,  'read', 'high', 'external', 14, '203.0.113.2'::INET, 'normal');
SELECT request_access(8,  34, 'read', 'high', 'external', 15, '203.0.113.8'::INET, 'normal');
SELECT request_access(12, 9,  'read', 'high', 'external', 10, '203.0.113.12'::INET,'normal');
SELECT request_access(12, 29, 'read', 'high', 'external', 11, '203.0.113.12'::INET,'normal');

-- === Nhóm 6: Truy cập bị từ chối - mức đe dọa critical ===
SELECT request_access(1,  1,  'read', 'high', 'internal', 10, '10.0.0.1'::INET,  'critical');
SELECT request_access(5,  2,  'read', 'high', 'internal', 11, '10.0.2.5'::INET,  'critical');
SELECT request_access(7,  5,  'read', 'high', 'internal', 14, '10.0.3.7'::INET,  'critical');
SELECT request_access(12, 4,  'read', 'high', 'internal', 15, '10.0.4.12'::INET, 'critical');
SELECT request_access(9,  8,  'read', 'high', 'internal', 10, '10.0.2.9'::INET,  'critical');
SELECT request_access(2,  1,  'read', 'high', 'internal', 11, '10.0.1.2'::INET,  'critical');
SELECT request_access(10, 7,  'read', 'high', 'internal', 14, '10.0.1.10'::INET, 'critical');
SELECT request_access(16, 7,  'read', 'high', 'internal', 15, '10.0.5.16'::INET, 'critical');

-- === Nhóm 7: Truy cập bị từ chối - hành động delete/export ===
SELECT request_access(1,  1,  'delete', 'high', 'internal', 10, '10.0.0.1'::INET,  'normal');
SELECT request_access(5,  2,  'delete', 'high', 'internal', 11, '10.0.2.5'::INET,  'normal');
SELECT request_access(7,  5,  'delete', 'high', 'internal', 14, '10.0.3.7'::INET,  'normal');
SELECT request_access(12, 4,  'export', 'high', 'internal', 15, '10.0.4.12'::INET, 'normal');
SELECT request_access(1,  1,  'export', 'high', 'internal', 10, '10.0.0.1'::INET,  'normal');
SELECT request_access(9,  8,  'export', 'high', 'internal', 11, '10.0.2.9'::INET,  'normal');

-- === Nhóm 8: Truy cập liên ngành hợp lệ (cross_agency_grant + read) ===
-- Tran Thi Binh (MOJ, CL5, cross_agency) đọc HS các bộ khác
SELECT request_access(2, 1,  'read', 'medium', 'vpn',      11, '172.16.0.2'::INET, 'normal');
SELECT request_access(2, 4,  'read', 'medium', 'vpn',      14, '172.16.0.2'::INET, 'normal');
SELECT request_access(2, 8,  'read', 'high',   'internal', 10, '10.0.1.2'::INET,   'normal');
SELECT request_access(2, 18, 'read', 'high',   'internal', 11, '10.0.1.2'::INET,   'normal');
SELECT request_access(2, 27, 'read', 'high',   'internal', 14, '10.0.1.2'::INET,   'normal');
SELECT request_access(2, 32, 'read', 'high',   'internal', 15, '10.0.1.2'::INET,   'normal');
SELECT request_access(2, 6,  'read', 'high',   'internal', 16, '10.0.1.2'::INET,   'normal');
-- Do Minh Khoa (MPS, CL4, cross_agency) đọc HS bộ khác
SELECT request_access(9, 1,  'read', 'high', 'vpn',      10, '172.16.0.9'::INET, 'normal');
SELECT request_access(9, 4,  'read', 'high', 'vpn',      11, '172.16.0.9'::INET, 'normal');
SELECT request_access(9, 6,  'read', 'high', 'internal', 14, '172.16.0.9'::INET, 'normal');
-- Ly Thi Son (HN, CL4, cross_agency)
SELECT request_access(17, 2,  'read', 'high', 'vpn', 10, '172.16.1.17'::INET, 'normal');
SELECT request_access(17, 18, 'read', 'high', 'vpn', 11, '172.16.1.17'::INET, 'normal');

-- === Nhóm 9: Break-glass khẩn cấp ===
-- Hoang Van Em (break_glass authorized)
SELECT request_access(5, 5,  'read', 'high', 'vpn',      2,  '172.16.2.5'::INET, 'normal');
SELECT request_access(5, 10, 'read', 'high', 'vpn',      3,  '172.16.2.5'::INET, 'normal');
SELECT request_access(5, 6,  'read', 'high', 'vpn',      4,  '172.16.2.5'::INET, 'normal');
-- Dang Van Giap (break_glass authorized)
SELECT request_access(7, 2,  'read', 'high', 'vpn',      1,  '172.16.3.7'::INET, 'normal');
SELECT request_access(7, 19, 'read', 'high', 'vpn',      3,  '172.16.3.7'::INET, 'normal');

-- === Nhóm 10: Truy cập VPN bình thường ===
SELECT request_access(1,  1,  'read', 'medium', 'vpn', 10, '172.16.0.1'::INET,  'normal');
SELECT request_access(1,  11, 'read', 'medium', 'vpn', 11, '172.16.0.1'::INET,  'normal');
SELECT request_access(5,  2,  'read', 'medium', 'vpn', 14, '172.16.0.5'::INET,  'normal');
SELECT request_access(7,  32, 'read', 'medium', 'vpn', 15, '172.16.0.7'::INET,  'normal');
SELECT request_access(12, 4,  'read', 'medium', 'vpn', 16, '172.16.0.12'::INET, 'normal');

-- === Nhóm 11: Truy cập inactive user (Le Van Cuong) ===
SELECT request_access(3, 1,  'read', 'high', 'internal', 10, '10.0.0.3'::INET, 'normal');
SELECT request_access(3, 11, 'read', 'high', 'internal', 11, '10.0.0.3'::INET, 'normal');
SELECT request_access(3, 13, 'read', 'high', 'internal', 14, '10.0.0.3'::INET, 'normal');
SELECT request_access(3, 7,  'read', 'high', 'internal', 15, '10.0.0.3'::INET, 'normal');

-- Trinh Van Uy (suspended)
SELECT request_access(19, 46, 'read', 'high', 'internal', 10, '10.0.9.19'::INET, 'normal');
SELECT request_access(19, 23, 'read', 'high', 'internal', 11, '10.0.9.19'::INET, 'normal');
SELECT request_access(19, 8,  'read', 'high', 'internal', 14, '10.0.9.19'::INET, 'normal');

-- === Nhóm 12: Nhiều truy cập bổ sung để tạo dữ liệu phong phú cho views ===
-- Nguyen Van An - thêm nhiều request
SELECT request_access(1, 1,  'read',   'high', 'internal', 8,  '10.0.0.1'::INET, 'normal');
SELECT request_access(1, 1,  'read',   'high', 'internal', 9,  '10.0.0.1'::INET, 'normal');
SELECT request_access(1, 11, 'read',   'high', 'internal', 10, '10.0.0.1'::INET, 'normal');
SELECT request_access(1, 13, 'read',   'high', 'internal', 11, '10.0.0.1'::INET, 'normal');
SELECT request_access(1, 14, 'update', 'high', 'internal', 14, '10.0.0.1'::INET, 'normal');
SELECT request_access(1, 16, 'read',   'high', 'internal', 15, '10.0.0.1'::INET, 'normal');
SELECT request_access(1, 17, 'read',   'high', 'internal', 16, '10.0.0.1'::INET, 'normal');
SELECT request_access(1, 7,  'read',   'high', 'internal', 17, '10.0.0.1'::INET, 'normal');
SELECT request_access(1, 45, 'read',   'high', 'internal', 18, '10.0.0.1'::INET, 'normal');

-- Hoang Van Em - thêm nhiều request
SELECT request_access(5, 2,  'read',   'high', 'internal', 8,  '10.0.2.5'::INET, 'normal');
SELECT request_access(5, 18, 'read',   'high', 'internal', 9,  '10.0.2.5'::INET, 'normal');
SELECT request_access(5, 19, 'update', 'high', 'internal', 10, '10.0.2.5'::INET, 'normal');
SELECT request_access(5, 20, 'read',   'high', 'internal', 11, '10.0.2.5'::INET, 'normal');
SELECT request_access(5, 22, 'read',   'high', 'internal', 14, '10.0.2.5'::INET, 'normal');
SELECT request_access(5, 8,  'read',   'high', 'internal', 15, '10.0.2.5'::INET, 'normal');
SELECT request_access(5, 40, 'read',   'high', 'internal', 16, '10.0.2.5'::INET, 'normal');
SELECT request_access(5, 41, 'read',   'high', 'internal', 17, '10.0.2.5'::INET, 'normal');
SELECT request_access(5, 2,  'read',   'high', 'internal', 18, '10.0.2.5'::INET, 'normal');

-- Tran Thi Binh - thêm nhiều liên ngành
SELECT request_access(2, 11, 'read', 'high', 'internal', 9,  '10.0.1.2'::INET, 'normal');
SELECT request_access(2, 20, 'read', 'high', 'internal', 10, '10.0.1.2'::INET, 'normal');
SELECT request_access(2, 40, 'read', 'high', 'internal', 11, '10.0.1.2'::INET, 'normal');
SELECT request_access(2, 9,  'read', 'high', 'internal', 14, '10.0.1.2'::INET, 'normal');
SELECT request_access(2, 5,  'read', 'high', 'internal', 15, '10.0.1.2'::INET, 'normal');
SELECT request_access(2, 10, 'read', 'high', 'internal', 16, '10.0.1.2'::INET, 'normal');

-- Dang Van Giap - thêm
SELECT request_access(7, 5,  'read',   'high', 'internal', 8,  '10.0.3.7'::INET, 'normal');
SELECT request_access(7, 30, 'read',   'high', 'internal', 9,  '10.0.3.7'::INET, 'normal');
SELECT request_access(7, 31, 'update', 'high', 'internal', 10, '10.0.3.7'::INET, 'normal');
SELECT request_access(7, 32, 'read',   'high', 'internal', 11, '10.0.3.7'::INET, 'normal');
SELECT request_access(7, 33, 'read',   'high', 'internal', 14, '10.0.3.7'::INET, 'normal');

-- Tran Van Nhat - thêm
SELECT request_access(12, 4,  'read', 'high', 'internal', 8,  '10.0.4.12'::INET, 'normal');
SELECT request_access(12, 27, 'read', 'high', 'internal', 9,  '10.0.4.12'::INET, 'normal');
SELECT request_access(12, 28, 'read', 'high', 'internal', 10, '10.0.4.12'::INET, 'normal');
SELECT request_access(12, 29, 'read', 'high', 'internal', 11, '10.0.4.12'::INET, 'normal');
SELECT request_access(12, 47, 'read', 'high', 'internal', 14, '10.0.4.12'::INET, 'normal');

-- Pham Thi Dao (CL2) - thêm nhiều deny bổ sung
SELECT request_access(4, 22, 'read', 'high', 'internal', 10, '10.0.2.4'::INET, 'normal');
SELECT request_access(4, 21, 'read', 'high', 'internal', 11, '10.0.2.4'::INET, 'normal');
SELECT request_access(4, 1,  'read', 'high', 'internal', 14, '10.0.2.4'::INET, 'normal');
SELECT request_access(4, 5,  'read', 'high', 'internal', 15, '10.0.2.4'::INET, 'normal');

-- Vo Thi Phuong (MOF, CL3) 
SELECT request_access(6, 4,  'read', 'high', 'internal', 10, '10.0.4.6'::INET, 'normal');
SELECT request_access(6, 27, 'read', 'high', 'internal', 11, '10.0.4.6'::INET, 'normal');
SELECT request_access(6, 30, 'read', 'high', 'internal', 14, '10.0.4.6'::INET, 'normal');
SELECT request_access(6, 47, 'read', 'high', 'internal', 15, '10.0.4.6'::INET, 'normal');

-- Le Thi Oanh (MOFA, CL3)
SELECT request_access(13, 38, 'read', 'high', 'internal', 10, '10.0.6.13'::INET, 'normal');
SELECT request_access(13, 6,  'read', 'high', 'internal', 11, '10.0.6.13'::INET, 'normal');

-- Phan Quoc Phong (MOST, CL3)
SELECT request_access(14, 49, 'read', 'high', 'internal', 10, '10.0.7.14'::INET, 'normal');
SELECT request_access(14, 48, 'read', 'high', 'internal', 11, '10.0.7.14'::INET, 'normal');

-- Cao Minh Tuan (DN, CL3)
SELECT request_access(18, 16, 'read', 'high', 'internal', 10, '10.0.8.18'::INET, 'normal');
SELECT request_access(18, 50, 'read', 'high', 'internal', 11, '10.0.8.18'::INET, 'normal');

-- === Nhóm 13: Tổ hợp kết hợp nhiều yếu tố bị từ chối ===
-- Low device + ngoài giờ
SELECT request_access(1,  1, 'read', 'low', 'internal', 22, '10.0.0.1'::INET, 'normal');
-- External + critical threat
SELECT request_access(5,  2, 'read', 'high', 'external', 10, '203.0.113.5'::INET, 'critical');
-- Inactive + low device
SELECT request_access(3,  1, 'read', 'low', 'internal', 10, '10.0.0.3'::INET, 'normal');
-- Cross-agency cố update (chỉ cho read)
SELECT request_access(2,  1, 'update','high', 'internal', 10, '10.0.1.2'::INET, 'normal');
SELECT request_access(2,  4, 'update','high', 'internal', 11, '10.0.1.2'::INET, 'normal');

-- ============================================================================
-- PHẦN 11: CHẠY TEST CASES
-- ============================================================================

-- TC01: PERMIT - Cán bộ MOH đọc HS y tế MOH, đủ cấp, thiết bị tin cậy, trong giờ
SELECT 'TC01' AS test_case, * FROM request_access(1, 1, 'read', 'high', 'internal', 10, '10.0.0.1'::INET, 'normal');

-- TC02: DENY - Thiết bị không tin cậy
SELECT 'TC02' AS test_case, * FROM request_access(1, 1, 'read', 'low', 'internal', 10, '10.0.0.1'::INET, 'normal');

-- TC03: DENY - Người dùng inactive
SELECT 'TC03' AS test_case, * FROM request_access(3, 1, 'read', 'high', 'internal', 10, '10.0.0.2'::INET, 'normal');

-- TC04: PERMIT - Liên ngành Tran Thi Binh (MOJ, CL5, cross_agency) đọc HS y tế MOH
SELECT 'TC04' AS test_case, * FROM request_access(2, 1, 'read', 'medium', 'vpn', 11, '172.16.0.5'::INET, 'normal');

-- TC05: DENY - Ngoài giờ hành chính (22h)
SELECT 'TC05' AS test_case, * FROM request_access(1, 1, 'read', 'high', 'internal', 22, '10.0.0.1'::INET, 'normal');

-- TC06: DENY - Cấp bảo mật không đủ (Pham Thi Dao CL2 vs HS điều tra CL5)
SELECT 'TC06' AS test_case, * FROM request_access(4, 2, 'read', 'high', 'internal', 10, '10.0.0.3'::INET, 'normal');

-- TC07: DENY - External network + dữ liệu tối mật (classification=4)
SELECT 'TC07' AS test_case, * FROM request_access(1, 6, 'read', 'high', 'external', 10, '203.0.113.5'::INET, 'normal');

-- TC08: PERMIT - Break-glass (Hoang Van Em đọc HS quốc phòng lúc 2h đêm)
SELECT 'TC08' AS test_case, * FROM request_access(5, 5, 'read', 'high', 'vpn', 14, '10.0.0.5'::INET, 'normal');

-- TC09: DENY - Hành động delete không được phép
SELECT 'TC09' AS test_case, * FROM request_access(1, 1, 'delete', 'high', 'internal', 10, '10.0.0.1'::INET, 'normal');

-- TC10: DENY - Mức đe dọa critical + dữ liệu mật
SELECT 'TC10' AS test_case, * FROM request_access(1, 1, 'read', 'high', 'internal', 10, '10.0.0.1'::INET, 'critical');

-- ============================================================================
-- PHẦN 12: CÁC VIEW BÁO CÁO
-- ============================================================================

-- View: Audit trail chi tiết
CREATE OR REPLACE VIEW v_audit_trail AS
SELECT
    r.request_id,
    r.trace_id,
    r.request_time,
    u.full_name AS user_name,
    u.agency_code,
    u.clearance_level AS user_clearance,
    res.resource_name,
    res.classification_level AS resource_classification,
    res.owner_agency,
    r.action,
    r.env_device_trust,
    r.env_network_zone,
    r.env_hour,
    r.env_threat_level,
    d.decision,
    d.reason,
    d.matched_policy_id,
    d.evaluation_time_ms,
    d.is_break_glass
FROM access_requests r
JOIN users u ON u.user_id = r.user_id
JOIN resources res ON res.resource_id = r.resource_id
JOIN access_decisions d ON d.request_id = r.request_id
ORDER BY r.request_id DESC;

-- View: Thống kê theo user
CREATE OR REPLACE VIEW v_user_access_stats AS
SELECT
    u.user_id,
    u.full_name,
    u.agency_code,
    COUNT(*) AS total_requests,
    COUNT(*) FILTER (WHERE d.decision = 'permit') AS permit_count,
    COUNT(*) FILTER (WHERE d.decision = 'deny') AS deny_count,
    ROUND(100.0 * COUNT(*) FILTER (WHERE d.decision = 'deny') / NULLIF(COUNT(*), 0), 1) AS deny_rate_pct,
    AVG(d.evaluation_time_ms) AS avg_eval_ms
FROM access_requests r
JOIN users u ON u.user_id = r.user_id
JOIN access_decisions d ON d.request_id = r.request_id
GROUP BY u.user_id, u.full_name, u.agency_code
ORDER BY deny_rate_pct DESC;

-- View: Thống kê theo policy
CREATE OR REPLACE VIEW v_policy_hit_stats AS
SELECT
    p.policy_id,
    p.policy_name,
    p.effect,
    p.priority,
    COUNT(d.decision_id) AS hit_count,
    p.is_enabled
FROM policies p
LEFT JOIN access_decisions d ON d.matched_policy_id = p.policy_id
GROUP BY p.policy_id, p.policy_name, p.effect, p.priority, p.is_enabled
ORDER BY hit_count DESC;

-- View: Phát hiện bất thường (user có tỷ lệ deny cao)
CREATE OR REPLACE VIEW v_anomaly_detection AS
SELECT
    u.user_id,
    u.full_name,
    u.agency_code,
    COUNT(*) AS total_requests,
    COUNT(*) FILTER (WHERE d.decision = 'deny') AS deny_count,
    ROUND(100.0 * COUNT(*) FILTER (WHERE d.decision = 'deny') / NULLIF(COUNT(*), 0), 1) AS deny_rate_pct,
    CASE
        WHEN ROUND(100.0 * COUNT(*) FILTER (WHERE d.decision = 'deny') / NULLIF(COUNT(*), 0), 1) > 80 THEN 'HIGH RISK'
        WHEN ROUND(100.0 * COUNT(*) FILTER (WHERE d.decision = 'deny') / NULLIF(COUNT(*), 0), 1) > 50 THEN 'MEDIUM RISK'
        ELSE 'NORMAL'
    END AS risk_level
FROM access_requests r
JOIN users u ON u.user_id = r.user_id
JOIN access_decisions d ON d.request_id = r.request_id
GROUP BY u.user_id, u.full_name, u.agency_code
HAVING COUNT(*) >= 1
ORDER BY deny_rate_pct DESC;

-- Xem kết quả kiểm thử
SELECT '=== AUDIT TRAIL ===' AS section;
SELECT * FROM v_audit_trail;

SELECT '=== USER ACCESS STATS ===' AS section;
SELECT * FROM v_user_access_stats;

SELECT '=== POLICY HIT STATS ===' AS section;
SELECT * FROM v_policy_hit_stats;

SELECT '=== ANOMALY DETECTION ===' AS section;
SELECT * FROM v_anomaly_detection;
