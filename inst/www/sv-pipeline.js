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

  /** Escape the characters a regular expression gives a meaning to, so the text matches itself. */
  function regexEscape(v) {
    return String(v).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  /**
   * One filter condition as R code; mirrors sv_filter_condition() in R.
   * `lazy` (an arrow or duckdb table): grepl() has no translation there, so "contains" is
   * stringr::str_detect(); a numeric column is cast to text first, as the rest of sideview does.
   * The value is written as an escaped regular expression, not stringr::fixed(): dbplyr turns
   * fixed() into a plain regex on duckdb, so fixed(".") matched every row there. An escaped
   * pattern means the same on arrow and on duckdb (both use RE2), wherever the step ends up.
   */
  function condition(col, op, val, numeric, lazy) {
    var c = ident(col);
    var lit = literal(val, numeric);
    switch (op) {
      case 'contains':
        if (lazy) {
          return 'stringr::str_detect(' + (numeric ? 'as.character(' + c + ')' : c) +
            ', ' + str(regexEscape(val)) + ')';
        }
        return 'grepl(' + str(val) + ', ' + c + ', fixed = TRUE)';
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

  /**
   * dplyr::join_by(...) for the key pairs plus one rule expression (null: keys only).
   * Equal-named pairs are written bare, the others as `l == r`; every name goes through ident().
   */
  function joinByCall(pairs, ruleExpr) {
    var parts = (pairs || []).map(function (p) {
      return p.left === p.right ? ident(p.left) : ident(p.left) + ' == ' + ident(p.right);
    });
    if (ruleExpr) parts.push(ruleExpr);
    return 'dplyr::join_by(' + parts.join(', ') + ')';
  }

  /**
   * `col + n` / `col - n` (a date-time moves by days), or the column alone for 0. On duckdb
   * (`lazy`) a Date moves by an integer (`col - 7L`), and a date-time is
   * `as.POSIXct(col) +/- lubridate::days(n)`: an arrow date-time arrives
   * as TIMESTAMP WITH TIME ZONE, and without duckdb's ICU extension TIMESTAMPTZ +/- INTERVAL has
   * no function, so the column is cast to TIMESTAMP first (dbplyr: CAST(col AS TIMESTAMP)).
   */
  function offsetExpr(col, n, kind, lazy) {
    var c = ident(col);
    n = Number(n);
    // On duckdb a zero bound of a date-time is cast as well, so both bounds have one type.
    if (n === 0) return kind === 'date-time' && lazy ? 'as.POSIXct(' + c + ')' : c;
    var amount = Math.abs(n) + '';
    if (kind === 'date-time') {
      if (lazy) {
        c = 'as.POSIXct(' + c + ')';
        amount = 'lubridate::days(' + amount + ')';
      } else {
        amount = 'as.difftime(' + amount + ', units = "days")';
      }
    } else if (kind === 'Date' && lazy) {
      // dbplyr writes 7 as 7.0 and duckdb has no DATE +/- DECIMAL; 7L is written 7 (DATE +/- INTEGER).
      amount += 'L';
    }
    return c + (n < 0 ? ' - ' : ' + ') + amount;
  }

  /**
   * How a (valid) date rule is written for a join (`lazy`: on duckdb): `pre` verbs before the join,
   * the `expr` inside join_by(), and `post` verbs after it. The helper columns .sv_lo / .sv_hi
   * exist only for a window and are dropped again by `post`.
   */
  function ruleParts(rule, kindOf, lazy) {
    var r = rule;
    var strict = r.inclusive === false;
    switch (r.shape) {
      case 'between':
        return { pre: [], post: [],
          expr: 'between(' + ident(r.xCol) + ', ' + ident(r.yFrom) + ', ' + ident(r.yTo) + ')' };
      case 'window': {
        var k = kindOf ? kindOf(r.xCol) : null;
        // The window is a column of x, so between() needs its arguments qualified: y comes first.
        return {
          pre: ['dplyr::mutate(.sv_lo = ' + offsetExpr(r.xCol, r.from, k, lazy) + ', .sv_hi = ' +
            offsetExpr(r.xCol, r.to, k, lazy) + ')'],
          expr: 'between(y$' + ident(r.yCol) + ', x$.sv_lo, x$.sv_hi)',
          post: ['dplyr::select(-.sv_lo, -.sv_hi)']
        };
      }
      case 'before':
        return { pre: [], post: [],
          expr: 'closest(' + ident(r.xCol) + (strict ? ' > ' : ' >= ') + ident(r.yCol) + ')' };
      case 'after':
        return { pre: [], post: [],
          expr: 'closest(' + ident(r.xCol) + (strict ? ' < ' : ' <= ') + ident(r.yCol) + ')' };
      case 'overlaps':
        return { pre: [], post: [],
          expr: 'overlaps(' + ident(r.xFrom) + ', ' + ident(r.xTo) + ', ' + ident(r.yFrom) + ', ' +
            ident(r.yTo) + ')' };
    }
    return null;
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

  /**
   * The dplyr verb calls a step contributes to its table's chain.
   * `ctx` (optional) describes the chain at this point: `copy` adds copy = TRUE to a join
   * (duckdb joined to a data frame) and `kind` ('arrow' | 'duckdb') is the lazy backend.
   * `strict` ({ relationship, unmatched? }, from the join check) is written into an in-memory join.
   */
  function verbs(step, refFor, ctx) {
    ctx = ctx || {};
    switch (step.kind) {
      case 'join': {
        var type = JOIN_TYPES.indexOf(step.type) >= 0 ? step.type : 'left_join';
        if (!step.by || !step.by.length) return [];
        // Strict: the arguments the join check found, only on a join in memory (dbplyr and arrow
        // joins have no relationship / unmatched). They come after na_matches and before copy.
        var strictTail = '';
        if (ctx.strict && ctx.kind == null) {
          strictTail = ', relationship = ' + str(ctx.strict.relationship) +
            (ctx.strict.unmatched ? ', unmatched = ' + str(ctx.strict.unmatched) : '');
        }
        // A valid date rule is written as join_by() with na_matches = "never". compose() sets
        // ctx.rule for a valid rule, in memory (ctx.kind null) or on duckdb (arrow moves there first).
        if (ctx.rule && step.rule) {
          var lazy = ctx.kind === 'duckdb';
          var tail = ', na_matches = "never"' + strictTail + (ctx.copy ? ', copy = TRUE' : '') + ')';
          var rr = step.rule;
          if (lazy && (rr.shape === 'before' || rr.shape === 'after')) {
            // dbplyr has no closest(): join on the inequality, then keep the nearest y per x row
            // (all of them on a tie). A semi / anti join only asks whether any y matches.
            var op = (rr.shape === 'before' ? '>' : '<') + (rr.inclusive === false ? '' : '=');
            var cond = ident(rr.xCol) + ' ' + op + ' ';
            if (type === 'semi_join' || type === 'anti_join') {
              return ['dplyr::' + type + '(' + refFor(step.right) + ', by = ' +
                joinByCall(step.by, cond + ident(rr.yCol)) + tail];
            }
            return [
              // .sv_row is only a per-row tag, so ROW_NUMBER() OVER () needs no ORDER BY.
              'dplyr::mutate(.sv_row = dplyr::row_number())',
              'dplyr::' + type + '(dplyr::mutate(' + refFor(step.right) + ', .sv_yd = ' + ident(rr.yCol) +
                '), by = ' + joinByCall(step.by, cond + '.sv_yd') + tail,
              'dplyr::group_by(.sv_row)',
              'dplyr::filter(' + (type === 'left_join' ? 'is.na(.sv_yd) | ' : '') + '.sv_yd == ' +
                (rr.shape === 'before' ? 'max' : 'min') + '(.sv_yd, na.rm = TRUE))',
              'dplyr::ungroup()',
              'dplyr::select(-.sv_row, -.sv_yd)'
            ];
          }
          var parts = ruleParts(rr, ctx.kindOf, lazy);
          if (parts) {
            return parts.pre.concat(['dplyr::' + type + '(' + refFor(step.right) + ', by = ' +
              joinByCall(step.by, parts.expr) + tail], parts.post);
          }
        }
        return ['dplyr::' + type + '(' + refFor(step.right) + ', by = ' + joinBy(step.by) +
          strictTail + (ctx.copy ? ', copy = TRUE' : '') + ')'];
      }
      case 'reshape': {
        if (step.type === 'pivot_wider') {
          if (!step.namesFrom || !step.valuesFrom) return [];
          return ['tidyr::pivot_wider(names_from = ' + ident(step.namesFrom) +
            ', values_from = ' + ident(step.valuesFrom) + ')'];
        }
        var rcols = (step.cols || []).filter(Boolean);
        if (!rcols.length) return [];
        return ['tidyr::pivot_longer(cols = c(' + rcols.map(ident).join(', ') + '), names_to = ' +
          str(step.namesTo || 'name') + ', values_to = ' + str(step.valuesTo || 'value') + ')'];
      }
      case 'filter': {
        // "contains" is written for the engine the chain is in when this step runs (a data frame
        // moved into duckdb by an earlier join cannot use grepl()): step.specs[i] holds its parts.
        var specs = step.specs || [];
        var conds = (step.conds || []).map(function (c, i) {
          var sp = specs[i];
          return sp && sp.op === 'contains'
            ? condition(sp.col, sp.op, sp.val, sp.numeric, ctx.kind)
            : c;
        }).filter(Boolean);
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
        // arrow rejects `.default = <column>` (it wants one value), so a closing `TRUE ~ <column>` arm.
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
          (ctx.kind === 'arrow' ? ', TRUE ~ ' + c : ', .default = ' + c) + '))'];
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

  /**
   * One line for a step. `ctx` is optional: a Pipeline, whose tables decide a date rule's wording
   * (days or the column's own unit) and whether the rule still holds ("Rule needs fixing").
   */
  function describe(step, ctx) {
    switch (step.kind) {
      case 'join': {
        var text = (step.type || 'left_join').replace('_', ' ') + ' ' + step.right + ' on ' +
          (step.by || []).map(function (p) { return p.left === p.right ? p.left : p.left + ' = ' + p.right; }).join(', ');
        if (step.rule) {
          if (ctx && typeof ctx.joinRuleProblem === 'function' && ctx.joinRuleProblem(step)) {
            return text + ' · Rule needs fixing';
          }
          var tx = ctx && ctx.tables && ctx.tables[step.table];
          var kx = tx && tx.kinds ? tx.kinds[step.rule.xCol || step.rule.xFrom] : null;
          var rl = ruleLabel(step.rule, kx);
          return rl ? text + ' · ' + rl : text;
        }
        return text;
      }
      case 'filter': return 'filter ' + (step.conds || []).join(step.combine === 'or' ? ' | ' : ', ');
      case 'arrange': return 'arrange ' + (step.cols || []).map(function (c) {
        return c.desc ? 'desc(' + c.col + ')' : c.col;
      }).join(', ');
      case 'reshape': return step.type === 'pivot_wider'
        ? 'pivot wider ' + step.namesFrom + ' / ' + step.valuesFrom
        : 'pivot longer ' + (step.cols || []).join(', ');
      case 'rename': return 'rename ' + step.from + ' to ' + step.to;
      case 'mutate': return 'mutate ' + step.name + ' = ' + step.expr;
      case 'recode': return 'recode ' + step.col + ' (' + (step.map || []).length + ' values)';
      case 'summarise': return 'summarise' + ((step.groups || []).length ? ' by ' + step.groups.join(', ') : '');
      case 'custom': return step.label || 'custom code';
      case 'supp': return 'merge ' + String(step.supp).toUpperCase() + ' (' + (step.qnams || []).length +
        ' QNAMs on ' + (step.idvars || []).map(function (v) {
          return v.idvar === '' ? 'subject' : v.idvar;
        }).join(' and ') + ')';
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
    this.tables = {};
    this.checks = {};   // join-check results by joinSig(): not state (no undo, never saved)
  }

  var LAZY_KINDS = { arrow: 1, duckdb: 1 };

  /**
   * Tell the pipeline which tables are lazy: `meta = { <name>: { lazy: 'arrow'|'duckdb'|null,
   * codeRef: string, kinds: { <column>: 'Date'|'date-time'|'numeric'|... } } }`. It decides how joins
   * are written and whether the code ends in collect(); `kinds` lets a date rule be checked.
   * It is not pipeline state (undo, saved workspaces): the cards carry it.
   */
  Pipeline.prototype.setTables = function (meta) {
    var next = {};
    Object.keys(meta || {}).forEach(function (name) {
      var m = meta[name] || {};
      next[name] = {
        lazy: LAZY_KINDS[m.lazy] ? m.lazy : null,
        codeRef: typeof m.codeRef === 'string' && m.codeRef !== '' ? m.codeRef : null,
        kinds: tableKinds(m.kinds)
      };
    });
    if (JSON.stringify(next) === JSON.stringify(this.tables)) return false;
    this.tables = next;
    this.emit('tables');
    return true;
  };

  /** 'arrow' | 'duckdb' for a lazy table, else null. */
  Pipeline.prototype.lazyKind = function (name) {
    var m = this.tables[name];
    return m && m.lazy ? m.lazy : null;
  };

  /** The R expression that names a table: a lazy table's codeRef when it differs from its name. */
  Pipeline.prototype.refFor = function (name) {
    var m = this.tables[name];
    if (m && m.lazy && m.codeRef && m.codeRef !== name) return m.codeRef;
    return ident(name);
  };

  /** True when an enabled step touches a lazy table (or custom code runs beside one). */
  Pipeline.prototype.hasLazy = function () {
    var self = this;
    var anyLazy = Object.keys(this.tables).some(function (n) { return self.tables[n].lazy; });
    if (!anyLazy) return false;
    return this.steps.some(function (s) {
      if (s.enabled === false) return false;
      if (s.kind === 'custom') return true;
      return !!(self.lazyKind(s.table) || (s.right && self.lazyKind(s.right)) ||
        (s.supp && self.lazyKind(s.supp)));
    });
  };

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

  /**
   * Add a set of key pairs ({left, right}) to the join between two tables as one undo step.
   * Merges into an existing join for (left, right), or into the reverse join (right, left)
   * with the pairs swapped; only missing pairs are added. A no-op leaves history alone.
   */
  Pipeline.prototype.addJoinKeys = function (left, right, pairs, type) {
    var self = this;
    var key = joinKey(left, right);
    var rkey = joinKey(right, left);
    this.change('join', function () {
      var fwd = self.steps[self.indexOf(function (x) { return x.key === key; })];
      var rev = fwd ? null : self.steps[self.indexOf(function (x) { return x.key === rkey; })];
      var s = fwd || rev;
      (pairs || []).forEach(function (p) {
        var l = rev ? p.right : p.left;
        var r = rev ? p.left : p.right;
        if (!s) {
          s = self.normalize({
            kind: 'join', key: key, table: left, right: right,
            type: type || 'left_join', by: []
          });
          self.steps.push(s);
        }
        var has = s.by.some(function (q) { return q.left === l && q.right === r; });
        if (!has) s.by.push({ left: l, right: r });
      });
    });
  };

  Pipeline.prototype.removeJoinKey =function (left, right, leftCol, rightCol) {
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


  /**
   * The names an R expression uses as variables: backticked names, and bare names outside string
   * literals that are not called (`f(`), not a member (`x$a`, `pkg::a`) and not an argument name
   * (`f(a = 1)`). A scan, not a parser: it only has to find a column that is no longer there.
   */
  function exprNames(expr) {
    var text = String(expr == null ? '' : expr);
    var names = [];
    var bare = '';
    var i = 0;
    function flush() { if (bare) { scanBare(bare); bare = ''; } }
    function scanBare(t) {
      var re = /[\p{L}.][\p{L}\p{N}._]*/gu;
      var m;
      while ((m = re.exec(t)) !== null) {
        var before = t.slice(Math.max(0, m.index - 2), m.index).replace(/\s+$/, '');
        var after = t.slice(m.index + m[0].length);
        if (/[$@]$/.test(before) || /::$/.test(before)) continue;
        if (/^\s*\(/.test(after)) continue;
        if (/^\s*=(?!=)/.test(after)) continue;
        if (/^\d/.test(m[0]) || /^\.\d/.test(m[0])) continue;
        if (names.indexOf(m[0]) < 0) names.push(m[0]);
      }
    }
    while (i < text.length) {
      var ch = text.charAt(i);
      if (ch === '"' || ch === "'" || ch === '`') {
        flush();
        var j = i + 1;
        while (j < text.length && text.charAt(j) !== ch) j += text.charAt(j) === '\\' ? 2 : 1;
        if (ch === '`') {
          var nm = text.slice(i + 1, j);
          if (nm && names.indexOf(nm) < 0) names.push(nm);
        }
        i = j + 1;
      } else {
        bare += ch;
        i++;
      }
    }
    flush();
    return names;
  }

  // The columns a step leaves on its table's chain: rename replaces a name, mutate adds one,
  // a supp merge adds its QNAMs. `cols` is changed in place.
  function stepColumns(s, cols) {
    if (s.kind === 'rename') {
      var i = cols.indexOf(s.from);
      if (i >= 0) cols[i] = s.to;
    } else if (s.kind === 'mutate') {
      if (cols.indexOf(s.name) < 0) cols.push(s.name);
    } else if (s.kind === 'supp') {
      (s.qnams || []).forEach(function (q) { if (cols.indexOf(q.qnam) < 0) cols.push(q.qnam); });
    }
  }
  // After these steps the chain's columns are not known in the browser.
  function unknownAfter(s) {
    return s.kind === 'join' || s.kind === 'summarise' || s.kind === 'reshape' || s.kind === 'custom';
  }

  /**
   * The columns `table` has on its chain before the step with key `key` (all enabled steps when
   * no step has that key), from the card's `columns`, by the same pass disableMissing() uses.
   * With `last` the step is taken as moved last (as Pipeline.add() does): every other enabled step counts.
   * Returns null when an earlier join, summarise, reshape or custom step makes them unknown.
   */
  Pipeline.prototype.columnsBefore = function (table, columns, key, last) {
    var cols = (columns || []).slice();
    for (var i = 0; i < this.steps.length; i++) {
      var s = this.steps[i];
      if (key && s.key === key) { if (last) continue; break; }
      if (s.table !== table || s.enabled === false) continue;
      stepColumns(s, cols);
      if (unknownAfter(s)) return null;
    }
    return cols;
  };

  /**
   * Disable the enabled steps of `table` that need a column its refreshed data no longer has
   * (`columns`: the new column names), or every step on it and every join with it (`columns` null:
   * the table is gone). Columns are tracked along the table's chain (rename, mutate); after an
   * enabled join, summarise, reshape or custom step they are unknown and later steps are kept.
   * `oldColumns` (the names the table had) lets a mutate expression be checked: it is disabled
   * when it uses a name that was a column and is not any more; without it mutate is not checked.
   * One undoable change; when something was disabled, undo and redo history is dropped.
   * Returns { disabled: [{id, kind, missing}], missing: [unique columns] }.
   */
  Pipeline.prototype.disableMissing = function (table, columns, oldColumns) {
    var self = this;
    var found = {};
    var order = [];
    function note(s, miss) {
      if (!found[s.id]) { found[s.id] = { id: s.id, kind: s.kind, missing: [] }; order.push(s.id); }
      miss.forEach(function (c) { if (found[s.id].missing.indexOf(c) < 0) found[s.id].missing.push(c); });
    }
    function lack(cols, need) {
      var out = [];
      need.forEach(function (c) {
        if (c !== undefined && c !== null && c !== '' && cols.indexOf(c) < 0 && out.indexOf(c) < 0) out.push(c);
      });
      return out;
    }
    function ruleCols(rule, side) {
      if (!rule) return [];
      return side === 'x' ? [rule.xCol, rule.xFrom, rule.xTo] : [rule.yCol, rule.yFrom, rule.yTo];
    }
    function leftNeeds(s, cols) {
      var n = [];
      switch (s.kind) {
        case 'arrange': (s.cols || []).forEach(function (c) { n.push(c.col); }); break;
        case 'filter':
          // conds are R expression strings; their columns travel in condCols (or specs / cond objects)
          (s.conds || []).forEach(function (c, i) {
            var sp = s.specs && s.specs[i];
            if (c && typeof c === 'object') n.push(c.col);
            else if (s.condCols && s.condCols[i] !== undefined) n.push(s.condCols[i]);
            else if (sp && sp.col !== undefined) n.push(sp.col);
          });
          break;
        case 'recode': n.push(s.col); break;
        case 'rename': n.push(s.from); break;
        case 'mutate':
          if (oldColumns) {
            exprNames(s.expr).forEach(function (c) {
              if (oldColumns.indexOf(c) >= 0 && cols.indexOf(c) < 0) n.push(c);
            });
          }
          break;
        case 'summarise':
          (s.groups || []).forEach(function (g) { n.push(g); });
          (s.aggs || []).forEach(function (a) { n.push(a.col); });
          break;
        case 'reshape':
          if (s.type === 'pivot_longer') (s.cols || []).forEach(function (c) { n.push(c); });
          else { n.push(s.namesFrom); n.push(s.valuesFrom); }
          break;
        case 'join':
          (s.by || []).forEach(function (b) { n.push(b.left); });
          n = n.concat(ruleCols(s.rule, 'x'));
          break;
        case 'supp':
          n = n.concat(s.keys || []);
          (s.idvars || []).forEach(function (v) { n.push(v.idvar); });
          break;
      }
      return n;
    }
    // The columns a SUPP card must have for a merge step that reads it.
    function suppNeeds(s) {
      return ['USUBJID', 'IDVAR', 'IDVARVAL', 'QNAM', 'QVAL'].concat(s.keys || [], s.rdomain_col ? ['RDOMAIN'] : []);
    }

    this.change('refresh', function () {
      var live = function (s) { return s.enabled !== false; };
      if (columns === null || columns === undefined) {
        self.steps.forEach(function (s) {
          if (live(s) && (s.table === table || (s.kind === 'join' && s.right === table) ||
              (s.kind === 'supp' && s.supp === table))) {
            note(s, []);
            s.enabled = false;
          }
        });
        return;
      }
      var cols = columns.slice();
      var unknown = false;
      self.steps.forEach(function (s) {
        if (s.table !== table || !live(s)) return;
        if (!unknown) {
          var miss = lack(cols, leftNeeds(s, cols));
          if (miss.length) { note(s, miss); s.enabled = false; return; }
          stepColumns(s, cols);
        }
        if (unknownAfter(s)) unknown = true;
      });
      var endCols = unknown ? null : cols;
      self.steps.forEach(function (s) {
        if (s.kind !== 'join' || s.right !== table || s.table === table || !live(s) || !endCols) return;
        var need = (s.by || []).map(function (b) { return b.right; }).concat(ruleCols(s.rule, 'y'));
        var miss = lack(endCols, need);
        if (miss.length) { note(s, miss); s.enabled = false; }
      });
      self.steps.forEach(function (s) {
        if (s.kind !== 'supp' || s.supp !== table || s.table === table || !live(s) || !endCols) return;
        var miss = lack(endCols, suppNeeds(s));
        if (miss.length) { note(s, miss); s.enabled = false; }
      });
    });

    var disabled = order.map(function (id) { return found[id]; });
    var missing = [];
    disabled.forEach(function (d) { d.missing.forEach(function (c) { if (missing.indexOf(c) < 0) missing.push(c); }); });
    if (disabled.length) { this.undoStack = []; this.redoStack = []; }
    return { disabled: disabled, missing: missing };
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

  // Steps that change which rows a chain holds (or that run code of their own). arrange, rename,
  // mutate and recode keep the rows, so a Strict join after them still sees the checked data.
  var ROW_CHANGING = { join: 1, filter: 1, summarise: 1, reshape: 1, custom: 1 };
  var STRICT_LAZY_REASON = 'Strict runs in R only: duckdb rejects relationship and unmatched, and arrow ignores them';

  /**
   * Whether Strict may write relationship / unmatched into a join step: { ok, reason }.
   * The join check looks at the two original tables, so the arguments are only valid when this join
   * is the first row-changing step on its left table's chain, the right side is the raw table (not
   * a chain of its own) and the chain runs in R. compose() and the UI both ask here.
   */
  Pipeline.prototype.strictApplies = function (step) {
    if (!step || step.kind !== 'join') return { ok: false, reason: 'Strict applies to joins only.' };
    if (this.lazyKind(step.table) || this.lazyKind(step.right)) return { ok: false, reason: STRICT_LAZY_REASON };
    var steps = this.steps.filter(function (x) { return x.enabled !== false; });
    var at = steps.indexOf(step);
    if (at < 0) {
      for (var i = 0; i < steps.length; i++) if (steps[i].id !== undefined && steps[i].id === step.id) { at = i; break; }
    }
    var earlier = at < 0 ? [] : steps.slice(0, at);
    var changed = earlier.some(function (x) { return x.table === step.table && ROW_CHANGING[x.kind]; });
    if (changed) {
      return { ok: false, reason: 'Strict applies only to a join on the original tables: an earlier step changes the rows' };
    }
    var prepared = step.right !== step.table && steps.some(function (x) {
      return x.table === step.right && x.kind !== 'custom';
    });
    if (prepared) {
      return { ok: false, reason: 'Strict applies only to a join on the original tables: ' + step.right + ' has steps of its own' };
    }
    return { ok: true, reason: '' };
  };

  /** Compose the enabled steps into one R script ('' when there is nothing). */
  // Known limit: a factor column holding NA segfaults duckdb 1.4.x when an arrow table is scanned through it.
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
        // A SUPP card with steps of its own is prepared first; its chain feeds <supp>_q.
        if (s.kind === 'supp' && s.supp !== t && chains[s.supp]) {
          (consumers[s.supp] = consumers[s.supp] || {})[t] = true;
        }
      });
    });

    var self = this;
    var out = [];
    var state = {};
    var asPrep = {};
    var finished = {};  // t -> { kind }: the chain's lazy backend after its steps

    function prepName(t) { return ident(t + '_prep'); }

    // The first duckdb card the steps use. An arrow rule chain moves onto its connection, so a later
    // join to a duckdb card shares the src (a chain on arrow's own duckdb connection does not).
    var duckRef = null;
    steps.some(function (s) {
      return [s.table, s.right].some(function (n) {
        if (n && self.lazyKind(n) === 'duckdb') { duckRef = self.refFor(n); return true; }
        return false;
      });
    });
    // con = for arrow::to_duckdb() in a rule move: the user's connection, else arrow's default one.
    var moveCon = duckRef ? ', con = dbplyr::remote_con(' + duckRef + ')' : '';

    // What a joined table is, as a join input: its code and its lazy backend.
    function rightInfo(r) {
      if (asPrep[r] && finished[r]) return { ref: prepName(r), kind: finished[r].kind };
      return { ref: self.refFor(r), kind: self.lazyKind(r) };
    }

    function render(t) {
      var kind = self.lazyKind(t);
      var con = kind ? self.refFor(t) : null;  // something dbplyr::remote_con() can read
      var lines = [self.refFor(t)];
      // A join across backends moves the left side into the right side's engine first:
      // wrapHead(open, rest) makes the chain so far the argument in open + <chain> + rest.
      function wrapHead(open, rest) {
        if (lines.length === 1) { lines = [open + lines[0] + rest]; return; }
        lines = [open.replace(/ $/, '') + '\n  ' + lines.join(' ' + pipe + '\n    ') + rest.replace(/^, /, ',\n  ')];
      }
      var supps = [];  // supp steps: their prep statements go before the chain

      chains[t].forEach(function (s) {
        if (s.kind === 'supp') {
          if (!s.idvars || !s.idvars.length) return;
          var si = rightInfo(s.supp);
          supps.push({ step: s, src: si.ref, lazy: !!si.kind, arrow: kind === 'arrow' });
          lines = lines.concat(suppJoins(s, kind));
          return;
        }
        if (s.kind === 'join') {
          var r = rightInfo(s.right);
          var rightRef = r.ref;
          var ctx = {};
          var hasRule = !!s.rule && !self.joinRuleProblem(s);
          if (hasRule && kind === 'arrow' && r.kind !== 'duckdb') {
            // arrow has no inequality join: a rule join runs in duckdb. Both sides move onto one
            // connection: a duckdb card's (moveCon) or, with none, arrow's default one.
            wrapHead('dplyr::compute(arrow::to_duckdb(', moveCon + '))');
            if (r.kind === 'arrow') rightRef = 'dplyr::compute(arrow::to_duckdb(' + r.ref + moveCon + '))';
            else ctx.copy = true;
            kind = 'duckdb';
            con = duckRef;
          } else if (hasRule && !kind && r.kind === 'arrow') {
            wrapHead('dplyr::compute(arrow::to_duckdb(arrow::arrow_table(', ')' + moveCon + '))');
            rightRef = 'dplyr::compute(arrow::to_duckdb(' + r.ref + moveCon + '))';
            kind = 'duckdb';
            con = duckRef;
          } else if (kind === 'duckdb' && !r.kind) ctx.copy = true;
          else if (kind === 'duckdb' && r.kind === 'arrow') {
            // compute(): to_duckdb() registers a view that R's garbage collector may drop before
            // the query runs ("Table arrow_003 does not exist"); compute() makes a real table.
            // con is null after a rule join moved arrow into arrow's default duckdb connection
            // (no duckdb card in the steps).
            rightRef = 'dplyr::compute(arrow::to_duckdb(' + r.ref +
              (con ? ', con = dbplyr::remote_con(' + con + ')' : '') + '))';
          } else if (kind === 'arrow' && r.kind === 'duckdb') {
            wrapHead('dplyr::compute(arrow::to_duckdb(', ', con = dbplyr::remote_con(' + r.ref + ')))');
            kind = 'duckdb';
            con = r.ref;
          } else if (!kind && r.kind === 'duckdb') {
            // A name of our own: copy_to(overwrite = TRUE) under the data frame's name would
            // replace a real table of that name in the user's database.
            wrapHead('dplyr::copy_to(dbplyr::remote_con(' + r.ref + '), ',
              ', name = ' + str('sideview_' + t) + ', overwrite = TRUE)');
            kind = 'duckdb';
            con = r.ref;
          } else if (!kind && r.kind === 'arrow') {
            wrapHead('arrow::arrow_table(', ')');
            kind = 'arrow';
            con = null;
          }
          // The rule forms: `kind` is the chain's backend now that any cross-backend move above has
          // happened, so with a rule it is null (in memory) or 'duckdb'.
          if (hasRule) {
            ctx.rule = true;
            ctx.kind = kind;
            ctx.kindOf = function (col) {
              var tx = self.tables[s.table];
              return tx && tx.kinds ? tx.kinds[col] : null;
            };
          }
          // Strict: the join check's arguments for this join type, when the chain is in memory here
          // (kind is null after any move above), the join is on the checked tables (strictApplies)
          // and a rule, if any, holds.
          if (s.strict && !kind && (!s.rule || hasRule) && self.strictApplies(s).ok) {
            var chk = self.checks[self.joinSig(s)];
            var jt = JOIN_TYPES.indexOf(s.type) >= 0 ? s.type : 'left_join';
            var sa = chk && Object.prototype.hasOwnProperty.call(chk, jt) ? chk[jt] : null;
            if (sa && typeof sa.relationship === 'string') ctx.strict = sa;
          }
          lines = lines.concat(verbs(s, function () { return rightRef; }, ctx));
          return;
        }
        var vs = verbs(s, ident, { kind: kind });
        if (s.kind === 'reshape' && kind === 'arrow' && vs.length) {
          // arrow has no pivot: bring the data into R first (duckdb pivots in SQL).
          vs.unshift('# reshape runs in R\n  dplyr::collect()');
          kind = null;
          con = null;
        }
        lines = lines.concat(vs);
      });

      // A chain is prepared (assigned) when a chain not yet written joins it.
      var later = Object.keys(consumers[t] || {}).some(function (c) { return state[c] !== 2; });
      asPrep[t] = later;
      finished[t] = { kind: kind };
      var head = (later ? prepName(t) + ' <- ' : '');
      if (lines.length === 1) return later ? head + lines[0] : '';
      // One collect() ends a lazy chain that is written out (a prepared chain stays lazy).
      if (kind && !later) lines.push('dplyr::collect()');
      // QNAM labels are set where the chain ends in memory: after the final collect(), and not at
      // all on a lazy chain prepared for another chain (attributes do not survive a lazy table).
      var withLabels = !(kind && later);
      var preps = supps.map(function (p) {
        if (withLabels && suppLabels(p.step).length) lines.push(suppLabelLine(p.step));
        return suppPrep(p.step, p.src, p.lazy, self.refFor(t), pipe, withLabels, p.arrow);
      });
      var chain = head + lines.join(' ' + pipe + '\n  ');
      return preps.length ? preps.join('\n\n') + '\n\n' + chain : chain;
    }

    function visit(t) {
      if (state[t]) return;  // done, or a join cycle: use the raw table
      state[t] = 1;
      chains[t].forEach(function (s) {
        if (s.kind === 'join' && s.right !== t && chains[s.right]) visit(s.right);
        if (s.kind === 'supp' && s.supp !== t && chains[s.supp]) visit(s.supp);
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

  // ---- a date rule in the join check (twin of R/join_rules.R) ----
  // Under a rule a missing key or rule value matches nothing (na_matches = "never").

  var RULE_SCALE = { 'Date': 1, 'date-time': 86400000, 'numeric': 1 };
  var RULE_DATE = /^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2})(\.\d+)?)?Z?)?$/;

  /**
   * A rule value as a number: a Date in days since 1970-01-01, a date-time in ms since the epoch
   * read as UTC wall clock (a DST change can differ from R by an hour), a number as it is.
   * NaN, which never matches, when missing or unparseable.
   */
  function ruleValue(v, kind) {
    if (isMissing(v)) return NaN;
    if (kind === 'numeric') return typeof v === 'number' ? v : NaN;
    var m = typeof v === 'string' ? RULE_DATE.exec(v.trim()) : null;
    if (!m || (kind === 'Date' && m[4] !== undefined) || (kind !== 'Date' && kind !== 'date-time')) return NaN;
    var y = +m[1], mo = +m[2] - 1, d = +m[3];
    var t = new Date(0);
    t.setUTCFullYear(y, mo, d);
    if (t.getUTCFullYear() !== y || t.getUTCMonth() !== mo || t.getUTCDate() !== d) return NaN;
    if (kind === 'Date') return t.getTime() / 86400000;
    var h = +(m[4] || 0), mi = +(m[5] || 0), s = +(m[6] || 0);
    if (h > 23 || mi > 59 || s > 59) return NaN;
    return t.getTime() + ((h * 60 + mi) * 60 + s) * 1000 + (m[7] ? Number(m[7]) * 1000 : 0);
  }

  /**
   * How many rule pairs each row is in: px[i] / py[j] for x row i / y row j, n in all. `kx` / `ky`
   * are row keys (null: a missing key); `v` holds the rule values xa, xb, ya, yb (window bounds
   * already in xa..xb). A nearest match keeps every y row at the nearest value (ties).
   */
  function rulePairs(kx, ky, v, rule) {
    var px = [], py = [], n = 0, i, j, k;
    for (i = 0; i < kx.length; i++) px.push(0);
    for (j = 0; j < ky.length; j++) py.push(0);
    var groups = new Map();
    for (j = 0; j < ky.length; j++) {
      if (ky[j] === null) continue;
      if (!groups.has(ky[j])) groups.set(ky[j], []);
      groups.get(ky[j]).push(j);
    }
    var shape = rule.shape, strict = rule.inclusive === false;
    var before = shape === 'before', nearest = before || shape === 'after';
    for (i = 0; i < kx.length; i++) {
      var g = kx[i] === null ? null : groups.get(kx[i]);
      if (!g) continue;
      var a = v.xa[i], b = v.xb ? v.xb[i] : NaN, hits = [], best = NaN;
      for (k = 0; k < g.length; k++) {
        j = g[k];
        var ya = v.ya[j];
        if (nearest) {
          // comparisons with NaN are false, so a missing value never matches
          if (!(before ? (strict ? ya < a : ya <= a) : (strict ? ya > a : ya >= a))) continue;
          if (hits.length && ya !== best) {
            if (before ? ya < best : ya > best) continue;
            hits = [];
          }
          best = ya;
          hits.push(j);
        } else if (shape === 'between' ? ya <= a && a <= v.yb[j] :
                   shape === 'overlaps' ? a <= v.yb[j] && b >= ya : a <= ya && ya <= b) {
          hits.push(j);
        }
      }
      for (k = 0; k < hits.length; k++) { px[i]++; py[hits[k]]++; n++; }
    }
    return { px: px, py: py, n: n };
  }

  /**
   * What Strict writes into a join, per join type (twin of sv_join_strict_args()): an entry is absent
   * when it would write nothing. `unmatched = "error"` only when every row of the checked side matches.
   */
  function strictArgs(d, rule) {
    var out = {};
    if (d.relationship === 'no matches') return out;
    var nearest = !!rule && (rule.shape === 'before' || rule.shape === 'after');
    var allX = d.matched_x === d.n_x, allY = d.matched_y === d.n_y;
    ['left_join', 'inner_join', 'right_join', 'full_join'].forEach(function (type) {
      if (nearest && (type === 'right_join' || type === 'full_join')) return;
      var args = { relationship: d.relationship };
      if (type === 'left_join' ? allY : type === 'right_join' ? allX : type === 'inner_join' && allX && allY) {
        args.unmatched = 'error';
      }
      out[type] = args;
    });
    return out;
  }

  /**
   * Diagnose a join before running it.
   * @param xCols,yCols column arrays keyed by name ({ id: [...], ... }); with a rule, the rule columns too
   * @param by [{ left, right }] key pairs
   * @param opts { rule, sampleN, xName, yName, xTypes, yTypes } (types are R class names). A rule that
   *   does not hold gives { error } with the message R stops with.
   */
  function joinDiagnostics(xCols, yCols, by, opts) {
    opts = opts || {};
    var xName = opts.xName || 'x', yName = opts.yName || 'y';
    var sampleN = opts.sampleN === undefined ? 5 : opts.sampleN;
    var byX = by.map(function (p) { return p.left; });
    var byY = by.map(function (p) { return p.right; });
    var kindsX = byX.map(function (c) { return keyKind((opts.xTypes || {})[c] || guessKind(xCols[c])); });
    var kindsY = byY.map(function (c) { return keyKind((opts.yTypes || {})[c] || guessKind(yCols[c])); });
    var rule = opts.rule || null, ruleKind = null;
    if (rule) {
      var colKinds = function (cols, types) {
        var m = {};
        Object.keys(cols).forEach(function (c) { m[c] = keyKind((types || {})[c] || guessKind(cols[c])); });
        return m;
      };
      var kmX = colKinds(xCols, opts.xTypes);
      var problem = ruleProblem(rule, kmX, colKinds(yCols, opts.yTypes), 'left_join');
      if (problem) return { error: problem };
      rule = normalizeRule(rule);
      ruleKind = kmX[rule[ruleSlots(rule.shape)[0].slot]];
    }
    var kx = joinKeys(xCols, byX, kindsX), ky = joinKeys(yCols, byY, kindsY);
    var core = joinCounts(kx, ky);
    var nX = kx.length, nY = ky.length;
    var rowNa = function (cols, names, i) {
      return names.some(function (c) { return isMissing(cols[c][i]); });
    };
    var anyNa = function (cols, names) {
      var n = 0;
      for (var i = 0; i < (names.length ? cols[names[0]].length : 0); i++) {
        if (rowNa(cols, names, i)) n++;
      }
      return n;
    };
    var rp = null, ruleKeys = null, ruleVals = null, ruleDropped = null;
    if (rule) {
      // keys with null for a row with a missing key part (it matches nothing under a rule)
      ruleKeys = function (fn) {
        var rx = joinKeys(xCols, byX, kindsX, fn), ry = joinKeys(yCols, byY, kindsY, fn);
        return {
          x: rx.map(function (k, i) { return rowNa(xCols, byX, i) ? null : k; }),
          y: ry.map(function (k, j) { return rowNa(yCols, byY, j) ? null : k; })
        };
      };
      var scale = RULE_SCALE[ruleKind];
      var vals = function (cols, col, n, off) {
        var out = [];
        for (var i = 0; i < n; i++) out.push(ruleValue(cols[col][i], ruleKind) + (off ? off * scale : 0));
        return out;
      };
      var sh = rule.shape;
      if (sh === 'window') {
        ruleVals = { xa: vals(xCols, rule.xCol, nX, rule.from), xb: vals(xCols, rule.xCol, nX, rule.to),
                     ya: vals(yCols, rule.yCol, nY) };
      } else if (sh === 'between') {
        ruleVals = { xa: vals(xCols, rule.xCol, nX), ya: vals(yCols, rule.yFrom, nY), yb: vals(yCols, rule.yTo, nY) };
      } else if (sh === 'overlaps') {
        ruleVals = { xa: vals(xCols, rule.xFrom, nX), xb: vals(xCols, rule.xTo, nX),
                     ya: vals(yCols, rule.yFrom, nY), yb: vals(yCols, rule.yTo, nY) };
      } else {
        ruleVals = { xa: vals(xCols, rule.xCol, nX), ya: vals(yCols, rule.yCol, nY) };
      }
      var rk = ruleKeys(null);
      rp = rulePairs(rk.x, rk.y, ruleVals, rule);
      var matched = function (p) { return p.filter(function (c) { return c > 0; }).length; };
      var mX = matched(rp.px), mY = matched(rp.py);
      var many = function (p) { return p.some(function (c) { return c > 1; }); };
      var manyX = many(rp.py), manyY = many(rp.px);
      // rows with a key partner (a missing key has none) but no rule pair
      var setX = new Set(rk.x.filter(function (k) { return k !== null; }));
      var setY = new Set(rk.y.filter(function (k) { return k !== null; }));
      var partners = function (keys, other) {
        return keys.filter(function (k) { return k !== null && other.has(k); }).length;
      };
      ruleDropped = { x: partners(rk.x, setY) - mX, y: partners(rk.y, setX) - mY };
      var unmatched = function (keys, p) {
        var seen = new Set(), out = [];
        p.forEach(function (c, i) { if (!c && !seen.has(keys[i])) { seen.add(keys[i]); out.push(keys[i]); } });
        return out;
      };
      core.matched_x = mX;
      core.matched_y = mY;
      core.relationship = !rp.n ? 'no matches' : manyX && manyY ? 'many-to-many' :
        manyY ? 'one-to-many' : manyX ? 'many-to-one' : 'one-to-one';
      core.rows = {
        left_join: rp.n + (nX - mX), inner_join: rp.n,
        full_join: rp.n + (nX - mX) + (nY - mY), right_join: rp.n + (nY - mY),
        semi_join: mX, anti_join: nX - mX
      };
      // a nearest match has no right or full row count
      if (sh === 'before' || sh === 'after') { delete core.rows.full_join; delete core.rows.right_join; }
      core.unmatched_x = unmatched(kx, rp.px);
      core.unmatched_y = unmatched(ky, rp.py);
    }
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
    d.strict_args = strictArgs(d, rule);
    if (rule) {
      d.rule = rule;
      d.rule_kind = ruleKind;
      d.rule_dropped_x = ruleDropped.x;
      d.rule_dropped_y = ruleDropped.y;
    }
    if (core.matched_x < nX || core.matched_y < nY) {
      var fixes = [
        { fix: 'trim', label: 'trimming whitespace', fn: function (s) { return s.trim(); } },
        { fix: 'case', label: 'ignoring case', fn: function (s) { return s.toLowerCase(); } },
        { fix: 'zeros', label: 'dropping leading zeros', fn: function (s) { return s.replace(/^0+(?=[0-9])/, ''); } }
      ];
      fixes.forEach(function (f) {
        var alt;
        if (rule) {
          var ak = ruleKeys(f.fn), ap = rulePairs(ak.x, ak.y, ruleVals, rule);
          var hit = function (p) { return p.filter(function (c) { return c > 0; }).length; };
          alt = { matched_x: hit(ap.px), matched_y: hit(ap.py) };
        } else {
          alt = joinCounts(joinKeys(xCols, byX, kindsX, f.fn), joinKeys(yCols, byY, kindsY, f.fn));
        }
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
      w.push('Missing keys (' + fmtN(d.na_x) + ' in ' + xName + ', ' + fmtN(d.na_y) + ' in ' + yName + '): ' +
        (rule ? 'with a date rule they match nothing (na_matches = "never").' :
          'dplyr matches NA to NA by default (na_matches = "na").'));
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
    // a check that could not run (a missing column, a rule that does not hold) has no counts
    if (d && d.error) return String(d.error);
    var rows = d.rows[type || 'left_join'];
    var rel = { 'one-to-one': '1:1', 'one-to-many': '1:m', 'many-to-one': 'm:1', 'many-to-many': 'm:m' }[d.relationship] ||
      d.relationship;
    return rel + ' · ' + Math.round(100 * d.match_rate_x) + '% of ' + (xName || 'x') + ' matched · ' +
      (rows === undefined ? '' : fmtN(rows) + ' rows');
  }

  // ---- Column profile and codebook -----------------------------------------
  // Mirrors sv_column_profile() / sv_codebook() in R/codebook.R so the saved
  // widget can inspect columns without R. Change both together.

  function profileKind(type, values) {
    var t = String(type || '').toLowerCase();
    if (!t) t = guessKind(values);
    if (t === 'date') return 'date';
    if (t === 'posixct' || t === 'posixt' || t === 'posixlt' || t === 'datetime' || t === 'dttm') return 'datetime';
    if (t === 'character' || t === 'factor' || t === 'ordered' || t === 'string' || t === 'chr' || t === 'fct') return 'character';
    if (t === 'logical' || t === 'lgl') return 'logical';
    if (NUMERIC_TYPES[t]) return 'numeric';
    return 'other';
  }

  // R's format_key() for one number: up to 15 significant digits, no exponent.
  function numKey(v) {
    var n = parseFloat(Number(v).toPrecision(15));
    var s = String(n);
    if (/e/i.test(s)) {
      s = Math.abs(n) >= 1 ? n.toLocaleString('en-US', { useGrouping: false, maximumFractionDigits: 0 }) :
        n.toFixed(20).replace(/\.?0+$/, '');
    }
    return s;
  }

  function rTrim(s) { return s.replace(/^[ \t\r\n]+|[ \t\r\n]+$/g, ''); }

  function nOf(n, one, many) { return fmtN(n) + ' ' + (n === 1 ? one : many); }

  function codeCompare(a, b) { return a < b ? -1 : a > b ? 1 : 0; }

  function quantile7(sorted, p) {
    var h = (sorted.length - 1) * p, lo = Math.floor(h);
    if (lo + 1 >= sorted.length) return sorted[sorted.length - 1];
    return sorted[lo] + (h - lo) * (sorted[lo + 1] - sorted[lo]);
  }

  function histogram(v, bins) {
    var lo = Infinity, hi = -Infinity;
    for (var i = 0; i < v.length; i++) { if (v[i] < lo) lo = v[i]; if (v[i] > hi) hi = v[i]; }
    if (lo === hi) return { breaks: [lo, hi], counts: [v.length] };
    var width = (hi - lo) / bins, counts = new Array(bins).fill(0), breaks = [];
    for (var j = 0; j < v.length; j++) counts[Math.min(Math.floor((v[j] - lo) / width), bins - 1)]++;
    for (var k = 0; k <= bins; k++) breaks.push(lo + width * k);
    return { breaks: breaks, counts: counts };
  }

  /**
   * Profile one column for the inspector.
   * @param values column values (null for NA)
   * @param type R class name of the column (optional; guessed from values)
   * @param opts { topN = 10, bins = 20, label }
   */
  function columnProfile(values, type, opts) {
    opts = opts || {};
    var topN = opts.topN === undefined ? 10 : opts.topN;
    var bins = opts.bins === undefined ? 20 : opts.bins;
    values = values || [];
    var kind = profileKind(type, values);
    var n = values.length, vals = [];
    for (var i = 0; i < n; i++) if (!isMissing(values[i])) vals.push(values[i]);
    var nMissing = n - vals.length;

    var counts = new Map();
    vals.forEach(function (v) {
      var k = kind === 'numeric' ? Number(v) :
        kind === 'logical' ? (v === true || v === 'TRUE' ? 'TRUE' : 'FALSE') : String(v);
      counts.set(k, (counts.get(k) || 0) + 1);
    });
    var nDistinct = counts.size;
    var out = {
      kind: kind, 'class': type || kind, label: opts.label || null,
      n: n, n_missing: nMissing, pct_missing: n ? nMissing / n : 0,
      n_distinct: nDistinct, unique_key: n > 0 && nMissing === 0 && nDistinct === n,
      stats: null, histogram: null, top: [], n_other: 0, issues: []
    };

    if (kind === 'numeric') {
      var v = vals.map(Number).filter(function (x) { return isFinite(x); })
        .sort(function (a, b) { return a - b; });
      if (v.length) {
        var sum = 0;
        v.forEach(function (x) { sum += x; });
        var mean = sum / v.length, ss = 0;
        v.forEach(function (x) { ss += (x - mean) * (x - mean); });
        out.stats = {
          min: v[0], q1: quantile7(v, 0.25), median: quantile7(v, 0.5), q3: quantile7(v, 0.75),
          max: v[v.length - 1], mean: mean, sd: v.length > 1 ? Math.sqrt(ss / (v.length - 1)) : null
        };
        out.histogram = histogram(v, bins);
      }
    } else if ((kind === 'date' || kind === 'datetime') && vals.length) {
      var s = vals.map(String).sort(codeCompare);
      var pick = function (p) { return s[Math.max(1, Math.ceil(s.length * p)) - 1]; };
      out.stats = { min: s[0], q1: pick(0.25), median: pick(0.5), q3: pick(0.75), max: s[s.length - 1] };
    }

    var showTop = kind === 'character' || kind === 'logical' || kind === 'other' ||
      (kind === 'numeric' && nDistinct <= topN);
    if (showTop && nDistinct && !out.unique_key) {
      var entries = Array.from(counts.entries()).sort(function (a, b) {
        return b[1] - a[1] || (kind === 'numeric' ? a[0] - b[0] : codeCompare(a[0], b[0]));
      });
      out.top = entries.slice(0, topN).map(function (e) {
        return { value: kind === 'numeric' ? numKey(e[0]) : e[0], n: e[1] };
      });
      out.n_other = nDistinct - out.top.length;
    }

    out.issues = profileIssues(kind, vals, out);
    return out;
  }

  function profileIssues(kind, vals, p) {
    var out = [];
    if (p.n > 0 && p.n_missing === p.n) return ['All values are missing.'];
    if (p.n_distinct === 1 && p.n > 1) out.push('Only one distinct value.');
    if (kind === 'character') {
      var s = vals.map(String);
      var spaced = s.filter(function (x) { return x !== rTrim(x); }).length;
      if (spaced) out.push(nOf(spaced, 'value has', 'values have') + ' leading or trailing spaces.');
      var empty = s.filter(function (x) { return x === ''; }).length;
      if (empty) out.push(nOf(empty, 'empty string', 'empty strings') + ', not NA.');
      var groups = new Map();
      Array.from(new Set(s)).forEach(function (x) {
        var f = rTrim(x).toLowerCase();
        if (!groups.has(f)) groups.set(f, []);
        groups.get(f).push(x);
      });
      var variants = Array.from(groups.entries())
        .filter(function (g) { return g[1].length > 1; })
        .sort(function (a, b) { return codeCompare(a[0], b[0]); });
      if (variants.length) {
        var eg = variants[0][1].slice().sort(codeCompare).slice(0, 3)
          .map(function (x) { return '"' + x + '"'; }).join(' / ');
        out.push(nOf(variants.length, 'value differs', 'values differ') +
          ' only in case or spacing (e.g. ' + eg + ').');
      }
      var nonblank = s.filter(function (x) { return rTrim(x) !== ''; }).map(rTrim);
      var numRe = /^[-+]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$/;
      if (nonblank.length && nonblank.every(function (x) { return numRe.test(x); })) {
        out.push('All values are numbers stored as text.');
      }
    }
    if (kind === 'numeric' && p.stats) {
      var iqr = p.stats.q3 - p.stats.q1;
      if (isFinite(iqr) && iqr > 0) {
        var lo = p.stats.q1 - 3 * iqr, hi = p.stats.q3 + 3 * iqr;
        var far = vals.map(Number).filter(function (x) { return isFinite(x) && (x < lo || x > hi); });
        if (far.length) {
          var ex = Array.from(new Set(far)).sort(function (a, b) { return b - a; }).slice(0, 3).map(numKey);
          out.push(nOf(far.length, 'value lies', 'values lie') +
            ' beyond 3 IQR of the quartiles (e.g. ' + ex.join(', ') + ').');
        }
      }
    }
    return out;
  }

  function signif6(v) { return parseFloat(Number(v).toPrecision(6)); }

  /**
   * One codebook row; mirrors sv_codebook_row() in R. `opts.nTotal` is the true row count of a
   * table profiled from a preview: `n` reports it and `rows_profiled` the rows used.
   * `opts.domain` is the table's CDISC domain (null when untagged).
   */
  function codebookRow(table, column, position, values, type, opts) {
    opts = opts || {};
    var p = columnProfile(values, type, { topN: opts.topN === undefined ? 5 : opts.topN, label: opts.label });
    var st = p.stats || {};
    var stat = function (k) {
      var v = st[k];
      if (v === undefined || v === null || (typeof v === 'number' && !isFinite(v))) return null;
      return typeof v === 'number' ? numKey(signif6(v)) : String(v);
    };
    var num = function (k) {
      var v = st[k];
      return typeof v === 'number' && isFinite(v) ? signif6(v) : null;
    };
    var top = null;
    if (p.top.length) {
      top = p.top.map(function (t) { return t.value + ' (' + t.n + ')'; }).join('; ');
      if (p.n_other > 0) top += '; +' + p.n_other + ' more';
    }
    return {
      table: table, domain: opts.domain === undefined ? null : opts.domain,
      column: column, position: position, 'class': p['class'], label: p.label,
      n: opts.nTotal === undefined || opts.nTotal === null ? p.n : opts.nTotal, rows_profiled: p.n,
      n_missing: p.n_missing, pct_missing: Math.round(10000 * p.pct_missing) / 100,
      n_distinct: p.n_distinct, unique_key: p.unique_key,
      min: stat('min'), q1: stat('q1'), median: stat('median'), q3: stat('q3'), max: stat('max'),
      mean: num('mean'), sd: num('sd'), top_values: top,
      issues: p.issues.length ? p.issues.join(' ') : null
    };
  }

  var CODEBOOK_FIELDS = ['table', 'domain', 'column', 'position', 'class', 'label', 'n', 'rows_profiled', 'n_missing',
    'pct_missing',
    'n_distinct', 'unique_key', 'min', 'q1', 'median', 'q3', 'max', 'mean', 'sd', 'top_values', 'issues'];
  var CODEBOOK_TEXT = { table: 1, domain: 1, column: 1, 'class': 1, label: 1, min: 1, q1: 1, median: 1, q3: 1, max: 1,
    top_values: 1, issues: 1 };

  /** Codebook rows as CSV, laid out like utils::write.csv(row.names = FALSE, na = ""). */
  function codebookCsv(rows) {
    var q = function (s) { return '"' + String(s).replace(/"/g, '""') + '"'; };
    var lines = [CODEBOOK_FIELDS.map(q).join(',')];
    rows.forEach(function (r) {
      lines.push(CODEBOOK_FIELDS.map(function (f) {
        var v = r[f];
        if (v === null || v === undefined) return '';
        if (typeof v === 'boolean') return v ? 'TRUE' : 'FALSE';
        return CODEBOOK_TEXT[f] ? q(v) : String(v);
      }).join(','));
    });
    return lines.join('\n') + '\n';
  }

  /**
   * Split a copilot reply around its fenced code: the prose before the first fence and the
   * prose after it (other fences removed), so the chat bubble keeps the reply's order.
   * `hasCode` is true when the reply had at least one fence.
   */
  function splitReply(text) {
    var fence = /```(?:\{?[a-zA-Z0-9_,-]*\}?)?[\s\S]*?```/g;
    var s = String(text == null ? '' : text);
    var m = fence.exec(s);
    if (!m) return { before: s.trim(), after: '', hasCode: false };
    var after = s.slice(m.index + m[0].length).replace(fence, '\n').replace(/\n{3,}/g, '\n\n').trim();
    return { before: s.slice(0, m.index).trim(), after: after, hasCode: true };
  }

  // ---- date rules on join steps -----------------------------------------------
  // A join step may carry `rule` (a date condition between the two tables) and `strict`
  // (stop on a problem the join check finds). Both are optional step fields: they travel in
  // the workspace state (schema v0.3.0) and an old state without them loads unchanged.

  var RULE_SHAPES = ['between', 'window', 'before', 'after', 'overlaps'];
  var RULE_SLOTS = {
    between: [['xCol', 'x'], ['yFrom', 'y'], ['yTo', 'y']],
    window: [['xCol', 'x'], ['yCol', 'y']],
    before: [['xCol', 'x'], ['yCol', 'y']],
    after: [['xCol', 'x'], ['yCol', 'y']],
    overlaps: [['xFrom', 'x'], ['xTo', 'x'], ['yFrom', 'y'], ['yTo', 'y']]
  };
  var RULE_KINDS = { 'Date': 1, 'date-time': 1, 'numeric': 1 };
  var RULE_MAX_DAYS = 3650;

  function ruleSlots(shape) {
    var slots = Object.prototype.hasOwnProperty.call(RULE_SLOTS, shape) ? RULE_SLOTS[shape] : [];
    return slots.map(function (p) { return { slot: p[0], side: p[1] }; });
  }

  /** A column-to-kind map with every kind in keyKind() names; non-text entries are dropped. */
  function tableKinds(kinds) {
    var out = {};
    if (kinds && typeof kinds === 'object') {
      Object.keys(kinds).forEach(function (c) {
        if (typeof kinds[c] === 'string' && kinds[c] !== '') out[c] = keyKind(kinds[c]);
      });
    }
    return out;
  }

  /** A whole number from a number or a numeric string; null for anything else (range not checked). */
  function wholeNumber(v) {
    if (typeof v === 'number') return isFinite(v) && Math.floor(v) === v ? v : null;
    if (typeof v === 'string' && /^\s*[-+]?\d+\s*$/.test(v)) return parseInt(v, 10);
    return null;
  }

  /**
   * The first problem with a date rule, or null. `kindsX` / `kindsY` map column to kind for the
   * left (`table`) and right (`right`) side; `type` is the join type.
   */
  function ruleProblem(rule, kindsX, kindsY, type) {
    if (!rule || RULE_SHAPES.indexOf(rule.shape) < 0) return 'Unknown date rule.';
    var slots = ruleSlots(rule.shape);
    var i;
    for (i = 0; i < slots.length; i++) {
      var v = rule[slots[i].slot];
      if (typeof v !== 'string' || v === '') return 'Pick a column for every slot.';
    }
    var cols = slots.map(function (sl) {
      var map = (sl.side === 'x' ? kindsX : kindsY) || {};
      var name = rule[sl.slot];
      return { col: name, kind: Object.prototype.hasOwnProperty.call(map, name) ? keyKind(map[name]) : null };
    });
    for (i = 0; i < cols.length; i++) {
      if (!cols[i].kind || !RULE_KINDS[cols[i].kind]) return cols[i].col + ' is not a date, date-time or number.';
    }
    for (i = 1; i < cols.length; i++) {
      if (cols[i].kind !== cols[0].kind) {
        return cols[0].col + ' is ' + cols[0].kind + ' but ' + cols[i].col + ' is ' + cols[i].kind +
          ': both sides of a date rule need the same kind.';
      }
    }
    if (rule.shape === 'window') {
      var from = wholeNumber(rule.from), to = wholeNumber(rule.to);
      if (from === null || to === null || Math.abs(from) > RULE_MAX_DAYS || Math.abs(to) > RULE_MAX_DAYS) {
        return 'Window bounds must be whole numbers from -3650 to 3650.';
      }
      if (from > to) return 'The window start must not be after its end.';
    }
    if ((rule.shape === 'before' || rule.shape === 'after') && (type === 'right_join' || type === 'full_join')) {
      return 'A nearest-match rule works with left, inner, semi and anti joins only.';
    }
    return null;
  }

  function signedOffset(n) {
    n = Number(n);
    return n > 0 ? '+' + n : String(n);
  }

  /** The rule as words, without a leading separator. `kindX` decides days or the column's own unit. */
  function ruleLabel(rule, kindX) {
    if (!rule) return '';
    switch (rule.shape) {
      case 'window':
        return rule.yCol + ' within ' + signedOffset(rule.from) + '..' + signedOffset(rule.to) +
          (kindX === 'numeric' ? '' : ' days') + ' of ' + rule.xCol;
      case 'before':
        return 'last ' + rule.yCol + (rule.inclusive === false ? ' before ' : ' on or before ') + rule.xCol;
      case 'after':
        return 'first ' + rule.yCol + (rule.inclusive === false ? ' after ' : ' on or after ') + rule.xCol;
      case 'between':
        return rule.xCol + ' between ' + rule.yFrom + ' and ' + rule.yTo;
      case 'overlaps':
        return rule.xFrom + '..' + rule.xTo + ' overlaps ' + rule.yFrom + '..' + rule.yTo;
    }
    return '';
  }

  /** A rule as it is stored: its shape and slots, window bounds as numbers, inclusive as a boolean. */
  function normalizeRule(rule) {
    var out = { shape: rule.shape };
    ruleSlots(rule.shape).forEach(function (sl) {
      out[sl.slot] = typeof rule[sl.slot] === 'string' ? rule[sl.slot] : '';
    });
    if (rule.shape === 'window') {
      ['from', 'to'].forEach(function (k) {
        var n = wholeNumber(rule[k]);
        // anything that is not a whole number is kept as typed, and ruleProblem says why
        if (n !== null) out[k] = n;
        else if (rule[k] !== undefined && rule[k] !== null) out[k] = rule[k];
      });
    }
    if (rule.shape === 'before' || rule.shape === 'after') out.inclusive = rule.inclusive !== false;
    return out;
  }

  /** Set or clear (null) the date rule of a join step. One undo restores the rule and any type change. */
  Pipeline.prototype.setJoinRule = function (id, rule) {
    var self = this;
    var step = this.find(id);
    if (!step || step.kind !== 'join') return false;
    if (rule && RULE_SHAPES.indexOf(rule.shape) < 0) return false;
    return this.change('rule', function () {
      var s = self.find(id);
      if (!rule) { delete s.rule; return; }
      s.rule = normalizeRule(rule);
      // a nearest match keeps the left rows only: right and full joins become a left join
      if ((s.rule.shape === 'before' || s.rule.shape === 'after') &&
          (s.type === 'right_join' || s.type === 'full_join')) s.type = 'left_join';
    });
  };

  /** Turn the Strict flag of a join step on or off. */
  Pipeline.prototype.setJoinStrict = function (id, strict) {
    var self = this;
    var step = this.find(id);
    if (!step || step.kind !== 'join') return false;
    return this.change('strict', function () {
      var s = self.find(id);
      if (strict) s.strict = true; else delete s.strict;
    });
  };

  /** The first problem with a join step's rule, from the tables' column kinds; null when fine or absent. */
  Pipeline.prototype.joinRuleProblem = function (step) {
    if (!step || !step.rule) return null;
    var tx = this.tables[step.table], ty = this.tables[step.right];
    return ruleProblem(step.rule, tx ? tx.kinds : {}, ty ? ty.kinds : {}, step.type || 'left_join');
  };

  /** One line for a step, with this pipeline's tables behind a rule's wording. */
  Pipeline.prototype.describe = function (step) { return describe(step, this); };

  /** What identifies a join for the join check: the tables, the key pairs and the rule. */
  Pipeline.prototype.joinSig = function (step) {
    return JSON.stringify([step.table, step.right,
      (step.by || []).map(function (p) { return [p.left, p.right]; }), step.rule || null]);
  };

  /**
   * Remember what the join check found for a join signature (null forgets it). Not pipeline state:
   * no undo, never saved. Emits 'checks' only when the stored value changed.
   */
  Pipeline.prototype.setJoinCheck = function (sig, strictArgs) {
    var had = Object.prototype.hasOwnProperty.call(this.checks, sig);
    if (strictArgs === null || strictArgs === undefined) {
      if (!had) return false;
      delete this.checks[sig];
    } else {
      if (had && JSON.stringify(this.checks[sig]) === JSON.stringify(strictArgs)) return false;
      this.checks[sig] = clone(strictArgs);
    }
    this.emit('checks');
    return true;
  };

  Pipeline.prototype.clearJoinChecks = function () {
    if (!Object.keys(this.checks).length) return false;
    this.checks = {};
    this.emit('checks');
    return true;
  };

  // ---- SUPP-- merge check: twin of sv_supp_check() (R/supp.R) ----------------

  function suppKeyType(colType) {
    var t = String(colType === null || colType === undefined ? '' : colType);
    if (/^(integer|int8|int16|int32)$/.test(t)) return 'integer';
    if (/^(numeric|double|float|int64|integer64)$/.test(t)) return 'double';
    if (/^(character|factor|string|utf8|large_utf8)$/.test(t) || /^dictionary</.test(t)) return 'character';
    return null;
  }

  var SUPP_INT_RE = /^\s*[+-]?[0-9]+\s*$/;
  var SUPP_DBL_RE = /^\s*[+-]?([0-9]+[.]?[0-9]*|[.][0-9]+)([eE][+-]?[0-9]+)?\s*$/;

  // A missing value is the string "NA" once keys are pasted together, as in R.
  function suppChr(v) {
    return v === null || v === undefined ? 'NA' : String(v);
  }

  // IDVARVAL text converted to the key type; null means it did not convert.
  function suppConvert(v, type) {
    if (v === null || v === undefined) return null;
    var s = String(v);
    if (type === 'character') return s;
    if (type === 'integer') {
      if (!SUPP_INT_RE.test(s)) return null;
      var n = parseInt(s.trim(), 10);
      if (!isFinite(n) || Math.abs(n) > 2147483647) return null;
      return String(n);
    }
    if (!SUPP_DBL_RE.test(s)) return null;
    var d = Number(s.trim());
    return isNaN(d) ? null : String(d);
  }

  function suppUnique(a) {
    var seen = {}, out = [];
    a.forEach(function (x) {
      var k = String(x);
      if (!Object.prototype.hasOwnProperty.call(seen, k)) { seen[k] = true; out.push(x); }
    });
    return out;
  }

  function suppSetdiff(a, b) {
    return suppUnique(a).filter(function (x) { return b.indexOf(x) < 0; });
  }

  function suppColNames(rows, given) {
    if (given) return given.slice();
    var seen = {}, out = [];
    rows.forEach(function (r) {
      Object.keys(r).forEach(function (k) { if (!seen[k]) { seen[k] = true; out.push(k); } });
    });
    return out;
  }

  function suppGuessType(rows, col) {
    var all = true, any = false, frac = false;
    rows.forEach(function (r) {
      var v = r[col];
      if (v === null || v === undefined) return;
      any = true;
      if (typeof v !== 'number') { all = false; return; }
      if (v % 1 !== 0) frac = true;
    });
    if (!any || !all) return 'character';
    return frac ? 'numeric' : 'integer';
  }

  // parentRows / suppRows: arrays of row objects. opts: {parentName, suppName, rdomain,
  // parentTypes: {col: colType}, parentCols, suppCols, plan, sampleN}.
  function suppCheck(parentRows, suppRows, opts) {
    opts = opts || {};
    parentRows = parentRows || [];
    suppRows = suppRows || [];
    var parentName = opts.parentName || 'parent', suppName = opts.suppName || 'supp';
    var sampleN = opts.sampleN === undefined || opts.sampleN === null ? 5 : opts.sampleN;
    var fromName = String(suppName).toUpperCase().replace(/^SUPP/, '');
    var rdomain = opts.rdomain === undefined || opts.rdomain === null || opts.rdomain === '' ? fromName : opts.rdomain;
    var warnOther = fromName === rdomain;
    var pNames = suppColNames(parentRows, opts.parentCols), sNames = suppColNames(suppRows, opts.suppCols);
    var i, k;

    var need = ['USUBJID', 'IDVAR', 'IDVARVAL', 'QNAM', 'QVAL'];
    for (i = 0; i < need.length; i++) {
      if (sNames.indexOf(need[i]) < 0) return { error: 'Not in ' + suppName + ': ' + need[i] };
    }
    if (pNames.indexOf('USUBJID') < 0) return { error: 'Not in ' + parentName + ': USUBJID' };

    var hasRd = sNames.indexOf('RDOMAIN') >= 0;
    var nOther = 0;
    if (hasRd) {
      var kept = suppRows.filter(function (r) {
        return r.RDOMAIN !== null && r.RDOMAIN !== undefined && String(r.RDOMAIN) === rdomain;
      });
      nOther = suppRows.length - kept.length;
      suppRows = kept;
    }
    var nSupp = suppRows.length;
    if (!nSupp) return { error: suppName + ' has no rows for ' + rdomain };

    var idvar = suppRows.map(function (r) {
      var v = r.IDVAR;
      return v === null || v === undefined || String(v).trim() === '' ? '' : String(v);
    });
    var qnam = suppRows.map(function (r) { return suppChr(r.QNAM); });
    var levels = suppUnique(idvar);
    levels = levels.filter(function (x) { return x !== ''; }).concat(levels.indexOf('') >= 0 ? [''] : []);

    var types = {};
    for (i = 0; i < levels.length; i++) {
      var iv = levels[i];
      if (iv === '') continue;
      if (pNames.indexOf(iv) < 0) return { error: 'Not in ' + parentName + ': ' + iv };
      var raw = (opts.parentTypes || {})[iv];
      if (raw === undefined || raw === null) raw = suppGuessType(parentRows, iv);
      var ty = suppKeyType(raw);
      if (ty === null) return { error: 'Cannot merge on ' + iv + ': its type is ' + raw };
      types[iv] = ty;
    }

    var keys = ['STUDYID', 'USUBJID'].filter(function (c) { return pNames.indexOf(c) >= 0 && sNames.indexOf(c) >= 0; });
    var keyOf = function (row) { return keys.map(function (c) { return suppChr(row[c]); }).join('\r'); };
    var pkey = parentRows.map(keyOf), skey = suppRows.map(keyOf);

    var val = [], bad = [], matched = [];
    for (i = 0; i < nSupp; i++) { val.push(''); bad.push(false); matched.push(false); }
    var pset = {};
    pkey.forEach(function (x) { pset[x] = true; });
    levels.forEach(function (iv) {
      var pairs = null;
      if (iv !== '') {
        pairs = {};
        parentRows.forEach(function (r, j) { pairs[pkey[j] + '\r' + suppChr(r[iv])] = true; });
      }
      for (var j = 0; j < nSupp; j++) {
        if (idvar[j] !== iv) continue;
        if (iv === '') { matched[j] = !!pset[skey[j]]; continue; }
        var cv = suppConvert(suppRows[j].IDVARVAL, types[iv]);
        val[j] = cv;
        bad[j] = cv === null;
        matched[j] = cv !== null && !!pairs[skey[j] + '\r' + cv];
      }
    });
    var orphan = matched.map(function (m, j) { return !m && !bad[j]; });

    var qn = suppUnique(qnam);
    var hasLabel = sNames.indexOf('QLABEL') >= 0;
    var qnams = qn.map(function (q) {
      var first = -1, lab = '';
      for (var j = 0; j < nSupp; j++) {
        if (qnam[j] !== q) continue;
        if (first < 0) first = j;
        var l = suppRows[j].QLABEL;
        if (hasLabel && l !== null && l !== undefined) { lab = String(l); break; }
      }
      return { qnam: q, label: lab, idvar: idvar[first] };
    });
    var idvars = levels.map(function (iv) { return { idvar: iv, type: iv !== '' ? types[iv] : null }; });
    var newPlan = { keys: keys, idvars: idvars, qnams: qnams, rdomain_col: hasRd };

    var dup = [], seen = {};
    for (i = 0; i < nSupp; i++) {
      var d = false;
      if (!bad[i]) {
        k = [skey[i], idvar[i], val[i], qnam[i]].join('\r');
        d = !!seen[k];
        seen[k] = true;
      }
      dup.push(d);
    }
    var twoLevel = qn.filter(function (q) {
      return suppUnique(idvar.filter(function (_, j) { return qnam[j] === q; })).length > 1;
    });
    var clashes = qn.filter(function (q) { return pNames.indexOf(q) >= 0; });
    var count = function (a) { return a.filter(Boolean).length; };

    var status = count(dup) || clashes.length || twoLevel.length ? 'error'
      : (count(orphan) || count(bad) || (warnOther && nOther > 0) ? 'warning' : 'ok');

    var drift = { stale: false, reasons: [] };
    var plan = opts.plan;
    if (plan) {
      var pick = function (l, f) {
        return (l || []).map(function (e) { return e && e[f] !== null && e[f] !== undefined ? String(e[f]) : null; });
      };
      var pQ = pick(plan.qnams, 'qnam'), pI = pick(plan.idvars, 'idvar'), pT = pick(plan.idvars, 'type');
      var reasons = [];
      suppSetdiff(qn, pQ).forEach(function (q) { reasons.push('New QNAM: ' + q); });
      suppSetdiff(levels, pI).forEach(function (iv) { reasons.push('New IDVAR: ' + (iv !== '' ? iv : '(subject level)')); });
      suppSetdiff(pQ, qn).forEach(function (q) { reasons.push('QNAM gone: ' + q); });
      levels.filter(function (iv) { return iv !== '' && pI.indexOf(iv) >= 0; }).forEach(function (iv) {
        var old = pT[pI.indexOf(iv)];
        if (old !== null && old !== undefined && old !== types[iv]) {
          reasons.push(iv + ' type changed from ' + old + ' to ' + types[iv]);
        }
      });
      drift = { stale: reasons.length > 0, reasons: reasons };
    }

    var samples = function (flags) {
      var out = [];
      for (var j = 0; j < nSupp && out.length < sampleN; j++) {
        if (!flags[j]) continue;
        var r = suppRows[j];
        out.push({
          USUBJID: r.USUBJID === undefined || r.USUBJID === null ? null : String(r.USUBJID),
          IDVAR: idvar[j],
          IDVARVAL: r.IDVARVAL === undefined || r.IDVARVAL === null ? null : String(r.IDVARVAL),
          QNAM: qnam[j]
        });
      }
      return out;
    };

    var pv = parentRows.slice(0, sampleN).map(function (r) {
      var o = {};
      Object.keys(r).forEach(function (c) { o[c] = r[c] === undefined ? null : r[c]; });
      return o;
    });
    var pvKey = pv.map(keyOf);
    suppSetdiff(qn, clashes.concat(twoLevel)).forEach(function (q) {
      var iv = idvar[qnam.indexOf(q)];
      var look = {};
      for (var j = nSupp - 1; j >= 0; j--) {   // backwards so the first row wins
        if (qnam[j] !== q || bad[j]) continue;
        var sk = iv !== '' ? skey[j] + '\r' + val[j] : skey[j];
        var qv = suppRows[j].QVAL;
        look[sk] = qv === null || qv === undefined ? null : String(qv);
      }
      pv.forEach(function (o, j) {
        var pk = iv !== '' ? pvKey[j] + '\r' + suppChr(o[iv]) : pvKey[j];
        o[q] = Object.prototype.hasOwnProperty.call(look, pk) ? look[pk] : null;
      });
    });

    return {
      status: status,
      plan: newPlan,
      n_parent: parentRows.length,
      n_supp: nSupp,
      n_matched: count(matched),
      n_orphan: count(orphan),
      orphan_samples: samples(orphan),
      n_other_rdomain: nOther,
      repeats: { n: count(dup), samples: samples(dup) },
      clashes: clashes,
      two_level: twoLevel,
      bad_idvarval: { n: count(bad), samples: samples(bad) },
      columns: qnams.map(function (q) { return { name: q.qnam, label: q.label }; }),
      preview: pv,
      drift: drift
    };
  }

  // ---- the supp merge step: SUPP-- rows folded into the parent (design §6) ----

  function suppList(x) { return x === null || x === undefined ? [] : [].concat(x); }

  /**
   * A supp step for Pipeline.add(), from a merge check's plan ({keys, idvars, qnams, rdomain_col}).
   * The step carries the whole plan, so it composes without the cards' CDISC tags.
   */
  function suppStep(table, supp, rdomain, plan) {
    plan = plan || {};
    var txt = function (v) { return v === null || v === undefined ? '' : String(v); };
    return {
      kind: 'supp', key: JSON.stringify(['supp', table, supp]), table: table, supp: supp,
      rdomain: rdomain,
      keys: suppList(plan.keys).map(String),
      idvars: suppList(plan.idvars).map(function (v) {
        v = v || {};
        return { idvar: txt(v.idvar), type: v.type ? String(v.type) : null };
      }),
      qnams: suppList(plan.qnams).map(function (q) {
        q = q || {};
        return { qnam: txt(q.qnam), label: txt(q.label), idvar: txt(q.idvar) };
      }),
      rdomain_col: !!plan.rdomain_col
    };
  }

  // <supp>_<idvar lower case>, or <supp>_subj for the subject level.
  function suppLevelName(supp, iv) {
    return ident(String(supp) + '_' + (iv === '' ? 'subj' : String(iv).toLowerCase()));
  }

  // IDVARVAL as the parent key's type. Text that does not convert is NA, as in the check
  // (sv_supp_convert / suppConvert): the integer and double patterns are the check's own.
  function suppKeyExpr(type) {
    if (type !== 'integer' && type !== 'double') return 'IDVARVAL';
    var re = type === 'integer' ? SUPP_INT_RE.source : SUPP_DBL_RE.source;
    return 'suppressWarnings(' + (type === 'integer' ? 'as.integer' : 'as.numeric') +
      '(dplyr::if_else(grepl(' + str(re) + ', IDVARVAL), as.character(IDVARVAL), NA_character_)))';
  }

  // A level whose key an Arrow join casts to the parent's type: a numeric IDVAR.
  function suppArrowCast(v) {
    return v.idvar !== '' && (v.type === 'integer' || v.type === 'double');
  }

  function suppLabels(s) {
    return (s.qnams || []).filter(function (q) { return q.label !== ''; });
  }

  /**
   * The statements written before the parent's chain (§6.2): <supp>_q, the guards, one pivoted
   * table per IDVAR level, and <supp>_labels when `withLabels`. `src` is the SUPP side's code (the
   * card, or its _prep chain); `srcLazy` collects it after the RDOMAIN filter; `parentRef` is the
   * parent table the clash guard reads (the names of collect(head(x, 0)): data frames, arrow tables,
   * datasets and queries, dbplyr tables). `arrowJoin`: the chain is Arrow where the levels join,
   * so a numeric level's key is cast to the parent's Arrow type.
   */
  function suppPrep(s, src, srcLazy, parentRef, pipe, withLabels, arrowJoin) {
    var S = String(s.supp), P = String(s.table);
    var q = ident(S + '_q');
    var nl = ' ' + pipe + '\n  ';
    var levels = s.idvars.map(function (v) { return v.idvar; });
    var out = [];
    var ql = [src];
    if (s.rdomain_col) ql.push('dplyr::filter(RDOMAIN == ' + str(s.rdomain) + ')');
    if (srcLazy) ql.push('dplyr::collect()');
    ql.push('dplyr::mutate(IDVAR = dplyr::if_else(is.na(IDVAR) | trimws(IDVAR) == "", "", as.character(IDVAR)))');
    out.push(q + ' <- ' + ql.join(nl));

    var g = ['local({'];
    g.push('  other <- setdiff(unique(' + q + '$IDVAR), c(' + levels.map(str).join(', ') + '))');
    if (levels.indexOf('') < 0) g.push('  other[other == ""] <- "(subject level)"');
    g.push('  if (length(other)) stop(' + str(S + ' has IDVAR values this merge does not handle: ') + ',');
    g.push('    paste(other, collapse = ", "), ". Refresh the merge step.", call. = FALSE)');
    g.push('  clash <- intersect(unique(' + q + '$QNAM), names(dplyr::collect(utils::head(' + parentRef + ', 0))))');
    g.push('  if (length(clash)) stop(' + str(S + ' QNAMs clash with ' + P + ' columns: ') +
      ', paste(clash, collapse = ", "), call. = FALSE)');
    if (levels.length > 1) {
      g.push('  lv <- unique(' + q + '[c("QNAM", "IDVAR")])');
      g.push('  both <- unique(lv$QNAM[duplicated(lv$QNAM)])');
      g.push('  if (length(both)) stop(' + str(S + ' QNAMs are at two levels: ') +
        ', paste(both, collapse = ", "), call. = FALSE)');
    }
    g.push('})');
    out.push(g.join('\n'));

    s.idvars.forEach(function (v) {
      var iv = v.idvar;
      var nm = suppLevelName(S, iv);
      var cols = s.keys.map(ident);
      var dupCols = s.keys.slice();
      if (iv !== '') { cols.push(ident(iv) + ' = ' + suppKeyExpr(v.type)); dupCols.push(iv); }
      cols.push('QNAM', 'QVAL');
      dupCols.push('QNAM');
      var l = [q, 'dplyr::filter(IDVAR == ' + str(iv) + ')', 'dplyr::transmute(' + cols.join(', ') + ')'];
      // rows whose IDVARVAL does not convert join nothing (the check counts them as bad, not orphans)
      if (iv !== '') l.push('dplyr::filter(!is.na(' + ident(iv) + '))');
      out.push(nm + ' <- ' + l.join(nl));
      // the repeat guard runs after conversion, so "01" and "1" are one record
      out.push('local({\n  dup <- ' + nm + '[duplicated(' + nm + '[c(' + dupCols.map(str).join(', ') + ')]), ]\n' +
        '  if (nrow(dup)) stop(' + str(S + ' repeats a QNAM for ') + ', nrow(dup), " record(s), first: ",\n' +
        '    dup$USUBJID[1], ' + (iv !== '' ? str(' ' + iv + ' ') + ', dup[[' + str(iv) + ']][1], ' : '') +
        '" ", dup$QNAM[1], call. = FALSE)\n})');
      out.push(nm + ' <- tidyr::pivot_wider(' + nm + ', names_from = QNAM, values_from = QVAL)');
      if (arrowJoin && suppArrowCast(v)) {
        // Arrow's hash join needs one key type on both sides: as.integer() gives int32 and
        // as.numeric() double, while a parquet parent often has int64. Cast to the parent's type
        // (read at run time); a fractional key cannot match an integer one, so it is dropped.
        var k = str(iv);
        out.push(nm + ' <- local({\n' +
          '  ty <- arrow::as_arrow_table(utils::head(' + parentRef + ', 0))$schema[[' + k + ']]$type\n' +
          '  x <- ' + nm + '\n' +
          '  if (is.double(x[[' + k + ']]) && grepl("int", ty$ToString())) x <- x[x[[' + k + ']] == trunc(x[[' + k + ']]), ]\n' +
          '  x <- arrow::arrow_table(x)\n' +
          '  x[[' + k + ']] <- x[[' + k + ']]$cast(ty)\n' +
          '  x\n})');
      }
    });

    var labs = suppLabels(s);
    if (withLabels && labs.length) {
      out.push(ident(S + '_labels') + ' <- c(' + labs.map(function (x) {
        return ident(x.qnam) + ' = ' + str(x.label);
      }).join(', ') + ')');
    }
    return out.join('\n');
  }

  // The chain's joins, one per level. `kind` is the chain's backend at this point: a duckdb chain
  // copies the data frame in, an arrow chain takes it as an Arrow table.
  function suppJoins(s, kind) {
    return s.idvars.map(function (v) {
      var nm = suppLevelName(s.supp, v.idvar);
      var by = s.keys.concat(v.idvar !== '' ? [v.idvar] : []).map(function (k) { return { left: k, right: k }; });
      // a cast level is an Arrow table already (suppPrep)
      var wrap = kind === 'arrow' && !suppArrowCast(v);
      return 'dplyr::left_join(' + (wrap ? 'arrow::arrow_table(' + nm + ')' : nm) +
        ', by = ' + joinBy(by) + (kind === 'duckdb' ? ', copy = TRUE' : '') + ')';
    });
  }

  function suppLabelLine(s) {
    var L = ident(String(s.supp) + '_labels');
    return 'dplyr::mutate(dplyr::across(dplyr::any_of(names(' + L + ')),\n    ~ structure(.x, label = ' +
      L + '[[dplyr::cur_column()]])))';
  }

  var api = {
    Pipeline: Pipeline,
    suppStep: suppStep,
    splitReply: splitReply,
    joinDiagnostics: joinDiagnostics,
    strictArgs: strictArgs,
    ruleValue: ruleValue,
    describeDiagnostics: describeDiagnostics,
    fmtN: fmtN,
    columnProfile: columnProfile,
    suppKeyType: suppKeyType,
    suppCheck: suppCheck,
    codebookRow: codebookRow,
    codebookCsv: codebookCsv,
    CODEBOOK_FIELDS: CODEBOOK_FIELDS,
    ident: ident,
    str: str,
    literal: literal,
    condition: condition,
    verbs: verbs,
    describe: describe,
    RULE_SHAPES: RULE_SHAPES,
    ruleSlots: ruleSlots,
    ruleProblem: ruleProblem,
    ruleLabel: ruleLabel,
    isSyntactic: isSyntactic,
    NUMERIC_TYPES: NUMERIC_TYPES,
    JOIN_TYPES: JOIN_TYPES,
    AGG_FNS: Object.keys(AGG_FNS)
  };
  global.SideviewPipeline = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this));
