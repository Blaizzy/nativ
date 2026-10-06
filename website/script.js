const header = document.querySelector('[data-header]');
const menuButton = document.querySelector('[data-menu-button]');
const mobileMenu = document.querySelector('[data-mobile-menu]');

const updateHeader = () => header?.classList.toggle('scrolled', window.scrollY > 12);
updateHeader();
window.addEventListener('scroll', updateHeader, { passive: true });

menuButton?.addEventListener('click', () => {
  const isOpen = menuButton.getAttribute('aria-expanded') === 'true';
  menuButton.setAttribute('aria-expanded', String(!isOpen));
  mobileMenu?.classList.toggle('open', !isOpen);
});

mobileMenu?.querySelectorAll('a').forEach((link) => {
  link.addEventListener('click', () => {
    mobileMenu.classList.remove('open');
    menuButton?.setAttribute('aria-expanded', 'false');
  });
});

document.querySelector('[data-to-top]')?.addEventListener('click', () => {
  window.scrollTo({ top: 0, behavior: 'smooth' });
});

const revealObserver = new IntersectionObserver(
  (entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add('is-visible');
        revealObserver.unobserve(entry.target);
      }
    });
  },
  { threshold: 0.12 }
);

document.querySelectorAll('.reveal').forEach((element, index) => {
  element.style.transitionDelay = `${Math.min(index % 3, 2) * 70}ms`;
  revealObserver.observe(element);
});

const productScreens = {
  chat: {
    src: 'assets/screenshots/nativ-main.png',
    alt: 'Nativ chat running the Gemma 4 model locally, with response token and memory telemetry',
    label: '01 / CHAT',
    caption: 'Talk to open models with streaming responses and per-message performance metrics.'
  },
  dashboard: {
    src: 'assets/screenshots/nativ-dashboard.png',
    alt: 'Nativ analytics dashboard showing local token usage, requests, success rate, and decode speed',
    label: '02 / ANALYTICS',
    caption: 'See token usage, request volume, success rate, and decode speed across your local workspace.'
  },
  models: {
    src: 'assets/screenshots/nativ-models.png',
    alt: 'Nativ model library with the CohereLabs North-Mini-Code model selected',
    label: '03 / MODELS',
    caption: 'Manage installed models and understand context, size, modalities, and tool support at a glance.'
  },
  integrations: {
    src: 'assets/screenshots/nativ-integrations.png',
    alt: 'Nativ integrations screen showing Pi, Codex, Claude Code, Hermes, and OpenCode configured to use local models',
    label: '04 / INTEGRATIONS',
    caption: 'Connect coding agents to models served locally from your Mac.'
  }
};

const productScreenshot = document.querySelector('[data-product-screenshot]');
if (productScreenshot) {
  Object.values(productScreens).forEach(({ src }) => {
    const image = new Image();
    image.src = src;
  });
}

const screenLabel = document.querySelector('[data-screen-label]');
const screenCaption = document.querySelector('[data-screen-caption]');

document.querySelectorAll('[data-screen]').forEach((button) => {
  button.addEventListener('click', () => {
    const screen = productScreens[button.dataset.screen];
    if (!screen || !productScreenshot) return;

    document.querySelectorAll('[data-screen]').forEach((tab) => {
      const isActive = tab === button;
      tab.classList.toggle('active', isActive);
      tab.setAttribute('aria-selected', String(isActive));
    });

    productScreenshot.classList.add('switching');
    window.setTimeout(() => {
      productScreenshot.src = screen.src;
      productScreenshot.alt = screen.alt;
      if (screenLabel) screenLabel.textContent = screen.label;
      if (screenCaption) screenCaption.textContent = screen.caption;
      productScreenshot.classList.remove('switching');
    }, 140);
  });
});

fetch('https://api.github.com/repos/Blaizzy/nativ/releases/latest', {
  cache: 'no-store',
  headers: { Accept: 'application/vnd.github+json' }
})
  .then((response) => (response.ok ? response.json() : Promise.reject()))
  .then((release) => {
    if (release.tag_name) {
      document.querySelectorAll('[data-release-version]').forEach((node) => {
        node.textContent = release.tag_name;
      });
    }

    const installers = release.assets?.filter(
      (asset) => asset.state === 'uploaded' && asset.name.toLowerCase().endsWith('.dmg')
    );
    const installer = installers?.find(
      (asset) => asset.content_type === 'application/x-apple-diskimage'
    ) ?? installers?.[0];
    if (!installer?.browser_download_url) return;

    document.querySelectorAll('[data-download]').forEach((link) => {
      link.href = installer.browser_download_url;
    });
  })
  .catch(() => {});

fetch('https://api.github.com/repos/Blaizzy/nativ')
  .then((response) => (response.ok ? response.json() : Promise.reject()))
  .then((repository) => {
    const value = repository.stargazers_count;
    document.querySelectorAll('[data-stars]').forEach((node) => {
      node.textContent = value >= 1000 ? `${(value / 1000).toFixed(1)}k` : String(value);
    });
  })
  .catch(() => {});
