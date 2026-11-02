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
    this.contains = function (n) {
      for (let cur = n; cur; cur = cur.parentNode) if (cur === this) return true;
      return false;
    };
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
    scenario8: {},
    scenario9: {},
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

  // Scenario 8: the rule row and the Strict checkbox on a join step.
  const s8_toasts = [];
  const s8_showToast = engine.showToast;
  engine.showToast = function (text, type) { s8_toasts.push({ text: text, type: type }); };
  engine.pipeline.clear();
  const s8_tables = function (visitKind) {
    return {
      patients: { kinds: { patient_id: 'character', admit_date: 'Date', age: 'numeric' } },
      visits: { kinds: { patient_id: 'character', visit_date: visitKind, cost: 'numeric' } }
    };
  };
  engine.pipeline.setTables(s8_tables('Date'));
  engine.pipeline.add({
    kind: 'join', table: 'patients', right: 'visits', type: 'left_join',
    by: [{ left: 'patient_id', right: 'patient_id' }]
  }, 'join');
  const s8_id = engine.pipeline.steps[0].id;
  const s8_li = function () { return container.querySelector('.sideview-step[data-step-id="' + s8_id + '"]'); };
  const s8_cur = function () { return engine.pipeline.find(s8_id); };
  const s8_fire = function (el, type, props) {
    const ev = new MockEvent(type, { bubbles: true });
    Object.assign(ev, props || {});
    el.dispatchEvent(ev);
  };
  const s8_set = function (sel, value) {
    const el = s8_li().querySelector(sel);
    el.value = String(value);
    s8_fire(el, 'change');
    return el;
  };
  const s8_row = function () { return s8_li().querySelector('.sideview-rule-row'); };
  const s8_apply = function () { return s8_li().querySelector('.sideview-rule-apply'); };
  const s8_open = function () { s8_li().querySelector('.sideview-step-rule').click(); };

  const s8_ruleBtn = s8_li().querySelector('.sideview-step-rule');
  const s8_hasBtn = !!s8_ruleBtn && s8_ruleBtn.dataset.stepAction === 'rule' &&
    s8_ruleBtn.getAttribute('aria-label') === 'Date rule';
  const s8_closedAtFirst = !s8_row();
  s8_open();
  const s8_opened = !!s8_row();
  const s8_shapeOptions = s8_row().querySelector('.sideview-rule-shape')
    .querySelectorAll('option').map(o => o.getAttribute('value'));
  s8_set('.sideview-rule-shape', 'window');
  const s8_colOptions = function (slot) {
    return s8_li().querySelector('.sideview-rule-col[data-slot="' + slot + '"]')
      .querySelectorAll('option').map(o => o.getAttribute('value')).filter(v => v !== '');
  };
  const s8_xOptions = s8_colOptions('xCol');
  s8_set('.sideview-rule-col[data-slot="xCol"]', 'admit_date');
  const s8_yOptions = s8_colOptions('yCol');
  s8_set('.sideview-rule-col[data-slot="yCol"]', 'visit_date');
  s8_set('.sideview-rule-from', 8);
  s8_set('.sideview-rule-to', 7);
  const s8_bad = {
    disabled: !!s8_apply().disabled,
    msg: s8_li().querySelector('.sideview-rule-msg').textContent
  };
  s8_set('.sideview-rule-from', -7);
  const s8_fixedEnabled = !s8_apply().disabled;
  s8_apply().click();
  const s8_code = engine.generatedCode;
  const s8_rule = s8_cur().rule;
  const s8_closedAfterApply = !s8_row();

  // Ctrl+Z removes the rule
  s8_fire(document, 'keydown', { key: 'z', ctrlKey: true });
  const s8_undone = !s8_cur().rule && engine.generatedCode.indexOf('.sv_lo') < 0;

  // Esc closes the row and keeps the code
  s8_open();
  const s8_reopened = !!s8_row();
  s8_set('.sideview-rule-shape', 'window');
  s8_set('.sideview-rule-col[data-slot="xCol"]', 'admit_date');
  s8_set('.sideview-rule-col[data-slot="yCol"]', 'visit_date');
  s8_apply().click();
  const s8_codeBefore = engine.generatedCode;
  s8_open();
  s8_fire(document, 'keydown', { key: 'Escape' });
  const s8_escClosed = !s8_row() && engine.generatedCode === s8_codeBefore && !!s8_cur().rule;

  // "none" with Apply (here by Ctrl+Enter) clears the rule
  s8_open();
  s8_set('.sideview-rule-shape', 'none');
  const s8_noneEnabled = !s8_apply().disabled;
  s8_fire(s8_li().querySelector('.sideview-rule-shape'), 'keydown', { key: 'Enter', ctrlKey: true });
  const s8_noneApplied = !s8_cur().rule && !s8_row();

  // Before on a right join switches to a left join and raises the toast
  engine.pipeline.update(s8_id, { type: 'right_join' });
  s8_open();
  s8_set('.sideview-rule-shape', 'before');
  s8_set('.sideview-rule-col[data-slot="xCol"]', 'admit_date');
  s8_set('.sideview-rule-col[data-slot="yCol"]', 'visit_date');
  const s8_beforeEnabled = !s8_apply().disabled;
  s8_toasts.length = 0;
  s8_apply().click();
  const s8_typeSwitched = s8_cur().type === 'left_join';
  const s8_toast = s8_toasts.some(t => t.type === 'info' &&
    t.text === 'Nearest-match rules need a left, inner, semi or anti join: switched to left join.');
  const s8_disabledTypes = s8_li().querySelector('.sideview-step-jointype').querySelectorAll('option')
    .filter(o => o.hasAttribute('disabled')).map(o => o.getAttribute('value')).sort();
  engine.pipeline.setJoinRule(s8_id, null);

  // Strict toggles step.strict
  const s8_strictBox = function () { return s8_li().querySelector('.sideview-step-strict'); };
  s8_strictBox().checked = true;
  s8_fire(s8_strictBox(), 'change');
  const s8_strictOn = s8_cur().strict === true;
  s8_strictBox().checked = false;
  s8_fire(s8_strictBox(), 'change');
  const s8_strictOff = !s8_cur().strict;

  // A column that changes kind leaves the rule needing a fix
  engine.pipeline.setJoinRule(s8_id, { shape: 'window', xCol: 'admit_date', yCol: 'visit_date', from: -7, to: 7 });
  const s8_okLabel = s8_li().textContent.indexOf('Rule needs fixing') < 0;
  engine.pipeline.setTables(s8_tables('character'));
  const s8_fixLabel = s8_li().querySelector('.sideview-step-rule').querySelector('.is-invalid');
  const s8_needsFix = s8_li().textContent.indexOf('Rule needs fixing') >= 0 && !!s8_fixLabel &&
    s8_fixLabel.textContent === 'Rule needs fixing';
  // the step's own label (its title; the mock DOM has no nested text) says so, from the pipeline's tables
  const s8_labelFix = s8_li().querySelector('.sideview-step-text').getAttribute('title').indexOf(' · Rule needs fixing') >= 0;

  // Strict is off on a lazy chain, with the reason
  engine.pipeline.setTables(Object.assign(s8_tables('Date'), {
    visits: { lazy: 'duckdb', codeRef: 'dplyr::tbl(con, "visits")', kinds: { patient_id: 'character', visit_date: 'Date' } }
  }));
  const s8_lazyDisabled = s8_strictBox().hasAttribute('disabled') && s8_strictBox().getAttribute('title') ===
    'Strict runs in R only: duckdb rejects relationship and unmatched, and arrow ignores them';

  // Strict is greyed, with the reason, when an earlier step changes the rows of the left table;
  // it keeps its flag, and is enabled again once the step is gone
  engine.pipeline.setTables(s8_tables('Date'));
  const s8_strictFree = !s8_strictBox().hasAttribute('disabled');
  engine.pipeline.setJoinStrict(s8_id, true);
  const s8_filterStep = engine.pipeline.add({
    kind: 'filter', table: 'patients', conds: ['age > 45'], combine: 'and'
  }, 'filter');
  engine.pipeline.move(s8_filterStep.id, -1);
  const s8_rowsGrey = s8_strictBox().hasAttribute('disabled') && s8_strictBox().getAttribute('title') ===
    'Strict applies only to a join on the original tables: an earlier step changes the rows' &&
    s8_cur().strict === true;
  engine.pipeline.remove(s8_filterStep.id);
  const s8_strictBack = !s8_strictBox().hasAttribute('disabled');

  // The ? list names the new use of Ctrl+Enter
  engine.toggleShortcuts(true);
  const s8_scrim = container.querySelector('.sideview-shortcuts-scrim');
  const s8_listed = !!s8_scrim && s8_scrim.textContent.indexOf('Add the step in a builder tab, or apply a date rule') >= 0;
  engine.toggleShortcuts(false);

  engine.pipeline.clear();
  engine.pipeline.setTables({});
  engine.ruleDraft = null;
  engine.showToast = s8_showToast;

  results.scenario8 = {
    rule_button: s8_hasBtn,
    closed_at_first: s8_closedAtFirst,
    row_opens: s8_opened,
    shape_options: JSON.stringify(s8_shapeOptions) === JSON.stringify(['none', 'between', 'window', 'before', 'after', 'overlaps']),
    x_columns_by_kind: JSON.stringify(s8_xOptions.slice().sort()) === JSON.stringify(['admit_date', 'age']),
    y_columns_follow_x: JSON.stringify(s8_yOptions) === JSON.stringify(['visit_date']),
    bad_window_blocked: s8_bad.disabled === true,
    bad_window_message: s8_bad.msg === 'The window start must not be after its end.',
    fixed_window_enabled: s8_fixedEnabled,
    apply_writes_code: s8_code.indexOf('.sv_lo') >= 0 && !!s8_rule && s8_rule.shape === 'window' && s8_rule.from === -7 && s8_rule.to === 7,
    apply_closes_row: s8_closedAfterApply,
    undo_removes_rule: s8_undone,
    reopens: s8_reopened,
    esc_closes_keeps_code: s8_escClosed,
    none_enabled: s8_noneEnabled,
    ctrl_enter_applies_none: s8_noneApplied,
    before_enabled_on_right: s8_beforeEnabled,
    before_switches_type: s8_typeSwitched,
    before_toast: s8_toast,
    right_full_disabled_under_before: JSON.stringify(s8_disabledTypes) === JSON.stringify(['full_join', 'right_join']),
    strict_on: s8_strictOn,
    strict_off: s8_strictOff,
    rule_ok_label_absent: s8_okLabel,
    rule_needs_fixing: s8_needsFix,
    strict_disabled_on_lazy: s8_lazyDisabled,
    step_label_says_rule_needs_fixing: s8_labelFix,
    strict_enabled_on_original_tables: s8_strictFree,
    strict_disabled_after_row_changing_step: s8_rowsGrey,
    strict_enabled_again: s8_strictBack,
    shortcut_listed: s8_listed
  };

  // Scenario 9: the join check panel shows the rule, what it dropped and what Strict would write.
  if (!container.querySelector('.sideview-joincheck')) {
    const s9_panel = new MockElement('DIV');
    s9_panel.className = 'sideview-joincheck';
    container.appendChild(s9_panel);
  }
  engine.pipeline.clear();
  engine.pipeline.setTables({
    visits: { kinds: { patient_id: 'character', visit_date: 'Date' } },
    labs: { kinds: { patient_id: 'character', lab_date: 'Date' } }
  });
  engine.pipeline.add({
    kind: 'join', table: 'visits', right: 'labs', type: 'left_join',
    by: [{ left: 'patient_id', right: 'patient_id' }],
    rule: { shape: 'before', xCol: 'visit_date', yCol: 'lab_date', inclusive: true }
  }, 'join');
  const s9_id = engine.pipeline.steps[0].id;
  const s9_step = function () { return engine.pipeline.find(s9_id); };
  const s9_reply = function (over) {
    return Object.assign({
      id: engine.joinDiagSig(s9_step()), status: 'ok', relationship: 'one-to-many',
      by: [{ left: 'patient_id', right: 'patient_id' }],
      n_x: 40, n_y: 15, matched_x: 40, matched_y: 3, match_rate_x: 1, match_rate_y: 0.2,
      distinct_x: 40, distinct_y: 4, distinct_matched: 4, dup_keys_x: 0, dup_keys_y: 2, na_x: 0, na_y: 0,
      rows: { left_join: 40, inner_join: 40, semi_join: 40, anti_join: 0 },
      unmatched_x: [], unmatched_y: [], type_issues: [], warnings: [], hints: [],
      rule: { shape: 'before', xCol: 'visit_date', yCol: 'lab_date', inclusive: true }, rule_kind: 'Date',
      rule_dropped_x: 2, rule_dropped_y: 1234,
      strict_args: { left_join: { relationship: 'one-to-many' } }
    }, over || {});
  };
  const s9_box = function () { return container.querySelector('.sideview-joincheck'); };
  const s9_show = function (over, type) {
    if (type) engine.pipeline.update(s9_id, { type: type });
    engine.joinDiag = {};
    engine.joinDiagPending[engine.joinDiagSig(s9_step())] = true; // the check the reply answers
    engine.onJoinDiagnostics(s9_reply(over));
    return s9_box().textContent.replace(/&quot;/g, '"');
  };
  const s9_t1 = s9_show({});
  const s9_titleRule = s9_t1.indexOf('rule: last lab_date on or before visit_date') >= 0;
  const s9_dropped = s9_t1.indexOf('Dropped by the rule') >= 0 && s9_t1.indexOf('2 visits rows / 1,234 labs rows') >= 0;
  const s9_dropTitle = (s9_box().querySelector('.sideview-joincheck-dropped') || { getAttribute: function () { return null; } })
    .getAttribute('title') === 'Rows that match on the key but not the rule';
  const s9_missingDash = s9_t1.indexOf('Unknown for right and full joins with a nearest match') >= 0;
  const s9_leftReason = s9_t1.indexOf('Strict would write: relationship = "one-to-many"') >= 0 &&
    s9_t1.indexOf('unmatched left out: 12 labs rows would be dropped') >= 0;
  const s9_tErr = s9_show({ matched_y: 15, strict_args: { left_join: { relationship: 'one-to-many', unmatched: 'error' } } });
  const s9_errArg = s9_tErr.indexOf('Strict would write: relationship = "one-to-many", unmatched = "error"') >= 0 &&
    s9_tErr.indexOf('would be dropped') < 0;
  const s9_tInner = s9_show({ matched_x: 28, matched_y: 12,
    strict_args: { inner_join: { relationship: 'one-to-many' } } }, 'inner_join');
  const s9_inner = s9_tInner.indexOf('12 visits rows and 3 labs rows would be dropped') >= 0;
  const s9_tRight = s9_show({ matched_x: 28, matched_y: 15,
    strict_args: { right_join: { relationship: 'one-to-many' } } }, 'right_join');
  const s9_right = s9_tRight.indexOf('unmatched right out: 12 visits rows would be dropped') >= 0;
  const s9_tSemi = s9_show({}, 'semi_join');
  const s9_semi = s9_tSemi.indexOf('Strict does not apply to semi and anti joins.') >= 0;
  const s9_tNone = s9_show({ relationship: 'no matches', strict_args: {} }, 'left_join');
  const s9_none = s9_tNone.indexOf('Strict needs at least one match.') >= 0;
  const s9_tPlain = s9_show({ rule: undefined, rule_kind: undefined, rule_dropped_x: undefined, rule_dropped_y: undefined,
    rows: { left_join: 40, right_join: 3, inner_join: 40, full_join: 43, semi_join: 40, anti_join: 0 } });
  const s9_plainClean = s9_tPlain.indexOf('Dropped by the rule') < 0 && s9_tPlain.indexOf('rule:') < 0 &&
    s9_tPlain.indexOf('Unknown for right and full joins') < 0;
  // CDISC key-check notes: heading + escaped items; none when empty or absent
  const s9_tCd = s9_show({ cdisc_notes: ['USUBJID is the subject key', '<b>x</b> & y'] });
  const s9_cdiscShown = s9_tCd.indexOf('CDISC') >= 0 && s9_tCd.indexOf('USUBJID is the subject key') >= 0;
  const s9_cdiscEscaped = s9_tCd.indexOf('<b>x</b>') < 0 && s9_tCd.indexOf('&lt;b&gt;x&lt;/b&gt;') >= 0;
  const s9_tCd0 = s9_show({ cdisc_notes: [] });
  const s9_cdiscEmpty = s9_tCd0.indexOf('CDISC') < 0;
  const s9_tCd1 = s9_show({});
  const s9_cdiscAbsent = s9_tCd1.indexOf('CDISC') < 0;
  // A filter before the join: the panel says why Strict writes nothing instead of what it would write
  const s9_filterStep = engine.pipeline.add({
    kind: 'filter', table: 'visits', conds: ['TRUE'], combine: 'and'
  }, 'filter');
  engine.pipeline.move(s9_filterStep.id, -1);
  const s9_tFilter = s9_show({}, 'left_join');
  const s9_filterReason = s9_tFilter.indexOf(
    'Strict applies only to a join on the original tables: an earlier step changes the rows') >= 0 &&
    s9_tFilter.indexOf('Strict would write') < 0;
  engine.joinDiag = {};
  engine.pipeline.clear();
  engine.pipeline.setTables({});

  results.scenario9 = {
    strict_reason_after_row_changing_step: s9_filterReason,
    title_names_rule: s9_titleRule,
    dropped_row: s9_dropped,
    dropped_row_title: s9_dropTitle,
    missing_row_types_note: s9_missingDash,
    strict_relationship_line: s9_leftReason,
    strict_with_unmatched_error: s9_errArg,
    strict_inner_reason: s9_inner,
    strict_right_reason_counts_table: s9_right,
    strict_semi_anti: s9_semi,
    strict_needs_a_match: s9_none,
    no_rule_no_rule_rows: s9_plainClean,
    cdisc_notes_shown: s9_cdiscShown,
    cdisc_notes_escaped: s9_cdiscEscaped,
    cdisc_notes_empty_hidden: s9_cdiscEmpty,
    cdisc_notes_absent_hidden: s9_cdiscAbsent
  };

  // SCENARIO 10: namespaced inputs and the ns-routed message registry (Shiny module transport)
  const s10_card = function () {
    return [{
      id: 'card_m1', name: 'labs', type: 'grid', x: 10, y: 10, dims: [2, 2],
      data: { id: ['a', 'b'], val: [2, 1] }, col_types: { id: 'character', val: 'numeric' }
    }];
  };
  const s10_make = function (opts) {
    const el = new MockElement('DIV');
    el.className = 'sideview-container';
    document.body.appendChild(el);
    opts.cards = s10_card();
    return { el: el, engine: global.Sideview.init(el, opts) };
  };
  const s10_toasts = function (m) {
    return m.el.querySelectorAll('.sideview-toast').map(function (t) { return t.textContent; });
  };
  const s10_warns = [];
  const s10_origWarn = console.warn;
  console.warn = function () { s10_warns.push(Array.prototype.slice.call(arguments).join(' ')); };

  const s10_a = s10_make({ ns: 'a-' });
  const s10_b = s10_make({ ns: 'b-' });
  const s10_before = wsMessages.length;
  s10_a.el.querySelector('.sideview-sort-btn[data-col-name="val"]').click();
  const s10_sent = wsMessages.slice(s10_before).map(function (m) { return m.event; });
  const s10_gadgetSort = wsMessages.filter(function (m) { return m.event === 'column_sorted'; }).length > 0;

  shinyHandlers.sideview_toast({ ns: 'b-', text: 'hi', type: 'info' });
  const s10_routeA = s10_toasts(s10_a);
  const s10_routeB = s10_toasts(s10_b);

  s10_warns.length = 0;
  let s10_threw = false;
  try { shinyHandlers.sideview_toast({ ns: 'zz-', text: 'lost' }); } catch (e) { s10_threw = true; }
  const s10_warned = s10_warns.length > 0;

  let s10_destroyed = false;
  const s10_oldDestroy = s10_a.engine.destroy;
  s10_a.engine.destroy = function () { s10_destroyed = true; return s10_oldDestroy.apply(this, arguments); };
  const s10_a2 = s10_make({ ns: 'a-' });
  const s10_registry = global.__sideviewEngines;
  const s10_regOk = s10_registry['a-'] === s10_a2.engine && s10_registry['b-'] === s10_b.engine;

  const s10_w = s10_make({ mode: 'embedded' });
  const s10_wKeys = Object.keys(s10_registry);
  shinyHandlers.sideview_toast({ ns: '', text: 'for the gadget' });
  const s10_widgetToasts = s10_toasts(s10_w);

  const s10_m = s10_make({ mode: 'embedded', ns: 'c-' });
  const s10_dataNs = new MockElement('DIV');
  s10_dataNs.className = 'sideview-container';
  s10_dataNs.setAttribute('data-sv-ns', 'd-');
  document.body.appendChild(s10_dataNs);
  const s10_dEngine = global.Sideview.init(s10_dataNs, { cards: s10_card() });

  console.warn = s10_origWarn;
  results.scenario10 = {
    module_input_prefix: s10_sent.indexOf('a-column_sorted') >= 0 && s10_sent.indexOf('column_sorted') < 0,
    gadget_input_unprefixed: s10_gadgetSort && engine.ns === '',
    route_by_ns: s10_routeB.indexOf('hi') >= 0 && s10_routeA.indexOf('hi') < 0,
    unknown_ns_ignored: !s10_threw && s10_warned,
    reregister_destroys_old: s10_destroyed && s10_regOk,
    widget_not_registered: s10_wKeys.every(function (k) { return s10_registry[k] !== s10_w.engine; }) &&
      s10_widgetToasts.indexOf('for the gadget') < 0,
    module_hasR: s10_m.engine.hasR() === true && s10_m.engine.isGadget() === false,
    widget_has_no_R: s10_w.engine.hasR() === false,
    data_attribute_ns: s10_dEngine.ns === 'd-' && s10_registry['d-'] === s10_dEngine,
    gadget_hasR: engine.hasR() === true && engine.isGadget() === true,
    gadget_still_routed: s10_registry[''] === engine
  };
  s10_a2.engine.destroy();
  s10_b.engine.destroy();
  s10_m.engine.destroy();
  s10_dEngine.destroy();
  results.scenario10.destroy_unregisters = !s10_registry['b-'] && !s10_registry['a-'] && !s10_registry['d-'];

  // SCENARIO 11: add / replace / remove cards, state and highlight from R; ready and snapshot (module)
  const s11_labsCard = function (cols, extra) {
    const data = {};
    cols.forEach(function (c) { data[c] = ['a', 'b']; });
    const types = {};
    cols.forEach(function (c) { types[c] = 'character'; });
    return Object.assign({ id: 'card_l1', name: 'labs', type: 'grid', x: 10, y: 10, dims: [2, cols.length],
      data: data, col_types: types, totalRows: 2 }, extra || {});
  };
  const s11_visitsCard = function () {
    return { id: 'card_v1', name: 'visits', type: 'grid', x: 400, y: 10, dims: [2, 2],
      data: { id: ['a', 'b'], visit_dt: ['x', 'y'] }, col_types: { id: 'character', visit_dt: 'character' } };
  };
  const s11_make = function (ns, cards) {
    const el = new MockElement('DIV');
    el.className = 'sideview-container';
    document.body.appendChild(el);
    return { el: el, engine: global.Sideview.init(el, { ns: ns, mode: 'embedded', cards: cards }) };
  };
  const s11_ws = function (name) { return wsMessages.filter(function (m) { return m.event === name; }); };
  const s11_toastTexts = function (m) {
    return m.el.querySelectorAll('.sideview-toast').map(function (t) { return t.textContent; });
  };
  const s11_connect = function (e, t1, c1, t2, c2) {
    const from = e.findPortElement(t1, c1), to = e.findPortElement(t2, c2);
    e.addConnection({ fromCard: from.closest('.sideview-card').dataset.cardId, fromTable: t1, fromCol: c1, fromElement: from,
      toCard: to.closest('.sideview-card').dataset.cardId, toTable: t2, toCol: c2, toElement: to, type: 'left_join' });
  };
  const s11_byName = function (m, name) {
    return Array.from(m.engine.cards.values()).filter(function (c) { return c.name === name; })[0];
  };
  const s11_r = {};
  const s11_origWarn = console.warn;
  const s11_warns = [];
  console.warn = function () { s11_warns.push(Array.prototype.slice.call(arguments).join(' ')); };

  // ready, and a remote card added from R
  const s11_a = s11_make('m-', [s11_labsCard(['id', 'lab_dt', 'val']), s11_visitsCard()]);
  s11_r.module_sends_ready = s11_ws('m-sideview_ready').length === 1 && s11_ws('sideview_ready').length === 0;
  const s11_big = { id: 'card_big', name: 'big', type: 'grid', dims: [5000, 1], totalRows: 5000, remote: true,
    data: { k: Array.from({ length: 500 }, function (_, i) { return i; }) }, col_types: { k: 'integer' } };
  shinyHandlers.sideview_card_add({ ns: 'm-', card: s11_big });
  const s11_bigMeta = s11_byName(s11_a, 'big');
  const s11_bigVt = s11_bigMeta && s11_bigMeta.element._virtualTable;
  s11_r.card_add_remote = !!s11_bigVt && !!s11_bigVt.remote && s11_bigVt.remote.total === 5000 &&
    s11_bigVt.remote.active === true && s11_bigMeta.element.dataset.totalRows === '5000';
  s11_a.engine.destroy();

  // replace: geometry, disabled steps, toast, join checks
  const s11_b = s11_make('m-', [s11_labsCard(['id', 'lab_dt', 'val']), s11_visitsCard()]);
  const s11_be = s11_b.engine;
  const s11_lm = s11_byName(s11_b, 'labs');
  s11_lm.element.style.left = '300px';
  s11_lm.element.style.top = '200px';
  s11_lm.x = 300; s11_lm.y = 200;
  s11_be.pipeline.add({ kind: 'filter', table: 'labs', conds: ['lab_dt > 1'], condCols: ['lab_dt'] });
  s11_be.joinDiag = { stale: { id: 'stale' } };
  shinyHandlers.sideview_card_replace({ ns: 'm-', card: s11_labsCard(['id', 'val']) });
  const s11_lm2 = s11_byName(s11_b, 'labs');
  s11_r.replace_keeps_geometry = !!s11_lm2 && parseFloat(s11_lm2.element.style.left) === 300 &&
    parseFloat(s11_lm2.element.style.top) === 200 && s11_lm2.element !== s11_lm.element &&
    s11_be.cards.size === 2 && !s11_lm.element.parentNode;
  s11_r.replace_disables_step = s11_be.pipeline.steps[0].enabled === false;
  s11_r.replace_toast = s11_toastTexts(s11_b).indexOf('labs refreshed: 1 step disabled (lab_dt not found)') >= 0;
  s11_r.replace_clears_join_checks = !('stale' in s11_be.joinDiag);

  // a spline on a dropped column goes, visually only
  const s11_c = s11_make('m-', [s11_labsCard(['id', 'lab_dt', 'val']), s11_visitsCard()]);
  const s11_ce = s11_c.engine;
  s11_connect(s11_ce, 'labs', 'lab_dt', 'visits', 'visit_dt');
  s11_connect(s11_ce, 'labs', 'id', 'visits', 'id');
  const s11_connBefore = s11_ce.connections.length;
  const s11_discC0 = s11_ws('m-column_disconnected').length;
  shinyHandlers.sideview_card_replace({ ns: 'm-', card: s11_labsCard(['id', 'val']) });
  s11_r.replace_removes_spline_visually = s11_connBefore === 2 && s11_ce.connections.length === 1 &&
    s11_ce.connections[0].fromCol === 'id' &&
    s11_ws('m-column_disconnected').length === s11_discC0 &&
    s11_ce.svg.querySelectorAll('.sideview-connector-path').length === 1 &&
    s11_ce.hitSvg.querySelectorAll('.sideview-connector-hit').length === 1;

  // remove
  const s11_d = s11_make('m-', [s11_labsCard(['id', 'lab_dt', 'val']), s11_visitsCard()]);
  s11_connect(s11_d.engine, 'labs', 'id', 'visits', 'id');
  const s11_discD0 = s11_ws('m-column_disconnected').length;
  shinyHandlers.sideview_card_remove({ ns: 'm-', name: 'labs' });
  s11_r.remove_card = s11_d.engine.cards.size === 1 && !s11_byName(s11_d, 'labs') &&
    s11_d.engine.pipeline.steps.length === 1 && s11_d.engine.pipeline.steps[0].enabled === false &&
    s11_d.engine.connections.length === 0 && s11_ws('m-column_disconnected').length === s11_discD0 &&
    s11_toastTexts(s11_d).indexOf('labs removed: 1 step disabled') >= 0;

  // a card name with markup and quotes stays text and is found by replace / remove
  const s11_hostile = 'a"b <i>x</i>';
  const s11_hcard = function (v) {
    return { id: 'card_h1', name: s11_hostile, type: 'grid', dims: [2, 1], data: { c: v }, col_types: { c: 'numeric' } };
  };
  const s11_e = s11_make('m-', [s11_labsCard(['id', 'val'])]);
  shinyHandlers.sideview_card_add({ ns: 'm-', card: s11_hcard([1, 2]) });
  const s11_hm = function () { return s11_byName(s11_e, s11_hostile); };
  const s11_hTitle = s11_hm() && s11_hm().element.querySelector('.sideview-card-title');
  // the mock DOM keeps entities as typed; a browser decodes them, so decode here to compare
  const s11_decode = function (t) {
    return t.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&');
  };
  const s11_textOk = !!s11_hTitle && s11_decode(s11_hTitle.textContent) === s11_hostile &&
    !s11_hm().element.querySelector('.sideview-card-title i');
  const s11_hEl = s11_hm() && s11_hm().element;
  shinyHandlers.sideview_card_replace({ ns: 'm-', card: s11_hcard([3, 4]) });
  const s11_replaced = !!s11_hm() && s11_hm().element !== s11_hEl;
  shinyHandlers.sideview_card_remove({ ns: 'm-', name: s11_hostile });
  s11_r.hostile_name = s11_textOk && s11_replaced && !s11_hm() && s11_e.engine.cards.size === 1;

  // unknown card, highlight, state
  s11_warns.length = 0;
  let s11_threw = false;
  try {
    shinyHandlers.sideview_card_replace({ ns: 'm-', card: { name: 'nope', type: 'grid', data: { a: [1] } } });
    shinyHandlers.sideview_card_remove({ ns: 'm-', name: 'nope' });
    shinyHandlers.sideview_highlight({ ns: 'm-', name: 'nope', cols: ['a'] });
  } catch (err) { s11_threw = true; }
  s11_r.unknown_card_warns = !s11_threw && s11_warns.length >= 3;
  shinyHandlers.sideview_highlight({ ns: 'm-', name: 'labs', cols: ['val', 'not_a_col'] });
  const s11_lvt = s11_byName(s11_e, 'labs').element._virtualTable;
  s11_r.highlight_columns = s11_lvt.highlightedColumns.get('val') === 'blue' && !s11_lvt.highlightedColumns.has('not_a_col');
  s11_e.engine.selectedColor = 'green';
  shinyHandlers.sideview_highlight({ ns: 'm-', name: 'labs', cols: ['id'] });
  s11_r.highlight_uses_swatch = s11_lvt.highlightedColumns.get('id') === 'green';
  const s11_st = { version: '0.3.0', canvas: { zoom: 1, pan_x: 0, pan_y: 0 },
    cards: [{ name: 'labs', x: 123, y: 77 }], connections: [],
    pipeline: { steps: [{ id: 's_x', kind: 'filter', table: 'labs', conds: ['id == 1'], enabled: true }], pipe: '%>%' } };
  s11_e.engine.pipeline.add({ kind: 'arrange', table: 'labs', cols: [{ col: 'id', dir: 'asc' }] });
  shinyHandlers.sideview_state_set({ ns: 'm-', state: JSON.stringify(s11_st) });
  s11_r.state_set = parseFloat(s11_byName(s11_e, 'labs').element.style.left) === 123 &&
    s11_e.engine.pipeline.steps.length === 1 && s11_e.engine.pipeline.steps[0].kind === 'filter' &&
    !s11_e.engine.pipeline.canUndo();

  // Save / Open / codebook in a module
  const s11_sv0 = s11_ws('m-state_save').length;
  s11_e.engine.saveWorkspace();
  s11_r.module_save_is_browser = s11_ws('m-state_save').length === s11_sv0 && s11_ws('state_save').length === 0 &&
    typeof s11_e.engine.lastStateJson === 'string';
  s11_e.engine.exportCodebook();
  s11_r.module_codebook_asks_r = s11_ws('m-codebook_export').length === 1;
  shinyHandlers.sideview_codebook_saved({ ns: 'm-', csv: 'a,b\n1,2', filename: 'codebook.csv' });
  s11_r.codebook_csv_downloads = s11_e.engine.lastCodebookCsv === 'a,b\n1,2';

  // a pruned (disconnected) engine is destroyed, not just forgotten
  const s11_p = s11_make('p-', [s11_labsCard(['id'])]);
  let s11_pDestroyed = false;
  const s11_pOld = s11_p.engine.destroy;
  s11_p.engine.destroy = function () { s11_pDestroyed = true; return s11_pOld.apply(this, arguments); };
  s11_p.el.isConnected = false;
  shinyHandlers.sideview_toast({ ns: 'm-', text: 'x' });
  s11_r.prune_destroys_engine = s11_pDestroyed && !global.__sideviewEngines['p-'];

  // a lazy card R serves whole (remote) is not labelled a preview; the widget's lazy card still is
  const s11_lazyCard = function (id, name, extra) {
    return Object.assign({ id: id, name: name, type: 'grid', lazy: 'duckdb', dims: [1000, 1], totalRows: 1000,
      data: { k: Array.from({ length: 50 }, function (_, i) { return i; }) }, col_types: { k: 'integer' } }, extra || {});
  };
  const s11_g = s11_make('m-', [s11_labsCard(['id', 'val'])]);
  shinyHandlers.sideview_card_add({ ns: 'm-', card: s11_lazyCard('card_lzr', 'lz_remote', { remote: true }) });
  shinyHandlers.sideview_card_add({ ns: 'm-', card: s11_lazyCard('card_lzw', 'lz_widget') });
  const s11_lzr = s11_byName(s11_g, 'lz_remote').element;
  const s11_lzw = s11_byName(s11_g, 'lz_widget').element;
  const s11_badge = function (el) { return el.querySelector('.sideview-badge-dims').textContent; };
  s11_r.remote_lazy_is_full = s11_lzr.dataset.rowsBasis === 'full' && s11_badge(s11_lzr).indexOf('First') < 0 &&
    s11_badge(s11_lzr) === '1,000 \u00d7 1' && s11_lzr.dataset.lazy === 'duckdb' && s11_lzr.dataset.tableRows === '1000';
  s11_r.widget_lazy_is_preview = s11_lzw.dataset.rowsBasis === 'preview' && s11_badge(s11_lzw) === 'First 50 of 1,000 rows';
  // a row-capped data-frame card (max_rows) is labelled a preview, but is not a lazy table
  shinyHandlers.sideview_card_add({ ns: 'm-', card: s11_lazyCard('card_trc', 'trunc_widget', { lazy: undefined, truncated: true }) });
  const s11_trc = s11_byName(s11_g, 'trunc_widget').element;
  s11_r.truncated_card_is_preview = s11_trc.dataset.rowsBasis === 'preview' && s11_badge(s11_trc) === 'First 50 of 1,000 rows' &&
    s11_trc.dataset.lazy === undefined && s11_trc.dataset.truncated === 'true' && s11_trc.dataset.previewRows === '50';
  // a lost link (toast with `card`) then downgrades the remote card to the preview label
  shinyHandlers.sideview_toast({ ns: 'm-', text: 'link lost', type: 'warning', card: 'card_lzr' });
  s11_r.remote_lazy_lost_link_downgrades = s11_lzr.dataset.rowsBasis === 'preview' &&
    s11_badge(s11_lzr).indexOf('First') === 0;
  s11_g.engine.destroy();

  // replace keeps the header sort and filter on columns that stay, and the view of a dropped column goes
  const s11_vcard = function (cols) {
    const data = {}, types = {};
    cols.forEach(function (c) { data[c] = ['c', 'a', 'b']; types[c] = 'character'; });
    return { id: 'card_vw', name: 'vw', type: 'grid', x: 10, y: 10, dims: [3, cols.length], data: data, col_types: types, totalRows: 3 };
  };
  const s11_h = s11_make('m-', [s11_vcard(['id', 'val', 'extra'])]);
  const s11_hc = s11_byName(s11_h, 'vw').element;
  s11_hc.querySelector('.sideview-sort-btn[data-col-name="val"]').click();
  const s11_fb = s11_hc.querySelector('.sideview-filter-btn[data-col-name="id"]');
  s11_fb.click();
  const s11_pop = document.querySelector('.sideview-filter-popover');
  s11_pop.querySelector('.sideview-filter-select').value = 'contains';
  s11_pop.querySelector('.sideview-filter-input').value = 'a';
  s11_pop.querySelector('.sideview-filter-apply').click();
  const s11_hv0 = s11_byName(s11_h, 'vw').element._virtualTable;
  const s11_hSetup = !!s11_hv0.sortState && s11_hv0.sortState.colName === 'val' && s11_hv0.sortState.direction === 'asc' &&
    !!s11_hv0.currentFilter && s11_hv0.currentFilter.colName === 'id';
  shinyHandlers.sideview_card_replace({ ns: 'm-', card: s11_vcard(['id', 'val', 'extra']) });
  const s11_hn = s11_byName(s11_h, 'vw').element;
  const s11_hv = s11_hn._virtualTable;
  const s11_hth = s11_hn.querySelector('th[data-col-name="val"]');
  s11_r.replace_keeps_sort_filter = s11_hSetup && s11_hn !== s11_hc && s11_hv.sortState.colName === 'val' &&
    s11_hv.sortState.direction === 'asc' && s11_hth.dataset.sortState === 'asc' &&
    s11_hn.querySelector('.sideview-sort-btn[data-col-name="val"]').classList.contains('active') &&
    s11_hv.currentFilter.colName === 'id' && s11_hv.currentFilter.operator === 'contains' &&
    s11_hn.querySelector('.sideview-filter-btn[data-col-name="id"]').classList.contains('active');
  // the sort column is dropped: no sort on the new card, and no error
  let s11_hThrew = false;
  try { shinyHandlers.sideview_card_replace({ ns: 'm-', card: s11_vcard(['id', 'extra']) }); } catch (err) { s11_hThrew = true; }
  const s11_hv2 = s11_byName(s11_h, 'vw').element._virtualTable;
  s11_r.replace_drops_view_of_dropped_column = !s11_hThrew && !(s11_hv2.sortState && s11_hv2.sortState.colName) &&
    !!s11_hv2.currentFilter && s11_hv2.currentFilter.colName === 'id';
  s11_h.engine.destroy();

  // a mutate step that uses a dropped column is disabled by a replace; one that does not is kept
  const s11_k = s11_make('m-', [s11_labsCard(['id', 'lab_dt', 'val'])]);
  s11_k.engine.pipeline.add({ kind: 'mutate', table: 'labs', name: 'dbl', expr: 'val * 2' });
  s11_k.engine.pipeline.add({ kind: 'mutate', table: 'labs', name: 'yr', expr: 'format(lab_dt, "%Y") # lab_dt' });
  shinyHandlers.sideview_card_replace({ ns: 'm-', card: s11_labsCard(['id', 'val']) });
  s11_r.replace_disables_mutate = s11_k.engine.pipeline.steps[0].enabled !== false &&
    s11_k.engine.pipeline.steps[1].enabled === false &&
    s11_toastTexts(s11_k).indexOf('labs refreshed: 1 step disabled (lab_dt not found)') >= 0;
  s11_k.engine.destroy();

  // an engine whose setup throws never takes the place of a working one
  const s11_z = s11_make('z-', [s11_labsCard(['id'])]);
  let s11_zDestroyed = false;
  const s11_zOld = s11_z.engine.destroy;
  s11_z.engine.destroy = function () { s11_zDestroyed = true; return s11_zOld.apply(this, arguments); };
  const s11_zel = new MockElement('DIV');
  s11_zel.className = 'sideview-container';
  document.body.appendChild(s11_zel);
  let s11_zThrew = false;
  try {
    global.Sideview.init(s11_zel, { ns: 'z-', mode: 'embedded', cards: [{ get name() { throw new Error('bad card'); } }] });
  } catch (err) { s11_zThrew = true; }
  s11_r.failed_init_keeps_registry = s11_zThrew && !s11_zDestroyed && global.__sideviewEngines['z-'] === s11_z.engine;
  s11_z.engine.destroy();

  console.warn = s11_origWarn;
  results.scenario11 = s11_r;
  s11_c.engine.destroy();
  s11_d.engine.destroy();
  s11_b.engine.destroy();

  // SCENARIO 12: CDISC badge, header label titles, tag updates, search, inspector, codebook domain
  const s12_r = {};
  const s12_warns = [];
  console.warn = function () { s12_warns.push(Array.prototype.slice.call(arguments).join(' ')); };
  const s12_tag = { domain: 'AE', label: 'Adverse Events', class: 'Events', standard: 'SDTM', parent: null,
    evidence: ['DOMAIN column is AE', 'name matches AE'], source: 'auto' };
  const s12_aeCard = {
    id: 'card_ae', name: 'ae', type: 'grid', x: 10, y: 10, dims: [2, 2],
    data: { USUBJID: ['a', 'b'], AETERM: ['x', 'y'] }, col_types: { USUBJID: 'character', AETERM: 'character' },
    col_labels: { USUBJID: 'Unique Subject Identifier', AETERM: '<img src=x onerror=alert(2)>' }, cdisc: s12_tag
  };
  const s12_hostileTag = Object.assign({}, s12_tag, { domain: 'ZZ', label: '<img src=x onerror=alert(1)>', standard: 'ADaM' });
  const s12_plain = { id: 'card_pl', name: 'plain', type: 'grid', x: 400, y: 10, dims: [2, 1],
    data: { id: ['a', 'b'] }, col_types: { id: 'character' } };
  const s12_hostile = { id: 'card_hz', name: 'hz', type: 'grid', x: 800, y: 10, dims: [2, 1],
    data: { id: ['a', 'b'] }, col_types: { id: 'character' }, cdisc: s12_hostileTag };
  const s12 = s11_make('c-', [s12_aeCard, s12_plain, s12_hostile]);
  const s12e = s12.engine;
  const s12_ae = s11_byName(s12, 'ae').element;
  const s12_bd = s12_ae.querySelector('.sideview-badge-cdisc');
  s12_r.badge_text = !!s12_bd && s12_bd.textContent === 'AE';
  s12_r.badge_class = !!s12_bd && s12_bd.classList.contains('sv-cdisc-sdtm');
  s12_r.badge_title = !!s12_bd && s12_bd.title ===
    'Adverse Events · SDTM Events\nDOMAIN column is AE\nname matches AE';
  s12_r.dataset_domain = s12_ae.dataset.cdiscDomain === 'AE' && s12e.cardDomain('ae') === 'AE';
  s12_r.untagged_has_no_badge = !s11_byName(s12, 'plain').element.querySelector('.sideview-badge-cdisc') &&
    s12e.cardDomain('plain') === null;
  const s12_hb = s11_byName(s12, 'hz').element.querySelector('.sideview-badge-cdisc');
  s12_r.hostile_label_is_text = !!s12_hb && s12_hb.classList.contains('sv-cdisc-adam') &&
    s12_hb.title.indexOf('<img src=x onerror=alert(1)> · ADaM Events') === 0 &&
    !s11_byName(s12, 'hz').element.querySelector('img');
  s12_r.header_label_title = s12_ae.querySelector('th[data-col-name="USUBJID"]').title === 'Unique Subject Identifier' &&
    s12_ae.querySelector('th[data-col-name="AETERM"]').title === '<img src=x onerror=alert(2)>' &&
    !s12_ae.querySelector('img');
  // search: domain and dataset label, and a hit on the card (not a column)
  const s12_hit = s12e.searchCards('adverse').filter(function (h) { return h.name === 'ae' && h.col === null; })[0];
  s12_r.search_label = !!s12_hit && s12_hit.rank === 1;
  s12_r.search_dims_not_domain = !!s12_hit && s12_hit.dims === '2 × 2';
  s12_r.search_domain = s12e.searchCards('zz').some(function (h) { return h.name === 'hz' && h.col === null; });
  s12_r.search_name_prefix_first = s12e.searchCards('ae')[0].name === 'ae' && s12e.searchCards('ae')[0].rank === 0;
  // tag update: a new tag, then a user-cleared one
  s12_warns.length = 0;
  let s12_threw = false;
  try {
    shinyHandlers.sideview_cdisc_update({ ns: 'c-', tags: { nope: { domain: 'AE' }, card_pl: { domain: 'LB',
      label: 'Laboratory', class: 'Findings', standard: 'SDTM', parent: null, evidence: 'name matches LB' } } });
    shinyHandlers.sideview_cdisc_update({ ns: 'c-' });
  } catch (err) { s12_threw = true; }
  const s12_pl = s11_byName(s12, 'plain').element;
  s12_r.update_adds_badge = !s12_threw && !!s12_pl.querySelector('.sideview-badge-cdisc') &&
    s12_pl.querySelector('.sideview-badge-cdisc').textContent === 'LB' && s12_pl.dataset.cdiscDomain === 'LB' &&
    s12_pl.querySelector('.sideview-badge-cdisc').title === 'Laboratory · SDTM Findings\nname matches LB';
  s12_r.update_unknown_card_quiet = !s12_threw && s12_warns.length === 0;
  shinyHandlers.sideview_cdisc_update({ ns: 'c-', tags: { card_ae: null } });
  s12_r.null_removes_badge = !s12_ae.querySelector('.sideview-badge-cdisc') && s12_ae.dataset.cdiscDomain === undefined &&
    s12e.cardDomain('ae') === null && s11_byName(s12, 'ae').cdisc === null;
  s12_r.cleared_not_searchable = !s12e.searchCards('adverse').some(function (h) { return h.name === 'ae'; });
  // inspector: dataset line under the card, and the column label
  s12_r.inspector_dataset_line = s12e.inspectorDatasetHtml('plain') ===
    '<p class="sideview-inspect-dataset">LB · Laboratory</p>' && s12e.inspectorDatasetHtml('ae') === '' &&
    s12e.inspectorDatasetHtml('hz').indexOf('&lt;img') > 0 && s12e.inspectorDatasetHtml('hz').indexOf('<img') < 0;
  // the codebook export reads the domain through cardDomain()
  s12_r.codebook_domain_source = s12e.cardDomain('plain') === 'LB';
  const s12_gad = new MockElement('DIV');
  s12_gad.className = 'sideview-container';
  const s12_gc = new MockElement('DIV');
  s12_gc.className = 'sideview-card';
  s12_gc.dataset.cardId = 'card_g'; s12_gc.dataset.cardName = 'g';
  s12_gc.setAttribute('data-cdisc', JSON.stringify(s12_hostileTag));
  s12_gc.setAttribute('data-col-labels', JSON.stringify({ id: '<img src=x onerror=alert(3)>' }));
  const s12_gh = new MockElement('DIV'); s12_gh.className = 'sideview-card-header';
  const s12_gg = new MockElement('DIV'); s12_gg.className = 'sideview-card-title-group';
  const s12_gt = new MockElement('SPAN'); s12_gt.className = 'sideview-card-title'; s12_gt.textContent = 'g';
  s12_gg.appendChild(s12_gt); s12_gh.appendChild(s12_gg); s12_gc.appendChild(s12_gh);
  s12e.renderCdiscBadge({ element: s12_gc, cdisc: parseGad(s12_gc) });
  function parseGad(el) { return JSON.parse(el.getAttribute('data-cdisc')); }
  const s12_gb = s12_gc.querySelector('.sideview-badge-cdisc');
  s12_r.gadget_attr_hostile_is_text = !!s12_gb && s12_gb.title.indexOf('<img') === 0 && !s12_gc.querySelector('img');
  s12e.destroy();
  console.warn = s11_origWarn;
  results.scenario12 = s12_r;

  // SCENARIO 13: L toggles the variable-label row; saved in state as view.labels_row
  const s13_r = {};
  const s13 = s11_make('l-', [
    { id: 'card_ae', name: 'ae', type: 'grid', x: 10, y: 10, dims: [2, 2],
      data: { USUBJID: ['a', 'b'], AETERM: ['x', 'y'] }, col_types: { USUBJID: 'character', AETERM: 'character' },
      col_labels: { USUBJID: 'Unique Subject Identifier', AETERM: '<img src=x onerror=alert(2)>' } },
    { id: 'card_pl', name: 'plain', type: 'grid', x: 400, y: 10, dims: [2, 1],
      data: { id: ['a', 'b'] }, col_types: { id: 'character' } }
  ]);
  const s13e = s13.engine;
  const s13_ae = s11_byName(s13, 'ae').element;
  const s13_pl = s11_byName(s13, 'plain').element;
  s13_r.off_by_default = !s13_ae.querySelector('.sv-label-row') && s13e.getState().view.labels_row === false;
  const s13_fire = function (el, props) {
    const ev = new MockEvent('keydown', Object.assign({ bubbles: true }, props));
    Object.assign(ev, props);
    el.dispatchEvent(ev);
  };
  const s13_ai = new MockElement('INPUT'); s13_ai.type = 'text'; s13_ai.className = 'sideview-ai-input';
  s13.el.appendChild(s13_ai);
  document.activeElement = s13.el;
  s13_fire(s13.el, { key: 'L' });
  s13_r.l_shows_row = !!s13_ae.querySelector('.sv-label-row') && s13e.getState().view.labels_row === true;
  s13_r.label_cell_text = s13_ae.querySelectorAll('.sv-label-cell').length === 2 &&
    s13_ae.querySelectorAll('.sv-label-cell')[0].textContent === 'Unique Subject Identifier' &&
    s13_ae.querySelectorAll('.sv-label-cell')[0].title === 'Unique Subject Identifier';
  s13_r.hostile_label_is_text = !s13_ae.querySelector('img') &&
    s13_ae.querySelectorAll('.sv-label-cell')[1].textContent === '<img src=x onerror=alert(2)>';
  s13_r.no_labels_no_row = !s13_pl.querySelector('.sv-label-row');
  s13_fire(s13.el, { key: 'l' });
  s13_r.l_hides_row = !s13_ae.querySelector('.sv-label-row') && s13e.getState().view.labels_row === false;
  // typing in the AI input does not toggle
  document.activeElement = s13_ai;
  s13_fire(s13_ai, { key: 'L' });
  document.activeElement = s13.el;
  s13_r.typing_ignored = !s13_ae.querySelector('.sv-label-row');
  s13e.applyState({ view: { labels_row: true } });
  s13_r.apply_state_shows = !!s13_ae.querySelector('.sv-label-row') && s13e.getState().view.labels_row === true;
  s13e.applyState({ cards: [] });
  s13_r.state_without_view_keeps = !!s13_ae.querySelector('.sv-label-row');
  s13_r.no_duplicate_row = s13e.toggleLabelsRow(true) === true && s13_ae.querySelectorAll('.sv-label-row').length === 1;
  s13_r.toggle_returns_bool = s13e.toggleLabelsRow(false) === false && !s13_ae.querySelector('.sv-label-row');
  s13e.toggleShortcuts(true);
  s13_r.shortcut_listed = (s13.el.textContent || '').indexOf('Show or hide variable labels') >= 0;
  s13e.destroy();
  results.scenario13 = s13_r;

  // snapshots wait for the debounce, so they finish after the synchronous scenarios
  results.__later = function () {
    const sleep = function (ms) { return new Promise(function (res) { setTimeout(res, ms); }); };
    const f = s11_make('s-', [s11_labsCard(['id', 'val']), s11_visitsCard()]);
    return sleep(400).then(function () {
      const base = s11_ws('s-sideview_snapshot').length;
      f.engine.pipeline.add({ kind: 'filter', table: 'labs', conds: ['id == 1'], condCols: ['id'] });
      f.engine.pipeline.add({ kind: 'arrange', table: 'labs', cols: [{ col: 'id', dir: 'asc' }] });
      f.engine.pipeline.setJoinCheck('sig', { relationship: 'one-to-one' });
      return sleep(100).then(function () {
        f.engine.pipeline.add({ kind: 'arrange', table: 'visits', cols: [{ col: 'id', dir: 'asc' }] });
        return sleep(350);
      }).then(function () {
        const snaps = s11_ws('s-sideview_snapshot').slice(base);
        const v = snaps.length ? snaps[snaps.length - 1].value : null;
        let st = null, steps = null;
        try { st = JSON.parse(v.state); steps = JSON.parse(v.pipeline); } catch (err) {}
        results.scenario11.snapshot_debounced = snaps.length === 1 && !!st && st.cards.length === 2 &&
          Array.isArray(steps) && steps.length === 3 && typeof v.code === 'string' && v.code.indexOf('arrange') >= 0 &&
          JSON.stringify(v.cards) === JSON.stringify(['labs', 'visits']);
        const n = s11_ws('s-sideview_snapshot').length;
        f.engine.pipeline.setJoinCheck('sig2', { relationship: 'one-to-one' });
        return sleep(400).then(function () {
          results.scenario11.snapshot_skips_checks = s11_ws('s-sideview_snapshot').length === n;
          f.engine.pipeline.clear();
          return sleep(400);
        }).then(function () {
          const last = s11_ws('s-sideview_snapshot').pop().value;
          results.scenario11.snapshot_empty_code = last.code === '';
          f.engine.destroy();
          results.scenario11.gadget_no_snapshot = s11_ws('sideview_snapshot').length === 0 &&
            s11_ws('sideview_ready').length === 0;
        });
      });
    });
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
const later = out.__later;
delete out.__later;
Promise.resolve(later ? later() : null).then(function () {
  console.log(JSON.stringify(out, null, 2));
});
