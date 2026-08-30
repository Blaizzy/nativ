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
  appcast: 'Update checks'
};

const state = {
  releases: fallbackReleases,
  assetType: 'all',
  release: 'all',
  history: null,
  historyStatus: 'loading',
  liveData: false
};

const rowsContainer = document.querySelector('[data-download-rows]');
const releaseSelect = document.querySelector('[data-release-select]');
const releaseTrigger = document.querySelector('[data-release-trigger]');
const releaseValue = document.querySelector('[data-release-value]');
const releaseOptions = document.querySelector('[data-release-options]');
const resultTotal = document.querySelector('[data-result-total]');
const resultLabel = document.querySelector('[data-result-label]');
const resultCount = document.querySelector('[data-result-count]');
const dataStatus = document.querySelector('[data-data-status]');
const refreshedAt = document.querySelector('[data-refreshed-at]');
const progressScope = document.querySelector('[data-progress-scope]');
const chartPlot = document.querySelector('[data-download-chart]');
const chartLines = document.querySelector('[data-chart-lines]');
const chartAxis = document.querySelector('[data-chart-axis]');
const chartStart = document.querySelector('[data-chart-start]');
const chartEnd = document.querySelector('[data-chart-end]');
const chartEmpty = document.querySelector('[data-chart-empty]');
const chartSummary = document.querySelector('[data-chart-summary]');
const chartScope = document.querySelector('[data-chart-scope]');

const progressPeriods = [
  { key: 'day', days: 1, unavailableLabel: 'Available after 24 hours' },
  { key: 'week', days: 7, unavailableLabel: 'Available after 7 days' },
  { key: 'month', days: 30, unavailableLabel: 'Available after 30 days' },
  { key: 'year', days: 365, unavailableLabel: 'Available after 1 year' }
];

let chartPoints = [];
let chartFrame = null;

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

const getFilteredAssets = (assets) => assets.filter((asset) => {
  const typeMatches = state.assetType === 'all' || asset.type === state.assetType;
  const releaseMatches = state.release === 'all' || asset.release === state.release;
  return typeMatches && releaseMatches;
});

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

const setProgressState = (period, value, note, title = '') => {
  const valueNode = document.querySelector(`[data-progress-value="${period.key}"]`);
  const noteNode = document.querySelector(`[data-progress-note="${period.key}"]`);
  if (valueNode) {
    valueNode.textContent = value;
    valueNode.title = title;
  }
  if (noteNode) noteNode.textContent = note;
};

const getHistoryAssetKey = (asset) => {
  if (!state.history?.assetIndex) return null;
  const idKey = asset.id == null ? null : String(asset.id);
  if (idKey && state.history.assetIndex[idKey]) return idKey;

  const matchingEntry = Object.entries(state.history.assetIndex).find(([, metadata]) => (
    metadata.release === asset.release && metadata.name === asset.name
  ));
  return matchingEntry?.[0] || idKey;
};

