async function fetchStatus() {
  try {
    const res = await fetch('/api/settings');
    if (!res.ok) return;
    const data = await res.json();
    updateUI(data);
  } catch (e) { }
}

async function fetchDevices() {
  try {
    const res = await fetch('/api/devices');
    if (!res.ok) return;
    const devices = await res.json();
    updateDeviceList(devices);
  } catch (e) { }
}

async function scanDevices() {
  const btn = document.getElementById('scanBtn');
  btn.disabled = true;
  btn.textContent = 'Scanning...';
  try {
    const res = await fetch('/api/scan', { method: 'POST' });
    const devices = await res.json();
    updateDeviceList(devices);
    showToast('Scan complete');
  } catch (e) {
    showToast('Scan failed');
  } finally {
    btn.disabled = false;
    btn.textContent = 'Scan';
  }
}

function updateDeviceList(devices) {
  const sel = document.getElementById('deviceSelect');
  sel.innerHTML = '<option value="">-- Choose Discovered Device --</option>';
  devices.forEach(d => {
    const opt = document.createElement('option');
    opt.value = d.ip + ':' + d.port;
    opt.textContent = d.name + ' (' + d.ip + ':' + d.port + ')';
    sel.appendChild(opt);
  });
}

function updateUI(data) {
  const badge = document.getElementById('statusBadge');
  const toggleBtn = document.getElementById('toggleBtn');
  if (data.active) {
    badge.className = 'status-badge active';
    badge.innerHTML = '<span class="status-dot"></span> Casting Live';
    toggleBtn.textContent = 'Stop Casting';
    toggleBtn.className = 'btn btn-danger';
  } else {
    badge.className = 'status-badge';
    badge.innerHTML = '<span class="status-dot"></span> Inactive';
    toggleBtn.textContent = 'Start Casting';
    toggleBtn.className = 'btn btn-secondary';
  }
  if (!document.getElementById('sinkInput').dataset.modified) {
    document.getElementById('sinkInput').value = data.sink || '';
  }
  document.getElementById('bitrateInput').value = data.bitrate || 2500;
  document.getElementById('presetSelect').value = data.preset || 'ultrafast';
  document.getElementById('debugLog').checked = !!data.debug_logging;
}

async function saveSettings() {
  const payload = {
    sink: document.getElementById('sinkInput').value,
    bitrate: parseInt(document.getElementById('bitrateInput').value, 10) || 2500,
    preset: document.getElementById('presetSelect').value,
    debug_logging: document.getElementById('debugLog').checked
  };
  try {
    const res = await fetch('/api/settings', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
    if (res.ok) {
      delete document.getElementById('sinkInput').dataset.modified;
      showToast('Settings saved!');
      fetchStatus();
    } else {
      showToast('Failed to save settings');
    }
  } catch (e) {
    showToast('Network error');
  }
}

async function toggleCast() {
  try {
    const res = await fetch('/api/toggle', { method: 'POST' });
    if (res.ok) fetchStatus();
  } catch (e) { }
}

function showToast(msg) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.classList.add('show');
  setTimeout(() => t.classList.remove('show'), 2200);
}

document.getElementById('sinkInput').addEventListener('input', () => {
  document.getElementById('sinkInput').dataset.modified = '1';
});
document.getElementById('deviceSelect').addEventListener('change', (e) => {
  if (e.target.value) {
    document.getElementById('sinkInput').value = e.target.value;
    delete document.getElementById('sinkInput').dataset.modified;
  }
});
document.getElementById('scanBtn').addEventListener('click', scanDevices);
document.getElementById('saveBtn').addEventListener('click', saveSettings);
document.getElementById('toggleBtn').addEventListener('click', toggleCast);

fetchStatus();
fetchDevices();
setInterval(fetchStatus, 3000);
