import { Spider, net } from 'catvod';

// Active pool from scripts/probe-cms-providers.mjs (re-run when stale).
// Ranked by search breadth + latency; same-catalog mirrors collapsed to one host.
// Faster hosts first so collectProviderLists fills the first screen sooner.
// Prefer hosts with healthy cover CDNs first (jisu/guangsu/haohua/bfzy); dead
 // cover CDNs (ffzy/fffgood, zuid/zuidapic, maoyan) stay later for playback only.
const DEFAULT_PROVIDERS = [
  { key: 'maoyan', name: '猫眼', api: 'https://api.maoyanapi.top/api.php/provide/vod' },
  { key: 'ruyi', name: '如意', api: 'https://cj.rycjapi.com/api.php/provide/vod' },
  { key: 'haohua', name: '豪华', api: 'https://hhzyapi.com/api.php/provide/vod' },
  { key: 'subo', name: '速播', api: 'https://subocaiji.com/api.php/provide/vod' },
  { key: 'huya', name: '虎牙', api: 'https://www.huyaapi.com/api.php/provide/vod' },
  { key: 'jinying', name: '金鹰', api: 'https://jyzyapi.com/provide/vod/from/jinyingyun/at/json' },
  { key: 'lzi', name: '量子', api: 'https://cj.lziapi.com/api.php/provide/vod' },
  { key: 'lzcaiji', name: '量子', api: 'https://cj.lzcaiji.com/api.php/provide/vod' },
  { key: 'ffzy_cj', name: '非凡', api: 'https://cj.ffzyapi.com/api.php/provide/vod' },
  { key: 'zuid_me', name: '最大', api: 'https://zuidazy.me/api.php/provide/vod' },
];

const MENU = [
  { id: 'recommend', name: '推荐' },
  { id: 'tv', name: '电视剧' },
  { id: 'movie', name: '电影' },
  { id: 'variety', name: '综艺' },
  { id: 'anime', name: '动漫' },
];

const ANIME_CLASS = [
  { n: '全部', v: '' },
  { n: '国漫', v: '国漫' },
  { n: '日漫', v: '日漫' },
  { n: '欧美', v: '欧美' },
];

const FILTER_CLASS = [
  { n: '全部', v: '' },
  { n: '剧情', v: '剧情' },
  { n: '喜剧', v: '喜剧' },
  { n: '爱情', v: '爱情' },
  { n: '动作', v: '动作' },
  { n: '科幻', v: '科幻' },
  { n: '悬疑', v: '悬疑' },
  { n: '犯罪', v: '犯罪' },
  { n: '奇幻', v: '奇幻' },
  { n: '恐怖', v: '恐怖' },
  { n: '战争', v: '战争' },
  { n: '古装', v: '古装' },
  { n: '家庭', v: '家庭' },
];

const FILTER_AREA = [
  { n: '全部', v: '' },
  { n: '大陆', v: '大陆' },
  { n: '香港', v: '香港' },
  { n: '台湾', v: '台湾' },
  { n: '美国', v: '美国' },
  { n: '韩国', v: '韩国' },
  { n: '日本', v: '日本' },
  { n: '英国', v: '英国' },
  { n: '其他', v: '其他' },
];

const FILTER_YEAR = [
  { n: '全部', v: '' },
  { n: '2026', v: '2026' },
  { n: '2025', v: '2025' },
  { n: '2024', v: '2024' },
  { n: '2023', v: '2023' },
  { n: '2022', v: '2022' },
  { n: '2021', v: '2021' },
  { n: '2020', v: '2020' },
  { n: '10年代', v: '2010' },
  { n: '更早', v: '2000' },
];

// 电视剧 / 综艺 / 动漫：默认豆瓣热门（对齐 FongMi 仓里的豆瓣站榜单思路）。
const FILTER_SORT = [
  { n: '豆瓣热门', v: '' },
  { n: '上映时间', v: 'release' },
  { n: '最新更新', v: 'time' },
  { n: '最热', v: 'hits' },
  { n: '豆瓣评分', v: 'douban' },
];

// 电影：与剧/综/漫一致，默认热门（豆瓣榜 / 大站热播优先）；上映时间改为可选。
const FILTER_SORT_MOVIE = [
  { n: '热门', v: '' },
  { n: '上映时间', v: 'release' },
  { n: '最新更新', v: 'time' },
  { n: '最热', v: 'hits' },
  { n: '豆瓣评分', v: 'douban' },
];

// m.douban.com rexxar collections (same idea as CatVod Douban spiders).
const DOUBAN_COLLECTION = {
  recommend: 'subject_real_time_hotest',
  tv: 'tv_hot',
  movie: 'movie_hot_gaia',
  variety: 'show_hot',
  anime: 'tv_animation',
};
const DOUBAN_HEADERS = {
  'User-Agent':
    'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
  Referer: 'https://m.douban.com/',
  Accept: 'application/json,text/plain,*/*',
};

function bucketFilters(bucket) {
  const anime = bucket === 'anime';
  const filters = [];
  // 站点切换在播放页「来源」完成；筛选里不再展示源站 chips。
  filters.push({
    key: 'class',
    name: '类型',
    init: '',
    value: anime ? ANIME_CLASS : FILTER_CLASS,
  });
  if (!anime) {
    filters.push({ key: 'area', name: '地区', init: '', value: FILTER_AREA });
  }
  filters.push({ key: 'year', name: '年份', init: '', value: FILTER_YEAR });
  filters.push({
    key: 'by',
    name: '排序',
    init: '',
    value: bucket === 'movie' ? FILTER_SORT_MOVIE : FILTER_SORT,
  });
  return filters;
}

function menuFilters() {
  const filters = {};
  for (let i = 0; i < MENU.length; i++) {
    const entry = MENU[i];
    if (entry.id === 'recommend') continue;
    filters['bucket|' + entry.id] = bucketFilters(entry.id);
  }
  return filters;
}

function animeLeafKind(name) {
  const n = String(name || '');
  if (/里番|伦理|福利|色情/.test(n)) return null;
  // iqiyi: 国产动漫 / 港台动漫 / 日韩动漫 / 欧美动漫
  if (/国产|国漫|大陆|中国|港台|香港|台湾/.test(n)) return '国漫';
  if (/日韩|日本|日漫|韩国/.test(n)) return '日漫';
  if (/欧美|美国|英国|海外/.test(n)) return '欧美';
  return null;
}

function matchesAnimeClass(item, classKey) {
  if (!classKey) return true;
  // 国漫/日漫/欧美 are synthetic; CMS uses 国产动漫 etc.
  if (classKey === '国漫' || classKey === '日漫' || classKey === '欧美') {
    const kind = animeLeafKind(
      [item && item.type_name, item && item.vod_class, item && item.vod_tag].join(' ')
    );
    return kind === classKey;
  }
  const blob = [item && item.type_name, item && item.vod_class, item && item.vod_tag, item && item.vod_name].join(' ');
  return blob.indexOf(classKey) >= 0;
}

