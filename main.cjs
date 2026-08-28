const { app, BrowserWindow, ipcMain, safeStorage, shell } = require('electron');
const path = require('node:path');
const fs = require('node:fs');
const net = require('node:net');
const { spawn } = require('node:child_process');
let mpvProcess;
const mpvControls = [
  '--osd-font=Segoe UI Variable', '--osd-font-size=22', '--osd-bold=yes',
  '--osd-color=#F7F8FC', '--osd-border-size=0', '--osd-shadow-offset=0',
  '--osd-margin-x=30', '--osd-margin-y=30', '--osd-on-seek=no'
];
const mpvExecutable = () => app.isPackaged
  ? path.join(process.resourcesPath, 'app.asar.unpacked', 'app', 'mpv', 'mpv.exe')
  : path.join(__dirname, 'app', 'mpv', 'mpv.exe');
const launchMpv = async args => {
  const mpv = mpvExecutable();
  if (!fs.existsSync(mpv)) throw new Error('未找到 mpv 播放器内核');
  const child = spawn(mpv, args, { cwd:path.dirname(mpv), windowsHide:false, stdio:['ignore', 'ignore', 'pipe'] });
  let stderr = '';
  child.stderr.on('data', chunk => { stderr = `${stderr}${chunk}`.slice(-2000); });
  child.getLaunchError = () => stderr.trim();
  await new Promise((resolve, reject) => { child.once('spawn', resolve); child.once('error', error => reject(new Error(`播放器启动失败：${error.message}`))); });
  await new Promise((resolve, reject) => {
    const onExit = code => { clearTimeout(timer); reject(new Error(stderr.trim() || `mpv 启动后立即退出（代码 ${code ?? '未知'}）`)); };
    const timer = setTimeout(() => { child.off('exit', onExit); resolve(); }, 700);
    child.once('exit', onExit);
  });
  return child;
};

// Translate the renderer-side playback settings into mpv CLI flags.
const mpvSettingArgs = playback => {
  const args = [];
  const renderer = playback.renderer || 'gpu-next';
  const hwdec = playback.hwdec || 'auto-safe';
  const gpu = playback.gpu || '';
  if (renderer) args.push(`--vo=${renderer}`);
  if (hwdec) args.push(`--hwdec=${hwdec}`);
  if (gpu) args.push(`--d3d11-adapter=${gpu}`);
  if (playback.downmix) args.push('--audio-channels=stereo');
  if (playback.subtitleEnabled === false) args.push('--sub-visibility=no');
  else {
    if (playback.subtitleLanguage && playback.subtitleLanguage !== 'auto') args.push(`--slang=${playback.subtitleLanguage}`);
    if (playback.subtitleScale && playback.subtitleScale !== '100') args.push(`--sub-scale=${Number(playback.subtitleScale) / 100}`);
  }
  const filters = [];
  if (playback.vocal) filters.push('lavfi=[highpass=f=80,equalizer=f=1000:t=q:w=1.5:g=6,equalizer=f=2800:t=q:w=1.5:g=4]');
  if (playback.night) filters.push('lavfi=[dynaudnorm=f=200:g=15:p=0.85]');
  if (filters.length) args.push(`--af=${filters.join(',')}`);
  return args;
};

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
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https:\/\/(www\.)?(youtube\.com|trakt\.tv)\//.test(url)) shell.openExternal(url);
    return { action: 'deny' };
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
      body: request.rawBody ?? (request.body ? JSON.stringify(request.body) : undefined),
      signal: controller.signal
    });
    const text = await response.text();
    const data = request.responseType === 'text' ? text : text ? JSON.parse(text) : null;
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

