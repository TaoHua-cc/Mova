const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('yingjiDesktop', {
  windowAction: action => ipcRenderer.send('window-action', action),
  request: request => ipcRenderer.invoke('api-request', request),
  playMpv: playback => ipcRenderer.invoke('mpv-play', playback),
  openUrl: playback => ipcRenderer.invoke('mpv-open-url', playback),
  setSecret: (key, value) => ipcRenderer.invoke('secret-set', key, value),
  getSecret: key => ipcRenderer.invoke('secret-get', key)
});