const renderProgress = (assets) => {
  const releaseLabel = state.release === 'all' ? 'all releases' : state.release;
  if (progressScope) progressScope.textContent = `${filterLabels[state.assetType]} · ${releaseLabel}`;

  if (!state.liveData) {
    progressPeriods.forEach((period) => setProgressState(period, '—', 'Waiting for live data'));
    return;
  }

  if (state.historyStatus === 'loading') {
    progressPeriods.forEach((period) => setProgressState(period, '—', 'Loading history'));
    return;
  }

  if (state.historyStatus === 'error') {
    progressPeriods.forEach((period) => setProgressState(period, '—', 'History unavailable'));
    return;
  }

  const snapshots = (state.history?.snapshots || [])
    .filter((snapshot) => Number.isFinite(new Date(snapshot.capturedAt).getTime()))
    .sort((left, right) => new Date(left.capturedAt) - new Date(right.capturedAt));
  const now = Date.now();

  progressPeriods.forEach((period) => {
    const cutoff = now - (period.days * 24 * 60 * 60 * 1000);
    const baseline = [...snapshots]
      .reverse()
      .find((snapshot) => new Date(snapshot.capturedAt).getTime() <= cutoff);

    if (!baseline) {
      setProgressState(period, '—', period.unavailableLabel);
      return;
    }

    let baselineTotal = 0;
    let delta = 0;
    assets.forEach((asset) => {
      const currentCount = Number(asset.download_count || 0);
      const key = getHistoryAssetKey(asset);
      const baselineCount = key ? Number(baseline.counts?.[key] || 0) : 0;
      baselineTotal += baselineCount;
      delta += Math.max(currentCount - baselineCount, 0);
    });

    const percentage = baselineTotal > 0 ? (delta / baselineTotal) * 100 : null;
    const formattedDelta = delta > 0 ? `+${numberFormatter.format(delta)}` : '0';
    const note = percentage == null
      ? (delta > 0 ? 'New downloads' : 'No change')
      : `${percentage < 0.1 && percentage > 0 ? percentage.toFixed(2) : percentage.toFixed(1)}% growth`;
    const baselineDate = new Intl.DateTimeFormat('en-US', {
      month: 'short',
      day: 'numeric',
      year: 'numeric',
      hour: 'numeric',
      minute: '2-digit'
    }).format(new Date(baseline.capturedAt));

    setProgressState(period, formattedDelta, note, `Compared with the ${baselineDate} snapshot`);
  });
};

const setChartEmptyState = (message) => {
  chartPoints = [];
  if (chartPlot) chartPlot.hidden = true;
  if (chartEmpty) chartEmpty.hidden = false;
  if (chartSummary) chartSummary.textContent = message;
};

const drawDownloadChart = () => {
  if (!chartPlot || !chartLines || chartPoints.length < 2 || chartPlot.hidden) return;
  const bounds = chartLines.getBoundingClientRect();
  if (!bounds.width || !bounds.height) return;

  const compactNumber = new Intl.NumberFormat('en-US', { notation: 'compact', maximumFractionDigits: 1 });
  const shortDate = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric' });
  const firstTime = chartPoints[0].date.getTime();
  const lastTime = chartPoints.at(-1).date.getTime();
  const values = chartPoints.map((point) => point.value);
  const rawMinimum = Math.min(...values);
  const rawMaximum = Math.max(...values);
  const rawRange = rawMaximum - rawMinimum;
  const rangePadding = rawRange > 0 ? rawRange * 0.12 : Math.max(rawMaximum * 0.04, 1);
  const minimum = Math.max(0, rawMinimum - rangePadding);
  const maximum = rawMaximum + rangePadding;
  const valueRange = Math.max(maximum - minimum, 1);
  const timeRange = Math.max(lastTime - firstTime, 1);
  const toX = (date) => ((date.getTime() - firstTime) / timeRange) * bounds.width;
  const toY = (value) => (1 - ((value - minimum) / valueRange)) * bounds.height;
  const coordinates = chartPoints.map((point) => ({ x: toX(point.date), y: toY(point.value) }));
  const fragment = document.createDocumentFragment();

  const area = document.createElement('i');
  area.className = 'download-chart-area';
  const polygonPoints = coordinates
    .map(({ x, y }) => `${(x / bounds.width) * 100}% ${(y / bounds.height) * 100}%`)
    .join(', ');
  area.style.clipPath = `polygon(${polygonPoints}, 100% 100%, 0 100%)`;
  fragment.append(area);

  coordinates.slice(0, -1).forEach((point, index) => {
    const nextPoint = coordinates[index + 1];
    const deltaX = nextPoint.x - point.x;
    const deltaY = nextPoint.y - point.y;
    const segment = document.createElement('i');
    segment.className = 'download-chart-segment';
    segment.style.left = `${point.x}px`;
    segment.style.top = `${point.y}px`;
    segment.style.width = `${Math.hypot(deltaX, deltaY)}px`;
    segment.style.transform = `rotate(${Math.atan2(deltaY, deltaX)}rad)`;
    fragment.append(segment);
  });

  const latestCoordinates = coordinates.at(-1);
  const latestMarker = document.createElement('i');
  latestMarker.className = 'download-chart-point';
  latestMarker.style.left = `${latestCoordinates.x}px`;
  latestMarker.style.top = `${latestCoordinates.y}px`;
  fragment.append(latestMarker);
  chartLines.replaceChildren(fragment);

  if (chartAxis) {
    const labels = Array.from({ length: 5 }, (_, index) => {
      const label = document.createElement('span');
      const value = maximum - ((index / 4) * valueRange);
      label.textContent = compactNumber.format(Math.max(value, 0));
      return label;
    });
    chartAxis.replaceChildren(...labels);
  }
  if (chartStart) chartStart.textContent = shortDate.format(chartPoints[0].date);
  if (chartEnd) chartEnd.textContent = shortDate.format(chartPoints.at(-1).date);
};

