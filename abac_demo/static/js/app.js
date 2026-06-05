/**
 * ABAC Demo — Frontend
 */

// ---------- SVG icons (stroke, 24dp-style) — no emoji ----------
function uiIcon(paths, svgAttrs = '') {
    const inner = paths.map((d) => `<path d="${d}"/>`).join('');
    return `<svg class="ui-icon" xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" ${svgAttrs}>${inner}</svg>`;
}

const Icon = {
    permit: () => uiIcon([
        'M22 11.08V12a10 10 0 1 1-5.93-9.14',
        'm9 11 3 3L22 4',
    ]),
    deny: () => uiIcon([
        'M12 22c5.523 0 10-4.477 10-10S17.523 2 12 2 2 6.477 2 12s4.477 10 10 10',
        'm15 9-6 6',
        'm9 9 6 6',
    ]),
    alert: () => uiIcon([
        'M12 22c5.523 0 10-4.477 10-10S17.523 2 12 2 2 6.477 2 12s4.477 10 10 10',
        'M12 8v4',
        'M12 16h.01',
    ]),
    /** Break-glass — ổ khóa mở (stroke) */
    breakGlass: () =>
        `<svg class="ui-icon ui-icon--sm" xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect width="18" height="11" x="3" y="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 9.9-1"/></svg>`,
};

function escHtml(s) {
    if (s == null || s === '') return '';
    const d = document.createElement('div');
    d.textContent = String(s);
    return d.innerHTML;
}

// ============================================================
// TAB SWITCHING
// ============================================================
document.querySelectorAll('.tab').forEach(tab => {
    tab.addEventListener('click', () => {
        document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
        document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
        tab.classList.add('active');
        document.getElementById('panel-' + tab.dataset.tab).classList.add('active');
        if (tab.dataset.tab === 'data') loadData();
        if (tab.dataset.tab === 'policies') loadPolicies();
        if (tab.dataset.tab === 'audit') { loadAuditLogs(); loadAuditStats(); }
        if (tab.dataset.tab === 'performance') {
            loadPerfStatus();
            loadPerfHistory();
        }
        if (tab.dataset.tab === 'loadtest') {
            loadLtStatus();
            loadLtHistory();
        }
    });
});

// ============================================================
// HELPERS
// ============================================================
const ABAC_ADMIN_SS_KEY = 'abac_admin_token';

const api = async (url, opts = {}) => {
    const headers = opts.headers ? { ...opts.headers } : {};
    const { headers: _, ...rest } = opts;
    const res = await fetch(url, { ...rest, headers });
    const text = await res.text();
    let data = null;
    try {
        data = text ? JSON.parse(text) : null;
    } catch {
        if (res.status === 429) {
            const m = text.match(/<p>([^<]+)<\/p>/i);
            const detail = m ? m[1].trim() : '';
            throw new Error(
                `Quá nhiều yêu cầu (HTTP 429)${detail ? `: ${detail}` : ''}. `
                + 'Đợi hoặc trên VPS: sudo systemctl restart abac-demo (reset bộ đếm).',
            );
        }
        const clip = text.length > 300 ? `${text.slice(0, 300)}…` : text;
        throw new Error(`Phản hồi không phải JSON (HTTP ${res.status}). Đầu tiên nhận được: ${clip}`);
    }
    if (!res.ok) {
        const msg = (data && (data.error || data.message)) || `HTTP ${res.status}`;
        const type = data && data.type ? ` (${data.type})` : '';
        const hint = data && data.hint ? `\n${data.hint}` : '';
        throw new Error(`${msg}${type}${hint}`);
    }
    return data;
};

function clBadge(level) {
    const labels = {1:'Công khai', 2:'Nội bộ', 3:'Mật', 4:'Tối mật', 5:'Tuyệt mật'};
    return `<span class="cl-${level}">${level} - ${labels[level] || level}</span>`;
}

function statusBadge(s) {
    return `<span class="badge badge-${s}">${s}</span>`;
}

function getAdminToken() {
    const ids = ['inp-lt-admin-token', 'inp-perf-admin-token', 'inp-admin-token'];
    for (const id of ids) {
        const el = document.getElementById(id);
        const v = (el?.value || '').trim();
        if (v) return v;
    }
    return (sessionStorage.getItem(ABAC_ADMIN_SS_KEY) || '').trim();
}

function bindAdminTokenInput(id) {
    const el = document.getElementById(id);
    if (!el) return;
    el.value = sessionStorage.getItem(ABAC_ADMIN_SS_KEY) || '';
    el.addEventListener('change', () => {
        const v = el.value.trim();
        if (v) sessionStorage.setItem(ABAC_ADMIN_SS_KEY, v);
        else sessionStorage.removeItem(ABAC_ADMIN_SS_KEY);
        document.querySelectorAll('#inp-admin-token, #inp-perf-admin-token, #inp-lt-admin-token').forEach((inp) => {
            if (inp && inp !== el) inp.value = v;
        });
    });
}

(function initAdminTokenFields() {
    bindAdminTokenInput('inp-admin-token');
    bindAdminTokenInput('inp-perf-admin-token');
    bindAdminTokenInput('inp-lt-admin-token');
})();

const apiAdmin = async (url, opts = {}) => {
    const tok = getAdminToken();
    const headers = { ...(opts.headers || {}) };
    if (tok) headers['X-Abac-Admin-Token'] = tok;
    return api(url, { ...opts, headers });
};

// ============================================================
// PAGINATION STATE (PIP tables)
// ============================================================
let userListPage = 1;
let resourceListPage = 1;

// ============================================================
// LOAD DROPDOWNS (PEP Form) — top of list only (IDs thấp = seed + bulk đầu)
// ============================================================
async function loadDropdowns() {
    const [usersRes, resRes] = await Promise.all([
        api('/api/users?page=1&per_page=200'),
        api('/api/resources?page=1&per_page=200'),
    ]);
    const users = usersRes.items || [];
    const resources = resRes.items || [];
    const su = document.getElementById('sel-user');
    const sr = document.getElementById('sel-resource');
    su.innerHTML = users.map(u =>
        `<option value="${u.user_id}">${escHtml(u.full_name)} (${escHtml(u.agency_code)}, CL${u.clearance_level}, ${escHtml(u.employment_status)})</option>`
    ).join('');
    sr.innerHTML = resources.map(r =>
        `<option value="${r.resource_id}">${escHtml(r.resource_name)} (CL${r.classification_level})</option>`
    ).join('');
}
loadDropdowns();

