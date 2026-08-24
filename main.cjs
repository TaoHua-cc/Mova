const { app, BrowserWindow, ipcMain, safeStorage } = require('electron');
const path = require('node:path');
const fs = require('node:fs');
const net = require('node:net');
const { spawn } = require('node:child_process');
let mpvProcess;

function createWindow() {
  const win = new BrowserWindow({
    width: 1440,
    height: 920,
    minWidth: 1024,
    minHeight: 680,
    frame: false,
    backgroundColor: '#080a0d',
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });
  win.loadFile(path.join(__dirname, 'app', 'index.html'));
  win.once('ready-to-show', () => win.show());
}

ipcMain.on('window-action', (event, action) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  if (!win) return;
  if (action === 'minimize') win.minimize();
  if (action === 'maximize') win.isMaximized() ? win.unmaximize() : win.maximize();
  if (action === 'close') win.close();
});

ipcMain.handle('api-request', async (_event, request) => {
  const url = new URL(request.url);
  if (!['http:', 'https:'].includes(url.protocol)) throw new Error('仅支持 HTTP 或 HTTPS 地址');
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 15000);
  try {
    const response = await fetch(url, {
      method: request.method || 'GET',
      headers: request.headers || {},
      body: request.body ? JSON.stringify(request.body) : undefined,
      signal: controller.signal
    });
    const text = await response.text();
    const data = text ? JSON.parse(text) : null;
    if (request.acceptErrors) return { status: response.status, data };
    if (!response.ok) throw new Error(`${response.status} ${text.slice(0, 180)}`);
    return data;
  } finally { clearTimeout(timer); }
});

function secretFile() { return path.join(app.getPath('userData'), 'secrets.json'); }
function readSecrets() { try { return JSON.parse(fs.readFileSync(secretFile(), 'utf8')); } catch { return {}; } }
ipcMain.handle('secret-set', (_event, key, value) => {
  if (!safeStorage.isEncryptionAvailable()) throw new Error('Windows 安全凭据加密当前不可用');
  const data = readSecrets();
  data[key] = safeStorage.encryptString(value).toString('base64');
  fs.writeFileSync(secretFile(), JSON.stringify(data));
  return true;
});
ipcMain.handle('secret-get', (_event, key) => {
  const value = readSecrets()[key];
  return value ? safeStorage.decryptString(Buffer.from(value, 'base64')) : '';
});

ipcMain.handle('mpv-play', async (_event, playback) => {
  const mediaUrl = new URL(playback.url);
  const serverUrl = new URL(playback.serverUrl);
  if (!['http:', 'https:'].includes(mediaUrl.protocol) || mediaUrl.origin !== serverUrl.origin) throw new Error('播放器地址不属于当前 Emby 服务器');
  if (mpvProcess) mpvProcess.kill();
  const mpv = app.isPackaged
    ? path.join(process.resourcesPath, 'app.asar.unpacked', 'app', 'mpv', 'mpv.exe')
    : path.join(__dirname, 'app', 'mpv', 'mpv.exe');
  if (!fs.existsSync(mpv)) throw new Error('未找到 mpv 播放器内核');
  const pipe = `\\\\.\\pipe\\yingji-mpv-${process.pid}-${Date.now()}`;
  const args = [
    `--input-ipc-server=${pipe}`,
    '--fullscreen',
    '--force-window=yes',
    `--force-media-title=${String(playback.title || '映迹').replace(/[\r\n]/g, ' ')}`,
    `--start=${Math.max(0, Number(playback.position || 0))}`,
    mediaUrl.href
  ];
  mpvProcess = spawn(mpv, args, { windowsHide: false, stdio: 'ignore' });
  const report = async (suffix, position, paused) => {
    try {
      await fetch(`${serverUrl.href.replace(/\/$/, '')}/Sessions/Playing${suffix}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Emby-Token': playback.token },
        body: JSON.stringify({ ItemId: playback.itemId, MediaSourceId: playback.mediaSourceId, PlaySessionId: playback.playSessionId, PositionTicks: Math.round((position || 0) * 10000000), IsPaused: !!paused, PlayMethod: 'DirectPlay' })
      });
    } catch {}
  };
  await report('', playback.position || 0, false);
  let position = Number(playback.position || 0), paused = false, lastReport = -1;
  const connect = attempt => new Promise((resolve, reject) => {
    const socket = net.connect(pipe, () => resolve(socket));
    socket.once('error', error => attempt < 30 ? setTimeout(() => connect(attempt + 1).then(resolve, reject), 200) : reject(error));
  });
  connect(0).then(socket => {
    socket.write('{"command":["observe_property",1,"time-pos"]}\n{"command":["observe_property",2,"pause"]}\n');
    let buffer = '';
    socket.on('data', chunk => {
      buffer += chunk.toString();
      const lines = buffer.split('\n'); buffer = lines.pop();
      for (const line of lines) try {
        const message = JSON.parse(line);
        if (message.event === 'property-change' && message.name === 'time-pos' && Number.isFinite(message.data)) position = message.data;
        if (message.event === 'property-change' && message.name === 'pause') paused = message.data;
        const second = Math.floor(position);
        if (second > 0 && second % 10 === 0 && second !== lastReport) { lastReport = second; report('/Progress', position, paused); }
      } catch {}
    });
  }).catch(() => {});
  mpvProcess.once('exit', () => { report('/Stopped', position, paused); mpvProcess = null; });
  return true;
});

app.whenReady().then(() => {
  createWindow();
  app.on('activate', () => BrowserWindow.getAllWindows().length || createWindow());
});
app.on('window-all-closed', () => process.platform === 'darwin' || app.quit());
