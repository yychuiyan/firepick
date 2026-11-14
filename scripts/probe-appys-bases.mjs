#!/usr/bin/env node
/**
 * Probe AppYs / xgapp / v1.vod candidates (parallel).
 * Writes sources/appys.whitelist.json + sources/appys.probe-report.json
 * Does NOT auto-publish dead hosts into ios-sources.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '..');
const candidatesPath = path.join(root, 'sources/appys.candidates.json');
const { candidates } = JSON.parse(fs.readFileSync(candidatesPath, 'utf8'));

const TIMEOUT_MS = 9000;
const KEYWORD = '庆余年';
const CONCURRENCY = 12;

function join(base, suffix) {
  const b = base.replace(/\/?$/, '/');
  return b + suffix.replace(/^\//, '');
}

function isVodStyle(api) {
  return /\.vod|mogai_api|lvdou_api|ruifenglb|xiaobai_api/i.test(api);
}

function isXgapp(api) {
  return /xgapp\.php/i.test(api);
}

function urlsFor(api) {
  if (isVodStyle(api)) {
    const rootApi = api.replace(/\/?$/, '');
    return {
      list: rootApi + '?ac=list',
      search: rootApi + '?ac=detail&wd=' + encodeURIComponent(KEYWORD) + '&pg=1',
      searchAlt: rootApi + '?wd=' + encodeURIComponent(KEYWORD) + '&pg=1',
    };
  }
  if (isXgapp(api)) {
    return {
      list: join(api, 'nav?token='),
      search: join(api, 'search?text=' + encodeURIComponent(KEYWORD) + '&pg=1&token='),
      searchAlt: join(api, 'video?tid=1&pg=1&token='),
    };
  }
  return {
    list: join(api, 'nav?token='),
    search: join(api, 'search?text=' + encodeURIComponent(KEYWORD) + '&pg=1&token='),
    searchAlt: join(api, 'video?tid=1&pg=1&token='),
  };
}

async function fetchText(url) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(url, {
      signal: ctrl.signal,
      redirect: 'follow',
      headers: {
        'User-Agent': 'okhttp/3.12.0',
        Accept: 'application/json',
      },
    });
    const text = await res.text();
    return { ok: res.ok, status: res.status, text };
  } finally {
    clearTimeout(timer);
  }
}

function looksJSON(text) {
  const t = String(text || '').trim();
  if (!(t.startsWith('{') || t.startsWith('['))) return false;
  try {
    JSON.parse(t);
    return true;
  } catch {
    return false;
  }
}

function hasListPayload(text) {
  if (!looksJSON(text)) return false;
  try {
    const obj = JSON.parse(text);
    // Reject auth/WAF JSON that looks "alive" but is unusable.
    if (obj.code === 999) return false;
    if (/验证失败|未登录|forbidden|token/i.test(String(obj.msg || ''))) return false;
    if (Array.isArray(obj.list) && obj.list.length) return true;
    if (Array.isArray(obj.class) && obj.class.length) return true;
    if (obj.data && Array.isArray(obj.data.list) && obj.data.list.length) return true;
    if (Array.isArray(obj.data) && obj.data.length) return true;
    return false;
  } catch {
    return false;
  }
}

async function probeOne(c) {
  const row = { ...c, listOK: false, searchOK: false, error: null };
  try {
    const urls = urlsFor(c.api);
    const list = await fetchText(urls.list);
    row.listStatus = list.status;
    row.listOK = list.ok && hasListPayload(list.text);
    let search = await fetchText(urls.search);
    row.searchStatus = search.status;
    row.searchOK = search.ok && looksJSON(search.text);
    if (!row.searchOK && urls.searchAlt) {
      search = await fetchText(urls.searchAlt);
      row.searchStatus = search.status;
      row.searchOK = search.ok && looksJSON(search.text);
      if (row.searchOK) row.searchVia = 'alt';
    }
  } catch (error) {
    row.error = String(error && error.message ? error.message : error);
  }
  return row;
}

async function mapPool(items, limit, worker) {
  const out = new Array(items.length);
  let i = 0;
  async function run() {
    while (i < items.length) {
      const idx = i++;
      out[idx] = await worker(items[idx], idx);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, () => run()));
  return out;
}

const results = await mapPool(candidates, CONCURRENCY, probeOne);
const whitelist = [];
for (const row of results) {
  const alive = row.listOK && row.searchOK;
  if (alive) whitelist.push({ key: row.key, name: row.name, api: row.api });
  console.log(
    (alive ? '★' : '✗'),
    row.key,
    'list=' + row.listOK,
    'search=' + row.searchOK,
    row.error || (row.listStatus != null ? 'http=' + row.listStatus + '/' + row.searchStatus : '')
  );
}

const report = {
  probedAt: new Date().toISOString(),
  results,
  whitelistCount: whitelist.length,
};
fs.writeFileSync(path.join(root, 'sources/appys.probe-report.json'), JSON.stringify(report, null, 2));
fs.writeFileSync(
  path.join(root, 'sources/appys.whitelist.json'),
  JSON.stringify({ providers: whitelist, meta: { probedAt: report.probedAt } }, null, 2)
);
console.log('Alive', whitelist.length + '/' + candidates.length);
