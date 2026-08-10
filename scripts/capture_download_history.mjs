#!/usr/bin/env node

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

const repository = process.env.GITHUB_REPOSITORY || 'Blaizzy/nativ';
const outputArgument = process.argv.find((argument) => argument.startsWith('--output='));
const outputPath = path.resolve(outputArgument?.slice('--output='.length) || 'website/data/download-history.json');
const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
const capturedAt = new Date(process.env.SNAPSHOT_AT || Date.now());

if (Number.isNaN(capturedAt.getTime())) throw new Error('SNAPSHOT_AT must be a valid date');

const headers = {
  Accept: 'application/vnd.github+json',
  'User-Agent': 'nativ-download-history',
  'X-GitHub-Api-Version': '2022-11-28'
};

if (token) headers.Authorization = `Bearer ${token}`;

const fetchReleases = async () => {
  const releases = [];

  for (let page = 1; page <= 10; page += 1) {
    const endpoint = `https://api.github.com/repos/${repository}/releases?per_page=100&page=${page}`;
    const response = await fetch(endpoint, { headers });
    if (!response.ok) throw new Error(`GitHub returned ${response.status} for ${endpoint}`);

    const pageReleases = await response.json();
    releases.push(...pageReleases.filter((release) => !release.draft));
    if (pageReleases.length < 100) break;
  }

  return releases;
};

const readHistory = async () => {
  try {
    const history = JSON.parse(await readFile(outputPath, 'utf8'));
    if (history.version !== 1 || typeof history.assetIndex !== 'object' || !Array.isArray(history.snapshots)) {
      throw new Error(`Unsupported download history schema in ${outputPath}`);
    }
    return history;
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    return { version: 1, assetIndex: {}, snapshots: [] };
  }
};

const getAssetType = (name) => {
  const normalizedName = name.toLowerCase();
  if (normalizedName.endsWith('.dmg')) return 'dmg';
  if (normalizedName === 'appcast.xml') return 'appcast';
  return 'other';
};

const releases = await fetchReleases();
if (!releases.length) throw new Error('No published releases found');

const history = await readHistory();
const counts = {};

releases.forEach((release) => {
  (release.assets || [])
    .filter((asset) => asset.state !== 'open')
    .forEach((asset) => {
      const key = String(asset.id);
      counts[key] = Number(asset.download_count || 0);
      history.assetIndex[key] = {
        release: release.tag_name,
        name: asset.name,
        type: getAssetType(asset.name)
      };
    });
});

history.snapshots.push({
  capturedAt: capturedAt.toISOString(),
  counts
});
history.snapshots.sort((left, right) => new Date(left.capturedAt) - new Date(right.capturedAt));
const retentionCutoff = capturedAt.getTime() - (400 * 24 * 60 * 60 * 1000);
history.snapshots = history.snapshots
  .filter((snapshot) => new Date(snapshot.capturedAt).getTime() >= retentionCutoff)
  .slice(-2000);

await mkdir(path.dirname(outputPath), { recursive: true });
await writeFile(outputPath, `${JSON.stringify(history, null, 2)}\n`);

console.log(`Captured ${Object.keys(counts).length} assets at ${capturedAt.toISOString()}`);