// ============================================================
// ACCESS CHECK (PEP → PDP)
// ============================================================
async function checkAccess() {
    const uidRaw = (document.getElementById('inp-user-id')?.value || '').trim();
    const ridRaw = (document.getElementById('inp-resource-id')?.value || '').trim();
    const body = {
        user_id: uidRaw || document.getElementById('sel-user').value,
        resource_id: ridRaw || document.getElementById('sel-resource').value,
        action: document.getElementById('sel-action').value,
        device_trust: document.getElementById('sel-device').value,
        network_zone: document.getElementById('sel-network').value,
        hour: document.getElementById('inp-hour').value,
        threat_level: document.getElementById('sel-threat').value,
    };
    document.getElementById('loading').style.display = 'block';
    document.getElementById('result-box').style.display = 'none';

    try {
        const r = await api('/api/access/check', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify(body),
        });

        document.getElementById('loading').style.display = 'none';
        showResult(r);
    } catch (e) {
        document.getElementById('loading').style.display = 'none';
        const box = document.getElementById('result-box');
        const ph = document.getElementById('result-placeholder');
        ph.style.display = 'none';
        box.style.display = 'block';
        box.className = 'result-box result-deny';
        box.replaceChildren();
        const row = document.createElement('h3');
        row.className = 'result-title';
        row.innerHTML = `${Icon.alert()}<span>Lỗi máy chủ hoặc API</span>`;
        const msg = document.createElement('div');
        msg.className = 'result-detail';
        msg.textContent = e.message || String(e);
        box.appendChild(row);
        box.appendChild(msg);
    }
}

function showResult(r) {
    const box = document.getElementById('result-box');
    const ph = document.getElementById('result-placeholder');
    ph.style.display = 'none';
    box.style.display = 'block';
    const isPermit = r.decision === 'permit';
    box.className = `result-box ${isPermit ? 'result-permit' : 'result-deny'}`;
    const titleText = isPermit ? 'PERMIT — Cho phép truy cập' : 'DENY — Từ chối truy cập';
    const icon = isPermit ? Icon.permit() : Icon.deny();
    box.innerHTML = `
        <h3 class="result-title">${icon}<span>${titleText}</span></h3>
        <div class="result-detail"><span>Lý do:</span> ${escHtml(r.reason)}</div>
        <div class="result-detail"><span>Policy ID:</span> ${escHtml(r.matched_policy_id != null ? String(r.matched_policy_id) : '—')}</div>
        <div class="result-detail"><span>Thời gian đánh giá:</span> ${escHtml(r.evaluation_time_ms != null ? String(r.evaluation_time_ms) + ' ms' : '—')}</div>
        <div class="result-detail"><span>Request ID:</span> ${escHtml(r.request_id != null ? String(r.request_id) : '—')}</div>
        <div class="result-detail"><span>Trace ID:</span> <code>${escHtml(r.trace_id != null ? String(r.trace_id) : '—')}</code></div>
    `;
}

// ============================================================
// TEST CASES
// ============================================================
function runTestCase(uid, rid, action, device, network, hour, threat) {
    document.getElementById('sel-user').value = uid;
    document.getElementById('sel-resource').value = rid;
    document.getElementById('sel-action').value = action;
    document.getElementById('sel-device').value = device;
    document.getElementById('sel-network').value = network;
    document.getElementById('inp-hour').value = hour;
    document.getElementById('sel-threat').value = threat;
    checkAccess();
}

// ============================================================
// LOAD USERS & RESOURCES DATA (PIP) — pagination
// ============================================================
function updatePager(kind, data) {
    const total = data.total ?? 0;
    const page = data.page ?? 1;
    const pages = data.pages ?? 1;
    const per = data.per_page ?? 50;
    const metaId = kind === 'users' ? 'pager-users-meta' : 'pager-resources-meta';
    const prevId = kind === 'users' ? 'btn-users-prev' : 'btn-resources-prev';
    const nextId = kind === 'users' ? 'btn-users-next' : 'btn-resources-next';
    const pageInp = kind === 'users' ? 'inp-users-page' : 'inp-resources-page';

    document.getElementById(metaId).textContent =
        `Trang ${page} / ${pages} — hiển thị tối đa ${per} dòng — tổng ${total.toLocaleString('vi-VN')} bản ghi`;

    document.getElementById(prevId).disabled = page <= 1;
    document.getElementById(nextId).disabled = page >= pages;
    document.getElementById(pageInp).value = String(page);
}

async function loadUsersTable() {
    const pp = parseInt(document.getElementById('sel-users-per').value, 10) || 50;
    const q = document.getElementById('inp-users-q').value.trim();
    const qs = new URLSearchParams({ page: String(userListPage), per_page: String(pp) });
    if (q) qs.set('q', q);
    const data = await api(`/api/users?${qs}`);
    if (data.pages && userListPage > data.pages) {
        userListPage = Math.max(1, data.pages);
        return loadUsersTable();
    }
    const users = data.items || [];
    document.querySelector('#tbl-users tbody').innerHTML = users.map(u => {
        const attrs = (typeof u.attributes === 'string' ? JSON.parse(u.attributes) : u.attributes) || [];
        const attrStr = attrs.map(a =>
            `<span class="badge" style="background:var(--primary-light);color:var(--primary);margin:2px;">${escHtml(a.key)}=${escHtml(a.value)}</span>`
        ).join(' ');
        return `<tr>
            <td>${u.user_id}</td>
            <td>${escHtml(u.full_name)}</td>
            <td>${escHtml(u.agency_code)} (${escHtml(u.agency_name)})</td>
            <td>${clBadge(u.clearance_level)}</td>
            <td>${statusBadge(u.employment_status)}</td>
            <td>${escHtml(u.position || '-')}</td>
            <td>${attrStr || '-'}</td>
        </tr>`;
    }).join('');
    updatePager('users', data);
}

async function loadResourcesTable() {
    const pp = parseInt(document.getElementById('sel-resources-per').value, 10) || 50;
    const q = document.getElementById('inp-resources-q').value.trim();
    const qs = new URLSearchParams({ page: String(resourceListPage), per_page: String(pp) });
    if (q) qs.set('q', q);
    const data = await api(`/api/resources?${qs}`);
    if (data.pages && resourceListPage > data.pages) {
        resourceListPage = Math.max(1, data.pages);
        return loadResourcesTable();
    }
    const resources = data.items || [];
    document.querySelector('#tbl-resources tbody').innerHTML = resources.map(r => `<tr>
        <td>${r.resource_id}</td>
        <td>${escHtml(r.resource_name)}</td>
        <td>${escHtml(r.resource_type)}</td>
        <td>${escHtml(r.owner_agency)} (${escHtml(r.agency_name)})</td>
        <td>${clBadge(r.classification_level)}</td>
        <td>${escHtml(r.managing_region || '-')}</td>
        <td>${statusBadge(r.record_status)}</td>
    </tr>`).join('');
    updatePager('resources', data);
}

