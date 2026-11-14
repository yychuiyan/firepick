#!/usr/bin/env node
/**
 * Probe AppleCMS provide/vod candidates from sources/cms-candidates.json.
 * Writes:
 *   - sources/providers.whitelist.json
 *   - sources/providers.probe-report.json
 * With --write-defaults also rewrites:
 *   - DEFAULT_PROVIDERS in Packages/.../Resources/firepick-cms.js + sources/firepick-cms.js
 *   - AppModel.firepickCMSProviders (keep in sync)
 *
 * Usage:
 *   node scripts/probe-cms-providers.mjs
 *   node scripts/probe-cms-providers.mjs --write-defaults
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '..');
const writeDefaults = process.argv.includes('--write-defaults');

const CANDIDATES_PATH = path.join(root, 'sources/cms-candidates.json');
const catalog = JSON.parse(fs.readFileSync(CANDIDATES_PATH, 'utf8'));
const CANDIDATES = Array.isArray(catalog.providers) ? catalog.providers : [];
if (!CANDIDATES.length) {
  console.error(`No providers in ${path.relative(root, CANDIDATES_PATH)}`);
  process.exit(1);
}

/** Mix drama + anime so active pool keeps 国漫/日漫 coverage. */
const KEYWORDS = ['庆余年', '三体', '进击的巨人', '绝命毒师', '斗破苍穹', '沧元图'];
const TIMEOUT_MS = 8000;
const CONCURRENCY = 4;
const ACTIVE_POOL = 10;

/** Chip / settings short labels (must stay ≤4 chars-ish for 来源 UI). */
const SHORT_NAMES = {
  lzcaiji: '量子',
  lzi: '量子',
  bfzy: '暴风',
  subo: '速播',
  ffzy: '非凡',
  ffzy_cj: '非凡',
  jisu: '极速',
  dytt: '天堂',
  zuid: '最大',
  zuid_me: '最大',
  guangsu: '光速',
  ruyi: '如意',
  iqiyi: '爱奇艺',
  xinlang: '新浪',
  uku: 'U酷',
  uku_alt: 'U酷',
  maoyan: '猫眼',
  zy360: '360',
  zy360zz: '360',
  modu: '魔都',
  wujin: '无尽',
  wujin_com: '无尽',
  hongniu: '红牛',
  hongniu3: '红牛',
  wolong: '卧龙',
  wolong_web: '卧龙',
  haohua: '豪华',
  yzzy: '优质',
  zy1080: '1080',
  huya: '虎牙',
  maotai: '茅台',
  jinying: '金鹰',
  jinyingzy: '金鹰',
  ikun: 'iKun',
  moduanime: '魔都漫',
  baidu: '百度',
  douban: '豆瓣',
  piaoling: '飘零',
  suoni: '索尼',
  heimuer: '木耳',
  niuniu: '牛牛',
  yaya: '丫丫',
  yinghua: '樱花',
  sdzy: '闪电',
  kuaiche: '快车',
  feisu: '飞速',
  kuaikan: '快看',
  xiongzhang: '熊掌',
  qihu: '奇虎',
  kuaiyun: '快云',
  wwzy: '旺旺',
  hw8: '华为吧',
  okzy: 'OK',
  taopian: '淘片',
  movie_legacy: '影视',
};

