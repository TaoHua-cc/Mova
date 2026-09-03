const { app, BrowserWindow, ipcMain, safeStorage, shell, nativeImage, net: electronNet } = require('electron');
const path = require('node:path');
const fs = require('node:fs');
const net = require('node:net');
const { spawn } = require('node:child_process');
const { apiRequest } = require('./app/host/api-request.cjs');
const { createSecretStore } = require('./app/host/secret-store.cjs');
const { createMpvLauncher } = require('./app/host/mpv-process.cjs');
let mpvProcess,mpvSocket,mainWindow,pipRestoreBounds,clipStart,mpvOwnHwnd=0,mpvTitleToken='',electronOwnerHwnd=0;
// Danmaku matching can finish before mpv has opened its IPC pipe. Preserve the
// newest update until that pipe is ready rather than dropping the first result.
let pendingMpvUpdate = null;
// Mirrors of the live player, kept at module scope so the console can read the
// current state the moment it opens instead of waiting for the next change.
let currentPlaybackState = null;
let currentMediaInfo = null;
const dynamicDanmakuFiles=new Set();
const secretStore = createSecretStore({ app, safeStorage, fs, path });
const mpvControls = [
  '--osd-font=Segoe UI Variable', '--osd-font-size=22', '--osd-bold=yes', '--osd-level=1',
  '--osd-color=#F7F8FC', '--osd-border-size=0', '--osd-shadow-offset=0',
  '--osd-margin-x=30', '--osd-margin-y=30', '--osd-on-seek=no'
];
const mpvExecutable = () => app.isPackaged
  ? path.join(process.resourcesPath, 'app.asar.unpacked', 'app', 'mpv', 'mpv.exe')
  : path.join(__dirname, 'app', 'mpv', 'mpv.exe');
const mpvPortableArgs = () => {
  const root = path.join(path.dirname(mpvExecutable()), 'portable_config');
  return ['--no-config', `--include=${path.join(root, 'mpv.conf')}`, `--script=${path.join(root, 'scripts', 'yingji-osc.lua')}`];
};

const redactMpvLog = value => String(value || '')
  .replace(/https?:\/\/\S+/gi, '<media-url>')
  .replace(/(X-Emby-Token|Authorization):[^\r\n,]*/gi, '$1: <redacted>')
  .replace(/(api_key|token)=[^&\s]+/gi, '$1=<redacted>');
const appendMpvLog = line => {
  try {
    const file = path.join(app.getPath('userData'), 'mpv-last.log');
    fs.appendFileSync(file, `[${new Date().toISOString()}] ${redactMpvLog(line)}\n`, 'utf8');
  } catch {}
};
const launchMpv = createMpvLauncher({
  resolveExecutable: mpvExecutable,
  fs,
  path,
  spawn,
  appendLog: line => appendMpvLog(redactMpvLog(line)),
  isCurrent: child => child === null ? (mpvProcess = null, true) : mpvProcess === child
});

// Translate the renderer-side playback settings into mpv CLI flags.
const mpvSettingArgs = playback => {
  const args = [];
  const renderer = playback.renderer || 'gpu-next';
  const hwdec = playback.hardware === false ? 'no' : (playback.hwdec || 'auto-safe');
  const gpu = playback.gpu || '';
  if (renderer) args.push(`--vo=${renderer}`);
  if (hwdec) args.push(`--hwdec=${hwdec}`);
  if (gpu) args.push(`--d3d11-adapter=${gpu}`);
  if (playback.hdr === false) args.push('--target-colorspace-hint=no');
  if (playback.downmix) args.push('--audio-channels=stereo');
  if (playback.subtitleEnabled === false) args.push('--sub-visibility=no');
  else {
    if (playback.subtitleLanguage && playback.subtitleLanguage !== 'auto') args.push(`--slang=${playback.subtitleLanguage}`);
    if (Number.isFinite(Number(playback.subtitleScale))) args.push(`--sub-scale=${Math.max(.7, Math.min(1.6, Number(playback.subtitleScale)))}`);
  }
  const filters = [];
  if (playback.vocal) filters.push('lavfi=[highpass=f=80,equalizer=f=1000:t=q:w=1.5:g=6,equalizer=f=2800:t=q:w=1.5:g=4]');
  if (playback.night) filters.push('lavfi=[dynaudnorm=f=200:g=15:p=0.85]');
  if (filters.length) args.push(`--af=${filters.join(',')}`);
  if (Number.isFinite(Number(playback.speed))) args.push(`--speed=${Math.max(.25, Math.min(3, Number(playback.speed)))}`);
  if (Number.isFinite(Number(playback.audioDelay))) args.push(`--audio-delay=${Math.max(-10, Math.min(10, Number(playback.audioDelay)))}`);
  if (Number.isFinite(Number(playback.subtitlePos))) args.push(`--sub-pos=${Math.max(0, Math.min(100, Number(playback.subtitlePos)))}`);
  if (Number.isFinite(Number(playback.subtitleDelay))) args.push(`--sub-delay=${Math.max(-10, Math.min(10, Number(playback.subtitleDelay)))}`);
  if (Number.isFinite(Number(playback.subtitleBorder))) args.push(`--sub-border-size=${Math.max(0, Math.min(6, Number(playback.subtitleBorder)))}`);
  if (['16:9','4:3','2.35:1'].includes(playback.videoAspect)) args.push(`--video-aspect-override=${playback.videoAspect}`);
  if (Number.isFinite(Number(playback.videoZoom))) args.push(`--video-zoom=${Math.max(0, Math.min(2, Number(playback.videoZoom)))}`);
  if ([0,90,180,270].includes(Number(playback.videoRotate))) args.push(`--video-rotate=${Number(playback.videoRotate)}`);
  if (playback.loopFile) args.push('--loop-file=inf');
  return args;
};