function reloadUsersPage(page) {
    userListPage = Math.max(1, page);
    loadUsersTable();
}

function changeUsersPage(delta) {
    userListPage = Math.max(1, userListPage + delta);
    loadUsersTable();
}

function gotoUsersPage() {
    const p = parseInt(document.getElementById('inp-users-page').value, 10);
    if (!Number.isFinite(p) || p < 1) return;
    userListPage = p;
    loadUsersTable();
}

function reloadResourcesPage(page) {
    resourceListPage = Math.max(1, page);
    loadResourcesTable();
}

function changeResourcesPage(delta) {
    resourceListPage = Math.max(1, resourceListPage + delta);
    loadResourcesTable();
}

function gotoResourcesPage() {
    const p = parseInt(document.getElementById('inp-resources-page').value, 10);
    if (!Number.isFinite(p) || p < 1) return;
    resourceListPage = p;
    loadResourcesTable();
}

async function loadData() {
    await Promise.all([loadUsersTable(), loadResourcesTable()]);
}

['inp-users-q', 'inp-resources-q'].forEach(id => {
    const el = document.getElementById(id);
    if (!el) return;
    el.addEventListener('keydown', e => {
        if (e.key === 'Enter') {
            if (id === 'inp-users-q') reloadUsersPage(1);
            else reloadResourcesPage(1);
        }
    });
});

// ============================================================
// LOAD POLICIES (PAP)
// ============================================================
async function loadPolicies() {
    const policies = await api('/api/policies');
    document.querySelector('#tbl-policies tbody').innerHTML = policies.map(p => {
        const conds = (typeof p.conditions === 'string' ? JSON.parse(p.conditions) : p.conditions) || [];
        const condStr = conds.map(c =>
            `<div style="font-size:0.8rem;"><b>${escHtml(c.attribute_type)}.${escHtml(c.attribute_key)}</b> ${escHtml(c.operator)} ${escHtml(String(c.compare_value ?? ''))}</div>`
        ).join('');
        return `<tr>
            <td>${p.policy_id}</td>
            <td><b>${escHtml(p.policy_name)}</b><br><span style="font-size:0.8rem;color:var(--gray-500);">${escHtml(p.description || '')}</span></td>
            <td><span class="badge badge-${p.effect}">${p.effect.toUpperCase()}</span></td>
            <td>${p.priority}</td>
            <td>${p.target_resource_type}/${p.target_action}</td>
            <td>${condStr}</td>
            <td>${p.is_enabled ? '<span class="badge badge-active">ON</span>' : '<span class="badge badge-inactive">OFF</span>'}</td>
            <td><button class="btn btn-sm ${p.is_enabled ? 'btn-warning' : 'btn-success'}" onclick="togglePolicy(${p.policy_id})">${p.is_enabled ? 'Tắt' : 'Bật'}</button></td>
        </tr>`;
    }).join('');
}

async function togglePolicy(id) {
    await apiAdmin(`/api/policies/${id}/toggle`, { method: 'PUT' });
    loadPolicies();
}

// ============================================================
// AUDIT LOGS & STATS
// ============================================================
async function loadAuditLogs() {
    const logs = await api('/api/audit/logs?limit=50');
    document.querySelector('#tbl-audit tbody').innerHTML = (logs || []).map(l => {
        const tracePrefix = escHtml((l.trace_id || '').substring(0, 8));
        return `<tr>
        <td>${l.request_id}</td>
        <td>${escHtml(new Date(l.request_time).toLocaleString('vi-VN'))}</td>
        <td style="font-size:0.7rem;">${tracePrefix}${(l.trace_id && l.trace_id.length > 8) ? '…' : ''}</td>
        <td>${escHtml(l.user_name)} (${escHtml(l.agency_code)})</td>
        <td>${escHtml(l.resource_name)}</td>
        <td>${escHtml(l.action)}</td>
        <td>${escHtml(l.env_device_trust)}</td>
        <td>${escHtml(l.env_network_zone)}</td>
        <td>${l.env_hour}h</td>
        <td><span class="badge badge-${l.decision} badge-with-icon">${l.decision.toUpperCase()}${l.is_break_glass ? `<span class="badge-suffix" title="Break-glass">${Icon.breakGlass()}<span class="badge-suffix-text">break-glass</span></span>` : ''}</span></td>
        <td style="font-size:0.8rem;">${escHtml(l.reason)}</td>
        <td>${l.evaluation_time_ms || '-'}ms</td>
    </tr>`;
    }).join('');
}

async function loadAuditStats() {
    const stats = await api('/api/audit/stats');
    const meta = stats.meta || {};
    const metaEl = document.getElementById('audit-anomaly-meta');
    if (metaEl) {
        const days = meta.audit_anomaly_since_days;
        const lim = meta.audit_anomaly_row_limit;
        if (days != null && days > 0 && lim != null) {
            metaEl.textContent =
                `Phạm vi phát hiện: khoảng ${days} ngày gần nhất (theo cấu hình server); tối đa ${lim} dòng.`;
        } else if (lim != null) {
            metaEl.textContent = `Tối đa ${lim} dòng (server không giới hạn thời gian — nếu log rất lớn có thể chậm).`;
        } else {
            metaEl.textContent = '';
        }
    }
    const us = stats.user_stats || [];
    const totalReqs = us.reduce((s, u) => s + (u.total_requests || 0), 0);
    const totalPermit = us.reduce((s, u) => s + (u.permit_count || 0), 0);
    const totalDeny = us.reduce((s, u) => s + (u.deny_count || 0), 0);

    document.getElementById('stat-cards').innerHTML = `
        <div class="stat-card"><div class="value">${totalReqs}</div><div class="label">Tổng yêu cầu</div></div>
        <div class="stat-card"><div class="value" style="color:var(--success)">${totalPermit}</div><div class="label">Cho phép (Permit)</div></div>
        <div class="stat-card"><div class="value" style="color:var(--danger)">${totalDeny}</div><div class="label">Từ chối (Deny)</div></div>
    `;

    const anomalies = stats.anomalies || [];
    document.querySelector('#tbl-anomaly tbody').innerHTML = anomalies.map(a => {
        const riskColor = a.risk_level === 'HIGH RISK' ? 'var(--danger)' : a.risk_level === 'MEDIUM RISK' ? 'var(--warning)' : 'var(--success)';
        return `<tr>
            <td>${a.user_id}</td>
            <td>${escHtml(a.full_name)}</td>
            <td>${escHtml(a.agency_code)}</td>
            <td>${a.total_requests}</td>
            <td>${a.deny_count}</td>
            <td>${a.deny_rate_pct}%</td>
            <td style="color:${riskColor};font-weight:600;">${escHtml(a.risk_level)}</td>
        </tr>`;
    }).join('');
}

