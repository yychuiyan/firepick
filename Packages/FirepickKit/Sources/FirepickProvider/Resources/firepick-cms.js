import { Spider, net } from 'catvod';

const DEFAULT_PROVIDERS = [
  {
    key: 'jisu',
    name: '极速资源',
    api: 'https://jszyapi.com/api.php/provide/vod/at/json',
  },
  {
    key: 'movie',
    name: '影视资源',
    api: 'https://dy.7772888.xyz/api.php/tvbox',
  },
  {
    key: 'dytt',
    name: '天堂资源',
    api: 'https://caiji.dyttzyapi.com/api.php/provide/vod/from/dyttm3u8/at/m3u8/',
  },
  {
    key: 'ffzy',
    name: '非凡资源',
    api: 'https://cj.ffzyapi.com/api.php/provide/vod/',
  },
  {
    key: 'lzi',
    name: '量子资源',
    api: 'https://cj.lziapi.com/api.php/provide/vod/',
  },
];

const MENU = [
  { id: 'recommend', name: '推荐' },
  { id: 'tv', name: '电视剧' },
  { id: 'movie', name: '电影' },
  { id: 'variety', name: '综艺' },
  { id: 'anime', name: '动漫' },
];

function encode(value) {
  return encodeURIComponent(String(value == null ? '' : value));
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
      timeout: 12000,
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

function providerID(provider, id) {
  return provider.key + '|' + id;
}

function splitID(value) {
  const text = String(value || '');
  const index = text.indexOf('|');
  if (index < 0) return null;
  return { provider: text.slice(0, index), id: text.slice(index + 1) };
}

function mediaItem(provider, item) {
  if (!item || item.vod_id === undefined || !item.vod_name) return null;
  item.vod_id = providerID(provider, item.vod_id);
  if (!item.vod_pic && item.vod_pic_thumb) item.vod_pic = item.vod_pic_thumb;
  if (!item.vod_remarks && item.vod_note) item.vod_remarks = item.vod_note;
  return item;
}

function classifyTypeName(name) {
  const n = String(name || '');
  if (/动漫|动画|卡通|番剧|国漫|日漫/.test(n)) return 'anime';
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
  return { tv: [], movie: [], variety: [], anime: [] };
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
      for (let k = 0; k < items.length; k++) {
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
    return list.slice(0, 60);
  }

  async homeContent(filter) {
    const providers = this.providers || DEFAULT_PROVIDERS;
    this.typeIdsByBucket = emptyBucketMap();
    this.typeNameByProviderType = {};
    const self = this;
    const results = await Promise.all(providers.map(function (provider) {
      return self.providerData(provider);
    }));
    for (let index = 0; index < results.length; index++) {
      this.rememberCatalog(results[index].provider, results[index].catalog);
    }
    return {
      class: menuClasses(),
      list: this.buildRecommendList(results),
    };
  }

  async homeVideoContent() {
    const result = await this.homeContent(false);
    return { list: result.list };
  }

  async bucketContent(bucket, pg) {
    const providers = this.providers || DEFAULT_PROVIDERS;
    const page = String(pg || 1);

    if (bucket === 'recommend') {
      const self = this;
      const results = await Promise.all(providers.map(async function (provider) {
        const latest = await requestJSON(provider.api, {
          ac: 'videolist',
          pg: page,
        });
        return { provider: provider, latest: latest };
      }));
      const list = this.buildRecommendList(results);
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
      // Cold path: catalogs not warm yet (e.g. direct category open).
      const self = this;
      const catalogs = await Promise.all(providers.map(async function (provider) {
        const catalog = await requestJSON(provider.api, { ac: 'list' });
        return { provider: provider, catalog: catalog };
      }));
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

    const results = await Promise.all(targets.map(async function (target) {
      const data = await requestJSON(target.provider.api, {
        ac: 'videolist',
        t: target.typeId,
        pg: page,
      });
      return { provider: target.provider, data: data };
    }));

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
    return {
      page: Number(page) || 1,
      pagecount: pagecount,
      limit: list.length,
      total: total || list.length,
      list: list,
    };
  }

  async categoryContent(tid, pg, filter, extend) {
    const value = splitID(tid);
    if (!value) return { list: [] };

    if (value.provider === 'bucket') {
      return this.bucketContent(value.id, pg);
    }

    const provider = this.providers.find(function (item) {
      return item.key === value.provider;
    });
    if (!provider) return { list: [] };
    const data = await requestJSON(provider.api, {
      ac: 'videolist',
      t: value.id,
      pg: String(pg || 1),
    });
    const list = data && Array.isArray(data.list) ? data.list : [];
    return {
      page: pg || 1,
      pagecount: data && data.pagecount ? data.pagecount : 1,
      limit: data && data.limit ? data.limit : list.length,
      total: data && data.total ? data.total : list.length,
      list: list.map(function (item) {
        return mediaItem(provider, Object.assign({}, item));
      }).filter(Boolean),
    };
  }

  async searchContent(key, quick, pg) {
    const providers = this.providers || DEFAULT_PROVIDERS;
    const results = await Promise.all(providers.map(async function (provider) {
      const data = await requestJSON(provider.api, {
        ac: 'videolist',
        wd: key,
        pg: String(pg || 1),
      });
      return { provider: provider, data: data };
    }));
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
    return { list: list };
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
