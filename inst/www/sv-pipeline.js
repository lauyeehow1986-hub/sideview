/**
 * sv-pipeline.js - sideview's composable tidyverse pipeline (no DOM).
 *
 * Every canvas or drawer operation becomes a typed step. The steps compose into
 * one R script: a chain per base table, joined tables that have their own
 * steps are prepared first (`<table>_prep <- ...`), and custom code (AI,
 * Copilot, auto-clean) is kept verbatim. Undo/redo snapshots the step list.
 *
 * The pipeline lives in the browser so it works the same in the Shiny gadget
 * and in a saved htmlwidget, where there is no R session.
 */
(function (global) {
  'use strict';

  var RESERVED = {
    'if': 1, 'else': 1, 'repeat': 1, 'while': 1, 'function': 1, 'for': 1, 'in': 1,
    'next': 1, 'break': 1, 'TRUE': 1, 'FALSE': 1, 'NULL': 1, 'Inf': 1, 'NaN': 1,
    'NA': 1, 'NA_integer_': 1, 'NA_real_': 1, 'NA_complex_': 1, 'NA_character_': 1
  };

  // R syntactic names: letters/dot start, no dot-digit start, not reserved.
  function isSyntactic(name) {
    if (typeof name !== 'string' || name === '') return false;
    if (RESERVED[name]) return false;
    return /^([A-Za-z]|[.](?![0-9]))[A-Za-z0-9._]*$/.test(name) || name === '.';
  }

  function ident(name) {
    name = String(name === null || name === undefined ? '' : name);
    if (/^`[^`]+`$/.test(name)) return name;
    return isSyntactic(name) ? name : '`' + name.replace(/\\/g, '\\\\').replace(/`/g, '\\`') + '`';
  }

  function str(value) {
    return '"' + String(value)
      .replace(/\\/g, '\\\\')
      .replace(/"/g, '\\"')
      .replace(/\n/g, '\\n')
      .replace(/\r/g, '\\r')
      .replace(/\t/g, '\\t') + '"';
  }

  function isNumberText(v) {
    return typeof v === 'number' || (typeof v === 'string' && v.trim() !== '' && !isNaN(Number(v)));
  }

  // A value typed into a builder, as an R literal.
  function literal(v, numeric) {
    var s = String(v === null || v === undefined ? '' : v).trim();
    if (s === 'NA') return 'NA';
    if (numeric && isNumberText(s)) return String(Number(s));
    return str(s);
  }

  var NUMERIC_TYPES = { numeric: 1, integer: 1, double: 1, dbl: 1, int: 1, num: 1 };

  /** One filter condition as R code; mirrors sv_filter_condition() in R. */
  function condition(col, op, val, numeric) {
    var c = ident(col);
    var lit = literal(val, numeric);
    switch (op) {
      case 'contains': return 'grepl(' + str(val) + ', ' + c + ', fixed = TRUE)';
      case 'equals': return c + ' == ' + lit;
      case 'not_equals': return c + ' != ' + lit;
      case 'gt': return c + ' > ' + lit;
      case 'gte': return c + ' >= ' + lit;
      case 'lt': return c + ' < ' + lit;
      case 'lte': return c + ' <= ' + lit;
      case 'is_na': return 'is.na(' + c + ')';
      case 'not_na': return '!is.na(' + c + ')';
      case 'in': {
        var vals = String(val).split(',').map(function (x) { return x.trim(); })
          .filter(function (x) { return x !== ''; });
        return c + ' %in% c(' + vals.map(function (x) { return literal(x, numeric); }).join(', ') + ')';
      }
    }
    return 'TRUE';
  }

  var JOIN_TYPES = ['left_join', 'inner_join', 'full_join', 'right_join', 'semi_join', 'anti_join'];

  function joinBy(pairs) {
    var same = pairs.every(function (p) { return p.left === p.right; });
    if (same && pairs.length === 1) return str(pairs[0].left);
    return 'c(' + pairs.map(function (p) {
      return p.left === p.right ? str(p.left) : str(p.left) + ' = ' + str(p.right);
    }).join(', ') + ')';
  }

  var AGG_FNS = { n: 1, n_distinct: 1, mean: 1, median: 1, sd: 1, min: 1, max: 1, sum: 1, first: 1, last: 1 };

  function aggExpr(a) {
    var fn = AGG_FNS[a.fn] ? a.fn : 'n';
    if (fn === 'n') return 'dplyr::n()';
    var c = ident(a.col);
    if (fn === 'n_distinct') return 'dplyr::n_distinct(' + c + ')';
    if (fn === 'first' || fn === 'last') return 'dplyr::' + fn + '(' + c + ')';
    return fn + '(' + c + ', na.rm = TRUE)';
  }

  function aggName(a) {
    if (a.name) return a.name;
    return a.fn === 'n' || !a.col ? 'n' : a.fn + '_' + a.col;
  }

  /** The dplyr verb calls a step contributes to its table's chain. */
  function verbs(step, refFor) {
    switch (step.kind) {
      case 'join': {
        var type = JOIN_TYPES.indexOf(step.type) >= 0 ? step.type : 'left_join';
        if (!step.by || !step.by.length) return [];
        return ['dplyr::' + type + '(' + refFor(step.right) + ', by = ' + joinBy(step.by) + ')'];
      }
      case 'filter': {
        var conds = (step.conds || []).filter(Boolean);
        if (!conds.length) return [];
        if (step.combine === 'or' && conds.length > 1) {
          return ['dplyr::filter(' + conds.map(function (c) {
            return /[&|]/.test(c) ? '(' + c + ')' : c;
          }).join(' | ') + ')'];
        }
        return ['dplyr::filter(' + conds.join(', ') + ')'];
      }
      case 'arrange': {
        var cols = (step.cols || []).filter(function (c) { return c && c.col; });
        if (!cols.length) return [];
        return ['dplyr::arrange(' + cols.map(function (c) {
          return c.desc ? 'dplyr::desc(' + ident(c.col) + ')' : ident(c.col);
        }).join(', ') + ')'];
      }
      case 'rename':
        if (!step.from || !step.to) return [];
        return ['dplyr::rename(' + ident(step.to) + ' = ' + ident(step.from) + ')'];
      case 'mutate':
        if (!step.name || !step.expr) return [];
        return ['dplyr::mutate(' + ident(step.name) + ' = ' + step.expr + ')'];
      case 'recode': {
        var map = (step.map || []).filter(function (m) { return m && m.from !== undefined && m.from !== ''; });
        if (!step.col || !map.length) return [];
        var c = ident(step.col);
        var targets = [];
        var byTarget = {};
        map.forEach(function (m) {
          var t = literal(m.to, step.numeric);
          if (!byTarget[t]) { byTarget[t] = []; targets.push(t); }
          byTarget[t].push(literal(m.from, step.numeric));
        });
        // case_when(): case_match() is deprecated from dplyr 1.2.0.
        var arms = targets.map(function (t) {
          var src = byTarget[t];
          var hasNA = src.indexOf('NA') >= 0;
          var vals = src.filter(function (v) { return v !== 'NA'; });
          var tests = [];
          if (vals.length === 1) tests.push(c + ' == ' + vals[0]);
          else if (vals.length > 1) tests.push(c + ' %in% c(' + vals.join(', ') + ')');
          if (hasNA) tests.push('is.na(' + c + ')');
          return tests.join(' | ') + ' ~ ' + t;
        });
        return ['dplyr::mutate(' + c + ' = dplyr::case_when(' + arms.join(', ') +
          ', .default = ' + c + '))'];
      }
      case 'summarise': {
        var aggs = (step.aggs || []).filter(function (a) { return a && (a.fn === 'n' || a.col); });
        if (!aggs.length) aggs = [{ fn: 'n' }];
        var out = [];
        var groups = (step.groups || []).filter(Boolean);
        if (groups.length) out.push('dplyr::group_by(' + groups.map(ident).join(', ') + ')');
        out.push('dplyr::summarise(' + aggs.map(function (a) {
          return ident(aggName(a)) + ' = ' + aggExpr(a);
        }).join(', ') + (groups.length ? ', .groups = "drop"' : '') + ')');
        return out;
      }
    }
    return [];
  }

  function describe(step) {
    switch (step.kind) {
      case 'join':
        return (step.type || 'left_join').replace('_', ' ') + ' ' + step.right + ' on ' +
          (step.by || []).map(function (p) { return p.left === p.right ? p.left : p.left + ' = ' + p.right; }).join(', ');
      case 'filter': return 'filter ' + (step.conds || []).join(step.combine === 'or' ? ' | ' : ', ');
      case 'arrange': return 'arrange ' + (step.cols || []).map(function (c) {
        return c.desc ? 'desc(' + c.col + ')' : c.col;
      }).join(', ');
      case 'rename': return 'rename ' + step.from + ' to ' + step.to;
      case 'mutate': return 'mutate ' + step.name + ' = ' + step.expr;
      case 'recode': return 'recode ' + step.col + ' (' + (step.map || []).length + ' values)';
      case 'summarise': return 'summarise' + ((step.groups || []).length ? ' by ' + step.groups.join(', ') : '');
      case 'custom': return step.label || 'custom code';
    }
    return step.kind;
  }

  function clone(x) { return JSON.parse(JSON.stringify(x)); }

  function Pipeline(opts) {
    opts = opts || {};
    this.steps = [];
    this.pipe = opts.pipe === '|>' ? '|>' : '%>%';
    this.undoStack = [];
    this.redoStack = [];
    this.maxHistory = opts.maxHistory || 100;
    this.onChange = opts.onChange || null;
    this._seq = 0;
  }

  Pipeline.prototype.snapshot = function () { return JSON.stringify(this.steps); };

  Pipeline.prototype.emit = function (label) {
    if (typeof this.onChange === 'function') this.onChange(this, label);
  };

  // Run fn as one undoable change; no-ops leave history alone.
  Pipeline.prototype.change = function (label, fn) {
    var before = this.snapshot();
    fn.call(this);
    if (this.snapshot() === before) return false;
    this.undoStack.push(before);
    if (this.undoStack.length > this.maxHistory) this.undoStack.shift();
    this.redoStack = [];
    this.emit(label);
    return true;
  };

  Pipeline.prototype.newId = function () {
    this._seq += 1;
    return 's' + Date.now().toString(36) + '_' + this._seq;
  };

  Pipeline.prototype.normalize = function (step) {
    var s = clone(step);
    if (!s.id) s.id = this.newId();
    if (s.enabled === undefined) s.enabled = true;
    return s;
  };

  Pipeline.prototype.indexOf = function (pred) {
    for (var i = 0; i < this.steps.length; i++) if (pred(this.steps[i])) return i;
    return -1;
  };

  Pipeline.prototype.find = function (id) {
    var i = this.indexOf(function (s) { return s.id === id; });
    return i < 0 ? null : this.steps[i];
  };

  /** Append a step. A step with `key` replaces the earlier one and moves last. */
  Pipeline.prototype.add = function (step, label) {
    var self = this;
    var s = this.normalize(step);
    this.change(label || 'add', function () {
      if (s.key) {
        var i = self.indexOf(function (x) { return x.key === s.key; });
        if (i >= 0) self.steps.splice(i, 1);
      }
      self.steps.push(s);
    });
    return s;
  };

  Pipeline.prototype.removeKey = function (key, label) {
    var self = this;
    return this.change(label || 'remove', function () {
      self.steps = self.steps.filter(function (s) { return s.key !== key; });
    });
  };

  Pipeline.prototype.remove = function (id) {
    var self = this;
    return this.change('remove', function () {
      self.steps = self.steps.filter(function (s) { return s.id !== id; });
    });
  };

  Pipeline.prototype.update = function (id, patch) {
    var self = this;
    return this.change('update', function () {
      var s = self.find(id);
      if (s) Object.keys(patch).forEach(function (k) { s[k] = clone(patch[k]); });
    });
  };

  Pipeline.prototype.toggle = function (id) {
    var s = this.find(id);
    return s ? this.update(id, { enabled: !s.enabled }) : false;
  };

  Pipeline.prototype.move = function (id, delta) {
    var self = this;
    return this.change('move', function () {
      var i = self.indexOf(function (s) { return s.id === id; });
      var j = i + delta;
      if (i < 0 || j < 0 || j >= self.steps.length) return;
      var s = self.steps.splice(i, 1)[0];
      self.steps.splice(j, 0, s);
    });
  };

  function joinKey(left, right) { return JSON.stringify(['join', left, right]); }

  /** Add one key pair to the join between two tables (multi-key joins merge). */
  Pipeline.prototype.addJoinKey = function (left, right, leftCol, rightCol, type) {
    var self = this;
    var key = joinKey(left, right);
    this.change('join', function () {
      var s = self.steps[self.indexOf(function (x) { return x.key === key; })];
      if (!s) {
        self.steps.push(self.normalize({
          kind: 'join', key: key, table: left, right: right,
          type: type || 'left_join', by: [{ left: leftCol, right: rightCol }]
        }));
        return;
      }
      var has = s.by.some(function (p) { return p.left === leftCol && p.right === rightCol; });
      if (!has) s.by.push({ left: leftCol, right: rightCol });
    });
  };

  Pipeline.prototype.removeJoinKey = function (left, right, leftCol, rightCol) {
    var self = this;
    var key = joinKey(left, right);
    return this.change('unjoin', function () {
      var i = self.indexOf(function (x) { return x.key === key; });
      if (i < 0) return;
      var s = self.steps[i];
      s.by = s.by.filter(function (p) { return !(p.left === leftCol && p.right === rightCol); });
      if (!s.by.length) self.steps.splice(i, 1);
    });
  };

  Pipeline.prototype.clear = function () {
    var self = this;
    return this.change('clear', function () { self.steps = []; });
  };

  /** Replace everything with one block of code (AI or Copilot output). */
  Pipeline.prototype.replaceWithCode = function (code, label) {
    var self = this;
    return this.change('replace', function () {
      self.steps = [self.normalize({ kind: 'custom', code: String(code), label: label || 'custom code' })];
    });
  };

  Pipeline.prototype.canUndo = function () { return this.undoStack.length > 0; };
  Pipeline.prototype.canRedo = function () { return this.redoStack.length > 0; };

  Pipeline.prototype.undo = function () {
    if (!this.undoStack.length) return false;
    this.redoStack.push(this.snapshot());
    this.steps = JSON.parse(this.undoStack.pop());
    this.emit('undo');
    return true;
  };

  Pipeline.prototype.redo = function () {
    if (!this.redoStack.length) return false;
    this.undoStack.push(this.snapshot());
    this.steps = JSON.parse(this.redoStack.pop());
    this.emit('redo');
    return true;
  };

  Pipeline.prototype.setPipe = function (pipe) {
    this.pipe = pipe === '|>' ? '|>' : '%>%';
    this.emit('pipe');
  };

  Pipeline.prototype.enabledCount = function () {
    return this.steps.filter(function (s) { return s.enabled !== false; }).length;
  };

  /** Compose the enabled steps into one R script ('' when there is nothing). */
  Pipeline.prototype.compose = function () {
    var pipe = this.pipe;
    var steps = this.steps.filter(function (s) { return s.enabled !== false; });
    var blocks = [];
    var chains = {};
    steps.forEach(function (s) {
      if (s.kind === 'custom') {
        if (s.code && String(s.code).trim()) blocks.push({ custom: String(s.code).trim() });
        return;
      }
      if (!s.table) return;
      if (!chains[s.table]) {
        chains[s.table] = [];
        blocks.push({ table: s.table });
      }
      chains[s.table].push(s);
    });

    // consumers[t] = chains that join t in.
    var consumers = {};
    Object.keys(chains).forEach(function (t) {
      chains[t].forEach(function (s) {
        if (s.kind === 'join' && s.right !== t && chains[s.right]) {
          (consumers[s.right] = consumers[s.right] || {})[t] = true;
        }
      });
    });

    var out = [];
    var state = {};
    var asPrep = {};

    function prepName(t) { return ident(t + '_prep'); }

    function render(t) {
      var verbList = [];
      chains[t].forEach(function (s) {
        verbList = verbList.concat(verbs(s, function (r) {
          return asPrep[r] ? prepName(r) : ident(r);
        }));
      });
      // A chain is prepared (assigned) when a chain not yet written joins it.
      var later = Object.keys(consumers[t] || {}).some(function (c) { return state[c] !== 2; });
      asPrep[t] = later;
      var head = (later ? prepName(t) + ' <- ' : '') + ident(t);
      if (!verbList.length) return later ? head : '';
      return head + ' ' + pipe + '\n  ' + verbList.join(' ' + pipe + '\n  ');
    }

    function visit(t) {
      if (state[t]) return;  // done, or a join cycle: use the raw table
      state[t] = 1;
      chains[t].forEach(function (s) {
        if (s.kind === 'join' && s.right !== t && chains[s.right]) visit(s.right);
      });
      var code = render(t);
      state[t] = 2;
      if (code) out.push(code);
    }

    blocks.forEach(function (b) {
      if (b.custom !== undefined) out.push(b.custom);
      else visit(b.table);
    });
    return out.join('\n\n');
  };

  Pipeline.prototype.toJSON = function () {
    return { steps: clone(this.steps), pipe: this.pipe };
  };

  Pipeline.prototype.load = function (obj) {
    if (!obj) return;
    var self = this;
    this.change('load', function () {
      self.steps = (obj.steps || []).map(function (s) { return self.normalize(s); });
    });
    if (obj.pipe) this.setPipe(obj.pipe);
  };

  // ---- join diagnostics ------------------------------------------------------
  // Mirrors sv_join_diagnostics() in R/diagnostics.R for the htmlwidget, which
  // has the full data but no R session. Keys compare like dplyr (NA matches NA).

  var NA_KEY = '\u0001NA';
  var KEY_SEP = '\u001f';

  function isMissing(v) {
    return v === null || v === undefined || (typeof v === 'number' && isNaN(v));
  }

  function keyKind(type) {
    var t = String(type || '').toLowerCase();
    if (t === 'character' || t === 'factor' || t === 'string' || t === 'chr' || t === 'fct') return 'character';
    if (t === 'date') return 'Date';
    if (t === 'posixct' || t === 'posixt' || t === 'datetime' || t === 'dttm') return 'date-time';
    if (t === 'logical' || t === 'lgl') return 'logical';
    if (NUMERIC_TYPES[t]) return 'numeric';
    return t || 'unknown';
  }

  function joinKeys(cols, names, kinds, fn) {
    var n = names.length ? (cols[names[0]] || []).length : 0;
    var out = new Array(n);
    for (var i = 0; i < n; i++) {
      var parts = [];
      for (var j = 0; j < names.length; j++) {
        var v = cols[names[j]][i];
        if (isMissing(v)) { parts.push(NA_KEY); continue; }
        var s = String(v);
        if (fn && kinds[j] === 'character') s = fn(s);
        parts.push(s);
      }
      out[i] = parts.join(KEY_SEP);
    }
    return out;
  }

  function tally(keys) {
    var m = new Map();
    for (var i = 0; i < keys.length; i++) m.set(keys[i], (m.get(keys[i]) || 0) + 1);
    return m;
  }

  function joinCounts(kx, ky) {
    var cx = tally(kx), cy = tally(ky);
    var inner = 0, matchedX = 0, matchedY = 0, distinctMatched = 0;
    var manyX = false, manyY = false, dupX = 0, dupY = 0;
    var unmatchedX = [], unmatchedY = [];
    cx.forEach(function (nx, k) {
      if (nx > 1) dupX++;
      var ny = cy.get(k);
      if (ny) {
        inner += nx * ny; matchedX += nx; distinctMatched++;
        if (nx > 1) manyX = true;
        if (ny > 1) manyY = true;
      } else {
        unmatchedX.push(k);
      }
    });
    cy.forEach(function (ny, k) {
      if (ny > 1) dupY++;
      if (cx.has(k)) matchedY += ny; else unmatchedY.push(k);
    });
    var rel = !distinctMatched ? 'no matches' : manyX && manyY ? 'many-to-many' :
      manyY ? 'one-to-many' : manyX ? 'many-to-one' : 'one-to-one';
    var nX = kx.length, nY = ky.length;
    return {
      distinct_x: cx.size, distinct_y: cy.size, distinct_matched: distinctMatched,
      matched_x: matchedX, matched_y: matchedY, dup_keys_x: dupX, dup_keys_y: dupY,
      relationship: rel,
      rows: {
        left_join: inner + (nX - matchedX), inner_join: inner,
        full_join: inner + (nX - matchedX) + (nY - matchedY), right_join: inner + (nY - matchedY),
        semi_join: matchedX, anti_join: nX - matchedX
      },
      unmatched_x: unmatchedX, unmatched_y: unmatchedY
    };
  }

  function decodeKey(k) {
    return k.split(NA_KEY).join('NA').split(KEY_SEP).join(', ');
  }

  function fmtN(n) {
    return Number(n).toLocaleString('en-US');
  }

  /**
   * Diagnose a join before running it.
   * @param xCols,yCols column arrays keyed by name ({ id: [...], ... })
   * @param by [{ left, right }] key pairs
   * @param opts { sampleN, xName, yName, xTypes, yTypes } (types are R class names)
   */
  function joinDiagnostics(xCols, yCols, by, opts) {
    opts = opts || {};
    var xName = opts.xName || 'x', yName = opts.yName || 'y';
    var sampleN = opts.sampleN === undefined ? 5 : opts.sampleN;
    var byX = by.map(function (p) { return p.left; });
    var byY = by.map(function (p) { return p.right; });
    var kindsX = byX.map(function (c) { return keyKind((opts.xTypes || {})[c] || guessKind(xCols[c])); });
    var kindsY = byY.map(function (c) { return keyKind((opts.yTypes || {})[c] || guessKind(yCols[c])); });
    var kx = joinKeys(xCols, byX, kindsX), ky = joinKeys(yCols, byY, kindsY);
    var core = joinCounts(kx, ky);
    var nX = kx.length, nY = ky.length;
    var anyNa = function (cols, names) {
      var n = 0;
      for (var i = 0; i < (names.length ? cols[names[0]].length : 0); i++) {
        if (names.some(function (c) { return isMissing(cols[c][i]); })) n++;
      }
      return n;
    };
    var d = {
      by: by.map(function (p) { return { left: p.left, right: p.right }; }),
      n_x: nX, n_y: nY,
      distinct_x: core.distinct_x, distinct_y: core.distinct_y, distinct_matched: core.distinct_matched,
      matched_x: core.matched_x, matched_y: core.matched_y,
      match_rate_x: nX ? core.matched_x / nX : 0, match_rate_y: nY ? core.matched_y / nY : 0,
      na_x: anyNa(xCols, byX), na_y: anyNa(yCols, byY),
      dup_keys_x: core.dup_keys_x, dup_keys_y: core.dup_keys_y,
      relationship: core.relationship, rows: core.rows,
      unmatched_x: core.unmatched_x.slice(0, sampleN).map(decodeKey),
      unmatched_y: core.unmatched_y.slice(0, sampleN).map(decodeKey),
      type_issues: [], hints: []
    };
    byX.forEach(function (c, i) {
      if (kindsX[i] !== kindsY[i]) {
        var col = c === byY[i] ? c : c + ' / ' + byY[i];
        d.type_issues.push(col + ' is ' + kindsX[i] + ' in ' + xName + ' but ' + kindsY[i] + ' in ' + yName +
          ': dplyr will refuse this join until both sides have the same type.');
      }
    });
    if (core.matched_x < nX || core.matched_y < nY) {
      var fixes = [
        { fix: 'trim', label: 'trimming whitespace', fn: function (s) { return s.trim(); } },
        { fix: 'case', label: 'ignoring case', fn: function (s) { return s.toLowerCase(); } },
        { fix: 'zeros', label: 'dropping leading zeros', fn: function (s) { return s.replace(/^0+(?=[0-9])/, ''); } }
      ];
      fixes.forEach(function (f) {
        var alt = joinCounts(joinKeys(xCols, byX, kindsX, f.fn), joinKeys(yCols, byY, kindsY, f.fn));
        var ex = alt.matched_x - core.matched_x, ey = alt.matched_y - core.matched_y;
        if (ex > 0 || ey > 0) d.hints.push({ fix: f.fix, label: f.label, extra_x: ex, extra_y: ey });
      });
    }
    var w = [];
    if (d.relationship === 'many-to-many') {
      w.push('Many-to-many: keys repeat in both tables, so a left join gives ' + fmtN(d.rows.left_join) +
        ' rows from ' + fmtN(nX) + ' ' + xName + ' rows.');
    }
    if (d.relationship === 'no matches' && nX && nY) {
      w.push('No ' + xName + ' key matches any ' + yName + ' key.');
    } else if (nX && d.match_rate_x < 0.5) {
      w.push('Only ' + Math.round(100 * d.match_rate_x) + '% of ' + xName + ' rows have a match in ' + yName + '.');
    }
    if (d.na_x || d.na_y) {
      w.push('Missing keys (' + fmtN(d.na_x) + ' in ' + xName + ', ' + fmtN(d.na_y) + ' in ' + yName +
        '): dplyr matches NA to NA by default (na_matches = "na").');
    }
    d.warnings = w;
    d.status = d.type_issues.length ? 'error' : w.length ? 'warn' : 'ok';
    return d;
  }

  // Column kind from the values when the card has no R types.
  function guessKind(values) {
    if (!values) return 'unknown';
    for (var i = 0; i < values.length; i++) {
      var v = values[i];
      if (isMissing(v)) continue;
      if (typeof v === 'number') return 'numeric';
      if (typeof v === 'boolean') return 'logical';
      return 'character';
    }
    return 'logical';
  }

  /** One-line summary of a diagnostics result for a join step. */
  function describeDiagnostics(d, type, xName) {
    var rows = d.rows[type || 'left_join'];
    var rel = { 'one-to-one': '1:1', 'one-to-many': '1:m', 'many-to-one': 'm:1', 'many-to-many': 'm:m' }[d.relationship] ||
      d.relationship;
    return rel + ' · ' + Math.round(100 * d.match_rate_x) + '% of ' + (xName || 'x') + ' matched · ' +
      (rows === undefined ? '' : fmtN(rows) + ' rows');
  }

  var api = {
    Pipeline: Pipeline,
    joinDiagnostics: joinDiagnostics,
    describeDiagnostics: describeDiagnostics,
    ident: ident,
    str: str,
    literal: literal,
    condition: condition,
    verbs: verbs,
    describe: describe,
    isSyntactic: isSyntactic,
    NUMERIC_TYPES: NUMERIC_TYPES,
    JOIN_TYPES: JOIN_TYPES,
    AGG_FNS: Object.keys(AGG_FNS)
  };
  global.SideviewPipeline = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this));
