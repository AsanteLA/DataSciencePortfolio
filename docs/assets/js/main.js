// ============================================================
// Portfolio site — small JS for scroll-reveal and active nav
// ============================================================

(function () {
  'use strict';

  // --- Scroll reveal (IntersectionObserver) ---------------------
  const revealTargets = document.querySelectorAll('.reveal, .stagger');
  if ('IntersectionObserver' in window && revealTargets.length) {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add('in');
          io.unobserve(entry.target);
        }
      });
    }, { threshold: 0.12, rootMargin: '0px 0px -40px 0px' });

    revealTargets.forEach((el) => io.observe(el));
  } else {
    // Fallback: just show everything
    revealTargets.forEach((el) => el.classList.add('in'));
  }

  // --- Active nav link based on current path --------------------
  const path = window.location.pathname.split('/').pop() || 'index.html';
  document.querySelectorAll('.nav-links a').forEach((a) => {
    const href = a.getAttribute('href');
    if (href === path || (path === '' && href === 'index.html')) {
      a.classList.add('active');
    }
  });

  // --- Animated hero headline (wrap letters in spans) -----------
  const heroTitle = document.querySelector('[data-animate-title]');
  if (heroTitle) {
    const text = heroTitle.textContent.trim();
    heroTitle.textContent = '';
    text.split(/(\s+)/).forEach((chunk) => {
      if (/^\s+$/.test(chunk)) {
        heroTitle.appendChild(document.createTextNode(chunk));
        return;
      }
      const word = document.createElement('span');
      word.className = 'animate-word';
      const inner = document.createElement('span');
      inner.textContent = chunk;
      word.appendChild(inner);
      heroTitle.appendChild(word);
    });
  }

  // --- Smooth fade-out on internal nav click --------------------
  // Gives pages a subtle page-transition feel without a router.
  document.querySelectorAll('a[href]').forEach((a) => {
    const href = a.getAttribute('href');
    if (!href) return;
    const isInternal =
      !href.startsWith('http') &&
      !href.startsWith('#') &&
      !href.startsWith('mailto:') &&
      !a.hasAttribute('target');
    if (!isInternal) return;

    a.addEventListener('click', (e) => {
      // Let modifier-clicks go through naturally
      if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      e.preventDefault();
      document.body.style.transition = 'opacity .35s ease, transform .35s ease';
      document.body.style.opacity = '0';
      document.body.style.transform = 'translateY(-4px)';
      setTimeout(() => { window.location.href = href; }, 320);
    });
  });
})();