function parseScore(value) {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

function recency(item) {
  const raw = String((item && (item.vod_time || item.vod_time_add)) || '').trim();
  const time = Date.parse(raw.replace(' ', 'T'));
  const year = Number(String((item && item.vod_year) || '').slice(0, 4));
  const timeScore = Number.isFinite(time) ? time : 0;
  const yearScore = Number.isFinite(year) ? year : 0;
  return timeScore * 10000 + yearScore;
}

function sortByRecency(list) {
  return list.slice().sort(function (a, b) {
    return recency(b) - recency(a);
  });
}

function sortByHotRecent(list) {
  const current = new Date().getFullYear();
  return list.slice().sort(function (a, b) {
    return hotRecentScore(b, current) - hotRecentScore(a, current);
  });
}

/// 腾讯 / 爱奇艺 / 优酷 / 芒果 / B站 — browse lists prefer these.
/// CMS rarely fills 播出平台; fall back to mainstream catalog signals.
function majorPlatformRank(item) {
  if (!item) return 0;
  const blob = [
    item.vod_name,
    item.type_name,
    item.vod_class,
    item.vod_tag,
    item.vod_remarks,
    item.vod_note,
    item.vod_blurb,
    item.vod_content,
    item.vod_play_from,
    item.vod_publisher,
    item.vod_tv,
    item.vod_version,
  ].join(' ');
  if (/腾讯视频|腾讯独播|(?:^|[^a-z])tx(?:视频)?/i.test(blob)) return 4;
  if (/爱奇艺|iqiyi/i.test(blob)) return 4;
  if (/优酷|youku/i.test(blob)) return 4;
  if (/芒果TV|芒果视频|芒果独播|mgtv/i.test(blob)) return 4;
  if (/哔哩哔哩|bilibili|B站|b站|仅限B站|僅限B站/i.test(blob)) return 4;
  if (/独播/.test(blob) && /腾讯|爱奇艺|优酷|芒果|哔哩|B站/.test(blob)) return 4;
  const douban = parseScore(item.vod_douban_score) || parseScore(item.vod_score);
  if (douban >= 6) return 3;
  if (douban > 0) return 2;
  const hasCast = String(item.vod_actor || '').trim().length > 1;
  const isFeature = String(item.vod_state || '') === '正片';
  const year = Number(String(item.vod_year || '').slice(0, 4));
  const hasYear = Number.isFinite(year) && year >= 2018;
  // Real series/movies usually ship cast + year; short-drama dumps often omit both.
  if (isFeature && hasCast && hasYear) return 2;
  if (hasCast && hasYear) return 1;
  return 0;
}

function hotRecentScore(item, current) {
  const year = Number(String((item && item.vod_year) || '').slice(0, 4));
  let yearRank = 0;
  if (Number.isFinite(year) && year >= current) yearRank = 3;
  else if (Number.isFinite(year) && year >= current - 1) yearRank = 2;
  else if (Number.isFinite(year) && year >= current - 2) yearRank = 1;
  let score =
    majorPlatformRank(item) * 1e14 +
    yearRank * 1e12 +
    parseScore(item && item.vod_hits) * 1000 +
    recency(item) / 1e8;
  // Any short-drama that slipped through ranks far below real series.
  if (looksShortDrama(item)) score -= 1e15;
  return score;
}

/// 上映时间：年份优先（避免高分老片靠平台分压过新片），再轻量平台分，再入库时间。
function releaseTime(item) {
  const year = Number(String((item && item.vod_year) || '').slice(0, 4));
  const yearScore = Number.isFinite(year) && year > 1900 ? year : 0;
  const raw = String((item && (item.vod_time || item.vod_time_add)) || '').trim();
  const time = Date.parse(raw.replace(' ', 'T'));
  const timeScore = Number.isFinite(time) ? time : 0;
  return yearScore * 1e13 + majorPlatformRank(item) * 1e10 + timeScore;
}

function sortByReleaseTime(list) {
  return list.slice().sort(function (a, b) {
    return releaseTime(b) - releaseTime(a);
  });
}

/// Keep major-platform titles up front, then mix CMS hosts for the rest.
function diversifyByProvider(sortedList, perProvider) {
  const cap = Math.max(1, perProvider || 4);
  const picked = [];
  const used = {};
  // 1) Lock in 腾讯/爱奇艺/优酷/芒果/B站 (or strong proxies) already sorted to the top.
  for (let i = 0; i < sortedList.length; i++) {
    const item = sortedList[i];
    if (majorPlatformRank(item) < 2) continue;
    picked.push(item);
    used[item.vod_id] = true;
    if (picked.length >= FIRST_SCREEN) return picked.concat(
      sortedList.filter(function (row) { return !used[row.vod_id]; })
    );
  }
  // 2) Round-robin remaining CMS providers so the grid is not one host.
  const counts = {};
  for (let i = 0; i < sortedList.length; i++) {
    const item = sortedList[i];
    if (used[item.vod_id]) continue;
    const split = splitID(item && item.vod_id);
    const key = split ? split.provider : '_';
    counts[key] = counts[key] || 0;
    if (counts[key] >= cap) continue;
    picked.push(item);
    used[item.vod_id] = true;
    counts[key] += 1;
  }
  for (let i = 0; i < sortedList.length; i++) {
    const item = sortedList[i];
    if (used[item.vod_id]) continue;
    picked.push(item);
  }
  return picked;
}

function applyExtend(list, extend, bucket) {
  const ext = extend && typeof extend === 'object' ? extend : {};
  const classKey = String(ext.class || '');
  const areaKey = String(ext.area || '');
  const yearKey = String(ext.year || '');
  const sortKey = String(ext.by || '');
  let out = list.slice();
  if (classKey) {
    out = out.filter(function (item) {
      return matchesAnimeClass(item, classKey);
    });
  }
  if (areaKey) {
    out = out.filter(function (item) {
      return matchesArea(item, areaKey);
    });
  }
  if (yearKey) {
    out = out.filter(function (item) {
      const year = String(item.vod_year || '');
      if (yearKey === '2010') return /^201\d/.test(year);
      if (yearKey === '2000') {
        const y = Number(year);
        return Number.isFinite(y) && y > 0 && y < 2010;
      }
      return year.indexOf(yearKey) >= 0;
    });
  }
  if (sortKey === 'hits') {
    out.sort(function (a, b) {
      const platform = majorPlatformRank(b) - majorPlatformRank(a);
      if (platform) return platform;
      return parseScore(b.vod_hits) - parseScore(a.vod_hits);
    });
  } else if (sortKey === 'douban') {
    out.sort(function (a, b) {
      const platform = majorPlatformRank(b) - majorPlatformRank(a);
      if (platform) return platform;
      const left = parseScore(a.vod_douban_score) || parseScore(a.vod_score);
      const right = parseScore(b.vod_douban_score) || parseScore(b.vod_score);
      if (right !== left) return right - left;
      return recency(b) - recency(a);
    });
  } else if (sortKey === 'time') {
    out.sort(function (a, b) {
      const platform = majorPlatformRank(b) - majorPlatformRank(a);
      if (platform) return platform;
      return recency(b) - recency(a);
    });
  } else if (sortKey === 'hot') {
    out = sortByHotRecent(out);
  } else if (sortKey === 'douban_hot') {
    // Already ordered by Douban chart — keep as-is.
  } else if (sortKey === 'release') {
    // 显式「上映时间」
    out = sortByReleaseTime(out);
  } else if (!sortKey) {
    // Default (含电影)：Douban chart order when resolved upstream;
    // fallback CMS path still uses hot-recent + major-platform rank.
    out = sortByHotRecent(out);
  } else {
    out = sortByHotRecent(out);
  }
  return out;
}

async function fetchDoubanHotEntries(bucket, count) {
  const collection = DOUBAN_COLLECTION[bucket];
  if (!collection) return [];
  const want = Math.max(8, Math.min(30, count || FIRST_SCREEN));
  const url =
    'https://m.douban.com/rexxar/api/v2/subject_collection/' +
    collection +
    '/items?start=0&count=' +
    want;
  try {
    const response = await net.req(url, {
      timeout: 8000,
      headers: DOUBAN_HEADERS,
    });
    if (!response || response.code < 200 || response.code >= 300) return [];
    const data = JSON.parse(response.content);
    const rows = data.subject_collection_items || data.items || [];
    const out = [];
    for (let i = 0; i < rows.length; i++) {
      const row = rows[i];
      const title = String((row && (row.title || row.name)) || '').trim();
      if (!title) continue;
      const rating =
        row.rating && typeof row.rating === 'object'
          ? Number(row.rating.value)
          : Number(row.rating);
      out.push({
        title: title,
        year: String((row && row.year) || '').slice(0, 4),
        rating: Number.isFinite(rating) && rating > 0 ? rating : 0,
        pic: (row && (row.pic && (row.pic.normal || row.pic.large))) || (row && row.cover_url) || '',
        rank: i + 1,
      });
    }
    return out;
  } catch (error) {
    return [];
  }
}

function titleMatchScore(query, candidate) {
  const q = normalizeTitle(query);
  const c = normalizeTitle(candidate);
  if (!q || !c) return 0;
  if (q === c) return 100;
  if (c.indexOf(q) === 0 || q.indexOf(c) === 0) return 80;
  if (c.indexOf(q) >= 0 || q.indexOf(c) >= 0) return 50;
  return 0;
}

async function findCMSMatchForTitle(entry, providers, accept) {
  const title = entry.title;
  let best = null;
  let bestScore = 0;
  // Two fast hosts + short timeout — keep Douban mapping inside category budget.
  const hosts = providers.slice(0, 2);
  await Promise.all(
    hosts.map(async function (provider) {
      const data = await requestJSON(
        provider.api,
        { ac: 'videolist', wd: title, pg: '1' },
        4000
      );
      const items = data && Array.isArray(data.list) ? data.list : [];
      for (let i = 0; i < items.length; i++) {
        const mapped = accept(provider, items[i]);
        if (!mapped) continue;
        let score = titleMatchScore(title, mapped.vod_name);
        if (score < 50) continue;
        if (entry.year && String(mapped.vod_year || '').indexOf(entry.year) >= 0) score += 8;
        score += itemScore(mapped);
        if (score > bestScore) {
          bestScore = score;
          best = mapped;
        }
      }
    })
  );
  if (!best) return null;
  if (entry.rating > 0) {
    best.vod_douban_score = String(entry.rating);
  }
  if (!best.vod_pic && entry.pic) best.vod_pic = entry.pic;
  best._douban_rank = entry.rank;
  return best;
}

const doubanEntryCache = { at: 0, byBucket: {} };
const doubanResolveCache = { at: 0, byBucket: {} };
const DOUBAN_CACHE_MS = 10 * 60 * 1000;

async function cachedDoubanEntries(bucket, count) {
  const now = Date.now();
  const cached = doubanEntryCache.byBucket[bucket];
  if (
    doubanEntryCache.at
    && now - doubanEntryCache.at < DOUBAN_CACHE_MS
    && cached
    && cached.length
  ) {
    return cached;
  }
  let entries = [];
  try {
    entries = await fetchDoubanHotEntries(bucket, count);
  } catch (e) {
    entries = [];
  }
  if (entries.length) {
    doubanEntryCache.at = now;
    doubanEntryCache.byBucket[bucket] = entries;
    return entries;
  }
  // Douban hung — keep last good chart past TTL (stale-while-revalidate).
  if (cached && cached.length) return cached;
  return [];
}

function staleDoubanResolved(bucket) {
  const cached = doubanResolveCache.byBucket[bucket];
  return cached && cached.length >= 4 ? cached.slice() : null;
}

/// Recommend: when Douban hotest is down, stitch last-good 剧/影/综/漫 charts.
function stitchStaleCategoryCharts() {
  const parts = ['tv', 'movie', 'variety', 'anime'];
  const lists = parts.map(function (key) {
    return doubanResolveCache.byBucket[key] || [];
  });
  const max = Math.max.apply(
    null,
    lists.map(function (rows) {
      return rows.length;
    }).concat([0])
  );
  if (!max) return null;
  const merged = [];
  const used = {};
  for (let i = 0; i < max && merged.length < FIRST_SCREEN * 2; i++) {
    for (let j = 0; j < lists.length; j++) {
      const item = lists[j][i];
      if (!item) continue;
      const key = normalizeTitle(item.vod_name);
      if (!key || used[key]) continue;
      used[key] = true;
      merged.push(item);
    }
  }
  return merged.length >= 4 ? merged : null;
}

function roughContentBucket(item) {
  const blob = [
    item && item.type_name,
    item && item.vod_class,
    item && item.vod_tag,
    item && item.vod_name,
  ].join('');
  if (/综艺|晚会|脱口秀|真人秀/.test(blob)) return 'variety';
  if (/动漫|动画|国漫|日漫|番剧/.test(blob)) return 'anime';
  if (/电影|影片|院线|剧场版/.test(blob)) return 'movie';
  return 'tv';
}

/// Mix types so CMS-only 推荐 is not one dump flood.
function interleaveByRoughBucket(list) {
  const buckets = { tv: [], movie: [], variety: [], anime: [] };
  for (let i = 0; i < (list || []).length; i++) {
    const item = list[i];
    buckets[roughContentBucket(item)].push(item);
  }
  const out = [];
  const max = Math.max(
    buckets.tv.length,
    buckets.movie.length,
    buckets.variety.length,
    buckets.anime.length
  );
  for (let i = 0; i < max; i++) {
    if (buckets.tv[i]) out.push(buckets.tv[i]);
    if (buckets.movie[i]) out.push(buckets.movie[i]);
    if (buckets.variety[i]) out.push(buckets.variety[i]);
    if (buckets.anime[i]) out.push(buckets.anime[i]);
  }
  return out.length ? out : list || [];
}

async function resolveDoubanHotList(bucket, providers, accept, options) {
  const now = Date.now();
  if (
    doubanResolveCache.at
    && now - doubanResolveCache.at < DOUBAN_CACHE_MS
    && doubanResolveCache.byBucket[bucket]
    && doubanResolveCache.byBucket[bucket].length >= 4
  ) {
    return doubanResolveCache.byBucket[bucket].slice();
  }
  // Cold-start / cache-only: still serve last good resolved list.
  if (options && options.allowNetwork === false) {
    return staleDoubanResolved(bucket);
  }
  // Wall-clock budget (JSC setTimeout is blocking — do not race with it).
  const budgetMs = options && options.budgetMs != null ? options.budgetMs : 3200;
  const deadline = now + budgetMs;
  const entries = await cachedDoubanEntries(bucket, 8);
  if (!entries.length) {
    return staleDoubanResolved(bucket);
  }
  const out = [];
  const used = {};
  for (let i = 0; i < entries.length; i += 4) {
    if (Date.now() > deadline) break;
    const chunk = entries.slice(i, i + 4);
    const found = await Promise.all(
      chunk.map(function (entry) {
        return findCMSMatchForTitle(entry, providers, accept);
      })
    );
    for (let j = 0; j < found.length; j++) {
      const item = found[j];
      if (!item) continue;
      const key = normalizeTitle(item.vod_name);
      if (!key || used[key]) continue;
      used[key] = true;
      out.push(item);
    }
    if (out.length >= FIRST_SCREEN) break;
  }
  if (out.length >= 4) {
    doubanResolveCache.at = Date.now();
    doubanResolveCache.byBucket[bucket] = out.slice();
    return out;
  }
  // Thin / timed-out resolve — prefer last good over CMS junk.
  const stale = staleDoubanResolved(bucket);
  if (stale) return stale;
  return out.length ? out : null;
}

/// When Douban chart miss/timeout: keep real TV/movies, drop short-drama floods.
function stableHotFallback(list) {
  const deduped = dedupeByTitle(list || []);
  const strong = [];
  const soft = [];
  for (let i = 0; i < deduped.length; i++) {
    const item = deduped[i];
    if (looksShortDrama(item)) continue;
    if (looksFranchiseDump(item)) continue;
    soft.push(item);
    const rank = majorPlatformRank(item);
    const year = Number(String(item.vod_year || '').slice(0, 4));
    const hasCast = String(item.vod_actor || '').trim().length > 1;
    const remarks = String(item.vod_remarks || item.vod_note || '');
    const updating = /更新/.test(remarks);
    const score = parseScore(item.vod_douban_score) || parseScore(item.vod_score);
    if (
      rank >= 2
      || score >= 6
      || (hasCast && Number.isFinite(year) && year >= 2020)
      || (updating && hasCast)
    ) {
      strong.push(item);
    }
  }
  // Always try to fill a screen — strong-only was leaving ~6–8 sparse rows.
  let pool = strong.length >= FIRST_SCREEN ? strong : soft.concat(strong);
  if (pool.length < FIRST_SCREEN) {
    pool = deduped.filter(function (item) {
      return !looksShortDrama(item) && !looksFranchiseDump(item);
    });
  }
  if (!pool.length) {
    pool = deduped.filter(function (item) {
      return !looksShortDrama(item);
    });
  }
  if (!pool.length) pool = deduped;
  return diversifyBySeriesFamily(
    diversifyByProvider(sortByHotRecent(dedupeByTitle(pool)), 3),
    1
  );
}

/// CMS-only compensation when Douban is down and no stale chart exists.
function compensatedCMSFallback(bucket, list) {
  let cleaned = stableHotFallback(list);
  const preferred = [];
  const rest = [];
  for (let i = 0; i < cleaned.length; i++) {
    const item = cleaned[i];
    const score = parseScore(item.vod_douban_score) || parseScore(item.vod_score);
    const rank = majorPlatformRank(item);
    const hasCast = String(item.vod_actor || '').trim().length > 1;
    const year = Number(String(item.vod_year || '').slice(0, 4));
    if (
      score >= 6
      || rank >= 2
      || (hasCast && Number.isFinite(year) && year >= 2022)
    ) {
      preferred.push(item);
    } else {
      rest.push(item);
    }
  }
  if (preferred.length >= Math.min(8, FIRST_SCREEN)) {
    cleaned = preferred.concat(rest);
  }
  cleaned = diversifyBySeriesFamily(
    diversifyByProvider(sortByHotRecent(cleaned), 2),
    1
  );
  if (bucket === 'recommend') {
    cleaned = interleaveByRoughBucket(cleaned);
  }
  return cleaned;
}

/// CMS first screen, then Douban order on top when chart resolves.
/// IMPORTANT: OnDevice JSC setTimeout is blocking (__firepickSleep). Never use
/// Promise.race(+setTimeout) here — it freezes the JS thread and Douban always "loses".
async function doubanOrCMSList(bucket, providers, accept, cmsFetcher, allowNetwork) {
  // Overlap CMS + Douban; keep Douban budget short so first paint is ~1–2s on Wi‑Fi.
  const cmsPromise = cmsFetcher();
  const doubanPromise =
    allowNetwork !== false
      ? resolveDoubanHotList(bucket, providers, accept, { budgetMs: 1400 }).catch(function () {
          return null;
        })
      : resolveDoubanHotList(bucket, providers, accept, { allowNetwork: false }).catch(
          function () {
            return null;
          }
        );
  const settled = await Promise.all([cmsPromise, doubanPromise]);
  const cmsList = settled[0];
  let douban = settled[1];
  if (!douban || douban.length < 4) {
    douban = staleDoubanResolved(bucket);
  }
  if ((!douban || douban.length < 4) && bucket === 'recommend') {
    douban = stitchStaleCategoryCharts();
  }
  const cms = stableHotFallback(cmsList || []);
  if (douban && douban.length >= 4) {
    const used = {};
    const merged = [];
    for (let i = 0; i < douban.length; i++) {
      const key = normalizeTitle(douban[i].vod_name);
      if (!key || used[key]) continue;
      used[key] = true;
      merged.push(douban[i]);
    }
    for (let i = 0; i < cms.length; i++) {
      const key = normalizeTitle(cms[i].vod_name);
      if (!key || used[key]) continue;
      used[key] = true;
      merged.push(cms[i]);
    }
    return { list: preferHealthyPics(healPicsByTitle(merged)), fromDouban: true };
  }
  return {
    list: preferHealthyPics(healPicsByTitle(compensatedCMSFallback(bucket, cmsList || []))),
    fromDouban: false,
  };
}

/// True when the user narrowed or re-sorted — keep that order (no platform shuffle).
function extendRequestsStrictOrder(extend) {
  const ext = extend && typeof extend === 'object' ? extend : {};
  if (String(ext.class || '')) return true;
  if (String(ext.area || '')) return true;
  if (String(ext.year || '')) return true;
  // Non-default sort key (movie default is ''; tv default is '')
  if (String(ext.by || '')) return true;
  return false;
}

const BATCH_SIZE = 8;
// Mobile/cellular often needs >4s; empty home with categories usually means timeout.
const REQUEST_TIMEOUT_MS = 12000;
// First-paint list fetch — don't let one slow host hold the grid for 12s.
const FIRST_PAINT_TIMEOUT_MS = 3500;
// Smaller first screen → stop waiting on slow CMS hosts sooner.
// First paint: 12 cards (~4 rows × 3). Smaller grids load covers faster.
const FIRST_SCREEN = 12;
const ADULT_PATTERN = /伦理|福利|里番|无码|有码|SWAG|色情|成人|黄游|性爱|口交|三级片/i;

function encode(value) {
  return encodeURIComponent(String(value == null ? '' : value));
}

function catalogParams(typeId, page, extend) {
  const params = {
    ac: 'videolist',
    t: typeId,
    pg: page,
  };
  const ext = extend && typeof extend === 'object' ? extend : {};
  const yearParam = String(ext.year || '');
  const areaParam = String(ext.area || '');
  const classParam = String(ext.class || '');
  if (/^\d{4}$/.test(yearParam)) params.year = yearParam;
  if (areaParam && areaParam !== '其他') params.area = areaParam;
  if (classParam) params.class = classParam;
  return params;
}

function buildURL(api, params) {
  const separator = api.indexOf('?') >= 0 ? '&' : '?';
  return api + separator + Object.keys(params)
    .filter(function (key) {
      return params[key] !== undefined && params[key] !== null;
    })
    .map(function (key) {
      return encode(key) + '=' + encode(params[key]);
    })
    .join('&');
}

async function requestJSON(api, params, timeout) {
  try {
    const response = await net.req(buildURL(api, params), {
      timeout: timeout || REQUEST_TIMEOUT_MS,
      headers: {
        'User-Agent': 'okhttp/4.1.0',
        Accept: 'application/json,text/plain,*/*',
      },
    });
    if (!response || response.code < 200 || response.code >= 300) return null;
    return JSON.parse(response.content);
  } catch (error) {
    return null;
  }
}

// Fill one screen from the fastest sites. Slow or dead hosts must not hold the page.
async function collectProviderLists(providers, page, limit, extra, accept, pageSpan) {
  const list = [];
  let cursor = 0;
  let stopped = false;
  // First paint: only the fastest few hosts; detail/search still use the full pool.
  const pool =
    limit <= FIRST_SCREEN * 2 ? providers.slice(0, Math.min(4, providers.length)) : providers;
  // Prefer a short span so the first screen returns before slow pages pile up.
  const span = pageSpan || (pool.length <= 2 ? 2 : 1);
  const start = (Math.max(1, Number(page) || 1) - 1) * span + 1;
  const concurrency = Math.min(4, pool.length);
  const paintTimeout = limit <= FIRST_SCREEN * 2 ? FIRST_PAINT_TIMEOUT_MS : REQUEST_TIMEOUT_MS;
  function take() {
    if (stopped || list.length >= limit || cursor >= pool.length) return null;
    const provider = pool[cursor];
    cursor += 1;
    return provider;
  }
  async function worker() {
    while (!stopped && list.length < limit) {
      const provider = take();
      if (!provider) return;
      for (let offset = 0; offset < span && !stopped && list.length < limit; offset++) {
        const params = { ac: 'videolist', pg: String(start + offset) };
        if (extra) {
          const keys = Object.keys(extra);
          for (let i = 0; i < keys.length; i++) params[keys[i]] = extra[keys[i]];
        }
        const data = await requestJSON(provider.api, params, paintTimeout);
        if (stopped || list.length >= limit) return;
        const items = data && Array.isArray(data.list) ? data.list : [];
        for (let i = 0; i < items.length && list.length < limit; i++) {
          const item = accept(provider, items[i]);
          if (item) list.push(item);
        }
        if (list.length >= limit) stopped = true;
      }
    }
  }
  const workers = [];
  for (let i = 0; i < concurrency; i++) workers.push(worker());
  await Promise.all(workers);
  return list;
}

async function collectTypedLists(targets, page, limit, extra, accept) {
  const list = [];
  let cursor = 0;
  let pagecount = Number(page) || 1;
  const concurrency = Math.min(4, targets.length);
  async function worker() {
    while (cursor < targets.length && list.length < limit) {
      const target = targets[cursor];
      cursor += 1;
      const params = { ac: 'videolist', t: String(target.typeId), pg: String(page) };
      if (extra && extra.year) params.year = extra.year;
      if (extra && extra.area) params.area = extra.area;
      if (extra && extra.class) params.class = extra.class;
      const data = await requestJSON(target.provider.api, params);
      const reported = Number(data && data.pagecount);
      if (Number.isFinite(reported) && reported > pagecount) pagecount = reported;
      const items = data && Array.isArray(data.list) ? data.list : [];
      for (let i = 0; i < items.length && list.length < limit; i++) {
        const item = accept(target.provider, items[i]);
        if (item) list.push(item);
      }
    }
  }
  const workers = [];
  for (let i = 0; i < concurrency; i++) workers.push(worker());
  await Promise.all(workers);
  return { list: list, pagecount: pagecount };
}

async function mapInBatches(items, batchSize, mapper) {
  const out = [];
  for (let i = 0; i < items.length; i += batchSize) {
    const chunk = items.slice(i, i + batchSize);
    const part = await Promise.all(chunk.map(mapper));
    for (let j = 0; j < part.length; j++) out.push(part[j]);
  }
  return out;
}

function providerID(provider, id) {
  return provider.key + '|' + id;
}

function splitID(value) {
  const text = String(value || '');
  const index = text.indexOf('|');
  if (index < 0) return null;
  return { provider: text.slice(0, index), id: text.slice(index + 1) };
}

function normalizeTitle(name) {
  return String(name || '')
    .replace(/\s+/g, '')
    .replace(/[　]/g, '')
    .replace(/[：:·\-—_|／/【】\[\]()（）「」『』《》<>]/g, '')
    // 一马当先 / 一马当先2026 / 一马当先第一季 → same show for list dedupe.
    .replace(/(?:第?[0-9０-９一二三四五六七八九十两]+季|第?[0-9０-９]+部|最终季|完结篇)$/g, '')
    .replace(/(?:19|20)\d{2}$/g, '')
    .toLowerCase();
}

function matchesArea(item, areaKey) {
  const area = String((item && item.vod_area) || '');
  const typeBlob = [item && item.type_name, item && item.vod_class, item && item.vod_tag].join('');
  if (areaKey === '其他') {
    return !/(大陆|中国|内地|香港|台湾|美国|韩国|日本|英国|国产)/.test(area)
      && !/(国产剧|大陆剧|香港|台湾|美剧|韩剧|日剧)/.test(typeBlob);
  }
  if (areaKey === '大陆') {
    if (/大陆|中国|内地/.test(area)) return true;
    if (/(香港|台湾|美国|韩国|日本|英国|泰国|新加坡|其他|其它)/.test(area)) return false;
    // Many CMS rows leave vod_area blank but tag 国产剧 / 大陆剧.
    if (!area.trim() && /国产|大陆|内地/.test(typeBlob)) return true;
    return false;
  }
  if (area.indexOf(areaKey) >= 0) return true;
  if (areaKey === '美国' && /美剧|欧美/.test(typeBlob)) return true;
  if (areaKey === '韩国' && /韩剧|韩国/.test(typeBlob)) return true;
  if (areaKey === '日本' && /日剧|日本/.test(typeBlob)) return true;
  if ((areaKey === '香港' || areaKey === '台湾') && typeBlob.indexOf(areaKey) >= 0) return true;
  return false;
}

function looksAdult(item) {
  if (!item) return true;
  const blob = [
    item.vod_name,
    item.type_name,
    item.vod_class,
    item.vod_tag,
    item.vod_remarks,
    item.vod_note,
  ].join(' ');
  return ADULT_PATTERN.test(blob);
}

/// 短剧 / 竖屏微短剧 — keep out of 电视剧 & 推荐 (they flood CMS “最新”).
/// Local franchise dumps (戏说台湾 / 同一【系列】刷屏) — keep ≤1 on 推荐.
function looksFranchiseDump(item) {
  if (!item) return false;
  const name = String(item.vod_name || '');
  if (/戏说台湾|台灣奇案|台湾奇案|民间剧场|民間劇場/.test(name)) return true;
  // 【xxx】title pattern flooding CMS “最新” with dozens of near-identical cards.
  if (/^[【\[][^】\]]{2,12}[】\]]/.test(name.trim()) && !/独播|腾讯|爱奇艺|优酷|芒果|B站/.test(name)) {
    const remarks = String(item.vod_remarks || item.vod_note || '');
    if (/已完结|全集/.test(remarks) && !/更新/.test(remarks)) return true;
  }
  return false;
}

