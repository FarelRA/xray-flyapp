document.addEventListener('DOMContentLoaded', () => {
    fetchServices();
    fetchConfigs();
    initTerminal();
    populateLogSelector();
});

const API_BASE = '/api';
let currentLogSource = null;

// --- Services ---
async function fetchServices() {
    try {
        const response = await fetch(`${API_BASE}/services`);
        const result = await response.json();
        if (result.status === 'success') {
            const grid = document.getElementById('services-grid');
            grid.innerHTML = result.data.map(service => `
                <div class="service-card">
                    <h3>${service.name}</h3>
                    <p>Status: <span class="status-${service.status}">${service.status.toUpperCase()}</span></p>
                    <div class="actions">
                        <button class="outline" onclick="handleServiceAction('${service.name}', 'start')">Start</button>
                        <button class="outline" onclick="handleServiceAction('${service.name}', 'stop')">Stop</button>
                        <button class="outline" onclick="handleServiceAction('${service.name}', 'restart')">Restart</button>
                    </div>
                </div>
            `).join('');
        }
    } catch (error) {
        console.error('Error fetching services:', error);
    }
}

async function handleServiceAction(name, action) {
    if (!confirm(`Are you sure you want to ${action} the ${name} service?`)) return;
    try {
        await fetch(`${API_BASE}/services/${name}/${action}`, { method: 'POST' });
        setTimeout(fetchServices, 500); // Refresh status after a short delay
    } catch (error) {
        console.error(`Error performing action ${action} on ${name}:`, error);
    }
}

// --- Configs ---
let configCache = [];
async function fetchConfigs() {
    try {
        const response = await fetch(`${API_BASE}/configs`);
        const result = await response.json();
        if (result.status === 'success') {
            configCache = result.data;
            const selector = document.getElementById('config-selector');
            selector.innerHTML = configCache.map((cfg, index) => `<option value="${index}">${cfg.name} (${cfg.path})</option>`).join('');
            loadSelectedConfig();
        }
    } catch (error) {
        console.error('Error fetching configs:', error);
    }
}

function loadSelectedConfig() {
    const selector = document.getElementById('config-selector');
    const editor = document.getElementById('config-editor');
    const selectedConfig = configCache[selector.value];
    if (selectedConfig) {
        editor.value = selectedConfig.content;
    }
}

async function saveCurrentConfig() {
    const selector = document.getElementById('config-selector');
    const editor = document.getElementById('config-editor');
    const statusEl = document.getElementById('config-status');
    const selectedConfig = configCache[selector.value];

    if (!selectedConfig) return;

    try {
        const response = await fetch(`${API_BASE}/configs`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                path: selectedConfig.path,
                content: editor.value
            })
        });
        const result = await response.json();
        statusEl.textContent = result.message;
        statusEl.className = result.status === 'success' ? 'success' : 'error';
        setTimeout(() => statusEl.textContent = '', 3000);
        // Refresh cache
        fetchConfigs();
    } catch (error) {
        console.error('Error saving config:', error);
        statusEl.textContent = 'Failed to save config.';
        statusEl.className = 'error';
    }
}

// --- Logs ---
function populateLogSelector() {
    const servicesWithLogs = ['frps', 'traefik', 'xray']; // Exclude dashboard, sshd
    const selector = document.getElementById('log-selector');
    selector.innerHTML = '<option value="">-- Select a Service --</option>' + 
        servicesWithLogs.map(s => `<option value="${s}">${s}</option>`).join('');
}

function streamLogs() {
    if (currentLogSource) {
        currentLogSource.close();
    }
    const selector = document.getElementById('log-selector');
    const service = selector.value;
    const logOutput = document.getElementById('log-output');

    if (!service) {
        logOutput.innerHTML = '<code>Select a service to view logs...</code>';
        return;
    }

    logOutput.innerHTML = `<code>Streaming logs for ${service}...</code>\n`;
    currentLogSource = new EventSource(`${API_BASE}/logs/${service}`);

    currentLogSource.onmessage = (event) => {
        logOutput.innerHTML += `<code>${event.data}</code>\n`;
        logOutput.scrollTop = logOutput.scrollHeight;
    };
    currentLogSource.onerror = () => {
        logOutput.innerHTML += `<code>Connection to log stream lost. Please re-select.</code>\n`;
        currentLogSource.close();
    };
}

// --- Terminal ---
function initTerminal() {
    const term = new Terminal({
        cursorBlink: true,
        theme: {
            background: '#202b33',
            foreground: '#d3d7cf'
        }
    });
    const fitAddon = new FitAddon.FitAddon();
    term.loadAddon(fitAddon);
    term.open(document.getElementById('terminal'));
    fitAddon.fit();
    
    window.addEventListener('resize', () => fitAddon.fit());

    const protocol = (location.protocol === 'https:') ? 'wss://' : 'ws://';
    const socketURL = protocol + location.host + '/api/ws/tty';
    const ws = new WebSocket(socketURL);

    ws.onopen = () => {
        term.onData(data => ws.send(JSON.stringify({type: 'input', data: data})));
        term.onResize(size => ws.send(JSON.stringify({type: 'resize', cols: size.cols, rows: size.rows})));
        ws.send(JSON.stringify({type: 'resize', cols: term.cols, rows: term.rows}));
    };

    ws.onmessage = (event) => {
        term.write(event.data);
    };

    ws.onclose = () => {
        term.write('\r\n\n--- CONNECTION CLOSED ---');
    };
}
