const releasesEndpoint = 'https://api.github.com/repos/Blaizzy/nativ/releases';

const fallbackReleases = [
  {
    tag_name: 'v0.2.2',
    published_at: '2026-08-04T15:47:48Z',
    html_url: 'https://github.com/Blaizzy/nativ/releases/tag/v0.2.2',
    assets: [
      { name: 'appcast.xml', download_count: 1092, browser_download_url: 'https://github.com/Blaizzy/nativ/releases/download/v0.2.2/appcast.xml' },
      { name: 'Nativ-0.2.2.dmg', download_count: 591, browser_download_url: 'https://github.com/Blaizzy/nativ/releases/download/v0.2.2/Nativ-0.2.2.dmg' }
    ]
  },
  {
    tag_name: 'v0.2.1',
    published_at: '2026-08-03T23:26:00Z',
    html_url: 'https://github.com/Blaizzy/nativ/releases/tag/v0.2.1',
    assets: [
      { name: 'appcast.xml', download_count: 198, browser_download_url: 'https://github.com/Blaizzy/nativ/releases/download/v0.2.1/appcast.xml' },
      { name: 'Nativ-0.2.1.dmg', download_count: 180, browser_download_url: 'https://github.com/Blaizzy/nativ/releases/download/v0.2.1/Nativ-0.2.1.dmg' }
    ]
  },
  {
    tag_name: 'v0.2.0',
    published_at: '2026-08-03T19:50:52Z',
    html_url: 'https://github.com/Blaizzy/nativ/releases/tag/v0.2.0',
    assets: [
      { name: 'appcast.xml', download_count: 26, browser_download_url: 'https://github.com/Blaizzy/nativ/releases/download/v0.2.0/appcast.xml' },
      { name: 'Nativ-0.2.0.dmg', download_count: 64, browser_download_url: 'https://github.com/Blaizzy/nativ/releases/download/v0.2.0/Nativ-0.2.0.dmg' }
    ]
  },
  {
    tag_name: 'v0.1.0',
    published_at: '2026-07-27T20:41:58Z',
    html_url: 'https://github.com/Blaizzy/nativ/releases/tag/v0.1.0',
    assets: [
      { name: 'appcast.xml', download_count: 719, browser_download_url: 'https://github.com/Blaizzy/nativ/releases/download/v0.1.0/appcast.xml' },
      { name: 'Nativ-0.1.0.dmg', download_count: 870, browser_download_url: 'https://github.com/Blaizzy/nativ/releases/download/v0.1.0/Nativ-0.1.0.dmg' }
    ]
  },
  {
    tag_name: 'v0.0.1',
    published_at: '2026-07-20T16:53:28Z',
    html_url: 'https://github.com/Blaizzy/nativ/releases/tag/v0.0.1',
    assets: [
      { name: 'Nativ-0.0.1.dmg', download_count: 4854, browser_download_url: 'https://github.com/Blaizzy/nativ/releases/download/v0.0.1/Nativ-0.0.1.dmg' }
    ]
  }
];

const numberFormatter = new Intl.NumberFormat('en-US');
const dateFormatter = new Intl.DateTimeFormat('en-US', {
  month: 'short',
  day: 'numeric',
  year: 'numeric'
});

const filterLabels = {
  all: 'All assets',
  dmg: 'Installers',
  appcast: 'Update feed'
};

const state = {
  releases: fallbackReleases,
  assetType: 'all',
  release: 'all'
};

const rowsContainer = document.querySelector('[data-download-rows]');
const releaseFilter = document.querySelector('[data-release-filter]');
const resultTotal = document.querySelector('[data-result-total]');
const resultLabel = document.querySelector('[data-result-label]');
const resultCount = document.querySelector('[data-result-count]');
const dataStatus = document.querySelector('[data-data-status]');
const refreshedAt = document.querySelector('[data-refreshed-at]');

const getAssetType = (asset) => {
  const name = asset.name.toLowerCase();
  if (name.endsWith('.dmg')) return 'dmg';
  if (name === 'appcast.xml') return 'appcast';
  return 'other';
};

