/**
 * sideview.js - Core frontend engine for Sideview 2D Infinite Canvas
 * Manages panzoom, draggable table cards, snap-to-edge docking, synchronized scrolling,
 * cell highlighting, SVG bezier field connections, inline renaming, and Shiny messaging.
 */

(function (global) {
  'use strict';

  // Helper to safely dispatch Shiny input values
    // Helper to escape non-syntactic R column identifiers
  function escapeColIdentifier(name) {
    if (!name) return '';
    return /^[a-zA-Z.][a-zA-Z0-9._]*$/.test(name) ? name : '`' + name.replace(/`/g, '\\`') + '`';
  }

function sendToShiny(name, value) {
    if (typeof global.Shiny !== 'undefined' && typeof global.Shiny.setInputValue === 'function') {
      global.Shiny.setInputValue(name, value, { priority: 'event' });
      return true;
    } else {
      // Standalone mode / browser console fallback
      if (typeof console !== 'undefined' && console.debug) {
        console.debug('[Sideview Event]', name, value);
      }
      return false;
    }
  }

  // Module-level cached Intl.Collator for high-performance 100k+ row string sorting
  var _sideviewCollator = (typeof Intl !== 'undefined' && Intl.Collator)
    ? new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' })
    : null;

  /**
   * VirtualTable - High-performance virtualized table renderer for 100k+ rows
   * Maintains accurate scrollbars via top/bottom spacers while rendering only visible rows + buffer.
   */
  function VirtualTable(tableOrContainer, options) {
    var self = this;
    options = options || {};

    if (typeof tableOrContainer === 'string') {
      tableOrContainer = document.querySelector(tableOrContainer);
    }
    if (!tableOrContainer) {
      throw new Error('VirtualTable target element not found');
    }

    if (tableOrContainer.tagName === 'TABLE') {
      this.table = tableOrContainer;
      this.scrollContainer = tableOrContainer.closest('.sideview-card-body') ||
                             tableOrContainer.closest('.sideview-table-viewport') ||
                             tableOrContainer.parentElement;
    } else {
      this.scrollContainer = tableOrContainer;
      this.table = tableOrContainer.querySelector('table') || tableOrContainer;
    }

    if (this.scrollContainer && !this.scrollContainer.classList.contains('sideview-table-viewport')) {
      this.scrollContainer.classList.add('sideview-table-viewport');
    }
    if (this.table && !this.table.classList.contains('sideview-table-virtual')) {
      this.table.classList.add('sideview-table-virtual');
    }

    this.options = Object.assign({
      rowHeight: 28,
      buffer: 10,
      colNames: null,
      colTypes: {},
      data: null
    }, options);

    this.rowHeight = this.options.rowHeight || 28;
    this.buffer = this.options.buffer !== undefined ? this.options.buffer : 10;
    this.colNames = this.options.colNames ? this.options.colNames.slice() : [];
    this.colTypes = this.options.colTypes || {};
    this.data = this.options.data || null;

    this.totalRows = 0;
    this.highlightedColumns = new Map();
    this.highlightedCells = new Map();
    this.filteredIndices = null;
    this.sortState = { colName: null, colIndex: -1, direction: 'none' };
    this.activeSortIndices = null;
    this.currentFilter = null;
    this._ticking = false;

    this.initDOM();
    this.initData();
    this.attachScrollListener();
    this.render();

    this.table._virtualTable = this;
    if (this.scrollContainer) {
      this.scrollContainer._virtualTable = this;
    }
  }

  VirtualTable.prototype.initDOM = function () {
    this.tbody = this.table.querySelector('tbody');
    if (!this.tbody) {
      this.tbody = document.createElement('tbody');
      this.table.appendChild(this.tbody);
    }

    this.topSpacer = document.createElement('tr');
    this.topSpacer.className = 'sideview-virtual-spacer sideview-virtual-spacer-top';
    this.topCell = document.createElement('td');
    this.topSpacer.appendChild(this.topCell);

    this.bottomSpacer = document.createElement('tr');
    this.bottomSpacer.className = 'sideview-virtual-spacer sideview-virtual-spacer-bottom';
    this.bottomCell = document.createElement('td');
    this.bottomSpacer.appendChild(this.bottomCell);
  };

  VirtualTable.prototype.initData = function () {
    var self = this;
    if (this.data) {
      if (!Array.isArray(this.data) && typeof this.data === 'object') {
        if (!this.colNames.length) {
          this.colNames = Object.keys(this.data);
        }
        if (this.colNames.length > 0 && Array.isArray(this.data[this.colNames[0]])) {
          this.totalRows = this.data[this.colNames[0]].length;
        } else {
          this.totalRows = 0;
        }
      } else if (Array.isArray(this.data)) {
        this.totalRows = this.data.length;
        if (!this.colNames.length && this.totalRows > 0) {
          var firstRow = this.data[0];
          if (!Array.isArray(firstRow) && typeof firstRow === 'object') {
            this.colNames = Object.keys(firstRow);
          }
        }
      }
      this.tbody.innerHTML = '';
      this.tbody.appendChild(this.topSpacer);
      this.tbody.appendChild(this.bottomSpacer);
    } else {
      var existingRows = Array.from(this.tbody.querySelectorAll('tr:not(.sideview-virtual-spacer)'));
      if (existingRows.length > 0) {
        if (!this.colNames.length) {
          var ths = this.table.querySelectorAll('thead th');
          ths.forEach(function (th) {
            self.colNames.push(th.dataset.colName || th.textContent.trim());
          });
        }
        var extracted = {};
        this.colNames.forEach(function (cn) { extracted[cn] = []; });
        existingRows.forEach(function (tr) {
          self.colNames.forEach(function (cn, colIdx) {
            var cell = tr.cells[colIdx];
            extracted[cn].push(cell ? cell.textContent.trim() : '');
          });
        });
        this.data = extracted;
        this.totalRows = existingRows.length;

        this.tbody.innerHTML = '';
        this.tbody.appendChild(this.topSpacer);
        this.tbody.appendChild(this.bottomSpacer);
      } else {
        this.tbody.appendChild(this.topSpacer);
        this.tbody.appendChild(this.bottomSpacer);
      }
    }

    var numCols = this.colNames.length || this.table.querySelectorAll('thead th').length || 1;
    this.topCell.colSpan = numCols;
    this.bottomCell.colSpan = numCols;

    // Column types rendered by the server (data-col-type) keep numbers right-aligned
    // without re-parsing cell text.
    var typeHeaders = this.table.querySelectorAll('thead th');
    for (var t = 0; t < typeHeaders.length; t++) {
      var thType = typeHeaders[t].dataset ? typeHeaders[t].dataset.colType : null;
      var thName = this.colNames[t];
      if (thType && thName && !this.colTypes[thName]) this.colTypes[thName] = thType;
    }
    // Names as the R session knows them; UI renames don't change the source data.
    this.sourceColNames = this.colNames.slice();
  };

  VirtualTable.prototype.sourceColName = function (colName) {
    var pos = this.colNames.indexOf(colName);
    return pos >= 0 && this.sourceColNames[pos] !== undefined ? this.sourceColNames[pos] : colName;
  };

  VirtualTable.prototype.attachScrollListener = function () {
    var self = this;
    if (!this.scrollContainer) return;
    this._scrollHandler = function () {
      if (self._ticking) return;
      self._ticking = true;
      requestAnimationFrame(function () {
        self._ticking = false;
        self.render();
      });
    };
    this.scrollContainer.addEventListener('scroll', this._scrollHandler, { passive: true });
  };

  VirtualTable.prototype.getActiveIndices = function () {
    if (this.filteredIndices !== null) {
      return this.filteredIndices;
    }
    if (this.activeSortIndices !== null) {
      return this.activeSortIndices;
    }
    return null;
  };

  VirtualTable.prototype.getRowCount = function () {
    if (this.remote && this.remote.active) return this.remote.count;
    var active = this.getActiveIndices();
    return active !== null ? active.length : this.totalRows;
  };

  VirtualTable.prototype.getCellValue = function (rowIndex, colName, colIndex) {
    if (!this.data) return '';
    if (this.data[colName] !== undefined) {
      return this.data[colName][rowIndex];
    }
    if (Array.isArray(this.data) && this.data[rowIndex] !== undefined) {
      var row = this.data[rowIndex];
      if (Array.isArray(row)) return row[colIndex];
      if (row && typeof row === 'object') return row[colName];
    }
    return '';
  };

  VirtualTable.prototype.render = function () {
    var totalCount = this.getRowCount();
    var totalVirtualHeight = totalCount * this.rowHeight;
    var scrollTop = this.scrollContainer ? this.scrollContainer.scrollTop : 0;
    var viewportHeight = this.scrollContainer ? (this.scrollContainer.clientHeight || 380) : 380;

    var visibleStart = Math.floor(scrollTop / this.rowHeight);
    var visibleCount = Math.ceil(viewportHeight / this.rowHeight);

    var startIndex = Math.max(0, visibleStart - this.buffer);
    var endIndex = Math.min(totalCount, visibleStart + visibleCount + this.buffer);

    var topHeight = startIndex * this.rowHeight;
    var bottomHeight = Math.max(0, (totalCount - endIndex) * this.rowHeight);

    this.topSpacer.style.height = topHeight + 'px';
    this.topCell.style.height = topHeight + 'px';
    this.topSpacer.style.display = topHeight > 0 ? '' : 'none';

    this.bottomSpacer.style.height = bottomHeight + 'px';
    this.bottomCell.style.height = bottomHeight + 'px';
    this.bottomSpacer.style.display = bottomHeight > 0 ? '' : 'none';

    var numCols = this.colNames.length || this.table.querySelectorAll('thead th').length || 1;
    this.topCell.colSpan = numCols;
    this.bottomCell.colSpan = numCols;

    var active = this.getActiveIndices();
    var remoteOn = !!(this.remote && this.remote.active);
    var frag = document.createDocumentFragment();

    for (var i = startIndex; i < endIndex; i++) {
      var remoteRow = remoteOn ? this.remoteRowAt(i) : null;
      var rawRowIndex = remoteOn ? (remoteRow ? remoteRow.id : -1) : (active !== null ? active[i] : i);
      var tr = document.createElement('tr');
      tr.dataset.rowIndex = rawRowIndex;
      tr.dataset.virtualIndex = i;
      if (remoteOn && !remoteRow) tr.className = 'sideview-row-loading';

      for (var c = 0; c < numCols; c++) {
        var colName = this.colNames[c];
        var td = document.createElement('td');
        var val = remoteOn
          ? (remoteRow ? remoteRow.get(c) : '…')
          : this.getCellValue(rawRowIndex, colName, c);
        td.textContent = (val === null || val === undefined) ? 'NA' : val;

        var knownType = this.colTypes ? this.colTypes[colName] : null;
        var isNum = (knownType === 'numeric' || knownType === 'integer' || knownType === 'double') ||
                    (typeof val === 'number') ||
                    (!knownType && !isNaN(parseFloat(val)) && isFinite(val) && val !== '' && val !== 'NA');
        if (isNum) {
          td.classList.add('is-number');
        }

        // Apply column highlight
        if (this.highlightedColumns.has(colName)) {
          var hColColor = this.highlightedColumns.get(colName);
          if (hColColor && hColColor !== 'clear') {
            td.classList.add('sv-highlight-' + hColColor, 'sideview-cell-highlight');
          }
        }

        // Apply cell highlight
        var cellKey = rawRowIndex + '_' + c;
        if (this.highlightedCells.has(cellKey)) {
          var hCellColor = this.highlightedCells.get(cellKey);
          if (hCellColor && hCellColor !== 'clear') {
            td.classList.add('sv-highlight-' + hCellColor, 'sideview-cell-highlight');
          }
        }

        tr.appendChild(td);
      }
      frag.appendChild(tr);
    }

    while (this.topSpacer.nextSibling && this.topSpacer.nextSibling !== this.bottomSpacer) {
      this.tbody.removeChild(this.topSpacer.nextSibling);
    }
    this.tbody.insertBefore(frag, this.bottomSpacer);
  };

  VirtualTable.prototype.sort = function (colIndex, colName, direction) {
    this.sortState = { colIndex: colIndex, colName: colName, direction: direction };
    if (!colName && this.colNames[colIndex]) {
      colName = this.colNames[colIndex];
    }
    // A new ordering starts from the first row, as filtering does.
    if (this.scrollContainer) this.scrollContainer.scrollTop = 0;
    if (this.remote) {
      this.remote.spec.sort = direction === 'none' ? null : { col: this.sourceColName(colName), dir: direction };
      this.resetRemote();
      return;
    }

    if (direction === 'none') {
      this.activeSortIndices = null;
      if (this.currentFilter) {
        this.reapplyFilter();
      }
    } else {
      var indices = [];
      for (var i = 0; i < this.totalRows; i++) indices.push(i);

      var self = this;
      indices.sort(function (a, b) {
        var valA = self.getCellValue(a, colName, colIndex);
        var valB = self.getCellValue(b, colName, colIndex);

        var numA = parseFloat(valA);
        var numB = parseFloat(valB);
        var isNum = !isNaN(numA) && !isNaN(numB) && valA !== '' && valB !== '' && valA !== 'NA' && valB !== 'NA';

        var cmp = 0;
        if (isNum) {
          cmp = numA - numB;
        } else {
          var strA = String(valA || '');
          var strB = String(valB || '');
          cmp = _sideviewCollator
            ? _sideviewCollator.compare(strA, strB)
            : strA.localeCompare(strB, undefined, { numeric: true, sensitivity: 'base' });
        }
        return direction === 'asc' ? cmp : -cmp;
      });

      this.activeSortIndices = indices;
      if (this.currentFilter) {
        this.reapplyFilter();
      }
    }

    this.render();
  };

  VirtualTable.prototype.filter = function (colIndex, colName, operator, value) {
    if (!colName && this.colNames[colIndex]) {
      colName = this.colNames[colIndex];
    }
    this.currentFilter = { colIndex: colIndex, colName: colName, operator: operator, value: value };
    if (this.remote) {
      this.remote.spec.filter = { col: this.sourceColName(colName), op: operator, val: String(value) };
      if (this.scrollContainer) this.scrollContainer.scrollTop = 0;
      this.resetRemote();
      return null; // the matching row count arrives asynchronously (onRemoteCount)
    }
    this.reapplyFilter();
    if (this.scrollContainer) this.scrollContainer.scrollTop = 0;
    this.render();
    return this.filteredIndices ? this.filteredIndices.length : 0;
  };

  VirtualTable.prototype.clearFilter = function () {
    this.currentFilter = null;
    this.filteredIndices = null;
    if (this.remote) {
      this.remote.spec.filter = null;
      this.resetRemote();
      return;
    }
    this.render();
  };

  VirtualTable.prototype.reapplyFilter = function () {
    if (!this.currentFilter) {
      this.filteredIndices = null;
      return;
    }
    var self = this;
    var colName = this.currentFilter.colName;
    var colIndex = this.currentFilter.colIndex;
    var op = this.currentFilter.operator;
    var val = this.currentFilter.value;
    // Same semantics as the generated dplyr::filter() code: case-sensitive,
    // fixed-string `contains`, and missing values never match.
    var strVal = String(val === null || val === undefined ? '' : val);
    var numVal = parseFloat(val);
    var isNumFilter = !isNaN(numVal);

    var baseIndices = this.activeSortIndices !== null
      ? this.activeSortIndices
      : Array.from({ length: this.totalRows }, function (_, i) { return i; });

    this.filteredIndices = baseIndices.filter(function (idx) {
      var raw = self.getCellValue(idx, colName, colIndex);
      if (raw === null || raw === undefined) return false;
      var text = String(raw).trim();
      var numCell = parseFloat(text);

      if (op === 'contains') {
        return text.indexOf(strVal) !== -1;
      } else if (op === 'equals') {
        return isNumFilter && !isNaN(numCell) ? numCell === numVal : text === strVal;
      } else if (op === 'not_equals') {
        return isNumFilter && !isNaN(numCell) ? numCell !== numVal : text !== strVal;
      } else if (op === 'gt') {
        return !isNaN(numCell) && numCell > numVal;
      } else if (op === 'gte') {
        return !isNaN(numCell) && numCell >= numVal;
      } else if (op === 'lt') {
        return !isNaN(numCell) && numCell < numVal;
      } else if (op === 'lte') {
        return !isNaN(numCell) && numCell <= numVal;
      }
      return true;
    });
  };

  VirtualTable.prototype.setColumnHighlight = function (colName, color) {
    if (!color || color === 'clear') {
      this.highlightedColumns.delete(colName);
    } else {
      this.highlightedColumns.set(colName, color);
    }
    this.render();
  };

  VirtualTable.prototype.setCellHighlight = function (rowIndex, colIndex, color) {
    var key = rowIndex + '_' + colIndex;
    if (!color || color === 'clear') {
      this.highlightedCells.delete(key);
    } else {
      this.highlightedCells.set(key, color);
    }
    this.render();
  };

  VirtualTable.prototype.clearHighlights = function () {
    this.highlightedColumns.clear();
    this.highlightedCells.clear();
    this.render();
  };

  VirtualTable.prototype.renameColumn = function (oldName, newName, colIndex) {
    if (colIndex !== undefined && colIndex !== null && colIndex >= 0 && colIndex < this.colNames.length) {
      this.colNames[colIndex] = newName;
    } else {
      var idx = this.colNames.indexOf(oldName);
      if (idx !== -1) {
        this.colNames[idx] = newName;
      }
    }
    if (this.data && typeof this.data === 'object' && !Array.isArray(this.data)) {
      if (this.data.hasOwnProperty(oldName) || this.data[oldName] !== undefined) {
        this.data[newName] = this.data[oldName];
        delete this.data[oldName];
      }
    }
    if (this.sortState && this.sortState.colName === oldName) {
      this.sortState.colName = newName;
    }
    if (this.currentFilter && this.currentFilter.colName === oldName) {
      this.currentFilter.colName = newName;
    }
    if (this.highlightedColumns && this.highlightedColumns.has(oldName)) {
      var color = this.highlightedColumns.get(oldName);
      this.highlightedColumns.delete(oldName);
      this.highlightedColumns.set(newName, color);
    }
  };

  // ---- remote paging -------------------------------------------------------
  // Cards larger than the HTML preview fetch row windows from the R session
  // (input `sideview_rows_request` -> message `sideview_rows`), so scrolling,
  // sorting and filtering always reflect the full data.

  VirtualTable.prototype.enableRemote = function (cardId, totalRows, requestFn) {
    this.remote = {
      cardId: cardId,
      total: totalRows,
      count: totalRows,
      blockSize: 200,
      blocks: {},
      pending: {},
      version: 0,
      spec: { sort: null, filter: null },
      request: requestFn,
      active: totalRows > this.totalRows
    };
    if (this.remote.active) this.seedRemoteFromLocal();
    this.render();
  };

  // Rows already in the preview are the first rows in natural order.
  VirtualTable.prototype.seedRemoteFromLocal = function () {
    var r = this.remote;
    var full = Math.floor(this.totalRows / r.blockSize);
    for (var b = 0; b < full; b++) {
      var ids = [];
      for (var k = 0; k < r.blockSize; k++) ids.push(b * r.blockSize + k);
      r.blocks[b] = { ids: ids, local: true };
    }
  };

  VirtualTable.prototype.resetRemote = function () {
    var r = this.remote;
    r.version += 1;
    r.blocks = {};
    r.pending = {};
    this.activeSortIndices = null;
    this.filteredIndices = null;
    var specEmpty = !r.spec.sort && !r.spec.filter;
    r.active = !specEmpty || r.total > this.totalRows;
    if (specEmpty) {
      r.count = r.total;
      this.seedRemoteFromLocal();
    } else {
      this.requestBlock(0);
    }
    this.render();
  };

  VirtualTable.prototype.requestBlock = function (b) {
    var r = this.remote;
    if (!r || r.pending[b] || r.blocks[b] || typeof r.request !== 'function') return;
    r.pending[b] = true;
    var self = this;
    var version = r.version;
    var sent = r.request({
      card_id: r.cardId,
      version: r.version,
      offset: b * r.blockSize,
      limit: r.blockSize,
      sort: r.spec.sort,
      filter: r.spec.filter
    });
    if (sent === false) {
      // Shiny not connected yet (requests during page load): retry shortly.
      delete r.pending[b];
      if (!r.retryTimer) {
        r.retryTimer = setTimeout(function () {
          r.retryTimer = null;
          if (r.version === version) self.render();
        }, 250);
      }
    }
  };

  VirtualTable.prototype.remoteRowAt = function (i) {
    var r = this.remote;
    var b = Math.floor(i / r.blockSize);
    var block = r.blocks[b];
    if (!block) { this.requestBlock(b); return null; }
    var k = i - b * r.blockSize;
    if (k >= block.ids.length) return null;
    var self = this;
    var id = block.ids[k];
    if (block.local) {
      return { id: id, get: function (c) { return self.getCellValue(id, self.colNames[c], c); } };
    }
    return {
      id: id,
      get: function (c) {
        // Columns are keyed by source name; a UI rename keeps the position.
        var col = block.columns[self.sourceColNames[c]] || block.columns[block.names[c]];
        return col ? col[k] : '';
      }
    };
  };

  VirtualTable.prototype.receiveRows = function (msg) {
    var r = this.remote;
    if (!r || msg.version !== r.version) return;
    var b = Math.floor((msg.offset || 0) / r.blockSize);
    delete r.pending[b];
    var ids = msg.row_ids;
    if (ids === null || ids === undefined) ids = [];
    if (!Array.isArray(ids)) ids = [ids];
    var columns = {};
    var names = Object.keys(msg.columns || {});
    names.forEach(function (n) {
      var v = msg.columns[n];
      columns[n] = Array.isArray(v) ? v : [v];
    });
    r.blocks[b] = { ids: ids, columns: columns, names: names };
    var countChanged = r.count !== msg.total || b === 0;
    r.count = msg.total;
    this.render();
    if (countChanged && typeof this.onRemoteCount === 'function') this.onRemoteCount(msg.total, r.total);
  };

  VirtualTable.prototype.destroy = function () {
    if (this.scrollContainer && typeof this.scrollContainer.removeEventListener === 'function' && this._scrollHandler) {
      this.scrollContainer.removeEventListener('scroll', this._scrollHandler);
    }
  };

  function SideviewEngine(containerElement, options) {
    var self = this;
    this.container = typeof containerElement === 'string'
      ? document.querySelector(containerElement)
      : containerElement;

    if (!this.container) {
      throw new Error('Sideview container element not found');
    }

    this.options = Object.assign({
      snapThreshold: 20,
      snapToEdge: true,
      minScale: 0.15,
      maxScale: 3.5,
      // 'standalone' (gadget / full page) or 'embedded' (htmlwidget in a document)
      mode: 'standalone',
      cards: []
    }, options);

    // Global (window/document) listeners registered through listenGlobal() are
    // removed again by destroy(), so re-rendered widgets don't leak handlers.
    this._globalListeners = [];
    this._rafPending = false;
    this._portDownHandled = null;

    this.cards = new Map();
    this.connections = [];
    this.activePort = null;
    this.selectedColor = null;
    this.syncScrollCards = new Set();
    this.isSyncingScroll = false;
    this.panzoom = null;
    this.generatedCode = '';
    this.suggestedConnections = [];
    this.lastDiscrepancy = null;
    // Join diagnostics by join signature (tables + keys); see joinDiagFor().
    this.joinDiag = {};
    this.joinDiagPending = {};
    this.colProfiles = {};
    this.colProfilePending = {};
    this.joinCheckStepId = null;

    // The composable pipeline is the single source of the generated code.
    if (!global.SideviewPipeline) {
      throw new Error('sideview: sv-pipeline.js must be loaded before sideview.js');
    }
    this.pipeline = new global.SideviewPipeline.Pipeline({
      pipe: this.options.pipe,
      onChange: function () { self.renderPipeline(); }
    });

    this.initDOM();
    // Focusable (not in the tab order) so clicks give it keyboard focus.
    if (!this.container.hasAttribute('tabindex')) this.container.setAttribute('tabindex', '-1');
    this.ensureToolbarExtras();
    this.applyThemeVars(this.options.themeVars);
    this.applyTheme(this.options.theme || this.container.getAttribute('data-sv-theme') || 'auto');
    this.ensureDrawer();
    hydrateIcons(this.container);
    this.initPanzoom();
    this.initEventListeners();
    this.initExistingCards();

    if (this.options.cards && this.options.cards.length > 0) {
      this.options.cards.forEach(function (cardData, index) {
        self.addCard(cardData, index);
      });
    }

    if (this.options.pipeline) {
      this.pipeline.load(this.options.pipeline);
      this.pipeline.undoStack = [];
    }
    this.renderPipeline();

    var saved = initialState(this);
    if (saved) {
      var restoredOut = this.applyState(saved);
      if (restoredOut.missing.length) this.showToast(stateSummary(restoredOut), 'warning');
    }

    this.registerShinyHandlers();
    this.initMinimap();
    this.initLayoutObserver();
  }

  // ---- icons ----------------------------------------------------------------
  // Inline SVG icons (paths after Lucide, ISC/MIT licensed). Emoji and Unicode
  // glyphs render inconsistently in the Windows RStudio Viewer, so every icon
  // goes through icon(). Server-rendered markup carries data-sv-icon
  // placeholders that hydrateIcons() fills in.
  var ICONS = {
    maximize: '<polyline points="15 3 21 3 21 9"/><polyline points="9 21 3 21 3 15"/><line x1="21" y1="3" x2="14" y2="10"/><line x1="3" y1="21" x2="10" y2="14"/>',
    restore: '<polyline points="4 14 10 14 10 20"/><polyline points="20 10 14 10 14 4"/><line x1="14" y1="10" x2="21" y2="3"/><line x1="3" y1="21" x2="10" y2="14"/>',
    link: '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>',
    minus: '<line x1="5" y1="12" x2="19" y2="12"/>',
    plus: '<line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/>',
    filter: '<polygon points="22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3"/>',
    sort: '<path d="m21 16-4 4-4-4"/><path d="M17 20V4"/><path d="m3 8 4-4 4 4"/><path d="M7 4v16"/>',
    sortAsc: '<path d="m5 12 7-7 7 7"/><path d="M12 19V5"/>',
    sortDesc: '<path d="M12 5v14"/><path d="m19 12-7 7-7-7"/>',
    fullscreen: '<path d="M8 3H5a2 2 0 0 0-2 2v3"/><path d="M21 8V5a2 2 0 0 0-2-2h-3"/><path d="M3 16v3a2 2 0 0 0 2 2h3"/><path d="M16 21h3a2 2 0 0 0 2-2v-3"/>',
    sparkles: '<path d="m12 3-1.9 5.8a2 2 0 0 1-1.3 1.3L3 12l5.8 1.9a2 2 0 0 1 1.3 1.3L12 21l1.9-5.8a2 2 0 0 1 1.3-1.3L21 12l-5.8-1.9a2 2 0 0 1-1.3-1.3Z"/>',
    close: '<path d="M18 6 6 18"/><path d="m6 6 12 12"/>',
    undo: '<path d="M3 7v6h6"/><path d="M21 17a9 9 0 0 0-9-9 9 9 0 0 0-6 2.3L3 13"/>',
    redo: '<path d="M21 7v6h-6"/><path d="M3 17a9 9 0 0 1 9-9 9 9 0 0 1 6 2.3l3 2.7"/>',
    chevronUp: '<path d="m18 15-6-6-6 6"/>',
    chevronDown: '<path d="m6 9 6 6 6-6"/>',
    trash: '<path d="M3 6h18"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="m6.34 17.66-1.41 1.41"/><path d="m19.07 4.93-1.41 1.41"/>',
    moon: '<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/>',
    check: '<path d="M20 6 9 17l-5-5"/>',
    inspect: '<path d="M3 3v16a2 2 0 0 0 2 2h16"/><path d="M18 17V9"/><path d="M13 17V5"/><path d="M8 17v-3"/>',
    download: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="m7 10 5 5 5-5"/><path d="M12 15V3"/>',
    alert: '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>',
    save: '<path d="M15.2 3a2 2 0 0 1 1.4.6l3.8 3.8a2 2 0 0 1 .6 1.4V19a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z"/><path d="M17 21v-7a1 1 0 0 0-1-1H8a1 1 0 0 0-1 1v7"/><path d="M7 3v4a1 1 0 0 0 1 1h7"/>',
    folderOpen: '<path d="m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2"/>',
    search: '<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>',
    map: '<path d="M14.106 5.553a2 2 0 0 0 1.788 0l3.659-1.83A1 1 0 0 1 21 4.619v12.764a1 1 0 0 1-.553.894l-4.553 2.277a2 2 0 0 1-1.788 0l-4.212-2.106a2 2 0 0 0-1.788 0l-3.659 1.83A1 1 0 0 1 3 19.381V6.618a1 1 0 0 1 .553-.894l4.553-2.277a2 2 0 0 1 1.788 0z"/><path d="M15 5.764v15"/><path d="M9 3.236v15"/>',
    keyboard: '<rect width="20" height="16" x="2" y="4" rx="2"/><path d="M6 8h.01"/><path d="M10 8h.01"/><path d="M14 8h.01"/><path d="M18 8h.01"/><path d="M8 12h.01"/><path d="M12 12h.01"/><path d="M16 12h.01"/><path d="M7 16h10"/>'
  };

  function icon(name) {
    var body = ICONS[name];
    if (!body) return '';
    return '<svg class="sv-icon" viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" ' +
      'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">' +
      body + '</svg>';
  }

  // Swap the icon shown inside an element (e.g. sort state changes).
  function setIcon(el, name) {
    if (!el) return;
    el.innerHTML = icon(name);
    el.dataset.svIcon = name;
  }

  // Fill empty [data-sv-icon] placeholders emitted by the R-side UI.
  function hydrateIcons(root) {
    if (!root || !root.querySelectorAll) return;
    root.querySelectorAll('[data-sv-icon]').forEach(function (el) {
      if (!el.firstElementChild && ICONS[el.dataset.svIcon]) el.innerHTML = icon(el.dataset.svIcon);
    });
  }

  // ---- small shared helpers -------------------------------------------------

  function escapeHtml(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function cssEscape(value) {
    var s = String(value == null ? '' : value);
    if (global.CSS && typeof global.CSS.escape === 'function') return global.CSS.escape(s);
    return s.replace(/["\\\]\[]/g, '\\$&');
  }

  // The column port under a pointer event. The connector SVG layer sits above
  // the cards, so a spline ending on a port can be the event target instead.
  function portFromEvent(e) {
    var t = e.target;
    var port = t && t.closest ? t.closest('.sideview-col-port') : null;
    if (port) return port;
    if (!t || !t.closest || !t.closest('.sideview-connector-svg')) return null;
    return portAtPoint(e.clientX, e.clientY, false);
  }

  // Port at a viewport point, looking through connector splines. With
  // `allowHeader`, a column header under the point maps to its port.
  function portAtPoint(x, y, allowHeader) {
    if (typeof document === 'undefined' || !document.elementsFromPoint) return null;
    var hits = document.elementsFromPoint(x, y) || [];
    for (var i = 0; i < hits.length; i++) {
      var el = hits[i];
      if (!el.closest) continue;
      if (el.classList.contains('sideview-col-port')) return el;
      // The first element below the splines decides.
      if (!el.closest('.sideview-connector-svg')) {
        var th = allowHeader ? el.closest('th') : null;
        return th ? th.querySelector('.sideview-col-port') : null;
      }
    }
    return null;
  }

  // Pair a visible spline with its click target in the hit layer. The visible
  // path ignores the pointer; the hit path forwards hover and click to it.
  function attachHitPath(engine, path) {
    if (!engine.hitSvg) return null;
    var hit = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    hit.setAttribute('class', 'sideview-connector-hit');
    if (path.dataset.connId) hit.dataset.connId = path.dataset.connId;
    var title = path.querySelector('title');
    if (title) hit.appendChild(title);
    hit.addEventListener('mouseenter', function () { path.classList.add('is-hover'); });
    hit.addEventListener('mouseleave', function () { path.classList.remove('is-hover'); });
    if (path.dataset.suggested) {
      hit.addEventListener('click', function (e) {
        e.stopPropagation();
        path.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
      });
    }
    hit._svVisible = path;
    path._svHit = hit;
    engine.hitSvg.appendChild(hit);
    return hit;
  }

  function pruneHitPaths(engine) {
    if (!engine.hitSvg) return;
    var hits = engine.hitSvg.querySelectorAll('.sideview-connector-hit');
    for (var i = 0; i < hits.length; i++) {
      var v = hits[i]._svVisible;
      if (!v || !v.parentNode) hits[i].parentNode.removeChild(hits[i]);
    }
  }

  // Shown in the code panel when there is nothing to run. It is display text
  // only and must never become the generated code.
  var CODE_PLACEHOLDER = '# Connect two columns to generate pipeline code';
  function isNoCode(code) {
    if (code === null || code === undefined) return true;
    var t = String(code).trim();
    return t === '' || t === CODE_PLACEHOLDER;
  }

  function asArray(x) {
    if (x === null || x === undefined) return [];
    return Array.isArray(x) ? x : [x];
  }

  // Data frames arrive column-wise ({x: [...], y: [...]}); turn them into rows.
  function rowsFromColumns(x) {
    if (x === null || x === undefined) return [];
    if (Array.isArray(x)) return x;
    if (typeof x !== 'object') return [];
    var keys = Object.keys(x);
    if (!keys.length) return [];
    var n = 0;
    keys.forEach(function (k) { n = Math.max(n, asArray(x[k]).length); });
    var rows = [];
    for (var i = 0; i < n; i++) {
      var row = {};
      keys.forEach(function (k) { row[k] = asArray(x[k])[i]; });
      rows.push(row);
    }
    return rows;
  }

  SideviewEngine.prototype.listenGlobal = function (target, type, fn, opts) {
    target.addEventListener(type, fn, opts);
    this._globalListeners.push([target, type, fn, opts]);
  };

  // Batch connector redraws into one per animation frame.
  SideviewEngine.prototype.scheduleConnectorUpdate = function () {
    var self = this;
    if (this._rafPending) return;
    if (typeof global.requestAnimationFrame !== 'function') {
      this.updateConnectors();
      this.renderMinimap();
      return;
    }
    this._rafPending = true;
    global.requestAnimationFrame(function () {
      self._rafPending = false;
      self.updateConnectors();
      self.activePopoverReposition();
      self.renderMinimap();
    });
  };

  // Publish chrome sizes as CSS variables so the drawer and AI bar never
  // overlap the top bar, whatever the window width.
  SideviewEngine.prototype.initLayoutObserver = function () {
    var self = this;
    var topbar = this.container.querySelector('.sideview-topbar');
    var aiBar = this.container.querySelector('.sideview-ai-bar');
    var setVar = function (name, value) {
      if (self.container.style && typeof self.container.style.setProperty === 'function') {
        self.container.style.setProperty(name, value);
      }
    };
    var publish = function () {
      if (topbar) setVar('--sv-topbar-h', topbar.offsetHeight + 'px');
      if (aiBar) setVar('--sv-aibar-h', aiBar.offsetHeight + 'px');
      self.container.classList.toggle('sv-narrow', self.container.clientWidth < 720);
      // Below this width the centred AI bar reaches the minimap's corner, so
      // the minimap moves up above it.
      self.container.classList.toggle('sv-compact', self.container.clientWidth < 1040);
      if (self.cards) self.freezeAllCardSizes();
      // First layout with a real size (a widget can start hidden in a tab).
      if (self._needsInitialLayout && self.container.clientWidth > 0) {
        self._needsInitialLayout = false;
        if (self.arrangeCards(true) && !self._restoredView) self.fitAll({ maxScale: 1, minScale: READABLE_SCALE });
      }
      self.scheduleConnectorUpdate();
    };
    this._needsInitialLayout = true;
    publish();
    if (typeof global.ResizeObserver === 'function') {
      this._resizeObserver = new global.ResizeObserver(publish);
      this._resizeObserver.observe(this.container);
      if (topbar) this._resizeObserver.observe(topbar);
      if (aiBar) this._resizeObserver.observe(aiBar);
    } else {
      this.listenGlobal(global, 'resize', publish);
    }
  };

  // ---- canvas layout ---------------------------------------------------------

  // Automatic layout never zooms out further than this, so table text stays
  // readable; anything beyond is reached by panning.
  var READABLE_SCALE = 0.5;

  // Bottom of the floating top chrome (toolbar, palette), in container pixels.
  SideviewEngine.prototype.chromeTop = function () {
    var cRect = this.container.getBoundingClientRect();
    var bottom = 0;
    var els = this.container.querySelectorAll('.sideview-topbar, .sideview-toolbar, .sideview-palette');
    for (var i = 0; i < els.length; i++) {
      var r = els[i].getBoundingClientRect();
      if (!r.width || !r.height || r.top - cRect.top > cRect.height / 3) continue;
      bottom = Math.max(bottom, r.bottom - cRect.top);
    }
    return bottom;
  };

  // Space kept clear at the bottom for the AI bar, in container pixels.
  SideviewEngine.prototype.chromeBottom = function () {
    var ai = this.container.querySelector('.sideview-ai-bar');
    if (!ai || !ai.offsetHeight) return 16;
    var cRect = this.container.getBoundingClientRect();
    return Math.max(16, cRect.bottom - ai.getBoundingClientRect().top + 12);
  };

  // Lay cards out in rows below the top chrome. Every column count is tried and
  // the one that fits the window at the largest zoom wins (ties go to more
  // columns, so tables stay side by side). With `onlyAuto`, only cards without
  // a saved position move, placed under the others. Returns true if any moved.
  SideviewEngine.prototype.arrangeCards = function (onlyAuto) {
    var gap = 32;
    var left = 24;
    var moving = [];
    var fixedBottom = null;
    this.cards.forEach(function (card) {
      var el = card.element;
      if (!el || el.classList.contains('is-maximized')) return;
      if (!onlyAuto || el.dataset.autoPlace === 'true') {
        moving.push(card);
      } else {
        var b = (parseFloat(el.style.top) || 0) + el.offsetHeight;
        fixedBottom = fixedBottom === null ? b : Math.max(fixedBottom, b);
      }
    });
    if (!moving.length) return false;

    var top = fixedBottom === null ? this.chromeTop() + 16 : fixedBottom + gap;
    var sizes = moving.map(function (card) {
      return { w: card.element.offsetWidth, h: card.element.offsetHeight };
    });
    var layout = function (cols) {
      var pos = [], x = left, y = top, rowH = 0, maxX = left;
      sizes.forEach(function (sz, i) {
        if (i > 0 && i % cols === 0) { x = left; y += rowH + gap; rowH = 0; }
        pos.push({ x: x, y: y });
        x += sz.w + gap;
        maxX = Math.max(maxX, x - gap);
        rowH = Math.max(rowH, sz.h);
      });
      return { pos: pos, w: maxX - left, h: y + rowH - top };
    };
    var availW = Math.max(this.container.clientWidth - 2 * left, 1);
    var availH = Math.max(this.container.clientHeight - (this.chromeTop() + 16) - this.chromeBottom(), 1);
    // Below READABLE_SCALE the view stops shrinking and the user pans; then a
    // layout whose width still fits wins, so panning is vertical only.
    var best = null;
    for (var cols = 1; cols <= sizes.length; cols++) {
      var l = layout(cols);
      var fit = Math.min(1, availW / Math.max(l.w, 1), availH / Math.max(l.h, 1));
      var widthOk = l.w * Math.max(fit, READABLE_SCALE) <= availW + 1;
      var better = !best || (widthOk && !best.widthOk) ||
        (widthOk === best.widthOk && fit >= best.fit - 1e-6);
      if (better) best = { fit: fit, widthOk: widthOk, pos: l.pos };
    }
    moving.forEach(function (card, i) {
      var el = card.element;
      var p = best.pos[i];
      el.style.left = p.x + 'px';
      el.style.top = p.y + 'px';
      card.x = p.x;
      card.y = p.y;
      delete el.dataset.autoPlace;
    });
    this.scheduleConnectorUpdate();
    return true;
  };

  // Zoom and pan so every card is visible between the top chrome and the AI
  // bar. `maxScale` stops small layouts being blown up; `minScale` keeps text
  // readable (the rest stays reachable by panning).
  SideviewEngine.prototype.fitAll = function (opts) {
    opts = opts || {};
    var pz = this.panzoom;
    if (!pz || typeof pz.zoom !== 'function' || typeof pz.pan !== 'function' || !this.cards.size) return;
    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    this.cards.forEach(function (card) {
      var el = card.element;
      if (!el || el.classList.contains('is-maximized')) return;
      var l = parseFloat(el.style.left) || 0;
      var t = parseFloat(el.style.top) || 0;
      minX = Math.min(minX, l);
      minY = Math.min(minY, t);
      maxX = Math.max(maxX, l + el.offsetWidth);
      maxY = Math.max(maxY, t + el.offsetHeight);
    });
    if (!isFinite(minX)) return;
    var margin = 24;
    var top = this.chromeTop() + 16;
    var availW = this.container.clientWidth - 2 * margin;
    var availH = this.container.clientHeight - top - this.chromeBottom();
    if (availW <= 0 || availH <= 0) return;
    var s = Math.min(availW / Math.max(maxX - minX, 1), availH / Math.max(maxY - minY, 1));
    var lo = Math.max(opts.minScale || 0, this.options.minScale);
    var hi = Math.min(opts.maxScale || this.options.maxScale, this.options.maxScale);
    s = Math.min(Math.max(s, lo), hi);
    pz.zoom(s);
    pz.pan(margin - minX * s, top - minY * s);
  };

  // Zoom and pan so one card fills the free canvas area (between the top chrome
  // and the AI bar), then flash it. A card too big to fit at a readable zoom is
  // shown from its top-left corner.
  SideviewEngine.prototype.zoomToCard = function (el) {
    var pz = this.panzoom;
    if (!el || !pz || typeof pz.zoom !== 'function' || typeof pz.pan !== 'function') return false;
    if (el.classList.contains('is-maximized')) return false;
    var l = parseFloat(el.style.left) || 0;
    var t = parseFloat(el.style.top) || 0;
    var w = Math.max(el.offsetWidth || 0, 1);
    var h = Math.max(el.offsetHeight || 0, 1);
    var margin = 24;
    var top = this.chromeTop() + 16;
    var availW = this.container.clientWidth - 2 * margin;
    var availH = this.container.clientHeight - top - this.chromeBottom();
    if (availW <= 0 || availH <= 0) return false;
    var s = Math.min(availW / w, availH / h);
    var lo = Math.max(READABLE_SCALE, this.options.minScale);
    var hi = Math.min(1.5, this.options.maxScale);
    s = Math.min(Math.max(s, lo), hi);
    pz.zoom(s);
    pz.pan(margin + Math.max(0, (availW - w * s) / 2) - l * s,
           top + Math.max(0, (availH - h * s) / 2) - t * s);
    this.flashClass(el, 'sv-card-focus');
    return true;
  };

  // Add a class for a moment (a highlight ring); restarts if already shown.
  SideviewEngine.prototype.flashClass = function (el, cls, ms) {
    if (!el) return;
    if (el._svFlashTimer) clearTimeout(el._svFlashTimer);
    el.classList.add(cls);
    el._svFlashTimer = setTimeout(function () {
      el.classList.remove(cls);
      el._svFlashTimer = null;
    }, ms || 1200);
  };

  // Centre the free canvas area on a canvas point, keeping the zoom.
  SideviewEngine.prototype.centreViewOn = function (pt) {
    var pz = this.panzoom;
    if (!pz || !pt || typeof pz.pan !== 'function') return;
    var s = pz.getScale();
    var top = this.chromeTop();
    var cy = (top + this.container.clientHeight - this.chromeBottom()) / 2;
    pz.pan(this.container.clientWidth / 2 - pt.x * s, cy - pt.y * s);
  };

  // ---- minimap ----------------------------------------------------------------
  // A small overview in the bottom-left corner: one rectangle per card plus the
  // visible area. Click or drag to move the view; click a card to zoom to it.

  SideviewEngine.prototype.initMinimap = function () {
    var self = this;
    var mm = this.container.querySelector('.sideview-minimap');
    if (!mm) {
      mm = document.createElement('div');
      mm.className = 'sideview-minimap';
      mm.innerHTML =
        '<button type="button" class="sideview-icon-btn sideview-minimap-toggle" data-action="toggle-minimap"></button>' +
        '<svg class="sideview-minimap-svg" xmlns="http://www.w3.org/2000/svg" preserveAspectRatio="xMidYMid meet" ' +
        'role="img" aria-label="Map of the cards. Click to move the view, click a card to zoom to it."></svg>';
      this.container.appendChild(mm);
    }
    this.minimap = mm;
    this._minimapSvg = mm.querySelector('.sideview-minimap-svg');
    this._minimapSig = '';
    var hidden = false;
    try { hidden = global.localStorage && global.localStorage.getItem('sideview.minimap') === 'hidden'; } catch (e) {}
    this.toggleMinimap(!hidden, true);

    var svg = this._minimapSvg;
    if (!svg || typeof svg.addEventListener !== 'function') return;
    svg.addEventListener('pointerdown', function (e) {
      if (e.button !== 0) return;
      e.preventDefault();
      e.stopPropagation();
      var startX = e.clientX, startY = e.clientY, moved = false;
      var hit = e.target && e.target.closest ? e.target.closest('.sideview-minimap-card') : null;
      self._minimapFrozen = true;
      try { svg.setPointerCapture(e.pointerId); } catch (err) {}
      var move = function (ev) {
        if (!moved && Math.abs(ev.clientX - startX) + Math.abs(ev.clientY - startY) < 4) return;
        moved = true;
        self.centreViewOn(self.minimapPoint(ev));
      };
      var up = function (ev) {
        svg.removeEventListener('pointermove', move);
        svg.removeEventListener('pointerup', up);
        svg.removeEventListener('pointercancel', up);
        self._minimapFrozen = false;
        if (!moved && ev.type === 'pointerup') {
          var card = hit ? self.cards.get(hit.getAttribute('data-card-id')) : null;
          if (card && card.element) self.zoomToCard(card.element);
          else self.centreViewOn(self.minimapPoint(ev));
        }
        self._minimapSig = '';
        self.scheduleConnectorUpdate();
      };
      svg.addEventListener('pointermove', move);
      svg.addEventListener('pointerup', up);
      svg.addEventListener('pointercancel', up);
    });
  };

  SideviewEngine.prototype.toggleMinimap = function (show, initial) {
    var mm = this.minimap;
    if (!mm) return false;
    if (show === undefined) show = mm.classList.contains('is-collapsed');
    mm.classList.toggle('is-collapsed', !show);
    var btn = mm.querySelector('.sideview-minimap-toggle');
    if (btn) {
      var label = show ? 'Hide the minimap (M)' : 'Show the minimap (M)';
      btn.title = label;
      btn.setAttribute('aria-label', label);
      btn.setAttribute('aria-expanded', show ? 'true' : 'false');
      setIcon(btn, show ? 'close' : 'map');
    }
    if (!initial) {
      try { if (global.localStorage) global.localStorage.setItem('sideview.minimap', show ? 'shown' : 'hidden'); } catch (e) {}
    }
    this._minimapSig = '';
    if (show) this.scheduleConnectorUpdate();
    return show;
  };

  // Canvas coordinates of a pointer event over the minimap.
  SideviewEngine.prototype.minimapPoint = function (ev) {
    var svg = this._minimapSvg;
    if (!svg) return null;
    var m = typeof svg.getScreenCTM === 'function' ? svg.getScreenCTM() : null;
    if (m && typeof svg.createSVGPoint === 'function') {
      var pt = svg.createSVGPoint();
      pt.x = ev.clientX;
      pt.y = ev.clientY;
      var c = pt.matrixTransform(m.inverse());
      return { x: c.x, y: c.y };
    }
    return null;
  };

  SideviewEngine.prototype.renderMinimap = function () {
    var mm = this.minimap, svg = this._minimapSvg;
    if (!mm || !svg || this._minimapFrozen) return;
    var rects = [];
    this.cards.forEach(function (card, id) {
      var el = card.element;
      if (!el || el.classList.contains('is-maximized')) return;
      rects.push({
        id: id, name: el.dataset.cardName || card.name || String(id),
        x: parseFloat(el.style.left) || 0, y: parseFloat(el.style.top) || 0,
        w: el.offsetWidth || 0, h: el.offsetHeight || 0
      });
    });
    mm.classList.toggle('is-empty', rects.length === 0);
    if (mm.classList.contains('is-collapsed') || !rects.length || !mm.offsetWidth) return;
    var pz = this.panzoom;
    var s = pz && pz.getScale ? pz.getScale() : 1;
    var p = pz && pz.getPan ? pz.getPan() : { x: 0, y: 0 };
    var vx = -p.x / s, vy = -p.y / s;
    var vw = this.container.clientWidth / s, vh = this.container.clientHeight / s;
    var minX = vx, minY = vy, maxX = vx + vw, maxY = vy + vh;
    rects.forEach(function (r) {
      minX = Math.min(minX, r.x);
      minY = Math.min(minY, r.y);
      maxX = Math.max(maxX, r.x + r.w);
      maxY = Math.max(maxY, r.y + r.h);
    });
    var pad = Math.max(maxX - minX, maxY - minY) * 0.04 + 8;
    var r2 = function (v) { return Math.round(v * 10) / 10; };
    var box = [minX - pad, minY - pad, maxX - minX + 2 * pad, maxY - minY + 2 * pad].map(r2).join(' ');
    var cardsSvg = rects.map(function (r) {
      return '<rect class="sideview-minimap-card" data-card-id="' + escapeHtml(String(r.id)) + '" x="' + r2(r.x) +
        '" y="' + r2(r.y) + '" width="' + r2(r.w) + '" height="' + r2(r.h) + '" vector-effect="non-scaling-stroke">' +
        '<title>' + escapeHtml(r.name) + '</title></rect>';
    }).join('');
    var view = '<rect class="sideview-minimap-view" x="' + r2(vx) + '" y="' + r2(vy) + '" width="' + r2(vw) +
      '" height="' + r2(vh) + '" vector-effect="non-scaling-stroke"/>';
    var sig = box + cardsSvg + view;
    if (sig === this._minimapSig) return;
    this._minimapSig = sig;
    svg.setAttribute('viewBox', box);
    svg.innerHTML = cardsSvg + view;
  };

  // ---- card search (Ctrl+K) -----------------------------------------------------

  // Cards and columns matching `query` (case-insensitive): card names first
  // (prefix matches before others), then columns. An empty query lists cards.
  SideviewEngine.prototype.searchCards = function (query) {
    var q = String(query || '').trim().toLowerCase();
    var out = [];
    this.cards.forEach(function (card, id) {
      var el = card.element;
      if (!el) return;
      var name = el.dataset.cardName || card.name || String(id);
      var dimsEl = el.querySelector('.sideview-card-header .sideview-badge:not(.sideview-badge-type)');
      var dims = dimsEl ? dimsEl.textContent.trim() : '';
      var lname = name.toLowerCase();
      var at = q ? lname.indexOf(q) : 0;
      if (at >= 0) out.push({ id: id, el: el, name: name, dims: dims, col: null, rank: at === 0 ? 0 : 1 });
      if (!q) return;
      var ths = el.querySelectorAll('thead th[data-col-name]');
      var seen = {};
      for (var i = 0; i < ths.length; i++) {
        var col = ths[i].dataset.colName;
        if (seen[col]) continue;
        seen[col] = true;
        var ca = col.toLowerCase().indexOf(q);
        if (ca >= 0) out.push({ id: id, el: el, name: name, dims: dims, col: col, rank: ca === 0 ? 2 : 3 });
      }
    });
    out.sort(function (a, b) { return a.rank - b.rank; });
    return out.slice(0, 50);
  };

  var searchSeq = 0;

  SideviewEngine.prototype.toggleSearch = function (show) {
    var self = this;
    var existing = this.container.querySelector('.sideview-search-scrim');
    if (show === undefined) show = !existing;
    if (!show) {
      if (existing) {
        existing.parentNode.removeChild(existing);
        var back = this._searchReturnFocus;
        this._searchReturnFocus = null;
        if (back && back.focus && this.container.contains(back)) back.focus();
        else { try { this.container.focus({ preventScroll: true }); } catch (e) {} }
      }
      return false;
    }
    if (existing) {
      var inp = existing.querySelector('.sideview-search-input');
      if (inp) inp.focus();
      return true;
    }
    if (this.closeActivePopover) this.closeActivePopover();
    this.toggleShortcuts(false);
    this._searchReturnFocus = document.activeElement;
    var n = ++searchSeq;
    var listId = 'sv-search-list-' + n;
    var scrim = document.createElement('div');
    scrim.className = 'sideview-search-scrim';
    scrim.innerHTML =
      '<div class="sideview-search" role="dialog" aria-modal="true" aria-label="Find a card or column">' +
      '<div class="sideview-search-field">' + icon('search') +
      '<input type="text" class="sideview-search-input" role="combobox" aria-expanded="true" ' +
      'aria-autocomplete="list" aria-controls="' + listId + '" autocomplete="off" spellcheck="false" ' +
      'placeholder="Find a card or column" aria-label="Find a card or column"></div>' +
      '<ul class="sideview-search-list" id="' + listId + '" role="listbox" aria-label="Matches"></ul>' +
      '<div class="sideview-search-hint"><kbd>Enter</kbd> go to <kbd>Esc</kbd> close</div></div>';
    this.container.appendChild(scrim);
    var input = scrim.querySelector('.sideview-search-input');
    var list = scrim.querySelector('.sideview-search-list');
    var items = [], sel = 0;
    var mark = function () {
      var lis = list.querySelectorAll('[role="option"]');
      for (var i = 0; i < lis.length; i++) lis[i].setAttribute('aria-selected', i === sel ? 'true' : 'false');
      var cur = lis[sel];
      if (cur) {
        input.setAttribute('aria-activedescendant', cur.id);
        // Keep the selection visible inside the list only (no page scroll).
        if (cur.offsetTop < list.scrollTop) list.scrollTop = cur.offsetTop;
        else if (cur.offsetTop + cur.offsetHeight > list.scrollTop + list.clientHeight) {
          list.scrollTop = cur.offsetTop + cur.offsetHeight - list.clientHeight;
        }
      } else input.removeAttribute('aria-activedescendant');
    };
    var render = function () {
      items = self.searchCards(input.value);
      sel = 0;
      if (!items.length) {
        list.innerHTML = '<li class="sideview-search-empty" role="presentation">No card or column matches</li>';
      } else {
        list.innerHTML = items.map(function (it, i) {
          return '<li role="option" id="sv-search-opt-' + n + '-' + i + '" data-index="' + i + '">' +
            '<span class="sideview-search-name">' + escapeHtml(it.name) + '</span>' +
            (it.col ? '<span class="sideview-search-col">' + escapeHtml(it.col) + '</span>' : '') +
            (it.dims ? '<span class="sideview-search-meta">' + escapeHtml(it.dims) + '</span>' : '') + '</li>';
        }).join('');
      }
      mark();
    };
    var choose = function (i) {
      var it = items[i];
      if (!it) return;
      self.toggleSearch(false);
      self.goToSearchResult(it);
    };
    input.addEventListener('input', render);
    input.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault();
        if (items.length) sel = (sel + (e.key === 'ArrowDown' ? 1 : items.length - 1)) % items.length;
        mark();
      } else if (e.key === 'Enter') {
        e.preventDefault();
        choose(sel);
      } else if (e.key === 'Escape') {
        e.preventDefault();
        e.stopPropagation();
        self.toggleSearch(false);
      } else if (e.key === 'Tab') {
        e.preventDefault();
      }
    });
    // Keep focus in the input while an option is clicked.
    list.addEventListener('mousedown', function (e) { e.preventDefault(); });
    list.addEventListener('click', function (e) {
      var li = e.target.closest('[role="option"]');
      if (li) choose(parseInt(li.getAttribute('data-index'), 10));
    });
    scrim.addEventListener('click', function (e) {
      if (e.target === scrim) self.toggleSearch(false);
    });
    render();
    try { input.focus({ preventScroll: true }); } catch (e) { input.focus(); }
    return true;
  };

  // Zoom to a search result; for a column, scroll it into the card and flash it.
  SideviewEngine.prototype.goToSearchResult = function (it) {
    var el = it && it.el;
    if (!el) return;
    if (el.classList.contains('is-minimized')) {
      var minBtn = el.querySelector('[data-action="minimize-card"]');
      if (minBtn) this.toggleMinimizeCard(el, minBtn);
    }
    this.zoomToCard(el);
    if (!it.col) return;
    var th = el.querySelector('thead th[data-col-name="' + cssEscape(it.col) + '"]');
    var body = el.querySelector('.sideview-card-body');
    if (!th) return;
    if (body) {
      var s = this.panzoom ? this.panzoom.getScale() : 1;
      var x = (th.getBoundingClientRect().left - body.getBoundingClientRect().left) / s + body.scrollLeft;
      body.scrollLeft = Math.max(0, x - (body.clientWidth - th.offsetWidth) / 2);
    }
    this.flashClass(th, 'sv-col-focus', 1600);
    this.scheduleConnectorUpdate();
  };

  SideviewEngine.prototype.destroy = function () {
    this._globalListeners.forEach(function (l) {
      try { l[0].removeEventListener(l[1], l[2], l[3]); } catch (e) {}
    });
    this._globalListeners = [];
    if (this._resizeObserver) { this._resizeObserver.disconnect(); this._resizeObserver = null; }
    if (this.panzoom && this.panzoom.destroy) this.panzoom.destroy();
    this.cards.forEach(function (card) {
      if (card.virtualTable && card.virtualTable.destroy) card.virtualTable.destroy();
    });
    this.closeActivePopover();
    var dialogs = this.container.querySelectorAll('.sideview-shortcuts-scrim, .sideview-search-scrim');
    for (var di = 0; di < dialogs.length; di++) {
      if (dialogs[di].parentNode) dialogs[di].parentNode.removeChild(dialogs[di]);
    }
    if (lastActiveEngine === this) lastActiveEngine = null;
    if (this.container._sideviewInstance === this) this.container._sideviewInstance = null;
  };

  // ---- theme ------------------------------------------------------------------
  // 'auto' follows prefers-color-scheme in CSS; 'light'/'dark' are explicit.
  // The R side may resolve 'auto' from the RStudio editor theme first.
  var THEMES = ['auto', 'light', 'dark'];

  SideviewEngine.prototype.applyTheme = function (mode) {
    if (THEMES.indexOf(mode) < 0) mode = 'auto';
    var cl = this.container.classList;
    THEMES.forEach(function (t) { cl.remove('sv-theme-' + t); });
    cl.add('sv-theme-' + mode);
    this.theme = mode;
    var btn = this.container.querySelector('[data-action="toggle-theme"]');
    if (btn) {
      var dark = this.isDarkTheme();
      setIcon(btn, dark ? 'sun' : 'moon');
      btn.title = dark ? 'Switch to light theme (T)' : 'Switch to dark theme (T)';
      btn.setAttribute('aria-label', btn.title);
    }
    return mode;
  };

  SideviewEngine.prototype.isDarkTheme = function () {
    if (this.theme === 'dark') return true;
    if (this.theme === 'light') return false;
    return !!(global.matchMedia && global.matchMedia('(prefers-color-scheme: dark)').matches);
  };

  SideviewEngine.prototype.toggleTheme = function () {
    return this.applyTheme(this.isDarkTheme() ? 'light' : 'dark');
  };

  // Token overrides, e.g. {primary: '#0d6efd'} -> --sv-primary. Only --sv-*
  // names are accepted, so options can never set arbitrary inline styles.
  SideviewEngine.prototype.applyThemeVars = function (vars) {
    if (!vars || typeof vars !== 'object') return;
    var style = this.container.style;
    Object.keys(vars).forEach(function (key) {
      var name = key.indexOf('--sv-') === 0 ? key : '--sv-' + key;
      var val = vars[key];
      if (/^--sv-[a-z0-9-]+$/.test(name) && typeof val === 'string' && !/[;{}<>]/.test(val)) {
        style.setProperty(name, val);
      }
    });
  };

  // Theme and keyboard-help buttons are added here (not in the R/JS toolbar
  // markup) so the gadget and the widget always get the same controls.
  SideviewEngine.prototype.ensureToolbarExtras = function () {
    var tb = this.container.querySelector('.sideview-toolbar');
    if (!tb) return;
    var after = tb.querySelector('[data-action="toggle-fullscreen"]');
    var add = function (action, name, label) {
      var b = tb.querySelector('[data-action="' + action + '"]');
      if (!b) {
        b = document.createElement('button');
        b.type = 'button';
        b.className = 'sideview-btn sideview-btn-icon';
        b.dataset.action = action;
        b.title = label;
        b.setAttribute('aria-label', label);
        b.innerHTML = icon(name);
        if (after && after.parentNode === tb) tb.insertBefore(b, after.nextSibling);
        else tb.appendChild(b);
      }
      after = b;
    };
    add('open-search', 'search', 'Find a card or column (Ctrl+K)');
    add('save-workspace', 'save', 'Save workspace (cards, joins, pipeline)');
    add('open-workspace', 'folderOpen', 'Open a saved workspace');
    add('toggle-theme', 'moon', 'Switch to dark theme (T)');
    add('show-shortcuts', 'keyboard', 'Keyboard shortcuts (?)');
  };

  // Keys in the shortcut list. Kept in sync with the keydown handlers.
  var SHORTCUTS = [
    [['F'], 'Fit all cards in view'],
    [['0'], 'Reset zoom to 100%'],
    [['+', '-'], 'Zoom in / out'],
    [['Ctrl+K'], 'Find a card or column'],
    [['Double-click a card title'], 'Zoom to that card'],
    [['M'], 'Show or hide the minimap'],
    [['D'], 'Show or hide the drawer'],
    [['T'], 'Switch light / dark theme'],
    [['/'], 'Type an AI prompt'],
    [['Ctrl+Z', 'Ctrl+Y'], 'Undo / redo a pipeline step'],
    [['Ctrl+Enter'], 'Add the step in a builder tab'],
    [['Esc'], 'Cancel a connection, close a popover, or restore a card'],
    [['?'], 'Show or hide this list']
  ];

  var shortcutsSeq = 0;

  SideviewEngine.prototype.toggleShortcuts = function (show) {
    var self = this;
    var existing = this.container.querySelector('.sideview-shortcuts-scrim');
    if (show === undefined) show = !existing;
    if (!show) {
      if (existing) {
        existing.parentNode.removeChild(existing);
        var back = this._shortcutsReturnFocus;
        this._shortcutsReturnFocus = null;
        if (back && back.focus && this.container.contains(back)) back.focus();
        else { try { this.container.focus({ preventScroll: true }); } catch (e) {} }
      }
      return false;
    }
    if (existing) return true;
    this._shortcutsReturnFocus = document.activeElement;
    var id = 'sv-shortcuts-title-' + (++shortcutsSeq);
    var rows = SHORTCUTS.map(function (row) {
      return '<dt>' + row[0].map(function (k) { return '<kbd>' + escapeHtml(k) + '</kbd>'; }).join(' / ') +
        '</dt><dd>' + escapeHtml(row[1]) + '</dd>';
    }).join('');
    var scrim = document.createElement('div');
    scrim.className = 'sideview-shortcuts-scrim';
    scrim.innerHTML =
      '<div class="sideview-shortcuts" role="dialog" aria-modal="true" aria-labelledby="' + id + '" tabindex="-1">' +
      '<div class="sideview-shortcuts-head"><span id="' + id + '">Keyboard shortcuts</span>' +
      '<button type="button" class="sideview-icon-btn" data-action="close-shortcuts" aria-label="Close shortcuts">' +
      icon('close') + '</button></div><dl>' + rows + '</dl></div>';
    scrim.addEventListener('click', function (e) {
      if (e.target === scrim) self.toggleShortcuts(false);
    });
    this.container.appendChild(scrim);
    var dialog = scrim.querySelector('.sideview-shortcuts');
    try { dialog.focus({ preventScroll: true }); } catch (e) { dialog.focus(); }
    return true;
  };

  // The engine reacts to single keys when focus is inside its container, or,
  // for the full-page gadget, when nothing else on the page has focus.
  SideviewEngine.prototype.ownsKeyboard = function () {
    var active = document.activeElement;
    if (active && active !== document.body && this.container.contains(active)) return true;
    if (this.options.mode === 'embedded') return false;
    return !active || active === document.body || active === document.documentElement;
  };

  function isTypingTarget(el) {
    if (!el || !el.tagName) return false;
    var tag = el.tagName.toLowerCase();
    if (tag === 'textarea' || tag === 'select' || el.isContentEditable) return true;
    if (tag !== 'input') return false;
    var type = String(el.type || 'text').toLowerCase();
    return ['button', 'checkbox', 'radio', 'range', 'color', 'submit', 'reset'].indexOf(type) < 0;
  }

  // ---- card window controls -------------------------------------------------

  // Freeze a card's natural size inline after first layout so that resizing it
  // (CSS resize: both) grows the body rather than fighting max-height.
  SideviewEngine.prototype.freezeCardSize = function (card) {
    if (!card || card.classList.contains('sv-sized') || card.classList.contains('is-maximized') ||
        card.classList.contains('is-minimized')) return;
    var w = card.offsetWidth;
    var h = card.offsetHeight;
    if (!w || !h) return; // not laid out yet (hidden tab); retried on resize
    if (!card.style.width) card.style.width = w + 'px';
    if (!card.style.height) card.style.height = h + 'px';
    card.classList.add('sv-sized');
  };

  SideviewEngine.prototype.freezeAllCardSizes = function () {
    var self = this;
    this.cards.forEach(function (meta) { self.freezeCardSize(meta.element); });
  };

  SideviewEngine.prototype.toggleMinimizeCard = function (card, btn) {
    var minimized = !card.classList.contains('is-minimized');
    card.classList.toggle('is-minimized', minimized);
    if (minimized) {
      // Remember an explicit height (from resize) so restore brings it back.
      card._svRestoreHeight = card.style.height || '';
      card.style.height = '';
    } else if (card._svRestoreHeight) {
      card.style.height = card._svRestoreHeight;
    }
    if (btn) {
      btn.title = minimized ? 'Expand card' : 'Collapse card';
      btn.setAttribute('aria-label', btn.title);
      btn.setAttribute('aria-pressed', minimized ? 'true' : 'false');
      setIcon(btn, minimized ? 'plus' : 'minus');
    }
    if (!minimized && card._virtualTable && card._virtualTable.render) card._virtualTable.render();
    this.scheduleConnectorUpdate();
  };

  // Maximize moves the card out of the transformed viewport into the overlay
  // layer (position: fixed inside a CSS transform is relative to the transform,
  // which made maximized cards ~10000px wide and off-screen).
  SideviewEngine.prototype.toggleMaximizeCard = function (card, btn) {
    var self = this;
    var isMax = card.classList.contains('is-maximized');
    if (!isMax) {
      if (card.classList.contains('is-minimized')) this.toggleMinimizeCard(card, null);
      card._svRestore = {
        parent: card.parentNode,
        next: card.nextSibling,
        style: { width: card.style.width, height: card.style.height }
      };
      card.style.width = '';
      card.style.height = '';
      if (this.overlay) this.overlay.appendChild(card);
      card.classList.add('is-maximized');
      if (this.overlay) this.overlay.classList.add('has-maximized');
    } else {
      var restore = card._svRestore || {};
      card.classList.remove('is-maximized');
      if (restore.parent) restore.parent.insertBefore(card, restore.next && restore.next.parentNode === restore.parent ? restore.next : null);
      if (restore.style) {
        card.style.width = restore.style.width || '';
        card.style.height = restore.style.height || '';
      }
      card._svRestore = null;
      if (this.overlay && !this.overlay.querySelector('.is-maximized')) this.overlay.classList.remove('has-maximized');
    }
    if (btn) {
      btn.title = !isMax ? 'Restore card' : 'Maximize card';
      btn.setAttribute('aria-label', btn.title);
      btn.setAttribute('aria-pressed', !isMax ? 'true' : 'false');
      setIcon(btn, !isMax ? 'restore' : 'maximize');
    }
    if (card._virtualTable && card._virtualTable.render) card._virtualTable.render();
    this.scheduleConnectorUpdate();
    setTimeout(function () { self.scheduleConnectorUpdate(); }, 50);
  };

  SideviewEngine.prototype.isNativeFullscreen = function () {
    return !!(document.fullscreenElement || document.webkitFullscreenElement ||
      document.mozFullScreenElement || document.msFullscreenElement);
  };

  // Native fullscreen on the container; when the browser refuses (e.g. inside
  // the RStudio Viewer iframe) fall back to a CSS "pseudo-fullscreen".
  SideviewEngine.prototype.toggleFullscreen = function (btn) {
    var self = this;
    var container = this.container;
    var setActive = function (on) {
      if (btn) btn.classList.toggle('active', on);
      self.scheduleConnectorUpdate();
      setTimeout(function () { self.scheduleConnectorUpdate(); }, 150);
    };
    var pseudoOn = container.classList.contains('sv-pseudo-fullscreen');

    if (pseudoOn) {
      container.classList.remove('sv-pseudo-fullscreen');
      setActive(false);
      return;
    }
    if (this.isNativeFullscreen()) {
      var exit = document.exitFullscreen || document.webkitExitFullscreen || document.mozCancelFullScreen || document.msExitFullscreen;
      if (exit) {
        try {
          var ep = exit.call(document);
          if (ep && ep.catch) ep.catch(function () {});
        } catch (err) {}
      }
      setActive(false);
      return;
    }

    var fallback = function () {
      container.classList.add('sv-pseudo-fullscreen');
      setActive(true);
    };
    var req = container.requestFullscreen || container.webkitRequestFullscreen ||
      container.mozRequestFullScreen || container.msRequestFullscreen;
    var enabled = document.fullscreenEnabled !== false && document.webkitFullscreenEnabled !== false;
    if (!req || !enabled) { fallback(); return; }
    try {
      var p = req.call(container);
      if (p && typeof p.then === 'function') {
        p.then(function () { setActive(true); }, fallback);
      } else {
        setActive(true);
      }
    } catch (err) {
      fallback();
    }
  };

  SideviewEngine.prototype.initDOM = function () {
    var self = this;

    // Ensure container has class
    if (!this.container.classList.contains('sideview-container')) {
      this.container.classList.add('sideview-container');
    }

    // Viewport and Canvas
    this.canvas = this.container.querySelector('.sideview-canvas');
    if (!this.canvas) {
      this.canvas = document.createElement('div');
      this.canvas.className = 'sideview-canvas';
      this.container.appendChild(this.canvas);
    }

    this.viewport = this.canvas.querySelector('.sideview-viewport');
    if (!this.viewport) {
      this.viewport = document.createElement('div');
      this.viewport.className = 'sideview-viewport';
      this.canvas.appendChild(this.viewport);
    }

    // SVG Connector overlay
    this.svg = this.viewport.querySelector('.sideview-connector-svg');
    if (!this.svg) {
      this.svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
      this.svg.setAttribute('class', 'sideview-connector-svg');
      this.svg.setAttribute('width', '100%');
      this.svg.setAttribute('height', '100%');
      this.viewport.appendChild(this.svg);
    }
    // Invisible, wider copies of the splines sit below the cards so a spline
    // crossing a card never steals clicks from the card's own controls.
    this.hitSvg = this.viewport.querySelector('.sideview-connector-hitlayer');
    if (!this.hitSvg) {
      this.hitSvg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
      this.hitSvg.setAttribute('class', 'sideview-connector-hitlayer');
      this.hitSvg.setAttribute('width', '100%');
      this.hitSvg.setAttribute('height', '100%');
      this.viewport.insertBefore(this.hitSvg, this.viewport.firstChild);
    }

    // Toolbar
    if (!this.container.querySelector('.sideview-toolbar')) {
      var toolbar = document.createElement('div');
      toolbar.className = 'sideview-toolbar';
      toolbar.innerHTML = [
        '<button class="sideview-btn" data-action="zoom-in" title="Zoom in (+)" aria-label="Zoom in">+</button>',
        '<button class="sideview-btn" data-action="zoom-out" title="Zoom out (-)" aria-label="Zoom out">-</button>',
        '<button class="sideview-btn" data-action="zoom-reset" title="Reset view to 100% (0)" aria-label="Reset zoom">100%</button>',
        '<button class="sideview-btn" data-action="fit-all" title="Fit all cards in view (F)">Fit</button>',
        '<button class="sideview-btn" data-action="arrange-cards" title="Arrange cards in a grid">Arrange</button>',
        '<span class="sideview-toolbar-divider"></span>',
        '<button class="sideview-btn active" data-action="toggle-snap" title="Snap to Edge">Snap</button>',
        '<button class="sideview-btn" data-action="suggest-mappings" title="Suggest Mappings across tables">Auto Map</button>',
        '<button class="sideview-btn" data-action="toggle-drawer" title="Show or hide the drawer (D)">Drawer</button>',
        '<button class="sideview-btn" data-action="toggle-fullscreen" title="Toggle Fullscreen Canvas" aria-label="Toggle fullscreen canvas">' + icon('fullscreen') + ' <span class="sideview-btn-label">Fullscreen</span></button>'
      ].join('');
      this.container.appendChild(toolbar);
    }

    // Palette
    if (!this.container.querySelector('.sideview-palette')) {
      var palette = document.createElement('div');
      palette.className = 'sideview-palette';
      palette.setAttribute('role', 'group');
      palette.setAttribute('aria-label', 'Highlight colour');
      var swatch = function (color, label, inner) {
        return '<button type="button" class="sideview-swatch sideview-swatch-' + color + '" data-color="' + color +
          '" title="' + label + '" aria-label="' + label + '" aria-pressed="false">' + (inner || '') + '</button>';
      };
      palette.innerHTML = [
        '<span class="sideview-palette-label">Highlight:</span>',
        swatch('blue', 'Highlight blue'),
        swatch('green', 'Highlight green'),
        swatch('amber', 'Highlight amber'),
        swatch('rose', 'Highlight rose'),
        swatch('purple', 'Highlight purple'),
        swatch('clear', 'Clear highlight', icon('close'))
      ].join('');
      this.container.appendChild(palette);
    }

    // Top bar: toolbar + palette share one wrapping flex row so they can never
    // overlap each other (older markup placed them as two floating boxes).
    var topbar = this.container.querySelector('.sideview-topbar');
    if (!topbar) {
      topbar = document.createElement('div');
      topbar.className = 'sideview-topbar';
      this.container.insertBefore(topbar, this.canvas.nextSibling);
    }
    var tb = this.container.querySelector('.sideview-toolbar');
    var pal = this.container.querySelector('.sideview-palette');
    if (tb && tb.parentNode !== topbar) topbar.appendChild(tb);
    if (pal && pal.parentNode !== topbar) topbar.appendChild(pal);

    // Overlay layer (not transformed by panzoom) for maximized cards and popovers
    this.overlay = this.container.querySelector('.sideview-overlay');
    if (!this.overlay) {
      this.overlay = document.createElement('div');
      this.overlay.className = 'sideview-overlay';
      this.container.appendChild(this.overlay);
    }

    if (this.options.mode === 'embedded') {
      this.container.classList.add('sv-embedded');
    }

    // Action Drawer
    if (!this.container.querySelector('.sideview-drawer')) {
      var drawer = document.createElement('div');
      drawer.className = 'sideview-drawer collapsed';
      drawer.innerHTML = [
        '<div class="sideview-drawer-header">',
        '  <span class="sideview-drawer-title">Tidyverse Operations</span>',
        '  <button class="sideview-icon-btn" data-action="close-drawer" title="Close drawer" aria-label="Close drawer">' + icon('close') + '</button>',
        '</div>',
        '<div class="sideview-drawer-tabs"></div>',
        '<div class="sideview-drawer-content">',
        '  <div class="sideview-tab-pane sideview-pipeline-pane" data-pane="pipeline">',
        '    <pre class="sideview-code-block"><code class="sideview-code-text">' + CODE_PLACEHOLDER + '</code></pre>',
        '  </div>',
        '  <div class="sideview-tab-pane sideview-discrepancy-pane" data-pane="discrepancy" style="display: none;">',
        '    <div class="sideview-joincheck" aria-live="polite"></div>',
        '    <div class="sideview-discrepancy-content">',
        '      <p class="sideview-drawer-desc">Connect columns between two tables to inspect discrepancies.</p>',
        '    </div>',
        '  </div>',
        '  <div class="sideview-tab-pane sideview-chat-pane" data-pane="chat" style="display: none;">',
        '    <div class="sideview-chat-messages">',
        '      <div class="sideview-chat-bubble sideview-chat-assistant">',
        '        <div class="sideview-chat-bubble-text">Hello! I am your AI Copilot. Ask me questions about your tables, request transformations, or refine existing pipelines.</div>',
        '      </div>',
        '    </div>',
        '    <div class="sideview-chat-input-wrap">',
        '      <input type="text" id="sideview-chat-input" class="sideview-chat-input" placeholder="Ask Copilot... (e.g. filter rows where age > 30)" />',
        '      <button id="sideview-chat-send" class="sideview-btn sideview-btn-primary sideview-chat-send">Send</button>',
        '    </div>',
        '  </div>',
        '</div>',
        '<div class="sideview-drawer-actions">',
        '  <button class="sideview-btn sideview-btn-primary" data-action="inject-script" data-r-only title="Insert code into active RStudio script">Insert Script</button>',
        '  <button class="sideview-btn" data-action="send-console-exit" data-r-only title="Send code to RStudio console and exit gadget to execute immediately">Run & Exit</button>',
        '  <button class="sideview-btn" data-action="eval-env" data-r-only title="Execute code immediately in active R session environment">Run in R</button>',
        '  <button class="sideview-btn" data-action="send-console" data-r-only title="Queue code to RStudio console (executes when gadget closes)">Run Console</button>',
        '  <button class="sideview-btn" data-action="copy-code">Copy</button>',
        '  <button class="sideview-btn sideview-btn-danger" data-action="clear-operation" title="Clear current operations, connector lines, and generated code">Clear</button>',
        '  <label class="sideview-autoclear-wrap" title="Automatically clear operations after inserting into script or copying"><input type="checkbox" class="sideview-autoclear-toggle" /> Auto-clear</label>',
        '</div>'
      ].join('');
      this.container.appendChild(drawer);
    }

    // AI Natural Language Prompt Bar
    if (!this.container.querySelector('.sideview-ai-bar')) {
      var aiBar = document.createElement('div');
      aiBar.className = 'sideview-ai-bar';
      aiBar.innerHTML = [
        '<span class="sideview-ai-icon" aria-hidden="true">' + icon('sparkles') + '</span>',
        '<input type="text" class="sideview-ai-input" placeholder="Ask AI: e.g., join patients and labs on ID, impute missing values..." />',
        '<button class="sideview-ai-send" data-action="send-ai">Send</button>'
      ].join('');
      this.container.appendChild(aiBar);
    }
  };

  SideviewEngine.prototype.initPanzoom = function () {
    var self = this;
    if (typeof global.Panzoom !== 'function') {
      console.warn('Panzoom library is not loaded');
      return;
    }

    this.panzoom = global.Panzoom(this.viewport, {
      canvas: true,
      minScale: this.options.minScale,
      maxScale: this.options.maxScale,
      excludeClass: 'sideview-card',
      wheelRequiresModifier: this.options.mode === 'embedded'
    });

    var zoomLabel = this.container.querySelector('[data-action="zoom-reset"]');
    this.viewport.addEventListener('panzoomchange', function (e) {
      var scale = e && e.detail && typeof e.detail.scale === 'number'
        ? e.detail.scale
        : (self.panzoom ? self.panzoom.getScale() : 1);
      if (zoomLabel) zoomLabel.textContent = Math.round(scale * 100) + '%';
      self.scheduleConnectorUpdate();
    });
  };

  SideviewEngine.prototype.initEventListeners = function () {
    var self = this;

    // Palette swatch selection
    this.container.addEventListener('click', function (e) {
      var swatch = e.target.closest('.sideview-swatch');
      if (swatch) {
        var color = swatch.dataset.color;
        var swatches = self.container.querySelectorAll('.sideview-swatch');
        swatches.forEach(function (s) {
          s.classList.remove('active');
          if (s.hasAttribute('aria-pressed')) s.setAttribute('aria-pressed', 'false');
        });

        if (self.selectedColor === color) {
          self.selectedColor = null;
        } else {
          self.selectedColor = color;
          swatch.classList.add('active');
          swatch.setAttribute('aria-pressed', 'true');
        }
      }
    });

    // Toolbar button clicks
    this.container.addEventListener('click', function (e) {
      var btn = e.target.closest('[data-action]');
      if (!btn) return;
      var action = btn.dataset.action;

      var rect = self.container.getBoundingClientRect();
      var centerPoint = { clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2 };

      if (action === 'zoom-in' && self.panzoom) {
        self.panzoom.zoomToPoint(self.panzoom.getScale() * 1.25, centerPoint);
      } else if (action === 'zoom-out' && self.panzoom) {
        self.panzoom.zoomToPoint(self.panzoom.getScale() * 0.8, centerPoint);
      } else if (action === 'zoom-reset' && self.panzoom) {
        self.panzoom.reset();
      } else if (action === 'fit-all') {
        self.fitAll();
      } else if (action === 'arrange-cards') {
        self.arrangeCards(false);
        self.fitAll({ maxScale: 1, minScale: READABLE_SCALE });
      } else if (action === 'minimize-card') {
        var minCard = btn.closest('.sideview-card');
        if (minCard) self.toggleMinimizeCard(minCard, btn);
      } else if (action === 'maximize-card') {
        var maxCard = btn.closest('.sideview-card');
        if (maxCard) self.toggleMaximizeCard(maxCard, btn);
      } else if (action === 'toggle-snap') {
        self.options.snapToEdge = !self.options.snapToEdge;
        btn.classList.toggle('active', self.options.snapToEdge);
      } else if (action === 'toggle-drawer') {
        var drawer = self.container.querySelector('.sideview-drawer');
        if (drawer) drawer.classList.toggle('collapsed');
      } else if (action === 'export-codebook') {
        self.exportCodebook();
      } else if (action === 'open-search') {
        self.toggleSearch(true);
      } else if (action === 'toggle-minimap') {
        self.toggleMinimap();
      } else if (action === 'save-workspace') {
        self.saveWorkspace();
      } else if (action === 'open-workspace') {
        self.openWorkspace();
      } else if (action === 'close-drawer') {
        var dr = self.container.querySelector('.sideview-drawer');
        if (dr) dr.classList.add('collapsed');
      } else if (action === 'toggle-fullscreen') {
        self.toggleFullscreen(btn);
      } else if (action === 'toggle-theme') {
        self.toggleTheme();
      } else if (action === 'show-shortcuts') {
        self.toggleShortcuts(true);
      } else if (action === 'close-shortcuts') {
        self.toggleShortcuts(false);
      } else if (action === 'inject-script') {
        if (!self.sendToR('inject_script', { code: self.generatedCode }, 'Insert Script')) return;
        if (self.shouldAutoClear()) {
          self.clearOperations(true);
          self.showToast('Code inserted into script and operations cleared!', 'success');
        } else {
          self.showToast('Code inserted into script! (Click Clear to reset)', 'success');
        }
      } else if (action === 'send-console') {
        if (!self.sendToR('send_console', { code: self.generatedCode }, 'Run Console')) return;
        self.showToast('Queuing code to RStudio console...', 'warning');
      } else if (action === 'send-console-exit') {
        if (!self.sendToR('send_console_and_exit', { code: self.generatedCode }, 'Run & Exit')) return;
        self.showToast('Executing in RStudio console and closing gadget...', 'success');
      } else if (action === 'eval-env') {
        if (!self.sendToR('eval_env', { code: self.generatedCode, assign_to: 'sv_result' }, 'Run in R')) return;
        self.showToast('Evaluating in R environment...', 'info');
      } else if (action === 'gadget-done') {
        self.showToast('Returning code to R...', 'success');
        sendToShiny('sideview_done', { code: isNoCode(self.generatedCode) ? '' : self.generatedCode });
      } else if (action === 'gadget-cancel') {
        sendToShiny('sideview_cancel', { at: Date.now() });
      } else if (action === 'copy-code') {
        if (navigator.clipboard && self.generatedCode) {
          navigator.clipboard.writeText(self.generatedCode);
          btn.textContent = 'Copied!';
          setTimeout(function () { btn.textContent = 'Copy'; }, 1500);
          if (self.shouldAutoClear()) {
            self.clearOperations(true);
            self.showToast('Code copied to clipboard and operations cleared!', 'success');
          } else {
            self.showToast('Code copied to clipboard! (Click Clear to reset)', 'info');
          }
        }
      } else if (action === 'pipeline-undo') {
        self.undoPipeline();
      } else if (action === 'pipeline-redo') {
        self.redoPipeline();
      } else if (action === 'clear-operation') {
        self.clearOperations();
      } else if (action === 'suggest-mappings') {
        self.requestSuggestedMappings();
      } else if (action === 'apply-auto-clean') {
        var disc = self.lastDiscrepancy || {};
        var lastConn = self.connections.length > 0 ? self.connections[self.connections.length - 1] : null;
        sendToShiny('apply_auto_clean', {
          discrepancy: disc,
          from_table: disc.from_table || (lastConn ? lastConn.fromTable : 'df'),
          to_table: disc.to_table || (lastConn ? lastConn.toTable : null),
          from_col: disc.from_col || (lastConn ? lastConn.fromCol : 'status'),
          to_col: disc.to_col || (lastConn ? lastConn.toCol : null)
        });
        self.showToast('Applying suggested cleanups...', 'info');
      }
    });

    // Click directly on an SVG connector spline to disconnect it
    this.container.addEventListener('click', function (e) {
      var path = e.target.closest('.sideview-connector-path, .sideview-connector-hit');
      if (!path) return;
      // Splines end on port centres; a click there is meant for the port.
      if (portFromEvent(e)) return;
      if (path.classList.contains('sideview-spline-suggested') || path.dataset.suggested) return;
      if (path._svVisible && path._svVisible.dataset.suggested) return;
      e.stopPropagation();
      var connId = path.dataset.connId;
      if (connId) {
        self.removeConnection(connId);
      }
    });

    // Right-click contextmenu on SVG spline or port to disconnect
    this.container.addEventListener('contextmenu', function (e) {
      var path = e.target.closest('.sideview-connector-path, .sideview-connector-hit');
      if (path) {
        e.preventDefault();
        e.stopPropagation();
        var connId = path.dataset.connId;
        if (connId) self.removeConnection(connId);
        return;
      }

      var port = e.target.closest('.sideview-col-port');
      if (port) {
        var colName = port.dataset.colName;
        var cardEl = port.closest('.sideview-card');
        var cardName = cardEl ? cardEl.dataset.cardName : '';
        var connsToRemove = self.connections.filter(function (c) {
          return (c.fromTable === cardName && c.fromCol === colName) ||
                 (c.toTable === cardName && c.toCol === colName);
        });
        if (connsToRemove.length > 0) {
          e.preventDefault();
          e.stopPropagation();
          connsToRemove.forEach(function (c) { self.removeConnection(c.id); });
        }
      }
    });

    // Drawer tab switching
    this.container.addEventListener('click', function (e) {
      var tab = e.target.closest('.sideview-drawer-tab');
      if (!tab) return;
      var tabName = tab.dataset.tab;
      self.activateDrawerTab(tabName);

      if (tabName === 'discrepancy') self.renderJoinCheck();
      if (tabName === 'discrepancy' && self.connections.length > 0) {
        var lastConn = self.connections[self.connections.length - 1];
        sendToShiny('discrepancy_check', {
          table1: lastConn.fromTable,
          col1: lastConn.fromCol,
          table2: lastConn.toTable,
          col2: lastConn.toCol
        });
      }
    });

    this.initPipelineListeners();

    // Copilot Chat Submit Handling
    function submitCopilotChat() {
      var chatInput = self.container.querySelector('#sideview-chat-input');
      var chatMessages = self.container.querySelector('.sideview-chat-messages');
      if (!chatInput) return;
      var msg = chatInput.value.trim();
      if (!msg) return;

      if (chatMessages) {
        var userBubble = document.createElement('div');
        userBubble.className = 'sideview-chat-bubble sideview-chat-user';
        var userText = document.createElement('div');
        userText.className = 'sideview-chat-bubble-text';
        userText.textContent = msg;
        userBubble.appendChild(userText);
        chatMessages.appendChild(userBubble);
        chatMessages.scrollTop = chatMessages.scrollHeight;
      }

      chatInput.value = '';

      if (sendToShiny('send_copilot_chat', {
        message: msg,
        current_code: self.generatedCode || ''
      })) {
        self.setAiBusy(true);
      }
    }

    this.container.addEventListener('click', function (e) {
      if (e.target.closest('#sideview-chat-send') || e.target.closest('.sideview-chat-send')) {
        submitCopilotChat();
      }

      var repBtn = e.target.closest('[data-action="chat-replace-pipeline"], .sideview-chat-replace-btn');
      if (repBtn) {
        var bubble = repBtn.closest('.sideview-chat-bubble');
        var codeBlock = bubble ? bubble.querySelector('.sideview-chat-code') : null;
        if (codeBlock && codeBlock.textContent) {
          self.updateDrawerCode(codeBlock.textContent.trim(), 'Copilot code');
          self.showToast('Pipeline replaced with the Copilot code (Ctrl+Z to undo)', 'success');
        }
      }

      var insBtn = e.target.closest('[data-action="chat-insert-editor"], .sideview-chat-insert-btn');
      if (insBtn) {
        var bubble = insBtn.closest('.sideview-chat-bubble');
        var codeBlock = bubble ? bubble.querySelector('.sideview-chat-code') : null;
        if (codeBlock && codeBlock.textContent) {
          sendToShiny('inject_script', { code: codeBlock.textContent.trim() });
        }
      }
    });

    this.container.addEventListener('keydown', function (e) {
      if (e.target && e.target.id === 'sideview-chat-input' && e.key === 'Enter') {
        e.preventDefault();
        submitCopilotChat();
      }
    });

    // AI Natural Language input submit
    var aiInput = this.container.querySelector('.sideview-ai-input');
    var aiSendBtn = this.container.querySelector('[data-action="send-ai"]');

    function submitAI() {
      if (!aiInput) return;
      var prompt = aiInput.value.trim();
      if (!prompt) return;

      var tableNames = Array.from(self.cards.values()).map(function (c) { return c.name; });
      if (self.aiBusy) return;
      var sent = sendToShiny('run_ai_prompt', {
        prompt: prompt,
        tables: tableNames
      });
      if (sent) {
        self.setAiBusy(true);
      } else {
        self.showToast('The AI bar needs the R session (run sideview() from R).', 'warning');
        return;
      }
      aiInput.value = '';
    }

    if (aiSendBtn) {
      aiSendBtn.addEventListener('click', submitAI);
    }
    if (aiInput) {
      aiInput.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') submitAI();
      });
    }

    // Cell & Column Highlighting on Table Click
    this.container.addEventListener('click', function (e) {
      if (!self.selectedColor) return;
      // Sort / filter / resize buttons live inside the th but must not highlight.
      if (e.target.closest('.sideview-th-btn, .sideview-col-resizer, [data-action]')) return;

      var th = e.target.closest('th');
      var td = e.target.closest('td');

      if (th && !e.target.closest('.sideview-col-port') && !e.target.closest('.sideview-rename-input')) {
        // Column highlight
        var colIdx = th.cellIndex;
        var table = th.closest('table');
        var cardEl = th.closest('.sideview-card');
        var cardId = cardEl ? cardEl.dataset.cardId : null;
        var colName = th.dataset.colName;

        if (table && table._virtualTable) {
          table._virtualTable.setColumnHighlight(colName, self.selectedColor);
        } else if (table) {
          var highlightClass = self.selectedColor === 'clear' ? '' : 'sv-highlight-' + self.selectedColor;
          var allCellsInCol = table.querySelectorAll('tbody tr td:nth-child(' + (colIdx + 1) + ')');

          allCellsInCol.forEach(function (cell) {
            cell.className = cell.className.replace(/sv-highlight-\w+/g, '').replace('sideview-cell-highlight', '').trim();
            if (highlightClass) {
              cell.classList.add(highlightClass, 'sideview-cell-highlight');
            }
          });
        }

        sendToShiny('sideview_highlight_changed', {
          card_id: cardId,
          col_name: colName,
          row_idx: null,
          color: self.selectedColor
        });
      } else if (td) {
        // Individual cell highlight
        var cellCard = td.closest('.sideview-card');
        var cellTable = td.closest('table');
        var thCol = cellTable ? cellTable.querySelectorAll('th')[td.cellIndex] : null;
        var rawRowIdx = td.parentElement.dataset.rowIndex !== undefined
          ? parseInt(td.parentElement.dataset.rowIndex, 10)
          : td.parentElement.rowIndex;

        if (cellTable && cellTable._virtualTable) {
          cellTable._virtualTable.setCellHighlight(rawRowIdx, td.cellIndex, self.selectedColor);
        } else {
          var cellHighlightClass = self.selectedColor === 'clear' ? '' : 'sv-highlight-' + self.selectedColor;
          td.className = td.className.replace(/sv-highlight-\w+/g, '').replace('sideview-cell-highlight', '').trim();
          if (cellHighlightClass) {
            td.classList.add(cellHighlightClass, 'sideview-cell-highlight');
          }
        }

        sendToShiny('sideview_highlight_changed', {
          card_id: cellCard ? cellCard.dataset.cardId : null,
          col_name: thCol ? thCol.dataset.colName : null,
          row_idx: rawRowIdx,
          color: self.selectedColor
        });
      }
    });

    // Sort Column Click
    this.container.addEventListener('click', function (e) {
      var sortBtn = e.target.closest('[data-action="sort-col"]');
      if (!sortBtn) return;
      e.stopPropagation();
      var cardEl = sortBtn.closest('.sideview-card');
      var th = sortBtn.closest('th');
      if (!cardEl || !th) return;
      var colName = sortBtn.dataset.colName || th.dataset.colName;
      self.sortColumn(cardEl, colName, th.cellIndex, sortBtn);
    });

    // Inspect Column Click -> Inspect tab
    this.container.addEventListener('click', function (e) {
      var inspectBtn = e.target.closest('[data-action="inspect-col"]');
      if (!inspectBtn) return;
      e.stopPropagation();
      var cardEl = inspectBtn.closest('.sideview-card');
      var th = inspectBtn.closest('th');
      if (!cardEl || !th) return;
      self.inspectColumn(cardEl.dataset.cardName, inspectBtn.dataset.colName || th.dataset.colName);
    });

    // Filter Column Click
    this.container.addEventListener('click', function (e) {
      var filterBtn = e.target.closest('[data-action="filter-col"]');
      if (!filterBtn) return;
      e.stopPropagation();
      var cardEl = filterBtn.closest('.sideview-card');
      var th = filterBtn.closest('th');
      if (!cardEl || !th) return;
      var colName = filterBtn.dataset.colName || th.dataset.colName;
      self.openFilterPopover(cardEl, colName, th.cellIndex, filterBtn);
    });

    // Column Connection Port Handling (Click port, click header, drag-to-connect, live draft spline)
    var draftPath = null;

    function cleanupDraft() {
      if (draftPath && draftPath.parentNode) {
        draftPath.parentNode.removeChild(draftPath);
      }
      draftPath = null;
      if (self.activePort && self.activePort.element) {
        self.activePort.element.classList.remove('connecting');
      }
      self.activePort = null;
      document.removeEventListener('mousemove', onDraftMove);
    }
    self.cleanupDraft = cleanupDraft;

    function onDraftMove(moveEvent) {
      if (!self.activePort || !draftPath) return;
      var viewportRect = self.viewport.getBoundingClientRect();
      var scale = self.panzoom ? self.panzoom.getScale() : 1;
      var r1 = self.activePort.element.getBoundingClientRect();
      var p1 = {
        x: (r1.left + r1.width / 2 - viewportRect.left) / scale,
        y: (r1.top + r1.height / 2 - viewportRect.top) / scale
      };
      var p2 = {
        x: (moveEvent.clientX - viewportRect.left) / scale,
        y: (moveEvent.clientY - viewportRect.top) / scale
      };
      draftPath.setAttribute('d', self.getBezierPath(p1, p2));
    }

    function startConnection(port, cardEl) {
      cleanupDraft();
      var cardId = cardEl.dataset.cardId;
      var cardName = cardEl.dataset.cardName;
      var colName = port.dataset.colName;

      self.activePort = { cardId: cardId, cardName: cardName, colName: colName, element: port };
      port.classList.add('connecting');

      draftPath = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      draftPath.setAttribute('class', 'sideview-connector-path sideview-connector-draft');
      self.svg.appendChild(draftPath);
      document.addEventListener('mousemove', onDraftMove);
      self.showToast('Connecting ' + cardName + '.' + colName + ' — click another column or port to link', 'info');
    }

    function completeConnection(targetPort, targetCardEl) {
      if (!self.activePort) return;
      var toCardId = targetCardEl.dataset.cardId;
      var toCardName = targetCardEl.dataset.cardName;
      var toColName = targetPort.dataset.colName;

      // Guard: Ignore if clicking the same active starting port
      if (targetPort === self.activePort.element) {
        return;
      }

      if (self.activePort.cardId === toCardId) {
        self.showToast('Cannot link columns within the same table', 'warning');
        cleanupDraft();
        return;
      }

      var fromCard = self.activePort.cardId;
      var fromTable = self.activePort.cardName;
      var fromCol = self.activePort.colName;
      var fromElement = self.activePort.element;

      cleanupDraft();

      self.addConnection({
        fromCard: fromCard,
        fromTable: fromTable,
        fromCol: fromCol,
        fromElement: fromElement,
        toCard: toCardId,
        toTable: toCardName,
        toCol: toColName,
        toElement: targetPort,
        type: 'left_join'
      });

      self.showToast('Linked ' + fromTable + '.' + fromCol + ' ↔ ' + toCardName + '.' + toColName, 'success');
    }

    this.container.addEventListener('click', function (e) {
      var port = portFromEvent(e);
      var th = port ? port.closest('th') : e.target.closest('th');

      // A real mouse press already ran through the mousedown handler below;
      // handling the trailing click again would start a phantom draft.
      if (port && self._portDownHandled === port) {
        self._portDownHandled = null;
        return;
      }
      self._portDownHandled = null;

      // Header tool buttons (sort / filter / resize) never connect.
      if (e.target.closest('.sideview-th-btn, .sideview-col-resizer, .sideview-rename-input')) return;

      if (!self.activePort) {
        if (port) {
          e.stopPropagation();
          var cardEl = port.closest('.sideview-card');
          if (cardEl) startConnection(port, cardEl);
        }
      } else {
        // Active port is set (connecting)
        if (port) {
          e.stopPropagation();
          if (port === self.activePort.element) return;
          var cardEl = port.closest('.sideview-card');
          if (cardEl) completeConnection(port, cardEl);
          return;
        }

        if (th) {
          var targetPort = th.querySelector('.sideview-col-port');
          var cardEl = th.closest('.sideview-card');
          if (targetPort && cardEl) {
            if (targetPort === self.activePort.element) return;
            e.stopPropagation();
            completeConnection(targetPort, cardEl);
            return;
          }
        }

        // Click outside or canvas background cancels draft
        if (!e.target.closest('.sideview-drawer') && !e.target.closest('.sideview-toolbar')) {
          cleanupDraft();
        }
      }
    });

    // Drag-to-connect support
    this.container.addEventListener('mousedown', function (e) {
      if (typeof e.button === 'number' && e.button !== 0) return;
      var port = portFromEvent(e);
      if (!port) return;
      var cardEl = port.closest('.sideview-card');
      if (!cardEl) return;
      e.stopPropagation();
      self._portDownHandled = port;

      // If already connecting, do not re-initialize on starting port
      if (self.activePort) {
        if (port !== self.activePort.element) {
          completeConnection(port, cardEl);
        }
        return;
      }

      var startX = e.clientX;
      var startY = e.clientY;
      var dragged = false;

      startConnection(port, cardEl);

      function onPointerDragMove(moveEvt) {
        if (Math.abs(moveEvt.clientX - startX) > 4 || Math.abs(moveEvt.clientY - startY) > 4) {
          dragged = true;
        }
      }

      function onPointerDragUp(upEvt) {
        document.removeEventListener('mousemove', onPointerDragMove);
        document.removeEventListener('mouseup', onPointerDragUp);

        if (dragged) {
          var targetPort = portAtPoint(upEvt.clientX, upEvt.clientY, true);
          var targetCard = targetPort ? targetPort.closest('.sideview-card') : null;
          if (targetPort && targetPort !== port && targetCard) {
            completeConnection(targetPort, targetCard);
            return;
          }
          cleanupDraft();
        }
      }

      document.addEventListener('mousemove', onPointerDragMove);
      document.addEventListener('mouseup', onPointerDragUp);
    });

    // Column Width Resizing via drag on .sideview-col-resizer
    this.container.addEventListener('mousedown', function (e) {
      var resizer = e.target.closest('.sideview-col-resizer');
      if (!resizer) return;
      e.stopPropagation();
      e.preventDefault();

      var th = resizer.closest('th');
      if (!th) return;

      var startX = e.clientX;
      var startWidth = th.offsetWidth;
      resizer.classList.add('is-resizing');

      function onColResizeMove(moveEvt) {
        var dx = moveEvt.clientX - startX;
        var newWidth = Math.max(65, startWidth + dx);
        th.style.width = newWidth + 'px';
        th.style.minWidth = newWidth + 'px';
        self.scheduleConnectorUpdate();
      }

      function onColResizeUp() {
        resizer.classList.remove('is-resizing');
        document.removeEventListener('mousemove', onColResizeMove);
        document.removeEventListener('mouseup', onColResizeUp);
        self.updateConnectors();
      }

      document.addEventListener('mousemove', onColResizeMove);
      document.addEventListener('mouseup', onColResizeUp);
    });

    // Pressing Escape cancels a draft connection, closes the filter popover,
    // or restores a maximized card (in that order).
    this.listenGlobal(document, 'keydown', function (e) {
      if (e.key !== 'Escape') return;
      if (self.container.querySelector('.sideview-search-scrim')) {
        if (self.ownsKeyboard()) self.toggleSearch(false);
        return;
      }
      if (self.toggleShortcuts && self.container.querySelector('.sideview-shortcuts-scrim')) {
        if (self.ownsKeyboard()) self.toggleShortcuts(false);
        return;
      }
      if (self.activePort) {
        cleanupDraft();
        self.showToast('Cancelled column connection', 'info');
        return;
      }
      if (self.closeActivePopover && self.closeActivePopover()) return;
      var maxed = self.overlay ? self.overlay.querySelector('.sideview-card.is-maximized') : null;
      if (maxed) {
        self.toggleMaximizeCard(maxed, maxed.querySelector('[data-action="maximize-card"]'));
      }
    });

    // Single-key canvas shortcuts (listed by "?"). They never fire while the
    // user types in a field, and an embedded widget only reacts once it has
    // focus, so keys typed elsewhere on a Quarto/R Markdown page are left alone.
    this.container.addEventListener('pointerdown', function (e) {
      if (!self.container.contains(document.activeElement) && !isTypingTarget(e.target)) {
        try { self.container.focus({ preventScroll: true }); } catch (err) { self.container.focus(); }
      }
    });
    // Ctrl+K / Cmd+K opens the card search, also from inside a text field.
    this.listenGlobal(document, 'keydown', function (e) {
      if (!(e.ctrlKey || e.metaKey) || e.altKey || e.shiftKey || e.defaultPrevented) return;
      if (String(e.key).toLowerCase() !== 'k' || !self.ownsKeyboard()) return;
      e.preventDefault();
      self.toggleSearch(true);
    });
    this.listenGlobal(document, 'keydown', function (e) {
      if (e.ctrlKey || e.metaKey || e.altKey || e.defaultPrevented) return;
      if (isTypingTarget(e.target) || !self.ownsKeyboard()) return;
      var k = e.key;
      var open = !!self.container.querySelector('.sideview-shortcuts-scrim');
      var rect = self.container.getBoundingClientRect();
      var centre = { clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2 };
      var handled = true;
      if (k === '?') self.toggleShortcuts();
      else if (open) handled = false;
      else if (k === 'f' || k === 'F') self.fitAll();
      else if (k === '0' && self.panzoom) self.panzoom.reset();
      else if ((k === '+' || k === '=') && self.panzoom) self.panzoom.zoomToPoint(self.panzoom.getScale() * 1.25, centre);
      else if ((k === '-' || k === '_') && self.panzoom) self.panzoom.zoomToPoint(self.panzoom.getScale() * 0.8, centre);
      else if (k === 't' || k === 'T') self.toggleTheme();
      else if (k === 'm' || k === 'M') self.toggleMinimap();
      else if (k === 'd' || k === 'D') {
        var drawerEl = self.container.querySelector('.sideview-drawer');
        if (drawerEl) drawerEl.classList.toggle('collapsed');
      } else if (k === '/') {
        var ai = self.container.querySelector('.sideview-ai-input');
        if (ai) ai.focus(); else handled = false;
      } else handled = false;
      if (handled) e.preventDefault();
    });

    // Inline Column Renaming via Double Click on column name
    this.container.addEventListener('dblclick', function (e) {
      var head = e.target.closest('.sideview-card-header');
      if (head && !e.target.closest('button, input, select, textarea, [data-action]')) {
        var headCard = head.closest('.sideview-card');
        if (headCard) {
          e.preventDefault();
          self.zoomToCard(headCard);
        }
        return;
      }
      var colNameEl = e.target.closest('.sideview-col-name');
      if (!colNameEl) return;

      var currentName = colNameEl.textContent.trim();
      var cardEl = colNameEl.closest('.sideview-card');
      var cardName = cardEl ? cardEl.dataset.cardName : '';
      var th = colNameEl.closest('th');

      var input = document.createElement('input');
      input.type = 'text';
      input.className = 'sideview-rename-input';
      input.value = currentName;

      colNameEl.style.display = 'none';
      colNameEl.parentNode.insertBefore(input, colNameEl);
      input.focus();
      input.select();

      function finishRename() {
        input.removeEventListener('blur', finishRename);
        var newName = input.value.trim();
        input.remove();
        colNameEl.style.display = '';

        if (newName && newName !== currentName) {
          colNameEl.textContent = newName;
          var table = (th && th.closest('table')) || {};
          if (table._virtualTable) {
            table._virtualTable.renameColumn(currentName, newName, th.cellIndex);
          }
          if (th) {
            th.dataset.colName = newName;
            var port = th.querySelector('.sideview-col-port');
            if (port) port.dataset.colName = newName;
          }
          self.pipeline.add({ kind: 'rename', table: cardName, from: currentName, to: newName }, 'rename');
          sendToShiny('column_renamed', {
            table: cardName,
            old_col: currentName,
            new_col: newName
          });
        }
      }

      input.addEventListener('blur', finishRename);
      input.addEventListener('keydown', function (evt) {
        if (evt.key === 'Enter') {
          input.removeEventListener('blur', finishRename);
          finishRename();
        } else if (evt.key === 'Escape') {
          input.removeEventListener('blur', finishRename);
          input.remove();
          colNameEl.style.display = '';
        }
      });
    });

    // Window resize & Fullscreen change connector synchronization
    if (typeof window !== 'undefined' && typeof window.addEventListener === 'function') {
      this.listenGlobal(window, 'resize', function () {
        self.scheduleConnectorUpdate();
      });
    }
    var onFullscreenChange = function () {
      var fsBtn = self.container.querySelector('[data-action="toggle-fullscreen"]');
      var isFs = self.isNativeFullscreen() || self.container.classList.contains('sv-pseudo-fullscreen');
      if (fsBtn) fsBtn.classList.toggle('active', isFs);
      self.scheduleConnectorUpdate();
    };
    if (typeof document !== 'undefined' && typeof document.addEventListener === 'function') {
      this.listenGlobal(document, 'fullscreenchange', onFullscreenChange);
      this.listenGlobal(document, 'webkitfullscreenchange', onFullscreenChange);
    }
  };

  /**
   * Add a table card to the canvas
   */
  SideviewEngine.prototype.addCard = function (cardData, index) {
    var self = this;
    var cardId = cardData.id || 'card_' + (index !== undefined ? index : Date.now());
    var cardName = cardData.name || 'Table_' + (index + 1);

    var cardEl = document.createElement('div');
    cardEl.className = 'sideview-card panzoom-exclude';
    cardEl.dataset.cardId = cardId;
    cardEl.dataset.cardName = cardName;

    // Positioning
    var hasPos = cardData.x != null || cardData.y != null;
    var initialX = cardData.x != null ? cardData.x : 40 + (index * 360);
    var initialY = cardData.y != null ? cardData.y : 60 + ((index % 2) * 50);
    cardEl.style.left = initialX + 'px';
    cardEl.style.top = initialY + 'px';
    // No saved position: flowed into a grid by arrangeCards() on first layout.
    if (!hasPos) cardEl.dataset.autoPlace = 'true';

    // Build Card Header
    var header = document.createElement('div');
    header.className = 'sideview-card-header';
    var dimsText = cardData.dims ? cardData.dims[0] + ' × ' + cardData.dims[1] : '';
    header.innerHTML = [
      '<div class="sideview-card-title-group">',
      '  <span class="sideview-card-title">' + escapeHtml(cardName) + '</span>',
      '  <span class="sideview-badge sideview-badge-type">' + escapeHtml(cardData.type || 'grid') + '</span>',
      dimsText ? '  <span class="sideview-badge">' + dimsText + '</span>' : '',
      '</div>',
      '<div class="sideview-card-actions">',
      '  <button class="sideview-icon-btn" data-action="maximize-card" title="Maximize card" aria-label="Maximize card" data-sv-icon="maximize">' + icon('maximize') + '</button>',
      '  <button class="sideview-icon-btn" data-action="sync-scroll" title="Synchronize vertical &amp; horizontal scrolling" aria-label="Synchronize scrolling" data-sv-icon="link">' + icon('link') + '</button>',
      '  <button class="sideview-icon-btn" data-action="minimize-card" title="Collapse card" aria-label="Collapse card" data-sv-icon="minus">' + icon('minus') + '</button>',
      '</div>'
    ].join('');
    cardEl.appendChild(header);

    // Build Card Body
    var body = document.createElement('div');
    body.className = 'sideview-card-body';

    if (cardData.type === 'grid' && cardData.data) {
      var table = document.createElement('table');
      table.className = 'sideview-table sideview-table-virtual';

      // Header row
      var thead = document.createElement('thead');
      var headerRow = document.createElement('tr');
      var colNames = Object.keys(cardData.data);
      var colTypes = cardData.col_types || {};

      colNames.forEach(function (colName) {
        var th = document.createElement('th');
        th.dataset.colName = colName;
        var colType = colTypes[colName] || '';
        if (colType) th.dataset.colType = colType;
        th.title = colType ? colName + ' (' + colType + ')' : colName;
        var safeName = escapeHtml(colName);
        th.innerHTML = [
          '<div class="col-header-wrap">',
          '  <div class="col-header-left">',
          '    <span class="sideview-col-name">' + safeName + '</span>',
          colType ? '    <span class="sideview-col-type">(' + escapeHtml(colType) + ')</span>' : '',
          '  </div>',
          '  <div class="col-header-tools">',
          '    <button class="sideview-th-btn sideview-sort-btn" data-action="sort-col" data-col-name="' + safeName + '" title="Sort column (Asc / Desc / Reset)" aria-label="Sort ' + safeName + '" data-sv-icon="sort">' + icon('sort') + '</button>',
          '    <button class="sideview-th-btn sideview-filter-btn" data-action="filter-col" data-col-name="' + safeName + '" title="Filter column" aria-label="Filter ' + safeName + '" data-sv-icon="filter">' + icon('filter') + '</button>',
          '    <button class="sideview-th-btn sideview-inspect-btn" data-action="inspect-col" data-col-name="' + safeName + '" title="Inspect column" aria-label="Inspect ' + safeName + '" data-sv-icon="inspect">' + icon('inspect') + '</button>',
          '    <span class="sideview-col-port" data-col-name="' + safeName + '" title="Connect to map field"></span>',
          '  </div>',
          '</div>',
          '<span class="sideview-col-resizer" title="Drag to resize column width"></span>'
        ].join('');
        headerRow.appendChild(th);
      });
      thead.appendChild(headerRow);
      table.appendChild(thead);

      body.appendChild(table);

      // Initialize VirtualTable for high-performance DOM viewport
      var vTable = new VirtualTable(table, {
        rowHeight: 28,
        buffer: 10,
        data: cardData.data,
        colNames: colNames,
        colTypes: colTypes
      });
      cardEl._virtualTable = table._virtualTable = vTable;
    } else if (cardData.html_content) {
      body.innerHTML = cardData.html_content;
    }

    cardEl.appendChild(body);
    this.viewport.appendChild(cardEl);

    // Register card in memory
    var cardMeta = {
      id: cardId,
      name: cardName,
      element: cardEl,
      body: body,
      x: initialX,
      y: initialY,
      colLabels: cardData.col_labels || null
    };
    this.cards.set(cardId, cardMeta);

    // Setup Drag and Drop
    this.setupCardDrag(cardEl, cardMeta);

    // Setup Synchronized Scroll
    this.setupScrollSync(cardMeta);
  };

  /**
   * Drag and drop table cards with snap-to-edge docking logic
   */
  SideviewEngine.prototype.setupCardDrag = function (cardEl, cardMeta) {
    var self = this;
    var header = cardEl.querySelector('.sideview-card-header');
    if (!header) return;

    var isDragging = false;
    var startPointerX = 0;
    var startPointerY = 0;
    var startCardX = 0;
    var startCardY = 0;

    function startDrag(e) {
      if (isDragging) return;
      if (typeof e.button === 'number' && e.button !== 0) return;
      if (e.target.closest('button') || e.target.closest('input')) return;
      if (cardEl.classList.contains('is-maximized')) return;
      // Browsers fire pointerdown then mousedown for one press; listen to a
      // single event family so each move is handled exactly once.
      var usePointer = e.type === 'pointerdown';
      var moveType = usePointer ? 'pointermove' : 'mousemove';
      var upType = usePointer ? 'pointerup' : 'mouseup';

      isDragging = true;
      cardEl.classList.add('is-dragging');
      if (header.setPointerCapture && e.pointerId !== undefined) {
        try { header.setPointerCapture(e.pointerId); } catch (err) {}
      }

      var scale = self.panzoom ? self.panzoom.getScale() : 1;
      startPointerX = e.clientX;
      startPointerY = e.clientY;
      startCardX = parseFloat(cardEl.style.left) || 0;
      startCardY = parseFloat(cardEl.style.top) || 0;

      function onPointerMove(moveEvent) {
        if (!isDragging) return;

        var scaleCurrent = self.panzoom ? self.panzoom.getScale() : 1;
        var dx = (moveEvent.clientX - startPointerX) / scaleCurrent;
        var dy = (moveEvent.clientY - startPointerY) / scaleCurrent;

        var targetX = startCardX + dx;
        var targetY = startCardY + dy;

        // Snap-to-edge calculation
        if (self.options.snapToEdge) {
          var snapThreshold = self.options.snapThreshold || 20;
          var cardWidth = cardEl.offsetWidth;
          var cardHeight = cardEl.offsetHeight;

          self.cards.forEach(function (other, otherId) {
            if (otherId === cardMeta.id) return;

            var otherEl = other.element;
            var ox = parseFloat(otherEl.style.left) || 0;
            var oy = parseFloat(otherEl.style.top) || 0;
            var ow = otherEl.offsetWidth;
            var oh = otherEl.offsetHeight;

            // Snap left-to-left
            if (Math.abs(targetX - ox) < snapThreshold) {
              targetX = ox;
            }
            // Snap left-to-right edge
            else if (Math.abs(targetX - (ox + ow + 16)) < snapThreshold) {
              targetX = ox + ow + 16;
            }
            // Snap right-to-left edge
            else if (Math.abs((targetX + cardWidth + 16) - ox) < snapThreshold) {
              targetX = ox - cardWidth - 16;
            }

            // Snap top-to-top
            if (Math.abs(targetY - oy) < snapThreshold) {
              targetY = oy;
            }
            // Snap top-to-bottom edge
            else if (Math.abs(targetY - (oy + oh + 16)) < snapThreshold) {
              targetY = oy + oh + 16;
            }
          });
        }

        cardEl.style.left = targetX + 'px';
        cardEl.style.top = targetY + 'px';
        cardMeta.x = targetX;
        cardMeta.y = targetY;

        // Update SVG bezier connectors during drag (batched per frame)
        self.scheduleConnectorUpdate();
      }

      function onPointerUp(upEvent) {
        if (!isDragging) return;
        isDragging = false;
        cardEl.classList.remove('is-dragging');
        if (header.releasePointerCapture && upEvent.pointerId !== undefined) {
          try { header.releasePointerCapture(upEvent.pointerId); } catch (err) {}
        }

        document.removeEventListener(moveType, onPointerMove);
        document.removeEventListener(upType, onPointerUp);
        self.updateConnectors();

        sendToShiny('sideview_card_moved', {
          card_id: cardMeta.id,
          x: cardMeta.x,
          y: cardMeta.y
        });
      }

      document.addEventListener(moveType, onPointerMove);
      document.addEventListener(upType, onPointerUp);
    }

    header.addEventListener('pointerdown', startDrag);
    header.addEventListener('mousedown', startDrag);
  };

  /**
   * Scan and initialize pre-rendered DOM cards (e.g. from Shiny Gadget mode)
   */
  SideviewEngine.prototype.initExistingCards = function () {
    var self = this;
    if (!this.viewport) return;
    var existingCards = this.viewport.querySelectorAll('.sideview-card');
    existingCards.forEach(function (cardEl, index) {
      var cardId = cardEl.dataset.cardId || cardEl.id || ('card_' + index);
      var cardName = cardEl.dataset.cardName || ('Table_' + (index + 1));
      var body = cardEl.querySelector('.sideview-card-body');
      var table = cardEl.querySelector('.sideview-table');
      var vTable = null;
      if (table && !table._virtualTable) {
        vTable = new VirtualTable(table, {
          rowHeight: 28,
          buffer: 10
        });
        cardEl._virtualTable = table._virtualTable = vTable;
        self.attachRemoteRows(cardEl, cardId, cardName, vTable);
      }
      var cardMeta = {
        id: cardId,
        name: cardName,
        element: cardEl,
        body: body,
        virtualTable: vTable,
        x: parseFloat(cardEl.style.left) || 0,
        y: parseFloat(cardEl.style.top) || 0
      };
      self.cards.set(cardId, cardMeta);
      self.setupCardDrag(cardEl, cardMeta);
      self.setupScrollSync(cardMeta);
    });
  };

  /**
   * Page rows from the R session when the card holds more rows than the HTML
   * preview (data-total-rows), so sort/filter/scroll cover the full data.
   */
  SideviewEngine.prototype.attachRemoteRows = function (cardEl, cardId, cardName, vTable) {
    var self = this;
    var total = parseInt(cardEl.dataset ? cardEl.dataset.totalRows : '', 10);
    // Shiny.setInputValue only appears once the session connects, which is
    // after this runs; requests made before then are retried.
    var hasShiny = typeof global.Shiny !== 'undefined';
    if (!hasShiny || isNaN(total) || total <= vTable.totalRows) return;
    vTable.onRemoteCount = function (count, fullTotal) {
      var f = vTable.currentFilter;
      if (f) {
        self.showToast('Filtered ' + f.colName + ' (' + count.toLocaleString() + '/' + fullTotal.toLocaleString() + ' rows)', 'success');
      }
    };
    vTable.enableRemote(cardId, total, function (req) {
      return sendToShiny('sideview_rows_request', req);
    });
  };

  /**
   * Synchronized vertical scroll handler for linked table pairs
   */
  SideviewEngine.prototype.setupScrollSync = function (cardMeta) {
    var self = this;
    var syncBtn = cardMeta.element.querySelector('[data-action="sync-scroll"]');
    var body = cardMeta.body;
    if (!body) return;

    if (syncBtn) {
      syncBtn.addEventListener('click', function () {
        if (self.syncScrollCards.has(cardMeta.id)) {
          self.syncScrollCards.delete(cardMeta.id);
          syncBtn.classList.remove('active');
        } else {
          self.syncScrollCards.add(cardMeta.id);
          syncBtn.classList.add('active');
        }
      });
    }

    body.addEventListener('scroll', function () {
      self.scheduleConnectorUpdate();
      if (self.isSyncingScroll || !self.syncScrollCards.has(cardMeta.id)) return;
      if (self.syncScrollCards.size < 2) return;

      // Vertical scroll ratio
      var maxScrollY = body.scrollHeight - body.clientHeight;
      var scrollRatioY = maxScrollY > 0 ? (body.scrollTop / maxScrollY) : 0;

      // Horizontal row/column scroll ratio
      var maxScrollX = body.scrollWidth - body.clientWidth;
      var scrollRatioX = maxScrollX > 0 ? (body.scrollLeft / maxScrollX) : 0;

      self.isSyncingScroll = true;
      self.syncScrollCards.forEach(function (otherId) {
        if (otherId === cardMeta.id) return;
        var other = self.cards.get(otherId);
        if (other && other.body) {
          // Synchronize vertical position
          if (maxScrollY > 0) {
            var otherMaxY = other.body.scrollHeight - other.body.clientHeight;
            if (otherMaxY > 0) {
              var targetTop = scrollRatioY * otherMaxY;
              if (Math.abs(other.body.scrollTop - targetTop) > 1) {
                other.body.scrollTop = targetTop;
              }
            }
          }
          // Synchronize horizontal row/column position
          if (maxScrollX > 0) {
            var otherMaxX = other.body.scrollWidth - other.body.clientWidth;
            if (otherMaxX > 0) {
              var targetLeft = scrollRatioX * otherMaxX;
              if (Math.abs(other.body.scrollLeft - targetLeft) > 1) {
                other.body.scrollLeft = targetLeft;
              }
            }
          }
        }
      });
      requestAnimationFrame(function () {
        self.isSyncingScroll = false;
      });
    });
  };

  /**
   * Field click-to-connect field mapping with SVG bezier curves
   */
  
  SideviewEngine.prototype.findPortElement = function (tableName, colName) {
    if (!tableName || !colName) return null;
    var card = this.container.querySelector('[data-card-name="' + cssEscape(tableName) + '"]') ||
               this.container.querySelector('[data-card-id="' + cssEscape(tableName) + '"]');
    if (!card) return null;
    return card.querySelector('.sideview-col-port[data-col-name="' + cssEscape(colName) + '"]');
  };

  SideviewEngine.prototype.requestSuggestedMappings = function (minConfidence) {
    sendToShiny('request_suggested_mappings', {
      min_confidence: typeof minConfidence === 'number' ? minConfidence : 0.70
    });
  };

  SideviewEngine.prototype.clearSuggestedSplines = function () {
    if (this.suggestedConnections && this.suggestedConnections.length > 0) {
      this.suggestedConnections.forEach(function (conn) {
        if (conn.path && conn.path.parentNode) {
          conn.path.parentNode.removeChild(conn.path);
        }
      });
    }
    this.suggestedConnections = [];
    if (this.svg) {
      var oldSuggested = this.svg.querySelectorAll('.sideview-spline-suggested');
      for (var i = 0; i < oldSuggested.length; i++) {
        if (oldSuggested[i].parentNode) oldSuggested[i].parentNode.removeChild(oldSuggested[i]);
      }
    }
    pruneHitPaths(this);
  };

  SideviewEngine.prototype.renderSuggestedSplines = function (suggestions) {
    var self = this;
    this.clearSuggestedSplines();
    if (!suggestions) return;

    var candidates = [];
    if (Array.isArray(suggestions)) {
      candidates = suggestions;
    } else if (suggestions && Array.isArray(suggestions.candidates)) {
      candidates = suggestions.candidates;
    } else if (suggestions && Array.isArray(suggestions.data)) {
      candidates = suggestions.data;
    }

    if (!candidates || candidates.length === 0) return;

    candidates.forEach(function (c) {
      var fromTable = c.from_table || c.fromTable || c.table1;
      var fromCol = c.from_col || c.fromCol || c.col1;
      var toTable = c.to_table || c.toTable || c.table2;
      var toCol = c.to_col || c.toCol || c.col2;
      var confidence = c.confidence !== undefined ? c.confidence : 0.8;
      var reason = c.reason || '';

      if (!fromTable || !fromCol || !toTable || !toCol) return;

      var alreadyConnected = self.connections.some(function (conn) {
        return (conn.fromTable === fromTable && conn.fromCol === fromCol &&
                conn.toTable === toTable && conn.toCol === toCol) ||
               (conn.fromTable === toTable && conn.fromCol === toCol &&
                conn.toTable === fromTable && conn.toCol === fromCol);
      });
      if (alreadyConnected) return;

      var p1 = self.findPortElement(fromTable, fromCol);
      var p2 = self.findPortElement(toTable, toCol);
      if (!p1 || !p2) return;

      var card1 = p1.closest('.sideview-card');
      var card2 = p2.closest('.sideview-card');
      var card1Id = card1 ? card1.dataset.cardId : fromTable;
      var card2Id = card2 ? card2.dataset.cardId : toTable;

      var path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      path.setAttribute('class', 'sideview-connector-path sideview-spline-suggested dashMove');
      path.dataset.suggested = 'true';
      path.dataset.fromTable = fromTable;
      path.dataset.fromCol = fromCol;
      path.dataset.toTable = toTable;
      path.dataset.toCol = toCol;
      path.dataset.confidence = String(confidence);

      var confPct = Math.round(confidence * 100);
      var titleEl = document.createElementNS('http://www.w3.org/2000/svg', 'title');
      titleEl.textContent = 'Suggested join: ' + fromTable + '.' + fromCol + ' ↔ ' + toTable + '.' + toCol +
        ' (' + confPct + '% confidence)' + (reason ? ' - ' + reason : '') + '\nClick to accept';
      path.appendChild(titleEl);

      path.addEventListener('click', function (e) {
        e.stopPropagation();
        e.preventDefault();

        if (path.parentNode) {
          path.parentNode.removeChild(path);
        }
        var sIdx = self.suggestedConnections.findIndex(function (s) { return s.path === path; });
        if (sIdx !== -1) {
          self.suggestedConnections.splice(sIdx, 1);
        }

        self.addConnection({
          fromCard: card1Id,
          fromTable: fromTable,
          fromCol: fromCol,
          fromElement: p1,
          toCard: card2Id,
          toTable: toTable,
          toCol: toCol,
          toElement: p2,
          type: 'left_join'
        });

        self.showToast('Accepted suggested mapping: ' + fromCol + ' ↔ ' + toCol + ' (' + confPct + '%)', 'success');
      });

      self.svg.appendChild(path);
      attachHitPath(self, path);

      self.suggestedConnections.push({
        path: path,
        fromTable: fromTable,
        fromCol: fromCol,
        fromElement: p1,
        toTable: toTable,
        toCol: toCol,
        toElement: p2,
        confidence: confidence,
        reason: reason
      });
    });

    self.updateConnectors();
  };

  SideviewEngine.prototype.addConnection = function (connData) {
    var self = this;
    this._connSeq = (this._connSeq || 0) + 1;
    var connId = 'conn_' + Date.now() + '_' + this._connSeq;

    var path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.setAttribute('class', 'sideview-connector-path');
    path.dataset.connId = connId;

    var titleEl = document.createElementNS('http://www.w3.org/2000/svg', 'title');
    titleEl.textContent = 'Click to disconnect ' + connData.fromCol + ' ↔ ' + connData.toCol;
    path.appendChild(titleEl);

    this.svg.appendChild(path);
    attachHitPath(this, path);

    var connection = Object.assign({ id: connId, path: path }, connData);
    this.connections.push(connection);

    this.updateConnectors();

    // Connections between the same two tables merge into one multi-key join,
    // and the join check then shows the newest join.
    this.joinCheckStepId = null;
    this.pipeline.addJoinKey(connData.fromTable, connData.toTable,
      connData.fromCol, connData.toCol, connData.type || 'left_join');

    sendToShiny('column_mapped', {
      from_table: connData.fromTable,
      from_col: connData.fromCol,
      to_table: connData.toTable,
      to_col: connData.toCol,
      join_type: connData.type || 'left_join'
    });
  };

  /**
   * Compute cubic bezier curve path string between two ports
   */
  /**
   * Remove a single connection by ID and update code
   */
  SideviewEngine.prototype.removeConnection = function (connId) {
    var self = this;
    var index = -1;
    for (var i = 0; i < this.connections.length; i++) {
      if (this.connections[i].id === connId) {
        index = i;
        break;
      }
    }
    if (index === -1) return;

    var conn = this.connections[index];
    if (conn.path && conn.path.parentNode) {
      conn.path.parentNode.removeChild(conn.path);
    }
    this.connections.splice(index, 1);
    pruneHitPaths(this);

    this.pipeline.removeJoinKey(conn.fromTable, conn.toTable, conn.fromCol, conn.toCol);

    this.showToast('Disconnected ' + conn.fromCol + ' ↔ ' + conn.toCol, 'info');
    sendToShiny('column_disconnected', {
      conn_id: connId,
      from_table: conn.fromTable,
      from_col: conn.fromCol,
      to_table: conn.toTable,
      to_col: conn.toCol,
      remaining_count: this.connections.length,
      code: this.generatedCode || ''
    });
  };

  SideviewEngine.prototype.getBezierPath = function (p1, p2) {
    var dir = p2.x >= p1.x ? 1 : -1;
    var dx = Math.max(40, Math.abs(p2.x - p1.x) * 0.45) * dir;
    return 'M ' + p1.x + ' ' + p1.y + ' C ' + (p1.x + dx) + ' ' + p1.y + ', ' +
      (p2.x - dx) + ' ' + p2.y + ', ' + p2.x + ' ' + p2.y;
  };

  /**
   * Redraw all SVG connector splines based on current port coordinates in viewport space
   */
  /**
   * Screen rect a spline should attach to for a port. Falls back to the card
   * header when the card is minimized, and clamps to the visible body when the
   * column is scrolled out of view horizontally.
   */
  SideviewEngine.prototype.portAnchorRect = function (portEl) {
    var r = portEl.getBoundingClientRect();
    var card = portEl.closest ? portEl.closest('.sideview-card') : null;
    if (!card) return r;
    var header = card.querySelector('.sideview-card-header');
    if (card.classList.contains('is-minimized') || (r.width === 0 && r.height === 0)) {
      return header ? header.getBoundingClientRect() : card.getBoundingClientRect();
    }
    var body = card.querySelector('.sideview-card-body');
    if (body) {
      var b = body.getBoundingClientRect();
      if (b.width > 0) {
        var cx = Math.min(Math.max(r.left + r.width / 2, b.left), b.right);
        var cy = Math.min(Math.max(r.top + r.height / 2, b.top), b.bottom);
        return { left: cx - r.width / 2, top: cy - r.height / 2, width: r.width, height: r.height };
      }
    }
    return r;
  };

  SideviewEngine.prototype.updateConnectors = function () {
    var self = this;
    var viewportRect = this.viewport.getBoundingClientRect();
    var scale = this.panzoom ? this.panzoom.getScale() : 1;

    var allConns = (this.connections || []).concat(this.suggestedConnections || []);
    allConns.forEach(function (conn) {
      if (!conn.fromElement || !conn.toElement || !conn.path) return;

      var r1 = self.portAnchorRect(conn.fromElement);
      var r2 = self.portAnchorRect(conn.toElement);

      var p1 = {
        x: (r1.left + r1.width / 2 - viewportRect.left) / scale,
        y: (r1.top + r1.height / 2 - viewportRect.top) / scale
      };

      var p2 = {
        x: (r2.left + r2.width / 2 - viewportRect.left) / scale,
        y: (r2.top + r2.height / 2 - viewportRect.top) / scale
      };

      var d = self.getBezierPath(p1, p2);
      conn.path.setAttribute('d', d);
      if (conn.path._svHit) conn.path._svHit.setAttribute('d', d);
    });
    pruneHitPaths(this);
  };

  // Legacy entry points: both now act on the pipeline (and are undoable).
  SideviewEngine.prototype.resetDrawerCode = function () {
    this.pipeline.clear();
  };

  SideviewEngine.prototype.updateDrawerCode = function (code, label) {
    if (isNoCode(code)) return this.resetDrawerCode();
    this.pipeline.replaceWithCode(String(code).trim(), label);
  };

  /**
   * Display a status toast banner
   */
  /**
   * Check if auto-clear checkbox is checked
   */
  SideviewEngine.prototype.shouldAutoClear = function () {
    var toggle = this.container.querySelector('.sideview-autoclear-toggle');
    return toggle ? toggle.checked : false;
  };

  /**
   * Clear all active operations, connector curves, port selections, and generated code
   */
  SideviewEngine.prototype.clearOperations = function (silent) {
    var self = this;

    // 0. Remove suggested splines and reset suggested connections
    this.clearSuggestedSplines();
    if (this.cleanupDraft) this.cleanupDraft();

    // 1. Remove all SVG connector paths from the DOM
    if (this.connections && this.connections.length > 0) {
      this.connections.forEach(function (conn) {
        if (conn.path && conn.path.parentNode) {
          conn.path.parentNode.removeChild(conn.path);
        }
      });
    }
    this.connections = [];

    if (this.svg) {
      var extraPaths = this.svg.querySelectorAll('.sideview-connector-path');
      extraPaths.forEach(function (p) { p.remove(); });
    }
    pruneHitPaths(this);

    // 2. Clear port selections
    if (this.activePort) {
      if (this.activePort.element) {
        this.activePort.element.classList.remove('connecting', 'active', 'selected');
      }
      this.activePort = null;
    }
    if (this.selectedPort) {
      this.selectedPort.classList.remove('active', 'selected', 'connecting');
      this.selectedPort = null;
    }
    var activePorts = this.container.querySelectorAll('.sideview-col-port.active, .sideview-col-port.selected, .sideview-col-port.connecting');
    activePorts.forEach(function (p) { p.classList.remove('active', 'selected', 'connecting'); });

    // Reset all VirtualTable instances
    this.cards.forEach(function (card) {
      var vt = card.virtualTable || (card.element ? card.element._virtualTable : null);
      if (vt) {
        vt.clearFilter();
        vt.sort(-1, null, 'none');
        vt.clearHighlights();
      }
    });

    // 2b. Reset all column sort indicators and row filters
    this.closeActivePopover();
    this.container.querySelectorAll('.sideview-row-filtered').forEach(function (r) {
      r.classList.remove('sideview-row-filtered');
    });
    this.container.querySelectorAll('.sideview-sort-btn').forEach(function (b) {
      setIcon(b, 'sort');
      b.classList.remove('active');
    });
    this.container.querySelectorAll('.sideview-filter-btn').forEach(function (b) {
      b.classList.remove('active');
    });
    this.container.querySelectorAll('thead th').forEach(function (th) {
      th.dataset.sortState = 'none';
    });

    // 3. Clear discrepancy highlighting
    var discCells = this.container.querySelectorAll('.sideview-discrepancy-fuzzy, .sideview-discrepancy-diff');
    discCells.forEach(function (c) {
      c.classList.remove('sideview-discrepancy-fuzzy', 'sideview-discrepancy-diff');
    });

    // 4. Reset generated code and drawer UI
    this.resetDrawerCode();

    // 5. Notify user if not silent
    if (!silent) {
      this.showToast('Tidyverse operations and connectors cleared.', 'info');
    }
    sendToShiny('clear_operations', { timestamp: Date.now() });
  };

  // ---- drawer: tabs, pipeline view, builders --------------------------------
  // The tab strip and pane containers are owned here so the server-rendered
  // gadget markup and the widget markup cannot drift apart.
  var DRAWER_TABS = [
    { id: 'pipeline', label: 'Pipeline' },
    { id: 'filter', label: 'Filter' },
    { id: 'arrange', label: 'Arrange' },
    { id: 'mutate', label: 'Mutate' },
    { id: 'recode', label: 'Recode' },
    { id: 'summarise', label: 'Summarise' },
    { id: 'inspect', label: 'Inspect' },
    { id: 'discrepancy', label: 'Discrepancy' },
    { id: 'chat', label: 'Copilot' }
  ];
  var BUILDER_TABS = { filter: 1, arrange: 1, mutate: 1, recode: 1, summarise: 1 };
  var TAB_ALIASES = { join: 'pipeline', copilot: 'chat' };

  function arrangeKey(table) { return JSON.stringify(['arrange', table]); }
  function headerFilterKey(table) { return JSON.stringify(['header-filter', table]); }

  SideviewEngine.prototype.ensureDrawer = function () {
    var drawer = this.container.querySelector('.sideview-drawer');
    if (!drawer) return;
    var tabs = drawer.querySelector('.sideview-drawer-tabs');
    if (tabs) {
      tabs.setAttribute('role', 'tablist');
      tabs.innerHTML = DRAWER_TABS.map(function (t, i) {
        return '<button type="button" class="sideview-drawer-tab' + (i === 0 ? ' active' : '') +
          '" data-tab="' + t.id + '" role="tab" aria-selected="' + (i === 0) + '">' + t.label + '</button>';
      }).join('');
    }
    var content = drawer.querySelector('.sideview-drawer-content');
    if (!content) return;
    DRAWER_TABS.forEach(function (t) {
      if (content.querySelector('[data-pane="' + t.id + '"]')) return;
      var pane = document.createElement('div');
      pane.className = 'sideview-tab-pane sideview-' + t.id + '-pane' + (BUILDER_TABS[t.id] ? ' sideview-builder-pane' : '');
      pane.dataset.pane = t.id;
      pane.style.display = 'none';
      content.appendChild(pane);
    });
    var pp = content.querySelector('[data-pane="pipeline"]');
    if (pp && !pp.querySelector('.sideview-step-list')) {
      var desc = pp.querySelector('.sideview-drawer-desc');
      if (desc) desc.remove();
      var bar = document.createElement('div');
      bar.className = 'sideview-pipeline-bar';
      bar.innerHTML = [
        '<button type="button" class="sideview-icon-btn" data-action="pipeline-undo" title="Undo (Ctrl+Z)" aria-label="Undo">' + icon('undo') + '</button>',
        '<button type="button" class="sideview-icon-btn" data-action="pipeline-redo" title="Redo (Ctrl+Y)" aria-label="Redo">' + icon('redo') + '</button>',
        '<label class="sideview-pipe-choice">Pipe <select class="sideview-pipe-select" aria-label="Pipe operator">',
        '<option value="%&gt;%">%&gt;%</option><option value="|&gt;">|&gt;</option></select></label>',
        '<span class="sideview-step-count" aria-live="polite"></span>'
      ].join('');
      var list = document.createElement('ol');
      list.className = 'sideview-step-list';
      list.setAttribute('aria-label', 'Pipeline steps');
      pp.insertBefore(list, pp.firstChild);
      pp.insertBefore(bar, list);
    }
  };

  SideviewEngine.prototype.activateDrawerTab = function (tabName) {
    tabName = TAB_ALIASES[tabName] || tabName;
    this.activeDrawerTab = tabName;
    this.container.querySelectorAll('.sideview-drawer-tab').forEach(function (t) {
      var on = t.dataset.tab === tabName;
      t.classList.toggle('active', on);
      t.setAttribute('aria-selected', on ? 'true' : 'false');
    });
    this.container.querySelectorAll('.sideview-drawer-content > .sideview-tab-pane').forEach(function (p) {
      var on = p.dataset.pane === tabName;
      p.style.display = on ? (tabName === 'chat' ? 'flex' : '') : 'none';
    });
    if (BUILDER_TABS[tabName]) this.renderBuilder(tabName);
    if (tabName === 'inspect') this.renderInspector();
  };

  SideviewEngine.prototype.recordSort = function (table, col, direction) {
    if (direction === 'none') {
      this.pipeline.removeKey(arrangeKey(table), 'arrange');
    } else {
      this.pipeline.add({
        kind: 'arrange', key: arrangeKey(table), table: table,
        cols: [{ col: col, desc: direction === 'desc' }], source: 'header'
      }, 'arrange');
    }
    return this.generatedCode;
  };

  SideviewEngine.prototype.undoPipeline = function () {
    if (this.pipeline.undo()) this.showToast('Undid last pipeline change', 'info');
  };

  SideviewEngine.prototype.redoPipeline = function () {
    if (this.pipeline.redo()) this.showToast('Redid pipeline change', 'info');
  };

  SideviewEngine.prototype.renderPipeline = function () {
    var self = this;
    var P = global.SideviewPipeline;
    var p = this.pipeline;
    var code = p.compose();
    this.generatedCode = code;
    var codeText = this.container.querySelector('.sideview-code-text');
    if (codeText) codeText.textContent = code || CODE_PLACEHOLDER;

    var n = p.steps.length;
    var list = this.container.querySelector('.sideview-step-list');
    if (list) {
      if (!n) {
        list.innerHTML = '<li class="sideview-step-empty">No steps yet. Connect two columns, ' +
          'sort or filter from a header, or add a step from the builder tabs.</li>';
      } else {
        list.innerHTML = p.steps.map(function (s, i) {
          var on = s.enabled !== false;
          var label = P.describe(s);
          var title = s.kind === 'custom' ? String(s.code || '').split('\n')[0] : label;
          var join = '';
          var diag = '';
          if (s.kind === 'join') {
            join = '<select class="sideview-step-jointype" aria-label="Join type">' +
              P.JOIN_TYPES.map(function (j) {
                return '<option value="' + j + '"' + (j === s.type ? ' selected' : '') + '>' + j.replace('_join', '') + '</option>';
              }).join('') + '</select>';
            diag = self.joinDiagLine(s);
          }
          return '<li class="sideview-step' + (on ? '' : ' is-disabled') + (diag ? ' has-diag' : '') +
            '" data-step-id="' + escapeHtml(s.id) + '">' +
            '<input type="checkbox" class="sideview-step-toggle"' + (on ? ' checked' : '') +
            ' aria-label="Include step ' + (i + 1) + '" />' +
            '<span class="sideview-step-text" title="' + escapeHtml(title) + '">' +
            '<span class="sideview-step-table">' + escapeHtml(s.table || 'code') + '</span> ' +
            escapeHtml(label) + '</span>' + join +
            '<button type="button" class="sideview-icon-btn" data-step-action="up" aria-label="Move step up"' +
            (i === 0 ? ' disabled' : '') + '>' + icon('chevronUp') + '</button>' +
            '<button type="button" class="sideview-icon-btn" data-step-action="down" aria-label="Move step down"' +
            (i === n - 1 ? ' disabled' : '') + '>' + icon('chevronDown') + '</button>' +
            '<button type="button" class="sideview-icon-btn" data-step-action="delete" aria-label="Delete step">' +
            icon('trash') + '</button>' + diag + '</li>';
        }).join('');
      }
    }
    var count = this.container.querySelector('.sideview-step-count');
    if (count) count.textContent = n === 1 ? '1 step' : n + ' steps';
    var undo = this.container.querySelector('[data-action="pipeline-undo"]');
    if (undo) undo.disabled = !p.canUndo();
    var redo = this.container.querySelector('[data-action="pipeline-redo"]');
    if (redo) redo.disabled = !p.canRedo();
    var pipeSel = this.container.querySelector('.sideview-pipe-select');
    if (pipeSel) pipeSel.value = p.pipe;
    if (this.activeDrawerTab === 'discrepancy') this.renderJoinCheck();

    // The drawer no longer pops open; the Drawer button shows the step count.
    var btn = this.container.querySelector('[data-action="toggle-drawer"]');
    if (btn && btn.classList) {
      var badge = btn.querySelector('.sideview-step-badge');
      if (!badge) {
        badge = document.createElement('span');
        badge.className = 'sideview-step-badge';
        btn.appendChild(badge);
      }
      badge.textContent = n ? String(n) : '';
      btn.classList.toggle('has-code', n > 0);
      btn.setAttribute('aria-label', n ? 'Drawer (' + n + ' pipeline step' + (n === 1 ? '' : 's') + ')' : 'Drawer');
    }
  };

  // Tables and columns currently on the canvas, for the builder selects.
  // ---- join diagnostics ------------------------------------------------------
  // Every join step gets a key check. The gadget asks R, which has the full
  // data (input `join_diagnostics_request` -> message `sideview_join_diagnostics`);
  // the htmlwidget holds the full data and computes it in the browser.

  SideviewEngine.prototype.joinDiagSig = function (s) {
    return JSON.stringify([s.table, s.right, (s.by || []).map(function (p) { return [p.left, p.right]; })]);
  };

  SideviewEngine.prototype.joinDiagFor = function (s) {
    var sig = this.joinDiagSig(s);
    if (this.joinDiag[sig]) return this.joinDiag[sig];
    if (this.joinDiagPending[sig]) return null;
    var req = {
      id: sig, left: s.table, right: s.right,
      by: (s.by || []).map(function (p) { return { left: p.left, right: p.right }; })
    };
    if (this.options.mode !== 'embedded' && typeof global.Shiny !== 'undefined') {
      this.joinDiagPending[sig] = true;
      this.requestJoinDiag(req, 0);
      return null;
    }
    var d = this.localJoinDiagnostics(req);
    d.id = sig;
    this.joinDiag[sig] = d;
    this.announceJoinDiag(d, s);
    return d;
  };

  // Shiny.setInputValue appears only once the session connects; retry until then.
  SideviewEngine.prototype.requestJoinDiag = function (req, attempt) {
    var self = this;
    if (sendToShiny('join_diagnostics_request', req)) return;
    if (attempt >= 40 || !this.container.isConnected) {
      delete this.joinDiagPending[req.id];
      this.joinDiag[req.id] = { id: req.id, error: 'The R session did not answer.' };
      this.renderPipeline();
      return;
    }
    setTimeout(function () { self.requestJoinDiag(req, attempt + 1); }, 250);
  };

  // Key columns of a card as arrays (the widget has every row in the browser).
  SideviewEngine.prototype.cardColumns = function (name, cols) {
    var el = this.container.querySelector('.sideview-card[data-card-name="' + cssEscape(name) + '"]');
    var vt = el && el._virtualTable;
    if (!vt) return { error: 'Table ' + name + ' is not on the canvas.' };
    var out = {};
    for (var k = 0; k < cols.length; k++) {
      var c = cols[k];
      var idx = vt.colNames.indexOf(c);
      if (idx < 0) return { error: 'Column ' + c + ' is not in ' + name + '.' };
      var vals = new Array(vt.totalRows);
      for (var i = 0; i < vt.totalRows; i++) vals[i] = vt.getCellValue(i, c, idx);
      out[c] = vals;
    }
    return { cols: out, types: vt.colTypes || {} };
  };

  SideviewEngine.prototype.localJoinDiagnostics = function (req) {
    var x = this.cardColumns(req.left, req.by.map(function (p) { return p.left; }));
    var y = this.cardColumns(req.right, req.by.map(function (p) { return p.right; }));
    if (x.error || y.error) return { error: x.error || y.error };
    return global.SideviewPipeline.joinDiagnostics(x.cols, y.cols, req.by, {
      xName: req.left, yName: req.right, xTypes: x.types, yTypes: y.types
    });
  };

  SideviewEngine.prototype.onJoinDiagnostics = function (data) {
    if (!data || !data.id) return;
    delete this.joinDiagPending[data.id];
    ['by', 'unmatched_x', 'unmatched_y', 'type_issues', 'warnings', 'hints'].forEach(function (k) {
      data[k] = asArray(data[k]);
    });
    this.joinDiag[data.id] = data;
    var step = this.pipeline.steps.filter(function (s) { return s.kind === 'join'; })
      .filter(function (s) { return this.joinDiagSig(s) === data.id; }, this)[0];
    this.announceJoinDiag(data, step);
    this.renderPipeline();
    this.renderJoinCheck();
  };

  // A toast for a risky join, once per set of keys.
  SideviewEngine.prototype.announceJoinDiag = function (d, step) {
    if (!d || d.error || d.status === 'ok') return;
    var msg = (d.type_issues && d.type_issues[0]) || (d.warnings && d.warnings[0]);
    if (!msg) return;
    var pair = step ? step.table + ' → ' + step.right + ': ' : '';
    this.showToast(pair + msg, d.status === 'error' ? 'danger' : 'warning');
  };

  SideviewEngine.prototype.joinDiagLine = function (s) {
    var d = this.joinDiagFor(s);
    if (!d) return '<span class="sideview-step-diag is-pending">Checking keys…</span>';
    if (d.error) {
      return '<span class="sideview-step-diag is-pending" title="' + escapeHtml(d.error) + '">Key check unavailable</span>';
    }
    var text = global.SideviewPipeline.describeDiagnostics(d, s.type, s.table);
    if (d.status === 'error') text = 'Key types differ · ' + text;
    return '<button type="button" class="sideview-step-diag is-' + d.status + '" data-step-action="diag"' +
      ' title="Show the join check">' + icon(d.status === 'ok' ? 'check' : 'alert') +
      '<span>' + escapeHtml(text) + '</span></button>';
  };

  SideviewEngine.prototype.showJoinCheck = function (stepId) {
    this.joinCheckStepId = stepId;
    this.activateDrawerTab('discrepancy');
    this.renderJoinCheck();
    var s = this.pipeline.find(stepId);
    if (s && s.by && s.by.length) {
      sendToShiny('discrepancy_check', {
        table1: s.table, col1: s.by[0].left, table2: s.right, col2: s.by[0].right
      });
    }
  };

  /** Full join report at the top of the Discrepancy tab (selected or last join). */
  SideviewEngine.prototype.renderJoinCheck = function () {
    var box = this.container.querySelector('.sideview-joincheck');
    if (!box) return;
    var self = this;
    var joins = this.pipeline.steps.filter(function (s) { return s.kind === 'join'; });
    var s = joins.filter(function (j) { return j.id === self.joinCheckStepId; })[0] || joins[joins.length - 1];
    box.className = 'sideview-joincheck';
    if (!s) { box.innerHTML = ''; return; }
    var d = this.joinDiagFor(s);
    var esc = escapeHtml;
    if (!d) {
      box.innerHTML = '<p class="sideview-joincheck-title">Checking keys for ' + esc(s.table) + ' and ' + esc(s.right) + '…</p>';
      return;
    }
    if (d.error) {
      box.innerHTML = '<p class="sideview-joincheck-title">Join check unavailable</p><p>' + esc(d.error) + '</p>';
      return;
    }
    box.classList.add('is-' + d.status);
    var fmt = function (n) { return Number(n).toLocaleString('en-US'); };
    var pct = function (p) { return (100 * p).toFixed(1) + '%'; };
    var by = d.by.map(function (p) { return p.left === p.right ? p.left : p.left + ' = ' + p.right; }).join(', ');
    var list = function (items, cls) {
      return items.length ? '<ul class="sideview-joincheck-list ' + cls + '">' +
        items.map(function (t) { return '<li>' + esc(t) + '</li>'; }).join('') + '</ul>' : '';
    };
    var keys = function (vals) {
      return vals.map(function (v) { return '<code>' + esc(v) + '</code>'; }).join(', ');
    };
    var hints = d.hints.map(function (h) {
      var gain = [];
      if (h.extra_x > 0) gain.push(fmt(h.extra_x) + ' more ' + s.table + ' rows');
      if (h.extra_y > 0) gain.push(fmt(h.extra_y) + ' more ' + s.right + ' rows');
      return h.label + ' would match ' + gain.join(' and ') + '.';
    });
    var html = [
      '<p class="sideview-joincheck-title">Join check: <code>' + esc(s.table) + '</code> → <code>' +
        esc(s.right) + '</code> by <code>' + esc(by) + '</code></p>',
      list(d.type_issues, 'sideview-joincheck-errors'),
      list(d.warnings, 'sideview-joincheck-warnings'),
      '<dl class="sideview-joincheck-stats">',
      '<dt>Relationship</dt><dd>' + esc(d.relationship) + '</dd>',
      '<dt>' + esc(s.table) + ' rows matched</dt><dd>' + fmt(d.matched_x) + ' of ' + fmt(d.n_x) + ' (' + pct(d.match_rate_x) + ')</dd>',
      '<dt>' + esc(s.right) + ' rows matched</dt><dd>' + fmt(d.matched_y) + ' of ' + fmt(d.n_y) + ' (' + pct(d.match_rate_y) + ')</dd>',
      '<dt>Distinct keys</dt><dd>' + fmt(d.distinct_x) + ' / ' + fmt(d.distinct_y) + ' (' + fmt(d.distinct_matched) + ' shared)</dd>',
      '<dt>Repeated keys</dt><dd>' + fmt(d.dup_keys_x) + ' / ' + fmt(d.dup_keys_y) + '</dd>',
      '<dt>Missing keys</dt><dd>' + fmt(d.na_x) + ' / ' + fmt(d.na_y) + ' rows</dd>',
      '</dl>',
      '<table class="sideview-joincheck-rows"><thead><tr><th scope="col">Join type</th><th scope="col">Rows</th></tr></thead><tbody>',
      global.SideviewPipeline.JOIN_TYPES.map(function (j) {
        return '<tr' + (j === s.type ? ' class="is-current"' : '') + '><td>' + j + '</td><td>' + fmt(d.rows[j]) + '</td></tr>';
      }).join(''),
      '</tbody></table>',
      d.unmatched_x.length ? '<p>Not in ' + esc(s.right) + ': ' + keys(d.unmatched_x) + '</p>' : '',
      d.unmatched_y.length ? '<p>Not in ' + esc(s.table) + ': ' + keys(d.unmatched_y) + '</p>' : '',
      hints.length ? '<p>Possible fixes:</p>' + list(hints, 'sideview-joincheck-hints') : ''
    ];
    box.innerHTML = html.join('');
  };

  SideviewEngine.prototype.tableSchemas = function () {
    var out = [];
    this.cards.forEach(function (card) {
      var el = card.element;
      if (!el) return;
      var cols = [];
      el.querySelectorAll('thead th[data-col-name]').forEach(function (th) {
        cols.push({ name: th.dataset.colName, type: th.dataset.colType || '' });
      });
      out.push({ name: card.name || el.dataset.cardName, columns: cols });
    });
    return out;
  };

  function optionList(values, selected) {
    return values.map(function (v) {
      var val = typeof v === 'object' ? v.value : v;
      var lab = typeof v === 'object' ? v.label : v;
      return '<option value="' + escapeHtml(val) + '"' + (val === selected ? ' selected' : '') + '>' +
        escapeHtml(lab) + '</option>';
    }).join('');
  }

  var FILTER_OPS = [
    { value: 'equals', label: '==' }, { value: 'not_equals', label: '!=' },
    { value: 'gt', label: '>' }, { value: 'gte', label: '>=' },
    { value: 'lt', label: '<' }, { value: 'lte', label: '<=' },
    { value: 'in', label: 'in (a, b, ...)' }, { value: 'contains', label: 'contains' },
    { value: 'is_na', label: 'is missing' }, { value: 'not_na', label: 'is not missing' }
  ];
  var AGG_CHOICES = [
    { value: 'n', label: 'count rows' }, { value: 'n_distinct', label: 'distinct' },
    { value: 'mean', label: 'mean' }, { value: 'median', label: 'median' },
    { value: 'sd', label: 'sd' }, { value: 'min', label: 'min' }, { value: 'max', label: 'max' },
    { value: 'sum', label: 'sum' }
  ];

  SideviewEngine.prototype.builderRow = function (kind, cols) {
    var names = cols.map(function (c) { return c.name; });
    var remove = '<button type="button" class="sideview-icon-btn" data-builder-action="remove-row" aria-label="Remove row">' +
      icon('close') + '</button>';
    if (kind === 'filter') {
      return '<div class="sideview-builder-row">' +
        '<select data-field="col" aria-label="Column">' + optionList(names) + '</select>' +
        '<select data-field="op" aria-label="Operator">' + optionList(FILTER_OPS) + '</select>' +
        '<input type="text" data-field="val" placeholder="value" aria-label="Value" />' + remove + '</div>';
    }
    if (kind === 'arrange') {
      return '<div class="sideview-builder-row">' +
        '<select data-field="col" aria-label="Column">' + optionList(names) + '</select>' +
        '<select data-field="dir" aria-label="Direction">' +
        optionList([{ value: 'asc', label: 'ascending' }, { value: 'desc', label: 'descending' }]) + '</select>' +
        remove + '</div>';
    }
    if (kind === 'summarise') {
      return '<div class="sideview-builder-row">' +
        '<select data-field="fn" aria-label="Summary">' + optionList(AGG_CHOICES) + '</select>' +
        '<select data-field="col" aria-label="Column">' + optionList(names) + '</select>' +
        '<input type="text" data-field="name" placeholder="name (optional)" aria-label="Result name" />' +
        remove + '</div>';
    }
    return '';
  };

  // ---- column inspector ------------------------------------------------------
  // The Inspect tab profiles one column. The gadget asks R, which has the full
  // data (input `column_profile_request` -> message `sideview_column_profile`);
  // the htmlwidget computes it in the browser with SideviewPipeline.columnProfile().

  SideviewEngine.prototype.inspectColumn = function (table, column) {
    this.inspectTarget = { table: table, column: column };
    var drawer = this.container.querySelector('.sideview-drawer');
    if (drawer) drawer.classList.remove('collapsed');
    this.activateDrawerTab('inspect');
  };

  /** Send an input that only the gadget's R session handles; warn (never claim success) without one. */
  SideviewEngine.prototype.sendToR = function (name, value, label) {
    if (this.isGadget() && sendToShiny(name, value)) return true;
    this.showToast(label + ' needs the R session (run sideview() from R). Use Copy instead.', 'warning');
    return false;
  };

  SideviewEngine.prototype.isGadget = function () {
    return this.options.mode !== 'embedded' && typeof global.Shiny !== 'undefined';
  };

  SideviewEngine.prototype.columnProfileFor = function (table, column) {
    var sig = JSON.stringify([table, column]);
    if (this.colProfiles[sig]) return this.colProfiles[sig];
    if (this.colProfilePending[sig]) return null;
    if (this.isGadget()) {
      this.colProfilePending[sig] = true;
      this.requestColumnProfile({ id: sig, table: table, column: column }, 0);
      return null;
    }
    var x = this.cardColumns(table, [column]);
    var p = x.error ? { error: x.error } :
      global.SideviewPipeline.columnProfile(x.cols[column], x.types[column], { label: this.columnLabel(table, column) });
    this.colProfiles[sig] = p;
    return p;
  };

  SideviewEngine.prototype.requestColumnProfile = function (req, attempt) {
    var self = this;
    if (sendToShiny('column_profile_request', req)) return;
    if (attempt >= 40 || !this.container.isConnected) {
      delete this.colProfilePending[req.id];
      this.colProfiles[req.id] = { error: 'The R session did not answer.' };
      this.renderInspector();
      return;
    }
    setTimeout(function () { self.requestColumnProfile(req, attempt + 1); }, 250);
  };

  SideviewEngine.prototype.onColumnProfile = function (data) {
    if (!data || !data.id) return;
    delete this.colProfilePending[data.id];
    data.top = asArray(data.top);
    data.issues = asArray(data.issues);
    if (data.histogram) {
      data.histogram.counts = asArray(data.histogram.counts);
      data.histogram.breaks = asArray(data.histogram.breaks);
    }
    this.colProfiles[data.id] = data;
    var t = this.inspectTarget;
    if (t && JSON.stringify([t.table, t.column]) === data.id) this.renderInspector();
  };

  // Variable label from R (haven/labelled `label` attribute), sent with widget cards.
  SideviewEngine.prototype.columnLabel = function (table, column) {
    var labels = null;
    this.cards.forEach(function (c) { if (c.name === table) labels = c.colLabels; });
    return labels && labels[column] ? String(labels[column]) : null;
  };

  SideviewEngine.prototype.renderInspector = function () {
    var pane = this.container.querySelector('.sideview-drawer-content > [data-pane="inspect"]');
    if (!pane) return;
    var schemas = this.tableSchemas().filter(function (t) { return t.columns.length; });
    if (!schemas.length) {
      pane.innerHTML = '<p class="sideview-drawer-desc">Add a table to the canvas to inspect its columns.</p>';
      return;
    }
    var t = this.inspectTarget || {};
    var schema = schemas.filter(function (s) { return s.name === t.table; })[0] || schemas[0];
    var names = schema.columns.map(function (c) { return c.name; });
    var column = names.indexOf(t.column) >= 0 ? t.column : names[0];
    this.inspectTarget = { table: schema.name, column: column };
    var p = this.columnProfileFor(schema.name, column);
    var body;
    if (!p) body = '<p class="sideview-drawer-desc">Profiling ' + escapeHtml(column) + '…</p>';
    else if (p.error) body = '<p class="sideview-drawer-desc">' + escapeHtml(p.error) + '</p>';
    else body = this.profileHtml(column, p);
    pane.innerHTML = '<div class="sideview-inspector">' +
      '<div class="sideview-inspect-pick">' +
      '<label class="sideview-builder-field">Table <select data-inspect="table">' +
      optionList(schemas.map(function (s) { return s.name; }), schema.name) + '</select></label>' +
      '<label class="sideview-builder-field">Column <select data-inspect="column">' +
      optionList(names, column) + '</select></label></div>' +
      '<div class="sideview-inspect-body" aria-live="polite">' + body + '</div>' +
      '<div class="sideview-builder-actions">' +
      '<button type="button" class="sideview-btn" data-action="export-codebook" title="One row per column of every table, as CSV">' +
      icon('download') + ' Export codebook</button></div></div>';
  };

  function fmtNum(v) {
    if (v === null || v === undefined || v === '') return '–';
    if (typeof v !== 'number') return String(v);
    if (!isFinite(v)) return String(v);
    var a = Math.abs(v);
    if (a !== 0 && (a >= 1e9 || a < 1e-3)) return v.toPrecision(4);
    return Number(v.toPrecision(6)).toLocaleString('en-US', { maximumFractionDigits: 6 });
  }

  SideviewEngine.prototype.profileHtml = function (column, p) {
    var esc = escapeHtml;
    var fmt = function (n) { return Number(n).toLocaleString('en-US'); };
    var rows = [
      ['Rows', fmt(p.n)],
      ['Missing', fmt(p.n_missing) + ' (' + (100 * p.pct_missing).toFixed(1) + '%)'],
      ['Distinct', fmt(p.n_distinct)],
      ['Unique key', p.unique_key ? 'Yes' : 'No']
    ];
    var st = p.stats;
    if (st) {
      if (p.kind === 'numeric') {
        rows.push(['Min', fmtNum(st.min)], ['Q1', fmtNum(st.q1)], ['Median', fmtNum(st.median)],
          ['Q3', fmtNum(st.q3)], ['Max', fmtNum(st.max)], ['IQR', fmtNum(st.q3 - st.q1)],
          ['Mean', fmtNum(st.mean)], ['SD', fmtNum(st.sd)]);
      } else {
        rows.push(['Earliest', esc(st.min)], ['Median', esc(st.median)], ['Latest', esc(st.max)]);
      }
    }
    var html = '<div class="sideview-inspect-head"><span class="sideview-inspect-name">' + esc(column) + '</span>' +
      '<span class="sideview-inspect-kind">' + esc(p['class'] || p.kind) + '</span></div>';
    if (p.label) html += '<p class="sideview-inspect-label">' + esc(p.label) + '</p>';
    html += '<dl class="sideview-inspect-stats">' + rows.map(function (r) {
      return '<div><dt>' + r[0] + '</dt><dd>' + r[1] + '</dd></div>';
    }).join('') + '</dl>';
    if (p.histogram && p.histogram.counts.length) html += this.histogramSvg(p.histogram);
    if (p.top && p.top.length) {
      var max = Math.max.apply(null, p.top.map(function (t) { return t.n; }));
      html += '<p class="sideview-inspect-section">Most common values</p><ul class="sideview-inspect-top">' +
        p.top.map(function (t) {
          var shown = t.value === '' ? '<em>(empty string)</em>' : esc(t.value);
          var pct = p.n ? (100 * t.n / p.n).toFixed(1) + '%' : '';
          return '<li><span class="sideview-inspect-value">' + shown + '</span>' +
            '<span class="sideview-inspect-track"><span class="sideview-inspect-fill" style="width:' +
            (100 * t.n / max).toFixed(1) + '%"></span></span>' +
            '<span class="sideview-inspect-n">' + fmt(t.n) + ' <span class="sideview-inspect-pct">' + pct + '</span></span></li>';
        }).join('') + '</ul>';
      if (p.n_other > 0) html += '<p class="sideview-builder-hint">and ' + fmt(p.n_other) + ' more distinct values</p>';
    }
    var issues = p.issues || [];
    html += '<p class="sideview-inspect-section">Checks</p>';
    html += issues.length ?
      '<ul class="sideview-inspect-issues">' + issues.map(function (i) {
        return '<li>' + icon('alert') + '<span>' + esc(i) + '</span></li>';
      }).join('') + '</ul>' :
      '<p class="sideview-inspect-ok">' + icon('check') + '<span>No problems found.</span></p>';
    return html;
  };

  SideviewEngine.prototype.histogramSvg = function (h) {
    var W = 300, H = 72, counts = h.counts, n = counts.length;
    var max = Math.max.apply(null, counts) || 1;
    var bw = W / n, bars = '';
    for (var i = 0; i < n; i++) {
      var bh = counts[i] ? Math.max(1, Math.round(H * counts[i] / max)) : 0;
      var lo = h.breaks[i], hi = h.breaks[Math.min(i + 1, h.breaks.length - 1)];
      bars += '<rect class="sideview-inspect-bar" x="' + (i * bw + 0.5).toFixed(2) + '" y="' + (H - bh) +
        '" width="' + Math.max(1, bw - 1).toFixed(2) + '" height="' + bh + '"><title>' +
        escapeHtml(fmtNum(lo) + ' to ' + fmtNum(hi) + ': ' + counts[i]) + '</title></rect>';
    }
    return '<figure class="sideview-inspect-hist">' +
      '<svg viewBox="0 0 ' + W + ' ' + H + '" preserveAspectRatio="none" role="img" aria-label="Histogram of ' +
      n + ' bins">' + bars + '</svg>' +
      '<figcaption><span>' + escapeHtml(fmtNum(h.breaks[0])) + '</span><span>' +
      escapeHtml(fmtNum(h.breaks[h.breaks.length - 1])) + '</span></figcaption></figure>';
  };

  /** Export codebook: R writes the file in the gadget; the widget downloads a CSV. */
  SideviewEngine.prototype.exportCodebook = function () {
    if (this.isGadget()) {
      if (!sendToShiny('codebook_export', Date.now())) this.showToast('The R session is not connected.', 'warning');
      return;
    }
    var P = global.SideviewPipeline, self = this, rows = [];
    this.tableSchemas().forEach(function (s) {
      var x = self.cardColumns(s.name, s.columns.map(function (c) { return c.name; }));
      if (x.error) return;
      s.columns.forEach(function (c, j) {
        rows.push(P.codebookRow(s.name, c.name, j + 1, x.cols[c.name], x.types[c.name] || c.type,
          { label: self.columnLabel(s.name, c.name) }));
      });
    });
    if (!rows.length) { this.showToast('No tables to describe.', 'warning'); return; }
    var csv = P.codebookCsv(rows);
    this.lastCodebookCsv = csv;
    try {
      var url = URL.createObjectURL(new Blob([csv], { type: 'text/csv' }));
      var a = document.createElement('a');
      a.href = url;
      a.download = 'codebook.csv';
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
      this.showToast('Codebook downloaded (' + rows.length + ' columns).', 'success');
    } catch (err) {
      this.showToast('Download blocked: ' + err.message, 'danger');
    }
  };

  // ---- workspace state ---------------------------------------------------------
  // The shape matches new_sideview_state() in R/state.R. Cards are matched by
  // name, so a state saved on one copy of the data restores on another.
  var STATE_VERSION = '0.3.0';

  function finiteOr(v, fallback) {
    var n = typeof v === 'number' ? v : parseFloat(v);
    return isFinite(n) ? n : fallback;
  }

  // The state embedded by sideview_ui() / passed by sideview_widget(): JSON text.
  function initialState(engine) {
    var s = engine.options.state;
    if (!s) {
      var tag = engine.container.querySelector('script.sideview-state');
      s = tag ? tag.textContent : null;
    }
    if (!s) return null;
    if (typeof s !== 'string') return s;
    try { return JSON.parse(s); } catch (e) {
      engine.showToast('Saved workspace could not be read: ' + e.message, 'danger');
      return null;
    }
  }

  SideviewEngine.prototype.getState = function () {
    var pz = this.panzoom;
    var pan = pz && pz.getPan ? pz.getPan() : { x: 0, y: 0 };
    var cards = [];
    this.cards.forEach(function (card) {
      var el = card.element;
      if (!el) return;
      var w = el.offsetWidth, h = el.offsetHeight;
      if (el.classList.contains('is-maximized') && el._svRestore) {
        w = parseFloat(el._svRestore.style.width) || null;
        h = parseFloat(el._svRestore.style.height) || null;
      } else if (el.classList.contains('is-minimized')) {
        h = parseFloat(el._svRestoreHeight) || null;
      }
      var vt = el._virtualTable;
      var sorts = [], filters = [];
      if (vt && vt.sortState && vt.sortState.colName && vt.sortState.direction && vt.sortState.direction !== 'none') {
        sorts.push({ col: vt.sortState.colName, dir: vt.sortState.direction });
      }
      if (vt && vt.currentFilter && vt.currentFilter.colName) {
        filters.push({ col: vt.currentFilter.colName, op: vt.currentFilter.operator, val: String(vt.currentFilter.value) });
      }
      cards.push({
        id: card.id,
        name: card.name,
        x: parseFloat(el.style.left) || 0,
        y: parseFloat(el.style.top) || 0,
        width: w || null,
        height: h || null,
        minimized: el.classList.contains('is-minimized'),
        sorts: sorts,
        filters: filters
      });
    });
    return {
      version: STATE_VERSION,
      canvas: { zoom: pz ? pz.getScale() : 1, pan_x: pan.x || 0, pan_y: pan.y || 0 },
      cards: cards,
      connections: this.connections.map(function (c) {
        return { from_table: c.fromTable, from_col: c.fromCol, to_table: c.toTable, to_col: c.toCol,
          join_type: c.type || 'left_join' };
      }),
      pipeline: {
        code: isNoCode(this.generatedCode) ? '' : this.generatedCode,
        active_tab: this.activeDrawerTab || 'pipeline',
        steps: this.pipeline.toJSON().steps,
        pipe: this.pipeline.pipe
      }
    };
  };

  // Show a saved sort / filter in a card's preview (the pipeline steps are
  // restored separately, so nothing is recorded here).
  SideviewEngine.prototype.applyCardView = function (el, sort, filter) {
    var table = el.querySelector('.sideview-table');
    var vt = table && table._virtualTable;
    if (!vt) return;
    var thFor = function (cls, col) {
      var b = col ? table.querySelector('thead .' + cls + '[data-col-name="' + cssEscape(col) + '"]') : null;
      return b ? { btn: b, th: b.closest('th') } : null;
    };
    var s = sort && thFor('sideview-sort-btn', sort.col);
    if (s && s.th && (sort.dir === 'asc' || sort.dir === 'desc')) {
      s.th.dataset.sortState = sort.dir;
      s.btn.classList.add('active');
      setIcon(s.btn, sort.dir === 'asc' ? 'sortAsc' : 'sortDesc');
      vt.sort(s.th.cellIndex, sort.col, sort.dir);
    }
    var f = filter && thFor('sideview-filter-btn', filter.col);
    if (f && f.th && filter.op && filter.val !== undefined && filter.val !== null) {
      f.btn.classList.add('active');
      vt.filter(f.th.cellIndex, filter.col, filter.op, String(filter.val));
    }
  };

  /**
   * Restore a saved workspace: card geometry, preview sorts/filters, joins,
   * pipeline steps and the view. Returns { restored, missing } card names.
   */
  SideviewEngine.prototype.applyState = function (state) {
    var self = this;
    var out = { restored: [], missing: [] };
    if (!state || typeof state !== 'object') return out;
    var byName = {};
    this.cards.forEach(function (card) { byName[card.name] = card; });

    asArray(state.cards).forEach(function (s) {
      if (!s || !s.name) return;
      var card = byName[s.name];
      if (!card || !card.element) { out.missing.push(String(s.name)); return; }
      var el = card.element;
      if (el.classList.contains('is-maximized')) self.toggleMaximizeCard(el, el.querySelector('[data-action="maximize-card"]'));
      var x = finiteOr(s.x, null), y = finiteOr(s.y, null);
      if (x !== null) { el.style.left = x + 'px'; card.x = x; }
      if (y !== null) { el.style.top = y + 'px'; card.y = y; }
      var w = finiteOr(s.width, 0), h = finiteOr(s.height, 0);
      if (el.classList.contains('is-minimized')) self.toggleMinimizeCard(el, el.querySelector('[data-action="minimize-card"]'));
      if (w > 0) el.style.width = w + 'px';
      if (h > 0) el.style.height = h + 'px';
      if (w > 0 && h > 0) el.classList.add('sv-sized');
      delete el.dataset.autoPlace;
      if (s.minimized === true) self.toggleMinimizeCard(el, el.querySelector('[data-action="minimize-card"]'));
      self.applyCardView(el, asArray(s.sorts)[0], asArray(s.filters)[0]);
      out.restored.push(card.name);
    });

    asArray(state.connections).forEach(function (c) {
      if (!c) return;
      var from = self.findPortElement(c.from_table, c.from_col);
      var to = self.findPortElement(c.to_table, c.to_col);
      if (!from || !to) return;
      var fromCard = from.closest('.sideview-card'), toCard = to.closest('.sideview-card');
      self.addConnection({
        fromCard: fromCard.dataset.cardId, fromTable: c.from_table, fromCol: c.from_col, fromElement: from,
        toCard: toCard.dataset.cardId, toTable: c.to_table, toCol: c.to_col, toElement: to,
        type: c.join_type || 'left_join'
      });
    });

    var p = state.pipeline || {};
    if (Array.isArray(p.steps)) {
      this.pipeline.load({ steps: p.steps, pipe: p.pipe });
    } else if (!isNoCode(p.code)) {
      // Version 0.2.0 files carry only the code.
      this.pipeline.replaceWithCode(String(p.code).trim(), 'restore');
    }
    if (p.pipe) this.pipeline.setPipe(p.pipe);
    // A restored workspace starts a fresh undo history.
    this.pipeline.undoStack = [];
    this.pipeline.redoStack = [];
    this.renderPipeline();
    if (p.active_tab && this.container.querySelector('.sideview-drawer-tab[data-tab="' + cssEscape(p.active_tab) + '"]')) {
      this.activateDrawerTab(p.active_tab);
    }

    var cv = state.canvas || {};
    var pz = this.panzoom;
    if (pz && typeof pz.zoom === 'function' && typeof pz.pan === 'function') {
      var zoom = Math.min(Math.max(finiteOr(cv.zoom, 1), this.options.minScale), this.options.maxScale);
      pz.zoom(zoom);
      pz.pan(finiteOr(cv.pan_x, 0), finiteOr(cv.pan_y, 0));
    }
    // Keep the saved view: the first layout only places cards the state lacks.
    if (out.restored.length) this._restoredView = true;
    this.scheduleConnectorUpdate();
    return out;
  };

  function stateSummary(out) {
    var msg = 'Restored ' + out.restored.length + ' card' + (out.restored.length === 1 ? '' : 's');
    if (out.missing.length) msg += '; not on this canvas: ' + out.missing.join(', ');
    return msg;
  }

  /** Open a workspace into the running canvas (replaces joins and pipeline). */
  SideviewEngine.prototype.openState = function (state) {
    this.clearOperations(true);
    var out = this.applyState(state);
    this.showToast(stateSummary(out), out.missing.length ? 'warning' : 'success');
    return out;
  };

  function downloadText(text, filename, type) {
    var url = URL.createObjectURL(new Blob([text], { type: type }));
    var a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
  }

  /** Save: R writes the file in the gadget (RStudio dialog); the widget downloads JSON. */
  SideviewEngine.prototype.saveWorkspace = function () {
    var json = JSON.stringify(this.getState(), null, 2);
    this.lastStateJson = json;
    if (this.isGadget()) {
      if (!sendToShiny('state_save', { json: json, nonce: Date.now() })) {
        this.showToast('The R session is not connected.', 'warning');
      }
      return;
    }
    try {
      downloadText(json, 'sideview-workspace.json', 'application/json');
      this.showToast('Workspace downloaded (sideview-workspace.json).', 'success');
    } catch (err) {
      this.showToast('Download blocked: ' + err.message, 'danger');
    }
  };

  /** Open: RStudio's dialog through R when there is one, else the browser's file picker. */
  SideviewEngine.prototype.openWorkspace = function () {
    var self = this;
    if (this.isGadget() && this.container.getAttribute('data-sv-file-dialog') === 'r') {
      if (!sendToShiny('state_open_request', Date.now())) this.showToast('The R session is not connected.', 'warning');
      return;
    }
    var input = document.createElement('input');
    input.type = 'file';
    input.accept = '.json,application/json';
    input.style.display = 'none';
    input.addEventListener('change', function () {
      var file = input.files && input.files[0];
      if (input.parentNode) input.parentNode.removeChild(input);
      if (!file) return;
      var reader = new FileReader();
      reader.onload = function () {
        try {
          self.openState(JSON.parse(String(reader.result)));
        } catch (err) {
          self.showToast('Not a sideview workspace: ' + err.message, 'danger');
        }
      };
      reader.readAsText(file);
    });
    this.container.appendChild(input);
    input.click();
  };

  SideviewEngine.prototype.renderBuilder = function (kind, keepTable) {
    var pane = this.container.querySelector('.sideview-drawer-content > [data-pane="' + kind + '"]');
    if (!pane) return;
    var schemas = this.tableSchemas();
    if (!schemas.length) {
      pane.innerHTML = '<p class="sideview-drawer-desc">Add a table to the canvas to build steps.</p>';
      return;
    }
    var prev = pane.querySelector('[data-field="table"]');
    var tableName = keepTable || (prev ? prev.value : '') || this.builderTable || schemas[0].name;
    var schema = schemas.filter(function (t) { return t.name === tableName; })[0] || schemas[0];
    var cols = schema.columns;
    var names = cols.map(function (c) { return c.name; });
    var head = '<label class="sideview-builder-field">Table <select data-field="table">' +
      optionList(schemas.map(function (t) { return t.name; }), schema.name) + '</select></label>';
    var body = '';
    var submit = 'Add step';
    if (kind === 'filter') {
      body = '<label class="sideview-builder-field">Keep rows matching <select data-field="combine">' +
        optionList([{ value: 'and', label: 'all conditions (AND)' }, { value: 'or', label: 'any condition (OR)' }]) +
        '</select></label><div class="sideview-builder-rows">' + this.builderRow('filter', cols) + '</div>' +
        '<button type="button" class="sideview-btn" data-builder-action="add-row">' + icon('plus') + ' Condition</button>';
      submit = 'Add filter step';
    } else if (kind === 'arrange') {
      body = '<div class="sideview-builder-rows">' + this.builderRow('arrange', cols) + '</div>' +
        '<button type="button" class="sideview-btn" data-builder-action="add-row">' + icon('plus') + ' Column</button>' +
        '<p class="sideview-builder-hint">Replaces any earlier sort of this table, like a header sort does.</p>';
      submit = 'Add arrange step';
    } else if (kind === 'mutate') {
      body = '<label class="sideview-builder-field">New or existing column <input type="text" data-field="name" placeholder="e.g. bmi" /></label>' +
        '<label class="sideview-builder-field">R expression <textarea data-field="expr" rows="3" spellcheck="false" placeholder="e.g. weight / (height / 100)^2"></textarea></label>' +
        '<div class="sideview-col-chips" aria-label="Insert a column name">' + names.map(function (nm) {
          return '<button type="button" class="sideview-col-chip" data-builder-action="insert-col" data-col="' + escapeHtml(nm) + '">' + escapeHtml(nm) + '</button>';
        }).join('') + '</div>';
      submit = 'Add mutate step';
    } else if (kind === 'recode') {
      body = '<label class="sideview-builder-field">Column <select data-field="col">' + optionList(names) + '</select></label>' +
        '<label class="sideview-builder-field">Value map, one per line (<code>old = new</code>) ' +
        '<textarea data-field="map" rows="4" spellcheck="false" placeholder="M = Male&#10;F = Female&#10;NA = Unknown"></textarea></label>' +
        '<p class="sideview-builder-hint">Values not listed are kept as they are.</p>';
      submit = 'Add recode step';
    } else if (kind === 'summarise') {
      body = '<label class="sideview-builder-field">Group by <select data-field="groups" multiple size="4">' + optionList(names) + '</select></label>' +
        '<div class="sideview-builder-rows">' + this.builderRow('summarise', cols) + '</div>' +
        '<button type="button" class="sideview-btn" data-builder-action="add-row">' + icon('plus') + ' Summary</button>';
      submit = 'Add summarise step';
    }
    pane.innerHTML = '<div class="sideview-builder" data-builder="' + kind + '">' + head + body +
      '<div class="sideview-builder-actions"><button type="button" class="sideview-btn sideview-btn-primary" data-builder-action="submit">' +
      submit + '</button></div></div>';
  };

  function fieldValue(root, name) {
    var el = root.querySelector('[data-field="' + name + '"]');
    return el ? String(el.value || '').trim() : '';
  }

  // Parse "old = new" lines; quotes around either side are optional.
  function parseRecodeMap(text) {
    var unq = function (v) { return v.trim().replace(/^(["'])(.*)\1$/, '$2'); };
    return String(text || '').split(/\r?\n/).map(function (line) {
      var i = line.indexOf('=');
      if (i < 0) return null;
      var from = unq(line.slice(0, i));
      var to = unq(line.slice(i + 1));
      return from === '' ? null : { from: from, to: to };
    }).filter(Boolean);
  }

  SideviewEngine.prototype.submitBuilder = function (builder) {
    var P = global.SideviewPipeline;
    var kind = builder.dataset.builder;
    var table = fieldValue(builder, 'table');
    var schema = this.tableSchemas().filter(function (t) { return t.name === table; })[0];
    var typeOf = function (col) {
      var c = schema ? schema.columns.filter(function (x) { return x.name === col; })[0] : null;
      return c ? c.type : '';
    };
    var rows = Array.prototype.slice.call(builder.querySelectorAll('.sideview-builder-row'));
    var step = null;
    var problem = '';
    if (kind === 'filter') {
      var conds = rows.map(function (r) {
        var col = fieldValue(r, 'col');
        var op = fieldValue(r, 'op');
        var val = fieldValue(r, 'val');
        if (!col || (val === '' && op !== 'is_na' && op !== 'not_na')) return null;
        var t = typeOf(col);
        var numeric = t ? !!P.NUMERIC_TYPES[t] : P.literal(val, true) !== P.str(val);
        return P.condition(col, op, val, numeric);
      }).filter(Boolean);
      if (!conds.length) problem = 'Enter a value for at least one condition.';
      else step = { kind: 'filter', table: table, conds: conds, combine: fieldValue(builder, 'combine') };
    } else if (kind === 'arrange') {
      var cols = rows.map(function (r) {
        return { col: fieldValue(r, 'col'), desc: fieldValue(r, 'dir') === 'desc' };
      }).filter(function (c) { return c.col; });
      if (!cols.length) problem = 'Pick at least one column.';
      else step = { kind: 'arrange', key: arrangeKey(table), table: table, cols: cols };
    } else if (kind === 'mutate') {
      var name = fieldValue(builder, 'name');
      var expr = fieldValue(builder, 'expr');
      if (!name || !expr) problem = 'Enter a column name and an R expression.';
      else step = { kind: 'mutate', table: table, name: name, expr: expr };
    } else if (kind === 'recode') {
      var rcol = fieldValue(builder, 'col');
      var map = parseRecodeMap(fieldValue(builder, 'map'));
      if (!rcol || !map.length) problem = 'Pick a column and enter at least one "old = new" line.';
      else step = { kind: 'recode', table: table, col: rcol, map: map, numeric: !!P.NUMERIC_TYPES[typeOf(rcol)] };
    } else if (kind === 'summarise') {
      var groupSel = builder.querySelector('[data-field="groups"]');
      var groups = groupSel && groupSel.options
        ? Array.prototype.filter.call(groupSel.options, function (o) { return o.selected; }).map(function (o) { return o.value; })
        : [];
      var aggs = rows.map(function (r) {
        return { fn: fieldValue(r, 'fn'), col: fieldValue(r, 'col'), name: fieldValue(r, 'name') };
      });
      step = { kind: 'summarise', table: table, groups: groups, aggs: aggs };
    }
    if (problem) {
      this.showToast(problem, 'warning');
      return null;
    }
    if (!step) return null;
    this.builderTable = table;
    this.pipeline.add(step, kind);
    this.showToast('Added ' + kind + ' step to the pipeline', 'success');
    this.activateDrawerTab('pipeline');
    return step;
  };

  // With several widgets on one page, keyboard undo goes to the one last used.
  var lastActiveEngine = null;

  SideviewEngine.prototype.initPipelineListeners = function () {
    var self = this;
    this.container.addEventListener('mousedown', function () { lastActiveEngine = self; });
    this.container.addEventListener('focusin', function () { lastActiveEngine = self; });
    // Ctrl/Cmd+Enter inside a builder tab adds its step.
    this.container.addEventListener('keydown', function (e) {
      if (e.key !== 'Enter' || !(e.ctrlKey || e.metaKey)) return;
      var builder = e.target && e.target.closest ? e.target.closest('.sideview-builder') : null;
      var submit = builder ? builder.querySelector('[data-builder-action="submit"]') : null;
      if (!submit) return;
      e.preventDefault();
      submit.click();
    });
    this.container.addEventListener('click', function (e) {
      var stepBtn = e.target.closest('[data-step-action]');
      if (stepBtn) {
        var li = stepBtn.closest('[data-step-id]');
        var id = li ? li.dataset.stepId : null;
        var act = stepBtn.dataset.stepAction;
        if (id && act === 'up') self.pipeline.move(id, -1);
        else if (id && act === 'down') self.pipeline.move(id, 1);
        else if (id && act === 'delete') self.pipeline.remove(id);
        else if (id && act === 'diag') self.showJoinCheck(id);
        return;
      }
      var bBtn = e.target.closest('[data-builder-action]');
      if (!bBtn) return;
      var builder = bBtn.closest('.sideview-builder');
      if (!builder) return;
      var bAct = bBtn.dataset.builderAction;
      if (bAct === 'submit') {
        self.submitBuilder(builder);
      } else if (bAct === 'add-row') {
        var rowsEl = builder.querySelector('.sideview-builder-rows');
        var schema = self.tableSchemas().filter(function (t) {
          return t.name === fieldValue(builder, 'table');
        })[0];
        if (rowsEl && schema) rowsEl.insertAdjacentHTML('beforeend', self.builderRow(builder.dataset.builder, schema.columns));
      } else if (bAct === 'remove-row') {
        var row = bBtn.closest('.sideview-builder-row');
        if (row && builder.querySelectorAll('.sideview-builder-row').length > 1) row.remove();
      } else if (bAct === 'insert-col') {
        var ta = builder.querySelector('[data-field="expr"]');
        if (!ta) return;
        var txt = global.SideviewPipeline.ident(bBtn.dataset.col);
        var start = typeof ta.selectionStart === 'number' ? ta.selectionStart : ta.value.length;
        var end = typeof ta.selectionEnd === 'number' ? ta.selectionEnd : start;
        ta.value = ta.value.slice(0, start) + txt + ta.value.slice(end);
        if (ta.focus) ta.focus();
        if (ta.setSelectionRange) ta.setSelectionRange(start + txt.length, start + txt.length);
      }
    });

    this.container.addEventListener('change', function (e) {
      var t = e.target;
      if (!t || !t.classList) return;
      var li = t.closest ? t.closest('[data-step-id]') : null;
      if (t.classList.contains('sideview-step-toggle') && li) {
        self.pipeline.update(li.dataset.stepId, { enabled: !!t.checked });
      } else if (t.classList.contains('sideview-step-jointype') && li) {
        self.pipeline.update(li.dataset.stepId, { type: t.value });
      } else if (t.classList.contains('sideview-pipe-select')) {
        self.pipeline.setPipe(t.value);
      } else if (t.dataset && t.dataset.inspect) {
        var pick = t.closest('.sideview-inspector');
        var tSel = pick && pick.querySelector('[data-inspect="table"]');
        var cSel = pick && pick.querySelector('[data-inspect="column"]');
        if (t.dataset.inspect === 'table') self.inspectTarget = { table: t.value, column: null };
        else self.inspectTarget = { table: tSel ? tSel.value : '', column: cSel ? cSel.value : '' };
        self.renderInspector();
      } else if (t.dataset && t.dataset.field === 'table') {
        var builder = t.closest('.sideview-builder');
        if (builder) self.renderBuilder(builder.dataset.builder, t.value);
      }
    });

    // Ctrl/Cmd+Z undoes and Ctrl+Y / Ctrl+Shift+Z redoes pipeline changes,
    // except while typing in a field (the browser's own text undo wins there).
    this.listenGlobal(document, 'keydown', function (e) {
      if (!(e.ctrlKey || e.metaKey) || e.altKey) return;
      var k = String(e.key || '').toLowerCase();
      if (k !== 'z' && k !== 'y') return;
      var tgt = e.target;
      if (lastActiveEngine && lastActiveEngine !== self) return;
      var tag = tgt && tgt.tagName ? tgt.tagName.toLowerCase() : '';
      if (tag === 'input' || tag === 'textarea' || tag === 'select' || (tgt && tgt.isContentEditable)) return;
      if (k === 'y' || e.shiftKey) self.redoPipeline();
      else self.undoPipeline();
      if (e.preventDefault) e.preventDefault();
    });
  };
  /**
   * Interactive Column Sorting (Asc -> Desc -> Reset)
   */
  SideviewEngine.prototype.sortColumn = function (cardEl, colName, colIndex, btn) {
    var self = this;
    var table = cardEl.querySelector('.sideview-table');
    if (!table) return;
    var tbody = table.querySelector('tbody');
    if (!tbody) return;

    var th = table.querySelectorAll('thead th')[colIndex];
    if (!th) return;

    var currentState = th.dataset.sortState || 'none';
    var nextState = 'asc';
    if (currentState === 'asc') nextState = 'desc';
    else if (currentState === 'desc') nextState = 'none';

    // Reset sort indicators on all headers in this table
    table.querySelectorAll('thead th').forEach(function (otherTh) {
      otherTh.dataset.sortState = 'none';
      var sBtn = otherTh.querySelector('.sideview-sort-btn');
      if (sBtn) {
        setIcon(sBtn, 'sort');
        sBtn.classList.remove('active');
      }
    });

    th.dataset.sortState = nextState;

    if (table._virtualTable) {
      table._virtualTable.sort(colIndex, colName, nextState);
      if (nextState === 'none') {
        setIcon(btn, 'sort');
        btn.classList.remove('active');
        self.recordSort(cardEl.dataset.cardName || 'df', colName, 'none');
        self.showToast('Reset column sort order on ' + colName, 'info');
      } else {
        btn.classList.add('active');
        setIcon(btn, nextState === 'asc' ? 'sortAsc' : 'sortDesc');

        var cardName = cardEl.dataset.cardName || 'df';
        var arrangeCode = self.recordSort(cardName, colName, nextState);
        self.showToast('Sorted ' + colName + ' (' + (nextState === 'asc' ? 'ascending' : 'descending') + ')', 'success');

        sendToShiny('column_sorted', {
          table: cardName,
          column: colName,
          direction: nextState,
          code: arrangeCode
        });
      }
    } else {
      // Fallback for non-virtualized table
      var rows = Array.from(tbody.querySelectorAll('tr'));
      rows.forEach(function (r, idx) {
        if (!r.dataset.rowIndex) r.dataset.rowIndex = idx;
      });

      if (nextState === 'none') {
        rows.sort(function (a, b) {
          return parseInt(a.dataset.rowIndex, 10) - parseInt(b.dataset.rowIndex, 10);
        });
        setIcon(btn, 'sort');
        btn.classList.remove('active');
        self.recordSort(cardEl.dataset.cardName || 'df', colName, 'none');
        self.showToast('Reset column sort order on ' + colName, 'info');
      } else {
        btn.classList.add('active');
        setIcon(btn, nextState === 'asc' ? 'sortAsc' : 'sortDesc');

        rows.sort(function (a, b) {
          var cellA = a.cells[colIndex] ? a.cells[colIndex].textContent.trim() : '';
          var cellB = b.cells[colIndex] ? b.cells[colIndex].textContent.trim() : '';

          var numA = parseFloat(cellA);
          var numB = parseFloat(cellB);
          var isNum = !isNaN(numA) && !isNaN(numB) && cellA !== '' && cellB !== '';

          var cmp = 0;
          if (isNum) {
            cmp = numA - numB;
          } else {
            cmp = cellA.localeCompare(cellB, undefined, { numeric: true, sensitivity: 'base' });
          }
          return nextState === 'asc' ? cmp : -cmp;
        });

        var cardNameFallback = cardEl.dataset.cardName || 'df';
        var arrangeCodeFallback = self.recordSort(cardNameFallback, colName, nextState);
        self.showToast('Sorted ' + colName + ' (' + (nextState === 'asc' ? 'ascending' : 'descending') + ')', 'success');

        sendToShiny('column_sorted', {
          table: cardNameFallback,
          column: colName,
          direction: nextState,
          code: arrangeCodeFallback
        });
      }
      rows.forEach(function (r) { tbody.appendChild(r); });
    }

    self.updateConnectors();
  };

  /**
   * Interactive Column Filter Popover
   *
   * The popover lives in the container's untransformed overlay layer and is
   * re-anchored to its button on pan, zoom, scroll and resize. Operators follow
   * the column type, and the generated code mirrors sv_filter_condition() in R.
   */
  var NUMERIC_COL_TYPES = { numeric: 1, integer: 1, double: 1, dbl: 1, int: 1, num: 1 };
  var TEXT_COL_TYPES = { character: 1, factor: 1, logical: 1, chr: 1, fct: 1, lgl: 1 };

  function rStringLiteral(value) {
    return '"' + String(value)
      .replace(/\\/g, '\\\\')
      .replace(/"/g, '\\"')
      .replace(/\n/g, '\\n') + '"';
  }

  function filterConditionCode(colName, op, val, isNumericCol) {
    var escCol = escapeColIdentifier(colName);
    var numOk = isNumericCol && val !== '' && !isNaN(Number(val));
    var lit = numOk ? String(Number(val)) : rStringLiteral(val);
    switch (op) {
      case 'contains': return 'grepl(' + rStringLiteral(val) + ', ' + escCol + ', fixed = TRUE)';
      case 'equals': return escCol + ' == ' + lit;
      case 'not_equals': return escCol + ' != ' + lit;
      case 'gt': return escCol + ' > ' + lit;
      case 'gte': return escCol + ' >= ' + lit;
      case 'lt': return escCol + ' < ' + lit;
      case 'lte': return escCol + ' <= ' + lit;
    }
    return 'TRUE';
  }

  SideviewEngine.prototype.closeActivePopover = function () {
    var pop = this._activePopover;
    if (pop && pop._closePopover) {
      pop._closePopover();
      return true;
    }
    return false;
  };

  SideviewEngine.prototype.activePopoverReposition = function () {
    var pop = this._activePopover;
    if (pop && pop._reposition) pop._reposition();
  };

  SideviewEngine.prototype.openFilterPopover = function (cardEl, colName, colIndex, btn) {
    var self = this;
    var existing = this._activePopover || document.querySelector('.sideview-filter-popover');
    if (existing) {
      var isSame = existing._sourceBtn === btn;
      if (existing._closePopover) existing._closePopover();
      else existing.remove();
      if (isSame) return;
    }

    var cardName = cardEl.dataset.cardName || 'df';
    var table = cardEl.querySelector('.sideview-table');
    var vt = table ? table._virtualTable : null;
    var th = btn.closest ? btn.closest('th') : null;
    var colType = (th && th.dataset && th.dataset.colType) ||
                  (vt && vt.colTypes ? vt.colTypes[colName] : '') || '';
    var typeKnown = colType !== '';
    var isTextCol = !!TEXT_COL_TYPES[colType];
    var isNumericCol = !!NUMERIC_COL_TYPES[colType];

    var popover = document.createElement('div');
    popover.className = 'sideview-filter-popover';
    popover._sourceBtn = btn;
    popover._sideviewOwner = this;
    popover.setAttribute('role', 'dialog');
    popover.setAttribute('aria-label', 'Filter ' + colName);

    var onDocMouseDown = function (evt) {
      var t = evt.target;
      var inside = popover.contains ? popover.contains(t) : false;
      var onBtn = t === btn || (btn.contains ? btn.contains(t) : false);
      if (!inside && !onBtn) closePopover();
    };
    var listenTimer = setTimeout(function () {
      document.addEventListener('mousedown', onDocMouseDown, true);
    }, 10);

    function closePopover() {
      clearTimeout(listenTimer);
      document.removeEventListener('mousedown', onDocMouseDown, true);
      if (popover.parentNode) popover.remove();
      if (self._activePopover === popover) self._activePopover = null;
    }
    popover._closePopover = closePopover;

    var ops = [
      ['contains', 'contains'],
      ['equals', 'equals (==)'],
      ['not_equals', 'not equals (!=)'],
      ['gt', 'greater than (&gt;)'],
      ['gte', 'greater or equal (&gt;=)'],
      ['lt', 'less than (&lt;)'],
      ['lte', 'less or equal (&lt;=)']
    ];
    // Text columns only offer text comparisons; unknown types keep everything.
    if (isTextCol) ops = ops.slice(0, 3);
    var defaultOp = isTextCol || !typeKnown ? 'contains' : 'equals';

    popover.innerHTML = [
      '<div class="sideview-filter-popover-header">',
      '  <span>Filter: ' + escapeHtml(colName) + (colType ? ' <small>(' + escapeHtml(colType) + ')</small>' : '') + '</span>',
      '  <button class="sideview-icon-btn sideview-filter-close" title="Close" aria-label="Close filter">' + icon('close') + '</button>',
      '</div>',
      '<select class="sideview-filter-select" aria-label="Operator">',
      ops.map(function (o) {
        return '  <option value="' + o[0] + '"' + (o[0] === defaultOp ? ' selected' : '') + '>' + o[1] + '</option>';
      }).join(''),
      '</select>',
      '<input type="text" class="sideview-filter-input" placeholder="Value (case-sensitive)" aria-label="Filter value" />',
      '<div class="sideview-filter-actions">',
      '  <button class="sideview-filter-clear">Clear</button>',
      '  <button class="sideview-filter-apply">Apply</button>',
      '</div>'
    ].join('');

    var host = this.overlay || this.container;
    host.appendChild(popover);
    this._activePopover = popover;

    function reposition() {
      if (!popover.parentNode) return;
      // A button scrolled or minimized out of view closes the popover.
      var cardHidden = cardEl.classList.contains('is-minimized');
      var btnRect = btn.getBoundingClientRect();
      var hostRect = host.getBoundingClientRect();
      if (cardHidden || (btnRect.width === 0 && btnRect.height === 0 && btn.offsetParent === null)) {
        closePopover();
        return;
      }
      var hostW = host.clientWidth || hostRect.width || (typeof window !== 'undefined' ? window.innerWidth : 800);
      var hostH = host.clientHeight || hostRect.height || (typeof window !== 'undefined' ? window.innerHeight : 600);
      var popW = popover.offsetWidth || 240;
      var popH = popover.offsetHeight || 170;
      var left = btnRect.left - hostRect.left - 80;
      var top = btnRect.bottom - hostRect.top + 6;
      if (top + popH > hostH - 8) top = btnRect.top - hostRect.top - popH - 6;
      left = Math.max(8, Math.min(hostW - popW - 8, left));
      top = Math.max(8, Math.min(hostH - popH - 8, top));
      popover.style.left = left + 'px';
      popover.style.top = top + 'px';
    }
    popover._reposition = reposition;
    reposition();

    var select = popover.querySelector('.sideview-filter-select');
    var input = popover.querySelector('.sideview-filter-input');
    if (vt && vt.currentFilter && vt.currentFilter.colName === colName) {
      select.value = vt.currentFilter.operator;
      input.value = vt.currentFilter.value;
    }
    input.focus();

    popover.querySelector('.sideview-filter-close').addEventListener('click', function () {
      closePopover();
    });

    popover.querySelector('.sideview-filter-clear').addEventListener('click', function () {
      if (table) {
        if (table._virtualTable) {
          table._virtualTable.clearFilter();
        } else {
          table.querySelectorAll('tbody tr').forEach(function (tr) {
            tr.classList.remove('sideview-row-filtered');
          });
        }
      }
      btn.classList.remove('active');
      self.pipeline.removeKey(headerFilterKey(cardName), 'filter');
      closePopover();
      self.updateConnectors();
      self.showToast('Cleared filter on ' + colName, 'info');
    });

    function applyFilter() {
      var val = input.value.trim();
      if (!val) {
        closePopover();
        return;
      }
      var op = select.value;
      if (!table) return;

      var totalRowsCount = 0;
      var matchedCount = 0;

      if (table._virtualTable) {
        var tv = table._virtualTable;
        totalRowsCount = tv.remote ? tv.remote.total : tv.totalRows;
        matchedCount = tv.filter(colIndex, colName, op, val);
      } else {
        var rows = table.querySelectorAll('tbody tr');
        totalRowsCount = rows.length;
        var numVal = parseFloat(val);
        var isNumFilter = !isNaN(numVal);

        rows.forEach(function (tr) {
          var cell = tr.cells[colIndex];
          var text = cell ? cell.textContent.trim() : '';
          var numCell = parseFloat(text);
          var match = false;

          if (op === 'contains') {
            match = text.indexOf(val) !== -1;
          } else if (op === 'equals') {
            match = isNumFilter && !isNaN(numCell) ? numCell === numVal : text === val;
          } else if (op === 'not_equals') {
            match = isNumFilter && !isNaN(numCell) ? numCell !== numVal : text !== val;
          } else if (op === 'gt') {
            match = !isNaN(numCell) && numCell > numVal;
          } else if (op === 'gte') {
            match = !isNaN(numCell) && numCell >= numVal;
          } else if (op === 'lt') {
            match = !isNaN(numCell) && numCell < numVal;
          } else if (op === 'lte') {
            match = !isNaN(numCell) && numCell <= numVal;
          }

          if (match) {
            tr.classList.remove('sideview-row-filtered');
            matchedCount++;
          } else {
            tr.classList.add('sideview-row-filtered');
          }
        });
      }

      btn.classList.add('active');

      var numericForCode = typeKnown ? isNumericCol : !isNaN(Number(val));
      var condExpr = filterConditionCode(colName, op, val, numericForCode);

      // The preview holds one header filter per table, and so does the pipeline.
      cardEl.querySelectorAll('.sideview-filter-btn.active').forEach(function (b) {
        if (b !== btn) b.classList.remove('active');
      });
      self.pipeline.add({
        kind: 'filter', key: headerFilterKey(cardName), table: cardName,
        conds: [condExpr], source: 'header'
      }, 'filter');
      var filterCode = self.generatedCode;
      // Server-paged tables report their count when the first block arrives.
      if (matchedCount !== null) {
        self.showToast('Filtered ' + colName + ' (' + matchedCount + '/' + totalRowsCount + ' rows)', 'success');
      }

      sendToShiny('column_filtered', {
        table: cardName,
        column: colName,
        operator: op,
        value: val,
        condition: condExpr,
        code: filterCode
      });

      closePopover();
      self.updateConnectors();
    }

    popover.querySelector('.sideview-filter-apply').addEventListener('click', applyFilter);
    input.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') applyFilter();
      else if (e.key === 'Escape') { e.stopPropagation(); closePopover(); }
    });
  };

  // Busy state for the AI bar and Copilot while R waits on the model.
  SideviewEngine.prototype.setAiBusy = function (busy) {
    var self = this;
    this.aiBusy = !!busy;
    if (this._aiBusyTimer) { clearTimeout(this._aiBusyTimer); this._aiBusyTimer = null; }
    var bar = this.container.querySelector('.sideview-ai-bar');
    if (bar) {
      bar.classList.toggle('is-busy', this.aiBusy);
      bar.setAttribute('aria-busy', this.aiBusy ? 'true' : 'false');
    }
    var buttons = this.container.querySelectorAll('[data-action="send-ai"], .sideview-chat-send');
    for (var i = 0; i < buttons.length; i++) {
      var b = buttons[i];
      if (this.aiBusy) {
        if (!b.dataset.idleLabel) b.dataset.idleLabel = b.textContent;
        b.textContent = 'Thinking...';
        b.disabled = true;
      } else {
        if (b.dataset.idleLabel) b.textContent = b.dataset.idleLabel;
        b.disabled = false;
      }
    }
    // Never leave the bar stuck if a reply is lost.
    if (this.aiBusy) {
      this._aiBusyTimer = setTimeout(function () { self.setAiBusy(false); }, 180000);
    }
  };

  SideviewEngine.prototype.showToast = function (message, type) {
    var toast = document.createElement('div');
    toast.className = 'sideview-toast ' + (type ? 'sideview-toast-' + type : '');
    toast.textContent = message;
    toast.setAttribute('role', 'status');
    var stack = this.container.querySelector('.sideview-toast-stack');
    if (!stack) {
      stack = document.createElement('div');
      stack.className = 'sideview-toast-stack';
      stack.setAttribute('aria-live', 'polite');
      this.container.appendChild(stack);
    }
    stack.appendChild(toast);
    setTimeout(function () {
      toast.classList.add('visible');
    }, 10);
    // Errors carry a fix hint, so they stay up longer.
    var ttl = (type === 'danger' || type === 'warning') ? 9000 : 4500;
    setTimeout(function () {
      toast.classList.remove('visible');
      setTimeout(function () { toast.remove(); }, 300);
    }, ttl);
  };

  SideviewEngine.prototype.registerShinyHandlers = function () {
    var self = this;
    if (typeof global.Shiny === 'undefined' || typeof global.Shiny.addCustomMessageHandler !== 'function') {
      return;
    }

    // Code update from R server
    global.Shiny.addCustomMessageHandler('sideview_console_result', function (data) {
      if (data && data.message) {
        self.showToast(data.message, data.success ? 'success' : 'warning');
      }
    });

    global.Shiny.addCustomMessageHandler('sideview_inject_result', function (data) {
      if (data && data.message) {
        self.showToast(data.message, data.success ? 'success' : 'warning');
      }
    });

    global.Shiny.addCustomMessageHandler('sideview_eval_result', function (data) {
      if (data && data.message) {
        self.showToast(data.message, data.success ? 'success' : 'danger');
      }
    });

    // The browser-side pipeline composes the code. Per-event echoes from R
    // (source "event") are ignored, Copilot replies wait for the user to press
    // "Replace pipeline", auto-clean code is appended as a step, and anything
    // else (AI bar, older servers) replaces the pipeline, undoably.
    global.Shiny.addCustomMessageHandler('sideview_code_update', function (data) {
      if (!data) return;
      var src = data.source || '';
      if (src === 'event' || src === 'copilot') return;
      if (src === 'auto_clean') {
        if (!isNoCode(data.code)) {
          self.pipeline.add({ kind: 'custom', code: String(data.code).trim(), label: 'auto-clean' }, 'auto_clean');
          self.showToast('Added the auto-clean step to the pipeline', 'success');
        }
        return;
      }
      self.updateDrawerCode(data.code, src === 'ai' ? 'AI code' : 'code from R');
    });

    global.Shiny.addCustomMessageHandler('sideview_ai_status', function (data) {
      self.setAiBusy(false);
      if (data && data.message) {
        self.showToast(data.message, data.success ? 'success' : 'danger');
      }
    });

    global.Shiny.addCustomMessageHandler('sideview_copilot_reply', function (data) {
      self.setAiBusy(false);
      if (!data) return;
      var chatMessages = self.container.querySelector('.sideview-chat-messages');
      if (!chatMessages) return;

      var assistantBubble = document.createElement('div');
      assistantBubble.className = 'sideview-chat-bubble sideview-chat-assistant';

      if (data.text) {
        var textWithoutFences = data.text.replace(/```(?:\{?[a-zA-Z0-9_,-]*\}?)?[\s\S]*?```/g, '').trim();
        var displayText = textWithoutFences || (data.code ? 'Here is the requested tidyverse transformation:' : data.text);
        var textEl = document.createElement('div');
        textEl.className = 'sideview-chat-bubble-text';
        textEl.textContent = displayText;
        assistantBubble.appendChild(textEl);
      }

      if (data.code && data.code.trim()) {
        var codeEl = document.createElement('pre');
        codeEl.className = 'sideview-chat-code';
        codeEl.textContent = data.code.trim();
        assistantBubble.appendChild(codeEl);

        var actionsEl = document.createElement('div');
        actionsEl.className = 'sideview-chat-code-actions';

        var replaceBtn = document.createElement('button');
        replaceBtn.className = 'sideview-btn sideview-btn-sm sideview-chat-replace-btn';
        replaceBtn.dataset.action = 'chat-replace-pipeline';
        replaceBtn.textContent = 'Replace Pipeline';

        var insertBtn = document.createElement('button');
        insertBtn.className = 'sideview-btn sideview-btn-sm sideview-btn-primary sideview-chat-insert-btn';
        insertBtn.dataset.action = 'chat-insert-editor';
        insertBtn.textContent = 'Insert into Editor';

        actionsEl.appendChild(replaceBtn);
        actionsEl.appendChild(insertBtn);
        assistantBubble.appendChild(actionsEl);
      }

      chatMessages.appendChild(assistantBubble);
      chatMessages.scrollTop = chatMessages.scrollHeight;
    });

    // Row window for a large card (reply to sideview_rows_request)
    global.Shiny.addCustomMessageHandler('sideview_rows', function (data) {
      if (!data || data.card_id === undefined) return;
      var meta = self.cards.get(data.card_id);
      if (!meta) {
        self.cards.forEach(function (m) { if (m.name === data.card_id) meta = m; });
      }
      var vt = meta ? (meta.virtualTable || (meta.element ? meta.element._virtualTable : null)) : null;
      if (data.error) {
        self.showToast('Could not load rows: ' + data.error, 'warning');
        return;
      }
      if (vt && typeof vt.receiveRows === 'function') {
        vt.receiveRows(data);
        self.scheduleConnectorUpdate();
      }
    });

    // Suggested mappings from server
    global.Shiny.addCustomMessageHandler('sideview_suggested_mappings', function (data) {
      if (data) {
        self.renderSuggestedSplines(data);
      }
    });

    // Column profile computed in R on the full data (reply to column_profile_request)
    global.Shiny.addCustomMessageHandler('sideview_column_profile', function (data) {
      self.onColumnProfile(data);
    });

    // Workspace written by R (reply to state_save)
    global.Shiny.addCustomMessageHandler('sideview_state_saved', function (data) {
      if (!data || data.cancelled) return;
      if (data.error) self.showToast('Workspace not saved: ' + data.error, 'danger');
      else self.showToast('Workspace saved to ' + data.path, 'success');
    });

    // Workspace chosen in RStudio's dialog (reply to state_open_request)
    global.Shiny.addCustomMessageHandler('sideview_state_loaded', function (data) {
      if (!data || data.cancelled) return;
      if (data.error) { self.showToast('Workspace not opened: ' + data.error, 'danger'); return; }
      try { self.openState(JSON.parse(data.json)); } catch (err) {
        self.showToast('Workspace not opened: ' + err.message, 'danger');
      }
    });

    // Codebook written by R (reply to codebook_export)
    global.Shiny.addCustomMessageHandler('sideview_codebook_saved', function (data) {
      if (!data || data.cancelled) return;
      if (data.error) self.showToast('Codebook not saved: ' + data.error, 'danger');
      else self.showToast('Codebook saved to ' + data.path, 'success');
    });

    // Join diagnostics computed in R on the full data (reply to join_diagnostics_request)
    global.Shiny.addCustomMessageHandler('sideview_join_diagnostics', function (data) {
      self.onJoinDiagnostics(data);
    });

    // Discrepancy report update
    global.Shiny.addCustomMessageHandler('sideview_discrepancies', function (data) {
      if (!data) return;
      // Shiny serialises data frames column-wise and length-1 vectors as scalars.
      data.fuzzy_matches = rowsFromColumns(data.fuzzy_matches);
      data.exact_matches = asArray(data.exact_matches);
      data.only_in_x = asArray(data.only_in_x);
      data.only_in_y = asArray(data.only_in_y);
      self.lastDiscrepancy = data;

      var discPane = self.container.querySelector('.sideview-discrepancy-pane') ||
                     self.container.querySelector('#sideview-discrepancy-content');
      var discContent = discPane ? (discPane.querySelector('.sideview-discrepancy-content') || discPane) : null;
      if (!discContent) {
        var drawerContent = self.container.querySelector('.sideview-drawer-content');
        if (drawerContent) {
          discPane = document.createElement('div');
          discPane.className = 'sideview-tab-pane sideview-discrepancy-pane';
          discPane.dataset.pane = 'discrepancy';
          discPane.style.display = 'none';
          drawerContent.appendChild(discPane);
          discContent = discPane;
        }
      }

      if (discContent) {
        var exactCnt = (data.exact_matches || []).length;
        var fuzzyCnt = (data.fuzzy_matches || []).length;
        var diffCnt = (data.only_in_x || []).length + (data.only_in_y || []).length;
        var discHtml = [
          '<div class="sideview-discrepancy-card">',
          '  <div class="sideview-discrepancy-summary">',
          '    <span>' + escapeHtml(data.from_table || 'Table 1') + ' ↔ ' + escapeHtml(data.to_table || 'Table 2') + '</span>',
          '    <span>' + exactCnt + ' matched · ' + fuzzyCnt + ' fuzzy · ' + diffCnt + ' diff</span>',
          '  </div>'
        ];
        if (fuzzyCnt > 0 || (data.only_in_x && data.only_in_x.length > 0)) {
          discHtml.push('  <button class="sideview-btn sideview-btn-auto-clean" data-action="apply-auto-clean">Apply Suggested Cleanups</button>');
        }
        discHtml.push('</div>');
        discHtml.push('<pre class="sideview-code-block"><code class="sideview-code-text">' + escapeHtml(self.generatedCode || '# Discrepancy checked') + '</code></pre>');
        discContent.innerHTML = discHtml.join('');
      }

      var targetCards = [];
      if (data.from_table) {
        var c1 = self.container.querySelector('[data-card-name="' + cssEscape(data.from_table) + '"]');
        if (c1) targetCards.push(c1);
      }
      if (data.to_table) {
        var c2 = self.container.querySelector('[data-card-name="' + cssEscape(data.to_table) + '"]');
        if (c2) targetCards.push(c2);
      }
      var scope = targetCards.length > 0 ? targetCards : [self.container];

      var searchCells = [];
      scope.forEach(function (el) {
        var found = el.querySelectorAll('td');
        for (var i = 0; i < found.length; i++) {
          searchCells.push(found[i]);
        }
      });

      // Highlight discrepancy cells in connected tables
      if (data.fuzzy_matches.length) {
        var fuzzyValues = {};
        data.fuzzy_matches.forEach(function (pair) {
          if (pair.x !== null && pair.x !== undefined) fuzzyValues[String(pair.x)] = true;
          if (pair.y !== null && pair.y !== undefined) fuzzyValues[String(pair.y)] = true;
        });
        searchCells.forEach(function (c) {
          if (fuzzyValues[c.textContent.trim()]) c.classList.add('sideview-discrepancy-fuzzy');
        });
      }

      if (data.only_in_x.length || data.only_in_y.length) {
        var diffValues = data.only_in_x.concat(data.only_in_y).map(String);
        searchCells.forEach(function (c) {
          if (diffValues.indexOf(c.textContent.trim()) !== -1) {
            c.classList.add('sideview-discrepancy-diff');
          }
        });
      }
    });
  };

  // Factory entry point for Sideview
  function initSideview(container, options) {
    var target = container;
    if (!target) {
      target = document.querySelector('.sideview-container') || document.body;
    }
    var instance = new SideviewEngine(target, options);
    instance.container._sideviewInstance = instance;
    global.sideviewInitialized = true;
    global._sideviewInstance = instance;
    if (typeof window !== 'undefined') {
      window.sideviewInitialized = true;
      window._sideviewInstance = instance;
    }
    return instance;
  }

  // Export globally
  global.initSideview = initSideview;
  global.VirtualTable = VirtualTable;
  global.SideviewVirtualTable = VirtualTable;
  global.Sideview = {
    init: initSideview,
    Engine: SideviewEngine,
    VirtualTable: VirtualTable
  };

})(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this));