// ============================================================
// PERFORMANCE BENCHMARK (3.2.2)
// ============================================================
const PERF_SCENARIO_LABELS = {
    none: 'Không index',
    btree: 'B-Tree',
    btree_partial: 'B-Tree + Partial',
};

let perfPresetsCache = [];
const PERF_RESULTS_SS_KEY = 'abac_perf_last_results';
let perfProgressTimer = null;
let perfProgressActiveBoxId = 'perf-progress';
let ltStatusCache = null;

const PERF_RUN_STEPS = [
    'Kiểm tra quy mô luật và EAV…',
    'Áp dụng kịch bản chỉ mục (DROP/CREATE)…',
    'Lấy cặp user/resource ngẫu nhiên…',
    'Gọi evaluate_access_dynamic()…',
    'Tính trung bình độ trễ từng đợt…',
    'Khôi phục chỉ mục production…',
    'Đóng gói kết quả…',
];

const PERF_SEED_STEPS = [
    'Xóa dữ liệu PERF_BENCH cũ…',
    'INSERT policies benchmark…',
    'INSERT policy_conditions…',
    'INSERT user_attributes (EAV)…',
    'ANALYZE bảng policies / EAV…',
];

function perfSelectedPresetIds() {
    return [...document.querySelectorAll('input[name="perf-preset"]:checked')]
        .map((el) => el.value);
}

function perfSelectedScenarios() {
    return [...document.querySelectorAll('input[name="perf-scenario"]:checked')]
        .map((el) => el.value);
}

function renderPerfPresets(presets) {
    perfPresetsCache = presets || [];
    const box = document.getElementById('perf-preset-list');
    if (!box) return;
    box.innerHTML = presets.map((p) => `
        <label class="perf-preset-item">
            <input type="checkbox" name="perf-preset" value="${escHtml(p.id)}">
            <span><b>${escHtml(p.label)}</b></span>
            <span class="perf-preset-meta">TL: ${p.rules} · EAV: ${p.eav_rows.toLocaleString('vi-VN')}</span>
        </label>
    `).join('');
}

async function loadPerfStatus() {
    const st = await api('/api/performance/status');
    const c = st.counts || {};
    const el = document.getElementById('perf-status');
    const rd = st.readiness || {};
    const sess = rd.session || {};
    if (el) {
        const seedOk = rd.ready_for_seed ? 'OK' : 'THIẾU QUYỀN';
        const runOk = rd.ready_for_run ? 'OK' : 'CHƯA SẴN SÀNG';
        const seedClass = rd.ready_for_seed ? 'perf-ok' : 'perf-bad';
        const runClass = rd.ready_for_run ? 'perf-ok' : 'perf-bad';
        el.innerHTML = `
            <div><b>DB user (config):</b> ${escHtml(rd.configured_db_user || '—')}
            · <b>session:</b> ${escHtml(sess.db_session_user || '—')}</div>
            <div><b>Seed:</b> <span class="${seedClass}">${seedOk}</span>
            · INSERT policies: ${sess.can_insert_policies ? 'yes' : 'no'}
            · audit_logs: ${sess.can_insert_audit ? 'yes' : 'no'}
            · EAV: ${sess.can_insert_eav ? 'yes' : 'no'}</div>
            <div><b>Run benchmark:</b> <span class="${runClass}">${runOk}</span>
            · PDP execute: ${sess.can_execute_pdp ? 'yes' : 'no'}
            · perf_index_functions: ${rd.perf_index_functions_installed ? 'yes' : 'no'}</div>
            <div><b>Luật đang bật:</b> ${Number(c.enabled_policies || 0).toLocaleString('vi-VN')}
            (PERF_BENCH: ${Number(c.bench_policies || 0).toLocaleString('vi-VN')})</div>
            <div><b>EAV:</b> ${Number(c.total_eav || 0).toLocaleString('vi-VN')}
            (PERF_BENCH: ${Number(c.bench_eav || 0).toLocaleString('vi-VN')})</div>
            <div><b>Users / Resources:</b> ${Number(c.users || 0).toLocaleString('vi-VN')} /
            ${Number(c.resources || 0).toLocaleString('vi-VN')}</div>
            <div><b>Index PDP:</b> ${(st.active_perf_indexes || []).join(', ') || '—'}</div>
            <div><b>Batch PDP (DB):</b> ${st.perf_eval_batch_available ? 'yes' : 'no — chạy perf_eval_batch.sql'}</div>
            ${!rd.ready_for_seed ? '<div class="perf-bad">Chạy trên VPS: sudo -u postgres psql -d abac_demo -f scripts/perf_grants_abac_user.sql và perf_index_functions.sql</div>' : ''}
        `;
    }
    const defs = st.defaults || {};
    const reqInp = document.getElementById('inp-perf-requests');
    const batInp = document.getElementById('inp-perf-batches');
    if (reqInp && !reqInp.dataset.touched) reqInp.value = defs.requests_per_batch ?? 1000;
    if (batInp && !batInp.dataset.touched) batInp.value = defs.batches ?? 5;
    const rh = document.getElementById('perf-req-hint');
    const bh = document.getElementById('perf-batch-hint');
    if (rh) rh.textContent = reqInp?.value || '1000';
    if (bh) bh.textContent = batInp?.value || '5';
    renderPerfPresets(st.presets || []);
    restorePerfResultsFromStorage();
    const histHint = document.getElementById('perf-history-hint');
    if (histHint) {
        histHint.textContent = st.history_table_ready
            ? 'Mỗi lần chạy benchmark được lưu tự động — chọn ≥2 dòng để so sánh.'
            : 'Chưa có bảng lịch sử — chạy scripts/perf_benchmark_history.sql trên PostgreSQL.';
    }
}

document.querySelectorAll('#inp-perf-requests, #inp-perf-batches').forEach((el) => {
    if (!el) return;
    el.addEventListener('input', () => {
        el.dataset.touched = '1';
        const rh = document.getElementById('perf-req-hint');
        const bh = document.getElementById('perf-batch-hint');
        if (el.id === 'inp-perf-requests' && rh) rh.textContent = el.value;
        if (el.id === 'inp-perf-batches' && bh) bh.textContent = el.value;
    });
});

function perfFormatDuration(sec) {
    sec = Math.max(0, Math.ceil(sec));
    const h = Math.floor(sec / 3600);
    const m = Math.floor((sec % 3600) / 60);
    const s = sec % 60;
    if (h > 0) return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
    if (m > 0) return `${m}:${String(s).padStart(2, '0')}`;
    return `${s} giây`;
}

