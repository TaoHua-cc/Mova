const fs = require('node:fs');
const vm = require('node:vm');

const source = fs.readFileSync('app/integration.js', 'utf8').split('const embyHeaders')[0];
const run = values => {
  const store = new Map(Object.entries(values));
  const context = { window: { yingjiDesktop: {}, YINGJI_CONFIG: {} }, localStorage: { getItem: key => store.get(key) ?? null, removeItem: key => store.delete(key), setItem: (key, value) => store.set(key, value) } };
  vm.runInNewContext(`${source}; result={ui:live.ui,watchlist:live.watchlist,emby:providerConfig.emby,chapterApis:yjChapterApis(),chapterRules:yjChapterRules(),chapterKey:yjMediaKey({tmdbid:42,season:2,episode:7}),player:effectivePlayerSettings('series:42')}`, context);
  return context.result;
};

for (const state of [
  {},
  { 'yingji.ui': '{bad json', 'yingji.providers': 'null', 'yingji.live-watchlist': '{}' },
  { 'yingji.ui': '{"calendarFilter":"watched","toggles":{"hdr":false}}', 'yingji.providers': '{"emby":[]}', 'yingji.live-watchlist': '[]' }
]) {
  const result = run(state);
  if (!Array.isArray(result.watchlist) || !Array.isArray(result.emby) || !Array.isArray(result.ui.recentSearches)) throw new Error('state arrays were not repaired');
  for (const key of ['hardware','hdr','chapterAutoSkip','traktOnly','tmdb','emby','trakt','wifi']) if (typeof result.ui.toggles[key] !== 'boolean') throw new Error(`missing toggle: ${key}`);
  if (!Array.isArray(result.chapterApis) || !Array.isArray(result.chapterRules) || result.chapterKey !== '42|2|7') throw new Error('chapter settings were not normalized');
  for (const key of ['audioDelay','subtitleScale','subtitlePos','subtitleDelay','subtitleBorder','videoAspect','videoZoom','videoRotate','loopFile']) if (!(key in result.player)) throw new Error(`missing player setting: ${key}`);
}
console.log('state migration verified');