function seriesFamilyKey(name) {
  const raw = String(name || '').trim();
  const bracket = raw.match(/^[【\[]([^】\]]+)[】\]]/);
  if (bracket) return normalizeTitle(bracket[1]);
  return normalizeTitle(raw).slice(0, 8);
}

/// Cap near-identical franchise cards so one dump cannot fill the grid.
function diversifyBySeriesFamily(list, perFamily) {
  const cap = Math.max(1, perFamily || 1);
  const counts = {};
  const out = [];
  for (let i = 0; i < (list || []).length; i++) {
    const item = list[i];
    const key = seriesFamilyKey(item && item.vod_name);
    if (!key) {
      out.push(item);
      continue;
    }
    counts[key] = counts[key] || 0;
    if (counts[key] >= cap) continue;
    counts[key] += 1;
    out.push(item);
  }
  return out;
}

function looksShortDrama(item) {
  if (!item) return true;
  const typeBlob = [item.type_name, item.vod_class, item.vod_tag].join('');
  if (/短剧|微短剧|竖屏|抖音剧|快手剧|小程序剧|短篇剧/.test(typeBlob)) return true;
  const name = String(item.vod_name || '');
  if (/短剧|微短剧/.test(name)) return true;
  const remarks = String(item.vod_remarks || item.vod_note || '');
  if (/竖屏|短剧|微短剧/.test(remarks)) return true;
  // Strong title tropes — enough alone (CMS often files these under 国产剧).
  if (
    /七零|八零|九零|团宠|闪婚|和离|家妻|家夫|夫君|萌宝|娇妻|弃妇|真千金|假千金|世子妃|娘娘|穿书|马甲|双穿|魂穿|白月光|麒麟血|觉醒后|分手后|退婚后|改嫁|替嫁|带球跑|霸总|神医战神|战神归来|争宠/.test(
      name
    )
  ) {
    return true;
  }
  // Weaker tropes + mini-drama pack size (全40–120集 / 已完结无“更新至”).
  const weakTrope =
    /重生|神医|战神|总裁|闪婚|娇妻|弃妇|千金|后妈|后爸|虐渣|打脸|逆袭|穿越|穿成/.test(name);
  const full = remarks.match(/全\s*(\d+)\s*集/);
  if (full && !/更新/.test(remarks)) {
    const n = Number(full[1]);
    if (Number.isFinite(n) && n >= 40 && n <= 120 && weakTrope) return true;
  }
  // “已完结” + weak trope + no year / low year often = short drama dump.
  if (weakTrope && /已完结|全集/.test(remarks) && !/更新/.test(remarks)) {
    const year = Number(String(item.vod_year || '').slice(0, 4));
    if (!Number.isFinite(year) || year < 2020) return true;
  }
  return false;
}