const assTime = value => {
  const seconds = Math.max(0, Number(value) || 0), hours = Math.floor(seconds / 3600), minutes = Math.floor(seconds % 3600 / 60);
  return `${hours}:${String(minutes).padStart(2, '0')}:${(seconds % 60).toFixed(2).padStart(5, '0')}`;
};
const assEscape = value => String(value || '').replace(/\\/g, '\\\\').replace(/[{}]/g, match => `\\${match}`).replace(/[\r\n]+/g, ' ');
const parseDanmaku = raw => {
  const xml = [...String(raw || '').matchAll(/<d\s+[^>]*p="([^"]+)"[^>]*>([\s\S]*?)<\/d>/gi)].map(match => ({ time:Number(match[1].split(',')[0]), text:match[2].replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>') }));
  if (xml.length) return xml;
  try {
    const data = JSON.parse(raw), list = Array.isArray(data) ? data : data.comments || data.data || [];
    return list.map(item => ({ time:Number(item.time ?? item.progress ?? item.t), text:item.text ?? item.content ?? item.m ?? '' })).filter(item => Number.isFinite(item.time) && item.text);
  } catch { return []; }
};
const createDanmakuSubtitle = playback => {
  const comments = parseDanmaku(playback.danmaku);
  if (!comments.length) return '';
  const size = playback.danmakuDensity === 'high' ? 30 : playback.danmakuDensity === 'low' ? 24 : 27;
  const lines = comments.slice(0, 1500).map((item, index) => `Dialogue: 0,${assTime(item.time)},${assTime(item.time + 5)},Danmaku,,0,0,0,,{\\move(1920,${80 + (index % 8) * 74},-500,${80 + (index % 8) * 74})}${assEscape(item.text)}`);
  const file = path.join(app.getPath('temp'), `yingji-danmaku-${Date.now()}.ass`);
  const header = `[Script Info]\nScriptType: v4.00+\nPlayResX: 1920\nPlayResY: 1080\n\n[V4+ Styles]\nFormat: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding\nStyle: Danmaku,Segoe UI,${size},&H00FFFFFF,&H00FFFFFF,&H80000000,&H80000000,0,0,0,0,100,100,0,0,1,1.5,0,7,20,20,20,1\n\n[Events]\nFormat: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text\n`;
  fs.writeFileSync(file, `${header}${lines.join('\n')}`, 'utf8');
  return file;
};