const flattenAssets = (releases) => releases.flatMap((release) =>
  (release.assets ?? [])
    .filter((asset) => asset.state !== 'open')
    .map((asset) => ({
      ...asset,
      type: getAssetType(asset),
      release: release.tag_name,
      releaseUrl: release.html_url,
      publishedAt: release.published_at
    }))
);

const sumDownloads = (assets) => assets.reduce(
  (total, asset) => total + Number(asset.download_count || 0),
  0
);

const setText = (selector, value) => {
  document.querySelectorAll(selector).forEach((node) => {
    node.textContent = value;
  });
};

const updateSummaryMetrics = (assets) => {
  const installers = assets.filter((asset) => asset.type === 'dmg');
  const updateFeeds = assets.filter((asset) => asset.type === 'appcast');
  const totals = {
    dmg: sumDownloads(installers),
    appcast: sumDownloads(updateFeeds),
    all: sumDownloads(assets)
  };

  setText('[data-installer-total]', numberFormatter.format(totals.dmg));
  setText('[data-update-total]', numberFormatter.format(totals.appcast));
  setText('[data-all-total]', numberFormatter.format(totals.all));

  Object.entries(totals).forEach(([type, total]) => {
    setText(`[data-filter-count="${type}"]`, numberFormatter.format(total));
  });
};

const makeCell = (content, className) => {
  const cell = document.createElement('td');
  if (className) cell.className = className;
  if (content instanceof Node) cell.append(content);
  else cell.textContent = content;
  return cell;
};

const assetTypeLabel = (type) => ({
  dmg: 'Installer',
  appcast: 'Update feed',
  other: 'Other asset'
})[type];

const renderRows = (assets, total) => {
  if (!rowsContainer) return;
  rowsContainer.replaceChildren();

  if (!assets.length) {
    const row = document.createElement('tr');
    const cell = makeCell('No assets match these filters.', 'download-loading');
    cell.colSpan = 6;
    row.append(cell);
    rowsContainer.append(row);
    return;
  }

  assets.forEach((asset) => {
    const row = document.createElement('tr');
    const releaseLink = document.createElement('a');
    releaseLink.href = asset.releaseUrl;
    releaseLink.target = '_blank';
    releaseLink.rel = 'noreferrer';
    releaseLink.textContent = asset.release;

    const assetLink = document.createElement('a');
    assetLink.href = asset.browser_download_url || asset.releaseUrl;
    assetLink.target = '_blank';
    assetLink.rel = 'noreferrer';
    assetLink.textContent = asset.name;

    const badge = document.createElement('span');
    badge.className = `asset-badge asset-badge-${asset.type}`;
    badge.textContent = assetTypeLabel(asset.type);

    const downloads = document.createElement('strong');
    downloads.textContent = numberFormatter.format(asset.download_count);

    const share = total > 0 ? (asset.download_count / total) * 100 : 0;
    const shareWrap = document.createElement('div');
    shareWrap.className = 'download-share';
    shareWrap.setAttribute('aria-label', `${share.toFixed(1)}% of filtered downloads`);
    const bar = document.createElement('i');
    bar.style.setProperty('--share', `${Math.max(share, 1)}%`);
    const percentage = document.createElement('span');
    percentage.textContent = `${share.toFixed(1)}%`;
    shareWrap.append(bar, percentage);

    row.append(
      makeCell(releaseLink, 'download-release'),
      makeCell(assetLink, 'download-asset'),
      makeCell(badge),
      makeCell(dateFormatter.format(new Date(asset.publishedAt)), 'download-date'),
      makeCell(downloads, 'download-value'),
      makeCell(shareWrap)
    );
    rowsContainer.append(row);
  });
};

const syncQuery = () => {
  const url = new URL(window.location.href);
  if (state.assetType === 'all') url.searchParams.delete('asset');
  else url.searchParams.set('asset', state.assetType);
  if (state.release === 'all') url.searchParams.delete('release');
  else url.searchParams.set('release', state.release);
  window.history.replaceState({}, '', url);
};

