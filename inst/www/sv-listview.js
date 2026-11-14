/**
 * sv-listview.js - the text-first list view of sideview (global.SideviewListView).
 *
 * A normal-flow, scrolling column that stands in for the canvas for keyboard and screen-reader use.
 * The engine (sideview.js) creates it the first time the list view is shown (engine.setView('list'))
 * and calls its result hooks from the reply handlers. This file builds the shell: the Summary and the
 * h2 sections in order (Summary, Tables, Join, Merge SUPP, Transform, Pipeline, Code, Copilot).
 * The section bodies are filled by later tasks through the same render()/renderTable() entry points.
 *
 * Everything is built with DOM calls and textContent: a table, column or file name is never parsed
 * as HTML.
 */
(function (global) {
  'use strict';

  var SECTIONS = [
    { key: 'summary', title: 'Summary' },
    { key: 'tables', title: 'Tables' },
    { key: 'join', title: 'Join' },
    { key: 'supp', title: 'Merge SUPP' },
    { key: 'transform', title: 'Transform' },
    { key: 'pipeline', title: 'Pipeline' },
    { key: 'code', title: 'Code' },
    { key: 'copilot', title: 'Copilot', needsLlm: true }
  ];

  var SKIPS = [
    { key: 'tables', text: 'Skip to tables' },
    { key: 'join', text: 'Skip to join' },
    { key: 'code', text: 'Skip to code' }
  ];

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = String(text);
    return e;
  }

  function plural(n, one, many) { return n + ' ' + (n === 1 ? one : many); }

  function ListView(engine) {
    this.engine = engine;
    this.ns = typeof engine.ns === 'string' ? engine.ns : '';
    this.el = el('section', 'sideview-listview');
    this.el.setAttribute('role', 'region');
    this.el.setAttribute('aria-label', 'sideview list view');
    this.el.hidden = true;
    this._summaryText = null;
    this._destroyed = false;
    // The list sits inside the container, after the canvas, so it shares the toolbar and the drawer.
    engine.container.appendChild(this.el);
    this.render();
  }

  ListView.prototype.sectionId = function (key) { return this.ns + 'sv-lv-' + key; };

  /** The full render: the skip links, then one h2 section per key. */
  ListView.prototype.render = function () {
    if (this._destroyed) return;
    var self = this;
    var root = this.el;
    while (root.firstChild) root.removeChild(root.firstChild);
    var llm = this.engine.llmAvailable();
    SECTIONS.forEach(function (s) {
      if (s.needsLlm && !llm) return;
      var wrap = el('div', 'sideview-lv-section');
      wrap.id = self.sectionId(s.key);
      wrap.setAttribute('data-sv-lv-section', s.key);
      var h = el('h2', 'sideview-lv-heading', s.title);
      h.tabIndex = -1;
      wrap.appendChild(h);
      var body = el('div', 'sideview-lv-body');
      body.setAttribute('data-sv-lv-body', s.key);
      wrap.appendChild(body);
      root.appendChild(wrap);
      if (s.key === 'summary') self.buildSummary(body);
    });
  };

  ListView.prototype.buildSummary = function (body) {
    var self = this;
    var eng = this.engine;
    var skips = el('p', 'sideview-lv-skips');
    SKIPS.forEach(function (k) {
      var a = el('a', 'sideview-skip', k.text);
      a.setAttribute('href', '#' + self.sectionId(k.key));
      // keep the page URL as it is: move focus to the heading instead of following the hash
      a.addEventListener('click', function (e) {
        e.preventDefault();
        self.focusSection(k.key);
      });
      skips.appendChild(a);
    });
    body.appendChild(skips);
    this._summaryText = el('p', 'sideview-lv-summary-text');
    body.appendChild(this._summaryText);

    var bar = el('div', 'sideview-lv-actions');
    var toggle = el('button', 'sideview-btn sideview-lv-toggle');
    toggle.type = 'button';
    toggle.setAttribute('data-action', 'toggle-view');
    toggle.setAttribute('data-sv-view-toggle', '');
    toggle.setAttribute('aria-pressed', eng.view === 'list' ? 'true' : 'false');
    toggle.textContent = 'List view';
    bar.appendChild(toggle);
    [['save-workspace', 'Save workspace'], ['open-workspace', 'Open workspace']].forEach(function (a) {
      var b = el('button', 'sideview-btn', a[1]);
      b.type = 'button';
      b.setAttribute('data-action', a[0]);
      bar.appendChild(b);
    });
    var sw = el('button', 'sideview-shortcuts-switch');
    sw.type = 'button';
    sw.setAttribute('role', 'switch');
    sw.setAttribute('data-sv-shortcuts-switch', '');
    sw.setAttribute('aria-checked', eng.shortcutsOn() ? 'true' : 'false');
    var track = el('span', 'sideview-shortcuts-switch-track');
    track.setAttribute('aria-hidden', 'true');
    sw.appendChild(track);
    sw.appendChild(el('span', null, 'Keyboard shortcuts'));
    sw.addEventListener('click', function () { eng.setShortcuts(!eng.shortcutsOn()); });
    bar.appendChild(sw);
    body.appendChild(bar);
    this.renderSummary();
  };

  /** "<n> tables, <j> join steps, <s> pipeline steps. Code is ready." (or "No code yet."). */
  ListView.prototype.renderSummary = function () {
    if (this._destroyed || !this._summaryText) return;
    var eng = this.engine;
    var steps = eng.pipeline && eng.pipeline.steps ? eng.pipeline.steps : [];
    var joins = steps.filter(function (s) { return s.kind === 'join'; }).length;
    var text = plural(eng.cards ? eng.cards.size : 0, 'table', 'tables') + ', ' +
      plural(joins, 'join step', 'join steps') + ', ' +
      plural(steps.length, 'pipeline step', 'pipeline steps') + '. ' +
      (eng.noCode() ? 'No code yet.' : 'Code is ready.');
    if (this._summaryText.textContent !== text) this._summaryText.textContent = text;
  };

  /** Move focus to a section's heading (the skip links, and the sections' own jumps). */
  ListView.prototype.focusSection = function (key) {
    var wrap = this.el.querySelector('[data-sv-lv-section="' + key + '"]');
    var h = wrap && wrap.querySelector('h2');
    if (!h) return false;
    try { h.focus({ preventScroll: false }); } catch (e) { h.focus(); }
    return true;
  };

  // One table's section (filled by the Tables task); the shell has nothing to redraw yet.
  ListView.prototype.renderTable = function (name) { return name; };

  // Result hooks, called by the engine from its reply handlers; the section tasks fill them in.
  ListView.prototype.onJoinDiag = function (sig, d) { return [sig, d]; };
  ListView.prototype.onSuppCheck = function (d) { return d; };
  ListView.prototype.onColumnProfile = function (d) { return d; };

  ListView.prototype.destroy = function () {
    this._destroyed = true;
    this._summaryText = null;
    if (this.el && this.el.parentNode) this.el.parentNode.removeChild(this.el);
  };

  global.SideviewListView = ListView;

})(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this));
