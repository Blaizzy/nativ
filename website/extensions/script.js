const list = document.querySelector('[data-extension-list]');
const search = document.querySelector('[data-extension-search]');
const count = document.querySelector('[data-extension-count]');
const filters = [...document.querySelectorAll('[data-filter]')];

let extensions = [];
let activeFilter = 'featured';

const matchesFilter = (extension) => {
  if (activeFilter === 'featured') return extension.featured === true;
  return true;
};

const emptyMessage = (query) => {
  if (query) return ['No matches found', 'Try a different name, category, or developer.'];
  if (extensions.length) return ['Nothing here yet', 'Choose another MarketPlace view.'];
  return ['The MarketPlace is opening soon', 'Reviewed extensions will appear here as they are published.'];
};

const render = () => {
  if (!list) return;

  const query = search?.value.trim().toLocaleLowerCase() ?? '';
  const matches = [...extensions]
    .filter(matchesFilter)
    .filter((extension) =>
      [extension.displayName, extension.summary, extension.category, extension.developer]
        .some((value) => value.toLocaleLowerCase().includes(query))
    )
    .sort((left, right) => activeFilter === 'recent'
      ? right.publishedAt.localeCompare(left.publishedAt)
      : 0
    );

  if (count) count.textContent = `${matches.length} ${matches.length === 1 ? 'extension' : 'extensions'}`;
  list.replaceChildren();

  if (!matches.length) {
    const [title, detail] = emptyMessage(query);
    const message = document.createElement('p');
    message.className = 'extension-message';
    const strong = document.createElement('strong');
    strong.textContent = title;
    const span = document.createElement('span');
    span.textContent = detail;
    message.append(strong, span);
    list.append(message);
    return;
  }

  matches.forEach((extension) => {
    const card = document.createElement('article');
    card.className = 'extension-card';
    card.id = extension.id;

    const mark = document.createElement('div');
    mark.className = 'extension-mark';
    mark.setAttribute('aria-hidden', 'true');
    mark.textContent = extension.displayName.split(/\s+/).map((word) => word[0]).join('').slice(0, 2);

    const identity = document.createElement('div');
    identity.className = 'extension-identity';
    const name = document.createElement('h3');
    name.textContent = extension.displayName;
    const meta = document.createElement('div');
    meta.className = 'extension-meta';
    meta.textContent = `${extension.category} · ${extension.developer}`;
    identity.append(name, meta);

    const summary = document.createElement('p');
    summary.className = 'extension-summary';
    summary.textContent = extension.summary;

    const status = document.createElement('span');
    status.className = 'extension-status';
    status.textContent = extension.status === 'preview' ? 'Coming soon' : 'View extension';

    card.append(mark, identity, summary, status);
    list.append(card);
  });
};

filters.forEach((filter) => {
  filter.addEventListener('click', () => {
    activeFilter = filter.dataset.filter;
    filters.forEach((item) => item.classList.toggle('active', item === filter));
    render();
  });
});

search?.addEventListener('input', render);
document.addEventListener('keydown', (event) => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLocaleLowerCase() === 'k') {
    event.preventDefault();
    search?.focus();
  }
});

fetch('./catalog.json')
  .then((response) => response.ok ? response.json() : Promise.reject())
  .then((catalog) => {
    extensions = Array.isArray(catalog.extensions) ? catalog.extensions : [];
    if (extensions.length && !extensions.some((extension) => extension.featured === true)) {
      activeFilter = 'all';
      filters.forEach((item) => item.classList.toggle('active', item.dataset.filter === 'all'));
    }
    render();
  })
  .catch(() => {
    if (!list) return;
    list.replaceChildren();
    const message = document.createElement('p');
    message.className = 'extension-message';
    message.textContent = 'The MarketPlace catalog could not be loaded.';
    list.append(message);
  });