function perfEstimateSeedSeconds(preset) {
    if (!preset) return 30;
    return Math.max(20, Math.round(preset.rules / 15 + preset.eav_rows / 6000 + 15));
}

function updatePerfProgressStep(message, boxId) {
    const stepEl = document.getElementById(`${boxId || perfProgressActiveBoxId}-step`);
    if (stepEl) stepEl.textContent = message;
}

function startPerfProgress(opts) {
    stopPerfProgress();
    const boxId = opts.boxId || 'perf-progress';
    perfProgressActiveBoxId = boxId;
    const box = document.getElementById(boxId);
    if (!box) return;

    const {
        title = 'Đang xử lý…',
        estimatedSec = 120,
        steps = ['Đang xử lý…'],
        hint = 'Không đóng tab trình duyệt.',
    } = opts;

    box.style.display = 'block';
    box.className = 'perf-progress perf-progress-active';
    box.innerHTML = `
        <div class="perf-progress-header">
            <span class="perf-progress-spinner" aria-hidden="true"></span>
            <strong class="perf-progress-title">${escHtml(title)}</strong>
        </div>
        <div class="perf-progress-track">
            <div class="perf-progress-fill" id="${boxId}-fill"></div>
        </div>
        <div class="perf-progress-meta">
            <span id="${boxId}-pct">0%</span>
            <span id="${boxId}-eta">Còn khoảng ${perfFormatDuration(estimatedSec)}</span>
        </div>
        <p class="perf-progress-step" id="${boxId}-step">${escHtml(steps[0])}</p>
        <p class="perf-progress-hint">${escHtml(hint)}</p>
    `;

    const start = Date.now();
    perfProgressTimer = setInterval(() => {
        const elapsed = (Date.now() - start) / 1000;
        const fill = document.getElementById(`${boxId}-fill`);
        const pctEl = document.getElementById(`${boxId}-pct`);
        const etaEl = document.getElementById(`${boxId}-eta`);
        const stepEl = document.getElementById(`${boxId}-step`);

        let pct;
        if (elapsed >= estimatedSec) {
            pct = Math.min(98, 95 + ((elapsed - estimatedSec) / Math.max(estimatedSec, 30)) * 3);
            if (etaEl) etaEl.textContent = 'Sắp xong — server vẫn đang xử lý…';
        } else {
            pct = (elapsed / estimatedSec) * 95;
            if (etaEl) etaEl.textContent = `Còn khoảng ${perfFormatDuration(estimatedSec - elapsed)}`;
        }
        if (fill) fill.style.width = `${pct}%`;
        if (pctEl) pctEl.textContent = `${Math.floor(pct)}%`;

        const stepIdx = Math.min(
            steps.length - 1,
            Math.floor((elapsed / estimatedSec) * steps.length),
        );
        if (stepEl) stepEl.textContent = steps[stepIdx];
    }, 400);
}

function stopPerfProgress(success, message, boxId) {
    if (perfProgressTimer) {
        clearInterval(perfProgressTimer);
        perfProgressTimer = null;
    }
    if (success === undefined && message === undefined) return;

    const id = boxId || perfProgressActiveBoxId;
    const box = document.getElementById(id);
    if (!box) return;

    const fill = document.getElementById(`${id}-fill`);
    const pctEl = document.getElementById(`${id}-pct`);
    const etaEl = document.getElementById(`${id}-eta`);
    const stepEl = document.getElementById(`${id}-step`);

    if (success) {
        box.classList.remove('perf-progress-active');
        box.classList.add('perf-progress-done');
        if (fill) fill.style.width = '100%';
        if (pctEl) pctEl.textContent = '100%';
        if (etaEl) etaEl.textContent = 'Hoàn tất';
        if (stepEl) stepEl.textContent = message || 'Xong.';
    } else {
        box.classList.remove('perf-progress-active');
        box.classList.add('perf-progress-error');
        if (etaEl) etaEl.textContent = '';
        if (stepEl) stepEl.textContent = message || 'Lỗi.';
    }
}

async function perfSeedSelected() {
    const ids = perfSelectedPresetIds();
    if (ids.length !== 1) {
        alert('Chọn đúng một preset để seed (tránh nhầm quy mô).');
        return;
    }
    const preset = perfPresetsCache.find((p) => p.id === ids[0]);
    if (!preset) return;
    const estSec = perfEstimateSeedSeconds(preset);
    if (!confirm(`Seed ${preset.label}?\nƯớc tính ~${Math.ceil(estSec / 60)} phút.`)) return;
    startPerfProgress({
        title: `Đang seed ${preset.label}…`,
        estimatedSec: estSec,
        steps: PERF_SEED_STEPS,
    });
    try {
        const r = await apiAdmin('/api/performance/seed', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ preset_id: preset.id }),
        });
        stopPerfProgress(
            true,
            `Seed xong (${r.elapsed_sec}s) — ${r.seeded_rules} luật, ${r.seeded_eav_rows?.toLocaleString('vi-VN')} EAV.`,
        );
        loadPerfStatus();
    } catch (e) {
        stopPerfProgress(false, e.message || String(e));
    }
}

async function perfCleanup() {
    if (!confirm('Xóa toàn bộ PERF_BENCH policies/EAV và khôi phục index mặc định?')) return;
    startPerfProgress({
        title: 'Đang dọn dữ liệu benchmark…',
        estimatedSec: 25,
        steps: ['Xóa policy_conditions…', 'Xóa policies PERF_BENCH…', 'Xóa EAV perf_bench…'],
    });
    try {
        const r = await apiAdmin('/api/performance/cleanup', { method: 'POST' });
        stopPerfProgress(
            true,
            `Đã xóa ${r.removed_policies} luật bench, ${r.removed_eav} EAV bench.`,
        );
        loadPerfStatus();
    } catch (e) {
        stopPerfProgress(false, e.message || String(e));
    }
}

function renderPerfResults(runPayload) {
    const tbody = document.querySelector('#tbl-perf-results tbody');
    const summary = document.getElementById('perf-results-summary');
    if (!tbody) return;
    const rows = [];
    let rowCount = 0;
    (runPayload.runs || []).forEach((run) => {
        const preset = run.preset || {};
        const scenarios = run.scenarios || {};
        Object.keys(scenarios).forEach((sc) => {
            const s = scenarios[sc];
            const measured = s.avg_ms;
            const ratio = s.ratio_vs_thesis != null ? `${s.ratio_vs_thesis}×` : '—';
            rowCount += 1;
            rows.push(`<tr>
                <td>${escHtml(preset.label || preset.id)}</td>
                <td>${escHtml(PERF_SCENARIO_LABELS[sc] || sc)}</td>
                <td><b>${measured}</b></td>
                <td>${ratio}</td>
            </tr>`);
        });
    });
    tbody.innerHTML = rows.join('') || '<tr><td colspan="4">Chưa có kết quả — có thể request bị timeout trước khi server trả JSON.</td></tr>';
    if (summary) {
        const savedAt = runPayload.saved_at
            ? new Date(runPayload.saved_at).toLocaleString('vi-VN')
            : new Date().toLocaleString('vi-VN');
        summary.textContent = rowCount
            ? `${rowCount} dòng kết quả · lưu lúc ${savedAt}`
            : 'Chưa có dòng kết quả. Thử giảm số yêu cầu/đợt hoặc tăng timeout Gunicorn/Nginx.';
    }
    document.getElementById('perf-results-card')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
    return rowCount;
}

