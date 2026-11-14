import { Spider, net } from 'catvod';

// Curated from LunaTV jin18 + local probe (scripts/probe-cms-providers.mjs).
// Re-run the probe periodically; dead hosts drag search latency.
const DEFAULT_PROVIDERS = [
  { key: 'iqiyi', name: '爱奇艺', api: 'https://iqiyizyapi.com/api.php/provide/vod' },
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

const FILTER_SORT = [
  { n: '热门', v: '' },
  { n: '最新', v: 'time' },
  { n: '最热', v: 'hits' },
  { n: '豆瓣评分', v: 'douban' },
];

function sourceFilter(providers) {
  if (providers.length < 2) return null;
  return {
    key: 'source',
    name: '源站',
    init: providers[0].key,
    value: providers.map(function (provider) {
      return { n: provider.name, v: provider.key };
    }),
  };
}

function bucketFilters(bucket, providers) {
  const anime = bucket === 'anime';
  const filters = [];
  const source = sourceFilter(providers);
  if (source) filters.push(source);
  filters.push({
    key: 'class',
    name: '类型',
    init: '',
    value: anime ? ANIME_CLASS : FILTER_CLASS,
  });
  if (!anime) {
    filters.push({ key: 'area', name: '地区', value: FILTER_AREA });
  }
  filters.push({ key: 'year', name: '年份', value: FILTER_YEAR });
  filters.push({ key: 'by', name: '排序', value: FILTER_SORT });
  return filters;
}

function menuFilters(providers) {
  const filters = {};
  for (let i = 0; i < MENU.length; i++) {
    const entry = MENU[i];
    if (entry.id === 'recommend') continue;
    filters['bucket|' + entry.id] = bucketFilters(entry.id, providers);
  }
  return filters;
}

// One line, one source site at a time. An empty choice stays on the first site.
function activeProviders(providers, extend) {
  const all =
    Array.isArray(providers) && providers.length ? providers : DEFAULT_PROVIDERS;
  const key = extend && String(extend.source || '');
  if (key) {
    const found = all.filter(function (provider) {
      return provider.key === key;
    });
    if (found.length) return found;
  }
  return all.slice(0, 1);
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

function hotRecentScore(item, current) {
  const year = Number(String((item && item.vod_year) || '').slice(0, 4));
  let yearRank = 0;
  if (Number.isFinite(year) && year >= current) yearRank = 3;
  else if (Number.isFinite(year) && year >= current - 1) yearRank = 2;
  else if (Number.isFinite(year) && year >= current - 2) yearRank = 1;
  return yearRank * 1e12 + parseScore(item && item.vod_hits) * 1000 + recency(item) / 1e8;
}

function applyExtend(list, extend) {
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
      const area = String(item.vod_area || '');
      if (areaKey === '其他') {
        return !/(大陆|中国|香港|台湾|美国|韩国|日本|英国)/.test(area);
      }
      return area.indexOf(areaKey) >= 0 || (areaKey === '大陆' && /中国/.test(area));
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
      return parseScore(b.vod_hits) - parseScore(a.vod_hits);
    });
  } else if (sortKey === 'douban') {
    out.sort(function (a, b) {
      const left = parseScore(a.vod_douban_score) || parseScore(a.vod_score);
      const right = parseScore(b.vod_douban_score) || parseScore(b.vod_score);
      if (right !== left) return right - left;
      return recency(b) - recency(a);
    });
  } else if (sortKey === 'time') {
    out = sortByRecency(out);
  } else {
    out = sortByHotRecent(out);
  }
  return out;
}