// mpv renders in its OWN top-level window (--force-window=yes) and carries the
// full V9 console itself: yingji-osc.lua draws the production OSC (transport,
// volume, settings panels, episode picker) inside the mpv window, so there is
// no Electron overlay anymore. The frameless mpv window is first glued to the
// app window geometry via a tiny Win32 helper, then the app window hides for
// the duration of playback and is shown again when mpv exits.
const MPV_TITLE_MARK = 'YINGJI_MPV_';
const mpvSync = { timer:null, pending:null };
const mpvGluePsPath = () => app.isPackaged
  ? path.join(process.resourcesPath, 'app.asar.unpacked', 'app', 'mpv', 'win32-glue.ps1')
  : path.join(__dirname, 'app', 'mpv', 'win32-glue.ps1');
const getElectronHwnd = win => {
  if (!win || win.isDestroyed()) return 0;
  try { return Number(win.getNativeWindowHandle().readBigUInt64LE()); } catch { return 0; }
};
const runMpvWin32 = (action, bounds) => new Promise(resolve => {
  let ps;
  try { ps = mpvGluePsPath(); } catch { return resolve(0); }
  if (!ps || !ps.length || !fs.existsSync(ps)) return resolve(0);
  const args = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ps, '-Token', mpvTitleToken, '-Action', action];
  if (bounds) args.push('-X', String(bounds.x), '-Y', String(bounds.y), '-W', String(bounds.width), '-H', String(bounds.height));
  if (mpvOwnHwnd) args.push('-RawHwnd', String(mpvOwnHwnd));
  if (electronOwnerHwnd) args.push('-OwnerHwnd', String(electronOwnerHwnd));
  const child = spawn('powershell.exe', args, { windowsHide:true, stdio:['ignore', 'pipe', 'pipe'] });
  let out = '';
  child.stdout.on('data', d => { out += d.toString(); });
  child.once('close', () => { const m = out.trim().match(/\d+/); const hwnd = m ? parseInt(m[0], 10) : 0; if (hwnd) mpvOwnHwnd = hwnd; resolve(hwnd); });
  child.once('error', () => resolve(0));
});
const syncMpvOwnWindow = win => {
  if (!win || win.isDestroyed() || !mpvProcess || mpvProcess.killed || !mpvTitleToken) return;
  electronOwnerHwnd = getElectronHwnd(win);
  const bounds = win.getBounds();
  mpvSync.pending = bounds;
  if (mpvSync.timer) return;
  mpvSync.timer = setTimeout(() => {
    mpvSync.timer = null;
    const job = mpvSync.pending;
    mpvSync.pending = null;
    if (!job) return;
    runMpvWin32('move', job).catch(() => {});
  }, 90);
};
const setMpvWindowVisible = visible => { if (mpvTitleToken) runMpvWin32(visible ? 'show' : 'hide', null).catch(() => {}); };
const applyPlayerOnTop = (win, onTop) => {
  if (win && !win.isDestroyed()) { try { win.setAlwaysOnTop(!!onTop, 'floating'); } catch {} }
  if (mpvSocket && !mpvSocket.destroyed) { try { mpvSocket.write(JSON.stringify({ command:['set_property', 'ontop', !!onTop] }) + '\n'); } catch {} }
};

function createWindow() {
  const win = new BrowserWindow({
    width: 1440,
    height: 920,
    minWidth: 1024,
    minHeight: 680,
    frame: false,
    transparent: true,
    backgroundColor: '#00000000',
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });
  mainWindow = win;
  const sync = () => syncMpvOwnWindow(win);
  for (const event of ['move','resize','restore','maximize','unmaximize','enter-full-screen','leave-full-screen','show','focus']) win.on(event, sync);
  win.on('minimize', () => { try { setMpvWindowVisible(false); } catch {} });
  win.on('hide', () => { try { setMpvWindowVisible(false); } catch {} });
  const sendFullscreen = () => { try { win.webContents.send('window-fullscreen-changed', win.isFullScreen()); } catch {} };
  win.on('enter-full-screen', sendFullscreen);
  win.on('leave-full-screen', sendFullscreen);
  win.on('closed', () => {
    if (mainWindow === win) mainWindow = null;
    try { if (mpvProcess && !mpvProcess.killed) mpvProcess.kill(); } catch {}
    mpvProcess = null;
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
ipcMain.handle('window-fullscreen-set', (event, requested) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  if (!win) return false;
  const next = typeof requested === 'boolean' ? requested : !win.isFullScreen();
  win.setFullScreen(next);
  if (mpvSocket && !mpvSocket.destroyed) { try { mpvSocket.write(JSON.stringify({ command:['set_property', 'fullscreen', next] }) + '\n'); } catch {} }
  syncMpvOwnWindow(win);
  return next;
});
ipcMain.handle('window-ontop-set', (event, requested) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  if (!win) return false;
  const next = !!requested;
  applyPlayerOnTop(win, next);
  return next;
});
ipcMain.handle('window-pip-set', (event, requested) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  if (!win) return false;
  const next = !!requested;
  if (next) {
    if (!pipRestoreBounds) pipRestoreBounds = win.getBounds();
    const display = require('electron').screen.getDisplayMatching(win.getBounds()).workArea;
    const width = Math.min(560, Math.max(420, Math.round(display.width * .27)));
    const height = Math.round(width * 9 / 16);
    win.setBounds({ x:display.x + display.width - width - 24, y:display.y + display.height - height - 24, width, height });
    win.setAlwaysOnTop(true, 'floating');
  } else {
    if (pipRestoreBounds) win.setBounds(pipRestoreBounds);
    pipRestoreBounds = null;
    win.setAlwaysOnTop(true, 'floating'); // still playing: keep console above mpv
  }
  syncMpvOwnWindow(win);
  return next;
});

ipcMain.handle('api-request', (_event, request) => apiRequest(request, { electronNet }));
ipcMain.handle('secret-set', (_event, key, value) => secretStore.set(key, value));
ipcMain.handle('secret-get', (_event, key) => secretStore.get(key));

