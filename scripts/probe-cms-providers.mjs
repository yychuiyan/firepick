#!/usr/bin/env node
/**
 * Probe AppleCMS provide/vod candidates.
 * Writes sources/providers.whitelist.json and sources/providers.probe-report.json
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '..');

const CANDIDATES = [
  { key: 'iqiyi', name: '爱奇艺资源', api: 'https://iqiyizyapi.com/api.php/provide/vod' },
  { key: 'ikun', name: 'iKun资源', api: 'https://ikunzyapi.com/api.php/provide/vod' },
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
  { key: 'wujin', name: '无尽资源', api: 'https://api.wujinapi.me/api.php/provide/vod' },
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
  { key: 'wolong', name: '卧龙资源', api: 'https://wolongzyw.com/api.php/provide/vod' },
  { key: 'maotai', name: '茅台资源', api: 'https://caiji.maotaizy.cc/api.php/provide/vod' },
  { key: 'ffzy_cj', name: '非凡采集', api: 'https://cj.ffzyapi.com/api.php/provide/vod' },
  { key: 'movie_legacy', name: '影视资源', api: 'https://dy.7772888.xyz/api.php/tvbox' },
];

const KEYWORDS = ['庆余年', '三体', '进击的巨人', '绝命毒师'];
const TIMEOUT_MS = 8000;
const CONCURRENCY = 4;

function buildURL(api, params) {
  const sep = api.includes('?') ? '&' : '?';
  return (
    api +
    sep +
    Object.entries(params)
      .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
      .join('&')
  );
}

async function fetchJSON(url) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  const started = Date.now();
  try {
    const res = await fetch(url, {
      signal: ctrl.signal,
      headers: {
        'User-Agent': 'okhttp/4.1.0',
        Accept: 'application/json,text/plain,*/*',
      },
    });
    const text = await res.text();
    const ms = Date.now() - started;
    if (!res.ok) return { ok: false, ms, error: `HTTP ${res.status}` };
    let data;
    try {
      data = JSON.parse(text);
    } catch {
      return { ok: false, ms, error: 'non-json' };
    }
    return { ok: true, ms, data };
  } catch (e) {
    return { ok: false, ms: Date.now() - started, error: String(e.name || e.message || e) };
  } finally {
    clearTimeout(timer);
  }
}

function listLen(data) {
  if (!data || !Array.isArray(data.list)) return 0;
  return data.list.length;
}

async function probeOne(candidate) {
  const list = await fetchJSON(buildURL(candidate.api, { ac: 'list' }));
  const hits = {};
  let searchable = false;
  for (const wd of KEYWORDS) {
    const r = await fetchJSON(
      buildURL(candidate.api, { ac: 'videolist', wd, pg: '1' })
    );
    const n = r.ok ? listLen(r.data) : 0;
    hits[wd] = { ok: r.ok, n, ms: r.ms, error: r.error };
    if (n > 0) searchable = true;
  }
  return {
    ...candidate,
    listOk: list.ok,
    listMs: list.ms,
    listError: list.error,
    searchable,
    hits,
    pass: list.ok && searchable,
  };
}

async function mapPool(items, limit, fn) {
  const out = new Array(items.length);
  let i = 0;
  async function worker() {
    while (i < items.length) {
      const idx = i++;
      out[idx] = await fn(items[idx], idx);
    }
  }
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, () => worker())
  );
  return out;
}

const results = await mapPool(CANDIDATES, CONCURRENCY, probeOne);
const passed = results.filter((r) => r.pass);
const seenHost = new Set();
const whitelist = [];
for (const r of passed) {
  let host;
  try {
    host = new URL(r.api).host;
  } catch {
    host = r.key;
  }
  if (seenHost.has(host)) continue;
  seenHost.add(host);
  whitelist.push({ key: r.key, name: r.name, api: r.api });
}

const report = {
  probedAt: new Date().toISOString(),
  keywords: KEYWORDS,
  total: results.length,
  passed: passed.length,
  whitelistCount: whitelist.length,
  whitelist,
  failures: results
    .filter((r) => !r.pass)
    .map((r) => ({
      key: r.key,
      name: r.name,
      api: r.api,
      listOk: r.listOk,
      searchable: r.searchable,
      listError: r.listError,
      hits: r.hits,
    })),
  details: results,
};

fs.writeFileSync(
  path.join(root, 'sources/providers.whitelist.json'),
  JSON.stringify(
    { providers: whitelist, meta: { probedAt: report.probedAt, keywords: KEYWORDS } },
    null,
    2
  ) + '\n'
);
fs.writeFileSync(
  path.join(root, 'sources/providers.probe-report.json'),
  JSON.stringify(report, null, 2) + '\n'
);

console.log(`Passed ${whitelist.length}/${results.length}`);
for (const w of whitelist) console.log(`  ✓ ${w.key} ${w.name}`);
for (const f of report.failures) {
  console.log(`  ✗ ${f.key} list=${f.listOk} search=${f.searchable} ${f.listError || ''}`);
}