const render = () => {
  const allAssets = flattenAssets(state.releases);
  const filteredAssets = allAssets.filter((asset) => {
    const typeMatches = state.assetType === 'all' || asset.type === state.assetType;
    const releaseMatches = state.release === 'all' || asset.release === state.release;
    return typeMatches && releaseMatches;
  });
  const total = sumDownloads(filteredAssets);
  const releaseCount = new Set(filteredAssets.map((asset) => asset.release)).size;

  updateSummaryMetrics(allAssets);
  renderRows(filteredAssets, total);

  if (resultTotal) resultTotal.textContent = numberFormatter.format(total);
  if (resultLabel) {
    const releaseLabel = state.release === 'all' ? 'all releases' : state.release;
    resultLabel.textContent = `${filterLabels[state.assetType]} · ${releaseLabel}`;
  }
  if (resultCount) {
    const assetWord = filteredAssets.length === 1 ? 'asset' : 'assets';
    const releaseWord = releaseCount === 1 ? 'release' : 'releases';
    resultCount.textContent = `${filteredAssets.length} ${assetWord} across ${releaseCount} ${releaseWord}`;
  }

  document.querySelectorAll('[data-asset-filter]').forEach((button) => {
    const active = button.dataset.assetFilter === state.assetType;
    button.classList.toggle('active', active);
    button.setAttribute('aria-pressed', String(active));
  });
  if (releaseFilter) releaseFilter.value = state.release;
  syncQuery();
};

const populateReleaseFilter = () => {
  if (!releaseFilter) return;
  releaseFilter.replaceChildren(new Option('All releases', 'all'));
  state.releases.forEach((release) => {
    releaseFilter.add(new Option(release.tag_name, release.tag_name));
  });

  const requestedRelease = new URLSearchParams(window.location.search).get('release');
  const releaseExists = state.releases.some((release) => release.tag_name === requestedRelease);
  state.release = releaseExists ? requestedRelease : 'all';
};

document.querySelectorAll('[data-asset-filter]').forEach((button) => {
  button.addEventListener('click', () => {
    state.assetType = button.dataset.assetFilter;
    render();
  });
});

releaseFilter?.addEventListener('change', () => {
  state.release = releaseFilter.value;
  render();
});

const requestedAssetType = new URLSearchParams(window.location.search).get('asset');
if (['dmg', 'appcast'].includes(requestedAssetType)) state.assetType = requestedAssetType;
populateReleaseFilter();
render();

const fetchAllReleases = async () => {
  const releases = [];
  for (let page = 1; page <= 10; page += 1) {
    const response = await fetch(`${releasesEndpoint}?per_page=100&page=${page}`, {
      cache: 'no-store',
      headers: { Accept: 'application/vnd.github+json' }
    });
    if (!response.ok) throw new Error(`GitHub returned ${response.status}`);
    const pageReleases = await response.json();
    releases.push(...pageReleases.filter((release) => !release.draft));
    if (pageReleases.length < 100) break;
  }
  return releases;
};

fetchAllReleases()
  .then((releases) => {
    if (!releases.length) throw new Error('No published releases found');
    state.releases = releases;
    populateReleaseFilter();
    render();
    if (dataStatus) dataStatus.textContent = 'Live from GitHub';
    if (refreshedAt) {
      refreshedAt.dateTime = new Date().toISOString();
      refreshedAt.textContent = `Updated ${new Intl.DateTimeFormat('en-US', {
        hour: 'numeric',
        minute: '2-digit',
        timeZoneName: 'short'
      }).format(new Date())}`;
    }
  })
  .catch(() => {
    if (dataStatus) dataStatus.textContent = 'Cached snapshot';
    if (refreshedAt) {
      refreshedAt.dateTime = '2026-08-09';
      refreshedAt.textContent = 'Snapshot · Aug 9, 2026';
    }
  });
