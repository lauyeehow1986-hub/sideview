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
    while (root.firstChild) root.removeChild(root.firstChild);
    var llm = this.engine.llmAvailable();
    SECTIONS.forEach(function (s) {
      if (s.needsLlm && !llm) return;
      var wrap = self.makeSection(s);
      root.appendChild(wrap);
      if (s.key === 'summary') self.buildSummary(wrap.lastChild);
    });
    this.syncTables();
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
    } else if (!want && have) {
      var active = document.activeElement;
      var held = active && have.contains(active);
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
    if (!body) { this.renderSummary(); return; }
    var self = this;
    var seen = {};
    var index = 0;
    var prev = null;
    this.engine.cards.forEach(function (meta, id) {
      var vt = meta.element && meta.element._virtualTable ? meta.element._virtualTable : null;
      var st = self.tables.get(id);
      if (st && (st.vt !== vt || st.meta !== meta || st.name !== meta.name)) {
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
    Array.from(this.tables.keys()).forEach(function (id) { if (!seen[id]) self.dropTable(id); });
    this.renderSummary();
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

  function sparkStats(card, c) {
    var th = card && card.querySelectorAll ? card.querySelectorAll('thead th')[c] : null;
    var out = { distinct: null, missing: null };
    if (!th) return out;
    var na = th.querySelector('.sideview-na-badge');
    var cat = th.querySelector('.sideview-cat-profile');
    var spark = th.querySelector('.sideview-sparkline');
    var m = na ? /^(\d+) missing/.exec(na.getAttribute('title') || '') : null;
    if (m) out.missing = parseInt(m[1], 10);
    else if (spark || (cat && !/^All values missing/.test(cat.getAttribute('title') || ''))) out.missing = 0;
    var d = cat ? /(\d+) distinct/.exec(cat.getAttribute('title') || '') : null;
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

  // Result hooks, called by the engine from its reply handlers; the section tasks fill them in.
  ListView.prototype.onJoinDiag = function (sig, d) { return [sig, d]; };
  ListView.prototype.onSuppCheck = function (d) { return d; };
  ListView.prototype.onColumnProfile = function (d) {
    if (this._destroyed || !d || !d.id) return;
    this.writeProfile(d.id, d);
  };

  ListView.prototype.destroy = function () {
    this._destroyed = true;
    this._summaryText = null;
    this.releaseTables();
    if (this.el && this.el.parentNode) this.el.parentNode.removeChild(this.el);
  };

  global.SideviewListView = ListView;

})(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this));
