/**
 * gui-test-runner.js
 * Automated Headless Browser / DOM Test Harness for sideview (v0.2.0 Pillar 5)
 * Simulates user interactions (dragging, port clicks, popovers, drawer buttons)
 * and executes sideview.js with complete state assertions.
 */

const fs = require('fs');
const path = require('path');

// Mock DOM Implementation
class MockClassList {
  constructor(node) {
    this.node = node;
    this.classes = new Set();
  }
  add(...names) {
    names.forEach(n => { if (n) this.classes.add(n); });
    this._sync();
  }
  remove(...names) {
    names.forEach(n => this.classes.delete(n));
    this._sync();
  }
  toggle(n, force) {
    if (force === true) this.classes.add(n);
    else if (force === false) this.classes.delete(n);
    else if (this.classes.has(n)) this.classes.delete(n);
    else this.classes.add(n);
    this._sync();
  }
  contains(n) { return this.classes.has(n); }
  _sync() {
    this.node._className = Array.from(this.classes).join(' ');
  }
}

class MockElement {
  constructor(tagName, ns = '') {
    this.tagName = tagName.toUpperCase();
    this.ns = ns;
    this.nodeType = 1;
    this.id = '';
    this._className = '';
    this.classList = new MockClassList(this);
    this.style = {};
    this.dataset = {};
    this.attributes = new Map();
    this.children = [];
    this.childNodes = this.children;
    this.parentElement = null;
    this.parentNode = null;
    this.listeners = new Map();
    this._textContent = '';
    this.value = '';
    this.checked = false;
    this._virtualTable = null;
    this._sideviewInstance = null;
    this._sourceBtn = null;
    this.scrollTop = 0;
    this.scrollLeft = 0;
    this.scrollWidth = 400;
    this.scrollHeight = 300;
    this.clientWidth = 400;
    this.clientHeight = 300;
  }

  get className() { return this._className; }
  set className(val) {
    this._className = val || '';
    this.classList.classes.clear();
    (this._className.split(/\s+/) || []).forEach(c => {
      if (c) this.classList.classes.add(c);
    });
  }

  get offsetWidth() {
    return parseFloat(this.style.width) || (this.classList.contains('sideview-card') ? 340 : 100);
  }
  get offsetHeight() {
    return parseFloat(this.style.height) || (this.classList.contains('sideview-card') ? 240 : 30);
  }

  get nextSibling() {
    if (!this.parentElement) return null;
    const idx = this.parentElement.children.indexOf(this);
    return idx >= 0 && idx < this.parentElement.children.length - 1 ? this.parentElement.children[idx + 1] : null;
  }

  get cells() {
    return this.children.filter(c => c.tagName === 'TD' || c.tagName === 'TH');
  }

  get cellIndex() {
    if (!this.parentElement) return 0;
    const cells = this.parentElement.cells || [];
    return cells.indexOf(this);
  }

  get rowIndex() {
    if (!this.parentElement) return 0;
    return this.parentElement.children.indexOf(this);
  }

  get textContent() {
    if (this.children.length === 0) return this._textContent;
    return this.children.map(c => c.textContent).join('');
  }
  set textContent(val) {
    this._textContent = String(val);
    this.children = [];
    this.childNodes = this.children;
  }

  get innerHTML() { return this.textContent; }
  set innerHTML(html) {
    this.children = [];
    this.childNodes = this.children;
    parseHTMLToMock(html, this);
  }

  setAttribute(k, v) {
    this.attributes.set(k, String(v));
    if (k === 'class') this.className = String(v);
    if (k === 'id') this.id = String(v);
    if (k.startsWith('data-')) {
      const prop = k.slice(5).replace(/-([a-z])/g, (_, g) => g.toUpperCase());
      this.dataset[prop] = String(v);
    }
  }
  getAttribute(k) {
    if (k === 'class') return this.className;
    if (k === 'id') return this.id;
    if (this.attributes.has(k)) return this.attributes.get(k);
    if (k.startsWith('data-')) {
      const prop = k.slice(5).replace(/-([a-z])/g, (_, g) => g.toUpperCase());
      return this.dataset[prop] || null;
    }
    return null;
  }
  hasAttribute(k) { return this.attributes.has(k) || (k === 'class' && !!this.className); }
  removeAttribute(k) {
    this.attributes.delete(k);
    if (k === 'class') this.className = '';
  }

