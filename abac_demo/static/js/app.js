/**
 * ABAC Demo — Frontend Application
 * Kiểm soát truy cập hồ sơ dữ liệu nhạy cảm cấp quốc gia
 * Attribute-Based Access Control | PEP / PDP / PIP / PAP
 */

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
    });
});

// ============================================================
// HELPERS
// ============================================================
const api = async (url, opts) => {
    const res = await fetch(url, opts);
    const text = await res.text();
    let data = null;
    try {
        data = text ? JSON.parse(text) : null;
    } catch {
        const clip = text.length > 300 ? `${text.slice(0, 300)}…` : text;
        throw new Error(`Phản hồi không phải JSON (HTTP ${res.status}). Đầu tiên nhận được: ${clip}`);
    }
    if (!res.ok) {
        const msg = (data && (data.error || data.message)) || `HTTP ${res.status}`;
        const type = data && data.type ? ` (${data.type})` : '';
        throw new Error(`${msg}${type}`);
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
        `<option value="${u.user_id}">${u.full_name} (${u.agency_code}, CL${u.clearance_level}, ${u.employment_status})</option>`
    ).join('');
    sr.innerHTML = resources.map(r =>
        `<option value="${r.resource_id}">${r.resource_name} (CL${r.classification_level})</option>`
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
        const h = document.createElement('h3');
        h.textContent = '❌ Không gọi được API / Lỗi máy chủ';
        const msg = document.createElement('div');
        msg.className = 'result-detail';
        msg.textContent = e.message || String(e);
        box.appendChild(h);
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
    box.innerHTML = `
        <h3>${isPermit ? '✅ PERMIT — Cho phép truy cập' : '❌ DENY — Từ chối truy cập'}</h3>
        <div class="result-detail"><span>Lý do:</span> ${r.reason}</div>
        <div class="result-detail"><span>Policy ID:</span> ${r.matched_policy_id || 'N/A (default deny)'}</div>
        <div class="result-detail"><span>Thời gian đánh giá:</span> ${r.evaluation_time_ms}ms</div>
        <div class="result-detail"><span>Request ID:</span> ${r.request_id || 'N/A'}</div>
        <div class="result-detail"><span>Trace ID:</span> <code>${r.trace_id || 'N/A'}</code></div>
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
            `<span class="badge" style="background:var(--primary-light);color:var(--primary);margin:2px;">${a.key}=${a.value}</span>`
        ).join(' ');
        return `<tr>
            <td>${u.user_id}</td>
            <td>${u.full_name}</td>
            <td>${u.agency_code} (${u.agency_name})</td>
            <td>${clBadge(u.clearance_level)}</td>
            <td>${statusBadge(u.employment_status)}</td>
            <td>${u.position || '-'}</td>
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
        <td>${r.resource_name}</td>
        <td>${r.resource_type}</td>
        <td>${r.owner_agency} (${r.agency_name})</td>
        <td>${clBadge(r.classification_level)}</td>
        <td>${r.managing_region || '-'}</td>
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
            `<div style="font-size:0.8rem;"><b>${c.attribute_type}.${c.attribute_key}</b> ${c.operator} ${c.compare_value}</div>`
        ).join('');
        return `<tr>
            <td>${p.policy_id}</td>
            <td><b>${p.policy_name}</b><br><span style="font-size:0.8rem;color:var(--gray-500);">${p.description || ''}</span></td>
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
    await api(`/api/policies/${id}/toggle`, { method: 'PUT' });
    loadPolicies();
}

// ============================================================
// AUDIT LOGS & STATS
// ============================================================
async function loadAuditLogs() {
    const logs = await api('/api/audit/logs?limit=50');
    document.querySelector('#tbl-audit tbody').innerHTML = (logs || []).map(l => `<tr>
        <td>${l.request_id}</td>
        <td>${new Date(l.request_time).toLocaleString('vi-VN')}</td>
        <td style="font-size:0.7rem;">${(l.trace_id || '').substring(0,8)}...</td>
        <td>${l.user_name} (${l.agency_code})</td>
        <td>${l.resource_name}</td>
        <td>${l.action}</td>
        <td>${l.env_device_trust}</td>
        <td>${l.env_network_zone}</td>
        <td>${l.env_hour}h</td>
        <td><span class="badge badge-${l.decision}">${l.decision.toUpperCase()}${l.is_break_glass ? ' 🔓' : ''}</span></td>
        <td style="font-size:0.8rem;">${l.reason}</td>
        <td>${l.evaluation_time_ms || '-'}ms</td>
    </tr>`).join('');
}

async function loadAuditStats() {
    const stats = await api('/api/audit/stats');
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
            <td>${a.full_name}</td>
            <td>${a.agency_code}</td>
            <td>${a.total_requests}</td>
            <td>${a.deny_count}</td>
            <td>${a.deny_rate_pct}%</td>
            <td style="color:${riskColor};font-weight:600;">${a.risk_level}</td>
        </tr>`;
    }).join('');
}
