#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sourceArg = process.argv[2];
if (!sourceArg) {
  console.error('Usage: build-niubihu-ios-config.mjs <path-to-1.json>');
  process.exit(2);
}
const sourcePath = path.resolve(sourceArg);
const outputPath = path.join(root, 'sources/niubihu-ios.json');
const source = JSON.parse(fs.readFileSync(sourcePath, 'utf8'));

if (!Array.isArray(source.sites)) {
  throw new Error(`No sites array in ${sourcePath}`);
}

const httpSites = source.sites.filter(
  (site) => site.type === 1 && /^https?:\/\//i.test(site.api || ''),
);
const standaloneJSSite = source.sites.find((site) => site.key === 'Easy-EmbyJS');
const liveNames = new Set([
  '🐯牛虎 ┃ 官方综合',
  '🍚饭太硬 ┃ 精选频道',
  '🐯虎牙 ┃ 一起看公网',
  '🐟斗鱼 ┃ 一起看公网',
]);
const lives = (source.lives || []).filter((live) => liveNames.has(live.name));

const compactSite = (site) => {
  const result = {
    key: site.key,
    name: site.name,
    type: site.type,
    api: site.api,
  };
  for (const field of ['searchable', 'quickSearch', 'changeable']) {
    if (site[field] !== undefined) result[field] = site[field];
  }
  return result;
};

const output = {
  notice: '牛虎 TVBox iOS 兼容精简版',
  sites: [...httpSites, standaloneJSSite].filter(Boolean).map(compactSite),
  lives,
};

if (output.sites.length === 0) {
  throw new Error('No iOS-compatible sites found');
}

fs.writeFileSync(outputPath, `${JSON.stringify(output, null, 2)}\n`);
console.log(
  `Wrote ${path.relative(root, outputPath)}: ${output.sites.length} sites, ${output.lives.length} lives`,
);
