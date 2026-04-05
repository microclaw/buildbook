(function() {
  'use strict';

  var STORAGE_KEY = 'microclaw-book-reading-progress';
  // Total chapter count for progress calculation
  var TOTAL_CHAPTERS = 23; // 1 intro + 18 chapters + 4 appendices

  // ── Reading Progress (localStorage) ─────────────────────────

  function getReadPages() {
    try {
      return JSON.parse(localStorage.getItem(STORAGE_KEY)) || {};
    } catch(e) {
      return {};
    }
  }

  function markCurrentPageRead() {
    var pages = getReadPages();
    var pageKey = getPageKey();
    if (pageKey && !pages[pageKey]) {
      pages[pageKey] = Date.now();
      localStorage.setItem(STORAGE_KEY, JSON.stringify(pages));
    }
  }

  function getPageKey() {
    // Normalize path: remove trailing .html, query, hash
    var path = window.location.pathname
      .replace(/\.html$/, '')
      .replace(/\/index$/, '')
      .replace(/\/$/, '');
    // Get just the meaningful part after the last known root segment
    var parts = path.split('/');
    // Use last 1-3 segments as key
    return parts.slice(-3).join('/');
  }

  function getReadCount() {
    return Object.keys(getReadPages()).length;
  }

  // ── Sidebar: Home Link ──────────────────────────────────────

  function addHomeLink(scrollbox) {
    if (scrollbox.querySelector('.sidebar-home-link')) return;

    var homeLink = document.createElement('a');
    var root = (typeof path_to_root !== 'undefined') ? path_to_root : '';
    homeLink.href = root + 'introduction.html';
    homeLink.className = 'sidebar-home-link';
    homeLink.innerHTML =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
      '<path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>' +
      '<polyline points="9 22 9 12 15 12 15 22"/></svg>' +
      '<span>首页</span>';
    scrollbox.insertBefore(homeLink, scrollbox.firstChild);
  }

  // ── Sidebar: Progress Bar ───────────────────────────────────

  function addProgressBar(scrollbox) {
    if (scrollbox.querySelector('.reading-progress-bar')) return;

    var readCount = getReadCount();
    var pct = Math.min(100, Math.round((readCount / TOTAL_CHAPTERS) * 100));

    var bar = document.createElement('div');
    bar.className = 'reading-progress-bar';
    bar.innerHTML =
      '<div>阅读进度 <strong>' + readCount + '/' + TOTAL_CHAPTERS + '</strong> (' + pct + '%)</div>' +
      '<div class="progress-track"><div class="progress-fill" style="width:' + pct + '%"></div></div>';

    // Insert after home link
    var homeLink = scrollbox.querySelector('.sidebar-home-link');
    if (homeLink && homeLink.nextSibling) {
      scrollbox.insertBefore(bar, homeLink.nextSibling);
    } else {
      scrollbox.insertBefore(bar, scrollbox.firstChild);
    }
  }

  // ── Sidebar: Read Checkmarks ────────────────────────────────

  function addReadCheckmarks() {
    var pages = getReadPages();
    var links = document.querySelectorAll('.sidebar .chapter li a');

    links.forEach(function(link) {
      if (link.querySelector('.chapter-read-mark')) return;

      // Get the href and normalize
      var href = link.getAttribute('href');
      if (!href) return;

      // Resolve to a page key
      var resolved = resolveHref(href);
      if (resolved && pages[resolved]) {
        var check = document.createElement('span');
        check.className = 'chapter-read-mark';
        check.textContent = ' ✓';
        check.title = '已读';
        link.appendChild(check);
      }
    });
  }

  function resolveHref(href) {
    // Create a temporary link to resolve relative paths
    var a = document.createElement('a');
    a.href = href;
    var path = a.pathname
      .replace(/\.html$/, '')
      .replace(/\/index$/, '')
      .replace(/\/$/, '');
    var parts = path.split('/');
    return parts.slice(-3).join('/');
  }

  // ── Bottom Navigation Cards ─────────────────────────────────

  function addBottomNavCards() {
    var main = document.querySelector('.content main');
    if (!main || main.querySelector('.next-chapter-card')) return;

    // Find mdBook's built-in nav links
    var prevLink = document.querySelector('a.nav-chapters.previous');
    var nextLink = document.querySelector('a.nav-chapters.next');

    // Get chapter titles from sidebar
    var navContainer = document.createElement('div');
    navContainer.style.marginTop = '3em';

    if (prevLink) {
      var prevTitle = getChapterTitle(prevLink.getAttribute('href'));
      var prevCard = document.createElement('a');
      prevCard.href = prevLink.getAttribute('href');
      prevCard.className = 'prev-chapter-card';
      prevCard.innerHTML =
        '<span class="prev-arrow">←</span>' +
        '<div><div style="font-size:0.85em;opacity:0.6">上一章</div>' +
        '<div>' + prevTitle + '</div></div>';
      navContainer.appendChild(prevCard);
    }

    if (nextLink) {
      var nextTitle = getChapterTitle(nextLink.getAttribute('href'));
      var nextCard = document.createElement('a');
      nextCard.href = nextLink.getAttribute('href');
      nextCard.className = 'next-chapter-card';
      nextCard.innerHTML =
        '<div><div class="next-label">下一章</div>' +
        '<div class="next-title">' + nextTitle + '</div></div>' +
        '<span class="next-arrow">→</span>';
      navContainer.appendChild(nextCard);
    }

    if (navContainer.children.length > 0) {
      main.appendChild(navContainer);
    }
  }

  function getChapterTitle(href) {
    if (!href) return '';
    // Try to find the matching sidebar link
    var links = document.querySelectorAll('.sidebar .chapter li a');
    for (var i = 0; i < links.length; i++) {
      var linkHref = links[i].getAttribute('href');
      if (linkHref && href.endsWith(linkHref.replace(/^\.\//, '').replace(/^\.\.\//, ''))) {
        // Get text content without the checkmark
        var text = links[i].textContent.replace(/\s*✓$/, '').trim();
        return text;
      }
    }
    // Fallback: try to resolve via full path match
    var a = document.createElement('a');
    a.href = href;
    for (var j = 0; j < links.length; j++) {
      var b = document.createElement('a');
      b.href = links[j].getAttribute('href');
      if (a.pathname === b.pathname) {
        return links[j].textContent.replace(/\s*✓$/, '').trim();
      }
    }
    return '继续阅读';
  }

  // ── Mark page read on scroll to bottom ──────────────────────

  function setupScrollTracking() {
    var marked = false;
    function checkScroll() {
      if (marked) return;
      var scrollTop = window.pageYOffset || document.documentElement.scrollTop;
      var docHeight = document.documentElement.scrollHeight;
      var winHeight = window.innerHeight;
      // Mark as read when user scrolls past 70% of the page
      if (scrollTop + winHeight > docHeight * 0.7) {
        marked = true;
        markCurrentPageRead();
        // Update sidebar checkmarks and progress bar
        addReadCheckmarks();
        var scrollbox = document.querySelector('.sidebar .sidebar-scrollbox');
        if (scrollbox) {
          var oldBar = scrollbox.querySelector('.reading-progress-bar');
          if (oldBar) oldBar.remove();
          addProgressBar(scrollbox);
        }
      }
    }
    window.addEventListener('scroll', checkScroll, { passive: true });
    // Also check immediately in case the page is short
    setTimeout(checkScroll, 500);
  }

  // ── Init ────────────────────────────────────────────────────

  function init() {
    var scrollbox = document.querySelector('.sidebar .sidebar-scrollbox');
    if (scrollbox) {
      addHomeLink(scrollbox);
      addProgressBar(scrollbox);
      addReadCheckmarks();
    }
    addBottomNavCards();
    setupScrollTracking();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
