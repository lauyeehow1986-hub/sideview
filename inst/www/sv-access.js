/*!
 * sv-access.js - the keyboard model of sideview's Accessible canvas (spec section 5).
 *
 * SideviewAccess(engine) is created by the engine (sideview.js) and only acts while the
 * Accessible canvas switch is on (engine.accessOn()). With the switch off it sets nothing and
 * every key goes on as before.
 *
 * On: every card is a Tab stop (tabindex="0", role="group", aria-label = card name) in reading
 * order (top-to-bottom, then left-to-right), its header buttons are Tab stops only while focus is
 * inside that card, and the column-header buttons stay out of the Tab order (Task 7 opens the
 * focused header's own buttons). A focused card takes:
 *   Arrows           move 20 px          Shift+Arrows  move 100 px
 *   JUMP_MODS+Arrows focus the nearest card in that direction
 *   PageUp / PageDown / Home / End  scroll the card's table body
 * Moves send one sideview_card_moved and announce "<name> moved." after a 500 ms pause.
 * Every attribute set here, and the card order in the DOM, is put back by disable().
 */
(function (global) {
  'use strict';

  // The modifiers of the card jump. 'alt' is Alt+Arrows; change to 'ctrl+alt' if a host
  // navigates Back on Alt+Left despite preventDefault().
  var JUMP_MODS = 'alt';
  var STEP = 20;
  var BIG_STEP = 100;
  var PAUSE_MS = 500;
  var MARGIN = 24;

  var DIRS = {
    ArrowLeft: { x: -1, y: 0 }, ArrowRight: { x: 1, y: 0 },
    ArrowUp: { x: 0, y: -1 }, ArrowDown: { x: 0, y: 1 }
  };
  var SCROLL_KEYS = { PageUp: 1, PageDown: 1, Home: 1, End: 1 };

  function modsMatch(e, mods) {
    var want = String(mods).toLowerCase().split('+');
    return !!e.altKey === (want.indexOf('alt') >= 0) &&
      !!e.ctrlKey === (want.indexOf('ctrl') >= 0) &&
      !!e.shiftKey === (want.indexOf('shift') >= 0) &&
      !e.metaKey;
  }

  function isCard(el) {
    return !!(el && el.classList && el.classList.contains('sideview-card'));
  }

  function num(v) {
    var n = parseFloat(v);
    return isFinite(n) ? n : 0;
  }

  function fmt(n) {
    return Number(n).toLocaleString('en-US');
  }

  function SideviewAccess(engine) {
    var self = this;
    this.engine = engine;
    this.container = engine.container;
    this.on = false;
    this._touched = [];        // elements whose attributes were set; originals in el._svAccOrig
    this._origOrder = null;    // the viewport's card order before enable()
    this._pending = null;      // { card, meta } of a move waiting for its pause
    this._moveTimer = null;
    this._orderTimer = null;
    this._observer = null;
    this._decorateQueued = false;

    this._onKeyDown = function (e) { self.handleKeyDown(e); };
    this._onFocusIn = function (e) { self.handleFocusIn(e); };
    this._onFocusOut = function (e) { self.handleFocusOut(e); };
    this._onPointerUp = function () {
      if (!self.on) return;
      if (self._orderTimer) clearTimeout(self._orderTimer);
      // after the click that ends a drag, so a card is never moved in the DOM mid-click
      self._orderTimer = setTimeout(function () { self._orderTimer = null; self.syncOrder(); }, 0);
    };
    this.container.addEventListener('keydown', this._onKeyDown);
    this.container.addEventListener('focusin', this._onFocusIn);
    this.container.addEventListener('focusout', this._onFocusOut);
    this.container.addEventListener('pointerup', this._onPointerUp);
    this._unsub = engine.onAccessChange(function (on) {
      if (on) self.enable(); else self.disable();
    });
    if (engine.accessOn()) this.enable();
  }

  SideviewAccess.JUMP_MODS = JUMP_MODS;
  SideviewAccess.prototype.JUMP_MODS = JUMP_MODS;

  // ---- attributes, set and put back exactly ----

  SideviewAccess.prototype._set = function (el, name, value) {
    var orig = el._svAccOrig;
    if (!orig) {
      orig = el._svAccOrig = {};
      this._touched.push(el);
    }
    if (!Object.prototype.hasOwnProperty.call(orig, name)) {
      orig[name] = el.hasAttribute(name) ? el.getAttribute(name) : null;
    }
    if (el.getAttribute(name) !== value) el.setAttribute(name, value);
  };

  SideviewAccess.prototype._reset = function (el, name) {
    var orig = el._svAccOrig;
    if (!orig || !Object.prototype.hasOwnProperty.call(orig, name)) return;
    var v = orig[name];
    delete orig[name];
    if (v === null) el.removeAttribute(name); else el.setAttribute(name, v);
  };

  SideviewAccess.prototype._restoreAll = function () {
    var list = this._touched;
    this._touched = [];
    for (var i = 0; i < list.length; i++) {
      var el = list[i], orig = el._svAccOrig;
      if (!orig) continue;
      Object.keys(orig).forEach(function (name) {
        if (orig[name] === null) el.removeAttribute(name); else el.setAttribute(name, orig[name]);
      });
      el._svAccOrig = null;
    }
  };

  // ---- cards ----

  SideviewAccess.prototype.cardEls = function () {
    var out = [], c = this.container;
    this.engine.cards.forEach(function (m) {
      if (m && m.element && c.contains(m.element)) out.push(m.element);
    });
    return out;
  };

  SideviewAccess.prototype.metaFor = function (cardEl) {
    var found = null;
    this.engine.cards.forEach(function (m) { if (m && m.element === cardEl) found = m; });
    return found;
  };

  SideviewAccess.prototype.cardName = function (cardEl) {
    var m = this.metaFor(cardEl);
    return (m && m.name) || cardEl.getAttribute('data-card-name') || '';
  };

  // "<name>, <rows> rows, <cols> columns." (the true row count where the card knows it)
  SideviewAccess.prototype.cardSentence = function (cardEl) {
    if (!cardEl) return '';
    var d = cardEl.dataset || {};
    var vt = cardEl._virtualTable;
    var rows = d.tableRows != null && d.tableRows !== '' ? Number(d.tableRows)
      : (d.totalRows != null && d.totalRows !== '' ? Number(d.totalRows) : (vt ? vt.totalRows : NaN));
    var cols = cardEl.querySelectorAll('thead th[data-col-name]').length ||
      (vt && vt.colNames ? vt.colNames.length : 0);
    var rowText = isFinite(rows) ? fmt(rows) + (rows === 1 ? ' row' : ' rows') : 'unknown rows';
    return this.cardName(cardEl) + ', ' + rowText + ', ' + fmt(cols) + (cols === 1 ? ' column.' : ' columns.');
  };

  SideviewAccess.prototype.headerButtons = function (cardEl) {
    var h = cardEl.querySelector('.sideview-card-header');
    return h ? h.querySelectorAll('button, a[href], input, select, [tabindex]') : [];
  };

  // Header buttons are Tab stops only while focus is inside their card.
  SideviewAccess.prototype.setActive = function (cardEl, active) {
    var btns = this.headerButtons(cardEl);
    for (var i = 0; i < btns.length; i++) {
      if (active) this._reset(btns[i], 'tabindex'); else this._set(btns[i], 'tabindex', '-1');
    }
  };

  SideviewAccess.prototype.decorate = function () {
    if (!this.on) return;
    var self = this;
    var active = global.document ? global.document.activeElement : null;
    // forget elements that left the page
    this._touched = this._touched.filter(function (el) { return el.isConnected !== false; });
    this.cardEls().forEach(function (card) {
      self._set(card, 'tabindex', '0');
      self._set(card, 'role', 'group');
      self._set(card, 'aria-label', self.cardName(card));
      var thBtns = card.querySelectorAll('thead button, thead [tabindex]');
      for (var i = 0; i < thBtns.length; i++) self._set(thBtns[i], 'tabindex', '-1');
      // the table body is not a Tab stop (Chrome makes a scroller without focusable children one)
      var body = card.querySelector('.sideview-card-body');
      if (body) self._set(body, 'tabindex', '-1');
      self.setActive(card, !!(active && card.contains(active)));
    });
  };

  SideviewAccess.prototype.scheduleDecorate = function () {
    var self = this;
    if (this._decorateQueued || !this.on) return;
    this._decorateQueued = true;
    Promise.resolve().then(function () {
      self._decorateQueued = false;
      self.decorate();
    });
  };

  // ---- reading order (top-to-bottom, then left-to-right) ----

  SideviewAccess.prototype.viewportCards = function () {
    var vp = this.engine.viewport;
    if (!vp) return [];
    var out = [];
    for (var n = vp.firstElementChild; n; n = n.nextElementSibling) if (isCard(n)) out.push(n);
    return out;
  };

  // Put the cards in `list` in that order in the DOM. The card holding focus is never moved
  // (moving it would blur it); the others are placed around it, keeping their body scroll.
  SideviewAccess.prototype.applyOrder = function (list) {
    var cur = this.viewportCards();
    if (cur.length !== list.length) return;
    var same = true;
    for (var i = 0; i < cur.length; i++) if (cur[i] !== list[i]) { same = false; break; }
    if (same) return;
    var vp = this.engine.viewport;
    var active = global.document ? global.document.activeElement : null;
    var k = 0;
    for (var j = 0; j < list.length; j++) if (active && list[j].contains(active)) { k = j; break; }
    var anchor = list[k];
    var scrolls = list.map(function (c) {
      var b = c.querySelector('.sideview-card-body');
      return b ? { b: b, t: b.scrollTop, l: b.scrollLeft } : null;
    });
    for (var a = 0; a < k; a++) vp.insertBefore(list[a], anchor);
    var ref = anchor;
    for (var z = k + 1; z < list.length; z++) {
      vp.insertBefore(list[z], ref.nextSibling);
      ref = list[z];
    }
    scrolls.forEach(function (s) {
      if (!s) return;
      if (s.b.scrollTop !== s.t) s.b.scrollTop = s.t;
      if (s.b.scrollLeft !== s.l) s.b.scrollLeft = s.l;
    });
  };

  SideviewAccess.prototype.syncOrder = function () {
    if (!this.on) return;
    var list = this.viewportCards().map(function (c, i) {
      return { el: c, top: num(c.style.top), left: num(c.style.left), i: i };
    });
    list.sort(function (p, q) { return p.top - q.top || p.left - q.left || p.i - q.i; });
    this.applyOrder(list.map(function (p) { return p.el; }));
  };

  SideviewAccess.prototype.restoreOrder = function () {
    var orig = this._origOrder || [];
    this._origOrder = null;
    var cur = this.viewportCards();
    var desired = orig.filter(function (c) { return cur.indexOf(c) >= 0; });
    cur.forEach(function (c) { if (desired.indexOf(c) < 0) desired.push(c); });
    this.applyOrder(desired);
  };

  // ---- switch ----

  SideviewAccess.prototype.enable = function () {
    if (this.on) { this.decorate(); return; }
    var self = this;
    this.on = true;
    this._origOrder = this.viewportCards();
    this.decorate();
    this.syncOrder();
    if (typeof global.MutationObserver === 'function') {
      this._observer = new global.MutationObserver(function (muts) {
        for (var i = 0; i < muts.length; i++) {
          var t = muts[i].target;
          // row windows of the virtual tables re-render all the time: not a card change
          if (t && t.closest && t.closest('tbody')) continue;
          self.scheduleDecorate();
          return;
        }
      });
      if (this.engine.viewport) this._observer.observe(this.engine.viewport, { childList: true, subtree: true });
      if (this.engine.overlay) this._observer.observe(this.engine.overlay, { childList: true, subtree: true });
    }
  };

  SideviewAccess.prototype.disable = function () {
    if (!this.on) return;
    this.cancelConnect(true);
    this.flushMove();
    this.on = false;
    if (this._observer) { this._observer.disconnect(); this._observer = null; }
    if (this._orderTimer) { clearTimeout(this._orderTimer); this._orderTimer = null; }
    var active = global.document ? global.document.activeElement : null;
    if (isCard(active) && this.container.contains(active)) {
      try { this.container.focus({ preventScroll: true }); } catch (e) { this.container.focus(); }
    }
    this.restoreOrder();
    this._restoreAll();
  };

  SideviewAccess.prototype.destroy = function () {
    if (this._moveTimer) { clearTimeout(this._moveTimer); this._moveTimer = null; }
    this._pending = null;
    if (this.on) this.disable();
    if (this._unsub) { this._unsub(); this._unsub = null; }
    this.container.removeEventListener('keydown', this._onKeyDown);
    this.container.removeEventListener('focusin', this._onFocusIn);
    this.container.removeEventListener('focusout', this._onFocusOut);
    this.container.removeEventListener('pointerup', this._onPointerUp);
  };

  // Connecting columns by keyboard is Task 7's; switching off mid-connect cancels it.
  SideviewAccess.prototype.cancelConnect = function (silent) {
    return false;
  };

  // ---- focus ----

  SideviewAccess.prototype.handleFocusIn = function (e) {
    if (!this.on) return;
    var t = e.target;
    var self = this;
    this.cardEls().forEach(function (card) { self.setActive(card, card.contains(t)); });
    if (isCard(t)) {
      var visible = true;
      try { visible = t.matches(':focus-visible'); } catch (err) { visible = true; }
      // keyboard focus pans the card into view; a mouse click on a card does not move the view
      if (visible) this.ensureVisible(t);
    }
  };

  SideviewAccess.prototype.handleFocusOut = function (e) {
    if (!this.on) return;
    var t = e.target;
    var card = t && t.closest ? t.closest('.sideview-card') : null;
    if (!card) return;
    var next = e.relatedTarget;
    if (!next || !card.contains(next)) this.setActive(card, false);
  };

  SideviewAccess.prototype.focusCard = function (cardEl) {
    try { cardEl.focus({ preventScroll: true }); } catch (e) { cardEl.focus(); }
    this.ensureVisible(cardEl);
  };

  // The part of the container a card can be seen in: below the top chrome, above the AI bar,
  // and clear of the open drawer and the minimap (each cut off on the side that keeps most room).
  SideviewAccess.prototype.safeRect = function () {
    var eng = this.engine;
    var c = this.container.getBoundingClientRect();
    var s = { l: c.left, t: c.top + eng.chromeTop(), r: c.right, b: c.bottom - eng.chromeBottom() };
    var obstacles = this.container.querySelectorAll('.sideview-drawer:not(.collapsed), .sideview-minimap');
    for (var i = 0; i < obstacles.length; i++) {
      var el = obstacles[i];
      if (!el.offsetWidth || !el.offsetHeight) continue;
      var cs = global.getComputedStyle ? global.getComputedStyle(el) : null;
      if (cs && (cs.display === 'none' || cs.visibility === 'hidden')) continue;
      var o = el.getBoundingClientRect();
      if (o.right <= s.l || o.left >= s.r || o.bottom <= s.t || o.top >= s.b) continue;
      var cands = [
        { l: s.l, t: s.t, r: o.left, b: s.b }, { l: o.right, t: s.t, r: s.r, b: s.b },
        { l: s.l, t: s.t, r: s.r, b: o.top }, { l: s.l, t: o.bottom, r: s.r, b: s.b }
      ];
      var best = null, area = -1;
      cands.forEach(function (k) {
        var a = Math.max(0, k.r - k.l) * Math.max(0, k.b - k.t);
        if (a > area) { area = a; best = k; }
      });
      if (best) s = best;
    }
    return s;
  };

  // Pan (never zoom, no animation) so `el` is fully visible with a 24 px margin.
  SideviewAccess.prototype.ensureVisible = function (el) {
    var eng = this.engine, pz = eng.panzoom;
    if (!el || !pz || !pz.pan || !pz.getPan || !eng.viewport || !eng.viewport.contains(el)) return;
    // focus can scroll the clipped canvas natively; the view is panned, never scrolled
    for (var n = eng.viewport.parentNode; n && n !== this.container.parentNode; n = n.parentNode) {
      if (n.scrollTop || n.scrollLeft) {
        var ov = global.getComputedStyle ? global.getComputedStyle(n).overflow : 'hidden';
        if (n !== this.container || /hidden|clip/.test(ov)) { n.scrollTop = 0; n.scrollLeft = 0; }
      }
    }
    var s = this.safeRect();
    var r = el.getBoundingClientRect();
    var dx = 0, dy = 0;
    if (r.width + 2 * MARGIN > s.r - s.l || r.left < s.l + MARGIN) dx = s.l + MARGIN - r.left;
    else if (r.right > s.r - MARGIN) dx = s.r - MARGIN - r.right;
    if (r.height + 2 * MARGIN > s.b - s.t || r.top < s.t + MARGIN) dy = s.t + MARGIN - r.top;
    else if (r.bottom > s.b - MARGIN) dy = s.b - MARGIN - r.bottom;
    if (Math.abs(dx) < 0.5 && Math.abs(dy) < 0.5) return;
    var p = pz.getPan();
    pz.pan(p.x + dx, p.y + dy);
    eng.scheduleConnectorUpdate();
  };

  // ---- keys ----

  SideviewAccess.prototype.handleKeyDown = function (e) {
    if (!this.on || e.defaultPrevented) return;
    var t = e.target;
    if (e.key === 'Tab') {
      this.syncOrder();
      // Shift+Tab from a card lands on the previous card's last header button, as Tab goes forward
      if (e.shiftKey && isCard(t)) {
        var cards = this.viewportCards();
        var i = cards.indexOf(t);
        if (i > 0) this.setActive(cards[i - 1], true);
      }
      return;
    }
    if (!isCard(t) || !this.container.contains(t) || !this.metaFor(t)) return;
    if (this.engine.isTypingTarget(t) || !this.engine.ownsKeyboard()) return;
    var dir = DIRS[e.key];
    if (dir) {
      if (modsMatch(e, JUMP_MODS)) {
        e.preventDefault();
        this.jump(t, dir);
        return;
      }
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      e.preventDefault();
      this.move(t, dir, e.shiftKey ? BIG_STEP : STEP);
      return;
    }
    if (SCROLL_KEYS[e.key] && !e.ctrlKey && !e.metaKey && !e.altKey && !e.shiftKey) {
      e.preventDefault();
      this.scrollBody(t, e.key);
    }
  };

  SideviewAccess.prototype.move = function (cardEl, dir, step) {
    if (cardEl.classList.contains('is-maximized')) return;
    var meta = this.metaFor(cardEl);
    if (!meta) return;
    if (this._pending && this._pending.card !== cardEl) this.flushMove();
    var x = num(cardEl.style.left) + dir.x * step;
    var y = num(cardEl.style.top) + dir.y * step;
    cardEl.style.left = x + 'px';
    cardEl.style.top = y + 'px';
    meta.x = x;
    meta.y = y;
    this.engine.scheduleConnectorUpdate();
    this.ensureVisible(cardEl);
    var self = this;
    this._pending = { card: cardEl, meta: meta };
    if (this._moveTimer) clearTimeout(this._moveTimer);
    this._moveTimer = setTimeout(function () { self._moveTimer = null; self.flushMove(); }, PAUSE_MS);
  };

  // The pause after a run of moves: one card_moved, a snapshot and one announcement.
  SideviewAccess.prototype.flushMove = function () {
    if (this._moveTimer) { clearTimeout(this._moveTimer); this._moveTimer = null; }
    var p = this._pending;
    this._pending = null;
    if (!p) return;
    var eng = this.engine;
    eng.send('sideview_card_moved', { card_id: p.meta.id, x: p.meta.x, y: p.meta.y });
    eng.scheduleSnapshot();
    eng.announce(p.meta.name + ' moved.');
    this.syncOrder();
  };

  // The nearest card whose centre lies in the 90-degree cone around `dir`; ties go to the one
  // closer on the cross axis. Canvas coordinates, so the zoom does not matter.
  SideviewAccess.prototype.nearest = function (cardEl, dir) {
    var box = function (el) {
      var x = num(el.style.left), y = num(el.style.top);
      return { x: x + el.offsetWidth / 2, y: y + el.offsetHeight / 2 };
    };
    var from = box(cardEl);
    var best = null, bestD = Infinity, bestCross = Infinity;
    this.viewportCards().forEach(function (el) {
      if (el === cardEl || !el.offsetWidth) return;
      var c = box(el);
      var dx = c.x - from.x, dy = c.y - from.y;
      var main = dir.x ? dx * dir.x : dy * dir.y;
      var cross = Math.abs(dir.x ? dy : dx);
      if (main <= 0 || cross > main) return;
      var d = Math.sqrt(dx * dx + dy * dy);
      if (d < bestD - 0.5 || (Math.abs(d - bestD) <= 0.5 && cross < bestCross)) {
        best = el; bestD = d; bestCross = cross;
      }
    });
    return best;
  };

  SideviewAccess.prototype.jump = function (cardEl, dir) {
    if (cardEl.classList.contains('is-maximized')) return;
    var next = this.nearest(cardEl, dir);
    if (!next) return;
    this.focusCard(next);
    this.engine.announce(this.cardSentence(next));
  };

  SideviewAccess.prototype.scrollBody = function (cardEl, key) {
    var body = cardEl.querySelector('.sideview-card-body');
    if (!body || !body.clientHeight) return;
    var page = Math.max(body.clientHeight * 0.9, 1);
    var max = Math.max(0, body.scrollHeight - body.clientHeight);
    if (key === 'PageDown') body.scrollTop = Math.min(max, body.scrollTop + page);
    else if (key === 'PageUp') body.scrollTop = Math.max(0, body.scrollTop - page);
    else if (key === 'Home') body.scrollTop = 0;
    else if (key === 'End') body.scrollTop = max;
  };

  global.SideviewAccess = SideviewAccess;
})(typeof window !== 'undefined' ? window : this);
