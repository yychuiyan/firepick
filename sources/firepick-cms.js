import { Spider, net } from 'catvod';

// Curated from LunaTV jin18 + local probe (scripts/probe-cms-providers.mjs).
// Re-run the probe periodically; dead hosts drag search latency.
const DEFAULT_PROVIDERS = [
  { key: 'iqiyi', name: '爱奇艺资源', api: 'https://iqiyizyapi.com/api.php/provide/vod' },
  { key: 'dytt', name: '电影天堂', api: 'https://caiji.dyttzyapi.com/api.php/provide/vod' },
  { key: 'maoyan', name: '猫眼资源', api: 'https://api.maoyanapi.top/api.php/provide/vod' },
  { key: 'lzcaiji', name: '量子资源', api: 'https://cj.lzcaiji.com/api.php/provide/vod' },
  { key: 'lzi', name: '量子影视', api: 'https://cj.lziapi.com/api.php/provide/vod' },
  { key: 'zy360', name: '360资源', api: 'https://360zyzz.com/api.php/provide/vod' },
  { key: 'jisu', name: '极速资源', api: 'https://jszyapi.com/api.php/provide/vod' },
  { key: 'modu', name: '魔都资源', api: 'https://www.mdzyapi.com/api.php/provide/vod' },
  { key: 'ffzy', name: '非凡资源', api: 'https://api.ffzyapi.com/api.php/provide/vod' },
  { key: 'bfzy', name: '暴风资源', api: 'https://bfzyapi.com/api.php/provide/vod' },
  { key: 'zuid', name: '最大资源', api: 'https://api.zuidapi.com/api.php/provide/vod' },
  { key: 'xinlang', name: '新浪资源', api: 'https://api.xinlangapi.com/xinlangapi.php/provide/vod' },
  { key: 'subo', name: '速播资源', api: 'https://subocaiji.com/api.php/provide/vod' },
  { key: 'jinying', name: '金鹰点播', api: 'https://jyzyapi.com/provide/vod/from/jinyingyun/at/json' },
  { key: 'uku', name: 'U酷影视', api: 'https://api.ukuapi88.com/api.php/provide/vod' },
  { key: 'guangsu', name: '光速资源', api: 'https://api.guangsuapi.com/api.php/provide/vod' },
  { key: 'hongniu', name: '红牛资源', api: 'https://www.hongniuzy2.com/api.php/provide/vod' },
  { key: 'moduanime', name: '魔都动漫', api: 'https://caiji.moduapi.cc/api.php/provide/vod' },
  { key: 'ruyi', name: '如意资源', api: 'https://cj.rycjapi.com/api.php/provide/vod' },
  { key: 'haohua', name: '豪华资源', api: 'https://hhzyapi.com/api.php/provide/vod' },
  { key: 'yzzy', name: '优质资源', api: 'https://api.yzzy-api.com/inc/apijson.php' },
  { key: 'huya', name: '虎牙资源', api: 'https://www.huyaapi.com/api.php/provide/vod' },
  { key: 'ffzy_cj', name: '非凡采集', api: 'https://cj.ffzyapi.com/api.php/provide/vod' },
  { key: 'movie_legacy', name: '影视资源', api: 'https://dy.7772888.xyz/api.php/tvbox' },
];

const MENU = [
  { id: 'recommend', name: '推荐' },
  { id: 'tv', name: '电视剧' },
  { id: 'movie', name: '电影' },
  { id: 'variety', name: '综艺' },
  { id: 'anime', name: '动漫' },
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
  { n: '综合', v: '' },
  { n: '最新', v: 'year' },
  { n: '豆瓣评分', v: 'douban' },
];

function bucketFilters() {
  return [
    { key: 'class', name: '类型', value: FILTER_CLASS },
    { key: 'area', name: '地区', value: FILTER_AREA },
    { key: 'year', name: '年份', value: FILTER_YEAR },
    { key: 'by', name: '排序', value: FILTER_SORT },
  ];
}

function menuFilters() {
  const filters = {};
  for (let i = 0; i < MENU.length; i++) {
    const entry = MENU[i];
    if (entry.id === 'recommend') continue;
    filters['bucket|' + entry.id] = bucketFilters();
  }
  return filters;
}

function parseScore(value) {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? n : 0;
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
      const blob = [item.type_name, item.vod_class, item.vod_tag, item.vod_name].join(' ');
      return blob.indexOf(classKey) >= 0;
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
  if (sortKey === 'year') {
    out.sort(function (a, b) {
      return String(b.vod_year || '').localeCompare(String(a.vod_year || ''));
    });
  } else if (sortKey === 'douban') {
    out.sort(function (a, b) {
      const left = parseScore(a.vod_douban_score) || parseScore(a.vod_score);
      const right = parseScore(b.vod_douban_score) || parseScore(b.vod_score);
      if (right !== left) return right - left;
      return 0;
    });
  }
  return out;
}

const BATCH_SIZE = 8;
const REQUEST_TIMEOUT_MS = 8000;
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