const scheduleChartDraw = () => {
  if (chartFrame) window.cancelAnimationFrame(chartFrame);
  chartFrame = window.requestAnimationFrame(drawDownloadChart);
};

const renderDownloadChart = (assets) => {
  const releaseLabel = state.release === 'all' ? 'all releases' : state.release;
  const scopeLabel = `${filterLabels[state.assetType]} · ${releaseLabel}`;
  if (chartScope) chartScope.textContent = scopeLabel;

  if (!state.liveData) {
    setChartEmptyState('Waiting for live download data.');
    return;
  }
  if (state.historyStatus === 'loading') {
    setChartEmptyState('Loading download history.');
    return;
  }
  if (state.historyStatus === 'error') {
    setChartEmptyState('Download history is unavailable.');
    return;
  }

  const cutoff = Date.now() - (365 * 24 * 60 * 60 * 1000);
  const points = (state.history?.snapshots || [])
    .map((snapshot) => ({
      date: new Date(snapshot.capturedAt),
      value: assets.reduce((total, asset) => {
        const key = getHistoryAssetKey(asset);
        return total + (key ? Number(snapshot.counts?.[key] || 0) : 0);
      }, 0)
    }))
    .filter((point) => Number.isFinite(point.date.getTime()) && point.date.getTime() >= cutoff)
    .sort((left, right) => left.date - right.date);

  const currentPoint = { date: new Date(), value: sumDownloads(assets) };
  const latestPoint = points.at(-1);
  if (!latestPoint || currentPoint.date.getTime() - latestPoint.date.getTime() > 60 * 60 * 1000) {
    points.push(currentPoint);
  } else if (latestPoint) {
    latestPoint.value = currentPoint.value;
  }

  if (points.length < 2) {
    setChartEmptyState('The chart appears after another snapshot is recorded.');
    return;
  }

  chartPoints = points;
  if (chartPlot) {
    chartPlot.hidden = false;
    const netChange = points.at(-1).value - points[0].value;
    chartPlot.setAttribute(
      'aria-label',
      `${scopeLabel} cumulative download history. ${numberFormatter.format(points.at(-1).value)} downloads, ${netChange >= 0 ? '+' : ''}${numberFormatter.format(netChange)} over the displayed period.`
    );
  }
  if (chartEmpty) chartEmpty.hidden = true;

  const netChange = points.at(-1).value - points[0].value;
  const firstDate = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric' }).format(points[0].date);
  if (chartSummary) {
    chartSummary.textContent = `${numberFormatter.format(points.length)} snapshots · ${netChange >= 0 ? '+' : ''}${numberFormatter.format(netChange)} downloads since ${firstDate}`;
  }
  scheduleChartDraw();
};

window.addEventListener('resize', scheduleChartDraw);

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

const setReleaseMenuOpen = (open, focusSelected = false) => {
  if (!releaseTrigger || !releaseOptions) return;
  releaseTrigger.setAttribute('aria-expanded', String(open));
  releaseOptions.hidden = !open;

  if (open && focusSelected) {
    const selected = releaseOptions.querySelector('[aria-selected="true"]');
    (selected || releaseOptions.querySelector('[data-release-option]'))?.focus();
  }
};

