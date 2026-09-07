#!/usr/bin/env node

import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

const repository = process.env.GITHUB_REPOSITORY || 'Blaizzy/nativ';
const outputArgument = process.argv.find((argument) => argument.startsWith('--output='));
const outputPath = path.resolve(outputArgument?.slice('--output='.length) || 'website/data/star-history.json');
const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
const capturedAt = new Date(process.env.SNAPSHOT_AT || Date.now());

if (Number.isNaN(capturedAt.getTime())) throw new Error('SNAPSHOT_AT must be a valid date');

const headers = {
  Accept: 'application/vnd.github+json',
  'User-Agent': 'nativ-star-history',
  'X-GitHub-Api-Version': '2026-03-10'
};

if (token) headers.Authorization = `Bearer ${token}`;

const fetchJSON = async (endpoint) => {
  const response = await fetch(endpoint, { headers });
  if (!response.ok) throw new Error(`GitHub returned ${response.status} for ${endpoint}`);
  return response.json();
};

// GitHub's star-history endpoint already returns one entry per calendar
// week (with a 7-day breakdown), so unlike download history there's no
// need to accumulate our own snapshots over time — every run can just
// re-derive the full series directly from GitHub.
const fetchAllWeeks = async () => {
  const weeks = [];
  for (let page = 1; page <= 20; page += 1) {
    const endpoint = `https://api.github.com/repos/${repository}/stargazers/history?per_page=30&page=${page}`;
    const batch = await fetchJSON(endpoint);
    if (!Array.isArray(batch) || batch.length === 0) break;
    weeks.push(...batch);
    if (batch.length < 30) break;
  }
  return weeks;
};

const repo = await fetchJSON(`https://api.github.com/repos/${repository}`);
const currentTotal = Number(repo.stargazers_count || 0);

const weeks = await fetchAllWeeks();
const sortedWeeks = weeks
  .filter((entry) => Number.isFinite(entry?.week) && Number.isFinite(entry?.total))
  .sort((left, right) => left.week - right.week);

if (sortedWeeks.length < 2) throw new Error('Not enough star history returned to build a chart');

let cumulative = 0;
const points = sortedWeeks.map((entry) => {
  cumulative += entry.total;
  return { date: new Date(entry.week * 1000).toISOString(), value: cumulative };
});

// Anchor the most recent point to the live star count so it matches the
// number shown elsewhere on the site, even if GitHub's history doesn't
// reach all the way back to repo creation.
const drift = currentTotal - points.at(-1).value;
if (drift !== 0) {
  points.forEach((point) => { point.value += drift; });
}

const history = {
  version: 1,
  capturedAt: capturedAt.toISOString(),
  currentTotal,
  points
};

await mkdir(path.dirname(outputPath), { recursive: true });
await writeFile(outputPath, `${JSON.stringify(history, null, 2)}\n`);

console.log(`Captured ${points.length} weeks of star history at ${capturedAt.toISOString()}`);
