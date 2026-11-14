import { Spider, net } from 'catvod';

/**
 * Generic AppleCMS provide/vod spider.
 * Pass the API root via site `ext`, e.g.
 *   "https://bfzyapi.com/api.php/provide/vod"
 * playerContent returns parse:0 for direct media URLs.
 */

function apiFromExt(ext) {
  if (!ext) return '';
  if (typeof ext === 'string') {
    const t = ext.trim();
    if (!t) return '';
    try {
      const parsed = JSON.parse(t);
      if (parsed && parsed.api) return String(parsed.api).replace(/\/?$/, '');
      if (parsed && parsed.url) return String(parsed.url).replace(/\/?$/, '');
    } catch (_) {}
    return t.replace(/\/?$/, '');
  }
  if (ext.api) return String(ext.api).replace(/\/?$/, '');
  if (ext.url) return String(ext.url).replace(/\/?$/, '');
  return '';
}

function looksPlayable(url) {
  const u = String(url || '');
  if (!u || u.indexOf('http') !== 0) return false;
  if (/\.(m3u8|mp4|mkv|flv|ts)(\?|$)/i.test(u)) return true;
  if (/\/m3u8|playlist\.m3u8|index\.m3u8/i.test(u)) return true;
  return false;
}

async function getJSON(api, params) {
  const query = Object.assign({}, params || {});
  const parts = [];
  Object.keys(query).forEach(function (key) {
    const value = query[key];
    if (value == null || value === '') return;
    parts.push(encodeURIComponent(key) + '=' + encodeURIComponent(String(value)));
  });
  const url = api + (api.indexOf('?') >= 0 ? '&' : '?') + parts.join('&');
  const response = await net.req(url, {
    timeout: 12000,
    headers: {
      'User-Agent': 'okhttp/3.12.0',
      Accept: 'application/json',
    },
  });
  if (!response || response.code < 200 || response.code >= 300) {
    throw new Error('HTTP ' + (response && response.code));
  }
  const text = String(response.content || '').trim();
  if (!text || text[0] === '<') throw new Error('non-json');
  return JSON.parse(text);
}

function mapCard(row) {
  if (!row || row.vod_id == null || !row.vod_name) return null;
  return {
    vod_id: String(row.vod_id),
    vod_name: String(row.vod_name),
    vod_pic: row.vod_pic || '',
    vod_remarks: row.vod_remarks || '',
    vod_year: row.vod_year || '',
  };
}

export default class extends Spider {
  async init(ext) {
    this.api = apiFromExt(ext);
  }

  async homeContent(filter) {
    if (!this.api) return { class: [], list: [] };
    const data = await getJSON(this.api, { ac: 'list' });
    const classes = Array.isArray(data.class)
      ? data.class.map(function (row) {
          return {
            type_id: String(row.type_id),
            type_name: String(row.type_name || row.type_id),
          };
        })
      : [];
    const list = (Array.isArray(data.list) ? data.list : [])
      .map(mapCard)
      .filter(Boolean)
      .slice(0, 24);
    const filters = {};
    if (filter && classes.length) {
      // AppleCMS class list is enough for browse; per-type filters optional.
    }
    return { class: classes, list: list, filters: filters };
  }

  async categoryContent(tid, pg) {
    if (!this.api) return { list: [] };
    const page = String(pg || 1);
    const data = await getJSON(this.api, {
      ac: 'detail',
      t: tid || '',
      pg: page,
    });
    const list = (Array.isArray(data.list) ? data.list : []).map(mapCard).filter(Boolean);
    return {
      page: Number(data.page) || Number(page) || 1,
      pagecount: Number(data.pagecount) || 1,
      limit: Number(data.limit) || list.length,
      total: Number(data.total) || list.length,
      list: list,
    };
  }

  async detailContent(ids) {
    if (!this.api) return { list: [] };
    const id = Array.isArray(ids) ? ids[0] : ids;
    const data = await getJSON(this.api, { ac: 'detail', ids: String(id) });
    const row = Array.isArray(data.list) ? data.list[0] : null;
    if (!row) return { list: [] };
    return {
      list: [
        {
          vod_id: String(row.vod_id),
          vod_name: String(row.vod_name || ''),
          vod_pic: row.vod_pic || '',
          vod_remarks: row.vod_remarks || '',
          vod_year: row.vod_year || '',
          vod_area: row.vod_area || '',
          vod_actor: row.vod_actor || '',
          vod_director: row.vod_director || '',
          vod_content: row.vod_content || '',
          vod_play_from: row.vod_play_from || '',
          vod_play_url: row.vod_play_url || '',
        },
      ],
    };
  }

  async searchContent(key, quick, pg) {
    if (!this.api) return { list: [] };
    const page = String(pg || 1);
    const data = await getJSON(this.api, {
      ac: 'detail',
      wd: key,
      pg: page,
    });
    const list = (Array.isArray(data.list) ? data.list : []).map(mapCard).filter(Boolean);
    return {
      page: Number(data.page) || Number(page) || 1,
      pagecount: Number(data.pagecount) || 1,
      list: list,
    };
  }

  async playerContent(flag, id) {
    const url = String(id || '');
    if (looksPlayable(url)) {
      return {
        parse: 0,
        url: url,
        header: {
          'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15',
        },
      };
    }
    // Non-direct ids: surface as parse:0 only when already a URL; otherwise empty.
    if (url.indexOf('http') === 0) {
      return { parse: 0, url: url };
    }
    return { parse: 0, url: '' };
  }
}