  appendChild(child) {
    if (!child) return null;
    if (child.parentElement) child.parentElement.removeChild(child);
    this.children.push(child);
    child.parentElement = this;
    child.parentNode = this;
    return child;
  }

  removeChild(child) {
    const idx = this.children.indexOf(child);
    if (idx >= 0) {
      this.children.splice(idx, 1);
      child.parentElement = null;
      child.parentNode = null;
    }
    return child;
  }

  insertBefore(newNode, refNode) {
    if (!newNode) return null;
    if (newNode.parentElement) newNode.parentElement.removeChild(newNode);
    if (!refNode) return this.appendChild(newNode);
    const idx = this.children.indexOf(refNode);
    if (idx >= 0) {
      this.children.splice(idx, 0, newNode);
      newNode.parentElement = this;
      newNode.parentNode = this;
    } else {
      this.appendChild(newNode);
    }
    return newNode;
  }

  remove() {
    if (this.parentElement) this.parentElement.removeChild(this);
  }

  addEventListener(type, fn) {
    if (!this.listeners.has(type)) this.listeners.set(type, []);
    this.listeners.get(type).push(fn);
  }
  removeEventListener(type, fn) {
    if (this.listeners.has(type)) {
      const fns = this.listeners.get(type).filter(f => f !== fn);
      this.listeners.set(type, fns);
    }
  }
  dispatchEvent(event) {
    event.target = this;
    let curr = this;
    while (curr) {
      event.currentTarget = curr;
      const fns = curr.listeners.get(event.type) || [];
      for (const fn of fns) {
        fn.call(curr, event);
        if (event._propagationStopped) break;
      }
      if (event._propagationStopped || !event.bubbles) break;
      curr = curr.parentElement;
    }
    return !event.defaultPrevented;
  }

  click() {
    const evt = new MockEvent('click', { bubbles: true, cancelable: true });
    this.dispatchEvent(evt);
  }
  focus() {}
  select() {}
  setPointerCapture() {}
  releasePointerCapture() {}

  getBoundingClientRect() {
    const left = parseFloat(this.style.left) || 40;
    const top = parseFloat(this.style.top) || 40;
    const width = this.offsetWidth;
    const height = this.offsetHeight;
    return {
      left: left,
      top: top,
      right: left + width,
      bottom: top + height,
      width: width,
      height: height,
      x: left,
      y: top
    };
  }

  closest(selector) {
    let curr = this;
    while (curr) {
      if (curr.matches && curr.matches(selector)) return curr;
      curr = curr.parentElement;
    }
    return null;
  }