const CMS_JS_PATHS = [
  path.join(
    root,
    'Packages/FirepickKit/Sources/FirepickProvider/Resources/firepick-cms.js'
  ),
  path.join(root, 'sources/firepick-cms.js'),
];
const APP_MODEL_PATH = path.join(root, 'apps/ios/Firepick/AppModel.swift');

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
  let hitCount = 0;
  let searchMsSum = 0;
  let searchMsN = 0;
  for (const wd of KEYWORDS) {
    const r = await fetchJSON(
      buildURL(candidate.api, { ac: 'videolist', wd, pg: '1' })
    );
    const n = r.ok ? listLen(r.data) : 0;
    hits[wd] = { ok: r.ok, n, ms: r.ms, error: r.error };
    searchMsSum += r.ms;
    searchMsN += 1;
    if (n > 0) {
      searchable = true;
      hitCount += 1;
    }
  }
  const avgSearchMs = searchMsN ? searchMsSum / searchMsN : TIMEOUT_MS;
  // Higher = better: breadth first, then latency.
  const score =
    (list.ok ? 10_000 : 0) +
    hitCount * 2_000 -
    Math.min(list.ms || TIMEOUT_MS, TIMEOUT_MS) -
    Math.min(avgSearchMs, TIMEOUT_MS);
  return {
    ...candidate,
    listOk: list.ok,
    listMs: list.ms,
    listError: list.error,
    searchable,
    hitCount,
    avgSearchMs,
    score,
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

function shortName(candidate) {
  if (SHORT_NAMES[candidate.key]) return SHORT_NAMES[candidate.key];
  return String(candidate.name || candidate.key)
    .replace(/(资源|采集|影视|点播|网|备)$/u, '')
    .slice(0, 4);
}

/** Ranked active pool: unique host, fast + searchable first. */
function pickActiveProviders(passed) {
  const ranked = [...passed].sort((a, b) => b.score - a.score);
  const seenHost = new Set();
  const picked = [];
  for (const r of ranked) {
    let host;
    try {
      host = new URL(r.api).host;
    } catch {
      host = r.key;
    }
    if (seenHost.has(host)) continue;
    seenHost.add(host);
    picked.push({
      key: r.key,
      name: shortName(r),
      api: r.api,
      score: r.score,
      listMs: r.listMs,
      hitCount: r.hitCount,
    });
    if (picked.length >= ACTIVE_POOL) break;
  }
  return picked;
}

function formatProvidersJS(providers) {
  const lines = providers.map(
    (p) =>
      `  { key: '${p.key}', name: '${p.name}', api: '${p.api}' },`
  );
  return `const DEFAULT_PROVIDERS = [\n${lines.join('\n')}\n];`;
}

function formatProvidersSwift(providers) {
  const lines = providers.map(
    (p) =>
      `    ("${p.key}", "${p.name}", "${p.api}"),`
  );
  return `  static let firepickCMSProviders: [(key: String, name: String, api: String)] = [\n${lines.join('\n')}\n  ]`;
}

function rewriteDefaultProviders(filePath, providers) {
  const src = fs.readFileSync(filePath, 'utf8');
  const next = src.replace(
    /const DEFAULT_PROVIDERS = \[[\s\S]*?\];/,
    formatProvidersJS(providers)
  );
  if (next === src) {
    throw new Error(`DEFAULT_PROVIDERS block not found in ${filePath}`);
  }
  fs.writeFileSync(filePath, next);
}

function rewriteAppModelProviders(filePath, providers) {
  const src = fs.readFileSync(filePath, 'utf8');
  const next = src.replace(
    /static let firepickCMSProviders: \[\(key: String, name: String, api: String\)\] = \[[\s\S]*?\]/,
    formatProvidersSwift(providers)
  );
  if (next === src) {
    throw new Error(`firepickCMSProviders block not found in ${filePath}`);
  }
  fs.writeFileSync(filePath, next);
}

console.log(
  `Probing ${CANDIDATES.length} candidates from ${path.relative(root, CANDIDATES_PATH)}`
);

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

const active = pickActiveProviders(passed);

const report = {
  probedAt: new Date().toISOString(),
  source: path.relative(root, CANDIDATES_PATH),
  keywords: KEYWORDS,
  total: results.length,
  passed: passed.length,
  whitelistCount: whitelist.length,
  activePool: active,
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
    {
      providers: whitelist,
      meta: {
        probedAt: report.probedAt,
        source: report.source,
        keywords: KEYWORDS,
      },
    },
    null,
    2
  ) + '\n'
);
fs.writeFileSync(
  path.join(root, 'sources/providers.probe-report.json'),
  JSON.stringify(report, null, 2) + '\n'
);

console.log(`Passed ${whitelist.length}/${results.length}; active pool ${active.length}`);
for (const w of active) {
  console.log(
    `  ★ ${w.key} ${w.name} score=${Math.round(w.score)} list=${w.listMs}ms hits=${w.hitCount}`
  );
}
for (const f of report.failures) {
  console.log(`  ✗ ${f.key} list=${f.listOk} search=${f.searchable} ${f.listError || ''}`);
}

if (!writeDefaults) {
  console.log(
    'Report only (pass --write-defaults to rewrite DEFAULT_PROVIDERS / firepickCMSProviders).'
  );
  process.exit(0);
}

if (!active.length) {
  console.error('No passing providers — refusing to rewrite DEFAULT_PROVIDERS');
  process.exit(1);
}

for (const cmsPath of CMS_JS_PATHS) {
  rewriteDefaultProviders(cmsPath, active);
  console.log(`Updated DEFAULT_PROVIDERS → ${path.relative(root, cmsPath)}`);
}
rewriteAppModelProviders(APP_MODEL_PATH, active);
console.log(`Updated firepickCMSProviders → ${path.relative(root, APP_MODEL_PATH)}`);
