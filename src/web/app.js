// Localization
let i18n = {};

function t(key, fallback) {
  if (i18n[key] !== undefined) return i18n[key];
  if (i18n['Zobscast.' + key] !== undefined) return i18n['Zobscast.' + key];
  return fallback;
}

function applyTranslations() {
  document.querySelectorAll('[data-i18n]').forEach(el => {
    const text = t(el.dataset.i18n, null);
    if (text !== null) el.textContent = text;
  });
  document.querySelectorAll('[data-i18n-placeholder]').forEach(el => {
    const text = t(el.dataset.i18nPlaceholder, null);
    if (text !== null) el.placeholder = text;
  });
  document.querySelectorAll('[data-i18n-title]').forEach(el => {
    const text = t(el.dataset.i18nTitle, null);
    if (text !== null) el.title = text;
  });
  const pageTitle = t('Title', null);
  if (pageTitle) document.title = pageTitle;
}

async function loadTranslations() {
  try {
    const res = await fetch('/api/locale');
    if (res.ok) {
      i18n = await res.json();
      applyTranslations();
      if (lastStatusData) {
        updateUI(lastStatusData);
      }
    }
  } catch (e) { }
}

// Form state & baseline
let savedSettings = {
  sink: '',
  bitrate: 2500,
  preset: 'ultrafast',
  debug_logging: false
};
let hasLoadedInitialSettings = false;
let lastStatusData = null;

function getCurrentFormValues() {
  return {
    sink: (document.getElementById('sinkInput').value || '').trim(),
    bitrate: parseInt(document.getElementById('bitrateInput').value, 10) || 2500,
    preset: document.getElementById('presetSelect').value || 'ultrafast',
    debug_logging: !!document.getElementById('debugLog').checked
  };
}

function isFormDirty() {
  if (!hasLoadedInitialSettings) return false;
  const current = getCurrentFormValues();
  return current.sink !== savedSettings.sink ||
    current.bitrate !== savedSettings.bitrate ||
    current.preset !== savedSettings.preset ||
    current.debug_logging !== savedSettings.debug_logging;
}

function updateSaveButton() {
  const saveBtn = document.getElementById('saveBtn');
  saveBtn.disabled = !isFormDirty();
}

function isAnyFieldFocused() {
  const activeId = document.activeElement ? document.activeElement.id : null;
  return ['sinkInput', 'bitrateInput', 'presetSelect', 'debugLog', 'deviceSelect'].includes(activeId);
}

// Data fetching & UI updates
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
  btn.textContent = t('Destination.ScanInProgress', 'Scanning...');
  try {
    const res = await fetch('/api/scan', { method: 'POST' });
    const devices = await res.json();
    updateDeviceList(devices);
    showToast(t('Toast.ScanComplete', 'Scan complete'));
  } catch (e) {
    showToast(t('Toast.ScanFailed', 'Scan failed'));
  } finally {
    btn.disabled = false;
    btn.textContent = t('Destination.Scan', 'Scan');
  }
}

function updateDeviceList(devices) {
  const sel = document.getElementById('deviceSelect');
  sel.innerHTML = `<option value="">${t('Destination.Choose', '-- Choose Discovered Device --')}</option>`;
  devices.forEach(d => {
    const opt = document.createElement('option');
    opt.value = d.ip + ':' + d.port;
    opt.textContent = d.name + ' (' + d.ip + ':' + d.port + ')';
    sel.appendChild(opt);
  });
}

function updateUI(data) {
  lastStatusData = data;
  const badge = document.getElementById('statusBadge');
  const toggleBtn = document.getElementById('toggleBtn');
  const statusText = document.getElementById('statusText');

  if (data.active) {
    badge.className = 'status-badge active';
    if (statusText) statusText.textContent = t('Status.Active', 'Casting Live');
    toggleBtn.textContent = t('Actions.Stop', 'Stop Casting');
    toggleBtn.className = 'btn btn-danger';
  } else {
    badge.className = 'status-badge';
    if (statusText) statusText.textContent = t('Status.Inactive', 'Inactive');
    toggleBtn.textContent = t('Actions.Start', 'Start Casting');
    toggleBtn.className = 'btn btn-secondary';
  }

  // Never overwrite user inputs if the user has changed values or is currently editing
  if (!hasLoadedInitialSettings || (!isFormDirty() && !isAnyFieldFocused())) {
    document.getElementById('sinkInput').value = data.sink || '';
    document.getElementById('bitrateInput').value = data.bitrate || 2500;
    document.getElementById('presetSelect').value = data.preset || 'ultrafast';
    document.getElementById('debugLog').checked = !!data.debug_logging;

    savedSettings = {
      sink: (data.sink || '').trim(),
      bitrate: data.bitrate || 2500,
      preset: data.preset || 'ultrafast',
      debug_logging: !!data.debug_logging
    };
    hasLoadedInitialSettings = true;
    updateSaveButton();
  }
}

async function saveSettings() {
  const payload = getCurrentFormValues();
  try {
    const res = await fetch('/api/settings', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
    if (res.ok) {
      savedSettings = { ...payload };
      updateSaveButton();
      showToast(t('Toast.Saved', 'Settings saved!'));
      fetchStatus();
    } else {
      showToast(t('Toast.SaveFailed', 'Failed to save settings'));
    }
  } catch (e) {
    showToast(t('Toast.NetworkError', 'Network error'));
  }
}

async function toggleCast() {
  try {
    const res = await fetch('/api/toggle', { method: 'POST' });
    if (res.ok) fetchStatus();
  } catch (e) { }
}

function showToast(msg) {
  const tEl = document.getElementById('toast');
  tEl.textContent = msg;
  tEl.classList.add('show');
  setTimeout(() => tEl.classList.remove('show'), 2200);
}

// Event Listeners
['sinkInput', 'bitrateInput', 'presetSelect', 'debugLog'].forEach(id => {
  const el = document.getElementById(id);
  el.addEventListener('input', updateSaveButton);
  el.addEventListener('change', updateSaveButton);
});

document.getElementById('deviceSelect').addEventListener('change', (e) => {
  if (e.target.value) {
    document.getElementById('sinkInput').value = e.target.value;
    updateSaveButton();
  }
});

document.getElementById('scanBtn').addEventListener('click', scanDevices);
document.getElementById('saveBtn').addEventListener('click', saveSettings);
document.getElementById('toggleBtn').addEventListener('click', toggleCast);

// Initial bootstrap
loadTranslations();
fetchStatus();
fetchDevices();
setInterval(fetchStatus, 3000);