function savePerfResults(runPayload) {
    try {
        const payload = { ...runPayload, saved_at: new Date().toISOString() };
        sessionStorage.setItem(PERF_RESULTS_SS_KEY, JSON.stringify(payload));
    } catch {
        /* ignore quota */
    }
}

function restorePerfResultsFromStorage() {
    try {
        const raw = sessionStorage.getItem(PERF_RESULTS_SS_KEY);
        if (!raw) return;
        renderPerfResults(JSON.parse(raw));
    } catch {
        /* ignore */
    }
}

function perfEstimateRunSeconds(presetIds, scenarios, batches, requests) {
    let totalSec = 0;
    presetIds.forEach((pid) => {
        const preset = perfPresetsCache.find((p) => p.id === pid);
        if (!preset?.thesis_ms) return;
        scenarios.forEach((sc) => {
            const ms = preset.thesis_ms[sc] || preset.thesis_ms.btree_partial || 50;
            totalSec += (batches * requests * ms) / 1000;
        });
    });
    totalSec += presetIds.length * scenarios.length * 30;
    return Math.max(30, Math.round(totalSec));
}

function perfEstimateRunMinutes(presetIds, scenarios, batches, requests) {
    return Math.max(1, Math.round(perfEstimateRunSeconds(presetIds, scenarios, batches, requests) / 60));
}

function perfSelectedHistoryIds() {
    return [...document.querySelectorAll('input[name="perf-history"]:checked')]
        .map((el) => parseInt(el.value, 10))
        .filter((n) => !Number.isNaN(n));
}

function perfFormatHistoryTime(iso) {
    if (!iso) return '—';
    try {
        return new Date(iso).toLocaleString('vi-VN', { dateStyle: 'short', timeStyle: 'short' });
    } catch {
        return iso;
    }
}

async function loadPerfHistory() {
    const tbody = document.querySelector('#tbl-perf-history tbody');
    if (!tbody) return;
    try {
        const data = await api('/api/performance/history');
        const items = data.items || [];
        if (!data.ready) {
            tbody.innerHTML = '<tr><td colspan="6">Chưa cài bảng lịch sử (perf_benchmark_history.sql).</td></tr>';
            return;
        }
        if (!items.length) {
            tbody.innerHTML = '<tr><td colspan="6">Chưa có lần chạy nào được lưu.</td></tr>';
            return;
        }
        tbody.innerHTML = items.map((h) => {
            const params = `${h.requests_per_batch}×${h.batches} · ${(h.scenarios || []).join(', ')}`;
            const presets = (h.preset_labels || []).join(', ') || '—';
            const note = h.note ? escHtml(h.note) : '—';
            return `<tr>
                <td><input type="checkbox" name="perf-history" value="${h.history_id}"></td>
                <td>${escHtml(perfFormatHistoryTime(h.created_at))}</td>
                <td>${note}</td>
                <td>${escHtml(params)}</td>
                <td>${h.result_rows} dòng · ${escHtml(presets)}</td>
                <td><button type="button" class="btn btn-sm" onclick="perfViewHistory(${h.history_id})">Xem</button></td>
            </tr>`;
        }).join('');
        const checkAll = document.getElementById('perf-history-check-all');
        if (checkAll) {
            checkAll.checked = false;
            checkAll.onchange = () => {
                document.querySelectorAll('input[name="perf-history"]').forEach((cb) => {
                    cb.checked = checkAll.checked;
                });
            };
        }
    } catch (e) {
        tbody.innerHTML = `<tr><td colspan="6">${escHtml(e.message || String(e))}</td></tr>`;
    }
}

async function perfViewHistory(historyId) {
    try {
        const item = await api(`/api/performance/history/${historyId}`);
        const payload = item.payload || {};
        payload.saved_at = item.created_at;
        payload.history_note = item.note;
        savePerfResults(payload);
        renderPerfResults(payload);
        document.getElementById('perf-results-card')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
    } catch (e) {
        alert(e.message || String(e));
    }
}

function renderPerfCompare(data) {
    const card = document.getElementById('perf-compare-card');
    const thead = document.querySelector('#tbl-perf-compare thead');
    const tbody = document.querySelector('#tbl-perf-compare tbody');
    const summary = document.getElementById('perf-compare-summary');
    if (!card || !thead || !tbody) return;

    const runs = data.runs || [];
    const rows = data.rows || [];
    thead.innerHTML = `<tr>
        <th>Quy mô</th>
        <th>Kịch bản</th>
        ${runs.map((r) => `<th>${escHtml(r.label || `#${r.history_id}`)}</th>`).join('')}
    </tr>`;

    tbody.innerHTML = rows.map((row) => {
        const cells = runs.map((r) => {
            const v = row.values?.[r.history_id];
            if (!v || v.avg_ms == null) return '<td>—</td>';
            const ratio = v.ratio_vs_thesis != null ? ` <span class="perf-compare-ratio">(${v.ratio_vs_thesis}×)</span>` : '';
            return `<td><b>${v.avg_ms}</b>${ratio}</td>`;
        }).join('');
        return `<tr>
            <td>${escHtml(row.preset_label)}</td>
            <td>${escHtml(PERF_SCENARIO_LABELS[row.scenario] || row.scenario)}</td>
            ${cells}
        </tr>`;
    }).join('') || `<tr><td colspan="${runs.length + 2}">Không có dòng chung để so sánh.</td></tr>`;

    if (summary) {
        summary.textContent = `So sánh ${runs.length} lần chạy · ${rows.length} dòng (quy mô + kịch bản).`;
    }
    card.style.display = 'block';
    card.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

async function perfCompareSelected() {
    const ids = perfSelectedHistoryIds();
    if (ids.length < 2) {
        alert('Chọn ít nhất 2 dòng lịch sử để so sánh.');
        return;
    }
    try {
        const data = await api('/api/performance/history/compare', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ run_ids: ids }),
        });
        renderPerfCompare(data);
    } catch (e) {
        alert(e.message || String(e));
    }
}

