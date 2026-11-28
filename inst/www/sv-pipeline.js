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
      .replace(/\t/g, '\\t')
      // the other control characters as R's encodeString() writes them: \a \b \f \v, octal, and \u00xx for C1
      .replace(/[\x00-\x1f\x7f-\x9f]/g, function (c) {
        var k = c.charCodeAt(0);
        var named = { 7: '\\a', 8: '\\b', 11: '\\v', 12: '\\f' }[k];
        if (named) return named;
        if (k < 0x80) return '\\' + ('00' + k.toString(8)).slice(-3);
        return '\\u' + ('000' + k.toString(16)).slice(-4);
      }) + '"';
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
      case 'derive': {
        var dins = [].concat(step.inputs || []);
        if (step.op === 'stack') return 'stack of ' + dins.join(' + ');
        // a compare's inputs are [old, new]
        if (step.op === 'compare_added') return 'added rows of ' + dins[1] + ' vs ' + dins[0];
        if (step.op === 'compare_removed') return 'removed rows of ' + dins[0] + ' vs ' + dins[1];
        if (step.op === 'compare_changed') return 'changed values of ' + dins[1] + ' vs ' + dins[0];
        return 'rows of ' + step.table;
      }
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
    // 'dplyr' | 'pharmaverse': how a SUPP merge is written (E1). State, but not undoable (as pipe).
    this.style = opts.style === 'pharmaverse' ? 'pharmaverse' : 'dplyr';
    // the merge checks' combine_supp fields by step key: not state (no undo, never saved)
    this.suppCombine = {};
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
    // a derived card is the table its derive step writes: it is as lazy as that step's expression ends
    var d = this.deriveFor(name);
    if (d) {
      this._kindBusy = this._kindBusy || {};
      if (!this._kindBusy[name]) {
        this._kindBusy[name] = true;
        try { return this.deriveExpr(d).kind; } finally { this._kindBusy[name] = false; }
      }
    }
    var m = this.tables[name];
    return m && m.lazy ? m.lazy : null;
  };

  /** The R expression that names a table: a lazy table's codeRef when it differs from its name. */
  Pipeline.prototype.refFor = function (name) {
    if (this.deriveFor(name)) return ident(name);
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

  // Update a step to fit new data (a replaced card). History from before no longer fits the data, so a change
  // clears undo and redo, as disableMissing does; a no-op leaves them alone.
  Pipeline.prototype.refit = function (id, patch) {
    var undo = this.undoStack, redo = this.redoStack;
    var changed = this.update(id, patch);
    if (changed) this.clearHistory();
    else { this.undoStack = undo; this.redoStack = redo; }
    return changed;
  };

  Pipeline.prototype.clearHistory = function () { this.undoStack = []; this.redoStack = []; };

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
      if (s.table !== table || s.enabled === false || s.kind === 'derive') continue;
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
          if (s.kind !== 'derive' && live(s) && (s.table === table || (s.kind === 'join' && s.right === table) ||
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
        if (s.table !== table || !live(s) || s.kind === 'derive') return;
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
    if (disabled.length) this.clearHistory();
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

  /** The code style, 'dplyr' or 'pharmaverse' (anything else is 'dplyr'). Not undoable, as setPipe(). */
  Pipeline.prototype.setStyle = function (style) {
    this.style = style === 'pharmaverse' ? 'pharmaverse' : 'dplyr';
    this.emit('style');
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
      return x.table === step.right && x.kind !== 'custom' && x.kind !== 'derive';
    });
    if (prepared) {
      return { ok: false, reason: 'Strict applies only to a join on the original tables: ' + step.right + ' has steps of its own' };
    }
    return { ok: true, reason: '' };
  };

  /**
   * How a join moves its sides onto one backend (shared by compose()'s chains and deriveExpr()).
   * `kind` / `con` describe the left side (a lazy backend, or null in memory, and what remote_con() can
   * read), `r` the right side `{ref, kind}`. Returns `{wrap, rightRef, copy, kind, con}`: `wrap`
   * ([open, rest]) puts the left side inside `open + <left> + rest`; `copy` asks for copy = TRUE.
   * A date rule has no Arrow form, so a rule join moves Arrow onto duckdb.
   */
  function crossBackend(kind, con, r, hasRule, moveCon, duckRef, name) {
    var o = { wrap: null, rightRef: r.ref, copy: false, kind: kind, con: con };
    if (hasRule && kind === 'arrow' && r.kind !== 'duckdb') {
      // arrow has no inequality join: a rule join runs in duckdb. Both sides move onto one
      // connection: a duckdb card's (moveCon) or, with none, arrow's default one.
      o.wrap = ['dplyr::compute(arrow::to_duckdb(', moveCon + '))'];
      if (r.kind === 'arrow') o.rightRef = 'dplyr::compute(arrow::to_duckdb(' + r.ref + moveCon + '))';
      else o.copy = true;
      o.kind = 'duckdb';
      o.con = duckRef;
    } else if (hasRule && !kind && r.kind === 'arrow') {
      o.wrap = ['dplyr::compute(arrow::to_duckdb(arrow::arrow_table(', ')' + moveCon + '))'];
      o.rightRef = 'dplyr::compute(arrow::to_duckdb(' + r.ref + moveCon + '))';
      o.kind = 'duckdb';
      o.con = duckRef;
    } else if (kind === 'duckdb' && !r.kind) o.copy = true;
    else if (kind === 'duckdb' && r.kind === 'arrow') {
      // compute(): to_duckdb() registers a view that R's garbage collector may drop before
      // the query runs ("Table arrow_003 does not exist"); compute() makes a real table.
      // con is null after a rule join moved arrow into arrow's default duckdb connection
      // (no duckdb card in the steps).
      o.rightRef = 'dplyr::compute(arrow::to_duckdb(' + r.ref +
        (con ? ', con = dbplyr::remote_con(' + con + ')' : '') + '))';
    } else if (kind === 'arrow' && r.kind === 'duckdb') {
      o.wrap = ['dplyr::compute(arrow::to_duckdb(', ', con = dbplyr::remote_con(' + r.ref + ')))'];
      o.kind = 'duckdb';
      o.con = r.ref;
    } else if (!kind && r.kind === 'duckdb') {
      // A name of our own: copy_to(overwrite = TRUE) under the data frame's name would
      // replace a real table of that name in the user's database.
      o.wrap = ['dplyr::copy_to(dbplyr::remote_con(' + r.ref + '), ',
        ', name = ' + str('sideview_' + name) + ', overwrite = TRUE)'];
      o.kind = 'duckdb';
      o.con = r.ref;
    } else if (!kind && r.kind === 'arrow') {
      o.wrap = ['arrow::arrow_table(', ')'];
      o.kind = 'arrow';
      o.con = null;
    }
    return o;
  }

  // ---- derived tables: the rows behind a join or SUPP check, as code (twin of sv_derive_card) ----

  /** The live derive step that writes `name`, or null. */
  Pipeline.prototype.deriveFor = function (name) {
    for (var i = this.steps.length - 1; i >= 0; i--) {
      var s = this.steps[i];
      if (s.kind === 'derive' && s.table === name && this.deriveLive(s)) return s;
    }
    return null;
  };

  /**
   * Whether a derive step is written: enabled, with two inputs that are on the canvas (setTables) or
   * written by another live derive step (in any position: compose() orders producers first). Never a reason to disable the step (disableMissing skips it).
   */
  Pipeline.prototype.deriveLive = function (step) {
    var self = this;
    if (!step || step.kind !== 'derive' || step.enabled === false) return false;
    var ins = [].concat(step.inputs || []);
    // a stack has 2 to 8 inputs, every other op exactly 2
    if (step.op === 'stack' ? (ins.length < 2 || ins.length > 8) : ins.length !== 2) return false;
    // a step that is already being asked about is a cycle: not live
    this._liveBusy = this._liveBusy || [];
    if (this._liveBusy.indexOf(step) >= 0) return false;
    this._liveBusy.push(step);
    try {
      // the producer of a derived input may stand anywhere in the steps: compose() writes it first
      return ins.every(function (n) {
        if (self.tables[n]) return true;
        return self.steps.some(function (x) {
          return x !== step && x.kind === 'derive' && x.table === n && self.deriveLive(x);
        });
      });
    } finally {
      this._liveBusy.pop();
    }
  };

  // The condition of an outside_window anti join, written for the kept side `side` (x$ is the kept
  // table in the join, y$ the other one). `lazy`: the join runs on duckdb.
  function deriveRule(rule, side, kindOf, lazy) {
    var r = rule;
    var strict = r.inclusive === false;
    var k = side === 'x' ? 'x$' : 'y$';   // the table the rule's x columns are on
    var o = side === 'x' ? 'y$' : 'x$';   // and the one its y columns are on
    var out = { prep: null, expr: '', post: null, other: null };
    switch (r.shape) {
      case 'between':
        out.expr = 'between(' + k + ident(r.xCol) + ', ' + o + ident(r.yFrom) + ', ' + o + ident(r.yTo) + ')';
        break;
      case 'overlaps':
        out.expr = 'overlaps(' + k + ident(r.xFrom) + ', ' + k + ident(r.xTo) + ', ' +
          o + ident(r.yFrom) + ', ' + o + ident(r.yTo) + ')';
        break;
      case 'window': {
        var kd = kindOf ? kindOf(r.xCol) : null;
        var lo = '.sv_lo = ' + offsetExpr(r.xCol, r.from, kd, lazy);
        var hi = '.sv_hi = ' + offsetExpr(r.xCol, r.to, kd, lazy);
        if (side === 'x') {
          out.prep = 'dplyr::mutate(' + lo + ', ' + hi + ')';
          out.post = 'dplyr::select(-.sv_lo, -.sv_hi)';
          out.expr = 'between(y$' + ident(r.yCol) + ', x$.sv_lo, x$.sv_hi)';
        } else {
          out.other = 'dplyr::mutate(%s, ' + lo + ', ' + hi + ')';
          out.expr = 'between(x$' + ident(r.yCol) + ', y$.sv_lo, y$.sv_hi)';
        }
        break;
      }
      case 'before':
        out.expr = k + ident(r.xCol) + (strict ? ' > ' : ' >= ') + o + ident(r.yCol);
        break;
      case 'after':
        out.expr = k + ident(r.xCol) + (strict ? ' < ' : ' <= ') + o + ident(r.yCol);
        break;
    }
    return out;
  }

  /**
   * The right-hand side of a derived table's assignment and the backend it ends in:
   * `{code, kind}`, kind `'arrow'`, `'duckdb'` or null (in memory). The step is
   * `{kind: 'derive', table, op, inputs: [x, y], args}`; `args` is what R's builder kept
   * (`by`, `side`, `rule`; for a SUPP op `rdomain` and `plan`). Nothing is collected.
   */
  Pipeline.prototype.deriveExpr = function (step) {
    var pipe = this.pipe;
    var ins = [].concat(step.inputs || []).map(String);
    var args = step.args || {};
    var op = step.op;
    if (op === 'stack') {
      var sp = args.plan;
      if (!sp || ins.length < 2 || ins.length > 8 || [].concat(sp.inputs || []).length !== ins.length) {
        return { code: '', kind: null };
      }
      var sres = stackCode(sp, ins.map(this.refFor, this), ins.map(this.lazyKind, this));
      return sres.code ? sres : { code: '', kind: null };
    }
    if (ins.length !== 2) return { code: '', kind: null };
    if (COMPARE_OPS[op]) {
      if (!args.plan) return { code: '', kind: null };
      var cres = compareCode(args.plan, ins.map(this.refFor, this), ins.map(this.lazyKind, this), op);
      return cres.code ? cres : { code: '', kind: null };
    }
    if (op === 'supp_orphans' || op === 'supp_bad_idvarval') {
      return { code: deriveSuppCode(this, op, ins, args), kind: null };
    }
    var side = args.side === 'y' ? 'y' : 'x';
    var rule = args.rule || null;
    if (op === 'outside_window' && !rule) return { code: '', kind: null };
    var keep = side === 'x' ? ins[0] : ins[1];
    var other = side === 'x' ? ins[1] : ins[0];
    var kp = [].concat(args.by || []).map(function (p) {
      return side === 'x' ? { left: String(p.x), right: String(p.y) } : { left: String(p.y), right: String(p.x) };
    });
    if (!kp.length) return { code: '', kind: null };
    var kk = this.lazyKind(keep);
    var ko = this.lazyKind(other);
    var duckRef = kk === 'duckdb' ? this.refFor(keep) : (ko === 'duckdb' ? this.refFor(other) : null);
    var moveCon = duckRef ? ', con = dbplyr::remote_con(' + duckRef + ')' : '';
    var hasRule = !!rule;
    var cb = crossBackend(kk, kk ? this.refFor(keep) : null, { ref: this.refFor(other), kind: ko },
      hasRule, moveCon, duckRef, 'derive_' + step.table);
    var head = this.refFor(keep);
    if (cb.wrap) head = cb.wrap[0] + head + cb.wrap[1];
    var copy = cb.copy ? ', copy = TRUE' : '';
    var right = cb.rightRef;
    var local = right !== this.refFor(other);
    if (local) right = '.sv_other';
    var code;
    if (!hasRule) {
      code = 'dplyr::anti_join(' + head + ', ' + right + ', by = ' + joinBy(kp) +
        ', na_matches = "na"' + copy + ')';
    } else if (op === 'unmatched') {
      code = 'dplyr::anti_join(' + head + ', ' + right + ', by = ' + joinBy(kp) +
        ', na_matches = "never"' + copy + ')';
    } else if (side === 'y' && (rule.shape === 'before' || rule.shape === 'after')) {
      // A nearest-match rule keeps, for each x row, the nearest y rows: a y row is inside the window
      // only if it is one of those. So collect the (key, date) of the y rows that are nearest to some
      // x row, then keep the y rows with a key partner that are none of them. The pair table is
      // built from the kept table on the left, so copy = TRUE moves a data frame onto its database.
      var nk = kp.map(function (p, i) { return '.sv_k' + (i + 1); });
      var strictR = rule.inclusive === false;
      // the x date is on or after the y date (before) or on or before it (after)
      var cmp = rule.shape === 'before' ? (strictR ? '<' : '<=') : (strictR ? '>' : '>=');
      var ysel = 'dplyr::select(.sv_keep, ' + kp.map(function (p, i) { return nk[i] + ' = ' + ident(p.left); })
        .concat(['.sv_yd = ' + ident(rule.yCol)]).join(', ') + ')';
      var xsel = 'dplyr::distinct(dplyr::select(.sv_other, ' + kp.map(function (p, i) {
        return nk[i] + ' = ' + ident(p.right);
      }).concat(['.sv_xd = ' + ident(rule.xCol)]).join(', ') + '))';
      var byNear = 'dplyr::join_by(' + nk.concat(['.sv_yd ' + cmp + ' .sv_xd']).join(', ') + ')';
      var grp = nk.concat(['.sv_xd']).join(', ');
      var pair = ['dplyr::inner_join(' + ysel + ', ' + xsel + ', by = ' + byNear + ', na_matches = "never"' + copy + ')',
        'dplyr::group_by(' + grp + ')',
        'dplyr::filter(.sv_yd == ' + (rule.shape === 'before' ? 'max' : 'min') + '(.sv_yd, na.rm = TRUE))',
        'dplyr::ungroup()',
        'dplyr::distinct(' + nk.concat(['.sv_yd']).join(', ') + ')'].join(' ' + pipe + '\n      ');
      var byPair = 'c(' + kp.map(function (p, i) { return ident(p.left) + ' = ' + str(nk[i]); })
        .concat([ident(rule.yCol) + ' = ".sv_yd"']).join(', ') + ')';
      code = 'local({\n  .sv_keep <- ' + head + '\n  .sv_other <- ' + cb.rightRef + '\n  .sv_pair <- ' + pair +
        '\n  .sv_keep ' + pipe + '\n    dplyr::semi_join(.sv_other, by = ' + joinBy(kp) +
        ', na_matches = "never"' + copy + ') ' + pipe +
        '\n    dplyr::anti_join(.sv_pair, by = ' + byPair + ', na_matches = "never")\n})';
      return { code: code, kind: cb.kind };
    } else {
      var tx = this.tables[ins[0]];
      var rp = deriveRule(rule, side, function (col) { return tx && tx.kinds ? tx.kinds[col] : null; },
        cb.kind === 'duckdb');
      var lines = [head];
      lines.push('dplyr::semi_join(' + right + ', by = ' + joinBy(kp) + ', na_matches = "never"' + copy + ')');
      if (rp.prep) lines.push(rp.prep);
      lines.push('dplyr::anti_join(' + (rp.other ? rp.other.replace('%s', right) : right) + ', by = ' +
        joinByCall(kp, rp.expr) + ', na_matches = "never"' + copy + ')');
      if (rp.post) lines.push(rp.post);
      code = lines.join(' ' + pipe + '\n  ');
    }
    if (local) {
      code = 'local({\n  .sv_other <- ' + cb.rightRef + '\n  ' + code.replace(/\n/g, '\n  ') + '\n})';
    }
    return { code: code, kind: cb.kind };
  };

  // ---- stack: the code that rebuilds a stacked card (twin of sv_stack_code(), R/stack.R and R/lazy.R) ----
  // The plan (args.plan) is R's own and is never recomputed here; it says every column's types, casts,
  // zones and renames, and carries the text of each lazy time-to-text cast (`tz_text`: the zone's offset
  // tree is long, R writes it once). A missing value (R's NA) is null.

  // the trailing zeros format() pads a number with (R's sub() pattern in sv_compare_code())
  var COMPARE_KEY_RE = /\.0+$|(\.[0-9]*[1-9])0+$/;

  function stackHas(v) { return v !== null && v !== undefined; }

  function stackQid(name) { return '"' + String(name).replace(/"/g, '""') + '"'; }

  function stackSql(text) { return 'dbplyr::sql(' + str(text) + ')'; }

  // The in-memory code of one cast (twin of sv_stack_cast_code()); `x` is the column as written in the code.
  function stackCastCode(x, from, to, zone) {
    function numOfChr(re) {
      return 'suppressWarnings(as.numeric(replace(' + x + ', !grepl(' + str(re) + ', ' + x + ', perl = TRUE), NA)))';
    }
    function whole(v) {
      return '(function(v) as.integer(ifelse(!is.na(v) & v == trunc(v) & abs(v) <= 2147483647, v, NA)))(' + v + ')';
    }
    switch (to) {
      case 'lgl':
        return from === 'chr'
          ? 'ifelse(' + x + ' == "TRUE", TRUE, ifelse(' + x + ' == "FALSE", FALSE, NA))'
          : 'ifelse(as.numeric(' + x + ') %in% c(0, 1), as.numeric(' + x + ') == 1, NA)';
      case 'int':
        if (from === 'lgl') return 'as.integer(' + x + ')';
        return from === 'chr' ? whole(numOfChr(SUPP_INT_RE.source)) : whole('as.numeric(' + x + ')');
      case 'num':
        return from === 'chr'
          ? '(function(v) replace(v, abs(v) > 1e308, NA))(' + numOfChr(SUPP_DBL_RE.source) + ')'
          : 'as.numeric(' + x + ')';
      case 'chr':
        return from === 'dttm'
          ? 'format(' + x + ', "%Y-%m-%d %H:%M:%S", tz = ' + str(zone) + ')'
          : 'as.character(' + x + ')';
      case 'date':
        return from === 'dttm'
          ? 'as.Date(' + x + ', tz = "UTC")'
          : 'as.Date(replace(' + x + ', !grepl(' + str('^[0-9]{4}-[0-9]{2}-[0-9]{2}$') + ', ' + x +
            '), NA), format = "%Y-%m-%d")';
      case 'dttm':
        return 'as.POSIXct(' + x + ', tz = ' + str(zone) + ')';
      case 'fct':
        return 'factor(as.character(' + x + '))';
    }
    return '';
  }

  // The lazy cast of one column as deparsed R (twin of sv_stack_lazy_cast(), written as rlang::expr_deparse()
  // prints it). `tzText` is the plan's text of a time-to-text cast.
  function stackLazyCast(cn, from, to, tzText) {
    var x = ident(cn);
    var q = stackQid(cn);
    var dbl = stackSql('TRY_CAST(' + q + ' AS DOUBLE)');
    var matches = function (re) { return 'regexp_matches(' + x + ', ' + str(re) + ')'; };
    switch (to) {
      case 'lgl':
        return from === 'chr'
          ? 'dplyr::case_when(' + x + ' == "TRUE" ~ TRUE, ' + x + ' == "FALSE" ~ FALSE, .default = NA)'
          : 'dplyr::case_when(' + x + ' == 0 ~ FALSE, ' + x + ' == 1 ~ TRUE, .default = NA)';
      case 'int':
        if (from === 'lgl') return 'as.integer(' + x + ')';
        if (from === 'chr') {
          return 'dplyr::if_else(' + matches(SUPP_INT_RE.source) + ' & abs(' + dbl + ') <= 2147483647, ' +
            stackSql('TRY_CAST(TRY_CAST(' + q + ' AS DOUBLE) AS INTEGER)') + ', NA)';
        }
        return 'dplyr::if_else(!isnan(' + x + ') & ' + x + ' == floor(' + x + ') & abs(' + x + ') <= 2147483647, ' +
          stackSql('TRY_CAST(' + q + ' AS INTEGER)') + ', NA)';
      case 'num':
        return from === 'chr'
          ? 'dplyr::if_else(' + matches(SUPP_DBL_RE.source) + ' & abs(' + dbl + ') <= 1e+308, ' + dbl + ', NA)'
          : stackSql('CAST(' + q + ' AS DOUBLE)');
      case 'chr':
        if (from === 'lgl') return 'if_else(' + x + ', "TRUE", "FALSE")';
        if (from === 'num') {
          return 'case_when(isnan(' + x + ') ~ "NaN", isinf(' + x + ') & ' + x + ' > 0 ~ "Inf", isinf(' + x +
            ') ~ "-Inf", .default = stringr::str_replace(as.character(' + x + '), "\\\\.0$", ""))';
        }
        if (from === 'dttm') return stackHas(tzText) ? String(tzText) : null;
        return 'as.character(' + x + ')';
      case 'date':
        return from === 'dttm'
          ? stackSql('CAST(make_timestamp(epoch_us(' + q + ')) AS DATE)')
          : 'dplyr::if_else(regexp_matches(' + x + ', "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"), ' +
            stackSql('TRY_CAST(' + q + ' AS DATE)') + ', NA)';
      case 'dttm':
        return stackSql('CAST(' + q + ' AS TIMESTAMP)');
    }
    return null;
  }

  // A column that an input lacks, typed so the union reads it as the target type
  function stackLazyNa(target) {
    var t = { lgl: 'BOOLEAN', int: 'INTEGER', num: 'DOUBLE', date: 'DATE', dttm: 'TIMESTAMP' }[target] || 'VARCHAR';
    return stackSql('CAST(NULL AS ' + t + ')');
  }

  // The code of a stack, `{code, kind}`: `refs` are the R references of the inputs, `kinds` null (in memory),
  // 'duckdb' or 'arrow' for each. An empty code means the plan cannot be written (a missing piece).
  function stackCode(plan, refs, kinds) {
    var cols = [].concat(plan.columns || []);
    var inputs = [].concat(plan.inputs || []).map(String);
    var id = String(plan.id_col);
    var at = function (v, i) { return v && stackHas(v[i]) ? v[i] : null; };
    var lazy = kinds.some(function (k) { return !!k; });
    if (!lazy) {
      var tz = plan.tz && !Array.isArray(plan.tz) ? plan.tz : {};
      var args = inputs.map(function (nm, i) {
        var ref = refs[i];
        var ren = cols.filter(function (c) { return at(c.rename_from, i) !== null; });
        if (ren.length) {
          ref = 'dplyr::rename(' + ref + ', ' + ren.map(function (c) {
            return ident(c.name) + ' = ' + ident(c.rename_from[i]);
          }).join(', ') + ')';
        }
        var cst = cols.filter(function (c) { return at(c.cast, i) !== null; });
        if (cst.length) {
          ref = 'dplyr::mutate(' + ref + ', ' + cst.map(function (c) {
            var zone = c.target === 'dttm' ? tz[c.name] : at(c.zones, i);
            if (!stackHas(zone)) zone = c.target === 'dttm' ? 'UTC' : '';
            return ident(c.name) + ' = ' + stackCastCode(ident(c.name), c.types[i], c.target, zone);
          }).join(', ') + ')';
        }
        return ident(nm) + ' = ' + ref;
      });
      var code = 'dplyr::bind_rows(' + args.join(', ') + ', .id = ' + str(id) + ')';
      var labels = plan.kept_labels && !Array.isArray(plan.kept_labels) ? plan.kept_labels : {};
      var lnames = Object.keys(labels);
      if (lnames.length) {
        code = 'dplyr::mutate(' + code + ', ' + lnames.map(function (cn) {
          return ident(cn) + ' = structure(' + ident(cn) + ', label = ' + str(labels[cn]) + ')';
        }).join(', ') + ')';
      }
      return { code: code, kind: null };
    }
    var duckRef = null;
    kinds.some(function (k, i) { if (k === 'duckdb') { duckRef = refs[i]; return true; } return false; });
    var bad = false;
    var parts = inputs.map(function (nm, i) {
      var ref = refs[i];
      var placed;
      if (!kinds[i]) {
        placed = duckRef === null
          ? 'arrow::to_duckdb(arrow::arrow_table(' + ref + '))'
          : 'dplyr::copy_to(dbplyr::remote_con(' + duckRef + '), ' + ref + ', name = ' +
            str('sideview_' + nm + '_' + (i + 1)) + ', overwrite = TRUE)';
      } else if (kinds[i] === 'arrow') {
        placed = duckRef === null
          ? 'arrow::to_duckdb(' + ref + ')'
          : 'dplyr::compute(arrow::to_duckdb(' + ref + ', con = dbplyr::remote_con(' + duckRef + ')))';
      } else placed = ref;
      var ren = cols.filter(function (c) { return at(c.rename_from, i) !== null; });
      if (ren.length) {
        placed = 'dplyr::rename(' + placed + ', ' + ren.map(function (c) {
          return ident(c.name) + ' = ' + ident(c.rename_from[i]);
        }).join(', ') + ')';
      }
      var sets = [ident(id) + ' = ' + str(nm)];
      cols.forEach(function (c) {
        var type = at(c.types, i);
        var e = null;
        if (type === null) e = stackLazyNa(c.target);
        else if (at(c.cast, i) !== null) {
          e = stackLazyCast(c.name, type, c.target, at(c.tz_text, i));
          if (e === null) bad = true;
        } else if (type === 'fct') e = 'as.character(' + ident(c.name) + ')';
        if (e !== null) sets.push(ident(c.name) + ' = ' + e);
      });
      var names = [id].concat(cols.map(function (c) { return c.name; })).map(str);
      return 'dplyr::select(dplyr::mutate(' + placed + ', ' + sets.join(', ') + '), dplyr::all_of(c(' +
        names.join(', ') + ')))';
    });
    if (bad) return { code: '', kind: null };
    var out = parts[parts.length - 1];
    for (var k = parts.length - 2; k >= 0; k--) out = 'dplyr::union_all(' + parts[k] + ', ' + out + ')';
    return { code: out, kind: 'duckdb' };
  }

  // ---- compare: the code that rebuilds a compare card (twin of sv_compare_code(), R/compare.R and R/lazy.R) ----
  // The plan (args.plan) is R's own: the key and compared columns with their types and zones, and for a lazy
  // compare the text of each time-to-text cast (`tz_text_old` / `tz_text_new`). A missing value is null.

  var COMPARE_OPS = { compare_added: 1, compare_removed: 1, compare_changed: 1 };

  // The code of one compare card, `{code, kind}`: `refs` are the R references of old and new, `kinds` null (in
  // memory), 'duckdb' or 'arrow' for each. An empty code means the plan cannot be written (a missing piece).
  function compareCode(plan, refs, kinds, op) {
    var by = [].concat(plan.by || []).map(String);
    var keys = [].concat(plan.keys || []);
    var compared = [].concat(plan.compared || []);
    if (!by.length || keys.length !== by.length) return { code: '', kind: null };
    var lazy = kinds.some(function (k) { return !!k; });
    var kind = lazy ? 'duckdb' : null;
    var cv = function (v) { return 'c(' + v.map(str).join(', ') + ')'; };
    var bad = false;
    // the text of a column: D2's cast to chr, a missing value NA (sv_compare_text()); `cn` is the plain name
    var text = function (cn, from, zone, tzText, key) {
      if (!stackHas(zone)) zone = '';
      if (lazy) {
        if (from === 'dttm') {
          if (!stackHas(tzText)) { bad = true; return ''; }
          return String(tzText);
        }
        var e = stackLazyCast(cn, from, 'chr', null);
        if (e === null) { bad = true; return ''; }
        return from === 'num' ? 'dplyr::if_else(isnan(' + ident(cn) + '), NA_character_, ' + e + ')' : e;
      }
      var x = ident(cn);
      if (key && from === 'num') {
        // a numeric key is written in full (100000, not 1e+05), as the join check's format_key() does
        return 'replace(sub(' + str(COMPARE_KEY_RE.source) + ', ' + str(String.fromCharCode(92) + '1') + ', format(' + x +
          ', scientific = FALSE, trim = TRUE, digits = 15)), is.na(' + x + '), NA_character_)';
      }
      return 'replace(' + stackCastCode(x, from, 'chr', zone) + ', is.na(' + x + '), NA_character_)';
    };
    if (lazy) {
      var duckRef = null;
      kinds.some(function (k, i) { if (k === 'duckdb') { duckRef = refs[i]; return true; } return false; });
      var keep = ', auto_disconnect = FALSE';
      refs = refs.map(function (ref, i) {
        if (!kinds[i]) {
          return duckRef === null
            ? 'arrow::to_duckdb(arrow::arrow_table(' + ref + ')' + keep + ')'
            : 'dplyr::copy_to(dbplyr::remote_con(' + duckRef + '), ' + ref + ', name = ' +
              str('sideview_' + ref + '_' + (i + 1)) + ', overwrite = TRUE)';
        }
        if (kinds[i] === 'arrow') {
          return duckRef === null
            ? 'arrow::to_duckdb(' + ref + keep + ')'
            : 'dplyr::compute(arrow::to_duckdb(' + ref + ', con = dbplyr::remote_con(' + duckRef + ')))';
        }
        return ref;
      });
    }
    var jb = by.slice();
    var side = function (i, ref) {
      var sets = [];
      keys.forEach(function (k, j) {
        if (k.text !== true) return;
        var nm = '.sv_k' + (j + 1);
        jb[j] = nm;
        sets.push(nm + ' = ' + (i === 0
          ? text(k.name, k.from_old, k.zone_old, k.tz_text_old, true)
          : text(k.name, k.from_new, k.zone_new, k.tz_text_new, true)));
      });
      return sets.length ? 'dplyr::mutate(' + ref + ', ' + sets.join(', ') + ')' : ref;
    };
    var o = side(0, refs[0]);
    var n = side(1, refs[1]);
    var extra = jb.filter(function (v, j) { return v !== by[j]; });
    var drop = function (x) { return extra.length ? 'dplyr::select(' + x + ', -c(' + extra.join(', ') + '))' : x; };
    var uniq = function (x) { return 'dplyr::filter(' + x + ', dplyr::n() == 1L, .by = ' + cv(jb) + ')'; };
    var code;
    if (op === 'compare_added') {
      code = drop('dplyr::anti_join(' + uniq(n) + ', ' + o + ', by = ' + cv(jb) + ', na_matches = "na")');
    } else if (op === 'compare_removed') {
      code = drop('dplyr::anti_join(' + uniq(o) + ', ' + n + ', by = ' + cv(jb) + ', na_matches = "na")');
    } else {
      var join = 'dplyr::inner_join(' + uniq(o) + ', ' + uniq(n) + ', by = ' + cv(jb) +
        ', suffix = c(".old", ".new"), na_matches = "na")';
      var kcols = by.map(function (b, j) {
        return keys[j].text === true ? ident(b) + ' = ' + ident(b + '.new') : ident(b);
      }).join(', ');
      var body;
      if (!compared.length) {
        var na = lazy ? stackLazyNa('chr') : 'NA_character_';
        body = 'dplyr::transmute(dplyr::filter(.sv_both, FALSE), ' + kcols + ', column = ' + na + ', old = ' + na +
          ', new = ' + na + ')';
      } else {
        var pieces = compared.map(function (cc) {
          var an = cc.name + '.old';
          var bn = cc.name + '.new';
          var a = ident(an);
          var b = ident(bn);
          var ca = a;
          var cb = b;
          if (cc.kind === 'character') { ca = 'as.character(' + a + ')'; cb = 'as.character(' + b + ')'; }
          // date-times of two zones compare by instant, without a 'tzone' warning (in memory only)
          if (!lazy && cc.kind === 'date-time') { ca = 'as.numeric(' + a + ')'; cb = 'as.numeric(' + b + ')'; }
          // missing: NA, or lazily NaN too for a double (duckdb says NaN is not NULL)
          var ma = lazy && cc.from_old === 'num' ? '(is.na(' + a + ') | isnan(' + a + '))' : 'is.na(' + a + ')';
          var mb = lazy && cc.from_new === 'num' ? '(is.na(' + b + ') | isnan(' + b + '))' : 'is.na(' + b + ')';
          var cond = '!(' + ma + ' & ' + mb + ') & (' + ma + ' | ' + mb + ' | ' + ca + ' != ' + cb + ')';
          return 'dplyr::transmute(dplyr::filter(.sv_both, ' + cond + '), ' + kcols + ', column = ' + str(cc.name) +
            ', old = ' + text(an, cc.from_old, cc.zone_old, cc.tz_text_old) +
            ', new = ' + text(bn, cc.from_new, cc.zone_new, cc.tz_text_new) + ')';
        });
        if (lazy) {
          body = pieces[pieces.length - 1];
          for (var k = pieces.length - 2; k >= 0; k--) body = 'dplyr::union_all(' + pieces[k] + ', ' + body + ')';
        } else {
          body = 'dplyr::arrange(dplyr::bind_rows(' + pieces.join(', ') + '), ' + by.map(ident).join(', ') + ')';
        }
      }
      code = 'local({\n  .sv_both <- ' + join + '\n  ' + body + '\n})';
    }
    if (bad) return { code: '', kind: null };
    return { code: code, kind: kind };
  }

  /**
   * One local({...}) block for a SUPP op: the SUPP rows of the check's own steps (RDOMAIN filter, key
   * text, IDVARVAL converted to the key type) matched against the parent's key text. A parent that is
   * lazy is first cut to the subjects the SUPP rows name and to the key columns, then collected.
   * The plan (args.plan, from R's check) says the keys and levels; it is never recomputed here.
   */
  function deriveSuppCode(self, op, ins, args) {
    var plan = args.plan || {};
    var keys = suppList(plan.keys).map(String);
    var levels = suppList(plan.idvars).map(function (v) {
      v = v || {};
      return {
        idvar: v.idvar === null || v.idvar === undefined ? '' : String(v.idvar),
        type: v.type ? String(v.type) : 'character'
      };
    });
    var rdomain = args.rdomain === undefined || args.rdomain === null ? '' : String(args.rdomain);
    var parent = self.refFor(ins[0]);
    var supp = self.refFor(ins[1]);
    var suppLazy = !!self.lazyKind(ins[1]);
    var parentLazy = !!self.lazyKind(ins[0]);
    var pcols = keys.slice();
    levels.forEach(function (l) { if (l.idvar !== '' && pcols.indexOf(l.idvar) < 0) pcols.push(l.idvar); });
    var nl = ' ' + self.pipe + '\n      ';
    var g = ['local({'];
    var sl = [supp];
    if (plan.rdomain_col) sl.push('dplyr::filter(RDOMAIN == ' + str(rdomain) + ')');
    if (suppLazy) sl.push('dplyr::collect()');
    g.push('  s <- ' + sl.join(nl));
    if (suppLazy) g.push('  s <- as.data.frame(s, stringsAsFactors = FALSE)');
    g.push('  n <- nrow(s)');
    g.push('  chr <- function(x) {');
    g.push('    if (inherits(x, "integer64")) x <- suppressWarnings(as.numeric(x))');
    g.push('    as.character(x)');
    g.push('  }');
    g.push('  iv <- as.character(s$IDVAR)');
    g.push('  iv[is.na(iv) | !nzchar(trimws(iv))] <- ""');
    g.push('  skey <- paste(' + keys.map(function (k) { return 'chr(s[[' + str(k) + ']])'; }).join(', ') +
      ', sep = "\\r")');
    g.push('  val <- rep("", n)');
    g.push('  bad <- rep(FALSE, n)');
    levels.forEach(function (l) {
      if (l.idvar === '') return;
      g.push('  r <- iv == ' + str(l.idvar));
      g.push('  v <- as.character(s$IDVARVAL[r])');
      if (l.type === 'integer' || l.type === 'double') {
        // the merge step's conversion (suppKeyConv); an overflow past 1e308 is bad here, as in the check
        // (the merge step drops those rows with its own filter after the pivot)
        g.push('  num <- ' + suppKeyConv(l.type, 'v'));
        if (l.type === 'double') g.push('  num[is.na(num) | abs(num) > 1e308] <- NA_real_');
        g.push('  cv <- ifelse(is.na(num), NA_character_, as.character(num))');
      } else {
        g.push('  cv <- v');
      }
      g.push('  val[r] <- cv');
      g.push('  bad[r] <- is.na(cv)');
    });
    g.push('  subj <- unique(as.character(s$USUBJID))');
    g.push('  q <- dplyr::select(' + parent + ', dplyr::all_of(c(' + pcols.map(str).join(', ') + ')))');
    if (parentLazy) {
      g.push('  q <- if (anyNA(subj)) {');
      g.push('    dplyr::filter(q, USUBJID %in% !!subj[!is.na(subj)] | is.na(USUBJID))');
      g.push('  } else {');
      g.push('    dplyr::filter(q, USUBJID %in% !!subj)');
      g.push('  }');
      g.push('  p <- as.data.frame(dplyr::collect(dplyr::distinct(q)), stringsAsFactors = FALSE)');
    } else {
      g.push('  p <- as.data.frame(q, stringsAsFactors = FALSE)');
    }
    g.push('  pkey <- paste(' + keys.map(function (k) { return 'chr(p[[' + str(k) + ']])'; }).join(', ') +
      ', sep = "\\r")');
    g.push('  matched <- rep(FALSE, n)');
    levels.forEach(function (l) {
      if (l.idvar === '') {
        g.push('  r <- iv == ""');
        g.push('  matched[r] <- skey[r] %in% pkey');
      } else {
        g.push('  r <- iv == ' + str(l.idvar));
        g.push('  matched[r] <- !bad[r] & paste(skey[r], val[r], sep = "\\r") %in%');
        g.push('    paste(pkey, chr(p[[' + str(l.idvar) + ']]), sep = "\\r")');
      }
    });
    g.push('  keep <- ' + (op === 'supp_orphans' ? '!matched & !bad' : 'bad'));
    g.push('  out <- s[keep, , drop = FALSE]');
    g.push('  rownames(out) <- NULL');
    g.push('  out');
    g.push('})');
    return g.join('\n');
  }

  /** A derive step for Pipeline.add(): `table` is the derived card's name, `args` what R's builder kept. */
  function deriveStep(table, op, inputs, args) {
    inputs = [].concat(inputs || []).map(String);
    args = args || {};
    return {
      kind: 'derive', key: JSON.stringify(['derive', op, inputs, args]),
      table: String(table), op: op, inputs: inputs, args: args
    };
  }

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
      if (!s.table || s.kind === 'derive') return;
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
    // derived tables first, in step order: a chain on one starts from its name, and a derived table
    // may read an earlier derived table. No collect(): a lazy derived table stays lazy (spec 5.4).
    var dsteps = steps.filter(function (s) { return s.kind === 'derive' && self.deriveLive(s); });
    while (dsteps.length) {
      // the first step none of whose inputs is written by a step still waiting (stable otherwise)
      var pick = 0;
      for (var di = 0; di < dsteps.length; di++) {
        var waits = dsteps.some(function (o) {
          return o !== dsteps[di] && dsteps[di].inputs.indexOf(o.table) >= 0;
        });
        if (!waits) { pick = di; break; }
      }
      var ds = dsteps.splice(pick, 1)[0];
      var d = self.deriveExpr(ds);
      if (d.code) out.push(ident(ds.table) + ' <- ' + d.code);
    }
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
          // the pharmaverse style writes combine_supp() where the check found it gives this result
          if (self.combineSuppFor(s).ok) {
            var cp = suppCombinePrep(s, si.ref, self.refFor(t), pipe, self.suppCombine[s.key].prep,
              si.ref !== self.refFor(s.supp));
            supps.push({ step: s, code: cp.code });
            lines.push('metatools::combine_supp(' + cp.ref + ')');
            return;
          }
          supps.push({ step: s, src: si.ref, lazy: !!si.kind, arrow: kind === 'arrow' });
          lines = lines.concat(suppJoins(s, kind));
          return;
        }
        if (s.kind === 'join') {
          var r = rightInfo(s.right);
          var rightRef = r.ref;
          var ctx = {};
          var hasRule = !!s.rule && !self.joinRuleProblem(s);
          var cbk = crossBackend(kind, con, r, hasRule, moveCon, duckRef, t);
          if (cbk.wrap) wrapHead(cbk.wrap[0], cbk.wrap[1]);
          rightRef = cbk.rightRef;
          if (cbk.copy) ctx.copy = true;
          kind = cbk.kind;
          con = cbk.con;
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
        if (p.code !== undefined) return p.code;  // combine_supp() labels its columns itself
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
    return { steps: clone(this.steps), pipe: this.pipe, style: this.style };
  };

  Pipeline.prototype.load = function (obj) {
    if (!obj) return;
    var self = this;
    this.change('load', function () {
      self.steps = (obj.steps || []).map(function (s) { return self.normalize(s); });
    });
    if (obj.pipe) this.setPipe(obj.pipe);
    // a state without a style (0.7.0 or earlier) is the dplyr style; setStyle() maps others to it
    this.setStyle(obj.style);
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
      type_issues: [], hints: [], x_name: xName, y_name: yName
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

  /**
   * Remember the combine_supp field ({ok, reason, prep: {rdomain, idvar_na}, installed}) of the
   * merge check for a supp step's key (null forgets it). A stale check is stored as a not-ok field
   * by the caller. Not pipeline state: no undo, never saved. Emits 'checks' only on a change.
   */
  Pipeline.prototype.setSuppCheck = function (key, field) {
    var had = Object.prototype.hasOwnProperty.call(this.suppCombine, key);
    if (field === null || field === undefined) {
      if (!had) return false;
      delete this.suppCombine[key];
    } else {
      if (had && JSON.stringify(this.suppCombine[key]) === JSON.stringify(field)) return false;
      this.suppCombine[key] = clone(field);
    }
    this.emit('checks');
    return true;
  };

  // Steps a parent may have before a merge that combine_supp() writes: they keep the checked
  // rows (or a subset of them) and their columns as they were.
  var COMBINE_SUPP_BEFORE = { filter: 1, arrange: 1, supp: 1 };

  /**
   * Rule 6 of the pharmaverse style (E1): { ok, reason }. The merge check looks at the two cards,
   * so combine_supp() may stand in for the dplyr code only when the SUPP card has no enabled step of
   * its own and the parent's enabled steps before the merge only filter, sort or merge. Like
   * strictApplies(), compose() and the UI both ask here.
   */
  Pipeline.prototype.combineSuppApplies = function (step) {
    if (!step || step.kind !== 'supp') return { ok: false, reason: 'combine_supp() applies to SUPP merges only.' };
    var steps = this.steps.filter(function (x) { return x.enabled !== false; });
    var at = steps.indexOf(step);
    if (at < 0) {
      for (var i = 0; i < steps.length; i++) if (steps[i].id !== undefined && steps[i].id === step.id) { at = i; break; }
    }
    var own = steps.some(function (x, j) {
      return j !== at && x !== step && x.table === step.supp && x.kind !== 'custom' && x.kind !== 'derive';
    });
    if (own) return { ok: false, reason: step.supp + ' has steps before the merge' };
    var earlier = at < 0 ? [] : steps.slice(0, at);
    var other = earlier.some(function (x) { return x.table === step.table && !COMBINE_SUPP_BEFORE[x.kind]; });
    if (other) return { ok: false, reason: step.table + ' has steps before the merge that combine_supp() cannot check' };
    return { ok: true, reason: '' };
  };

  /**
   * Whether compose() writes combine_supp() for a supp step: { ok, reason, rule }. ok only in the
   * pharmaverse style, with an ok combine_supp field stored for the step (setSuppCheck) and rule 6
   * holding. `rule` names what decided a no: 'style' (the dplyr style; reason null), 'check' (no
   * field yet, reason null; or a not-ok field, its reason) or 'steps' (rule 6, its reason); null when ok.
   */
  Pipeline.prototype.combineSuppFor = function (step) {
    if (this.style !== 'pharmaverse') return { ok: false, reason: null, rule: 'style' };
    var key = step && step.key;
    var f = key !== undefined && Object.prototype.hasOwnProperty.call(this.suppCombine, key) ?
      this.suppCombine[key] : null;
    if (!f) return { ok: false, reason: null, rule: 'check' };
    if (f.ok !== true) {
      return { ok: false, reason: f.reason === undefined || f.reason === null ? null : String(f.reason), rule: 'check' };
    }
    var ap = this.combineSuppApplies(step);
    if (!ap.ok) return { ok: false, reason: ap.reason, rule: 'steps' };
    return { ok: true, reason: null, rule: null };
  };

  // ---- SUPP-- merge check: twin of sv_supp_check() (R/supp.R) ----------------

  function suppKeyType(colType) {
    var t = String(colType === null || colType === undefined ? '' : colType);
    if (/^(integer|int8|int16|int32)$/.test(t)) return 'integer';
    if (/^(numeric|double|float|int64|integer64)$/.test(t)) return 'double';
    if (/^(character|factor|string|utf8|large_utf8)$/.test(t) || /^dictionary</.test(t)) return 'character';
    return null;
  }

  // The whitespace allowed around a numeric IDVARVAL: ASCII only (space, tab, LF, CR, FF, VT),
  // which is what R's as.integer()/as.numeric() skip. \s and trim() would also take NBSP,
  // U+2028, U+3000 and the BOM, so the class is spelled out, here and in sv_supp_ws (R/supp.R).
  // The generated code runs these patterns with perl = TRUE: TRE reads "\t" in a bracket as a
  // backslash and a "t". \x0b is VT (in PCRE \v is a class of its own).
  var SUPP_WS = '[ \\t\\n\\r\\f\\x0b]';
  var SUPP_INT_RE = new RegExp('^' + SUPP_WS + '*[+-]?[0-9]+' + SUPP_WS + '*$');
  var SUPP_DBL_RE = new RegExp('^' + SUPP_WS + '*[+-]?([0-9]+[.]?[0-9]*|[.][0-9]+)([eE][+-]?[0-9]+)?' +
    SUPP_WS + '*$');
  var SUPP_WS_EDGES = new RegExp('^' + SUPP_WS + '+|' + SUPP_WS + '+$', 'g');
  // Past this a double key is bad: R parses "1.7976931348623158e308" (the largest double) to
  // Inf where Number() keeps it, so the top of the range is cut off on both sides alike.
  var SUPP_DBL_MAX = 1e308;

  // ---- R's as.character() for a double, under scipen = 0 (twin of sv_r_chr, R/supp.R) ----
  // R keeps the fewest significant digits, at most 15, that give the value rounded to 15 digits
  // (ties to even), and writes the fixed form when it is no wider than the scientific one. The
  // digits are worked out exactly here (BigInt). R works them out in long double arithmetic and
  // prints with the C library, so a value within a hair of a rounding tie may come out otherwise
  // there: such a value is not sure (rAsCharacterSure), and the combine_supp field says not ok.
  var HAS_BIGINT = typeof BigInt === 'function';
  var P10 = [];
  function pow10n(k) {
    if (!P10.length) P10.push(BigInt(1));
    while (P10.length <= k) P10.push(P10[P10.length - 1] * BigInt(10));
    return P10[k];
  }

  // x > 0, finite: x = num / den exactly, den a power of 2
  function dblExact(x) {
    var dv = new DataView(new ArrayBuffer(8));
    dv.setFloat64(0, x);
    var hi = dv.getUint32(0), ex = (hi >>> 20) & 0x7ff;
    var m = BigInt(hi & 0xfffff) * BigInt(4294967296) + BigInt(dv.getUint32(4));
    var e = -1074;
    if (ex !== 0) { m = m + BigInt(4503599627370496); e = ex - 1075; }
    return e >= 0 ? { num: m << BigInt(e), den: BigInt(1) } : { num: m, den: BigInt(1) << BigInt(-e) };
  }

  // a / b rounded to an integer, ties to even; `tie`: exactly half way; `half(n, d)`: the
  // fraction a / b - floor(a / b) is within n / d of one half
  function roundEven(a, b) {
    var q = a / b, two = (a % b) * BigInt(2);
    if (two > b || (two === b && q % BigInt(2) === BigInt(1))) q = q + BigInt(1);
    var gap = two > b ? two - b : b - two;
    return { q: q, tie: two === b, half: function (n, d) { return gap * BigInt(d) <= b * BigInt(2 * n); } };
  }

  function rChr(x) {
    if (x === null || x === undefined) return { text: null, sure: true };
    if (x === 'Inf' || x === '-Inf' || x === 'NaN') return { text: x, sure: true };
    x = Number(x);
    if (isNaN(x)) return { text: 'NaN', sure: true };
    if (!isFinite(x)) return { text: x > 0 ? 'Inf' : '-Inf', sure: true };
    if (x === 0) return { text: '0', sure: true };
    if (!HAS_BIGINT) return { text: String(x), sure: false };
    var neg = x < 0 ? 1 : 0, ex = dblExact(Math.abs(x));
    var cmp10 = function (p) {   // sign of |x| - 10^p
      var l = p >= 0 ? ex.num : ex.num * pow10n(-p), r = p >= 0 ? ex.den * pow10n(p) : ex.den;
      return l < r ? -1 : (l > r ? 1 : 0);
    };
    var e10 = Math.floor(Math.log10(Math.abs(x)));
    while (cmp10(e10) < 0) e10--;
    while (cmp10(e10 + 1) >= 0) e10++;
    // the 15 significant digits: R's alpha = |x| / 10^kp, rounded
    var kp = e10 - 14;
    var a = roundEven(kp >= 0 ? ex.num : ex.num * pow10n(-kp), kp >= 0 ? ex.den * pow10n(kp) : ex.den);
    var q = a.q;
    if (q === pow10n(15)) { q = pow10n(14); e10++; }
    var mant = q.toString().replace(/0+$/, ''), nsig = mant.length;
    var sciW = neg + (nsig > 1 ? nsig + 1 : 1) + (Math.abs(e10) >= 100 ? 5 : 4);
    var rgt = Math.max(0, nsig - e10 - 1);
    var fixW = neg + (e10 >= 0 ? e10 + 1 : 1) + (rgt > 0 ? rgt + 1 : 0);
    // R scales by a power of ten held exactly only for |kp| < 10; past -308 it scales in double
    var sure = kp <= -308 ? !a.half(3, 10) : (a.tie ? Math.abs(kp) < 10 : !a.half(1, 1000));
    var text;
    if (fixW <= sciW) {
      var f = roundEven(ex.num * pow10n(rgt), ex.den);
      text = f.q.toString();
      if (rgt > 0) {
        while (text.length <= rgt) text = '0' + text;
        text = text.slice(0, text.length - rgt) + '.' + text.slice(text.length - rgt);
      }
      // the C library rounds the printed digits on its own: a near-tie there may differ; and
      // past 19 integer digits R's printf on Windows is not exact (about 1 in 8 at 20 digits)
      if (f.half(1, 50) || e10 >= 19) sure = false;
    } else {
      var ae = Math.abs(e10);
      text = mant.charAt(0) + (nsig > 1 ? '.' + mant.slice(1) : '') + 'e' + (e10 < 0 ? '-' : '+') +
        (ae < 10 ? '0' : '') + ae;
      if (a.tie && nsig === 15) sure = false;
    }
    return { text: (neg ? '-' : '') + text, sure: sure };
  }

  /** R's as.character(x) for a double x (scipen = 0); null for NA. Also takes "Inf", "-Inf", "NaN". */
  function rAsCharacter(x) { return rChr(x).text; }

  /** Whether rAsCharacter(x) is known to equal R's text (false near a rounding tie). */
  function rAsCharacterSure(x) { return rChr(x).sure; }

  // The Unicode White_Space set that stringr::str_trim() trims; twin of sv_str_trim_ws (R/supp.R).
  // Not trim(), which also takes the BOM and not U+0085; not SUPP_WS, the ASCII class of the keys.
  var STR_TRIM_WS = '[\\t\\n\\x0b\\f\\r \\x85\\xa0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000]';
  var STR_TRIM_EDGES = new RegExp('^' + STR_TRIM_WS + '+|' + STR_TRIM_WS + '+$', 'g');

  /** stringr::str_trim(s): also drops one leading BOM, as stringi does; null for NA. */
  function strTrim(s) {
    if (s === null || s === undefined) return null;
    return String(s).replace(/^\ufeff/, '').replace(STR_TRIM_EDGES, '');
  }

  // A missing value is the string "NA" once keys are pasted together, as in R.
  function suppChr(v) {
    return v === null || v === undefined ? 'NA' : String(v);
  }

  // A key value as the check pastes it: a double as R's as.character() writes it (15 digits).
  function suppKeyText(v, type) {
    return type === 'double' && typeof v === 'number' ? rAsCharacter(v) : suppChr(v);
  }

  // IDVARVAL converted to a numeric key type as a number; null means it did not convert.
  function suppConvertNum(v, type) {
    if (v === null || v === undefined) return null;
    var s = String(v);
    if (type === 'integer') {
      if (!SUPP_INT_RE.test(s)) return null;
      var n = parseInt(s.replace(SUPP_WS_EDGES, ''), 10);
      return isFinite(n) && Math.abs(n) <= 2147483647 ? n : null;
    }
    if (!SUPP_DBL_RE.test(s)) return null;
    var d = Number(s.replace(SUPP_WS_EDGES, ''));
    // 1e999 overflows to Infinity: bad, as in R; so is anything past SUPP_DBL_MAX
    return isFinite(d) && Math.abs(d) <= SUPP_DBL_MAX ? d : null;
  }

  // Whether R's as.numeric() surely reads this decimal text as the double Number() reads. R's
  // R_strtod gathers the digits in long double and then multiplies or divides by a power of ten,
  // so a value that is not exact is rounded twice and can land on the neighbouring double (about
  // 1 text in 8000, short ones such as "6.228e-9" too). Sure only where nothing is rounded: the
  // digits make an integer below 2^64 (exact in long double), the power of ten is at most 10^27
  // (exact), the value is itself a double, and it has at most 15 significant digits.
  // test-supp.R holds this to R over a sweep of texts.
  function suppNumSure(v) {
    if (!HAS_BIGINT || v === null || v === undefined) return false;
    var m = /^[+-]?([0-9]*)(?:[.]([0-9]*))?(?:[eE]([+-]?[0-9]+))?$/.exec(String(v).replace(SUPP_WS_EDGES, ''));
    if (!m) return false;
    var frac = m[2] || '', digits = (m[1] + frac).replace(/^0+/, '');
    if (digits === '') return true; // zero
    if (digits.length > 20 || digits.replace(/0+$/, '').length > 15) return false;
    var expn = (m[3] === undefined ? 0 : Number(m[3])) - frac.length;
    if (!isFinite(expn) || Math.abs(expn) > 27) return false;
    var num = BigInt(digits), den = BigInt(1), zero = BigInt(0), one = BigInt(1), two = BigInt(2);
    if (num >= BigInt('18446744073709551616')) return false;
    if (expn >= 0) num = num * pow10n(expn); else den = pow10n(-expn);
    // a double: num / den = odd * 2^j with odd < 2^53, so the 5s of den must divide num
    var five = BigInt(5);
    while (den % five === zero) {
      if (num % five !== zero) return false;
      num = num / five;
      den = den / five;
    }
    while (num % two === zero) num = num / two;
    return num < BigInt('9007199254740992') && (den & (den - one)) === zero;
  }

  // IDVARVAL text converted to the key type; null means it did not convert.
  function suppConvert(v, type) {
    if (v === null || v === undefined) return null;
    if (type === 'character') return String(v);
    var n = suppConvertNum(v, type);
    return n === null ? null : suppKeyText(n, type);
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
  // parentTypes: {col: colType}, suppTypes: {col: colType} (R class names; guessed when absent),
  // parentCols, suppCols, plan, sampleN, lazy: {name, kind: 'duckdb'|'arrow'} or null (a lazy
  // card: combine_supp rule 2), preview: true when a card holds only its preview rows (rule 3),
  // rounded: true when the rows came through 16-digit JSON (the widget), inexact: {parent: [...],
  // supp: [...]}, each card's col_inexact (rule 7 then trusts only the double columns not listed;
  // with rounded and no inexact it trusts none)}. combine_supp is not ok unless both type maps
  // name every column rules 7 and 8 read.
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
      // blank as R's trimws() sees it: space, tab, CR and LF only (trim() would also take NBSP)
      return v === null || v === undefined || /^[ \t\r\n]*$/.test(String(v)) ? '' : String(v);
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
    // key text as sv_supp_key_chr() writes it: a double key in R's 15 digits, on each side by its type
    var keyKinds = function (rows, given) {
      return keys.map(function (c) {
        var t = (given || {})[c];
        return suppKeyType(t === undefined || t === null ? suppGuessType(rows, c) : t);
      });
    };
    var pKinds = keyKinds(parentRows, opts.parentTypes), sKinds = keyKinds(suppRows, opts.suppTypes);
    var keyFn = function (kinds) {
      return function (row) { return keys.map(function (c, n) { return suppKeyText(row[c], kinds[n]); }).join('\r'); };
    };
    var keyOf = keyFn(pKinds);
    var pkey = parentRows.map(keyOf), skey = suppRows.map(keyFn(sKinds));

    // num: the converted value as a number on a numeric level (the combine_supp rows compare it)
    var val = [], bad = [], matched = [], num = [];
    for (i = 0; i < nSupp; i++) { val.push(''); bad.push(false); matched.push(false); num.push(null); }
    var pset = {};
    pkey.forEach(function (x) { pset[x] = true; });
    levels.forEach(function (iv) {
      var pairs = null;
      if (iv !== '') {
        pairs = {};
        parentRows.forEach(function (r, j) { pairs[pkey[j] + '\r' + suppKeyText(r[iv], types[iv])] = true; });
      }
      for (var j = 0; j < nSupp; j++) {
        if (idvar[j] !== iv) continue;
        if (iv === '') { matched[j] = !!pset[skey[j]]; continue; }
        var cv = suppConvert(suppRows[j].IDVARVAL, types[iv]);
        val[j] = cv;
        bad[j] = cv === null;
        if (types[iv] !== 'character') num[j] = suppConvertNum(suppRows[j].IDVARVAL, types[iv]);
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
        var pk = iv !== '' ? pvKey[j] + '\r' + suppKeyText(o[iv], types[iv]) : pvKey[j];
        o[q] = Object.prototype.hasOwnProperty.call(look, pk) ? look[pk] : null;
      });
    });

    var combine = suppCombine({
      parentRows: parentRows, suppRows: suppRows, pNames: pNames, sNames: sNames,
      parentName: parentName, suppName: suppName, levels: levels, idvar: idvar, qnam: qnam,
      types: types, keys: keys, matched: matched, val: val, bad: bad, num: num, plan: newPlan,
      nOther: nOther, opts: opts,
      check: { status: status, repeats: { n: count(dup) }, clashes: clashes, two_level: twoLevel }
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
      drift: drift,
      combine_supp: combine
    };
  }

  // ---- combine_supp: would metatools::combine_supp() give the dplyr code's result? ----
  // Twin of sv_supp_combine() (R/supp.R) and, for rules 2 and 3, of the lazy check (R/lazy.R).
  // The browser cannot tell whether metatools is installed: `installed` is null, R fills it in.

  /** Rule 1: the reason for a check whose status is "error" (the merge code stops). */
  function combineSuppStopReason(d, parentName) {
    d = d || {};
    var n = d.repeats && d.repeats.n, clashes = suppList(d.clashes), two = suppList(d.two_level);
    var parts = [];
    if (n !== null && n !== undefined && n > 0) parts.push(n + ' repeated QNAM ' + (n === 1 ? 'record' : 'records'));
    if (clashes.length) parts.push(clashes.join(', ') + ' already in ' + parentName);
    if (two.length) parts.push(two.join(', ') + ' on two IDVAR levels');
    return 'The merge stops: ' + parts.join('; ');
  }

  var COMBINE_SUPP_COLS = ['STUDYID', 'RDOMAIN', 'USUBJID', 'IDVAR', 'IDVARVAL', 'QNAM', 'QLABEL', 'QVAL', 'QORIG'];
  var COMBINE_PARENT_COLS = ['STUDYID', 'DOMAIN', 'USUBJID'];

  // A number as exact text, so equal text is equal doubles (sv_supp_hex); -0 is 0, NA is "NA".
  function suppHex(x) {
    if (x === null || x === undefined) return 'NA';
    var n = Number(x);
    return n === 0 ? '0' : String(n);
  }

  // For each element of `s`, how many elements of `p` equal it (sv_supp_count).
  function suppCount(p, s) {
    var m = new Map();
    p.forEach(function (x) { m.set(x, (m.get(x) || 0) + 1); });
    return s.map(function (x) { return m.get(x) || 0; });
  }

  function suppCombine(c) {
    var opts = c.opts, suppRows = c.suppRows, parentRows = c.parentRows;
    var idvarNa = suppRows.some(function (r) {
      return r.IDVAR !== null && r.IDVAR !== undefined && /^[ \t\r\n]*$/.test(String(r.IDVAR));
    });
    var prep = { rdomain: c.nOther > 0, idvar_na: idvarNa };
    var no = function (reason) { return { ok: false, reason: reason, prep: prep, installed: null }; };
    // rule 1: the merge stops
    if (c.check.status === 'error') return no(combineSuppStopReason(c.check, c.parentName));
    // rule 2: combine_supp() needs data frames
    var lazy = opts.lazy;
    if (lazy) {
      return no('combine_supp() needs data frames: ' + lazy.name + ' is ' +
        (lazy.kind === 'arrow' ? 'an Arrow table' : 'a duckdb table'));
    }
    // rule 3: a preview-only card
    if (opts.preview) return no('Checked on preview rows only');
    // rule 4: exactly the SDTM SUPP columns (QEVAL may be there or not)
    var miss = suppSetdiff(COMBINE_SUPP_COLS, c.sNames);
    if (miss.length) return no(c.suppName + ' has no ' + miss[0] + ' column');
    var extra = suppSetdiff(c.sNames, COMBINE_SUPP_COLS.concat(['QEVAL']));
    if (extra.length) return no(c.suppName + ' has extra columns: ' + extra.join(', '));
    // rule 5: it joins on STUDYID, DOMAIN and USUBJID
    miss = suppSetdiff(COMBINE_PARENT_COLS, c.pNames);
    if (miss.length) return no(c.parentName + ' has no ' + miss[0] + ' column');
    // it drops a parent IDVARVAL column (ret$IDVARVAL <- NULL); the dplyr code keeps it
    if (c.pNames.indexOf('IDVARVAL') >= 0) return no(c.parentName + ' has an IDVARVAL column, which combine_supp() would drop');
    // rules 7 and 8 need R's text of each value, so R's class of every column they read
    var typed = function (types, cols) {
      if (types === null || types === undefined || typeof types !== 'object' || Array.isArray(types)) return false;
      return cols.every(function (k) { var t = types[k]; return t !== null && t !== undefined && t !== ''; });
    };
    var pNeed = ['STUDYID', 'USUBJID', 'DOMAIN'].concat(c.keys,
      c.levels.filter(function (iv) { return iv !== ''; }));
    var sNeed = ['STUDYID', 'USUBJID', 'RDOMAIN', 'IDVARVAL', 'QLABEL', 'QNAM'].concat(c.keys);
    if (!typed(opts.parentTypes, pNeed) || !typed(opts.suppTypes, sNeed)) {
      return no('Column types are not known in the browser');
    }
    var why = suppCombineRows(c);
    if (why === null) why = suppCombineFactor(c);
    if (why === null) why = suppCombineLabels(c);
    if (why !== null) return no(why);
    return { ok: true, reason: null, prep: prep, installed: null };
  }

  // Rule 7, the rows (sv_supp_combine_rows): for each SUPP row, the parent rows the dplyr code
  // joins ("ours") and those combine_supp() joins ("theirs") must be the same set.
  function suppCombineRows(c) {
    var parentRows = c.parentRows, s = c.suppRows, opts = c.opts, n = s.length;
    var pTypes = opts.parentTypes || {}, sTypes = opts.suppTypes || {};
    var typeOf = function (rows, given, col) {
      var t = given[col];
      return t === undefined || t === null ? suppGuessType(rows, col) : String(t);
    };
    var unsure = null;
    var tooClose = function (col, t) { return col + ' ' + t + " is too close to R's rounding to check in the browser"; };
    // opts.rounded: the rows came through 16-digit JSON (the widget), where Inf and NaN arrive as
    // null and some doubles arrive changed. opts.inexact = {parent: [...], supp: [...]} names the
    // double columns R found not to survive that (sv_inexact_cols()); the others are exact and
    // null in them is NA. Without the list no double column can be trusted.
    var rounded = !!opts.rounded;
    var inexact = opts.inexact;
    var lossy = function (side, col) {
      var l = inexact !== null && inexact !== undefined && typeof inexact === 'object' ? inexact[side] : null;
      if (typeof l === 'string') l = [l];
      return !Array.isArray(l) || l.indexOf(col) >= 0;
    };
    // R's text of one value (sv_r_chr for theirs; sv_supp_key_chr for ours, where an integer64
    // key is a double). A value whose text may not be R's is remembered for the reason.
    var text = function (v, type, col, ours) {
      var dbl = /^(numeric|double|float)$/.test(type) || (ours && suppKeyType(type) === 'double');
      if (v === null || v === undefined) return null;
      if (typeof v === 'boolean') return v ? 'TRUE' : 'FALSE';
      if (!dbl || (typeof v !== 'number' && v !== 'Inf' && v !== '-Inf' && v !== 'NaN')) return String(v);
      var r = rChr(v);
      if (!r.sure && unsure === null) unsure = tooClose(col, r.text);
      return r.text;
    };
    var column = function (rows, given, col, ours) {
      var ty = typeOf(rows, given, col);
      if (rounded && unsure === null && rows.length && suppKeyType(ty) === 'double' &&
          lossy(rows === parentRows ? 'parent' : 'supp', col)) {
        unsure = col + ' has values the browser cannot read exactly';
      }
      return rows.map(function (r) { return text(r[col], ty, col, ours); });
    };
    var enc = function (x) { return x === null ? '\x01' : '\x02' + x; };
    var paste = function (cols) {
      return cols.length ? cols[0].map(function (_, j) {
        return cols.map(function (col) { return col[j]; }).join('\r');
      }) : [];
    };
    var keyCols = function (rows, given) {
      return paste(c.keys.map(function (k) {
        return column(rows, given, k, true).map(function (x) { return x === null ? 'NA' : x; });
      }));
    };
    var pkey = keyCols(parentRows, pTypes), skey = keyCols(s, sTypes);
    var pk_t = paste(['STUDYID', 'DOMAIN', 'USUBJID'].map(function (k) { return column(parentRows, pTypes, k).map(enc); }));
    var sk_t = paste(['STUDYID', 'RDOMAIN', 'USUBJID'].map(function (k) { return column(s, sTypes, k).map(enc); }));
    var ivText = column(s, sTypes, 'IDVARVAL');
    var nO = [], nT = [], nB = [], sO = [], sT = [], lv = {}, pvText = {};
    for (var i = 0; i < n; i++) { nO.push(0); nT.push(0); nB.push(0); sO.push(''); sT.push(''); }
    c.levels.forEach(function (iv) {
      var r = [];
      for (var j = 0; j < n; j++) if (c.idvar[j] === iv) r.push(j);
      var joins = r.map(function (j) { return c.matched[j]; });
      var pO, pT;
      if (iv === '') {
        pO = pkey;
        pT = pk_t;
        r.forEach(function (j) { sO[j] = skey[j]; sT[j] = sk_t[j]; });
      } else {
        var pv = parentRows.map(function (row) { return row[iv]; });
        if (c.types[iv] === 'character') {
          var kc = column(parentRows, pTypes, iv, true);
          pO = pkey.map(function (k, j) { return k + '\r' + (kc[j] === null ? 'NA' : kc[j]); });
          r.forEach(function (j) { sO[j] = skey[j] + '\r' + (c.val[j] === null ? 'NA' : c.val[j]); });
        } else {
          pO = pkey.map(function (k, j) { return k + '\r' + suppHex(pv[j]); });
          r.forEach(function (j) { sO[j] = skey[j] + '\r' + suppHex(c.num[j]); });
          joins = r.map(function (j) { return !c.bad[j]; });
        }
        pvText[iv] = column(parentRows, pTypes, iv);
        // a double IDVARVAL that R may read as another double (suppNumSure) makes ours uncertain;
        // a row the browser marks bad too: near the 1e308 cut R may read the text as a double
        // it keeps where Number() reads one past the cut. No sure text is past the cut (sure
        // means below 2^64 * 10^27), so a sure row is never bad for its size.
        if (c.types[iv] === 'double' && unsure === null) {
          r.forEach(function (j) {
            var t = s[j].IDVARVAL;
            if (unsure === null && t !== null && t !== undefined && SUPP_DBL_RE.test(String(t)) &&
                !suppNumSure(t)) {
              unsure = tooClose('IDVARVAL', String(s[j].IDVARVAL).replace(SUPP_WS_EDGES, ''));
            }
          });
        }
        pT = pk_t.map(function (k, j) { return k + '\r' + enc(strTrim(pvText[iv][j])); });
        r.forEach(function (j) { sT[j] = sk_t[j] + '\r' + enc(strTrim(ivText[j])); });
      }
      var rO = r.map(function (j) { return sO[j]; }), rT = r.map(function (j) { return sT[j]; });
      var cO = suppCount(pO, rO), cT = suppCount(pT, rT);
      var cB = suppCount(pO.map(function (x, j) { return x + '\n' + pT[j]; }),
        r.map(function (j) { return sO[j] + '\n' + sT[j]; }));
      r.forEach(function (j, k) {
        nO[j] = joins[k] ? cO[k] : 0;
        nT[j] = cT[k];
        nB[j] = joins[k] ? cB[k] : 0;
      });
      lv[iv] = { pO: pO, pT: pT };
    });
    // a text that may not be R's makes every comparison above uncertain
    if (unsure !== null) return unsure;
    var say = function (x) { return x === null ? 'NA' : x; };
    for (i = 0; i < n; i++) {
      if (nO[i] === nT[i] && nB[i] === nO[i]) continue;
      var iv = c.idvar[i];
      if (iv === '') return say(column([s[i]], sTypes, 'USUBJID')[0]) + ' would not match in combine_supp()';
      var p = lv[iv];
      var v = 'IDVARVAL "' + say(ivText[i]) + '" ';
      var key = function (j) { return iv + ' ' + say(j < 0 ? null : pvText[iv][j]); };
      if (nT[i] === 0) return v + 'would not match ' + key(p.pO.indexOf(sO[i])) + ' in combine_supp()';
      if (nO[i] === 0) return v + 'would match ' + key(p.pT.indexOf(sT[i])) + ' in combine_supp()';
      return v + 'would match a different ' + c.parentName + ' record in combine_supp()';
    }
    return null;
  }

  // Rule 7, the classes (sv_supp_combine_factor): a join turns a factor it joins on into text.
  // Rule 8, the classes: combine_supp() picks a factor QNAM's column by its code and sets a factor
  // QLABEL as the label.
  function suppCombineFactor(c) {
    var pTypes = c.opts.parentTypes || {};
    var sTypes = c.opts.suppTypes || {};
    var isFactor = function (col, types) { return /^(factor|ordered)$/.test(String((types || pTypes)[col])); };
    for (var i = 0; i < c.levels.length; i++) {
      var iv = c.levels[i];
      if (iv !== '' && isFactor(iv)) return iv + ' would be a factor in combine_supp(), not text';
    }
    if (isFactor('DOMAIN')) return 'DOMAIN would be text in combine_supp(), not a factor';
    if (isFactor('QNAM', sTypes)) return c.suppName + ' QNAM is a factor, so combine_supp() would label the wrong columns';
    if (isFactor('QLABEL', sTypes)) return c.suppName + ' QLABEL is a factor, so combine_supp() would set factor labels';
    return null;
  }

  // Rule 8, the labels (sv_supp_combine_labels): combine_supp() takes the last distinct QLABEL of
  // a QNAM, in order of first appearance; ours is the plan's. NA and "" both mean no label.
  function suppCombineLabels(c) {
    if (c.sNames.indexOf('QLABEL') < 0) return null;
    var none = function (x) { return x === null || x === undefined || x === ''; };
    var say = function (x) { return none(x) ? 'none' : '"' + x + '"'; };
    var lab = c.suppRows.map(function (r) {
      var l = r.QLABEL;
      return l === null || l === undefined ? null : String(l);
    });
    var qnams = c.plan.qnams;
    for (var i = 0; i < qnams.length; i++) {
      var q = qnams[i].qnam, ours = qnams[i].label, seen = new Map(), theirs = null;
      for (var j = 0; j < lab.length; j++) {
        if (c.qnam[j] !== q || seen.has(lab[j])) continue;
        seen.set(lab[j], true);
        theirs = lab[j];
      }
      if (none(ours) && none(theirs)) continue;
      if (!none(ours) && !none(theirs) && ours === theirs) continue;
      return q + ' label would be ' + say(theirs) + ' in combine_supp(), not ' + say(ours);
    }
    return null;
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
    return suppKeyConv(type, 'IDVARVAL');
  }

  // The one conversion of IDVARVAL text to the key's type, for the merge step (`vec` = the column
  // IDVARVAL) and the derive step (`vec` = the level's text vector). Both must agree, so both use it.
  function suppKeyConv(type, vec) {
    if (type !== 'integer' && type !== 'double') return vec;
    var re = type === 'integer' ? SUPP_INT_RE.source : SUPP_DBL_RE.source;
    return 'suppressWarnings(' + (type === 'integer' ? 'as.integer' : 'as.numeric') +
      '(dplyr::if_else(grepl(' + str(re) + ', ' + vec + ', perl = TRUE), as.character(' + vec + '), NA_character_)))';
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
    // a missing QNAM is the name "NA", as in the check and as pivot_wider() names its column, so
    // the guards below see an NA QNAM and a QNAM "NA" as one name
    ql.push('dplyr::mutate(IDVAR = dplyr::if_else(is.na(IDVAR) | trimws(IDVAR) == "", "", as.character(IDVAR)),\n' +
      '                QNAM = dplyr::coalesce(as.character(QNAM), "NA"))');
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
      // (a double key that overflows, "1e999", is Inf, and one past 1e308 is bad in the check too)
      if (iv !== '') l.push(v.type === 'double' ? 'dplyr::filter(abs(' + ident(iv) + ') <= 1e308)' : 'dplyr::filter(!is.na(' + ident(iv) + '))');
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
        // (read at run time). The check compares the parent's values as doubles, so a key that
        // does not survive the cast unchanged matches nothing: a fraction on an integer type, a
        // value out of the type's range (300 on int8, 1e19 on int64), a float32 or decimal
        // rounding (0.1, 0.125 on decimal(10, 2)). Such rows are dropped, never rounded onto a
        // record. The test cast is unsafe, so it wraps instead of stopping; a decimal cast stops
        // on overflow even then, so the keys are then tested one at a time.
        var k = str(iv);
        out.push(nm + ' <- local({\n' +
          '  ty <- arrow::as_arrow_table(utils::head(' + parentRef + ', 0))$schema[[' + k + ']]$type\n' +
          '  x <- ' + nm + '\n' +
          '  same <- function(v) {\n' +
          '    cv <- suppressWarnings(as.numeric(as.vector(arrow::Array$create(v)$cast(ty, safe = FALSE))))\n' +
          '    !is.na(cv) & cv == v\n' +
          '  }\n' +
          '  ok <- tryCatch(same(x[[' + k + ']]), error = function(e)\n' +
          '    vapply(x[[' + k + ']], function(v) isTRUE(tryCatch(same(v), error = function(e) FALSE)), logical(1)))\n' +
          '  x <- arrow::arrow_table(x[ok, ])\n' +
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
      // NA keys match NA, as in the check and in memory. Arrow's default is already "na";
      // writing it out keeps the code from depending on that default.
      var extra = kind === 'duckdb' ? ', copy = TRUE, na_matches = "na"' :
        kind === 'arrow' ? ', na_matches = "na"' : '';
      return 'dplyr::left_join(' + (wrap ? 'arrow::arrow_table(' + nm + ')' : nm) +
        ', by = ' + joinBy(by) + extra + ')';
    });
  }

  function suppLabelLine(s) {
    var L = ident(String(s.supp) + '_labels');
    return 'dplyr::mutate(dplyr::across(dplyr::any_of(names(' + L + ')),\n    ~ structure(.x, label = ' +
      L + '[[dplyr::cur_column()]])))';
  }

  /**
   * The statements written before the parent's chain in the pharmaverse style (E1 design §5.3), and
   * what the chain's metatools::combine_supp() call takes: { code, ref }. `src` is the SUPP side's
   * code (the card, or its _prep chain: `chained`); `prep` the field's {rdomain, idvar_na}. <supp>_q
   * is written only with a prep line or a SUPP chain; else the guards and the call read `src`.
   * The guards are the 0.7.0 ones combine_supp() does not do itself (IDVAR values the plan does not
   * handle, QNAMs at two levels, a repeated QNAM for one record: on the converted key for a numeric
   * level, the trimmed IDVARVAL for a text level), with no clash guard (combine_supp() stops on a
   * clash). Then the later-cut guards. First the input guards: a parent grouped into more than one
   * group or a grouped SUPP (rowwise with group columns too), and a parent IDVARVAL column. A
   * DOMAIN guard: each parent record the dplyr code joins a SUPP row to must have the row's RDOMAIN as DOMAIN (NA never matches). And one key guard per
   * keyed level: the records a row finds as the dplyr code joins (the merge keys plus the key: by
   * number with suppKeyConv() and its overflow rule, keys as sprintf("%.17g") text so the session's
   * scipen plays no part, or by exact text) must be the records it finds as combine_supp() joins
   * (STUDYID, DOMAIN == RDOMAIN, USUBJID and stringr::str_trim(as.character()) on both keys, under
   * the session's scipen). NA matches NA in both. Then the type guards (DOMAIN and each IDVAR key
   * keep their type through the joins), a subject-level guard for rows only combine_supp() sees
   * (no RDOMAIN prep line), the column guard (no QNAM column the dplyr code lacks) and the label
   * guards (combine_supp()'s last QLABEL must be the plan's label; no factor QNAM or QLABEL).
   * They only stop: they never reshape the data.
   */
  function suppCombinePrep(s, src, parentRef, pipe, prep, chained) {
    var S = String(s.supp);
    var nl = ' ' + pipe + '\n  ';
    var gl = ' ' + pipe + '\n    ';
    var levels = s.idvars.map(function (v) { return v.idvar; });
    var out = [];
    var ql = [src];
    if (prep && prep.rdomain) ql.push('dplyr::filter(RDOMAIN == ' + str(s.rdomain) + ')');
    if (prep && prep.idvar_na) ql.push('dplyr::mutate(IDVAR = dplyr::na_if(trimws(IDVAR), ""))');
    var ref = src;
    if (ql.length > 1 || chained) {
      ref = ident(S + '_q');
      out.push(ref + ' <- ' + ql.join(nl));
    }

    var P = String(s.table);
    var tl = '; use the dplyr code style for this merge';
    var g = ['local({'];
    // Grouped inputs: the dplyr code's label step loses the labels across the parent's groups, and
    // its pivot keeps a grouped SUPP's group columns; combine_supp() does neither. One group
    // (or a rowwise SUPP with no group columns) gives the same result. A lazy table is not a
    // grouped_df, so these pass it. And combine_supp() drops a parent IDVARVAL column (checked on a
    // data frame only: names() of a tbl_lazy warns).
    g.push('  p <- ' + parentRef);
    g.push('  grp <- function(x) {');
    g.push('    v <- paste(dplyr::group_vars(x), collapse = ", ")');
    g.push('    if (!inherits(x, "rowwise_df")) paste("grouped by", v) else if (nzchar(v)) paste0("rowwise (by ", v, ")") else "rowwise"');
    g.push('  }');
    g.push('  if (inherits(p, c("grouped_df", "rowwise_df")) && dplyr::n_groups(p) > 1L) stop(' + str(P + ' is ') + ', grp(p),');
    g.push('    ' + str(', which combine_supp() and the dplyr code treat differently' + tl) + ', call. = FALSE)');
    g.push('  if (inherits(' + ref + ', c("grouped_df", "rowwise_df")) && length(dplyr::group_vars(' + ref + '))) stop(' + str(S + ' is ') + ', grp(' + ref + '),');
    g.push('    ' + str(', which combine_supp() and the dplyr code treat differently' + tl) + ', call. = FALSE)');
    g.push('  if (is.data.frame(p) && "IDVARVAL" %in% names(p)) stop(' + str(P + ' has an IDVARVAL column, which combine_supp() would drop' + tl) + ', call. = FALSE)');
    // the guards' own copy: subject level as "", a missing QNAM as "NA" (as the 0.7.0 <supp>_q)
    g.push('  q <- ' + [ref, 'dplyr::mutate(IDVAR = dplyr::if_else(is.na(IDVAR) | trimws(IDVAR) == "", "", as.character(IDVAR)),\n' +
      '                  QNAM = dplyr::coalesce(as.character(QNAM), "NA"))'].join(gl));
    g.push('  other <- setdiff(unique(q$IDVAR), c(' + levels.map(str).join(', ') + '))');
    if (levels.indexOf('') < 0) g.push('  other[other == ""] <- "(subject level)"');
    g.push('  if (length(other)) stop(' + str(S + ' has IDVAR values this merge does not handle: ') + ',');
    g.push('    paste(other, collapse = ", "), ". Refresh the merge step.", call. = FALSE)');
    if (levels.length > 1) {
      g.push('  lv <- unique(q[c("QNAM", "IDVAR")])');
      g.push('  both <- unique(lv$QNAM[duplicated(lv$QNAM)])');
      g.push('  if (length(both)) stop(' + str(S + ' QNAMs are at two levels: ') +
        ', paste(both, collapse = ", "), call. = FALSE)');
    }
    s.idvars.forEach(function (v) {
      var iv = v.idvar;
      var cols = s.keys.map(ident);
      var dupCols = s.keys.slice();
      // a numeric level keys on the converted IDVARVAL ("01" and "1" are one record), a text level
      // on the trimmed IDVARVAL, as combine_supp() joins ("G2" and "G2 " are one record)
      if (iv !== '') {
        cols.push(ident(iv) + ' = ' + (v.type === 'character' ?
          'stringr::str_trim(as.character(IDVARVAL))' : suppKeyExpr(v.type)));
        dupCols.push(iv);
      }
      cols.push('QNAM');
      dupCols.push('QNAM');
      var l = ['q', 'dplyr::filter(IDVAR == ' + str(iv) + ')', 'dplyr::transmute(' + cols.join(', ') + ')'];
      if (iv !== '') l.push(v.type === 'double' ? 'dplyr::filter(abs(' + ident(iv) + ') <= 1e308)' : 'dplyr::filter(!is.na(' + ident(iv) + '))');
      g.push('  x <- ' + l.join(gl));
      g.push('  dup <- x[duplicated(x[c(' + dupCols.map(str).join(', ') + ')]), ]');
      g.push('  if (nrow(dup)) stop(' + str(S + ' repeats a QNAM for ') + ', nrow(dup), " record(s), first: ",');
      g.push('    dup$USUBJID[1], ' + (iv !== '' ? str(' ' + iv + ' ') + ', dup[[' + str(iv) + ']][1], ' : '') +
        '" ", dup$QNAM[1], call. = FALSE)');
      if (iv === '') return;
      // combine_supp() pivots every row of the level, the NA, unconvertible and overflowing
      // IDVARVALs the check above drops too, so a QNAM repeated among them would make a list
      // column: repeat-check all rows on the trimmed text, an NA counting as a value
      g.push('  x <- ' + ['q', 'dplyr::filter(IDVAR == ' + str(iv) + ')',
        'dplyr::transmute(STUDYID, USUBJID, ' + ident(iv) + ' = stringr::str_trim(as.character(IDVARVAL)), QNAM)'].join(gl));
      g.push('  dup <- x[duplicated(x[c("STUDYID", "USUBJID", ' + str(iv) + ', "QNAM")]), ]');
      g.push('  if (nrow(dup)) stop(' + str(S + ' repeats a QNAM for ') + ', nrow(dup), " record(s), first: ",');
      g.push('    dup$USUBJID[1], ' + str(' ' + iv + ' ') + ', dup[[' + str(iv) + ']][1], " ", dup$QNAM[1], call. = FALSE)');
    });
    // Later-cut guards. "Ours" (po/so) models the dplyr code's join: the rows its RDOMAIN filter
    // keeps (dk), on the merge keys plus, for a keyed level, the converted IDVARVAL (numeric, keys
    // as sprintf("%.17g") text so scipen plays no part) or the exact text. "Theirs" (pt/st) models
    // combine_supp(): STUDYID, DOMAIN == RDOMAIN, USUBJID and the trimmed key text. NA matches NA.
    var pkeys = s.keys.map(function (c) { return 'p[[' + str(c) + ']]'; });
    var xkeys = s.keys.map(function (c) { return 'x[[' + str(c) + ']]'; });
    g.push('  enc <- function(v) ifelse(is.na(v), "\\001", paste0("\\002", v))');
    g.push('  val <- function(v) {');
    g.push('    if (is.factor(v)) v <- as.character(v)');
    g.push('    if (!is.numeric(v) && !inherits(v, "integer64")) return(enc(as.character(v)))');
    g.push('    v <- suppressWarnings(as.numeric(v))');
    g.push('    v[!is.na(v) & v == 0] <- 0');
    g.push('    out <- sprintf("%.17g", v)');
    g.push('    out[is.na(v)] <- NA');
    g.push('    enc(out)');
    g.push('  }');
    g.push('  rec <- function(...) do.call(paste, c(lapply(list(...), val), sep = "\\r"))');
    g.push('  cnt <- function(a, b) {');
    g.push('    u <- unique(a)');
    g.push('    n <- tabulate(match(a, u), nbins = length(u))[match(b, u)]');
    g.push('    n[is.na(n)] <- 0L');
    g.push('    n');
    g.push('  }');
    // a DOMAIN or RDOMAIN that is NA never counts as a match in the DOMAIN guard
    g.push('  dom <- function(v, na) { v <- as.character(v); ifelse(is.na(v), na, paste0("\\002", v)) }');
    g.push('  shown <- function(v) if (is.na(v)) "NA" else paste0("\\"", v, "\\"")');
    g.push('  dk <- ' + (s.rdomain_col ? '!is.na(q$RDOMAIN) & as.character(q$RDOMAIN) == ' + str(s.rdomain) :
      'rep(TRUE, nrow(q))'));
    g.push('  pk <- rec(' + pkeys.join(', ') + ')');
    g.push('  pd <- rec(p$STUDYID, p$DOMAIN, p$USUBJID)');
    g.push('  pdom <- dom(p$DOMAIN, "\\003")');
    // Type guards. A join casts its keys to their common type (dplyr 1.1): combine_supp() joins
    // DOMAIN to RDOMAIN, the dplyr code each IDVAR key to the converted IDVARVAL (a number for a
    // numeric level, the IDVARVAL itself for a text one). Each column must keep its type there.
    // STUDYID and USUBJID are joined by both. A key that cannot join stops the dplyr code: stop here.
    // (a missing column is left to the code's own errors; a label attribute plays no part)
    g.push('  keeps <- function(a, b) {');
    g.push('    if (is.null(a)) return(TRUE)');
    g.push('    ty <- tryCatch(vctrs::vec_ptype_common(a, b), error = function(e) NULL)');
    g.push('    if (is.null(ty)) return(NA)');
    g.push('    identical(class(ty), class(a)) && identical(levels(ty), levels(a))');
    g.push('  }');
    g.push('  if (isFALSE(keeps(p$DOMAIN, ' + ref + '$RDOMAIN))) stop(' + str('DOMAIN in ' + P + ' would not keep its type (') +
      ', class(p$DOMAIN)[1],');
    g.push('    ") in combine_supp(); use the dplyr code style for this merge", call. = FALSE)');
    s.idvars.forEach(function (v) {
      var iv = v.idvar, k = 'p[[' + str(iv) + ']]';
      if (iv === '') return;
      var b = v.type === 'integer' ? 'integer()' : v.type === 'double' ? 'double()' : ref + '$IDVARVAL';
      g.push('  kt <- keeps(' + k + ', ' + b + ')');
      g.push('  if (is.na(kt)) stop(' + str(iv + ' in ' + P + ' (') + ', class(' + k + ')[1],');
      g.push('    ") would not join in the dplyr code; use the dplyr code style for this merge", call. = FALSE)');
      g.push('  if (!kt) stop(' + str(iv + ' in ' + P + ' would not keep its type (') + ', class(' + k + ')[1],');
      g.push('    ") in the dplyr code; use the dplyr code style for this merge", call. = FALSE)');
    });
    // one level's rows (x, kept by the dplyr code's filter or not) and its "ours" keys (po, so)
    var ours = function (v) {
      var iv = v.idvar, k = 'p[[' + str(iv) + ']]';
      var r = ['    x <- q[xi, , drop = FALSE]', '    kept <- dk[xi]'];
      if (iv === '') {
        r.push('    po <- pk');
        r.push('    so <- ifelse(kept, rec(' + xkeys.join(', ') + '), NA_character_)');
      } else if (v.type === 'integer' || v.type === 'double') {
        r.push('    cv <- ' + suppKeyConv(v.type, 'x$IDVARVAL'));
        if (v.type === 'double') r.push('    cv[!is.na(cv) & abs(cv) > 1e308] <- NA');
        r.push('    po <- paste(pk, val(' + k + '), sep = "\\r")');
        r.push('    so <- ifelse(kept & !is.na(cv), paste(rec(' + xkeys.join(', ') + '), val(cv), sep = "\\r"), NA_character_)');
      } else {
        r.push('    po <- paste(pk, val(' + k + '), sep = "\\r")');
        // an NA IDVARVAL joins nothing in the dplyr code (its filter(!is.na(<key>))), as an NA cv above
        r.push('    so <- ifelse(kept & !is.na(x$IDVARVAL), paste(rec(' + xkeys.join(', ') + '), val(x$IDVARVAL), sep = "\\r"), NA_character_)');
      }
      return r;
    };
    // the DOMAIN guard: every parent record the dplyr code joins a SUPP row to must have that
    // row's RDOMAIN as its DOMAIN, or combine_supp() would not join it
    // It also collects the QNAMs of the rows the dplyr code pivots (kq): the column guard below.
    var foreign = !(prep && prep.rdomain);
    g.push('  kq <- character()');
    s.idvars.forEach(function (v) {
      g.push('  xi <- which(q$IDVAR == ' + str(v.idvar) + ')');
      g.push('  if (length(xi)) {');
      ours(v).forEach(function (x) { g.push(x); });
      g.push('    kq <- c(kq, x$QNAM[!is.na(so)])');
      if (v.idvar === '' && foreign) {
        // with no RDOMAIN prep line combine_supp() sees the rows the dplyr code's filter drops;
        // the key guards cover a keyed one, this a subject-level one
        g.push('    j <- which(!kept & cnt(pd, rec(x$STUDYID, x$RDOMAIN, x$USUBJID)) > 0)[1]');
        g.push('    if (!is.na(j)) stop(' + str(S + ' has a row for USUBJID ') + ', as.character(x$USUBJID[j]),');
        g.push('      ' + str(' that would match ' + P + ' in combine_supp() but not in the dplyr code; ' +
          'use the dplyr code style for this merge') + ', call. = FALSE)');
      }
      g.push('    sdom <- dom(x$RDOMAIN, "\\004")');
      g.push('    i <- which(cnt(paste(po, pdom, sep = "\\n"), paste(so, sdom, sep = "\\n")) < cnt(po, so))[1]');
      g.push('    if (!is.na(i)) {');
      g.push('      j <- which(po == so[i] & pdom != sdom[i])[1]');
      g.push('      stop("DOMAIN ", shown(p$DOMAIN[j]), ' + str(' in ' + P + ' does not match RDOMAIN ') +
        ', shown(x$RDOMAIN[i]),');
      g.push('        " in combine_supp(); use the dplyr code style for this merge", call. = FALSE)');
      g.push('    }');
      g.push('  }');
    });
    // the key guards, one per keyed level: the records a SUPP row finds must be the same both ways
    s.idvars.forEach(function (v) {
      var iv = v.idvar, k = 'p[[' + str(iv) + ']]';
      if (iv === '') return;
      var tail = ' in combine_supp(); use the dplyr code style for this merge';
      var msg = function (how) {
        return 'stop("IDVARVAL \\"", as.character(x$IDVARVAL[i]), ' + str('" matches ' + iv + ' ') +
          ', as.character(k),\n        ' + str(' ' + how) + ', call. = FALSE)';
      };
      g.push('  xi <- which(q$IDVAR == ' + str(iv) + ')');
      g.push('  if (length(xi)) {');
      ours(v).forEach(function (x) { g.push(x); });
      g.push('    pt <- paste(pd, enc(stringr::str_trim(as.character(' + k + '))), sep = "\\r")');
      g.push('    st <- paste(rec(x$STUDYID, x$RDOMAIN, x$USUBJID), enc(stringr::str_trim(as.character(x$IDVARVAL))), sep = "\\r")');
      g.push('    no <- cnt(po, so)');
      g.push('    nt <- cnt(pt, st)');
      if (v.type === 'integer' || v.type === 'double') {
        g.push('    nb <- cnt(paste(po, pt, sep = "\\n"), paste(so, st, sep = "\\n"))');
        g.push('    nb[is.na(so)] <- 0L');
        g.push('    i <- which(nb < no | nb < nt)[1]');
        g.push('    if (!is.na(i) && nb[i] < no[i]) {');
        g.push('      k <- ' + k + '[which(po == so[i] & pt != st[i])[1]]');
        g.push('      ' + msg('as a number but not as text' + tail));
        g.push('    }');
        g.push('    if (!is.na(i)) {');
        g.push('      k <- ' + k + '[which(pt == st[i] & !(po %in% so[i]))[1]]');
        g.push('      ' + msg('as text but not as a number' + tail));
        g.push('    }');
      } else {
        // after the DOMAIN guard the exact-text matches are a subset of the trimmed ones
        g.push('    i <- which(no < nt)[1]');
        g.push('    if (!is.na(i)) {');
        g.push('      k <- ' + k + '[which(pt == st[i] & !(po %in% so[i]))[1]]');
        g.push('      ' + msg('only when trimmed, as in combine_supp(); use the dplyr code style for this merge'));
        g.push('    }');
      }
      g.push('  }');
    });
    // The column guard: combine_supp() makes a column of every QNAM it is given, the dplyr code of
    // the QNAMs of the rows it pivots (kq: kept by its RDOMAIN filter, with a key that converts)
    g.push('  nq <- setdiff(unique(q$QNAM), kq)');
    g.push('  if (length(nq)) stop(' + str(S + ' QNAM ') + ', nq[1],');
    g.push('    ' + str(' would be a column in combine_supp() but not in the dplyr code' + tl) + ', call. = FALSE)');
    // The label guards: combine_supp() labels each QNAM with its last QLABEL in
    // unique(supp[c("QNAM", "QLABEL")]), as it is (a factor too, and a factor QNAM picks the column
    // by its code); the dplyr code with the plan's label. NA and "" are no label.
    g.push('  if (is.factor(' + ref + '$QNAM)) stop(' +
      str(S + ' QNAM is a factor, so combine_supp() would label the wrong columns' + tl) + ', call. = FALSE)');
    g.push('  if (is.factor(' + ref + '$QLABEL)) stop(' +
      str(S + ' QLABEL is a factor, so combine_supp() would set factor labels' + tl) + ', call. = FALSE)');
    var labs = suppLabels(s);
    g.push('  ours <- ' + (labs.length ? 'c(' + labs.map(function (x) {
      return ident(x.qnam) + ' = ' + str(x.label);
    }).join(', ') + ')' : 'character()'));
    g.push('  said <- function(v) if (nzchar(v)) paste0("\\"", v, "\\"") else "none"');
    // (a SUPP with no QLABEL is left to combine_supp()'s own column check)
    g.push('  lab <- if ("QLABEL" %in% names(' + ref + ')) unique(' + ref + '[c("QNAM", "QLABEL")]) else list(QNAM = NULL)');
    g.push('  for (n in unique(lab$QNAM[!is.na(lab$QNAM)])) {');
    g.push('    a <- if (n %in% names(ours)) ours[[n]] else ""');
    g.push('    b <- as.character(utils::tail(lab$QLABEL[lab$QNAM %in% n], 1))');
    g.push('    if (is.na(b)) b <- ""');
    g.push('    if (!identical(a, b)) stop(n, " label would be ", said(b), " in combine_supp(), not ", said(a),');
    g.push('      ' + str(tl) + ', call. = FALSE)');
    g.push('  }');
    g.push('})');
    out.push(g.join('\n'));
    return { code: out.join('\n'), ref: ref };
  }

  // ---- plain-sentence helpers (twins of R/say.R) ----
  function sayPct(num, den) {
    if (!den) return null;
    var tenths = Math.floor((2000 * num + den) / (2 * den));
    return Math.floor(tenths / 10) + '.' + (tenths % 10) + ' percent';
  }

  function sayList(x) {
    var a = (x || []).map(String), n = a.length;
    if (n === 0) return '';
    if (n === 1) return a[0];
    if (n === 2) return a[0] + ' and ' + a[1];
    return a.slice(0, n - 1).join(', ') + ', and ' + a[n - 1];
  }

  function sayValue(v) {
    if (v === null || v === undefined || (typeof v === 'number' && isNaN(v))) return 'missing';
    if (typeof v === 'boolean') return v ? 'TRUE' : 'FALSE';
    if (typeof v === 'number') {
      if (!isFinite(v)) return v > 0 ? 'Inf' : '-Inf';
      return numKey(v);
    }
    var s = String(v);
    if (s.indexOf(', ') >= 0) s = '(' + s + ')';
    return s;
  }

  function saySamples(x, total, max) {
    var m = max === undefined || max === null ? 3 : max;
    var shown = (x || []).slice(0, m).map(sayValue);
    if (total !== undefined && total !== null && total > shown.length) {
      return shown.join(', ') + ', and ' + fmtN(total - shown.length) + ' more';
    }
    return sayList(shown);
  }

  function sayNum(v) {
    if (typeof v === 'boolean') return v ? 'TRUE' : 'FALSE';
    if (typeof v !== 'number') return v === null || v === undefined ? 'NA' : String(v);
    if (isNaN(v)) return 'NaN';
    if (!isFinite(v)) return v > 0 ? 'Inf' : '-Inf';
    if (v === Math.round(v)) return fmtN(v);
    return numKey(signif6(v));
  }

  function sayCheckLines(x) { return (x || []).map(String); }

  // A sentence ends in ".", "!" or "?"; add a "." when it does not (twin of sv_say_sentence).
  function saySentence(s) { s = String(s); return /[.!?]$/.test(s) ? s : s + '.'; }

  // "1 row of NAME" or "N rows of NAME" (twin of sv_say_rows).
  function sayRows(n, nm) { return sayNum(n) + (n === 1 ? ' row of ' : ' rows of ') + nm; }

  // A join check as plain sentences (twin of sv_say_join in R/say.R).
  function sayJoin(d, xName, yName) {
    var X = xName === undefined || xName === null ? 'x' : xName;
    var Y = yName === undefined || yName === null ? 'y' : yName;
    if (d.error !== undefined && d.error !== null) return ['Join check failed: ' + saySentence(d.error)];
    var key = sayList(d.by.map(function (p) { return p.left === p.right ? p.left : p.left + ' = ' + p.right; }));
    var out = ['Join of ' + X + ' and ' + Y + ' by ' + key + ' is ' + d.relationship.split('-').join(' ') + '.'];
    if (d.rule) {
      out.push('Date rule: ' + ruleLabel(d.rule, d.rule_kind) + '.');
      if (d.rule_dropped_x + d.rule_dropped_y > 0) {
        out.push('The rule drops ' + sayNum(d.rule_dropped_x) + ' ' + X + ' rows and ' +
          sayNum(d.rule_dropped_y) + ' ' + Y + ' rows.');
      }
    }
    var matchLine = function (m, n, nm) {
      var pct = sayPct(m, n);
      return sayNum(m) + ' of ' + sayNum(n) + ' ' + nm + ' rows match' + (pct === null ? '' : ', ' + pct) + '.';
    };
    out.push(matchLine(d.matched_x, d.n_x, X), matchLine(d.matched_y, d.n_y, Y));
    var missLine = function (n, matched, dup, samples, nm) {
      var k = n - matched;
      if (k <= 0) return;
      var eg = !samples.length ? '' : dup === 0 ? ', for example ' + saySamples(samples, k) :
        ', for example keys ' + saySamples(samples);
      out.push(sayRows(k, nm) + (k === 1 ? ' has' : ' have') + ' no match' + eg + '.');
    };
    missLine(d.n_x, d.matched_x, d.dup_keys_x, d.unmatched_x, X);
    missLine(d.n_y, d.matched_y, d.dup_keys_y, d.unmatched_y, Y);
    if (d.na_x > 0) out.push(sayRows(d.na_x, X) + (d.na_x === 1 ? ' has' : ' have') + ' a missing key.');
    if (d.na_y > 0) out.push(sayRows(d.na_y, Y) + (d.na_y === 1 ? ' has' : ' have') + ' a missing key.');
    var types = [['left', 'left_join'], ['inner', 'inner_join'], ['right', 'right_join'],
                 ['full', 'full_join'], ['semi', 'semi_join'], ['anti', 'anti_join']];
    var parts = [];
    types.forEach(function (t) {
      var v = d.rows[t[1]];
      if (v !== undefined && v !== null) parts.push(t[0] + ' ' + sayNum(v));
    });
    out.push('Rows by join type: ' + parts.join(', ') + '.');
    (d.hints || []).forEach(function (h) {
      var gain = [];
      if (h.extra_x > 0) gain.push(sayNum(h.extra_x) + ' more ' + X + ' rows');
      if (h.extra_y > 0) gain.push(sayNum(h.extra_y) + ' more ' + Y + ' rows');
      out.push(h.label.charAt(0).toUpperCase() + h.label.slice(1) + ' would match ' + gain.join(' and ') + '.');
    });
    (d.type_issues || []).concat(d.warnings || []).forEach(function (s) { out.push(saySentence(s)); });
    return out;
  }

  // "1 row has" / "N rows have" for a count of NAME's rows (twin of sv_say_n_rows).
  function sayNRows(n, nm, one, many) { return sayNum(n) + ' ' + nm + (n === 1 ? ' row ' + one : ' rows ' + many); }

  // One "USUBJID IDVAR IDVARVAL" per sample row; an empty or missing part is left out.
  function saySuppSamples(s) {
    return (s || []).map(function (r) {
      return [r.USUBJID, r.IDVAR, r.IDVARVAL].filter(function (v) {
        return v !== null && v !== undefined && String(v) !== '';
      }).map(String).join(' ');
    });
  }

  // A SUPP merge check as plain sentences (twin of sv_say_supp in R/say.R).
  function saySupp(chk, parentName, suppName) {
    var P = parentName === undefined || parentName === null ? 'parent' : parentName;
    var S = suppName === undefined || suppName === null ? 'supp' : suppName;
    if (chk.error !== undefined && chk.error !== null) return ['SUPP check failed: ' + saySentence(chk.error)];
    var cols = (chk.columns || []).map(function (c) { return String(c.name); });
    var nc = cols.length;
    var out = ['Merging ' + S + ' into ' + P + ' adds ' + sayNum(nc) + (nc === 1 ? ' column' : ' columns') +
      (nc > 0 ? ': ' + sayList(cols) : '') + '.'];
    out.push(sayNum(chk.n_matched) + ' of ' + sayNum(chk.n_supp) + ' ' + S + ' rows match a ' + P + ' row.');
    var withEg = function (n, samples) {
      var eg = saySuppSamples(samples);
      return eg.length ? ', for example ' + saySamples(eg, n) : '';
    };
    if (chk.n_orphan > 0) {
      out.push(sayNRows(chk.n_orphan, S, 'has no ' + P + ' row', 'have no ' + P + ' row') +
        withEg(chk.n_orphan, chk.orphan_samples) + '.');
    }
    if (chk.bad_idvarval.n > 0) {
      out.push(sayNRows(chk.bad_idvarval.n, S, 'has an IDVARVAL that does not convert',
        'have an IDVARVAL that does not convert') + withEg(chk.bad_idvarval.n, chk.bad_idvarval.samples) + '.');
    }
    if (chk.n_other_rdomain > 0) {
      out.push(sayNRows(chk.n_other_rdomain, S, 'is for another domain and is left out',
        'are for another domain and are left out') + '.');
    }
    if (chk.repeats.n > 0) {
      out.push(sayNRows(chk.repeats.n, S, 'repeats a QNAM for the same ' + P + ' row',
        'repeat a QNAM for the same ' + P + ' row') + '.');
    }
    if ((chk.clashes || []).length) out.push('These QNAMs clash with ' + P + ' columns: ' + sayList(chk.clashes) + '.');
    if ((chk.two_level || []).length) out.push('These QNAMs use more than one IDVAR: ' + sayList(chk.two_level) + '.');
    if (chk.drift && chk.drift.stale === true) out.push('Merge needs refreshing: ' + sayList(chk.drift.reasons) + '.');
    return out;
  }

  // A column profile as plain sentences (twin of sv_say_profile in R/say.R).
  function sayProfile(p, name) {
    var N = name === undefined || name === null ? 'Column' : name;
    var nl = p.label !== null && p.label !== undefined && p.label !== '' ? N + ', ' + p.label : N;
    var words = { numeric: 'number', character: 'text', logical: 'true or false', date: 'date', datetime: 'date-time' };
    var word = words[p.kind] || p['class'] || 'other';
    var out = [nl + ' is a ' + word + ' column.'];
    out.push(p.n_missing === 0 ? 'No values are missing.' :
      sayNum(p.n_missing) + ' of ' + sayNum(p.n) + ' values are missing, ' + sayPct(p.n_missing, p.n) + '.');
    out.push('It has ' + sayNum(p.n_distinct) + (p.n_distinct === 1 ? ' distinct value.' : ' distinct values.'));
    if (p.unique_key === true) out.push('Every value is unique, so it can be a key.');
    var st = p.stats;
    if (p.kind === 'numeric' && st) {
      out.push('Minimum ' + sayNum(st.min) + ', median ' + sayNum(st.median) + ', maximum ' + sayNum(st.max) + '.');
      out.push('Mean ' + sayNum(st.mean) + ', standard deviation ' + sayNum(st.sd) + '.');
    } else if ((p.kind === 'date' || p.kind === 'datetime') && st) {
      out.push('Earliest ' + st.min + ', latest ' + st.max + '.');
    }
    var top = p.top || [];
    if (p.kind !== 'numeric' && top.length > 0) {
      var shown = top.slice(0, 5);
      out.push('Most common values: ' + shown.map(function (t) { return sayValue(t.value) + ' (' + sayNum(t.n) + ')'; })
        .join(', ') + '.');
      var left = p.n_other + (top.length - shown.length);
      if (left > 0) out.push(sayNum(left) + (left === 1 ? ' other value is' : ' other values are') + ' not listed.');
    }
    (p.issues || []).forEach(function (s) { out.push(saySentence(s)); });
    return out;
  }

  var api = {
    Pipeline: Pipeline,
    sayPct: sayPct,
    sayList: sayList,
    saySamples: saySamples,
    sayValue: sayValue,
    sayNum: sayNum,
    sayCheckLines: sayCheckLines,
    sayJoin: sayJoin,
    saySupp: saySupp,
    sayProfile: sayProfile,
    suppStep: suppStep,
    deriveStep: deriveStep,
    splitReply: splitReply,
    joinDiagnostics: joinDiagnostics,
    strictArgs: strictArgs,
    ruleValue: ruleValue,
    describeDiagnostics: describeDiagnostics,
    fmtN: fmtN,
    columnProfile: columnProfile,
    suppKeyType: suppKeyType,
    suppCheck: suppCheck,
    combineSuppStopReason: combineSuppStopReason,
    rAsCharacter: rAsCharacter,
    rAsCharacterSure: rAsCharacterSure,
    suppNumSure: suppNumSure,
    strTrim: strTrim,
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
