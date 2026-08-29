const { app, BrowserWindow } = require('electron');
const fs = require('node:fs');
const path = require('node:path');

app.whenReady().then(async () => {
  const window = new BrowserWindow({ width: 1700, height: 980, show: false, webPreferences: { backgroundThrottling: false } });
  await window.loadFile(path.join(__dirname, 'player-design.html'));
  await new Promise(resolve => setTimeout(resolve, 450));
  for (const id of ['overview', 'audio-menu', 'subtitle-menu', 'more-menu', 'episode-tray', 'icon-sheet', 'resource-menu', 'danmaku-menu', 'picture-menu', 'chapters-menu', 'diagnostics-menu', 'states']) {
    await window.webContents.executeJavaScript(`document.querySelector('#${id}').scrollIntoView({block:'start'}); scrollBy(0,-40)`);
    await new Promise(resolve => setTimeout(resolve, 80));
    const rect = await window.webContents.executeJavaScript(`(() => { const r=document.querySelector('#${id}').getBoundingClientRect(); return {x:Math.round(r.x),y:Math.round(r.y),width:Math.round(r.width),height:Math.round(r.height)} })()`);
    const image = await window.webContents.capturePage(rect);
    fs.writeFileSync(path.join(__dirname, `${id}.png`), image.toPNG());
  }
  const result = await window.webContents.executeJavaScript(`({
    artboards: document.querySelectorAll('.artboard').length,
    icons: document.querySelectorAll('#icons .icon-cell').length,
    controls: document.querySelectorAll('button').length,
    externalSymbols: [...document.querySelectorAll('use')].every(node => node.getAttribute('href').startsWith('player-icons.svg#'))
  })`);
  if (result.artboards !== 12 || result.icons !== 39 || !result.externalSymbols) throw new Error(JSON.stringify(result));
  console.log(JSON.stringify(result));
  window.destroy();
  app.quit();
}).catch(error => { console.error(error); app.exit(1); });
