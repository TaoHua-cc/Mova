'use strict';

/**
 * Process adapter for the current mpv backend. The renderer and IPC layer use
 * this stable launch contract while the implementation can later be replaced
 * by an in-process libmpv adapter without changing UI commands.
 */
function createMpvLauncher({ resolveExecutable, fs, path, spawn, appendLog, isCurrent }) {
  return async function launchMpv(args, mode = 'primary') {
    const mpv = resolveExecutable();
    if (!fs.existsSync(mpv)) throw new Error('未找到 mpv 播放器内核');
    appendLog(`launch ${mode} executable=${mpv} args=${args.map(argument => /^--http-header-fields=/i.test(argument) ? '--http-header-fields=<redacted>' : /^https?:\/\//i.test(argument) ? '<media-url>' : argument).join(' ')}`);
    const child = spawn(mpv, args, { cwd: path.dirname(mpv), windowsHide: false, stdio: ['ignore', 'ignore', 'pipe'] });
    let stderr = '';
    child.stderr.on('data', chunk => {
      const text = String(chunk);
      stderr = `${stderr}${text}`.slice(-2000);
      for (const line of text.split(/\r?\n/)) {
        const trimmed = line.trim();
        if (trimmed && /(error|fail|cannot|could not|invalid|unable|vo\b|gpu|d3d|egl|vulkan|present)/i.test(trimmed)) {
          appendLog(`mpv: ${trimmed}`);
        }
      }
    });
    child.getLaunchError = () => stderr.trim();
    child.once('error', error => appendLog(`error ${mode} pid=${child.pid || 0} detail=${error.message}`));
    child.once('exit', (code, signal) => {
      appendLog(`exit ${mode} pid=${child.pid || 0} code=${code ?? 'null'} signal=${signal || 'none'}${stderr.trim() ? ` stderr=${stderr.trim()}` : ''}`);
      if (isCurrent(child)) isCurrent(null);
    });
    await new Promise((resolve, reject) => {
      child.once('spawn', resolve);
      child.once('error', error => reject(new Error(`播放器启动失败：${error.message}`)));
    });
    await new Promise((resolve, reject) => {
      const onExit = code => {
        clearTimeout(timer);
        reject(new Error(stderr.trim() || `mpv 启动后立即退出（代码 ${code ?? '未知'}）`));
      };
      const timer = setTimeout(() => {
        child.off('exit', onExit);
        resolve();
      }, 350);
      child.once('exit', onExit);
    });
    return child;
  };
}

module.exports = { createMpvLauncher };