const BATCH_SIZE = 8;
// Mobile/cellular often needs >4s; empty home with categories usually means timeout.
const REQUEST_TIMEOUT_MS = 12000;
const FIRST_SCREEN = 36;
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
  // Prefer a short span so the first screen returns before slow pages pile up.
  const span = pageSpan || (providers.length <= 2 ? 2 : 1);
  const start = (Math.max(1, Number(page) || 1) - 1) * span + 1;
  const concurrency = Math.min(10, providers.length);
  function take() {
    if (stopped || list.length >= limit || cursor >= providers.length) return null;
    const provider = providers[cursor];
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
        const data = await requestJSON(provider.api, params);
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
    .toLowerCase();
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

function mediaItem(provider, item) {
  if (!item || item.vod_id === undefined || !item.vod_name) return null;
  if (looksAdult(item)) return null;
  item.vod_id = providerID(provider, item.vod_id);
  if (!item.vod_pic && item.vod_pic_thumb) item.vod_pic = item.vod_pic_thumb;
  if (!item.vod_remarks && item.vod_note) item.vod_remarks = item.vod_note;
  return item;
}

function itemScore(item) {
  let score = 0;
  if (item.vod_pic) score += 2;
  if (item.vod_remarks || item.vod_note) score += 1;
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

function classifyTypeName(name) {
  const n = String(name || '').replace(/\s+/g, '');
  if (!n) return null;
  // Order matters: 动画片 / 纪录片 / 剧情片 must not fall through to 电视剧.
  if (/少儿|儿童|亲子|幼儿|卡通/.test(n)) return 'kids';
  if (/纪录/.test(n)) return 'doc';
  if (/动漫|动画|番剧|国漫|日漫/.test(n)) return 'anime';
  if (/综艺|晚会|脱口秀|选秀/.test(n)) return 'variety';
  if (/电影|影片|院线|片/.test(n)) return 'movie';
  if (/连续剧|电视剧|美剧|韩剧|日剧|港剧|台剧|泰剧|国产剧|港台剧|日韩剧|欧美剧|海外剧|短剧|网剧|剧集/.test(n)) {
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
    const providers = activeProviders(configuredProviders, null);
    const self = this;
    const list = await collectProviderLists(providers, 1, FIRST_SCREEN, null, function (provider, row) {
      const bucket = self.classifyItem(provider, row);
      if (bucket !== 'tv' && bucket !== 'movie' && bucket !== 'variety' && bucket !== 'anime') return null;
      return mediaItem(provider, Object.assign({}, row));
    });
    return {
      class: menuClasses(),
      list: sortByHotRecent(dedupeByTitle(list)),
      filters: menuFilters(configuredProviders),
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
      if (/里番|伦理|福利|色情/.test(target.typeName || '')) return false;
      return !parents[target.provider.key + '|' + target.typeId];
    });
    return leaves.length ? leaves : all.filter(function (target) {
      return !/里番|伦理|福利|色情/.test(target.typeName || '');
    });
  }

  async bucketContent(bucket, pg, extend) {
    const configuredProviders = this.providers || DEFAULT_PROVIDERS;
    const providers = activeProviders(configuredProviders, extend);
    const providerKeys = new Set(providers.map(function (provider) {
      return provider.key;
    }));
    const requestedPage = Math.max(1, Number(pg) || 1);
    const self = this;
    const classKey = String((extend && extend.class) || '');
    const areaKey = String((extend && extend.area) || '');
    const extra = {};
    if (extend && /^\d{4}$/.test(String(extend.year || ''))) {
      extra.year = String(extend.year);
    }
    if (areaKey && areaKey !== '其他') extra.area = areaKey;
    if (classKey && bucket !== 'anime') extra.class = classKey;
    let list = [];
    let reportedPages = requestedPage;
    if (bucket !== 'recommend') {
      await this.ensureCatalogs();
      let targets = this.leafTargets(bucket).filter(function (target) {
        return providerKeys.has(target.provider.key);
      });
      if (bucket === 'anime' && classKey) {
        targets = targets.filter(function (target) {
          return animeLeafKind(target.typeName) === classKey;
        });
      }
      if (targets.length) {
        const typed = await collectTypedLists(targets, requestedPage, bucket === 'anime' ? 24 : 60, extra, function (provider, row) {
          if (self.classifyItem(provider, row) === 'kids' || self.classifyItem(provider, row) === 'doc') {
            return null;
          }
          if (bucket === 'anime' && classKey && !matchesAnimeClass(row, classKey)) {
            return null;
          }
          return mediaItem(provider, Object.assign({}, row));
        });
        list = typed.list;
        reportedPages = typed.pagecount;
      }
    }
    if (!list.length) {
      list = await collectProviderLists(
        providers,
        requestedPage,
        FIRST_SCREEN,
        extra,
        function (provider, row) {
          const found = self.classifyItem(provider, row);
          if (bucket === 'recommend') {
            if (found !== 'tv' && found !== 'movie' && found !== 'variety' && found !== 'anime') return null;
          } else if (found !== bucket) {
            return null;
          }
          if (bucket === 'anime' && classKey && !matchesAnimeClass(row, classKey)) {
            return null;
          }
          return mediaItem(provider, Object.assign({}, row));
        }
      );
    }
    const deduped = applyExtend(dedupeByTitle(list), extend);
    const hasMore = reportedPages > requestedPage || deduped.length >= 12;
    return {
      page: requestedPage,
      pagecount: hasMore ? requestedPage + 1 : requestedPage,
      limit: deduped.length,
      total: deduped.length,
      list: deduped,
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
      extend
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
    const providers = this.providers || DEFAULT_PROVIDERS;
    const results = await mapInBatches(providers, BATCH_SIZE, async function (provider) {
      const data = await requestJSON(provider.api, {
        ac: 'videolist',
        wd: key,
        pg: String(pg || 1),
      });
      return { provider: provider, data: data };
    });
    const list = [];
    for (let index = 0; index < results.length; index++) {
      const result = results[index];
      const items = result.data && Array.isArray(result.data.list)
        ? result.data.list
        : [];
      for (let j = 0; j < items.length; j++) {
        const item = mediaItem(result.provider, Object.assign({}, items[j]));
        if (item) list.push(item);
      }
    }
    return { list: dedupeByTitle(list) };
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
