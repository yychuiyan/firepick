import { Spider, net } from 'catvod';

/**
 * Generic AppYsV2-style spider. Pass the API root via site `ext`, e.g.
 *   "https://example.com/api.php/app/"
 *   "https://example.com/xgapp.php/v1/"
 *   "https://example.com/mogai_api.php/v1.vod"
 *
 * playerContent returns parse:0 direct URLs when possible.
 */

function baseFromExt(ext) {
  if (!ext) return '';
  if (typeof ext === 'string') {
    const t = ext.trim();
    if (!t) return '';
    try {
      const parsed = JSON.parse(t);
      if (parsed && parsed.url) return String(parsed.url).replace(/\/?$/, '/');
      if (parsed && parsed.api) return String(parsed.api).replace(/\/?$/, '/');
    } catch (_) {}
    return t.replace(/\/?$/, '/');
  }
  if (ext.url) return String(ext.url).replace(/\/?$/, '/');
  if (ext.api) return String(ext.api).replace(/\/?$/, '/');
  return '';
}

function isVodStyle(api) {
  return /\.vod|\/v1\.vod|mogai_api|lvdou_api|ruifenglb/i.test(api);
}

function isXgapp(api) {
  return /xgapp\.php/i.test(api);
}

async function getJSON(url) {
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

function pickList(obj) {
  if (!obj) return [];
  if (Array.isArray(obj.list)) return obj.list;
  if (obj.data && Array.isArray(obj.data.list)) return obj.data.list;
  if (Array.isArray(obj.data)) return obj.data;
  return [];
}

function mapCard(row) {
  if (!row) return null;
  const id = row.vod_id != null ? row.vod_id : row.nextlink || row.id;
  const name = row.vod_name || row.title || row.name;
  if (id == null || !name) return null;
  return {
    vod_id: String(id),
    vod_name: String(name),
    vod_pic: row.vod_pic || row.pic || row.img || '',
    vod_remarks: row.vod_remarks || row.state || row.remarks || '',
  };
}

export default class extends Spider {
  async init(ext) {
    this.api = baseFromExt(ext);
  }

  async homeContent() {
    if (!this.api) return { class: [], list: [] };
    if (isVodStyle(this.api)) {
      const data = await getJSON(this.api + '?ac=list');
      const classes = Array.isArray(data.class) ? data.class : [];
      return { class: classes, list: [] };
    }
    if (isXgapp(this.api)) {
      const data = await getJSON(this.api + 'nav?token=');
      const rows = pickList(data);
      const classes = rows
        .map(function (row) {
          return {
            type_id: String(row.type_id || row.id || ''),
            type_name: String(row.type_name || row.name || ''),
          };
        })
        .filter(function (c) {
          return c.type_id && c.type_name;
        });
      return { class: classes, list: [] };
    }
    const data = await getJSON(this.api + 'nav?token=');
    const rows = pickList(data);
    const classes = rows
      .map(function (row) {
        return {
          type_id: String(row.type_id || row.id || ''),
          type_name: String(row.type_name || row.name || ''),
        };
      })
      .filter(function (c) {
        return c.type_id && c.type_name;
      });
    return { class: classes, list: [] };
  }

  async categoryContent(tid, pg) {
    if (!this.api) return { list: [] };
    const page = String(pg || 1);
    let url;
    if (isVodStyle(this.api)) {
      url = this.api + '?ac=detail&t=' + encodeURIComponent(tid) + '&pg=' + page;
    } else if (isXgapp(this.api)) {
      url =
        this.api +
        'video?tid=' +
        encodeURIComponent(tid) +
        '&pg=' +
        page +
        '&token=';
    } else {
      url =
        this.api +
        'video?tid=' +
        encodeURIComponent(tid) +
        '&pg=' +
        page +
        '&token=';
    }
    const data = await getJSON(url);
    const list = pickList(data).map(mapCard).filter(Boolean);
    return {
      page: Number(page) || 1,
      pagecount: Number(data.pagecount || data.totalpage || page) || 1,
      list: list,
    };
  }

  async searchContent(key, quick, pg) {
    if (!this.api) return { list: [] };
    const page = String(pg || 1);
    let url;
    if (isVodStyle(this.api)) {
      url =
        this.api +
        '?ac=detail&wd=' +
        encodeURIComponent(key) +
        '&pg=' +
        page;
    } else if (isXgapp(this.api)) {
      url =
        this.api +
        'search?text=' +
        encodeURIComponent(key) +
        '&pg=' +
        page +
        '&token=';
    } else {
      url =
        this.api +
        'search?text=' +
        encodeURIComponent(key) +
        '&pg=' +
        page +
        '&token=';
    }
    const data = await getJSON(url);
    return { list: pickList(data).map(mapCard).filter(Boolean) };
  }

  async detailContent(ids) {
    if (!this.api || !ids || !ids.length) return { list: [] };
    const id = ids[0];
    let url;
    if (isVodStyle(this.api)) {
      url = this.api + '?ac=detail&ids=' + encodeURIComponent(id);
    } else if (isXgapp(this.api)) {
      url = this.api + 'video_detail?id=' + encodeURIComponent(id) + '&token=';
    } else {
      url = this.api + 'video_detail?id=' + encodeURIComponent(id) + '&token=';
    }
    const data = await getJSON(url);
    const rows = pickList(data);
    const item = rows[0] || data.data || data;
    if (!item) return { list: [] };
    return {
      list: [
        {
          vod_id: String(item.vod_id || id),
          vod_name: item.vod_name || item.title || '',
          vod_pic: item.vod_pic || item.pic || '',
          vod_content: item.vod_content || item.content || '',
          vod_play_from: item.vod_play_from || item.play_from || '默认',
          vod_play_url: item.vod_play_url || item.play_url || '',
          vod_year: item.vod_year || '',
          vod_remarks: item.vod_remarks || '',
        },
      ],
    };
  }

  async playerContent(flag, id) {
    const value = String(id || '');
    if (!value) return {};
    if (/^https?:\/\//i.test(value) || value.indexOf('.m3u8') >= 0) {
      return { parse: 0, url: value, flag: flag };
    }
    return { parse: 0, url: value, flag: flag };
  }
}