  matches(selector) {
    if (!selector) return false;
    selector = selector.trim();
    if (selector === '*') return true;

    if (selector.includes(',')) {
      return selector.split(',').some(s => this.matches(s.trim()));
    }

    const idMatch = selector.match(/#([a-zA-Z0-9_-]+)/);
    if (idMatch && this.id !== idMatch[1]) return false;

    const tagMatch = selector.match(/^([a-zA-Z0-9]+)/);
    if (tagMatch && this.tagName !== tagMatch[1].toUpperCase()) return false;

    const classMatches = selector.match(/\.([a-zA-Z0-9_-]+)/g);
    if (classMatches) {
      for (const cm of classMatches) {
        const cls = cm.slice(1);
        if (!this.classList.contains(cls)) return false;
      }
    }

    const attrRegex = /\[([a-zA-Z0-9_-]+)(?:(=|~=|\|=|\^=|\$=|\*=)["']?([^"'\]]*)["']?)?\]/g;
    let attrMatch;
    while ((attrMatch = attrRegex.exec(selector)) !== null) {
      const attr = attrMatch[1];
      const val = attrMatch[3];
      if (attr.startsWith('data-')) {
        const prop = attr.slice(5).replace(/-([a-z])/g, (_, g) => g.toUpperCase());
        if (val === undefined) {
          if (this.dataset[prop] === undefined) return false;
        } else if (this.dataset[prop] !== val) {
          return false;
        }
      } else {
        if (val === undefined) {
          if (!this.hasAttribute(attr)) return false;
        } else if (this.getAttribute(attr) !== val) {
          return false;
        }
      }
    }

    return true;
  }

  querySelector(selector) {
    const all = this.querySelectorAll(selector);
    return all.length > 0 ? all[0] : null;
  }

  querySelectorAll(selector) {
    if (!selector) return [];
    if (selector.includes(',')) {
      const parts = selector.split(',').map(s => s.trim());
      const set = new Set();
      for (const p of parts) {
        for (const el of this.querySelectorAll(p)) set.add(el);
      }
      return Array.from(set);
    }

    const parts = selector.trim().split(/\s+/);
    if (parts.length > 1) {
      let current = [this];
      for (const part of parts) {
        const next = [];
        for (const parent of current) {
          next.push(...parent.querySelectorAll(part));
        }
        current = next;
      }
      return current;
    }

    const results = [];
    function walk(node) {
      for (const child of node.children) {
        if (child.matches && child.matches(selector)) results.push(child);
        walk(child);
      }
    }
    walk(this);
    return results;
  }
}

class MockEvent {
  constructor(type, opts = {}) {
    this.type = type;
    this.bubbles = opts.bubbles !== undefined ? opts.bubbles : true;
    this.cancelable = opts.cancelable !== undefined ? opts.cancelable : true;
    this.clientX = opts.clientX || 0;
    this.clientY = opts.clientY || 0;
    this.pointerId = opts.pointerId || 1;
    this.key = opts.key || '';
    this.defaultPrevented = false;
    this._propagationStopped = false;
    this.target = null;
    this.currentTarget = null;
  }
  stopPropagation() { this._propagationStopped = true; }
  preventDefault() { this.defaultPrevented = true; }
}

function parseHTMLToMock(html, parent) {
  if (!html) return;
  const tagRegex = /<([a-zA-Z0-9]+)([^>]*)>([\s\S]*?)<\/\1>|<([a-zA-Z0-9]+)([^>]*)\/>/g;
  let match;

  while ((match = tagRegex.exec(html)) !== null) {
    const tag = match[1] || match[4];
    const attrsStr = match[2] || match[5] || '';
    const inner = match[3] || '';
    const el = new MockElement(tag);

    const attrRegex = /([a-zA-Z0-9_-]+)(?:=["']([^"']*)["'])?/g;
    let attrMatch;
    while ((attrMatch = attrRegex.exec(attrsStr)) !== null) {
      el.setAttribute(attrMatch[1], attrMatch[2] !== undefined ? attrMatch[2] : '');
    }

    if (inner && !inner.includes('<')) {
      el._textContent = inner.trim();
    } else if (inner) {
      parseHTMLToMock(inner, el);
    }
    parent.appendChild(el);
  }
}

function findSideviewJs() {
  const candidates = [
    // Set by test-computer-use-gui.R from system.file(), which also works in
    // R CMD check where there is no inst/ folder.
    process.env.SIDEVIEW_JS || '',
    path.join(__dirname, '../../inst/www/sideview.js'),
    path.join(__dirname, '../inst/www/sideview.js'),
    path.join(__dirname, 'inst/www/sideview.js'),
    path.resolve('inst/www/sideview.js'),
    path.resolve('../inst/www/sideview.js')
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  throw new Error('Cannot locate inst/www/sideview.js');
}

function runAllScenarios() {
  const wsMessages = [];
  const results = {
    scenario1: {},
    scenario2: {},
    scenario3: {},
    scenario4: {},
    scenario5: {},
    scenario6: {},
    scenario7: {},
    diagnostics: {}
  };

  // Set up globals
  global.window = global;
  if (!global.window.addEventListener) global.window.addEventListener = function () {};
  if (!global.window.removeEventListener) global.window.removeEventListener = function () {};
  global.MockElement = MockElement;
  global.MockEvent = MockEvent;
  global.MouseEvent = MockEvent;
  global.PointerEvent = MockEvent;
  global.CustomEvent = MockEvent;
  global.requestAnimationFrame = cb => setTimeout(cb, 0);

  const documentRoot = new MockElement('BODY');
  global.document = {
    body: documentRoot,
    readyState: 'complete',
    createElement(tag) { return new MockElement(tag); },
    createElementNS(ns, tag) { return new MockElement(tag, ns); },
    createDocumentFragment() {
      const f = new MockElement('FRAGMENT');
      f.isFragment = true;
      return f;
    },
    querySelector(sel) {
      if (sel === 'body') return documentRoot;
      return documentRoot.querySelector(sel);
    },
    querySelectorAll(sel) { return documentRoot.querySelectorAll(sel); },
    addEventListener: documentRoot.addEventListener.bind(documentRoot),
    removeEventListener: documentRoot.removeEventListener.bind(documentRoot),
    dispatchEvent: documentRoot.dispatchEvent.bind(documentRoot)
  };

  // Shiny message sink
  const shinyHandlers = {};
  global.Shiny = {
    setInputValue(name, value, opts) {
      wsMessages.push({ event: name, value: value, priority: opts ? opts.priority : null, timestamp: Date.now() });
    },
    addCustomMessageHandler(type, fn) { shinyHandlers[type] = fn; }
  };

  // Panzoom Mock
  let currentScale = 1.0;
  global.Panzoom = function(viewport, options) {
    return {
      getScale() { return currentScale; },
      zoomToPoint(newScale, center) {
        currentScale = newScale;
        viewport.dispatchEvent(new MockEvent('panzoomchange'));
        return currentScale;
      },
      reset() {
        currentScale = 1.0;
        viewport.dispatchEvent(new MockEvent('panzoomchange'));
        return currentScale;
      }
    };
  };

  // Load and evaluate sv-pipeline.js, then sideview.js (same order as the dependency)
  const sideviewPath = findSideviewJs();
  eval(fs.readFileSync(path.join(path.dirname(sideviewPath), 'sv-pipeline.js'), 'utf8'));
  const sideviewCode = fs.readFileSync(sideviewPath, 'utf8');
  eval(sideviewCode);

  const container = new MockElement('DIV');
  container.className = 'sideview-container';
  document.body.appendChild(container);

  const sampleCards = [
    {
      id: 'card_000001',
      name: 'patients',
      type: 'grid',
      // Fixed positions: these scenarios check drag/dock arithmetic. Automatic
      // launch layout is covered by the real-browser tests.
      x: 40,
      y: 60,
      dims: [4, 3],
      data: {
        patient_id: ['P1', 'P2', 'P3', 'P4'],
        age: [45, 62, 38, 55],
        gender: ['M', 'F', 'F', 'M']
      },
      col_types: { patient_id: 'character', age: 'numeric', gender: 'character' }
    },
    {
      id: 'card_000002',
      name: 'visits',
      type: 'grid',
      x: 400,
      y: 110,
      dims: [4, 3],
      data: {
        patient_id: ['P1', 'P2', 'P3', 'P5'],
        visit_date: ['2026-01-01', '2026-02-15', '2026-03-10', '2026-04-05'],
        cost: [120, 350, 80, 210]
      },
      col_types: { patient_id: 'character', visit_date: 'character', cost: 'numeric' }
    }
  ];

  const engine = global.Sideview.init(container, {
    cards: sampleCards,
    snapToEdge: true,
    snapThreshold: 20
  });

  // SCENARIO 1: Canvas Coordinates & Pan/Zoom
  const canvas = container.querySelector('.sideview-canvas');
  const viewport = container.querySelector('.sideview-viewport');
  const svg = container.querySelector('.sideview-connector-svg');
  const toolbar = container.querySelector('.sideview-toolbar');
  const drawer = container.querySelector('.sideview-drawer');
  const card1 = container.querySelector('[data-card-id="card_000001"]');
  const card2 = container.querySelector('[data-card-id="card_000002"]');

  const s1_init_scale = engine.panzoom.getScale();
  toolbar.querySelector('[data-action="zoom-in"]').click();
  const s1_zoom_in_scale = engine.panzoom.getScale();
  toolbar.querySelector('[data-action="zoom-out"]').click();
  const s1_zoom_out_scale = engine.panzoom.getScale();
  toolbar.querySelector('[data-action="zoom-reset"]').click();
  const s1_reset_scale = engine.panzoom.getScale();

  results.scenario1 = {
    initialized: global.sideviewInitialized === true,
    has_canvas: !!canvas,
    has_viewport: !!viewport,
    has_svg: !!svg,
    has_toolbar: !!toolbar,
    has_drawer: !!drawer,
    card_count: engine.cards.size,
    card1_id: card1 ? card1.dataset.cardId : null,
    card2_id: card2 ? card2.dataset.cardId : null,
    card1_left: parseFloat(card1.style.left),
    card2_left: parseFloat(card2.style.left),
    initial_scale: s1_init_scale,
    zoom_in_scale: s1_zoom_in_scale,
    zoom_out_scale: s1_zoom_out_scale,
    reset_scale: s1_reset_scale
  };

  // SCENARIO 2: Card Dragging Simulation & Magnetic Docking
  const header2 = card2.querySelector('.sideview-card-header');
  const s2_initial_left = parseFloat(card2.style.left);

  // Drag card2 by +120px horizontally
  header2.dispatchEvent(new MockEvent('mousedown', { clientX: 450, clientY: 100 }));
  document.dispatchEvent(new MockEvent('mousemove', { clientX: 570, clientY: 100 }));
  document.dispatchEvent(new MockEvent('mouseup', { clientX: 570, clientY: 100 }));

  const s2_dragged_left = parseFloat(card2.style.left);
  const s2_move_msg = wsMessages.filter(m => m.event === 'sideview_card_moved').pop();

  // Magnetic docking drag
  header2.dispatchEvent(new MockEvent('mousedown', { clientX: 570, clientY: 100 }));
  document.dispatchEvent(new MockEvent('mousemove', { clientX: 440, clientY: 100 })); // target = 390 -> snaps to 396
  document.dispatchEvent(new MockEvent('mouseup', { clientX: 440, clientY: 100 }));

  const s2_snapped_left = parseFloat(card2.style.left);

  results.scenario2 = {
    initial_left: s2_initial_left,
    dragged_left: s2_dragged_left,
    expected_dragged: s2_initial_left + 120,
    moved_dispatched: !!s2_move_msg && s2_move_msg.value.card_id === 'card_000002',
    snapped_left: s2_snapped_left,
    docking_success: s2_snapped_left === 396
  };

  // SCENARIO 3: Column Port Connection & Cubic Bezier Spline
  const portA = card1.querySelector('.sideview-col-port[data-col-name="patient_id"]');
  const portB = card2.querySelector('.sideview-col-port[data-col-name="patient_id"]');

  portA.click();
  const s3_portA_connecting = portA.classList.contains('connecting');

  portB.click();
  const s3_portA_connected = !portA.classList.contains('connecting');

  // Test Escape cancellation
  engine.clearOperations();
  portA.click();
  const s3_escape_active = engine.activePort !== null;
  document.dispatchEvent(new MockEvent('keydown', { key: 'Escape' }));
  const s3_escape_cancelled = engine.activePort === null;

  // Test header th click-to-connect
  portA.click();
  const thTarget = card2.querySelector('th[data-col-name="patient_id"]');
  thTarget.click();
  const s3_th_connected = engine.connections.length === 1;

  const connectors = svg.querySelectorAll('.sideview-connector-path');
  const activePath = connectors.length > 0 ? connectors[0] : null;
  const pathD = activePath ? activePath.getAttribute('d') : '';
  const s3_map_msg = wsMessages.filter(m => m.event === 'column_mapped').pop();

  results.scenario3 = {
    portA_connecting: s3_portA_connecting,
    portA_connected: s3_portA_connected,
    escape_cancelled: s3_escape_active && s3_escape_cancelled,
    th_connected: s3_th_connected,
    connectors_count: connectors.length,
    has_bezier: !!pathD && pathD.startsWith('M ') && pathD.includes(' C '),
    path_d: pathD,
    drawer_code: engine.generatedCode,
    mapped_event_dispatched: !!s3_map_msg && s3_map_msg.value.from_col === 'patient_id' && s3_map_msg.value.to_col === 'patient_id'
  };

  // SCENARIO 4: Suggested Spline Interaction
  engine.clearOperations();
  engine.renderSuggestedSplines([
    {
      from_table: 'patients',
      from_col: 'patient_id',
      to_table: 'visits',
      to_col: 'patient_id',
      confidence: 0.95,
      reason: 'Exact identifier match'
    }
  ]);

  const suggestedSpline = svg.querySelector('.sideview-spline-suggested');
  const s4_rendered = !!suggestedSpline;
  const s4_has_dashMove = suggestedSpline ? suggestedSpline.classList.contains('dashMove') : false;
  const s4_is_suggested = suggestedSpline ? suggestedSpline.dataset.suggested === 'true' : false;
  const s4_confidence = suggestedSpline ? suggestedSpline.dataset.confidence : null;

  if (suggestedSpline) {
    suggestedSpline.click();
  }
  const s4_remaining_suggested = svg.querySelectorAll('.sideview-spline-suggested').length;
  const s4_accepted_connections = engine.connections.length;

  results.scenario4 = {
    rendered: s4_rendered,
    has_dashMove: s4_has_dashMove,
    is_suggested: s4_is_suggested,
    confidence: s4_confidence,
    remaining_suggested_after_click: s4_remaining_suggested,
    accepted_connections: s4_accepted_connections,
    acceptance_success: s4_remaining_suggested === 0 && s4_accepted_connections === 1
  };

  // SCENARIO 5: Header Sort Cycling & Filter Popover Click
  const sortBtnAge = card1.querySelector('.sideview-sort-btn[data-col-name="age"]');
  const thAge = card1.querySelector('th[data-col-name="age"]');

  sortBtnAge.click(); // asc
  const s5_sort1_state = thAge.dataset.sortState;
  const s5_sort1_text = sortBtnAge.dataset.svIcon;

  sortBtnAge.click(); // desc
  const s5_sort2_state = thAge.dataset.sortState;
  const s5_sort2_text = sortBtnAge.dataset.svIcon;

  sortBtnAge.click(); // none
  const s5_sort3_state = thAge.dataset.sortState;
  const s5_sort3_text = sortBtnAge.dataset.svIcon;

  const filterBtnAge = card1.querySelector('.sideview-filter-btn[data-col-name="age"]');
  filterBtnAge.click();

  const popover = document.querySelector('.sideview-filter-popover');
  const s5_popover_open = !!popover;

  if (popover) {
    popover.querySelector('.sideview-filter-select').value = 'gt';
    popover.querySelector('.sideview-filter-input').value = '50';
    popover.querySelector('.sideview-filter-apply').click();
  }
  const s5_filter_active = filterBtnAge.classList.contains('active');

  results.scenario5 = {
    sort_cycle_asc: s5_sort1_state === 'asc' && s5_sort1_text === 'sortAsc',
    sort_cycle_desc: s5_sort2_state === 'desc' && s5_sort2_text === 'sortDesc',
    sort_cycle_none: s5_sort3_state === 'none' && s5_sort3_text === 'sort',
    popover_rendered: s5_popover_open,
    filter_active: s5_filter_active
  };

  // SCENARIO 6: Action Drawer Code Dispatch
  engine.updateDrawerCode('patients %>% dplyr::filter(age > 50)');

  drawer.querySelector('[data-action="inject-script"]').click();
  const s6_inject_msg = wsMessages.filter(m => m.event === 'inject_script').pop();

  drawer.querySelector('[data-action="eval-env"]').click();
  const s6_eval_msg = wsMessages.filter(m => m.event === 'eval_env').pop();

  drawer.querySelector('[data-action="send-console-exit"]').click();
  const s6_exit_msg = wsMessages.filter(m => m.event === 'send_console_and_exit').pop();

  drawer.querySelector('[data-action="clear-operation"]').click();
  const s6_clear_msg = wsMessages.filter(m => m.event === 'clear_operations').pop();

  results.scenario6 = {
    inject_script_dispatched: !!s6_inject_msg && s6_inject_msg.value.code.includes('age > 50'),
    eval_env_dispatched: !!s6_eval_msg && s6_eval_msg.value.code.includes('age > 50'),
    console_exit_dispatched: !!s6_exit_msg && s6_exit_msg.value.code.includes('age > 50'),
    clear_dispatched: !!s6_clear_msg,
    svg_paths_cleared: svg.querySelectorAll('.sideview-connector-path').length === 0,
    drawer_code_cleared: engine.generatedCode === ''
  };

  // Scenario 7: an R error on a step that touches an arrow / duckdb table says where to look.
  const s7_toasts = [];
  const s7_showToast = engine.showToast;
  engine.showToast = function (text, type) { s7_toasts.push({ text: text, type: type }); };
  const s7_hint = 'This step may need data in R: move collect() above it.';
  const s7_fire = function (message, success) { shinyHandlers.sideview_eval_result({ success: success, message: message }); };
  engine.pipeline.clear();
  engine.pipeline.setTables({});
  s7_fire('Error in x: boom', false);                  // no lazy table: the message is untouched
  engine.pipeline.setTables({ lazy_tbl: { lazy: 'duckdb', codeRef: 'dplyr::tbl(con, "lazy_tbl")' } });
  s7_fire('Error in x: boom', false);                  // a lazy table, but no step touches it
  engine.pipeline.add({ kind: 'filter', table: 'lazy_tbl', conds: ['x > 1'] });
  s7_fire('Error in x: boom', false);                  // a step touches it: the hint is added
  s7_fire('Ran fine', true);                           // success: never changed
  const s7_code = engine.pipeline.compose();
  engine.pipeline.clear();
  engine.pipeline.setTables({});
  engine.showToast = s7_showToast;

  results.scenario7 = {
    plain_unchanged: s7_toasts[0].text === 'Error in x: boom',
    idle_lazy_unchanged: s7_toasts[1].text === 'Error in x: boom',
    hint_added: s7_toasts[2].text === 'Error in x: boom ' + s7_hint && s7_toasts[2].type === 'danger',
    success_unchanged: s7_toasts[3].text === 'Ran fine' && s7_toasts[3].type === 'success',
    lazy_code_collects: /dplyr::collect\(\)$/.test(s7_code) && s7_code.indexOf('dplyr::tbl(con, "lazy_tbl")') === 0
  };

  // DIAGNOSTIC FAILURE CAPTURE HELPER
  function captureDiagnostics(testName, errorMsg) {
    const canvasDump = {
      test: testName,
      error: errorMsg || null,
      scale: engine.panzoom.getScale(),
      cards: Array.from(engine.cards.entries()).map(([id, c]) => ({
        id: id,
        name: c.name,
        x: c.x,
        y: c.y,
        width: c.element ? c.element.offsetWidth : null,
        height: c.element ? c.element.offsetHeight : null
      })),
      connections: engine.connections.map(c => ({
        id: c.id,
        from: `${c.fromTable}.${c.fromCol}`,
        to: `${c.toTable}.${c.toCol}`
      })),
      ws_log_count: wsMessages.length,
      last_ws_message: wsMessages.length > 0 ? wsMessages[wsMessages.length - 1] : null
    };

    const report = [
      '+-------------------------------------------------------------+',
      '| AUTOMATED GUI DIAGNOSTIC REPORT                             |',
      `| Test: ${testName.padEnd(52)}|`,
      '| Status: FAILED                                              |',
      `| Error: ${(errorMsg || 'Assertion failure').slice(0, 52).padEnd(53)}|`,
      '|                                                             |',
      '| Captured Artifacts:                                         |',
      `|  - Canvas Dump: artifacts/canvas_failure_dump.json          |`,
      `|  - WS Log: ${String(wsMessages.length).padEnd(4)} messages recorded                     |`,
      '+-------------------------------------------------------------+'
    ].join('\n');

    return { dump: canvasDump, report: report };
  }

  const sampleDiag = captureDiagnostics('Scenario 3 (Spline Connection)', 'Port element did not register click');
  results.diagnostics = {
    has_dump: !!sampleDiag.dump,
    has_report: !!sampleDiag.report,
    report_text: sampleDiag.report,
    ws_log_count: wsMessages.length
  };

  return results;
}

const out = runAllScenarios();
console.log(JSON.stringify(out, null, 2));