const selectRelease = (value) => {
  state.release = value;
  render();
  setReleaseMenuOpen(false);
  releaseTrigger?.focus();
};

const render = () => {
  const allAssets = flattenAssets(state.releases);
  const filteredAssets = getFilteredAssets(allAssets);
  const total = sumDownloads(filteredAssets);
  const releaseCount = new Set(filteredAssets.map((asset) => asset.release)).size;

  updateSummaryMetrics(allAssets);
  renderProgress(filteredAssets);
  renderDownloadChart(filteredAssets);
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
  const releaseText = state.release === 'all' ? 'All releases' : state.release;
  if (releaseValue) releaseValue.textContent = releaseText;
  if (releaseTrigger) releaseTrigger.setAttribute('aria-label', `Release: ${releaseText}`);
  releaseOptions?.querySelectorAll('[data-release-option]').forEach((option) => {
    option.setAttribute('aria-selected', String(option.dataset.releaseOption === state.release));
  });
  syncQuery();
};

const populateReleaseFilter = () => {
  if (!releaseOptions) return;
  releaseOptions.replaceChildren();

  const addOption = (label, value) => {
    const option = document.createElement('button');
    option.className = 'release-select-option';
    option.type = 'button';
    option.setAttribute('role', 'option');
    option.dataset.releaseOption = value;
    option.setAttribute('aria-selected', String(value === state.release));
    option.textContent = label;
    option.addEventListener('click', () => selectRelease(value));
    releaseOptions.append(option);
  };

  addOption('All releases', 'all');
  state.releases.forEach((release) => addOption(release.tag_name, release.tag_name));

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

releaseTrigger?.addEventListener('click', () => {
  const open = releaseTrigger.getAttribute('aria-expanded') !== 'true';
  setReleaseMenuOpen(open, open);
});

releaseTrigger?.addEventListener('keydown', (event) => {
  if (!['ArrowDown', 'ArrowUp'].includes(event.key)) return;
  event.preventDefault();
  setReleaseMenuOpen(true, true);
});

releaseOptions?.addEventListener('keydown', (event) => {
  const options = [...releaseOptions.querySelectorAll('[data-release-option]')];
  const currentIndex = options.indexOf(document.activeElement);
  let nextIndex = currentIndex;

  if (event.key === 'ArrowDown') nextIndex = Math.min(currentIndex + 1, options.length - 1);
  else if (event.key === 'ArrowUp') nextIndex = Math.max(currentIndex - 1, 0);
  else if (event.key === 'Home') nextIndex = 0;
  else if (event.key === 'End') nextIndex = options.length - 1;
  else if (event.key === 'Escape') {
    event.preventDefault();
    setReleaseMenuOpen(false);
    releaseTrigger?.focus();
    return;
  } else if (['Enter', ' '].includes(event.key)) {
    event.preventDefault();
    const option = options[currentIndex];
    if (option) selectRelease(option.dataset.releaseOption);
    return;
  } else return;

  event.preventDefault();
  options[nextIndex]?.focus();
});

document.addEventListener('click', (event) => {
  if (!releaseSelect?.contains(event.target)) setReleaseMenuOpen(false);
});

releaseSelect?.addEventListener('keydown', (event) => {
  if (event.key === 'Tab') setReleaseMenuOpen(false);
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

const fetchDownloadHistory = async () => {
  const response = await fetch('data/download-history.json', { cache: 'no-store' });
  if (!response.ok) throw new Error(`History returned ${response.status}`);
  const history = await response.json();
  if (history.version !== 1 || typeof history.assetIndex !== 'object' || !Array.isArray(history.snapshots)) {
    throw new Error('Unsupported download history schema');
  }
  return history;
};

fetchDownloadHistory()
  .then((history) => {
    state.history = history;
    state.historyStatus = 'ready';
    render();
  })
  .catch(() => {
    state.historyStatus = 'error';
    render();
  });

fetchAllReleases()
  .then((releases) => {
    if (!releases.length) throw new Error('No published releases found');
    state.releases = releases;
    state.liveData = true;
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
