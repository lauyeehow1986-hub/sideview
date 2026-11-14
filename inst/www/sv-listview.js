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

  function cssEscape(v) {
    return typeof CSS !== 'undefined' && CSS.escape ? CSS.escape(String(v)) : String(v).replace(/["\\]/g, '\\$&');
  }

  function plural(n, one, many) { return n + ' ' + (n === 1 ? one : many); }
  function fmt(n) { return Number(n).toLocaleString('en-US'); }

  var PAGE = 25;
  var KIND_WORDS = {
    numeric: 'number', integer: 'number', double: 'number', dbl: 'number', int: 'number', num: 'number',
    character: 'text', factor: 'text', string: 'text', chr: 'text', fct: 'text',
    logical: 'true or false', lgl: 'true or false',
    date: 'date', posixct: 'date-time', posixt: 'date-time', datetime: 'date-time', dttm: 'date-time'
  };
  function kindWord(type) {
    var t = String(type || '').toLowerCase();
    return KIND_WORDS[t] || (t || 'other');
  }

  function ListView(engine) {
    this.engine = engine;
    this.ns = typeof engine.ns === 'string' ? engine.ns : '';
    this.el = el('section', 'sideview-listview');
    this.el.setAttribute('role', 'region');
    this.el.setAttribute('aria-label', 'sideview list view');
    this.el.hidden = true;
    this._summaryText = null;
    this._destroyed = false;
    this.tables = new Map();      // card id -> per-table state (section, rows page, unsubscribe)
    this._inspectBoxes = {};      // profile id -> the box waiting for the reply
    // The list sits inside the container, after the canvas, so it shares the toolbar and the drawer.
    engine.container.appendChild(this.el);
    this.render();
  }

  ListView.prototype.sectionId = function (key) { return this.ns + 'sv-lv-' + key; };

  ListView.prototype.makeSection = function (s) {
    var wrap = el('div', 'sideview-lv-section');
    wrap.id = this.sectionId(s.key);
    wrap.setAttribute('data-sv-lv-section', s.key);
    var h = el('h2', 'sideview-lv-heading', s.title);
    h.tabIndex = -1;
    wrap.appendChild(h);
    var body = el('div', 'sideview-lv-body');
    body.setAttribute('data-sv-lv-body', s.key);
    wrap.appendChild(body);
    return wrap;
  };

  /** The full render: the skip links, then one h2 section per key. Resets every table's page. */
  ListView.prototype.render = function () {
    if (this._destroyed) return;
    var self = this;
    var root = this.el;
    this.releaseTables();
    // the drawer's panes live in the sections: give them back before the sections are wiped
    var eng = this.engine;
    var hadPanes = !!(eng._movedPanes && eng._movedPanes.length);
    if (hadPanes) eng.movePanes('drawer');
    while (root.firstChild) root.removeChild(root.firstChild);
    var llm = eng.llmAvailable();
    SECTIONS.forEach(function (s) {
      if (s.needsLlm && !llm) return;
      var wrap = self.makeSection(s);
      root.appendChild(wrap);
      if (s.key === 'summary') self.buildSummary(wrap.lastChild);
      else if (s.key === 'join') self.buildJoin(wrap.lastChild);
      else if (s.key === 'supp') self.buildSupp(wrap.lastChild);
      else if (s.key === 'transform') self.buildTransform(wrap.lastChild);
    });
    this.syncTables();
    if (hadPanes && eng.view === 'list') eng.movePanes('list');
  };

  // ---- transform, pipeline, code and copilot: the drawer's own pane nodes move in (movePanes) ----

  var BUILDERS = [
    ['filter', 'Filter'], ['arrange', 'Arrange'], ['mutate', 'Mutate'],
    ['recode', 'Recode'], ['summarise', 'Summarise']
  ];

  /** One wrapper per builder, each with an h3 the builder's pane is moved under. */
  ListView.prototype.buildTransform = function (body) {
    var self = this;
    BUILDERS.forEach(function (b) {
      var wrap = el('div', 'sideview-lv-builder');
      wrap.setAttribute('data-sv-lv-builder', b[0]);
      var h = el('h3', 'sideview-lv-subheading', b[1]);
      h.id = self.ns + 'sv-lv-b-' + b[0];
      h.tabIndex = -1;
      wrap.appendChild(h);
      body.appendChild(wrap);
    });
  };

  /** A section's body element (null when the section is not drawn, e.g. Copilot without an LLM). */
  ListView.prototype.bodyFor = function (key) {
    return this.el.querySelector('[data-sv-lv-body="' + key + '"]');
  };

  ListView.prototype.builderHost = function (kind) {
    return this.el.querySelector('[data-sv-lv-builder="' + cssEscape(kind) + '"]');
  };

  ListView.prototype.builderHeading = function (kind) {
    var host = this.builderHost(kind);
    return host ? host.querySelector('h3') : null;
  };

  /**
   * The narrow update: add or remove the Copilot section when the LLM comes or goes, bring the
   * tables up to date, and refresh the summary. Nothing else is rebuilt, so focus, scroll, the
   * rows page and an open Columns list stay as they are.
   */
  ListView.prototype.updateSections = function () {
    if (this._destroyed) return;
    var have = this.el.querySelector('[data-sv-lv-section="copilot"]');
    var want = this.engine.llmAvailable();
    if (want && !have) {
      this.el.appendChild(this.makeSection(SECTIONS[SECTIONS.length - 1]));
      if (this.engine.view === 'list') this.engine.movePanes('list');
    } else if (!want && have) {
      var active = document.activeElement;
      var held = active && have.contains(active);
      var chat = have.querySelector('[data-pane="chat"]');
      if (chat) this.engine.unmovePane(chat);
      have.parentNode.removeChild(have);
      if (held) this.focusSection('summary');
    }
    this.syncTables();
  };

  /** The list came on screen: sections follow the cards; rows follow the canvas order. */
  ListView.prototype.refresh = function () {
    if (this._destroyed) return;
    this.updateSections();
    var sw = this.el.querySelector('[data-sv-shortcuts-switch]');
    if (sw) sw.setAttribute('aria-checked', this.engine.shortcutsOn() ? 'true' : 'false');
    var self = this;
    this.tables.forEach(function (st) { self.refreshTable(st); });
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

  // ---- tables ----------------------------------------------------------------------

  ListView.prototype.tablesBody = function () {
    return this.el.querySelector('[data-sv-lv-body="tables"]');
  };

  ListView.prototype.releaseTables = function () {
    this.tables.forEach(function (st) { if (st.unsub) st.unsub(); });
    this.tables.clear();
    this._inspectBoxes = {};
  };

  /** One section per card, in card order; a card that came, went or was replaced is the only change. */
  ListView.prototype.syncTables = function () {
    if (this._destroyed) return;
    var body = this.tablesBody();
    if (!body) { this.renderSummary(); this.syncJoin(); this.syncSupp(); return; }
    var self = this;
    var seen = {};
    var index = 0;
    var prev = null;
    var lost = null; // focus was inside a section that goes away: where it was, so it can be handed on
    this.engine.cards.forEach(function (meta, id) {
      var vt = meta.element && meta.element._virtualTable ? meta.element._virtualTable : null;
      var st = self.tables.get(id);
      if (st && (st.vt !== vt || st.meta !== meta || st.name !== meta.name)) {
        if (st.section.contains(document.activeElement)) lost = { name: st.name, index: st.index };
        self.dropTable(id);
        st = null;
      }
      if (!st) st = self.buildTable(id, meta, vt);
      seen[id] = true;
      // keep the DOM order equal to the card order, moving only what is out of place
      var want = prev ? prev.nextSibling : body.firstChild;
      if (st.section !== want) body.insertBefore(st.section, want);
      st.heading.id = self.ns + 'sv-lv-t-' + index;
      st.index = index++;
      prev = st.section;
    });
    Array.from(this.tables.keys()).forEach(function (id) {
      if (seen[id]) return;
      var gone = self.tables.get(id);
      if (gone && gone.section.contains(document.activeElement)) lost = { name: gone.name, index: gone.index };
      self.dropTable(id);
    });
    if (lost) this.refocusAfterDrop(lost);
    var none = body.querySelector('.sideview-lv-no-tables');
    if (!this.engine.cards.size && !none) body.appendChild(el('p', 'sideview-lv-no-tables', 'No tables yet.'));
    else if (this.engine.cards.size && none) body.removeChild(none);
    this.renderSummary();
    this.syncJoin();
    this.syncSupp();
    this.engine.refreshBuilders();
  };

  /** A focused section was removed: focus its same-named replacement, else the nearest heading, never body. */
  ListView.prototype.refocusAfterDrop = function (lost) {
    var st = this.tableState(lost.name);
    var best = null;
    this.tables.forEach(function (t) {
      if (!best || Math.abs(t.index - lost.index) < Math.abs(best.index - lost.index)) best = t;
    });
    var target = (st || best) && (st || best).heading;
    if (target && target.isConnected) {
      try { target.focus(); } catch (e) { /* nothing to focus */ }
    } else this.focusSection('tables');
  };

  ListView.prototype.dropTable = function (id) {
    var st = this.tables.get(id);
    if (!st) return;
    if (st.unsub) st.unsub();
    if (st.section.parentNode) st.section.parentNode.removeChild(st.section);
    this.tables.delete(id);
  };

  ListView.prototype.tableState = function (name) {
    var found = null;
    this.tables.forEach(function (st) { if (st.name === name) found = st; });
    return found;
  };

  // One table's section; kept for the engine's per-table hook.
  ListView.prototype.renderTable = function (name) {
    var st = this.tableState(name);
    if (st) this.refreshTable(st);
  };

  function headingText(eng, st) {
    var meta = st.meta, card = meta.element, vt = st.vt;
    if (!vt) return meta.name + '.';
    var ds = (card && card.dataset) || {};
    var total = parseInt(ds.tableRows, 10);
    if (isNaN(total)) total = vt.totalRows;
    var domain = eng.cardDomain ? eng.cardDomain(meta.name) : null;
    var basis = 'full table';
    if (ds.rowsBasis === 'preview') {
      var shown = parseInt(ds.previewRows, 10);
      if (isNaN(shown)) shown = vt.totalRows;
      basis = 'preview of the first ' + fmt(shown) + ' rows';
    }
    return meta.name + ', ' + (domain ? domain + ' domain, ' : '') + fmt(total) + ' rows by ' +
      fmt(vt.colNames.length) + ' columns, ' + basis + '.';
  }

  ListView.prototype.buildTable = function (id, meta, vt) {
    var self = this;
    var eng = this.engine;
    var st = { id: id, meta: meta, vt: vt, name: meta.name, start: 0, sig: null, loading: false, unsub: null };
    var section = el('div', 'sideview-lv-table');
    section.setAttribute('data-sv-table', meta.name);
    section.setAttribute('data-card-id', String(id));
    st.section = section;
    st.heading = el('h3', 'sideview-lv-table-heading');
    st.heading.tabIndex = -1;
    section.appendChild(st.heading);
    this.tables.set(id, st);
    if (!vt) { st.heading.textContent = headingText(eng, st); return st; }

    st.colSpans = [];
    st.profileBoxes = {};
    var n = vt.colNames.length;
    var ul = el('ul', 'sideview-lv-cols');
    vt.colNames.forEach(function (colName, c) {
      var li = el('li', 'sideview-lv-col');
      var text = el('span', 'sideview-lv-col-text');
      st.colSpans.push(text);
      li.appendChild(text);
      var acts = el('div', 'sideview-lv-col-actions');
      [['Sort', 'sort'], ['Filter', 'filter'], ['Inspect', 'inspect']].forEach(function (a) {
        var b = el('button', 'sideview-btn', a[0]);
        b.type = 'button';
        b.setAttribute('data-sv-lv-action', a[1]);
        b.setAttribute('data-col-index', String(c));
        b.setAttribute('aria-label', a[0] + ' ' + colName);
        // the Filter builder arrives with engine.openBuilder: until then the button says it is inert
        if (a[1] === 'filter' && !eng.openBuilder) b.setAttribute('aria-disabled', 'true');
        b.addEventListener('click', function () { self.onColumnAction(st, a[1], c); });
        acts.appendChild(b);
      });
      li.appendChild(acts);
      var box = el('div', 'sideview-lv-profile');
      st.profileBoxes[c] = box;
      li.appendChild(box);
      ul.appendChild(li);
    });
    if (n > 30) {
      var det = el('details', 'sideview-lv-cols-details');
      det.appendChild(el('summary', null, 'Columns (' + n + ')'));
      det.appendChild(ul);
      section.appendChild(det);
    } else {
      section.appendChild(ul);
    }

    // the rows: a captioned table, the pager and the Go to row control
    var empty = el('p', 'sideview-lv-empty', 'No rows.');
    empty.hidden = true;
    var wrap = el('div', 'sideview-lv-rows-wrap');
    var table = el('table', 'sideview-lv-rows-table');
    table.appendChild(el('caption', 'sv-sr-only', meta.name + ' rows'));
    var thead = el('thead');
    var htr = el('tr');
    htr.setAttribute('aria-rowindex', '1');
    thead.appendChild(htr);
    table.appendChild(thead);
    var tbody = el('tbody');
    table.appendChild(tbody);
    wrap.appendChild(table);
    var pager = el('div', 'sideview-lv-pager');
    pager.setAttribute('role', 'group');
    pager.setAttribute('aria-label', meta.name + ' row paging');
    st.prev = el('button', 'sideview-btn', 'Previous rows');
    st.next = el('button', 'sideview-btn', 'Next rows');
    st.prev.type = st.next.type = 'button';
    st.status = el('span', 'sideview-lv-page-status');
    var lab = el('label', null, 'Go to row ');
    st.go = el('input');
    st.go.type = 'number';
    st.go.min = '1';
    lab.appendChild(st.go);
    var goBtn = el('button', 'sideview-btn', 'Go');
    goBtn.type = 'button';
    st.prev.addEventListener('click', function () { self.page(st, st.prev, st.start - PAGE); });
    st.next.addEventListener('click', function () { self.page(st, st.next, st.start + PAGE); });
    var go = function () {
      var v = parseInt(st.go.value, 10);
      if (isNaN(v)) return;
      self.page(st, goBtn, v - 1);
    };
    goBtn.addEventListener('click', go);
    st.go.addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); go(); } });
    [st.prev, st.next, st.status, lab, goBtn].forEach(function (x) { pager.appendChild(x); });
    st.parts = { empty: empty, wrap: wrap, table: table, htr: htr, tbody: tbody, pager: pager };
    section.appendChild(empty);
    section.appendChild(wrap);
    section.appendChild(pager);

    // a row block that lands later fills the cells that showed an ellipsis
    if (typeof vt.onBlock === 'function') {
      st.unsub = vt.onBlock(function () { if (!self._destroyed && st.loading) self.renderRows(st); });
    }
    this.refreshTable(st);
    return st;
  };

  /** Heading, column lines and rows follow the card; the page restarts if sort, filter or size changed. */
  ListView.prototype.refreshTable = function (st) {
    if (this._destroyed || !st.vt) return;
    var text = headingText(this.engine, st);
    if (st.heading.textContent !== text) st.heading.textContent = text;
    this.refreshColumns(st);
    var vt = st.vt;
    var sig = JSON.stringify([vt.getRowCount(), vt.sortState, vt.currentFilter]);
    if (sig !== st.sig) { st.start = 0; st.sig = sig; }
    this.renderRows(st);
  };

  /**
   * Counts read from a card's header badges. A card that only holds a preview of its table (lazy,
   * truncated, or data-rows-basis="preview") has badges computed from those rows, so they say nothing
   * here: Inspect gives the exact numbers. A title that does not match the expected text, and an
   * approximate ("~N distinct", a sampled column), give no count rather than a guess.
   */
  function sparkStats(card, c) {
    var out = { distinct: null, missing: null };
    if (!card || !card.querySelectorAll) return out;
    var ds = card.dataset || {};
    if (ds.lazy || ds.truncated || ds.rowsBasis === 'preview') return out;
    var th = card.querySelectorAll('thead th')[c];
    if (!th) return out;
    var na = th.querySelector('.sideview-na-badge');
    var cat = th.querySelector('.sideview-cat-profile');
    var spark = th.querySelector('.sideview-sparkline');
    var catTitle = cat ? (cat.getAttribute('title') || '') : '';
    if (na) {
      var m = /^(\d+) missing values \(/.exec(na.getAttribute('title') || '');
      if (m) out.missing = parseInt(m[1], 10);
    } else if (spark || (cat && /\| \d+ distinct$/.test(catTitle))) {
      out.missing = 0;
    }
    var d = /\| (\d+) distinct$/.exec(catTitle);
    if (d) out.distinct = parseInt(d[1], 10);
    return out;
  }

  ListView.prototype.columnText = function (st, c) {
    var vt = st.vt;
    var name = vt.colNames[c];
    var labels = st.meta.colLabels;
    var src = vt.sourceColNames ? vt.sourceColNames[c] : name;
    var label = labels && (labels[src] || labels[name]);
    var parts = [name];
    if (label) parts.push(String(label));
    parts.push(kindWord(vt.colTypes ? vt.colTypes[name] : ''));
    var stats = sparkStats(st.meta.element, c);
    if (stats.distinct !== null) parts.push(fmt(stats.distinct) + ' values');
    if (stats.missing !== null) parts.push(fmt(stats.missing) + ' missing');
    var th = st.meta.element && st.meta.element.querySelectorAll('thead th')[c];
    var ss = th && th.dataset ? th.dataset.sortState : null;
    if (ss === 'asc' || ss === 'desc') parts.push('sorted ' + (ss === 'asc' ? 'ascending' : 'descending'));
    return parts.join(', ');
  };

  ListView.prototype.refreshColumns = function (st) {
    var self = this;
    st.colSpans.forEach(function (span, c) {
      var t = self.columnText(st, c);
      if (span.textContent !== t) span.textContent = t;
    });
  };

  /** Show the rows of the current page; opts.announce says the new range (a page change). */
  ListView.prototype.renderRows = function (st, opts) {
    var vt = st.vt;
    var p = st.parts;
    var n = vt.getRowCount();
    if (!isFinite(n)) n = 0;
    p.empty.hidden = n > 0;
    p.wrap.hidden = p.pager.hidden = n === 0;
    if (n === 0) { st.loading = false; return; }
    if (st.start > n - 1) st.start = n - 1;
    if (st.start < 0) st.start = 0;
    var end = Math.min(n, st.start + PAGE);
    var cols = vt.colNames;
    p.table.setAttribute('aria-rowcount', String(n + 1));
    p.table.setAttribute('aria-colcount', String(cols.length));
    while (p.htr.firstChild) p.htr.removeChild(p.htr.firstChild);
    cols.forEach(function (c) {
      var th = el('th', null, c);
      th.setAttribute('scope', 'col');
      p.htr.appendChild(th);
    });
    var loading = false;
    var frag = document.createDocumentFragment();
    for (var i = st.start; i < end; i++) {
      var tr = el('tr');
      tr.setAttribute('aria-rowindex', String(i + 2));
      for (var c = 0; c < cols.length; c++) {
        var t = vt.cellText(i, c);
        if (t === null) { loading = true; t = '…'; }
        tr.appendChild(el('td', null, t));
      }
      frag.appendChild(tr);
    }
    while (p.tbody.firstChild) p.tbody.removeChild(p.tbody.firstChild);
    p.tbody.appendChild(frag);
    st.loading = loading;
    if (loading) p.table.setAttribute('aria-busy', 'true'); else p.table.removeAttribute('aria-busy');
    st.go.max = String(n);
    var range = 'Rows ' + fmt(st.start + 1) + ' to ' + fmt(end) + ' of ' + fmt(n) + '.';
    st.status.textContent = range;
    var active = document.activeElement;
    st.prev.disabled = st.start <= 0;
    st.next.disabled = end >= n;
    // a pressed button that just became disabled would drop focus: hand it to its neighbour
    if (active === st.prev && st.prev.disabled && !st.next.disabled) st.next.focus();
    else if (active === st.next && st.next.disabled && !st.prev.disabled) st.prev.focus();
    if (opts && opts.announce) this.engine.announce(range);
  };

  /** Start the page at row index `start` and say where it is; focus stays on the pressed control. */
  ListView.prototype.page = function (st, control, start) {
    var n = st.vt.getRowCount();
    if (start > n - 1) start = n - 1;
    if (start < 0) start = 0;
    st.start = start;
    this.renderRows(st, { announce: true });
    if (control && document.activeElement !== control && !control.disabled) control.focus();
  };

  ListView.prototype.onColumnAction = function (st, action, c) {
    var eng = this.engine;
    var vt = st.vt;
    var colName = vt.colNames[c];
    if (action === 'sort') {
      var card = st.meta.element;
      var th = card.querySelectorAll('thead th')[c];
      var btn = th && th.querySelector('.sideview-sort-btn');
      if (!btn) return;
      eng.sortColumn(card, colName, c, btn);
      var state = th.dataset.sortState;
      eng.announce(state === 'asc' ? 'Sorted ' + st.name + ' by ' + colName + ' ascending.' :
        state === 'desc' ? 'Sorted ' + st.name + ' by ' + colName + ' descending.' : 'Sort removed.');
      st.start = 0;
      st.sig = JSON.stringify([vt.getRowCount(), vt.sortState, vt.currentFilter]);
      this.refreshColumns(st);
      this.renderRows(st);
    } else if (action === 'filter') {
      if (eng.openBuilder) eng.openBuilder('filter', { table: st.name, column: colName });
    } else if (action === 'inspect') {
      var sig = JSON.stringify([st.name, colName]);
      this._inspectBoxes[sig] = { box: st.profileBoxes[c], column: colName };
      var prof = eng.columnProfileFor(st.name, colName);
      if (prof) this.writeProfile(sig, prof);
    }
  };

  ListView.prototype.writeProfile = function (sig, data) {
    var target = this._inspectBoxes[sig];
    if (!target) return;
    delete this._inspectBoxes[sig];
    var box = target.box;
    while (box.firstChild) box.removeChild(box.firstChild);
    var sentences = data.error ? [String(data.error)] : global.SideviewPipeline.sayProfile(data, target.column);
    sentences.forEach(function (t) { box.appendChild(el('p', null, t)); });
    if (sentences.length) this.engine.announce(sentences[0]);
  };

  // Result hook, called by the engine from its reply handler.
  ListView.prototype.onColumnProfile = function (d) {
    if (this._destroyed || !d || !d.id) return;
    this.writeProfile(d.id, d);
  };

  // ---- join ------------------------------------------------------------------------

  var RULE_CHOICES = [
    ['none', 'No rule'], ['between', 'Between'], ['window', 'Window'],
    ['before', 'Nearest before'], ['after', 'Nearest after'], ['overlaps', 'Overlaps']
  ];
  var SLOT_WORDS = { xCol: 'date', yCol: 'date', xFrom: 'start', xTo: 'end', yFrom: 'start', yTo: 'end' };
  var CDISC_KINDS = { trace: 'ADaM to SDTM trace', subject: 'subject key', visit: 'visit key' };

  /** A labelled control: the label's visible text is the control's accessible name. */
  function field(text, control) {
    var lab = el('label', 'sideview-lv-field');
    lab.appendChild(el('span', 'sideview-lv-field-name', text));
    lab.appendChild(control);
    return lab;
  }

  function button(text, action) {
    var b = el('button', 'sideview-btn', text);
    b.type = 'button';
    b.setAttribute('data-sv-lv-action', action);
    return b;
  }

  function makeSelect(name, id) {
    var sel = el('select', 'sideview-lv-select');
    sel.setAttribute('data-sv-field', id);
    sel.setAttribute('aria-label', name);
    return sel;
  }

  /** Set a select's options; nothing is touched while the list is the same, so a pick and focus stay. */
  function fillSelect(sel, values, placeholder) {
    var sig = JSON.stringify([placeholder || null, values]);
    if (sel._svSig === sig) return false;
    var keep = sel.value;
    while (sel.firstChild) sel.removeChild(sel.firstChild);
    if (placeholder) {
      var o0 = document.createElement('option');
      o0.value = '';
      o0.textContent = placeholder;
      sel.appendChild(o0);
    }
    values.forEach(function (v) {
      var o = document.createElement('option');
      o.value = v;
      o.textContent = v;
      sel.appendChild(o);
    });
    sel._svSig = sig;
    if (values.indexOf(keep) >= 0) sel.value = keep; else sel.selectedIndex = 0;
    return true;
  }

  ListView.prototype.cardNames = function () {
    var out = [];
    this.engine.cards.forEach(function (m) { out.push(m.name); });
    return out;
  };

  ListView.prototype.colsOf = function (name) {
    return (name && this.engine.cardColNames(name)) || [];
  };

  ListView.prototype.buildJoin = function (body) {
    var self = this;
    var P = global.SideviewPipeline;
    var j = this.join = { pairs: [], resultSig: null, resultOk: false };

    // suggestions (Auto Map)
    var sug = el('div', 'sideview-lv-suggest');
    j.suggestBtn = button('Suggest joins', 'suggest-joins');
    j.suggestStatus = el('p', 'sideview-lv-suggest-status');
    j.suggestList = el('ul', 'sideview-lv-suggestions');
    j.suggestList.setAttribute('data-sv-suggestions', '');
    j.suggestBtn.addEventListener('click', function () { self.onSuggest(); });
    sug.appendChild(j.suggestBtn);
    sug.appendChild(j.suggestStatus);
    sug.appendChild(j.suggestList);
    body.appendChild(sug);

    // the form
    var form = el('div', 'sideview-lv-joinform');
    form.setAttribute('role', 'group');
    form.setAttribute('aria-label', 'Join two tables');
    j.form = form;
    j.left = makeSelect('Left table', 'left-table');
    j.right = makeSelect('Right table', 'right-table');
    var tabs = el('div', 'sideview-lv-row');
    tabs.appendChild(field('Left table', j.left));
    tabs.appendChild(field('Right table', j.right));
    form.appendChild(tabs);
    j.pairsBox = el('div', 'sideview-lv-pairs');
    form.appendChild(j.pairsBox);
    j.addPair = button('Add another key pair', 'add-pair');
    j.addPair.addEventListener('click', function () {
      var row = self.addPairRow();
      self.syncJoin();
      var f = row.querySelector('select');
      if (f) f.focus();
    });
    form.appendChild(j.addPair);
    j.type = makeSelect('Join type', 'join-type');
    (P.JOIN_TYPES || []).forEach(function (t) {
      var o = document.createElement('option');
      o.value = t;
      o.textContent = t;
      j.type.appendChild(o);
    });
    j.shape = makeSelect('Date rule', 'rule-shape');
    RULE_CHOICES.forEach(function (c) {
      if (c[0] !== 'none' && (P.RULE_SHAPES || []).indexOf(c[0]) < 0) return;
      var o = document.createElement('option');
      o.value = c[0];
      o.textContent = c[1];
      j.shape.appendChild(o);
    });
    var opts = el('div', 'sideview-lv-row');
    opts.appendChild(field('Join type', j.type));
    opts.appendChild(field('Date rule', j.shape));
    form.appendChild(opts);
    j.ruleBox = el('div', 'sideview-lv-rulebox');
    form.appendChild(j.ruleBox);
    var acts = el('div', 'sideview-lv-actions');
    j.check = button('Check join', 'check-join');
    j.add = button('Add join step', 'add-join');
    j.add.disabled = true;
    acts.appendChild(j.check);
    acts.appendChild(j.add);
    form.appendChild(acts);
    j.result = el('div', 'sideview-lv-join-result');
    j.result.setAttribute('data-sv-join-result', '');
    form.appendChild(j.result);
    body.appendChild(form);

    // one listener each, on the form: a redraw of the pieces never adds another
    j.check.addEventListener('click', function () { self.onJoinCheck(); });
    j.add.addEventListener('click', function () { self.onJoinAdd(); });
    form.addEventListener('change', function (e) { self.onJoinChange(e); });
    form.addEventListener('input', function () { self.onJoinForm(); });
    this.addPairRow();
    this.syncJoin();
  };

  /** One key pair: a group of two selects and a Remove button. */
  ListView.prototype.addPairRow = function () {
    var self = this;
    var j = this.join;
    var row = el('div', 'sideview-lv-pair');
    row.setAttribute('role', 'group');
    var pair = { left: makeSelect('Left column', 'left-column'), right: makeSelect('Right column', 'right-column') };
    row.pair = pair;
    row.appendChild(field('Left column', pair.left));
    row.appendChild(field('Right column', pair.right));
    pair.remove = button('Remove key pair', 'remove-pair');
    pair.remove.addEventListener('click', function () {
      var at = j.pairs.indexOf(row);
      if (j.pairs.length < 2 || at < 0) return;
      j.pairs.splice(at, 1);
      row.parentNode.removeChild(row);
      self.numberPairs();
      self.onJoinForm();
      var next = j.pairs[Math.min(at, j.pairs.length - 1)].pair.remove;
      (next.disabled ? j.addPair : next).focus();
    });
    row.appendChild(pair.remove);
    j.pairs.push(row);
    j.pairsBox.appendChild(row);
    this.numberPairs();
    return row;
  };

  ListView.prototype.numberPairs = function () {
    var j = this.join;
    j.pairs.forEach(function (row, i) {
      row.setAttribute('aria-label', 'Key pair ' + (i + 1));
      row.pair.remove.setAttribute('aria-label', 'Remove key pair ' + (i + 1));
      row.pair.remove.disabled = j.pairs.length < 2;
    });
  };

  /** Follow the cards: table choices, column choices and the rule slots; unchanged lists stay as they are. */
  ListView.prototype.syncJoin = function () {
    var j = this.join;
    if (!j || this._destroyed || !this.el.contains(j.form)) return;
    var self = this;
    var names = this.cardNames();
    fillSelect(j.left, names, 'Pick a table');
    fillSelect(j.right, names, 'Pick a table');
    var lc = this.colsOf(j.left.value), rc = this.colsOf(j.right.value);
    j.pairs.forEach(function (row) {
      fillSelect(row.pair.left, lc, 'Pick a column');
      fillSelect(row.pair.right, rc, 'Pick a column');
    });
    var ruleKey = JSON.stringify([j.shape.value, j.left.value, j.right.value]);
    if (j.ruleKey !== ruleKey) {
      j.ruleKey = ruleKey;
      this.renderRule();
    } else {
      j.ruleBox.querySelectorAll('select[data-slot]').forEach(function (sel) {
        fillSelect(sel, self.colsOf(sel.getAttribute('data-side') === 'x' ? j.left.value : j.right.value), 'Pick a column');
      });
    }
    this.onJoinForm();
  };

  /** The slot controls of the chosen date rule; the picks that still fit are kept. */
  ListView.prototype.renderRule = function () {
    var self = this;
    var j = this.join;
    var P = global.SideviewPipeline;
    var old = {};
    j.ruleBox.querySelectorAll('[data-slot]').forEach(function (c) {
      old[c.getAttribute('data-slot')] = c.type === 'checkbox' ? c.checked : c.value;
    });
    while (j.ruleBox.firstChild) j.ruleBox.removeChild(j.ruleBox.firstChild);
    var shape = j.shape.value;
    if (shape === 'none') return;
    P.ruleSlots(shape).forEach(function (sl) {
      var tname = sl.side === 'x' ? j.left.value : j.right.value;
      var label = (tname || (sl.side === 'x' ? 'Left table' : 'Right table')) + ' ' + SLOT_WORDS[sl.slot];
      var sel = makeSelect(label, 'rule-' + sl.slot);
      sel.setAttribute('data-slot', sl.slot);
      sel.setAttribute('data-side', sl.side);
      fillSelect(sel, self.colsOf(tname), 'Pick a column');
      if (old[sl.slot]) sel.value = old[sl.slot];
      j.ruleBox.appendChild(field(label, sel));
    });
    if (shape === 'window') {
      [['from', 'Window start', -7], ['to', 'Window end', 7]].forEach(function (w) {
        var inp = el('input');
        inp.type = 'number';
        inp.step = '1';
        inp.setAttribute('data-slot', w[0]);
        inp.setAttribute('aria-label', w[1]);
        inp.value = old[w[0]] !== undefined && old[w[0]] !== '' ? old[w[0]] : String(w[2]);
        j.ruleBox.appendChild(field(w[1], inp));
      });
    }
    if (shape === 'before' || shape === 'after') {
      var cb = el('input');
      cb.type = 'checkbox';
      cb.setAttribute('data-slot', 'inclusive');
      cb.checked = old.inclusive === undefined ? true : !!old.inclusive;
      var lab = el('label', 'sideview-lv-check');
      lab.appendChild(cb);
      lab.appendChild(el('span', null, 'Same day counts'));
      j.ruleBox.appendChild(lab);
    }
  };

  /** The form as a step-like object ({table, right, by, type, rule}); rule keys follow the pipeline's own. */
  ListView.prototype.readJoin = function () {
    var j = this.join;
    var P = global.SideviewPipeline;
    var by = j.pairs.map(function (row) { return { left: row.pair.left.value, right: row.pair.right.value }; });
    var rule = null;
    var shape = j.shape.value;
    if (shape !== 'none') {
      rule = { shape: shape };
      var get = function (slot) { return j.ruleBox.querySelector('[data-slot="' + slot + '"]'); };
      P.ruleSlots(shape).forEach(function (sl) { var c = get(sl.slot); rule[sl.slot] = c ? c.value : ''; });
      if (shape === 'window') {
        ['from', 'to'].forEach(function (k) {
          var c = get(k);
          var t = c ? c.value.trim() : '';
          rule[k] = /^[-+]?\d+$/.test(t) ? parseInt(t, 10) : t;
        });
      }
      if (shape === 'before' || shape === 'after') {
        var ic = get('inclusive');
        rule.inclusive = ic ? ic.checked : true;
      }
    }
    return { table: j.left.value, right: j.right.value, by: by, type: j.type.value, rule: rule };
  };

  function joinComplete(f) {
    return !!f.table && !!f.right && f.by.length > 0 && f.by.every(function (p) { return !!p.left && !!p.right; });
  }

  /** The signature of the form as it is now, or null while it is incomplete. */
  ListView.prototype.joinFormSig = function () {
    var f = this.readJoin();
    return joinComplete(f) ? this.engine.joinDiagSig(f) : null;
  };

  /** A change to a table or the rule shape redraws what depends on it. */
  ListView.prototype.onJoinChange = function (e) {
    var t = e && e.target;
    var j = this.join;
    if (t && (t === j.left || t === j.right || t === j.shape)) this.syncJoin();
    else this.onJoinForm();
  };

  /** The form moved: a result for another signature no longer stands, and Add waits for a new check. */
  ListView.prototype.onJoinForm = function () {
    var j = this.join;
    if (!j) return;
    var sig = this.joinFormSig();
    if (j.resultSig !== null && j.resultSig !== sig) {
      j.resultSig = null;
      while (j.result.firstChild) j.result.removeChild(j.result.firstChild);
    }
    j.add.disabled = !(sig !== null && j.resultSig === sig && j.resultOk);
  };

  ListView.prototype.writeJoinResult = function (sentences) {
    var j = this.join;
    while (j.result.firstChild) j.result.removeChild(j.result.firstChild);
    sentences.forEach(function (t) { j.result.appendChild(el('p', null, t)); });
  };

  ListView.prototype.onJoinCheck = function () {
    var j = this.join;
    var f = this.readJoin();
    j.resultSig = null;
    j.resultOk = false;
    j.add.disabled = true;
    if (!joinComplete(f)) {
      var msg = 'Pick a left table, a right table and a column on each side first.';
      this.writeJoinResult([msg]);
      this.engine.announce(msg);
      return;
    }
    var sig = this.engine.joinDiagSig(f);
    this.writeJoinResult(['Checking the join.']);
    var d = this.engine.joinDiagFor(f);
    // a cached or local answer comes back now; R's reply arrives through onJoinDiag
    if (d) this.onJoinDiag(sig, d);
  };

  /** The engine's reply to a join check: written to the Join section if the form still has that signature. */
  ListView.prototype.onJoinDiag = function (sig, d) {
    var j = this.join;
    if (this._destroyed || !j || !d || !this.el.contains(j.form)) return;
    if (this.joinFormSig() !== sig) return;
    var f = this.readJoin();
    var sentences = global.SideviewPipeline.sayJoin(d, f.table, f.right);
    this.writeJoinResult(sentences);
    j.resultSig = sig;
    j.resultOk = !d.error;
    j.add.disabled = !!d.error;
    if (this.engine.view === 'list' && sentences.length) {
      this.engine.announce(sentences[0], { assertive: !!d.error });
    }
  };

  ListView.prototype.cardIdOf = function (name) {
    var meta = this.engine.cardMetaByName(name);
    return meta ? meta.id : name;
  };

  /** Connection objects for key pairs of one table to another, with the canvas ports when they are there. */
  ListView.prototype.connectionsFor = function (from, to, pairs, type) {
    var eng = this.engine;
    var self = this;
    return pairs.map(function (p) {
      return {
        fromCard: self.cardIdOf(from), fromTable: from, fromCol: p.left,
        fromElement: eng.findPortElement(from, p.left),
        toCard: self.cardIdOf(to), toTable: to, toCol: p.right,
        toElement: eng.findPortElement(to, p.right),
        type: type || 'left_join'
      };
    });
  };

  ListView.prototype.joinStepFor = function (a, b) {
    var steps = this.engine.pipeline.steps.filter(function (s) { return s.kind === 'join'; });
    // the forward step wins, as in Pipeline.addJoinKeys
    return steps.filter(function (s) { return s.table === a && s.right === b; })[0] ||
      steps.filter(function (s) { return s.table === b && s.right === a; })[0] || null;
  };

  /** Focus a pipeline step's item; the Pipeline heading when the item is not on screen. */
  ListView.prototype.focusPipelineItem = function (stepId) {
    var li = this.engine.container.querySelector('.sideview-step[data-step-id="' + cssEscape(stepId) + '"]');
    if (li) {
      if (!li.hasAttribute('tabindex')) li.tabIndex = -1;
      try { li.focus({ preventScroll: false }); } catch (e) { li.focus(); }
      if (document.activeElement === li) return true;
    }
    return this.focusSection('pipeline');
  };

  ListView.prototype.onJoinAdd = function () {
    var j = this.join;
    var eng = this.engine;
    if (j.add.disabled) return;
    var f = this.readJoin();
    if (!joinComplete(f) || eng.joinDiagSig(f) !== j.resultSig) { j.add.disabled = true; return; }
    eng.addConnections(this.connectionsFor(f.table, f.right, f.by, f.type));
    var step = this.joinStepFor(f.table, f.right);
    if (step && f.rule) eng.pipeline.setJoinRule(step.id, f.rule);
    j.add.disabled = true;
    if (step) this.focusPipelineItem(step.id);
  };

  // ---- suggested joins -------------------------------------------------------------

  ListView.prototype.onSuggest = function () {
    var j = this.join;
    if (!this.engine.hasR()) {
      j.suggestStatus.textContent = 'Suggested joins need the R session.';
      this.engine.announce(j.suggestStatus.textContent);
      return;
    }
    j.suggestStatus.textContent = 'Looking for joins.';
    this.engine.requestSuggestedMappings();
  };

  function candidateParts(c) {
    return {
      ft: c.from_table || c.fromTable || c.table1, fc: c.from_col || c.fromCol || c.col1,
      tt: c.to_table || c.toTable || c.table2, tc: c.to_col || c.toCol || c.col2
    };
  }

  ListView.prototype.alreadyConnected = function (ft, fc, tt, tc) {
    return (this.engine.connections || []).some(function (c) {
      return (c.fromTable === ft && c.fromCol === fc && c.toTable === tt && c.toCol === tc) ||
        (c.fromTable === tt && c.fromCol === tc && c.toTable === ft && c.toCol === fc);
    });
  };

  /** The suggestions reply: one list item for each pair, and one for each CDISC key set. */
  ListView.prototype.onSuggested = function (data) {
    var j = this.join;
    if (this._destroyed || !j) return;
    var self = this;
    var cands = Array.isArray(data) ? data : data && Array.isArray(data.candidates) ? data.candidates :
      data && Array.isArray(data.data) ? data.data : [];
    var groups = {}, order = [], items = [];
    cands.forEach(function (c) {
      if (!c) return;
      if (c.group) {
        if (!groups[c.group]) { groups[c.group] = []; order.push(c.group); }
        groups[c.group].push(c);
        return;
      }
      var p = candidateParts(c);
      if (!p.ft || !p.fc || !p.tt || !p.tc || self.alreadyConnected(p.ft, p.fc, p.tt, p.tc)) return;
      var conf = c.confidence !== undefined ? c.confidence : 0.8;
      items.push({
        label: p.ft + '.' + p.fc + ' to ' + p.tt + '.' + p.tc + ', confidence ' + Math.round(conf * 100) + '%',
        add: function () { return self.addSuggestedPair(p); },
        match: function (s) {
          return !s.group && s.fromTable === p.ft && s.fromCol === p.fc && s.toTable === p.tt && s.toCol === p.tc;
        }
      });
    });
    order.forEach(function (g) {
      var it = self.groupItem(g, groups[g]);
      if (it) items.push(it);
    });
    while (j.suggestList.firstChild) j.suggestList.removeChild(j.suggestList.firstChild);
    items.forEach(function (it) {
      var li = el('li', 'sideview-lv-suggestion');
      li.appendChild(el('span', 'sideview-lv-suggestion-text', it.label));
      var b = button('Add', 'add-suggestion');
      b.setAttribute('aria-label', 'Add ' + it.label);
      b.addEventListener('click', function () { self.acceptSuggestion(li, it); });
      li.appendChild(b);
      j.suggestList.appendChild(li);
    });
    j.suggestStatus.textContent = items.length ?
      plural(items.length, 'suggested join.', 'suggested joins.') : 'No suggested joins found.';
    if (this.engine.view === 'list') this.engine.announce(j.suggestStatus.textContent);
  };

  /** A CDISC key set (or a SUPP merge) as one list item. */
  ListView.prototype.groupItem = function (groupId, rows) {
    var self = this;
    var pairs = [];
    rows.forEach(function (c) {
      var p = candidateParts(c);
      if (p.ft && p.fc && p.tt && p.tc) pairs.push(p);
    });
    if (!pairs.length) return null;
    var from = pairs[0].ft, to = pairs[0].tt;
    pairs = pairs.filter(function (p) { return p.ft === from && p.tt === to; });
    var kind = rows[0].kind || null;
    var isSupp = kind === 'supp';
    if (!isSupp) {
      pairs = pairs.filter(function (p) { return !self.alreadyConnected(p.ft, p.fc, p.tt, p.tc); });
      if (!pairs.length) return null;
    }
    var cols = pairs.map(function (p) { return p.fc === p.tc ? p.fc : p.fc + ' = ' + p.tc; }).join(', ');
    var label = isSupp ? 'merge ' + from + ' into ' + to + ', one column per QNAM' :
      from + ' to ' + to + ' by ' + cols + (kind && CDISC_KINDS[kind] ? ', ' + CDISC_KINDS[kind] : '') +
      ', confidence 100%';
    return {
      label: label,
      add: function () { return self.addSuggestedGroup(from, to, pairs, isSupp); },
      match: function (s) { return s.group === groupId; }
    };
  };

  ListView.prototype.addSuggestedPair = function (p) {
    this.engine.addConnections(this.connectionsFor(p.ft, p.tt, [{ left: p.fc, right: p.tc }], 'left_join'));
    return 'Added join ' + p.ft + '.' + p.fc + ' to ' + p.tt + '.' + p.tc + '.';
  };

  ListView.prototype.addSuggestedGroup = function (from, to, pairs, isSupp) {
    var eng = this.engine;
    if (isSupp) {
      eng.requestSuppCheck(to, from, null, { mode: 'add', rdomain: eng.suppRdomain(from, to), list: true });
      return 'Checking the merge of ' + from + ' into ' + to + '.';
    }
    var by = pairs.map(function (p) { return { left: p.fc, right: p.tc }; });
    // an existing join in the opposite direction decides: the new keys follow it
    var opposite = (eng.connections || []).some(function (c) { return c.fromTable === to && c.toTable === from; }) ||
      eng.pipeline.steps.some(function (s) { return s.kind === 'join' && s.table === to && s.right === from; });
    if (opposite) {
      var t = from; from = to; to = t;
      by = by.map(function (p) { return { left: p.right, right: p.left }; });
    }
    eng.addConnections(this.connectionsFor(from, to, by, 'left_join'));
    return 'Added join ' + from + ' to ' + to + ' by ' + by.map(function (p) {
      return p.left === p.right ? p.left : p.left + ' = ' + p.right;
    }).join(', ') + '.';
  };

  ListView.prototype.acceptSuggestion = function (li, it) {
    var j = this.join;
    var eng = this.engine;
    var sentence = it.add();
    // the canvas drew a dashed path for it: an accepted pair must not leave its twin behind
    var keep = [];
    (eng.suggestedConnections || []).forEach(function (s) {
      if (it.match(s)) { if (s.path && s.path.parentNode) s.path.parentNode.removeChild(s.path); } else keep.push(s);
    });
    eng.suggestedConnections = keep;
    eng.updateConnectors();
    var next = li.nextElementSibling || li.previousElementSibling;
    var held = li.contains(document.activeElement);
    if (li.parentNode) li.parentNode.removeChild(li);
    var left = j.suggestList.children.length;
    j.suggestStatus.textContent = left ? plural(left, 'suggested join.', 'suggested joins.') : 'No more suggested joins.';
    if (held) (next ? next.querySelector('button') : j.suggestBtn).focus();
    eng.announce(sentence);
  };

  // ---- merge SUPP -------------------------------------------------------------------

  ListView.prototype.suppBody = function () { return this.el.querySelector('[data-sv-lv-body="supp"]'); };

  ListView.prototype.buildSupp = function (body) {
    this.supp = new Map();
    this._suppNone = el('p', 'sideview-lv-supp-none', 'No SUPP tables on the canvas.');
    body.appendChild(this._suppNone);
  };

  /** One section per SUPP-tagged card. A section is rebuilt only when its card, parents or data changed. */
  ListView.prototype.syncSupp = function () {
    var body = this.suppBody();
    if (this._destroyed || !body || !this.supp) return;
    var self = this;
    var eng = this.engine;
    var seen = {};
    var prev = this._suppNone;
    eng.cards.forEach(function (meta, id) {
      if (!eng.suppIsTag(meta.cdisc)) return;
      var info = eng.suppTargets(meta);
      var vt = meta.element && meta.element._virtualTable ? meta.element._virtualTable : null;
      var sig = JSON.stringify([meta.name, info.rdomain, info.missing,
        info.targets.map(function (t) { return [t.name, t.rdomain, t.reason]; })]);
      var st = self.supp.get(id);
      if (st && (st.sig !== sig || st.vt !== vt)) { self.dropSupp(id); st = null; }
      if (!st) st = self.buildSuppSection(id, meta, info, vt, sig);
      seen[id] = true;
      if (st.section.previousSibling !== prev) body.insertBefore(st.section, prev.nextSibling);
      prev = st.section;
    });
    Array.from(this.supp.keys()).forEach(function (id) { if (!seen[id]) self.dropSupp(id); });
    this._suppNone.hidden = this.supp.size > 0;
  };

  ListView.prototype.dropSupp = function (id) {
    var st = this.supp.get(id);
    if (!st) return;
    var held = st.section.contains(document.activeElement);
    if (st.section.parentNode) st.section.parentNode.removeChild(st.section);
    this.supp.delete(id);
    if (held) this.focusSection('supp');
  };

  /** The distinct QNAMs of a SUPP card, or null when the card has no QNAM column to read. */
  ListView.prototype.qnamCount = function (name) {
    var x = this.engine.cardColumns(name, ['QNAM']);
    if (x.error || !x.cols || !x.cols.QNAM) return null;
    var seen = {}, n = 0;
    x.cols.QNAM.forEach(function (v) {
      if (v === null || v === undefined || String(v) === '') return;
      var k = String(v);
      if (!Object.prototype.hasOwnProperty.call(seen, k)) { seen[k] = 1; n++; }
    });
    return n;
  };

  ListView.prototype.buildSuppSection = function (id, meta, info, vt, sig) {
    var self = this;
    var eng = this.engine;
    var section = el('div', 'sideview-lv-supp');
    section.setAttribute('data-sv-supp', meta.name);
    var st = { id: id, meta: meta, vt: vt, sig: sig, section: section, keys: {}, result: null, parentSel: null };
    this.supp.set(id, st);
    this.suppBody().appendChild(section);
    var usable = info.targets.filter(function (t) { return !t.reason; });
    var h = el('h3', 'sideview-lv-supp-heading');
    h.tabIndex = -1;
    section.appendChild(h);
    if (!info.targets.length) {
      h.textContent = meta.name + ': parent ' + info.rdomain + ' is not on the canvas.';
      return st;
    }
    if (!usable.length) {
      h.textContent = meta.name + ': ' + info.targets[0].reason + '.';
      return st;
    }
    usable.forEach(function (t) { st.keys[JSON.stringify(['supp', t.name, meta.name])] = t; });
    var n = this.qnamCount(meta.name);
    var current = function () {
      var name = st.parentSel ? st.parentSel.value : usable[0].name;
      return usable.filter(function (t) { return t.name === name; })[0] || usable[0];
    };
    var title = function () {
      h.textContent = meta.name + ' into ' + current().name + (n === null ? '' : ', ' + plural(n, 'QNAM', 'QNAMs'));
    };
    if (usable.length > 1) {
      st.parentSel = makeSelect('Parent for ' + meta.name, 'supp-parent');
      fillSelect(st.parentSel, usable.map(function (t) { return t.name; }));
      st.parentSel.addEventListener('change', function () { title(); self.clearSuppResult(st); });
      section.appendChild(field('Parent for ' + meta.name, st.parentSel));
    }
    title();
    var acts = el('div', 'sideview-lv-actions');
    var chk = button('Check', 'supp-check');
    var mrg = button('Merge', 'supp-merge');
    chk.setAttribute('aria-label', 'Check ' + meta.name);
    mrg.setAttribute('aria-label', 'Merge ' + meta.name);
    acts.appendChild(chk);
    acts.appendChild(mrg);
    section.appendChild(acts);
    st.result = el('div', 'sideview-lv-supp-result');
    st.result.setAttribute('data-sv-supp-result', '');
    section.appendChild(st.result);
    chk.addEventListener('click', function () {
      var t = current();
      // an existing step is checked with its own plan, so a drift shows as "needs refreshing"
      var step = eng.pipeline.steps.filter(function (s) {
        return s.kind === 'supp' && s.table === t.name && s.supp === meta.name && s.enabled !== false;
      })[0] || null;
      eng.requestSuppCheck(t.name, meta.name, step, { mode: step ? 'check' : 'peek', rdomain: t.rdomain, list: true });
    });
    mrg.addEventListener('click', function () {
      var t = current();
      eng.requestSuppCheck(t.name, meta.name, null, { mode: 'add', rdomain: t.rdomain, list: true });
    });
    return st;
  };

  ListView.prototype.clearSuppResult = function (st) {
    if (!st.result) return;
    while (st.result.firstChild) st.result.removeChild(st.result.firstChild);
  };

  /** The engine's merge-check reply: written to the section of that SUPP card, wherever focus is. */
  ListView.prototype.onSuppCheck = function (d, key, fromList) {
    if (this._destroyed || !d || !this.supp) return;
    var found = null;
    this.supp.forEach(function (st) { if (st.keys[key]) found = st; });
    if (!found || !found.result) return;
    var parts;
    try { parts = JSON.parse(key); } catch (e) { return; }
    var sentences = global.SideviewPipeline.saySupp(d, parts[1], parts[2]);
    this.clearSuppResult(found);
    sentences.forEach(function (t) { found.result.appendChild(el('p', null, t)); });
    if (fromList) {
      var stale = !!(d.drift && d.drift.stale === true);
      this.engine.announce(stale ? 'Merge needs refreshing.' : sentences[0], { assertive: !!d.error });
    }
  };

  ListView.prototype.destroy = function () {
    try { if (this.engine.movePanes) this.engine.movePanes('drawer'); } catch (e) {}
    this._destroyed = true;
    this._summaryText = null;
    this.releaseTables();
    if (this.el && this.el.parentNode) this.el.parentNode.removeChild(this.el);
  };

  global.SideviewListView = ListView;

})(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this));