ipcMain.handle('mpv-play', async (event, playback) => {
  const sender = event.sender;
  const mediaUrl = new URL(playback.url);
  const serverUrl = new URL(playback.serverUrl);
  if (!['http:', 'https:'].includes(mediaUrl.protocol) || mediaUrl.origin !== serverUrl.origin) throw new Error('播放器地址不属于当前 Emby 服务器');
  if (mpvProcess) mpvProcess.kill();
  const pipe = `\\\\.\\pipe\\yingji-mpv-${process.pid}-${Date.now()}`;
  const danmakuFile = playback.danmakuEnabled ? createDanmakuSubtitle(playback) : '';
  const args = [
    `--input-ipc-server=${pipe}`,
    '--fullscreen',
    '--force-window=yes',
    ...mpvControls,
    ...mpvSettingArgs(playback),
    `--force-media-title=${String(playback.title || '映迹').replace(/[\r\n]/g, ' ')}`,
    `--start=${Math.max(0, Number(playback.position || 0))}`,
    `--http-header-fields=X-Emby-Token: ${playback.token}`,
    ...(danmakuFile ? [`--sub-file=${danmakuFile}`] : []),
    mediaUrl.href
  ];
  mpvProcess = await launchMpv(args);
  const report = async (suffix, position, paused) => {
    try {
      await fetch(`${serverUrl.href.replace(/\/$/, '')}/Sessions/Playing${suffix}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Emby-Token': playback.token },
        body: JSON.stringify({ ItemId: playback.itemId, MediaSourceId: playback.mediaSourceId, PlaySessionId: playback.playSessionId, PositionTicks: Math.round((position || 0) * 10000000), IsPaused: !!paused, PlayMethod: 'DirectPlay' })
      });
    } catch {}
  };
  const mediaInfo = { video: null, audio: null, fps: null, bitrate: null };
  const sendMediaInfo = () => { try { sender.send('mpv-media-info', { ...mediaInfo }); } catch {} };
  let position = Number(playback.position || 0), paused = false, lastReport = -1;
  const connect = attempt => new Promise((resolve, reject) => {
    const socket = net.connect(pipe, () => resolve(socket));
    socket.once('error', error => attempt < 30 ? setTimeout(() => connect(attempt + 1).then(resolve, reject), 200) : reject(error));
  });
  await report('', playback.position || 0, false);
  connect(0).then(socket => {
    socket.write('{"command":["observe_property",1,"time-pos"]}\n{"command":["observe_property",2,"pause"]}\n{"command":["observe_property",3,"video-params"]}\n{"command":["observe_property",4,"audio-params"]}\n{"command":["observe_property",5,"estimated-vf-fps"]}\n{"command":["observe_property",6,"bitrate"]}\n');
    let buffer = '';
    socket.on('data', chunk => {
      buffer += chunk.toString();
      const lines = buffer.split('\n'); buffer = lines.pop();
      for (const line of lines) try {
        const message = JSON.parse(line);
        if (message.event !== 'property-change') continue;
        if (message.name === 'time-pos' && Number.isFinite(message.data)) position = message.data;
        else if (message.name === 'pause') paused = message.data;
        else if (message.name === 'video-params') { mediaInfo.video = message.data; sendMediaInfo(); }
        else if (message.name === 'audio-params') { mediaInfo.audio = message.data; sendMediaInfo(); }
        else if (message.name === 'estimated-vf-fps') { mediaInfo.fps = message.data; sendMediaInfo(); }
        else if (message.name === 'bitrate') { mediaInfo.bitrate = message.data; sendMediaInfo(); }
        const second = Math.floor(position);
        if (second > 0 && second % 10 === 0 && second !== lastReport) { lastReport = second; report('/Progress', position, paused); }
      } catch {}
    });
  }).catch(() => {});
  mpvProcess.once('exit', () => { report('/Stopped', position, paused); if (danmakuFile) fs.rmSync(danmakuFile, { force:true }); sender.send('mpv-media-info', { ended: true }); mpvProcess = null; });
  return true;
});

ipcMain.handle('mpv-open-url', async (_event, playback) => {
  const mediaUrl = new URL(playback.url);
  if (!['http:', 'https:'].includes(mediaUrl.protocol)) throw new Error('仅支持 HTTP 或 HTTPS 媒体地址');
  if (mpvProcess) mpvProcess.kill();
  const args = ['--fullscreen', '--force-window=yes', ...mpvControls, ...mpvSettingArgs(playback), `--force-media-title=${String(playback.title || '映迹').replace(/[\r\n]/g, ' ')}`];
  if (playback.authorization && /^Basic [A-Za-z0-9+/=]+$/.test(playback.authorization)) args.push(`--http-header-fields=Authorization: ${playback.authorization}`);
  args.push(mediaUrl.href);
  mpvProcess = await launchMpv(args);
  mpvProcess.once('exit', () => { mpvProcess = null; });
  return true;
});

// Enumerate D3D11 GPUs so the user can pin mpv to a specific adapter.
ipcMain.handle('mpv-adapters', async () => {
  const mpv = mpvExecutable();
  if (!fs.existsSync(mpv)) return [];
  return new Promise(resolve => {
    const child = spawn(mpv, ['--vo=gpu-next', '--d3d11-adapter=help'], { cwd: path.dirname(mpv), windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    child.stdout.on('data', chunk => { out += chunk.toString(); });
    child.stderr.on('data', chunk => { out += chunk.toString(); });
    child.once('close', () => {
      const adapters = [];
      for (const raw of out.split('\n')) {
        const line = raw.trim();
        let name = null;
        const m = line.match(/^\d+\s*:\s*(.+)$/);
        if (m) name = m[1].trim();
        else { const m2 = line.match(/Adapter\s+\d+\s*:\s*(.+)$/i); if (m2) name = m2[1].trim(); }
        if (name && !adapters.includes(name)) adapters.push(name);
      }
      resolve(adapters);
    });
    child.once('error', () => resolve([]));
  });
});

app.whenReady().then(() => {
  createWindow();
  app.on('activate', () => BrowserWindow.getAllWindows().length || createWindow());
});
app.on('window-all-closed', () => process.platform === 'darwin' || app.quit());