async function perfDeleteHistorySelected() {
    const ids = perfSelectedHistoryIds();
    if (!ids.length) {
        alert('Chọn ít nhất một dòng để xóa.');
        return;
    }
    if (!confirm(`Xóa ${ids.length} bản ghi lịch sử?`)) return;
    for (const id of ids) {
        try {
            await apiAdmin(`/api/performance/history/${id}`, { method: 'DELETE' });
        } catch (e) {
            alert(`Không xóa #${id}: ${e.message || e}`);
            break;
        }
    }
    loadPerfHistory();
}

async function perfRunBenchmark() {
    const presetIds = perfSelectedPresetIds();
    const scenarios = perfSelectedScenarios();
    if (!presetIds.length) {
        alert('Chọn ít nhất một quy mô preset.');
        return;
    }
    if (!scenarios.length) {
        alert('Chọn ít nhất một kịch bản chỉ mục.');
        return;
    }
    const requests = parseInt(document.getElementById('inp-perf-requests')?.value, 10) || 1000;
    const batches = parseInt(document.getElementById('inp-perf-batches')?.value, 10) || 5;
    const estCalls = presetIds.length * scenarios.length * batches * requests;
    const estMin = perfEstimateRunMinutes(presetIds, scenarios, batches, requests);
    const slowWarn = estMin >= 30
        ? `\n⚠ Ước tính ~${estMin} phút. Nên chạy 1 kịch bản/lần với preset lớn.`
        : `\nƯớc tính ~${estMin} phút.`;
    if (!confirm(
        `Chạy benchmark?\n` +
        `- ${presetIds.length} preset × ${scenarios.length} kịch bản\n` +
        `- ${requests} yêu cầu/đợt × ${batches} đợt\n` +
        `- ~${estCalls.toLocaleString('vi-VN')} lần gọi PDP` +
        slowWarn +
        `\nIndex sẽ DROP/CREATE tạm thời. Không đóng tab.`
    )) return;

    const estSec = perfEstimateRunSeconds(presetIds, scenarios, batches, requests);
    startPerfProgress({
        title: 'Đang chạy benchmark PDP…',
        estimatedSec: estSec,
        steps: PERF_RUN_STEPS,
        hint: `~${estCalls.toLocaleString('vi-VN')} lần gọi PDP · không đóng tab.`,
    });
    try {
        const note = (document.getElementById('inp-perf-run-note')?.value || '').trim();
        const data = await apiAdmin('/api/performance/run', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                preset_ids: presetIds,
                scenarios,
                batches,
                requests_per_batch: requests,
                note: note || undefined,
            }),
        });
        const totalSec = (data.runs || []).reduce((s, r) => s + (r.elapsed_sec || 0), 0);
        savePerfResults(data);
        const rowCount = renderPerfResults(data);
        const histMsg = data.history_id
            ? ` · đã lưu lịch sử #${data.history_id}`
            : (data.history_save_error ? ' · chưa lưu lịch sử (xem log)' : '');
        stopPerfProgress(
            true,
            rowCount
                ? `Hoàn tất: ${rowCount} dòng (${data.runs?.length || 0} preset, ~${totalSec}s)${histMsg}.`
                : `Server trả về nhưng không có dòng kết quả (~${totalSec}s).`,
        );
        loadPerfStatus();
        loadPerfHistory();
    } catch (e) {
        stopPerfProgress(false, e.message || String(e));
    }
}

// ============================================================
// LOAD TEST TPS/P95 (3.2.3)
// ============================================================
const LT_RESULTS_SS_KEY = 'abac_lt_last_results';

function ltSelectedConfigIds() {
    return [...document.querySelectorAll('input[name="lt-config"]:checked')]
        .map((el) => el.value);
}

function renderLtConfigList(configs) {
    const box = document.getElementById('lt-config-list');
    if (!box) return;
    box.innerHTML = (configs || []).map((c) => `
        <label class="perf-preset-item">
            <input type="checkbox" name="lt-config" value="${escHtml(c.id)}" checked>
            <span><b>${escHtml(c.label)}</b></span>
            <span class="perf-preset-meta">${escHtml(c.note || '')}</span>
        </label>
    `).join('');
}

async function loadLtStatus() {
    const st = await api('/api/loadtest/status');
    ltStatusCache = st;
    const c = st.counts || {};
    const el = document.getElementById('lt-status');
    if (el) {
        el.innerHTML = `
            <div><b>Luật bật:</b> ${c.enabled_policies ?? '—'} · <b>Users:</b> ${c.users ?? '—'} · <b>Requests:</b> ${c.access_requests ?? '—'}</div>
            <div><b>loadtest_functions:</b> ${st.loadtest_functions_available ? 'yes' : 'no'}
            · <b>history:</b> ${st.history_table_ready ? 'yes' : 'no'}</div>
            <div><b>Index LT:</b> ${(st.active_loadtest_indexes || []).join(', ') || '—'}</div>
            ${!st.loadtest_functions_available ? '<div class="perf-bad">Chạy scripts/loadtest_functions.sql trên PostgreSQL</div>' : ''}
        `;
    }
    renderLtConfigList(st.configs || []);
    const dur = document.getElementById('inp-lt-duration');
    const wrk = document.getElementById('inp-lt-workers');
    if (dur && st.defaults?.duration_sec) dur.value = st.defaults.duration_sec;
    if (wrk && st.defaults?.workers) wrk.value = st.defaults.workers;
    const dh = document.getElementById('lt-duration-hint');
    const wh = document.getElementById('lt-workers-hint');
    if (dh && dur) dh.textContent = dur.value;
    if (wh && wrk) wh.textContent = wrk.value;
    restoreLtResultsFromStorage();
}

document.querySelectorAll('#inp-lt-duration, #inp-lt-workers').forEach((el) => {
    el?.addEventListener('input', () => {
        const dh = document.getElementById('lt-duration-hint');
        const wh = document.getElementById('lt-workers-hint');
        if (el.id === 'inp-lt-duration' && dh) dh.textContent = el.value;
        if (el.id === 'inp-lt-workers' && wh) wh.textContent = el.value;
    });
});

