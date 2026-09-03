const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('yingjiDesktop', {
  windowAction: action => ipcRenderer.send('window-action', action),
  setWindowFullScreen: requested => ipcRenderer.invoke('window-fullscreen-set', requested),
  onWindowFullScreen: callback => ipcRenderer.on('window-fullscreen-changed', (_event, enabled) => callback(!!enabled)),
  setWindowOnTop: requested => ipcRenderer.invoke('window-ontop-set', requested),
  setWindowPictureInPicture: requested => ipcRenderer.invoke('window-pip-set', requested),
  request: request => ipcRenderer.invoke('api-request', request),
  playMpv: playback => ipcRenderer.invoke('mpv-play', playback),
  openUrl: playback => ipcRenderer.invoke('mpv-open-url', playback),
  listAdapters: () => ipcRenderer.invoke('mpv-adapters'),
  mediaInfo: callback => ipcRenderer.on('mpv-media-info', (_event, info) => callback(info)),
  playbackState: callback => ipcRenderer.on('mpv-playback-state', (_event, state) => callback(state)),
  playerAction: callback => ipcRenderer.on('mpv-player-action', (_event, action) => callback(action)),
  mpvCommand: payload => ipcRenderer.invoke('mpv-command', payload),
  mpvState: () => ipcRenderer.invoke('mpv-state'),
  captureMpv: kind => ipcRenderer.invoke('mpv-capture', kind),
  updateMpv: update => ipcRenderer.invoke('mpv-player-update', update),
  setSecret: (key, value) => ipcRenderer.invoke('secret-set', key, value),
  getSecret: key => ipcRenderer.invoke('secret-get', key)
});
