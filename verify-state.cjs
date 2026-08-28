const fs = require('node:fs');
const vm = require('node:vm');

const source = fs.readFileSync('app/integration.js', 'utf8').split('let discoverySyncing')[0];
const run = values => {
  const store = new Map(Object.entries(values));
  const context = { window: { yingjiDesktop: {}, YINGJI_CONFIG: {} }, localStorage: { getItem: key => store.get(key) ?? null, removeItem: key => store.delete(key), setItem: (key, value) => store.set(key, value) } };
  vm.runInNewContext(`${source}; result={ui:live.ui,watchlist:live.watchlist,emby:providerConfig.emby}`, context);
  return context.result;
};

for (const state of [
  {},
  { 'yingji.ui': '{bad json', 'yingji.providers': 'null', 'yingji.live-watchlist': '{}' },
  { 'yingji.ui': '{"calendarFilter":"watched","toggles":{"hdr":false}}', 'yingji.providers': '{"emby":[]}', 'yingji.live-watchlist': '[]' }
]) {
  const result = run(state);
  if (!Array.isArray(result.watchlist) || !Array.isArray(result.emby) || !Array.isArray(result.ui.recentSearches)) throw new Error('state arrays were not repaired');
  for (const key of ['hardware','hdr','traktOnly','tmdb','emby','trakt','wifi']) if (typeof result.ui.toggles[key] !== 'boolean') throw new Error(`missing toggle: ${key}`);
}
console.log('state migration verified');
