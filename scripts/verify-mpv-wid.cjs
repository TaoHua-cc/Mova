const { app, BrowserWindow } = require('electron');
const { spawn } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');
const net = require('node:net');

const nativeWindowId = win => {
  const handle = win.getNativeWindowHandle();
  return handle.length >= 8 ? handle.readBigUInt64LE(0).toString() : String(handle.readUInt32LE(0));
};

app.whenReady().then(async () => {
  const host = new BrowserWindow({
    width:960,
    height:540,
    frame:false,
    show:false,
    focusable:true,
    skipTaskbar:true,
    backgroundColor:'#000',
    webPreferences:{ sandbox:true, contextIsolation:true, nodeIntegration:false }
  });
  await host.loadURL('data:text/html,%3Cstyle%3Ehtml%2Cbody%7Bmargin%3A0%3Bbackground%3A%23000%7D%3C%2Fstyle%3E');
  host.show();
  host.setIgnoreMouseEvents(true);
  const mpv = path.join(__dirname, '..', 'app', 'mpv', 'mpv.exe');
  const portable = path.join(path.dirname(mpv), 'portable_config');
  const stateFile = path.join(app.getPath('temp'), `yingji-wid-smoke-${process.pid}.json`);
  const pipe = `\\\\.\\pipe\\yingji-wid-smoke-${process.pid}-${Date.now()}`;
  fs.writeFileSync(stateFile, JSON.stringify({ seriesLogo:'映迹', episodeName:'宿主窗口验证' }));
  const child = spawn(mpv, [
    `--input-ipc-server=${pipe}`,
    '--no-config', `--include=${path.join(portable, 'mpv.conf')}`, `--script=${path.join(portable, 'scripts', 'yingji-osc.lua')}`,
    `--wid=${nativeWindowId(host)}`, '--force-window=yes', '--audio=no', '--input-default-bindings=no',
    '--vo=gpu-next', '--hwdec=no', '--loop-file=inf', `--script-opts=yj-state-file=${stateFile},yj-headless=yes`,
    'av://lavfi:testsrc=size=960x540:rate=24'
  ], { cwd:path.dirname(mpv), windowsHide:true, stdio:['ignore','ignore','pipe'] });
  let stderr = '';
  child.stderr.on('data', chunk => { stderr += chunk.toString(); });
  const connect = attempt => new Promise((resolve, reject) => {
    if (child.exitCode !== null || child.killed) return reject(new Error(stderr.trim() || 'mpv exited'));
    const socket = net.connect(pipe);
    socket.once('connect', () => resolve(socket));
    socket.once('error', error => { socket.destroy(); attempt < 30 ? setTimeout(() => connect(attempt + 1).then(resolve, reject), 100) : reject(error); });
  });
  setTimeout(async () => {
    let socket = null;
    try { socket = await connect(0); } catch (error) { stderr += `\nIPC: ${error.message}`; }
    const alive = child.exitCode === null && !child.killed && !!socket;
    console.log(alive ? `PASS wid=${nativeWindowId(host)} pid=${child.pid} ipc=ready` : `FAIL ${stderr.trim()}`);
    try { socket?.destroy(); } catch {}
    try { child.kill(); } catch {}
    try { host.destroy(); } catch {}
    try { fs.rmSync(stateFile, { force:true }); } catch {}
    app.exit(alive ? 0 : 1);
  }, 1200);
});