function renderLtResults(payload) {
    const tbody = document.querySelector('#tbl-lt-results tbody');
    const summary = document.getElementById('lt-results-summary');
    if (!tbody) return 0;
    const rows = [];
    (payload.table_rows || []).forEach((r) => {
        rows.push(`<tr>
            <td>${escHtml(r.label)}</td>
            <td><b>${r.tps ?? '—'}</b></td>
            <td><b>${r.p95_ms ?? '—'}</b></td>
            <td>${escHtml(r.note || 'Đo thực tế')}</td>
        </tr>`);
    });
    if (payload.forecast_row) {
        const f = payload.forecast_row;
        rows.push(`<tr class="lt-forecast-row">
            <td>${escHtml(f.label)}</td>
            <td>~${f.tps ?? '—'}</td>
            <td>~${f.p95_ms ?? '—'}</td>
            <td>${escHtml(f.note || 'Dự báo')}</td>
        </tr>`);
    }
    tbody.innerHTML = rows.join('') || '<tr><td colspan="4">Chưa có kết quả</td></tr>';
    if (summary) {
        const n = (payload.table_rows || []).length;
        summary.textContent = n
            ? `${n} cấu hình đo thực tế${payload.history_id ? ` · lịch sử #${payload.history_id}` : ''}`
            : 'Chưa có dòng kết quả.';
    }
    document.getElementById('lt-results-card')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
    return rows.length;
}

function saveLtResults(payload) {
    try {
        sessionStorage.setItem(LT_RESULTS_SS_KEY, JSON.stringify({ ...payload, saved_at: new Date().toISOString() }));
    } catch { /* ignore */ }
}

function restoreLtResultsFromStorage() {
    try {
        const raw = sessionStorage.getItem(LT_RESULTS_SS_KEY);
        if (raw) renderLtResults(JSON.parse(raw));
    } catch { /* ignore */ }
}

async function loadLtHistory() {
    const tbody = document.querySelector('#tbl-lt-history tbody');
    if (!tbody) return;
    try {
        const data = await api('/api/loadtest/history');
        const items = data.items || [];
        if (!data.ready) {
            tbody.innerHTML = '<tr><td colspan="5">Chưa cài loadtest_history.sql</td></tr>';
            return;
        }
        if (!items.length) {
            tbody.innerHTML = '<tr><td colspan="5">Chưa có lần chạy nào.</td></tr>';
            return;
        }
        tbody.innerHTML = items.map((h) => `
            <tr>
                <td><input type="checkbox" name="lt-history" value="${h.history_id}"></td>
                <td>${escHtml(new Date(h.created_at).toLocaleString('vi-VN'))}</td>
                <td>${escHtml(h.note || '—')}</td>
                <td>${h.duration_sec}s · ${h.workers} worker · ${h.row_count} dòng</td>
                <td><button type="button" class="btn btn-sm" onclick="ltViewHistory(${h.history_id})">Xem</button></td>
            </tr>
        `).join('');
        const checkAll = document.getElementById('lt-history-check-all');
        if (checkAll) {
            checkAll.onchange = () => {
                document.querySelectorAll('input[name="lt-history"]').forEach((cb) => {
                    cb.checked = checkAll.checked;
                });
            };
        }
    } catch (e) {
        tbody.innerHTML = `<tr><td colspan="5">${escHtml(e.message)}</td></tr>`;
    }
}

async function ltViewHistory(historyId) {
    const item = await api(`/api/loadtest/history/${historyId}`);
    const payload = item.payload || {};
    payload.history_id = item.history_id;
    saveLtResults(payload);
    renderLtResults(payload);
}

async function ltDeleteHistorySelected() {
    const ids = [...document.querySelectorAll('input[name="lt-history"]:checked')]
        .map((el) => parseInt(el.value, 10)).filter((n) => !Number.isNaN(n));
    if (!ids.length) { alert('Chọn ít nhất một dòng.'); return; }
    if (!confirm(`Xóa ${ids.length} bản ghi lịch sử load test?`)) return;
    for (const id of ids) {
        await apiAdmin(`/api/loadtest/history/${id}`, { method: 'DELETE' });
    }
    loadLtHistory();
}

async function ltRunLoadtest() {
    if (!ltStatusCache) await loadLtStatus();
    const configIds = ltSelectedConfigIds();
    if (!configIds.length) { alert('Chọn ít nhất một cấu hình.'); return; }
    const duration = parseInt(document.getElementById('inp-lt-duration')?.value, 10) || 30;
    const workers = parseInt(document.getElementById('inp-lt-workers')?.value, 10) || 4;
    const configs = ltStatusCache?.configs || [];
    const configLabels = configIds.map((id) => {
        const c = configs.find((x) => x.id === id);
        return c ? c.label : id;
    });
    const perConfigSec = duration + 15;
    const estSec = configIds.length * perConfigSec + 20;
    if (!confirm(
        `Chạy load test?\n- ${configIds.length} cấu hình × ${duration}s × ${workers} worker\n` +
        `Ước tính ~${Math.ceil(estSec / 60)} phút. Không đóng tab.`
    )) return;

    const progressBoxId = 'lt-progress';
    startPerfProgress({
        boxId: progressBoxId,
        title: 'Đang chạy load test TPS/P95…',
        estimatedSec: estSec,
        steps: configLabels.map((label, i) => `Cấu hình ${i + 1}/${configIds.length}: ${label}`),
        hint: 'Mỗi cấu hình chạy riêng — tránh timeout gateway.',
    });

    const allRuns = [];
    const allRows = [];
    let lastPayload = null;

    try {
        for (let i = 0; i < configIds.length; i++) {
            const cid = configIds[i];
            const label = configLabels[i];
            updatePerfProgressStep(
                `Cấu hình ${i + 1}/${configIds.length}: ${label} — warm-up & đo TPS…`,
                progressBoxId,
            );
            const data = await apiAdmin('/api/loadtest/run', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    config_ids: [cid],
                    duration_sec: duration,
                    workers,
                    save_history: false,
                    include_citus_forecast: false,
                }),
            });
            allRuns.push(...(data.runs || []));
            allRows.push(...(data.table_rows || []));
            lastPayload = data;
        }

        const note = (document.getElementById('inp-lt-note')?.value || '').trim();
        const merged = {
            runs: allRuns,
            duration_sec: duration,
            workers,
            warmup: lastPayload?.warmup,
            table_rows: allRows,
        };
        const forecast = ltStatusCache?.citus_forecast;
        if (forecast) {
            merged.forecast_row = {
                ...forecast,
                tps: forecast.tps,
                p95_ms: forecast.p95_ms,
            };
        }

        try {
            const saveRes = await apiAdmin('/api/loadtest/history', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ payload: merged, note: note || undefined }),
            });
            if (saveRes.history_id) merged.history_id = saveRes.history_id;
        } catch (saveErr) {
            merged.history_save_error = saveErr.message || String(saveErr);
        }

        saveLtResults(merged);
        const n = renderLtResults(merged);
        const hist = merged.history_id ? ` · lịch sử #${merged.history_id}` : '';
        stopPerfProgress(true, `Hoàn tất: ${n} dòng Bảng 11${hist}.`, progressBoxId);
        loadLtStatus();
        loadLtHistory();
    } catch (e) {
        stopPerfProgress(false, e.message || String(e), progressBoxId);
    }
}
