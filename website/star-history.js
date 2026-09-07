(() => {
const historyPath = 'data/star-history.json';

const numberFormatter = new Intl.NumberFormat('en-US');
const compactNumber = new Intl.NumberFormat('en-US', { notation: 'compact', maximumFractionDigits: 1 });
const shortDate = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric' });

const chartPlot = document.querySelector('[data-star-chart]');
const chartLines = document.querySelector('[data-star-chart-lines]');
const chartAxis = document.querySelector('[data-star-chart-axis]');
const chartStart = document.querySelector('[data-star-chart-start]');
const chartEnd = document.querySelector('[data-star-chart-end]');
const chartEmpty = document.querySelector('[data-star-chart-empty]');
const chartSummary = document.querySelector('[data-star-chart-summary]');

let chartPoints = [];
let chartFrame = null;

const setEmptyState = (message) => {
  chartPoints = [];
  if (chartPlot) chartPlot.hidden = true;
  if (chartEmpty) chartEmpty.hidden = false;
  if (chartSummary) chartSummary.textContent = message;
};

const drawStarChart = () => {
  if (!chartPlot || !chartLines || chartPoints.length < 2 || chartPlot.hidden) return;
  const bounds = chartLines.getBoundingClientRect();
  if (!bounds.width || !bounds.height) return;

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
  chartFrame = window.requestAnimationFrame(drawStarChart);
};

const loadStarHistory = async () => {
  setEmptyState('Loading star history.');
  try {
    const response = await fetch(historyPath, { cache: 'no-store' });
    if (!response.ok) throw new Error(`history request failed (${response.status})`);
    const history = await response.json();

    const points = (history.points || [])
      .map((point) => ({ date: new Date(point.date), value: Number(point.value) }))
      .filter((point) => Number.isFinite(point.date.getTime()) && Number.isFinite(point.value))
      .sort((left, right) => left.date - right.date);

    if (points.length < 2) {
      setEmptyState('Star history appears after the next scheduled update.');
      return;
    }

    chartPoints = points;
    if (chartPlot) {
      chartPlot.hidden = false;
      const netChange = points.at(-1).value - points[0].value;
      chartPlot.setAttribute(
        'aria-label',
        `Nativ GitHub star history. ${numberFormatter.format(points.at(-1).value)} stars, ${netChange >= 0 ? '+' : ''}${numberFormatter.format(netChange)} over the displayed period.`
      );
    }
    if (chartEmpty) chartEmpty.hidden = true;
    if (chartSummary) {
      const capturedAt = new Date(history.capturedAt);
      const asOf = Number.isFinite(capturedAt.getTime()) ? shortDate.format(capturedAt) : shortDate.format(points.at(-1).date);
      chartSummary.textContent = `${numberFormatter.format(points.at(-1).value)} stars as of ${asOf}.`;
    }
    scheduleChartDraw();
  } catch (error) {
    setEmptyState('Star history is unavailable.');
  }
};

window.addEventListener('resize', scheduleChartDraw);
loadStarHistory();
})();