function coerceScore(value) {
  if (value == null || value === '') return 0;
  const n = Number(String(value).replace(/分/g, '').trim());
  return Number.isFinite(n) && n > 0 && n <= 10 ? n : 0;
}

/// List APIs often omit Douban; pull score from alternate keys / remarks.
function enrichScores(item) {
  if (!item) return item;
  let douban = coerceScore(item.vod_douban_score);
  let score = coerceScore(item.vod_score) || coerceScore(item.vod_scroe);
  if (!douban && !score) {
    const blob = String(item.vod_remarks || item.vod_note || '');
    let match = blob.match(/豆瓣[:：\s]*([0-9]+(?:\.[0-9])?)/);
    if (match) douban = coerceScore(match[1]);
    if (!douban) {
      match = blob.match(/(?:评分|满分)[:：\s]*([0-9]+(?:\.[0-9])?)/);
      if (match) score = coerceScore(match[1]);
    }
    if (!douban && !score) {
      match = blob.match(/\b([0-9]\.[0-9])\s*分\b/);
      if (match) score = coerceScore(match[1]);
    }
  }
  if (douban > 0) item.vod_douban_score = String(douban);
  if (score > 0) item.vod_score = String(score);
  return item;
}

function mediaItem(provider, item) {
  if (!item || item.vod_id === undefined || !item.vod_name) return null;
  if (looksAdult(item)) return null;
  item.vod_id = providerID(provider, item.vod_id);
  if (!item.vod_pic && item.vod_pic_thumb) item.vod_pic = item.vod_pic_thumb;
  if (item.vod_pic) item.vod_pic = rewritePicURL(item.vod_pic);
  if (!item.vod_remarks && item.vod_note) item.vod_remarks = item.vod_note;
  return enrichScores(item);
}

