const { app, BrowserWindow, ipcMain, safeStorage, shell, nativeImage, net: electronNet } = require('electron');
const path = require('node:path');
const fs = require('node:fs');
const net = require('node:net');
const { spawn } = require('node:child_process');
let mpvProcess,mpvSocket;
// Danmaku matching can finish before mpv has opened its IPC pipe. Preserve the
// newest update until that pipe is ready rather than dropping the first result.
let pendingMpvUpdate = null;
const dynamicDanmakuFiles=new Set();
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
    const timer = setTimeout(() => { child.off('exit', onExit); resolve(); }, 350);
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
  const timeoutMs = Math.min(60000, Math.max(5000, Number(request.timeoutMs) || 15000));
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const options = {
      method: request.method || 'GET',
      headers: { Accept: 'application/json, text/plain, application/xml, text/xml, */*', 'User-Agent': 'Yingji/2.0', ...(request.headers || {}) },
      body: request.rawBody ?? (request.body ? JSON.stringify(request.body) : undefined),
      signal: controller.signal
    };
    let response;
    try { response = await fetch(url, options); }
    catch (error) {
      if (!electronNet?.fetch) throw error;
      response = await electronNet.fetch(url, options);
    }
    const text = await response.text();
    const data = request.responseType === 'text' ? text : text ? JSON.parse(text) : null;
    if (request.acceptErrors) return { status: response.status, data };
    if (!response.ok) throw new Error(`${response.status} ${text.slice(0, 180)}`);
    return data;
  } catch (error) {
    if (controller.signal.aborted) throw new Error(`请求超时（${Math.round(timeoutMs / 1000)} 秒）`);
    throw error;
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

ipcMain.handle('mpv-play', async (event, playback) => {
  const sender = event.sender;
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
    speed:Number(playback.speed || 1), audioDelay:Number(playback.audioDelay || 0), subtitleScale:Number(playback.subtitleScale || 1), subtitlePos:Number(playback.subtitlePos || 92), subtitleDelay:Number(playback.subtitleDelay || 0), subtitleBorder:Number(playback.subtitleBorder || 1.5), videoAspect:String(playback.videoAspect || 'auto'), videoZoom:Number(playback.videoZoom || 0), videoRotate:Number(playback.videoRotate || 0), loopFile:!!playback.loopFile,
    danmakuContext: playback.danmakuContext || null,
    danmakuSourceInfo:danmakuSourceInfo.slice(0,12),
    chapterKey:String(playback.chapterKey || ''), chapterRule:playback.chapterRule || null, chapterAutoSkip:playback.chapterAutoSkip !== false
  }), 'utf8');
  const args = [
    `--input-ipc-server=${pipe}`,
    ...mpvPortableArgs(),
    '--force-window=yes',
    ...mpvControls,
    ...mpvSettingArgs(playback),
    `--force-media-title=${String(playback.title || '映迹').replace(/[\r\n]/g, ' ')}`,
    `--script-opts=yj-state-file=${playerStateFile}`,
    `--start=${Math.max(0, Number(playback.position || 0))}`,
    `--http-header-fields=X-Emby-Token: ${playback.token}`,
    ...(danmakuFile ? [`--sub-file=${danmakuFile}`] : []),
    mediaUrl.href
  ];
  try { mpvProcess = await launchMpv(args); }
  catch (error) {
    // A stale hardware-decoder/adapter selection can make mpv exit before its
    // IPC socket is ready. Retry once in a conservative software-decoder mode
    // so a transient graphics choice does not look like a player crash.
    const safeArgs=args.filter(argument=>!/^--(?:vo|hwdec|d3d11-adapter)=/i.test(argument)).concat(['--vo=gpu-next','--hwdec=no']);
    try { mpvProcess = await launchMpv(safeArgs); }
    catch { fs.rmSync(playerStateFile, { force:true }); for (const file of episodeThumbnailFiles) fs.rmSync(file, { force:true }); if (seriesLogoImage?.file) fs.rmSync(seriesLogoImage.file,{force:true}); throw error; }
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
  const sendMediaInfo = () => { try { sender.send('mpv-media-info', { ...mediaInfo }); } catch {} };
  let position = Number(playback.position || 0), paused = false, lastReport = -1;
  const connect = attempt => new Promise((resolve, reject) => {
    const socket = net.connect(pipe, () => resolve(socket));
    socket.once('error', error => attempt < 30 ? setTimeout(() => connect(attempt + 1).then(resolve, reject), 200) : reject(error));
  });
  report('', playback.position || 0, false).catch(() => {});
  connect(0).then(socket => {
    mpvSocket=socket;
    socket.write('{"command":["observe_property",1,"time-pos"]}\n{"command":["observe_property",2,"pause"]}\n{"command":["observe_property",3,"video-params"]}\n{"command":["observe_property",4,"audio-params"]}\n{"command":["observe_property",5,"estimated-vf-fps"]}\n{"command":["observe_property",6,"bitrate"]}\n{"command":["observe_property",7,"user-data/yj-active"]}\n{"command":["observe_property",8,"user-data/yj-player-action"]}\n');
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
        if (message.name === 'time-pos' && Number.isFinite(message.data)) position = message.data;
        else if (message.name === 'pause') paused = message.data;
        else if (message.name === 'video-params') { mediaInfo.video = message.data; sendMediaInfo(); }
        else if (message.name === 'audio-params') { mediaInfo.audio = message.data; sendMediaInfo(); }
        else if (message.name === 'estimated-vf-fps') { mediaInfo.fps = message.data; sendMediaInfo(); }
        else if (message.name === 'bitrate') { mediaInfo.bitrate = message.data; sendMediaInfo(); }
        else if (message.name === 'user-data/yj-active' && message.data) { try { const next = JSON.parse(message.data); if (next?.serverUrl && next?.itemId) playbackContext = { ...playbackContext, ...next }; } catch {} }
        else if (message.name === 'user-data/yj-player-action' && message.data) { try { sender.send('mpv-player-action',JSON.parse(message.data)); } catch {} }
        const second = Math.floor(position);
        if (second > 0 && second % 10 === 0 && second !== lastReport) { lastReport = second; report('/Progress', position, paused); }
      } catch {}
    });
  }).catch(() => {});
  const launchedProcess=mpvProcess;
  launchedProcess.once('exit', () => { report('/Stopped', position, paused); if (danmakuFile) fs.rmSync(danmakuFile, { force:true }); for (const file of dynamicDanmakuFiles) fs.rmSync(file,{force:true}); dynamicDanmakuFiles.clear(); for (const file of episodeThumbnailFiles) fs.rmSync(file, { force:true }); if (seriesLogoImage?.file) fs.rmSync(seriesLogoImage.file,{force:true}); fs.rmSync(playerStateFile, { force:true }); sender.send('mpv-media-info', { ended: true }); if (mpvProcess===launchedProcess) { mpvSocket=null; pendingMpvUpdate=null; mpvProcess = null; } });
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