const assTime = value => {
  const seconds = Math.max(0, Number(value) || 0), hours = Math.floor(seconds / 3600), minutes = Math.floor(seconds % 3600 / 60);
  return `${hours}:${String(minutes).padStart(2, '0')}:${(seconds % 60).toFixed(2).padStart(5, '0')}`;
};
const assEscape = value => String(value || '').replace(/\\/g, '\\\\').replace(/[{}]/g, match => `\\${match}`).replace(/[\r\n]+/g, ' ');
const parseDanmaku = raw => {
  if (Array.isArray(raw)) return raw.flatMap(parseDanmaku);
  if (raw && typeof raw === 'object') {
    const point = typeof raw.p === 'string' ? raw.p.split(',')[0] : raw.p ?? raw.time ?? raw.progress ?? raw.t ?? raw.start ?? raw.startTime ?? raw.start_ms ?? raw.startMs ?? raw.start_sec ?? raw.startSec ?? raw.timestamp ?? raw.timestamp_ms;
    const text = raw.text ?? raw.content ?? raw.m ?? raw.message ?? raw.comment ?? raw.value ?? raw.body ?? raw.msg ?? raw.textContent;
    const seconds = Number(point);
    if (text != null && Number.isFinite(seconds)) return [{ time:Math.abs(seconds) > 100000 ? seconds / 1000 : seconds, text:String(text) }];
    const list = raw.comments ?? raw.danmaku ?? raw.items ?? raw.events ?? raw.list ?? raw.results ?? raw.data?.comments ?? raw.data?.danmaku ?? raw.data?.items ?? raw.data?.events ?? raw.data?.list ?? raw.data?.results ?? raw.data ?? raw.result;
    return Array.isArray(list) ? list.flatMap(parseDanmaku) : list ? parseDanmaku(list) : [];
  }
  const source=String(raw || '').replace(/^\uFEFF/, '').trim();
  const xml = [...source.matchAll(/<d\b[^>]*\bp\s*=\s*(["'])([^"']+)\1[^>]*>([\s\S]*?)<\/d>/gi)].map(match => ({ time:Number(match[2].split(',')[0]), text:match[3].replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'") }));
  if (xml.length) return xml;
  try {
    const data = JSON.parse(source);
    return parseDanmaku(data);
  } catch {
    const lines=source.split(/\r?\n/).map(line => line.trim()).filter(Boolean);
    if (lines.length > 1) return lines.flatMap(line => { try { return parseDanmaku(JSON.parse(line)); } catch { return []; } });
    return [];
  }
};
const createDanmakuSubtitle = playback => {
  const seen = new Set();
  const comments = parseDanmaku(playback.danmaku)
    .map(item => ({ time:Math.max(0, Number(item?.time) || 0), text:String(item?.text || '').trim() }))
    .filter(item => item.text && Number.isFinite(item.time))
    .sort((left, right) => left.time - right.time)
    .filter(item => {
      const key=`${item.time.toFixed(3)}\u0000${item.text}`;
      if (seen.has(key)) return false;
      seen.add(key); return true;
    });
  if (!comments.length) return { file:'', count:0 };
  const density = playback.danmakuDensity === 'high' ? 30 : playback.danmakuDensity === 'low' ? 24 : 27;
  const fontScale = Math.max(70, Math.min(160, Number(playback.danmakuFontScale) || 100));
  const opacity = Math.max(20, Math.min(100, Number(playback.danmakuOpacity) || 86));
  const alpha = Math.round(255 * (1 - opacity / 100)).toString(16).padStart(2, '0').toUpperCase();
  const duration = Math.max(2, Math.min(12, Number(playback.danmakuDuration) || 5));
  const maxCount = Math.max(100, Math.min(5000, Number(playback.danmakuMaxCount) || 1500));
  const outline = String(playback.danmakuOutline || 'soft');
  const outlineSize = outline === 'none' ? 0 : outline === 'strong' ? 2.4 : 1.5;
  const size = Math.round(density * fontScale / 100);
  const mode = String(playback.danmakuMode || 'smart');
  const rowBase = mode === 'bottom' ? 700 : 80;
  const rowCount = mode === 'smart' ? 8 : 4;
  const lines = comments.slice(0, maxCount).map((item, index) => {
    const time = Math.max(0, Number(item.time) || 0), y = rowBase + (index % rowCount) * (size + 42);
    return `Dialogue: 0,${assTime(time)},${assTime(time + duration)},Danmaku,,0,0,0,,{\\move(1920,${y},-500,${y})}${assEscape(item.text)}`;
  });
  const file = path.join(app.getPath('temp'), `yingji-danmaku-${Date.now()}.ass`);
  const header = `[Script Info]\nScriptType: v4.00+\nPlayResX: 1920\nPlayResY: 1080\n\n[V4+ Styles]\nFormat: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding\nStyle: Danmaku,Segoe UI,${size},&H${alpha}FFFFFF,&H${alpha}FFFFFF,&H80000000,&H80000000,0,0,0,0,100,100,0,0,1,${outlineSize},0,7,20,20,20,1\n\n[Events]\nFormat: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text\n`;
  fs.writeFileSync(file, `${header}${lines.join('\n')}`, 'utf8');
  return { file, count:comments.length };
};

const prepareEpisodeThumbnails = async (options, currentEpisode) => {
  const files = [];
  const nearest = options
    .filter(option => option.itemId && option.serverUrl && option.token)
    .sort((left, right) => Math.abs(Number(left.episode || 0) - Number(currentEpisode || 0)) - Math.abs(Number(right.episode || 0) - Number(currentEpisode || 0)))
    .slice(0, 6);
  await Promise.all(nearest.map(async option => {
    const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 700);
    try {
      const url = new URL(`${String(option.serverUrl).replace(/\/$/, '')}/Items/${encodeURIComponent(option.itemId)}/Images/Primary`);
      url.searchParams.set('maxWidth', '320'); url.searchParams.set('quality', '82'); url.searchParams.set('api_key', option.token);
      const response = await electronNet.fetch(url.href, { signal:controller.signal, headers:{ 'X-Emby-Token':option.token } });
      if (!response.ok) return;
      const original = nativeImage.createFromBuffer(Buffer.from(await response.arrayBuffer()));
      if (original.isEmpty()) return;
      const originalSize=original.getSize(),targetRatio=272/112,sourceRatio=originalSize.width/originalSize.height;
      const scaled=sourceRatio>=targetRatio ? original.resize({height:112,quality:'best'}) : original.resize({width:272,quality:'best'});
      const scaledSize=scaled.getSize(),image=scaled.crop({x:Math.max(0,Math.floor((scaledSize.width-272)/2)),y:Math.max(0,Math.floor((scaledSize.height-112)/2)),width:272,height:112});
      if (image.isEmpty()) return;
      const size = image.getSize(), file = path.join(app.getPath('temp'), `yingji-episode-${process.pid}-${Date.now()}-${option.episode}.bgra`);
      const bitmap = image.toBitmap({ scaleFactor:1 });
      const radius = 12;
      for (let y = 0; y < size.height; y += 1) for (let x = 0; x < size.width; x += 1) {
        const cornerX = x < radius ? radius - x : x >= size.width - radius ? x - (size.width - radius - 1) : 0;
        const cornerY = y < radius ? radius - y : y >= size.height - radius ? y - (size.height - radius - 1) : 0;
        if (cornerX && cornerY && cornerX * cornerX + cornerY * cornerY > radius * radius) bitmap[(y * size.width + x) * 4 + 3] = 0;
      }
      fs.writeFileSync(file, bitmap); files.push(file);
      option.thumbnail = { file, width:size.width, height:size.height, stride:size.width * 4 };
    } catch {} finally { clearTimeout(timer); }
  }));
  return files;
};
const preparePlayerLogo = async value => {
  const urls=[...(Array.isArray(value) ? value : [value])].filter(Boolean);
  for (const url of urls) {
    const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),1200);
    try {
      const response=await electronNet.fetch(url,{signal:controller.signal}); if (!response.ok) continue;
      const original=nativeImage.createFromBuffer(Buffer.from(await response.arrayBuffer())); if (original.isEmpty()) continue;
      const originalSize=original.getSize();
      const scale=Math.min(1,360/originalSize.width,58/originalSize.height);
      const width=Math.max(1,Math.round(originalSize.width*scale)),height=Math.max(1,Math.round(originalSize.height*scale));
      const image=original.resize({width,height,quality:'best'}),size=image.getSize(),file=path.join(app.getPath('temp'),`yingji-logo-${process.pid}-${Date.now()}.bgra`);
      fs.writeFileSync(file,image.toBitmap({scaleFactor:1})); return {file,width:size.width,height:size.height,stride:size.width*4};
    } catch {} finally { clearTimeout(timer); }
  }
  return null;
};
const deliverMpvUpdate = update => {
  if (!mpvSocket || mpvSocket.destroyed || !['danmaku','episode-data'].includes(update?.type)) return false;
  const created=createDanmakuSubtitle({danmaku:update.danmaku,danmakuDensity:update.density,danmakuMode:update.mode,danmakuFontScale:update.fontScale,danmakuOpacity:update.opacity,danmakuDuration:update.duration,danmakuMaxCount:update.maxCount,danmakuOutline:update.outline});
  if (created.file) dynamicDanmakuFiles.add(created.file);
  const sources=(Array.isArray(update.sources)?update.sources:[]).map(source => ({ ...source, status:created.count===0 && String(source?.status || '').includes('已返回') ? '已返回但未识别弹幕' : source?.status }));
  const payload={type:update.type,file:created.file,count:created.count,sources,chapterRule:update.chapterRule || null,chapterKey:String(update.chapterKey || '')};
  mpvSocket.write(`${JSON.stringify({command:['set_property','user-data/yj-player-update',JSON.stringify(payload)]})}\n`); return true;
};
ipcMain.handle('mpv-player-update',(_event,update)=>{
  if (!['danmaku','episode-data'].includes(update?.type)) return false;
  if (deliverMpvUpdate(update)) return { delivered:true };
  pendingMpvUpdate=update;
  return { queued:true };
});

// ── Runtime transport channel ──────────────────────────────────────────────
// The renderer never touches the mpv socket directly. Every command and every
// property write is matched against a whitelist here, so a bad UI state can
// only ever be ignored — never turned into an arbitrary mpv instruction.
const MPV_VERBS = new Set(['cycle','add','multiply','seek','osd','stop','quit','playlist-next','playlist-prev','frame-step','frame-back-step','sub-seek','show-text','keypress','loadfile']);
const MPV_PROPERTIES = new Map([
  ['pause','boolean'],['volume','number'],['mute','boolean'],['speed','number'],
  ['time-pos','number'],['percent-pos','number'],['audio-delay','number'],
  ['aid','track'],['sid','track'],['secondary-sid','track'],['sub-visibility','boolean'],
  ['sub-delay','number'],['sub-pos','number'],['sub-scale','number'],
  ['video-aspect','string'],['video-zoom','number'],['video-rotate','number'],
  ['loop-file','boolean'],['fullscreen','boolean'],['ontop','boolean'],
  ['af','string'],['audio-channels','string']
]);
const mpvCommandLine = payload => {
  if (!payload || typeof payload !== 'object') return null;
  if (Array.isArray(payload.command)) {
    const verb = String(payload.command[0] || '');
    if (!MPV_VERBS.has(verb)) return null;
    // Only accept primitive arguments; never allow nested arrays or objects.
    const args = payload.command.slice(1);
    if (args.some(arg => arg !== null && ['object','function','symbol'].includes(typeof arg))) return null;
    return `${JSON.stringify({ command: payload.command })}\n`;
  }
  if (payload.set && typeof payload.set.name === 'string') {
    const kind = MPV_PROPERTIES.get(payload.set.name);
    if (!kind) return null;
    const value = payload.set.value;
    if (kind === 'number' && (typeof value !== 'number' || !Number.isFinite(value))) return null;
    if (kind === 'boolean' && typeof value !== 'boolean') return null;
    if (kind === 'string' && typeof value !== 'string') return null;
    if (kind === 'track' && !['string','number','boolean'].includes(typeof value)) return null;
    return `${JSON.stringify({ command: ['set_property', payload.set.name, value] })}\n`;
  }
  return null;
};
ipcMain.handle('mpv-command',(_event,payload)=>{
  if (!mpvSocket || mpvSocket.destroyed) return { ok:false, reason:'no-player' };
  const line = mpvCommandLine(payload);
  if (!line) return { ok:false, reason:'blocked' };
  try { mpvSocket.write(line); return { ok:true }; }
  catch (error) { return { ok:false, reason:String(error?.message || 'write-failed') }; }
});
ipcMain.handle('mpv-state',()=>({ ok:!!(mpvSocket && !mpvSocket.destroyed), state:currentPlaybackState ? { ...currentPlaybackState } : null, info:currentMediaInfo ? { ...currentMediaInfo } : null }));
ipcMain.handle('mpv-capture', (_event, kind) => {
  if (!mpvSocket || mpvSocket.destroyed) return { ok:false, reason:'no-player' };
  const stamp = new Date().toISOString().replace(/[:.]/g,'-');
  if (kind === 'screenshot') {
    const dir = path.join(app.getPath('pictures'), '映迹');
    fs.mkdirSync(dir, { recursive:true });
    const file = path.join(dir, `映迹截图-${stamp}.png`);
    mpvSocket.write(`${JSON.stringify({ command:['screenshot-to-file',file,'subtitles'] })}\n`);
    return { ok:true, phase:'saved', file };
  }
  if (kind === 'clip') {
    const position = Number(currentPlaybackState?.timePos || 0);
    if (!Number.isFinite(position)) return { ok:false, reason:'no-position' };
    if (!Number.isFinite(clipStart)) {
      clipStart = position;
      mpvSocket.write(`${JSON.stringify({ command:['set_property','ab-loop-a',position] })}\n`);
      return { ok:true, phase:'start', position };
    }
    const dir = path.join(app.getPath('videos'), '映迹');
    fs.mkdirSync(dir, { recursive:true });
    const file = path.join(dir, `映迹片段-${stamp}.mkv`);
    mpvSocket.write(`${JSON.stringify({ command:['set_property','ab-loop-b',position] })}\n${JSON.stringify({ command:['ab-loop-dump-cache',file] })}\n`);
    clipStart = null;
    return { ok:true, phase:'saved', file };
  }
  return { ok:false, reason:'blocked' };
});

ipcMain.handle('mpv-play', async (event, playback) => {
  const sender = event.sender;
  const owner = BrowserWindow.fromWebContents(sender);
  clipStart = null;
  const mediaUrl = new URL(playback.url);
  const serverUrl = new URL(playback.serverUrl);
  if (!['http:', 'https:'].includes(mediaUrl.protocol) || mediaUrl.origin !== serverUrl.origin) throw new Error('播放器地址不属于当前 Emby 服务器');
  if (mpvProcess) mpvProcess.kill();
  mpvSocket=null;
  pendingMpvUpdate=null;
  const pipe = `\\\\.\\pipe\\yingji-mpv-${process.pid}-${Date.now()}`;
  const danmakuState = playback.danmakuEnabled ? createDanmakuSubtitle(playback) : { file:'', count:0 };
  const danmakuFile = danmakuState.file;
  const danmakuSourceInfo=(Array.isArray(playback.danmakuSourceInfo)?playback.danmakuSourceInfo:[]).map(source => ({ ...source, status:String(source?.status || '').includes('待解析') ? (danmakuState.count ? '已加载' : '已返回但未识别弹幕') : source?.status }));
  const resourceOptions = (Array.isArray(playback.resourceOptions) ? playback.resourceOptions : [])
    .filter(option => {
      try {
        const optionUrl = new URL(option?.url || ''), optionServer = new URL(option?.serverUrl || serverUrl.href);
        return ['http:', 'https:'].includes(optionUrl.protocol) && ['http:', 'https:'].includes(optionServer.protocol) && optionUrl.origin === optionServer.origin;
      } catch { return false; }
    })
    .slice(0, 32)
    .map(option => ({ ...option, url:String(option.url), label:String(option.label || '播放版本'), serverUrl:String(option.serverUrl || serverUrl.href), token:String(option.token || playback.token || '') }));
  if (!resourceOptions.some(option => option.url === mediaUrl.href)) resourceOptions.unshift({ url:mediaUrl.href, label:String(playback.resourceLabel || '当前播放版本'), serverUrl:serverUrl.href, token:String(playback.token || ''), itemId:playback.itemId, mediaSourceId:playback.mediaSourceId, playSessionId:playback.playSessionId || '' });
  const episodeOptions = (Array.isArray(playback.episodeOptions) ? playback.episodeOptions : [])
    .filter(option => {
      try {
        const optionUrl = new URL(option?.url || ''), optionServer = new URL(option?.serverUrl || serverUrl.href);
        return ['http:', 'https:'].includes(optionUrl.protocol) && ['http:', 'https:'].includes(optionServer.protocol) && optionUrl.origin === optionServer.origin;
      } catch { return false; }
    })
    .slice(0, 200)
    .map(option => ({
      ...option, url:String(option.url), label:String(option.label || '剧集'), serverUrl:String(option.serverUrl || serverUrl.href), token:String(option.token || playback.token || ''),
      resourceOptions:(Array.isArray(option.resourceOptions) ? option.resourceOptions : []).filter(resource => {
        try { const resourceUrl=new URL(resource?.url || ''), resourceServer=new URL(resource?.serverUrl || option.serverUrl || serverUrl.href); return ['http:','https:'].includes(resourceUrl.protocol) && resourceUrl.origin===resourceServer.origin; } catch { return false; }
      }).slice(0,32).map(resource => ({ ...resource, url:String(resource.url), label:String(resource.label || '播放版本'), serverUrl:String(resource.serverUrl || option.serverUrl || serverUrl.href), token:String(resource.token || option.token || playback.token || '') }))
    }));
  const [episodeThumbnailFiles, seriesLogoImage] = await Promise.all([
    prepareEpisodeThumbnails(episodeOptions, playback.episode),
    preparePlayerLogo(playback.seriesLogoUrls || playback.seriesLogoUrl)
  ]);
  const playerStateFile = path.join(app.getPath('temp'), `yingji-player-${process.pid}-${Date.now()}.json`);
  fs.writeFileSync(playerStateFile, JSON.stringify({
    seriesLogo: String(playback.seriesLogo || playback.title || '映迹').replace(/[\r\n]/g, ' '),
    seriesLogoImage,
    season: String(playback.season || ''),
    episode: String(playback.episode || ''),
    // Keep the episode label separate from the media/resource title. Falling
    // back to playback.title used to leak codec/bitrate text into the header.
    episodeName: String(playback.episodeName || '').replace(/[\r\n]/g, ' '),
    resourceOptions,
    resourceLabel:String(playback.resourceLabel || resourceOptions[0]?.label || '当前版本'),
    resourceDetails:resourceOptions.find(option => option.url===mediaUrl.href)?.details || resourceOptions[0]?.details || {},
    episodeOptions,
    danmakuCount: danmakuState.count,
    danmakuSources: Number(playback.danmakuSources || 0),
    danmakuEnabled: !!playback.danmakuEnabled,
    danmakuDensity: String(playback.danmakuDensity || 'normal'),
    danmakuMode: String(playback.danmakuMode || 'smart'),
    danmakuFontScale: Number(playback.danmakuFontScale || 100),
    danmakuOpacity: Number(playback.danmakuOpacity || 86),
    danmakuDuration: Number(playback.danmakuDuration || 5),
    danmakuMaxCount: Number(playback.danmakuMaxCount || 1500),
    danmakuOutline: String(playback.danmakuOutline || 'soft'),
    playerPreferenceKey:String(playback.playerPreferenceKey || ''),
    audioPreference:playback.audioPreference || null,
    subtitlePreference:playback.subtitlePreference || null,
    speed:Number(playback.speed || 1), audioDelay:Number(playback.audioDelay || 0), subtitleScale:Number(playback.subtitleScale || 1), subtitlePos:Number(playback.subtitlePos || 92), subtitleDelay:Number(playback.subtitleDelay || 0), subtitleBorder:Number(playback.subtitleBorder || 1.5), videoAspect:String(playback.videoAspect || 'auto'), videoZoom:Number(playback.videoZoom || 0), videoRotate:Number(playback.videoRotate || 0), loopFile:!!playback.loopFile, downmix:!!playback.downmix, vocal:!!playback.vocal, night:!!playback.night, hardware:playback.hardware !== false, hdr:playback.hdr !== false, hwdec:String(playback.hwdec || 'auto-safe'), renderer:String(playback.renderer || 'gpu-next'), gpu:String(playback.gpu || ''), gpuAdapters:Array.isArray(playback.gpuAdapters) ? playback.gpuAdapters.map(String).slice(0,16) : [],
    danmakuContext: playback.danmakuContext || null,
    danmakuSourceInfo:danmakuSourceInfo.slice(0,12),
    chapterKey:String(playback.chapterKey || ''), chapterRule:playback.chapterRule || null, chapterAutoSkip:playback.chapterAutoSkip !== false
  }), 'utf8');
  mpvTitleToken = `${MPV_TITLE_MARK}${process.pid}-${Date.now()}`;
  mpvOwnHwnd = 0; // force the first Win32 sync to re-enumerate by the new title token
  const ownerBounds = (owner && !owner.isDestroyed()) ? owner.getBounds() : { x:0, y:0, width:1280, height:720 };
  const args = [
    `--input-ipc-server=${pipe}`,
    ...mpvPortableArgs(),
    '--force-window=yes',
    '--no-border',
    `--title=${mpvTitleToken}`,
    `--geometry=${ownerBounds.width}x${ownerBounds.height}+${ownerBounds.x}+${ownerBounds.y}`,
    ...mpvControls,
    ...mpvSettingArgs(playback),
    `--force-media-title=${String(playback.title || '映迹').replace(/[\r\n]/g, ' ')}`,
    `--script-opts=yj-state-file=${playerStateFile},yj-headless=no`,
    `--start=${Math.max(0, Number(playback.position || 0))}`,
    `--http-header-fields=X-Emby-Token: ${playback.token}`,
    ...(danmakuFile ? [`--sub-file=${danmakuFile}`] : []),
    mediaUrl.href
  ];
  const connect = (child, attempt = 0) => new Promise((resolve, reject) => {
    if (!child || child.exitCode !== null || child.killed) {
      reject(new Error(child?.getLaunchError?.() || 'mpv 在播放窗口就绪前退出'));
      return;
    }
    const socket = net.connect(pipe);
    const onError = error => {
      socket.destroy();
      if (attempt < 30 && child.exitCode === null && !child.killed) setTimeout(() => connect(child, attempt + 1).then(resolve, reject), 200);
      else reject(new Error(child.getLaunchError?.() || error.message || '无法连接 mpv 控制通道'));
    };
    socket.once('error', onError);
    socket.once('connect', () => { socket.removeListener('error', onError); resolve(socket); });
  });
  const cleanupPreparedPlayer = () => {
    fs.rmSync(playerStateFile, { force:true });
    if (danmakuFile) fs.rmSync(danmakuFile, { force:true });
    for (const file of episodeThumbnailFiles) fs.rmSync(file, { force:true });
    if (seriesLogoImage?.file) fs.rmSync(seriesLogoImage.file,{force:true});
  };
  let startupError = null;
  try {
    mpvProcess = await launchMpv(args, 'primary');
    mpvSocket = await connect(mpvProcess);
  } catch (error) {
    startupError = error;
    try { if (mpvProcess && !mpvProcess.killed) mpvProcess.kill(); } catch {}
    mpvProcess = null; mpvSocket = null;
    // Retry with software decoding. Keep the fallback flags before the media
    // URL; mpv applies options positionally and flags appended after the URL
    // do not repair the file that already failed to open.
    const safeArgs = [...args.slice(0, -1).filter(argument => !/^--(?:vo|hwdec|d3d11-adapter)=/i.test(argument)), '--vo=gpu-next', '--hwdec=no', args.at(-1)];
    try {
      mpvProcess = await launchMpv(safeArgs, 'software-fallback');
      mpvSocket = await connect(mpvProcess);
    } catch (fallbackError) {
      try { if (mpvProcess && !mpvProcess.killed) mpvProcess.kill(); } catch {}
      mpvProcess = null; mpvSocket = null;
      cleanupPreparedPlayer();
      const detail = fallbackError?.message || startupError?.message || '未知错误';
      appendMpvLog(`startup failed detail=${detail}`);
      throw new Error(`播放器窗口启动失败：${redactMpvLog(detail)}`);
    }
  }
  let playbackContext = { serverUrl:serverUrl.href, token:String(playback.token || ''), itemId:playback.itemId, mediaSourceId:playback.mediaSourceId, playSessionId:playback.playSessionId || '' };
  const report = async (suffix, position, paused) => {
    const context = playbackContext;
    if (!context.serverUrl || !context.token || !context.itemId) return;
    try {
      await fetch(`${String(context.serverUrl).replace(/\/$/, '')}/Sessions/Playing${suffix}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Emby-Token': context.token },
        body: JSON.stringify({ ItemId: context.itemId, MediaSourceId: context.mediaSourceId, PlaySessionId: context.playSessionId, PositionTicks: Math.round((position || 0) * 10000000), IsPaused: !!paused, PlayMethod: 'DirectPlay' })
      });
    } catch {}
  };
  const mediaInfo = { video: null, audio: null, fps: null, bitrate: null };
  const sendMediaInfo = () => { currentMediaInfo = { ...mediaInfo }; try { sender.send('mpv-media-info', { ...mediaInfo }); } catch {} };
  let position = Number(playback.position || 0), paused = false, lastReport = -1;
  // Live transport + setting mirror for the in-app player console.
  const playbackState = {
    timePos:Number(playback.position || 0), duration:0, pause:false, volume:100, mute:false, speed:1,
    aid:null, sid:null, subDelay:0, subPos:100, subScale:1, audioDelay:0, audioChannels:'auto',
    videoZoom:0, videoRotate:0, videoAspect:'auto', loopFile:false, subVisibility:true,
    hwdec:'', vo:'', dropCount:0, tracks:[], chapters:[]
  };
  currentPlaybackState = playbackState;
  currentMediaInfo = { ...mediaInfo };
  let stateLastSent = 0, stateTimer = null;
  // time-pos fires roughly every frame; the console only needs ~2.5 Hz.
  const sendPlaybackState = immediate => {
    const flush = () => { stateTimer = null; stateLastSent = Date.now(); currentPlaybackState = { ...playbackState }; try { sender.send('mpv-playback-state', { ...playbackState }); } catch {} };
    if (stateTimer) { clearTimeout(stateTimer); stateTimer = null; }
    if (immediate) { flush(); return; }
    const wait = 400 - (Date.now() - stateLastSent);
    if (wait <= 0) { flush(); return; }
    stateTimer = setTimeout(flush, wait);
  };
  report('', playback.position || 0, false).catch(() => {});
  {
    const socket = mpvSocket;
    socket.on('error', error => appendMpvLog(`ipc error pid=${mpvProcess?.pid || 0} detail=${error.message}`));
    const observed = [
      'time-pos','pause','video-params','audio-params','estimated-vf-fps','bitrate',
      'user-data/yj-active','user-data/yj-player-action','duration','volume','mute','speed',
      'aid','sid','track-list','sub-delay','sub-pos','sub-scale','audio-delay','audio-channels',
      'video-zoom','video-rotate','video-aspect','loop-file','sub-visibility',
      'hwdec-current','current-vo','frame-drop-count','chapter-list'
    ];
    socket.write(observed.map((name, index) => JSON.stringify({ command: ['observe_property', index + 1, name] })).join('\n') + '\n');
    if (pendingMpvUpdate) {
      const update=pendingMpvUpdate; pendingMpvUpdate=null;
      deliverMpvUpdate(update);
    }
    let buffer = '';
    socket.on('data', chunk => {
      buffer += chunk.toString();
      const lines = buffer.split('\n'); buffer = lines.pop();
      for (const line of lines) try {
        const message = JSON.parse(line);
        if (message.event !== 'property-change') continue;
        const data = message.data;
        if (message.name === 'time-pos') { if (Number.isFinite(data)) { position = data; playbackState.timePos = data; } sendPlaybackState(false); }
        else if (message.name === 'pause') { paused = !!data; playbackState.pause = !!data; sendPlaybackState(true); }
        else if (message.name === 'duration') { playbackState.duration = Number.isFinite(data) ? data : 0; sendPlaybackState(true); }
        else if (message.name === 'volume') { playbackState.volume = Number.isFinite(data) ? data : 100; sendPlaybackState(true); }
        else if (message.name === 'mute') { playbackState.mute = !!data; sendPlaybackState(true); }
        else if (message.name === 'speed') { playbackState.speed = Number.isFinite(data) ? data : 1; sendPlaybackState(true); }
        else if (message.name === 'aid') { playbackState.aid = data; sendPlaybackState(true); }
        else if (message.name === 'sid') { playbackState.sid = data; sendPlaybackState(true); }
        else if (message.name === 'track-list') { playbackState.tracks = Array.isArray(data) ? data : []; sendPlaybackState(true); }
        else if (message.name === 'sub-delay') { playbackState.subDelay = Number(data) || 0; sendPlaybackState(true); }
        else if (message.name === 'sub-pos') { playbackState.subPos = Number(data) || 100; sendPlaybackState(true); }
        else if (message.name === 'sub-scale') { playbackState.subScale = Number(data) || 1; sendPlaybackState(true); }
        else if (message.name === 'audio-delay') { playbackState.audioDelay = Number(data) || 0; sendPlaybackState(true); }
        else if (message.name === 'audio-channels') { playbackState.audioChannels = String(data || 'auto'); sendPlaybackState(true); }
        else if (message.name === 'video-zoom') { playbackState.videoZoom = Number(data) || 0; sendPlaybackState(true); }
        else if (message.name === 'video-rotate') { playbackState.videoRotate = Number(data) || 0; sendPlaybackState(true); }
        else if (message.name === 'video-aspect') { playbackState.videoAspect = data === null ? 'auto' : String(data); sendPlaybackState(true); }
        else if (message.name === 'loop-file') { playbackState.loopFile = data === 'inf' || data === true; sendPlaybackState(true); }
        else if (message.name === 'sub-visibility') { playbackState.subVisibility = data !== false; sendPlaybackState(true); }
        else if (message.name === 'hwdec-current') { playbackState.hwdec = String(data || ''); sendPlaybackState(true); }
        else if (message.name === 'current-vo') { playbackState.vo = String(data || ''); sendPlaybackState(true); }
        else if (message.name === 'frame-drop-count') { playbackState.dropCount = Number(data) || 0; sendPlaybackState(true); }
        else if (message.name === 'chapter-list') { playbackState.chapters = Array.isArray(data) ? data : []; sendPlaybackState(true); }
        else if (message.name === 'video-params') { mediaInfo.video = data; sendMediaInfo(); }
        else if (message.name === 'audio-params') { mediaInfo.audio = data; sendMediaInfo(); }
        else if (message.name === 'estimated-vf-fps') { mediaInfo.fps = data; sendMediaInfo(); }
        else if (message.name === 'bitrate') { mediaInfo.bitrate = data; sendMediaInfo(); }
        else if (message.name === 'user-data/yj-active' && data) { try { const next = JSON.parse(data); if (next?.serverUrl && next?.itemId) playbackContext = { ...playbackContext, ...next }; } catch {} }
        else if (message.name === 'user-data/yj-player-action' && data) { try { sender.send('mpv-player-action',JSON.parse(data)); } catch {} }
        const second = Math.floor(position);
        if (second > 0 && second % 10 === 0 && second !== lastReport) { lastReport = second; report('/Progress', position, paused); }
      } catch {}
    });
  }
  // The mpv window now owns the whole player UI (its OSC draws the V9-style
  // console). Hide the Electron app window so mpv's window is the only thing
  // on screen — the player becomes a dedicated mpv window, not an overlay.
  try { if (owner && !owner.isDestroyed()) owner.hide(); } catch {}
  syncMpvOwnWindow(owner);
  [120, 400, 1000, 2500].forEach(delay => setTimeout(() => { try { if (mpvProcess && !mpvProcess.killed) syncMpvOwnWindow(owner); } catch {} }, delay));
  const launchedProcess=mpvProcess;
  launchedProcess.once('exit', () => {
    report('/Stopped', position, paused);
    if (stateTimer) { clearTimeout(stateTimer); stateTimer = null; }
    currentPlaybackState = null; currentMediaInfo = null;
    if (danmakuFile) fs.rmSync(danmakuFile, { force:true });
    for (const file of dynamicDanmakuFiles) fs.rmSync(file,{force:true}); dynamicDanmakuFiles.clear();
    for (const file of episodeThumbnailFiles) fs.rmSync(file, { force:true });
    if (seriesLogoImage?.file) fs.rmSync(seriesLogoImage.file,{force:true});
    fs.rmSync(playerStateFile, { force:true });
    sender.send('mpv-media-info', { ended: true });
    // Restore the app window: while playing we hide() it so the mpv window owns
    // the whole player UI; bring it back (and drop the old pin) when playback
    // ends, including when the user closes the mpv window itself.
    if (mainWindow && !mainWindow.isDestroyed()) {
      try { mainWindow.setAlwaysOnTop(false); } catch {}
      try { mainWindow.show(); } catch {}
    }
    if (mpvProcess===launchedProcess) { mpvSocket=null; pendingMpvUpdate=null; mpvProcess = null; }
  });
  return true;
});

ipcMain.handle('mpv-open-url', async (_event, playback) => {
  const mediaUrl = new URL(playback.url);
  if (!['http:', 'https:'].includes(mediaUrl.protocol)) throw new Error('仅支持 HTTP 或 HTTPS 媒体地址');
  if (mpvProcess) mpvProcess.kill();
  const args = [...mpvPortableArgs(), '--force-window=yes', ...mpvControls, ...mpvSettingArgs(playback), `--force-media-title=${String(playback.title || '映迹').replace(/[\r\n]/g, ' ')}`];
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
    // A hung probe would orphan yet another mpv, so cap the wait.
    const probeTimer = setTimeout(() => { try { child.kill(); } catch {} }, 10000);
    child.stdout.on('data', chunk => { out += chunk.toString(); });
    child.stderr.on('data', chunk => { out += chunk.toString(); });
    child.once('close', () => {
      clearTimeout(probeTimer);
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
    child.once('error', () => { clearTimeout(probeTimer); resolve([]); });
  });
});

// mpv is spawned as a detached child, so it outlives Electron unless we kill it.
// Quitting used to orphan the player: the leftover processes sit there as
// "mpv smtc" windows with 0 CPU time, keep app/mpv/mpv.exe locked, and later
// stall electron-builder during packaging (it hangs in the packaging step).
const cleanupMpv = () => {
  const proc = mpvProcess;
  mpvProcess = null;
  if (proc && !proc.killed) { try { proc.kill(); } catch {} }
  if (mpvSocket && !mpvSocket.destroyed) { try { mpvSocket.destroy(); } catch {} }
  mpvSocket = null;
  clipStart = null;
  mpvOwnHwnd = 0;
  mpvTitleToken = '';
  electronOwnerHwnd = 0;
  if (mainWindow && !mainWindow.isDestroyed()) { try { mainWindow.setAlwaysOnTop(false); } catch {} }
  for (const file of dynamicDanmakuFiles) { try { fs.rmSync(file, { force: true }); } catch {} }
  dynamicDanmakuFiles.clear();
};
app.on('before-quit', cleanupMpv);
app.on('will-quit', cleanupMpv);

app.whenReady().then(() => {
  createWindow();
  app.on('activate', () => BrowserWindow.getAllWindows().length || createWindow());
});
app.on('window-all-closed', () => process.platform === 'darwin' || app.quit());