function itemScore(item) {
  let score = majorPlatformRank(item) * 10;
  // Prefer healthy cover CDNs so first-screen grids are not dominated by dead hosts.
  score += picQuality(item.vod_pic) * 3;
  if (item.vod_remarks || item.vod_note) score += 1;
  if (String(item.vod_actor || '').trim()) score += 1;
  return score;
}

function dedupeByTitle(list) {
  const best = new Map();
  const order = [];
  for (let i = 0; i < list.length; i++) {
    const item = list[i];
    const key = normalizeTitle(item.vod_name);
    if (!key) continue;
    const prev = best.get(key);
    if (!prev) {
      best.set(key, item);
      order.push(key);
      continue;
    }
    const platformDelta = majorPlatformRank(item) - majorPlatformRank(prev);
    if (platformDelta > 0) {
      best.set(key, item);
      continue;
    }
    if (platformDelta < 0) continue;
    const picDelta = picQuality(item.vod_pic) - picQuality(prev.vod_pic);
    // A working cover beats a slightly newer row with a dead CDN.
    if (picDelta >= 2) {
      best.set(key, item);
      continue;
    }
    if (picDelta <= -2) continue;
    const newer = recency(item) > recency(prev);
    const sameTimeBetterPic = recency(item) === recency(prev) && itemScore(item) > itemScore(prev);
    if (newer || sameTimeBetterPic) {
      best.set(key, item);
    }
  }
  return order.map(function (key) {
    return best.get(key);
  });
}

// Keep one hit per provider+title so source chips can rematch the same show.
function dedupeByProviderTitle(list) {
  const best = new Map();
  const order = [];
  for (let i = 0; i < list.length; i++) {
    const item = list[i];
    const title = normalizeTitle(item.vod_name);
    if (!title) continue;
    const split = splitID(item.vod_id);
    const provider = split ? split.provider : '';
    const key = provider + '\0' + title;
    const prev = best.get(key);
    if (!prev) {
      best.set(key, item);
      order.push(key);
      continue;
    }
    const newer = recency(item) > recency(prev);
    const sameTimeBetterPic = recency(item) === recency(prev) && itemScore(item) > itemScore(prev);
    if (newer || sameTimeBetterPic) {
      best.set(key, item);
    }
  }
  return order.map(function (key) {
    return best.get(key);
  });
}

/// Some AppleCMS hosts ignore `wd` and dump a generic videolist — drop those.
function matchesSearchQuery(item, key) {
  const q = normalizeTitle(key);
  if (!q) return true;
  const name = normalizeTitle(item && item.vod_name);
  if (name && name.indexOf(q) >= 0) return true;
  const actor = normalizeTitle(item && item.vod_actor);
  if (actor && actor.indexOf(q) >= 0) return true;
  const director = normalizeTitle(item && item.vod_director);
  if (director && director.indexOf(q) >= 0) return true;
  return false;
}

/// Hosts that currently return SSL/reset/timeout failures for covers (measured 2026-11-14).
function looksBrokenPicHost(pic) {
  // Measured flaky/dead cover CDNs — demote so heal/preferHealthy can pick alternatives.
  return /ok\.zuidapic\.com|fffgood\.com|xl\.xltupian\.com|maoyanimg\.top|p\.lztutu\.com|lztutu\.com/i.test(
    String(pic || '')
  );
}

/// Dead cover CDNs that share `/cover/<hash>` with healthy mirrors (速播→极速/光速).
const COVER_PIC_MIRRORS = [
  'img.jisuimage.com',
  'img.guangsuimage.com',
  'hhmage.com',
];

