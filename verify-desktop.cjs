const { _electron: electron } = require('playwright');
const http = require('node:http');

(async () => {
  const wav = Buffer.alloc(44 + 8000);
  wav.write('RIFF'); wav.writeUInt32LE(wav.length - 8, 4); wav.write('WAVEfmt ', 8); wav.writeUInt32LE(16, 16); wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22); wav.writeUInt32LE(8000, 24); wav.writeUInt32LE(8000, 28); wav.writeUInt16LE(1, 32); wav.writeUInt16LE(8, 34); wav.write('data', 36); wav.writeUInt32LE(8000, 40); wav.fill(128, 44);
  const server = http.createServer((request, response) => {
    if (request.url.startsWith('/audio.wav')) { response.setHeader('Content-Type', 'audio/wav'); response.end(wav); return; }
    if (request.url.startsWith('/Sessions/')) { response.statusCode = 204; response.end(); return; }
    response.setHeader('Content-Type', 'application/json');
    response.end('{"ok":true}');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const app = await electron.launch({ executablePath: require('electron'), args: ['.'] });
  const page = await app.firstWindow();
  await page.waitForSelector('.hero');
  const result = await page.evaluate(() => ({
    title: document.title,
    desktopBridge: typeof window.yingjiDesktop?.windowAction === 'function',
    navItems: document.querySelectorAll('.nav button').length,
    theme: document.body.className,
    railWidth: getComputedStyle(document.querySelector('.bar')).width
  }));
  if (!result.desktopBridge || result.navItems !== 7 || result.railWidth !== '62px') throw new Error(JSON.stringify(result));
  const bridge = await page.evaluate(async port => {
    await window.yingjiDesktop.setSecret('verification-only', 'encrypted-value');
    return {
      secret: await window.yingjiDesktop.getSecret('verification-only'),
      api: await window.yingjiDesktop.request({ url: `http://127.0.0.1:${port}/test` }),
      navIcons: document.querySelectorAll('.nav button svg path, .nav button svg rect, .nav button svg circle').length
    };
  }, server.address().port);
  if (bridge.secret !== 'encrypted-value' || !bridge.api.ok || bridge.navIcons < 7) throw new Error(JSON.stringify(bridge));
  await page.evaluate(async port => window.yingjiDesktop.playMpv({
    url: `http://127.0.0.1:${port}/audio.wav`, serverUrl: `http://127.0.0.1:${port}`,
    title: 'mpv verification', token: 'test', itemId: '1', mediaSourceId: '1', playSessionId: '1', position: 0
  }), server.address().port);
  await page.waitForTimeout(1400);
  await page.screenshot({ path: '../../outputs/yingji-windows-app.png' });
  await page.locator('.nav button').first().hover();
  await page.waitForTimeout(300);
  const expandedWidth = await page.locator('.bar').evaluate(element => getComputedStyle(element).width);
  if (expandedWidth !== '228px') throw new Error(`Rail did not expand: ${expandedWidth}`);
  await page.screenshot({ path: '../../outputs/yingji-windows-nav-expanded.png' });
  await page.locator('[data-go="settings"]').click();
  await page.waitForSelector('[data-provider="emby"]');
  await page.screenshot({ path: '../../outputs/yingji-windows-connections.png' });
  result.expandedWidth = expandedWidth;
  result.bridge = bridge;
  await page.locator('.win span').nth(2).click();
  await new Promise(resolve => setTimeout(resolve, 250));
  if (!page.isClosed()) throw new Error('Window close action did not close the app');
  console.log(JSON.stringify(result));
  server.close();
})().catch(error => { console.error(error); process.exit(1); });