async function requestJSON(api, params) {
  try {
    const response = await net.req(buildURL(api, params), {
      timeout: REQUEST_TIMEOUT_MS,
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
    if (itemScore(item) > itemScore(prev)) {
      best.set(key, item);
    }
  }
  return order.map(function (key) {
    return best.get(key);
  });
}

function classifyTypeName(name) {
  const n = String(name || '');
  if (/少儿|儿童|亲子|幼儿|Kids|卡通片/.test(n)) return 'kids';
  if (/纪录|纪录片|Doc|纪录片/.test(n)) return 'doc';
  if (/动漫|动画|番剧|国漫|日漫/.test(n)) return 'anime';
  if (/综艺|晚会|真人|脱口秀|娱乐|选秀/.test(n)) return 'variety';
  if (/电影|影片|院线/.test(n)) return 'movie';
  if (/剧|电视|连续|剧集|美剧|韩剧|日剧|港剧|台剧|泰剧|短剧/.test(n)) return 'tv';
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
    if (typeof ext !== 'string' || !ext.trim()) return;
    try {
      const config = JSON.parse(ext);
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
      if (bucket && this.typeIdsByBucket[bucket]) {
        this.typeIdsByBucket[bucket].push({
          provider: provider,
          typeId: category.type_id,
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
    const buckets = { tv: [], movie: [], variety: [], other: [] };
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
        } else if (bucket !== 'anime') {
          buckets.other.push(item);
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
    for (let o = 0; o < buckets.other.length && list.length < 60; o++) {
      list.push(buckets.other[o]);
    }
    return dedupeByTitle(list).slice(0, 60);
  }

  async homeContent(filter) {
    const providers = this.providers || DEFAULT_PROVIDERS;
    this.typeIdsByBucket = emptyBucketMap();
    this.typeNameByProviderType = {};
    const self = this;
    const results = await mapInBatches(providers, BATCH_SIZE, function (provider) {
      return self.providerData(provider);
    });
    for (let index = 0; index < results.length; index++) {
      this.rememberCatalog(results[index].provider, results[index].catalog);
    }
    return {
      class: menuClasses(),
      list: this.buildRecommendList(results),
      filters: menuFilters(),
    };
  }

  async homeVideoContent() {
    const result = await this.homeContent(false);
    return { list: result.list };
  }

  async bucketContent(bucket, pg, extend) {
    const providers = this.providers || DEFAULT_PROVIDERS;
    const page = String(pg || 1);

    if (bucket === 'recommend') {
      const results = await mapInBatches(providers, BATCH_SIZE, async function (provider) {
        const latest = await requestJSON(provider.api, {
          ac: 'videolist',
          pg: page,
        });
        return { provider: provider, latest: latest };
      });
      const list = applyExtend(this.buildRecommendList(results), extend);
      return {
        page: Number(page) || 1,
        pagecount: list.length ? Number(page) + 1 : Number(page) || 1,
        limit: list.length,
        total: list.length,
        list: list,
      };
    }

    let targets = (this.typeIdsByBucket && this.typeIdsByBucket[bucket]) || [];
    if (!targets.length) {
      const catalogs = await mapInBatches(providers, BATCH_SIZE, async function (provider) {
        const catalog = await requestJSON(provider.api, { ac: 'list' });
        return { provider: provider, catalog: catalog };
      });
      this.typeIdsByBucket = emptyBucketMap();
      this.typeNameByProviderType = {};
      for (let i = 0; i < catalogs.length; i++) {
        this.rememberCatalog(catalogs[i].provider, catalogs[i].catalog);
      }
      targets = this.typeIdsByBucket[bucket] || [];
    }

    if (!targets.length) {
      return { page: Number(page) || 1, pagecount: 1, limit: 0, total: 0, list: [] };
    }

    // Cap fan-out for category pages: first matching type per provider is enough.
    const byProvider = new Map();
    for (let i = 0; i < targets.length; i++) {
      const target = targets[i];
      if (!byProvider.has(target.provider.key)) {
        byProvider.set(target.provider.key, target);
      }
    }
    const uniqueTargets = Array.from(byProvider.values());

    const results = await mapInBatches(uniqueTargets, BATCH_SIZE, async function (target) {
      const data = await requestJSON(
        target.provider.api,
        catalogParams(target.typeId, page, extend)
      );
      return { provider: target.provider, data: data };
    });

    const list = [];
    let pagecount = 1;
    let total = 0;
    for (let index = 0; index < results.length; index++) {
      const result = results[index];
      const items = result.data && Array.isArray(result.data.list) ? result.data.list : [];
      if (result.data && result.data.pagecount) {
        pagecount = Math.max(pagecount, Number(result.data.pagecount) || 1);
      }
      if (result.data && result.data.total) {
        total += Number(result.data.total) || 0;
      }
      for (let j = 0; j < items.length; j++) {
        const item = mediaItem(result.provider, Object.assign({}, items[j]));
        if (item) list.push(item);
      }
    }
    const deduped = applyExtend(dedupeByTitle(list), extend);
    return {
      page: Number(page) || 1,
      pagecount: pagecount,
      limit: deduped.length,
      total: total || deduped.length,
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