function rewritePicURL(pic) {
  const text = String(pic || '').trim();
  if (!text) return text;
  const brokenHost =
    /xl\.xltupian\.com|ok\.zuidapic\.com|fffgood\.com|maoyanimg\.top|lztutu\.com|ukzy|wujin|lzimg|tu\.jisu/i.test(
      text
    );
  if (!brokenHost) return text;
  // Only /cover/<hash> is shared across CMS mirrors. /upload/ hashes are
  // source-specific and rewriting them produces a 404 on the mirror.
  if (/\/cover\//i.test(text)) {
    return text.replace(/https?:\/\/[^/]+/i, 'https://' + COVER_PIC_MIRRORS[0]);
  }
  return text;
}

function picQuality(pic) {
  const text = String(pic || '').trim();
  if (!text) return 0;
  if (looksBrokenPicHost(text)) return 1;
  if (/img\.jisuimage\.com|img\.guangsuimage\.com|hhmage\.com|p\.bfp|doubanio\.com/i.test(text)) {
    return 4;
  }
  if (/^https?:\/\//i.test(text)) return 3;
  return 2;
}

/// 剧版 / 重制版 / 真人版 share a cover family with the main title prefix.
function coverFamilyKey(name) {
  let key = normalizeTitle(name);
  if (!key) return '';
  key = key.replace(
    /(?:真人版|剧版|重制版|重置版|电影版|动画版|电视版|完整版|特别版|纪念版|导演剪辑版|未删减版|加长版|抢先版)$/g,
    ''
  );
  return key || normalizeTitle(name);
}

/// Borrow a healthier cover: exact title first, then same family (凡人修仙传←重制版).
function healPicsByTitle(list) {
  const bestPic = new Map();
  const bestFamilyPic = new Map();
  for (let i = 0; i < list.length; i++) {
    const item = list[i];
    const key = normalizeTitle(item.vod_name);
    if (!key) continue;
    const pic = rewritePicURL(String(item.vod_pic || '').trim());
    if (pic && pic !== item.vod_pic) item.vod_pic = pic;
    if (picQuality(pic) < 3) continue;
    const prev = bestPic.get(key);
    if (!prev || picQuality(pic) > picQuality(prev)) {
      bestPic.set(key, pic);
    }
    const family = coverFamilyKey(item.vod_name);
    if (!family) continue;
    const prevFamily = bestFamilyPic.get(family);
    // Healthier CDN wins; ties prefer the shorter/base title as donor.
    if (
      !prevFamily ||
      picQuality(pic) > picQuality(prevFamily.pic) ||
      (picQuality(pic) === picQuality(prevFamily.pic) && key.length < prevFamily.keyLength)
    ) {
      bestFamilyPic.set(family, { pic: pic, keyLength: key.length });
    }
  }
  for (let i = 0; i < list.length; i++) {
    const item = list[i];
    const key = normalizeTitle(item.vod_name);
    if (!key) continue;
    if (picQuality(item.vod_pic) >= 3) continue;
    const exact = bestPic.get(key);
    if (exact) {
      item.vod_pic = exact;
      continue;
    }
    const family = coverFamilyKey(item.vod_name);
    const donor = family ? bestFamilyPic.get(family) : null;
    if (donor) item.vod_pic = donor.pic;
  }
  return list;
}

/// Push broken-CDN rows down so first-screen grids fill with loadable posters first.
function preferHealthyPics(list) {
  const good = [];
  const weak = [];
  for (let i = 0; i < list.length; i++) {
    if (picQuality(list[i].vod_pic) >= 3) good.push(list[i]);
    else weak.push(list[i]);
  }
  return good.concat(weak);
}

// Search must finish under ProviderCoordinator's budget (~5–10s). Slow hosts
// used to hold mapInBatches for 12s each and the whole search was cancelled empty.
const SEARCH_TIMEOUT_MS = 2800;

async function searchProviders(providers, key, pg, timeoutMs) {
  const budget = timeoutMs || SEARCH_TIMEOUT_MS;
  let responded = 0;
  // All hosts in parallel — do not wait on batch N before starting batch N+1.
  const results = await Promise.all(providers.map(async function (provider) {
    const data = await requestJSON(provider.api, {
      ac: 'videolist',
      wd: key,
      pg: String(pg || 1),
    }, budget);
    if (data && Array.isArray(data.list)) responded += 1;
    return { provider: provider, data: data };
  }));
  const list = [];
  for (let index = 0; index < results.length; index++) {
    const result = results[index];
    const items = result.data && Array.isArray(result.data.list)
      ? result.data.list
      : [];
    for (let j = 0; j < items.length; j++) {
      if (!matchesSearchQuery(items[j], key)) continue;
      const item = mediaItem(result.provider, Object.assign({}, items[j]));
      if (item) list.push(item);
    }
  }
  return {
    list: preferHealthyPics(healPicsByTitle(dedupeByProviderTitle(list))),
    responded: responded,
  };
}

function classifyTypeName(name) {
  const n = String(name || '').replace(/\s+/g, '');
  if (!n) return null;
  // Order matters: 动画片 / 纪录片 / 剧情片 must not fall through to 电视剧.
  if (/少儿|儿童|亲子|幼儿|卡通/.test(n)) return 'kids';
  if (/纪录/.test(n)) return 'doc';
  if (/短剧|微短剧|竖屏/.test(n)) return null; // not TV — filtered in lists
  if (/动漫|动画|番剧|国漫|日漫/.test(n)) return 'anime';
  if (/综艺|晚会|脱口秀|选秀/.test(n)) return 'variety';
  if (/电影|影片|院线|片/.test(n)) return 'movie';
  if (/连续剧|电视剧|美剧|韩剧|日剧|港剧|台剧|泰剧|国产剧|港台剧|日韩剧|欧美剧|海外剧|网剧|剧集/.test(n)) {
    return 'tv';
  }
  if (/剧/.test(n)) return 'tv';
  return null;
}

function directPlayableScore(group) {
  const episodes = String(group || '').split('#');
  let score = 0;
  for (let index = 0; index < episodes.length; index++) {
    const episode = episodes[index];
    const separator = episode.indexOf('$');
    const target = separator >= 0 ? episode.slice(separator + 1) : episode;
    if (/\.(m3u8|mp4|mkv|flv|ts|webm)(?:[?#]|$)/i.test(target)) score++;
  }
  return score;
}

// Some AppleCMS providers expose both a web page and a direct HLS line.
// Put the immediately playable line first so the player does not stop on a
// webpage that a native client cannot open.
function preferDirectPlaybackLines(item) {
  if (!item || typeof item.vod_play_url !== 'string') return item;
  const groups = item.vod_play_url.split('$$$');
  const names = String(item.vod_play_from || '').split('$$$');
  const indexes = groups.map(function (_, index) { return index; });
  const playableIndexes = indexes.filter(function (index) {
    return directPlayableScore(groups[index]) > 0;
  });
  const selectedIndexes = playableIndexes.length ? playableIndexes : indexes;
  selectedIndexes.sort(function (left, right) {
    return directPlayableScore(groups[right]) - directPlayableScore(groups[left]);
  });
  item.vod_play_from = selectedIndexes.map(function (index) {
    return names[index] || ('线路 ' + (index + 1));
  }).join('$$$');
  item.vod_play_url = selectedIndexes.map(function (index) {
    return groups[index];
  }).join('$$$');
  return item;
}

function emptyBucketMap() {
  return { tv: [], movie: [], variety: [], anime: [], kids: [], doc: [] };
}

function menuClasses() {
  return MENU.map(function (entry) {
    return {
      type_id: 'bucket|' + entry.id,
      type_name: entry.name,
    };
  });
}

export default class extends Spider {
  async init(ext) {
    this.providers = DEFAULT_PROVIDERS;
    this.typeIdsByBucket = emptyBucketMap();
    this.typeNameByProviderType = {};
    this.parentTypeIds = {};
    this.catalogReady = false;
    if (!ext) return;
    try {
      const config =
        typeof ext === 'string'
          ? (ext.trim() ? JSON.parse(ext) : null)
          : ext;
      if (config && Array.isArray(config.providers) && config.providers.length) {
        this.providers = config.providers
          .filter(function (item) {
            return item && item.key && item.api;
          })
          .map(function (item, index) {
            return {
              key: String(item.key),
              name: String(item.name || ('线路 ' + (index + 1))),
              api: String(item.api),
            };
          });
      }
    } catch (error) {}
  }

  rememberCatalog(provider, catalog) {
    const categories = catalog && Array.isArray(catalog.class) ? catalog.class : [];
    if (!this.typeIdsByBucket) this.typeIdsByBucket = emptyBucketMap();
    if (!this.typeNameByProviderType) this.typeNameByProviderType = {};
    for (let j = 0; j < categories.length; j++) {
      const category = categories[j];
      if (!category || category.type_id === undefined) continue;
      const typeName = category.type_name || '';
      const bucket = classifyTypeName(typeName);
      this.typeNameByProviderType[provider.key + '|' + category.type_id] = typeName;
      if (category.type_pid !== undefined && category.type_pid !== null && String(category.type_pid) !== '0') {
        if (!this.parentTypeIds) this.parentTypeIds = {};
        this.parentTypeIds[provider.key + '|' + category.type_pid] = true;
      }
      if (bucket && this.typeIdsByBucket[bucket]) {
        this.typeIdsByBucket[bucket].push({
          provider: provider,
          typeId: category.type_id,
          typeName: typeName,
          bucket: bucket,
        });
      }
    }
  }

  classifyItem(provider, item) {
    if (!item) return null;
    const byName = classifyTypeName(item.type_name) || classifyTypeName(item.vod_class);
    if (byName) return byName;
    const key = provider.key + '|' + item.type_id;
    return classifyTypeName(this.typeNameByProviderType && this.typeNameByProviderType[key]);
  }

  async providerData(provider) {
    const [catalog, latest] = await Promise.all([
      requestJSON(provider.api, { ac: 'list' }),
      requestJSON(provider.api, { ac: 'videolist', pg: '1' }),
    ]);
    return { provider: provider, catalog: catalog, latest: latest };
  }

  buildRecommendList(results) {
    const buckets = { tv: [], movie: [], variety: [] };
    for (let index = 0; index < results.length; index++) {
      const result = results[index];
      const provider = result.provider;
      const items = result.latest && Array.isArray(result.latest.list)
        ? result.latest.list
        : [];
      // Cap per provider so home stays snappy with 20+ backends.
      const limit = Math.min(items.length, 8);
      for (let k = 0; k < limit; k++) {
        const item = mediaItem(provider, Object.assign({}, items[k]));
        if (!item) continue;
        const bucket = this.classifyItem(provider, items[k]);
        if (bucket === 'tv' || bucket === 'movie' || bucket === 'variety') {
          buckets[bucket].push(item);
        }
      }
    }
    const list = [];
    const max = Math.max(buckets.tv.length, buckets.movie.length, buckets.variety.length);
    for (let i = 0; i < max; i++) {
      if (buckets.tv[i]) list.push(buckets.tv[i]);
      if (buckets.movie[i]) list.push(buckets.movie[i]);
      if (buckets.variety[i]) list.push(buckets.variety[i]);
    }
    return sortByRecency(dedupeByTitle(list)).slice(0, 60);
  }

  async homeContent(filter) {
    const configuredProviders = this.providers || DEFAULT_PROVIDERS;
    const providers = configuredProviders;
    const self = this;
    function acceptHome(provider, row) {
      if (looksShortDrama(row)) return null;
      if (looksFranchiseDump(row)) return null;
      const bucket = self.classifyItem(provider, row);
      if (bucket !== 'tv' && bucket !== 'movie' && bucket !== 'variety' && bucket !== 'anime') {
        return null;
      }
      return mediaItem(provider, Object.assign({}, row));
    }
    // Allow Douban network — `false` left 推荐 stuck on CMS “最新” dumps (戏说台湾刷屏).
    const packed = await doubanOrCMSList(
      'recommend',
      providers,
      acceptHome,
      function () {
        return collectProviderLists(providers, 1, FIRST_SCREEN * 3, null, acceptHome);
      },
      true
    );
    let list = packed.fromDouban
      ? packed.list
      : diversifyBySeriesFamily(
          diversifyByProvider(sortByHotRecent(packed.list), 3),
          1
        );
    list = preferHealthyPics(healPicsByTitle(list));
    if (list.length < FIRST_SCREEN) {
      const cmsMore = await collectProviderLists(
        providers,
        1,
        FIRST_SCREEN * 2,
        null,
        acceptHome
      );
      const used = {};
      for (let i = 0; i < list.length; i++) {
        const key = normalizeTitle(list[i].vod_name);
        if (key) used[key] = true;
      }
      for (let i = 0; i < cmsMore.length && list.length < FIRST_SCREEN; i++) {
        const key = normalizeTitle(cmsMore[i].vod_name);
        if (!key || used[key]) continue;
        used[key] = true;
        list.push(cmsMore[i]);
      }
      list = preferHealthyPics(healPicsByTitle(list));
    }
    list = list.slice(0, FIRST_SCREEN);
    return {
      class: menuClasses(),
      list: list,
      filters: menuFilters(),
    };
  }

  async homeVideoContent() {
    const result = await this.homeContent(false);
    return { list: result.list };
  }

  async ensureCatalogs() {
    if (this.catalogReady) return;
    const providers = this.providers || DEFAULT_PROVIDERS;
    await Promise.all(providers.map(async (provider) => {
      const catalog = await requestJSON(provider.api, { ac: 'list' });
      this.rememberCatalog(provider, catalog);
    }));
    this.catalogReady = true;
  }

  leafTargets(bucket) {
    const all = (this.typeIdsByBucket && this.typeIdsByBucket[bucket]) || [];
    const parents = this.parentTypeIds || {};
    const leaves = all.filter(function (target) {
      const name = target.typeName || '';
      if (/里番|伦理|福利|色情|短剧|微短剧|竖屏/.test(name)) return false;
      return !parents[target.provider.key + '|' + target.typeId];
    });
    return leaves.length ? leaves : all.filter(function (target) {
      return !/里番|伦理|福利|色情|短剧|微短剧|竖屏/.test(target.typeName || '');
    });
  }

  /// One leaf type per provider for first screen (avoids 40+ typed requests).
  preferredLeafTargets(bucket, targets) {
    const prefer = {
      tv: /国产剧|连续剧|电视剧|港台剧|日韩剧|欧美剧|美剧|韩剧/,
      movie: /电影|动作片|喜剧片|爱情片|剧情片|科幻片|恐怖片|战争片|纪录片/,
      variety: /综艺|晚会|脱口秀/,
      anime: /动漫|国漫|日漫|动画/,
    };
    const re = prefer[bucket];
    const best = new Map();
    for (let i = 0; i < targets.length; i++) {
      const target = targets[i];
      const key = target.provider.key;
      const prev = best.get(key);
      if (!prev) {
        best.set(key, target);
        continue;
      }
      if (re && re.test(target.typeName || '') && !re.test(prev.typeName || '')) {
        best.set(key, target);
      }
    }
    return Array.from(best.values());
  }

  async bucketContent(bucket, pg, extend) {
    const configuredProviders = this.providers || DEFAULT_PROVIDERS;
    const providers = configuredProviders;
    const providerKeys = new Set(providers.map(function (provider) {
      return provider.key;
    }));
    const requestedPage = Math.max(1, Number(pg) || 1);
    const self = this;
    const classKey = String((extend && extend.class) || '');
    const areaKey = String((extend && extend.area) || '');
    const yearKey = String((extend && extend.year) || '');
    const sortKey = String((extend && extend.by) || '');
    const extra = {};
    if (extend && /^\d{4}$/.test(String(extend.year || ''))) {
      extra.year = String(extend.year);
    }
    if (areaKey && areaKey !== '其他') extra.area = areaKey;
    if (classKey && bucket !== 'anime') extra.class = classKey;
    let list = [];
    let reportedPages = requestedPage;

    function acceptRow(provider, row) {
      // 电视剧 / 推荐：丢掉短剧，避免“最新”被竖屏短剧刷屏。
      if ((bucket === 'tv' || bucket === 'recommend') && looksShortDrama(row)) {
        return null;
      }
      if (bucket === 'recommend' && looksFranchiseDump(row)) {
        return null;
      }
      const found = self.classifyItem(provider, row);
      if (bucket === 'recommend') {
        if (found !== 'tv' && found !== 'movie' && found !== 'variety' && found !== 'anime') return null;
      } else if (found !== bucket) {
        return null;
      }
      if (bucket === 'anime' && classKey && !matchesAnimeClass(row, classKey)) {
        return null;
      }
      if (found === 'kids' || found === 'doc') return null;
      return mediaItem(provider, Object.assign({}, row));
    }

    // Warm catalogs in the background — do not block the first screen on 7× ac=list.
    if (!this.catalogReady) {
      this.ensureCatalogs().catch(function () {});
    }

    // Default 推荐桶外各分类（含电影）与显式「豆瓣热门」：Douban 榜单优先，
    // 对齐腾讯/爱奇艺/优酷/芒果/B站热播；CMS 作续页与兜底。
    const wantDouban =
      !classKey
      && !areaKey
      && !yearKey
      && (sortKey === 'douban_hot' || sortKey === '');
    const filtered = extendRequestsStrictOrder(extend);

    if (wantDouban && requestedPage === 1 && !filtered) {
      const want = FIRST_SCREEN;
      const packed = await doubanOrCMSList(bucket, providers, acceptRow, function () {
        return collectProviderLists(providers, 1, want * 2, extra, acceptRow);
      });
      if (packed.list.length) {
        let ordered = packed.fromDouban
          ? packed.list
          : diversifyByProvider(sortByHotRecent(packed.list), 4);
        ordered = preferHealthyPics(healPicsByTitle(ordered));
        function padOrdered(fromList) {
          const used = {};
          for (let i = 0; i < ordered.length; i++) {
            const key = normalizeTitle(ordered[i].vod_name);
            if (key) used[key] = true;
          }
          for (let i = 0; i < (fromList || []).length && ordered.length < FIRST_SCREEN; i++) {
            const key = normalizeTitle(fromList[i].vod_name);
            if (!key || used[key]) continue;
            used[key] = true;
            ordered.push(fromList[i]);
          }
        }
        // Douban / CMS first paint often resolves <12 — pad until a full screen.
        if (ordered.length < FIRST_SCREEN) {
          const cmsMore = await collectProviderLists(
            providers,
            1,
            FIRST_SCREEN * 4,
            extra,
            acceptRow
          );
          padOrdered(cmsMore);
        }
        // Still thin: pull typed 电影/剧 leaves (videolist “最新” is mostly noise).
        if (ordered.length < FIRST_SCREEN && bucket !== 'recommend') {
          await this.ensureCatalogs();
          let targets = this.leafTargets(bucket).filter(function (target) {
            return providerKeys.has(target.provider.key);
          });
          targets = this.preferredLeafTargets(bucket, targets);
          if (targets.length) {
            const typed = await collectTypedLists(
              targets,
              1,
              FIRST_SCREEN * 3,
              extra,
              acceptRow
            );
            padOrdered(typed.list || []);
          }
        }
        ordered = preferHealthyPics(healPicsByTitle(ordered));
        // Keep pagecount open so loadMore can pull CMS pages 2+.
        return {
          page: 1,
          pagecount: 99,
          limit: ordered.length,
          total: ordered.length,
          list: ordered.slice(0, FIRST_SCREEN),
        };
      }
    }

    // Page 1 unfiltered: videolist (fast). Filtered (地区/年份/类型): typed
    // 国产剧 leaves + deeper pull — CMS area=大陆 “最新” is mostly 短剧/更新中,
    // so completed hits like 嫁金钗 never appear unless we query category pages.
    if (requestedPage === 1 && !filtered) {
      const want = FIRST_SCREEN;
      list = await collectProviderLists(
        providers,
        1,
        want * 2,
        extra,
        acceptRow
      );
      // videolist “最新” rarely yields 12 in-bucket hits — fall through to typed leaves.
      if (list.length < FIRST_SCREEN && bucket !== 'recommend') {
        await this.ensureCatalogs();
        let targets = this.leafTargets(bucket).filter(function (target) {
          return providerKeys.has(target.provider.key);
        });
        targets = this.preferredLeafTargets(bucket, targets);
        if (targets.length) {
          const typed = await collectTypedLists(
            targets,
            1,
            FIRST_SCREEN * 3,
            extra,
            acceptRow
          );
          const used = {};
          for (let i = 0; i < list.length; i++) {
            const key = normalizeTitle(list[i].vod_name);
            if (key) used[key] = true;
          }
          for (let i = 0; i < (typed.list || []).length && list.length < FIRST_SCREEN; i++) {
            const key = normalizeTitle(typed.list[i].vod_name);
            if (!key || used[key]) continue;
            used[key] = true;
            list.push(typed.list[i]);
          }
          reportedPages = Math.max(reportedPages, typed.pagecount || 1, 2);
        }
      }
    } else if (bucket !== 'recommend') {
      await this.ensureCatalogs();
      let targets = this.leafTargets(bucket).filter(function (target) {
        return providerKeys.has(target.provider.key);
      });
      if (bucket === 'anime' && classKey) {
        targets = targets.filter(function (target) {
          return animeLeafKind(target.typeName) === classKey;
        });
      }
      if (filtered && areaKey === '大陆' && bucket === 'tv') {
        const mainland = targets.filter(function (target) {
          return /国产|大陆|内地/.test(target.typeName || '');
        });
        if (mainland.length) targets = mainland;
      }
      targets = this.preferredLeafTargets(bucket, targets);
      if (targets.length) {
        const typedAccept = function (provider, row) {
          if (bucket === 'tv' && looksShortDrama(row)) return null;
          if (self.classifyItem(provider, row) === 'kids'
            || self.classifyItem(provider, row) === 'doc') {
            return null;
          }
          if (bucket === 'anime' && classKey && !matchesAnimeClass(row, classKey)) {
            return null;
          }
          return mediaItem(provider, Object.assign({}, row));
        };
        const want = filtered ? FIRST_SCREEN * 4 : FIRST_SCREEN;
        const typed = await collectTypedLists(
          targets,
          requestedPage,
          want,
          extra,
          typedAccept
        );
        list = typed.list;
        reportedPages = typed.pagecount;
        // Filtered page 1: also pull page 2 so 已完结热门 (嫁金钗…) aren't buried.
        if (filtered && requestedPage === 1) {
          const more = await collectTypedLists(targets, 2, FIRST_SCREEN * 2, extra, typedAccept);
          list = list.concat(more.list);
          reportedPages = Math.max(reportedPages, more.pagecount, 2);
        }
      }
    }
    if (!list.length) {
      list = await collectProviderLists(
        providers,
        requestedPage,
        FIRST_SCREEN,
        extra,
        acceptRow
      );
    }
    let deduped = applyExtend(dedupeByTitle(list), extend, bucket);
    // Heal covers on every bucket path — movie/TV CMS rows often ship dead CDNs.
    deduped = preferHealthyPics(healPicsByTitle(deduped));
    if (bucket === 'recommend' && !filtered) {
      deduped = diversifyBySeriesFamily(diversifyByProvider(deduped, 3), 1);
    }
    // Do not diversify after explicit sort — it scrambled 上映时间 / 豆瓣热门 / 最新更新.
    const hasMore = reportedPages > requestedPage || deduped.length >= FIRST_SCREEN;
    return {
      page: requestedPage,
      pagecount: hasMore ? requestedPage + 1 : requestedPage,
      limit: deduped.length,
      total: deduped.length,
      list: requestedPage === 1 && !filtered
        ? deduped.slice(0, FIRST_SCREEN)
        : deduped,
    };
  }

  async categoryContent(tid, pg, filter, extend) {
    const value = splitID(tid);
    if (!value) return { list: [] };

    if (value.provider === 'bucket') {
      return this.bucketContent(value.id, pg, extend);
    }

    const provider = this.providers.find(function (item) {
      return item.key === value.provider;
    });
    if (!provider) return { list: [] };
    const data = await requestJSON(
      provider.api,
      catalogParams(value.id, String(pg || 1), extend)
    );
    const list = data && Array.isArray(data.list) ? data.list : [];
    const mapped = applyExtend(
      list.map(function (item) {
        return mediaItem(provider, Object.assign({}, item));
      }).filter(Boolean),
      extend,
      null
    );
    return {
      page: pg || 1,
      pagecount: data && data.pagecount ? data.pagecount : 1,
      limit: data && data.limit ? data.limit : mapped.length,
      total: data && data.total ? data.total : mapped.length,
      list: mapped,
    };
  }

  async searchContent(key, quick, pg) {
    const configured = this.providers || DEFAULT_PROVIDERS;
    // Wave 1: only the first few (already ordered for healthy/fast hosts).
    const wave1 = configured.slice(0, Math.min(4, configured.length));
    let packed = await searchProviders(wave1, key, pg, 2500);
    // Wave 2: rest of the active pool if wave 1 missed.
    if (packed.list.length === 0 && configured.length > wave1.length) {
      packed = await searchProviders(configured, key, pg, SEARCH_TIMEOUT_MS);
    }
    // Wave 3: bundled defaults when the 测速 pool is empty/flaky.
    if (
      packed.list.length === 0
      && configured !== DEFAULT_PROVIDERS
      && configured.length
    ) {
      const fallback = await searchProviders(DEFAULT_PROVIDERS, key, pg, SEARCH_TIMEOUT_MS);
      if (fallback.list.length || fallback.responded > packed.responded) {
        packed = fallback;
      }
    }
    if (packed.list.length === 0 && packed.responded === 0) {
      throw new Error('采集站暂时不可用，请稍后重试或重新测速');
    }
    return { list: packed.list };
  }

  async detailContent(ids) {
    const value = splitID(Array.isArray(ids) ? ids[0] : ids);
    if (!value) return { list: [] };
    const provider = this.providers.find(function (item) {
      return item.key === value.provider;
    });
    if (!provider) return { list: [] };
    const data = await requestJSON(provider.api, {
      ac: 'detail',
      ids: value.id,
    });
    if (!data || !Array.isArray(data.list) || !data.list.length) {
      return { list: [] };
    }
    const item = preferDirectPlaybackLines(data.list[0]);
    item.vod_id = providerID(provider, item.vod_id || value.id);
    return { list: [item] };
  }

  async playerContent(flag, id, vipFlags) {
    const value = String(id || '');
    if (!value) return {};
    return {
      parse: 0,
      url: value,
      flag: flag,
    };
  }
}
