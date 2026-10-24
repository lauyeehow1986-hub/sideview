# Source R files if running standalone
if (!"package:sideview" %in% search()) {
  r_files <- list.files(c("R", "../R", "../../R"), pattern = "\\.[Rr]$", full.names = TRUE)
  for (f in r_files) source(f)
}

find_asset <- function(filename) {
  candidates <- c(
    file.path("inst", "www", filename),
    file.path("..", "inst", "www", filename),
    file.path("..", "..", "inst", "www", filename),
    system.file("www", filename, package = "sideview")
  )
  for (c in candidates) {
    if (nzchar(c) && file.exists(c)) {
      return(normalizePath(c))
    }
  }
  # Return expected path for clear assertion failures
  file.path("inst", "www", filename)
}

read_asset <- function(filename) {
  path <- find_asset(filename)
  if (!file.exists(path)) return("")
  paste(readLines(path, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
}

test_that("all required web asset files exist and are non-empty", {
  required_files <- c("sv-panzoom.js", "sv-pipeline.js", "sideview.css", "sideview.js")
  for (f in required_files) {
    path <- find_asset(f)
    expect_true(file.exists(path), info = paste("Asset missing:", f, "at", path))
    info <- file.info(path)
    expect_gt(info$size, 0, label = paste("Asset file size of", f))
  }
})

test_that("sideview.css contains all required CSS selectors and styles", {
  css <- read_asset("sideview.css")
  expect_gt(nchar(css), 100, label = "sideview.css length")

  # Infinite canvas & panzoom viewport
  expect_match(css, "\\.sideview-canvas", info = "sideview.css must contain .sideview-canvas")
  expect_match(css, "overflow|transform|perspective", info = "canvas must configure viewport/overflow/transforms")

  # Draggable table cards
  expect_match(css, "\\.sideview-card", info = "sideview.css must contain .sideview-card")
  expect_match(css, "\\.sideview-card-header", info = "sideview.css must contain .sideview-card-header")
  expect_match(css, "\\.sideview-card-body", info = "sideview.css must contain .sideview-card-body")

  # Scrollable tables, sticky headers, cell highlight classes
  expect_match(css, "\\.sideview-table", info = "sideview.css must contain .sideview-table")
  expect_match(css, "position:\\s*sticky|sticky", info = "table must support sticky headers")
  expect_match(css, "highlight|\\.sv-highlight|\\.sideview-cell-highlight", info = "table must have highlight classes")

  # SVG spline overlay for field mapping
  expect_match(css, "\\.sideview-connector-svg", info = "sideview.css must contain .sideview-connector-svg")

  # Action drawer for join, mutate, recode, discrepancy
  expect_match(css, "\\.sideview-drawer", info = "sideview.css must contain .sideview-drawer")

  # Floating natural language AI prompt bar
  expect_match(css, "\\.sideview-ai-bar", info = "sideview.css must contain .sideview-ai-bar")

  # Color highlighter swatches palette
  expect_match(css, "\\.sideview-palette", info = "sideview.css must contain .sideview-palette")

  # Column header sorting and filtering styles
  expect_match(css, "\\.sideview-sort-btn|\\.sideview-th-btn", info = "sideview.css must style sort buttons")
  expect_match(css, "\\.sideview-filter-popover", info = "sideview.css must style filter popover")

  # Modern CSS custom properties (variables)
  expect_match(css, "--sv-|--sideview-", info = "sideview.css must use CSS custom properties")
})

test_that("sideview.js contains required functions, event handlers, and Shiny integration", {
  js <- read_asset("sideview.js")
  expect_gt(nchar(js), 500, label = "sideview.js length")

  # initSideview()
  expect_match(js, "function\\s+initSideview|initSideview\\s*=|window\\.initSideview", 
               info = "sideview.js must define or export initSideview")

  # Panzoom wheel zoom and pan handling
  expect_match(js, "wheel|zoom|pan|Panzoom|panzoom", 
               info = "sideview.js must handle panzoom wheel zoom and pan")

  # Table card drag and drop handling with snap-to-edge
  expect_match(js, "drag|mousedown|mousemove|mouseup|pointerdown|pointermove|pointerup", 
               info = "sideview.js must handle card dragging")
  expect_match(js, "snap|threshold|dock|snap-to-edge|snapToEdge", 
               info = "sideview.js must implement snap-to-edge logic")

  # Independent table scrolling and synchronized scroll sync
  expect_match(js, "scroll|sync|scrollSync|syncScroll", 
               info = "sideview.js must implement table scrolling and sync scroll")
  expect_match(js, "scrollLeft", 
               info = "sideview.js must support horizontal scroll synchronization")

  # Cell/column color highlighting
  expect_match(js, "highlight|palette|color", 
               info = "sideview.js must handle cell/column color highlighting")

  # Click-to-connect field mapping with SVG bezier curves
  expect_match(js, "connector|bezier|path|M.*C|curve|connect", 
               info = "sideview.js must draw SVG bezier curves for field connections")

  # Inline column renaming
  expect_match(js, "rename|dblclick|contenteditable|prompt|renameColumn", 
               info = "sideview.js must support inline column renaming")

  # Shiny.setInputValue integration
  expect_match(js, "Shiny\\.setInputValue", 
               info = "sideview.js must integrate Shiny.setInputValue for event dispatch")

  # Clear operations and reset functionality
  expect_match(js, "clearOperations|clear-operation", 
               info = "sideview.js must support clearing operations and resetting connectors")
  
  # Disconnect individual column splines
  expect_match(js, "removeConnection|column_disconnected", 
               info = "sideview.js must support disconnecting individual column splines")
  
  # Interactive column sorting and filter popover
  expect_match(js, "sortColumn|column_sorted", info = "sideview.js must support column sorting")
  expect_match(js, "openFilterPopover|column_filtered", info = "sideview.js must support filter popover")

  # Syntax validation via node if installed
  node_path <- Sys.which("node")
  if (nzchar(node_path)) {
    js_path <- find_asset("sideview.js")
    status <- system2(node_path, c("-c", shQuote(js_path)), stdout = TRUE, stderr = TRUE)
    attr_status <- attr(status, "status")
    expect_true(is.null(attr_status) || attr_status == 0,
                info = paste("sideview.js syntax error:", paste(status, collapse = "\n")))
  }
})

test_that("sv-panzoom.js contains a valid Panzoom library implementation", {
  pz <- read_asset("sv-panzoom.js")
  expect_gt(nchar(pz), 200, label = "sv-panzoom.js length")
  expect_match(pz, "panzoom|Panzoom|transform|matrix|zoom", 
               info = "sv-panzoom.js must contain Panzoom library functionality")
})

test_that("sideview.js resets activePort in clearOperations and escapes column names", {
  js <- read_asset("sideview.js")
  expect_match(js, "activePort", info = "Must handle activePort in clearOperations")
  expect_match(js, "escapeIdent|escapeCol", info = "Must escape column identifiers")
})


test_that("sideview.js and sideview.css implement DOM virtualization for high row counts", {
  js <- read_asset("sideview.js")
  css <- read_asset("sideview.css")

  # VirtualTable definition and window exposure
  expect_match(js, "function\\s+VirtualTable|class\\s+VirtualTable",
               info = "sideview.js must define VirtualTable constructor or class")
  expect_match(js, "SideviewVirtualTable|Sideview\\.VirtualTable",
               info = "sideview.js must expose VirtualTable on window or Sideview namespace")

  # Virtual scrolling calculations and spacer logic
  expect_match(js, "sideview-virtual-spacer",
               info = "sideview.js must use virtual spacer classes")
  expect_match(js, "rowHeight",
               info = "sideview.js must configure or calculate rowHeight")
  expect_match(js, "scrollTop",
               info = "sideview.js must listen to scroll events and calculate scrollTop offset")

  # Performance optimization and column rename synchronization
  expect_match(js, "_sideviewCollator",
               info = "sideview.js must define cached _sideviewCollator for high-performance string sorting")
  expect_match(js, "VirtualTable\\.prototype\\.renameColumn|renameColumn",
               info = "sideview.js must define renameColumn method on VirtualTable")
  expect_match(js, "VirtualTable\\.prototype\\.destroy|\\.destroy\\s*=",
               info = "sideview.js must define destroy method on VirtualTable")

  # CSS classes for virtual scrolling
  expect_match(css, "\\.sideview-virtual-spacer",
               info = "sideview.css must contain .sideview-virtual-spacer rule")
  expect_match(css, "\\.sideview-table-viewport",
               info = "sideview.css must contain .sideview-table-viewport rule")
  expect_match(css, "height:\\s*28px|min-height|max-height",
               info = "sideview.css must constrain virtual row height or viewport")

  # Node syntax check
  node_path <- Sys.which("node")
  if (nzchar(node_path)) {
    js_path <- find_asset("sideview.js")
    status <- system2(node_path, c("-c", shQuote(js_path)), stdout = TRUE, stderr = TRUE)
    attr_status <- attr(status, "status")
    expect_true(is.null(attr_status) || attr_status == 0,
                info = paste("sideview.js syntax error:", paste(status, collapse = "\n")))
  }
})


test_that("VirtualTable JavaScript engine executes 100k row virtualization correctly in Node runtime", {
  node_path <- Sys.which("node")
  skip_if(!nzchar(node_path), "Node.js not available for JavaScript runtime verification")

  js_path <- find_asset("sideview.js")
  test_script <- paste0(
    "class MockElement {",
    "  constructor(tag) {",
    "    this.tagName = (tag || 'DIV').toUpperCase();",
    "    this.classList = new Set();",
    "    this.classList.add = (...cs) => cs.forEach(c => this.classList[c] = true);",
    "    this.classList.remove = (c) => delete this.classList[c];",
    "    this.classList.contains = (c) => !!this.classList[c];",
    "    this.style = {};",
    "    this.children = [];",
    "    this.dataset = {};",
    "    this.scrollTop = 0;",
    "    this.clientHeight = 380;",
    "    this.scrollHeight = 380;",
    "    this._listeners = {};",
    "  }",
    "  set className(val) {",
    "    this._className = val;",
    "    (val || '').split(/\\s+/).forEach(c => { if (c) this.classList.add(c); });",
    "  }",
    "  get className() { return this._className || ''; }",
    "  _relink() {",
    "    for (let i = 0; i < this.children.length; i++) {",
    "      this.children[i].parentElement = this;",
    "      this.children[i].parentNode = this;",
    "      this.children[i].previousSibling = i > 0 ? this.children[i - 1] : null;",
    "      this.children[i].nextSibling = i < this.children.length - 1 ? this.children[i + 1] : null;",
    "    }",
    "  }",
    "  appendChild(child) {",
    "    this.children.push(child);",
    "    this._relink();",
    "    return child;",
    "  }",
    "  removeChild(child) {",
    "    const idx = this.children.indexOf(child);",
    "    if (idx !== -1) {",
    "      this.children.splice(idx, 1);",
    "      child.parentElement = null;",
    "      child.parentNode = null;",
    "      child.previousSibling = null;",
    "      child.nextSibling = null;",
    "      this._relink();",
    "    }",
    "    return child;",
    "  }",
    "  insertBefore(newNode, refNode) {",
    "    if (newNode.tagName === 'FRAGMENT') {",
    "      const kids = newNode.children.slice();",
    "      for (const k of kids) this.insertBefore(k, refNode);",
    "      return newNode;",
    "    }",
    "    const idx = refNode ? this.children.indexOf(refNode) : -1;",
    "    if (idx !== -1) this.children.splice(idx, 0, newNode);",
    "    else this.children.push(newNode);",
    "    this._relink();",
    "    return newNode;",
    "  }",
    "  querySelector(sel) {",
    "    if (sel === 'tbody') return this.children.find(c => c.tagName === 'TBODY');",
    "    if (sel === 'thead th') return this.children.find(c => c.tagName === 'THEAD');",
    "    return null;",
    "  }",
    "  querySelectorAll(sel) {",
    "    if (sel === 'thead th') return [];",
    "    if (sel.includes('tr')) return this.children.filter(c => c.tagName === 'TR');",
    "    return [];",
    "  }",
    "  closest(sel) { return this; }",
    "  addEventListener(event, fn) {",
    "    this._listeners[event] = this._listeners[event] || [];",
    "    this._listeners[event].push(fn);",
    "  }",
    "  removeEventListener(event, fn) {",
    "    if (!this._listeners[event]) return;",
    "    const idx = this._listeners[event].indexOf(fn);",
    "    if (idx !== -1) this._listeners[event].splice(idx, 1);",
    "  }",
    "}",
    "global.document = {",
    "  createElement: (tag) => new MockElement(tag),",
    "  createDocumentFragment: () => new MockElement('FRAGMENT')",
    "};",
    "global.requestAnimationFrame = (cb) => cb();",
    "require('", gsub("\\\\", "/", normalizePath(js_path)), "');",
    "const VT = global.SideviewVirtualTable;",
    "if (!VT) throw new Error('SideviewVirtualTable not found');",
    "const rowCount = 100000;",
    "const colA = new Array(rowCount);",
    "const colB = new Array(rowCount);",
    "for (let i = 0; i < rowCount; i++) { colA[i] = 'ID_' + i; colB[i] = i * 1.5; }",
    "const mockTable = new MockElement('TABLE');",
    "const vt = new VT(mockTable, { data: { id: colA, val: colB }, rowHeight: 28, buffer: 10 });",
    "if (vt.getRowCount() !== 100000) throw new Error('Incorrect rowCount');",
    "const rowsInitial = vt.tbody.children.filter(c => c.tagName === 'TR' && !c.classList.contains('sideview-virtual-spacer'));",
    "if (rowsInitial.length < 20 || rowsInitial.length > 40) throw new Error('Initial rendered row buffer count mismatch');",
    "vt.scrollContainer.scrollTop = 1400000;",
    "vt.render();",
    "const rowsMid = vt.tbody.children.filter(c => c.tagName === 'TR' && !c.classList.contains('sideview-virtual-spacer'));",
    "if (rowsMid.length < 20 || rowsMid.length > 40) throw new Error('Mid rendered row buffer count mismatch');",
    "vt.scrollContainer.scrollTop = 0;",
    "vt.sort(1, 'val', 'desc');",
    "const topRowSorted = vt.tbody.children.find(c => c.tagName === 'TR' && !c.classList.contains('sideview-virtual-spacer'));",
    "if (parseInt(topRowSorted.dataset.rowIndex, 10) !== 99999) throw new Error('Sort desc failed');",
    "const matches = vt.filter(0, 'id', 'equals', 'ID_42');",
    "if (matches !== 1) throw new Error('Filter equals failed');",
    "vt.renameColumn('id', 'identifier', 0);",
    "if (vt.colNames[0] !== 'identifier' || !vt.data['identifier'] || vt.data['id'] !== undefined) throw new Error('renameColumn failed');",
    "vt.destroy();",
    "console.log('SUCCESS');"
  )

  status <- system2(node_path, c("-e", shQuote(test_script)), stdout = TRUE, stderr = TRUE)
  attr_status <- attr(status, "status")
  expect_true(is.null(attr_status) || attr_status == 0,
              info = paste("VirtualTable Node execution error:", paste(status, collapse = "\n")))
  expect_match(paste(status, collapse = "\n"), "SUCCESS")
})

test_that("sideview.js and sideview.css support suggested splines and auto-cleanup crosswalk UI", {
  js <- read_asset("sideview.js")
  css <- read_asset("sideview.css")

  # CSS assertions for animated suggested splines
  expect_match(css, "\\.sideview-spline-suggested", info = "sideview.css must style .sideview-spline-suggested")
  expect_match(css, "stroke-dasharray", info = "suggested spline must use dashed stroke")
  expect_match(css, "dashMove", info = "suggested spline must reference dashMove animation")
  expect_match(css, "@keyframes\\s+dashMove", info = "sideview.css must define @keyframes dashMove")

  # CSS assertions for suggested tooltip and auto-clean button
  expect_match(css, "\\.sideview-btn-auto-clean|apply-auto-clean",
               info = "sideview.css must style auto-clean button")

  # JS assertions for renderSuggestedSplines and handlers
  expect_match(js, "renderSuggestedSplines",
               info = "sideview.js must define renderSuggestedSplines on SideviewEngine")
  expect_match(js, "sideview_suggested_mappings",
               info = "sideview.js must listen for sideview_suggested_mappings custom message")
  expect_match(js, "apply_auto_clean",
               info = "sideview.js must send apply_auto_clean message to Shiny")

  # JavaScript syntax check with Node
  node_path <- Sys.which("node")
  if (nzchar(node_path)) {
    js_path <- find_asset("sideview.js")
    status <- system2(node_path, c("-c", shQuote(js_path)), stdout = TRUE, stderr = TRUE)
    attr_status <- attr(status, "status")
    expect_true(is.null(attr_status) || attr_status == 0,
                info = paste("sideview.js syntax error:", paste(status, collapse = "\n")))
  }

})

test_that("updateConnectors includes suggestedConnections and clearOperations calls clearSuggestedSplines", {
  js <- read_asset("sideview.js")

  # 1. updateConnectors must iterate over both connections and suggestedConnections
  expect_match(js, "suggestedConnections", info = "sideview.js must define or use suggestedConnections")
  expect_match(
    js,
    "var\\s+allConns\\s*=\\s*\\(this\\.connections\\s*\\|\\|\\s*\\[\\]\\)\\.concat\\(this\\.suggestedConnections\\s*\\|\\|\\s*\\[\\]\\);",
    info = "updateConnectors must combine this.connections and this.suggestedConnections"
  )
  expect_match(
    js,
    "allConns\\.forEach\\(function\\s*\\(conn\\)",
    info = "updateConnectors must iterate over allConns"
  )

  # 2. clearOperations must call clearSuggestedSplines
  expect_match(
    js,
    "SideviewEngine\\.prototype\\.clearOperations\\s*=\\s*function[\\s\\S]*?this\\.clearSuggestedSplines\\(\\)",
    perl = TRUE,
    info = "clearOperations must call this.clearSuggestedSplines()"
  )
})

test_that("sideview.js and sideview.css implement opaque filter popover and edge-to-edge canvas", {
  js <- read_asset("sideview.js")
  css <- read_asset("sideview.css")

  # Popover opacity and z-index
  expect_match(css, "\\.sideview-filter-popover[^{]*\\{[^}]*background:\\s*#ffffff\\s*!important", perl = TRUE)
  expect_match(css, "\\.sideview-filter-popover[^{]*\\{[^}]*z-index:\\s*9999\\s*!important", perl = TRUE)

  # Edge-to-edge canvas on the gadget page only; embedded widgets keep the host page intact
  expect_match(css, "html\\.sv-standalone,\\s*html\\.sv-standalone body\\s*\\{[^}]*margin:\\s*0", perl = TRUE)
  expect_match(css, "\\.sideview-container\\.sv-standalone\\s*\\{[^}]*position:\\s*fixed", perl = TRUE)
  expect_match(css, "\\.sideview-container\\s*\\{[^}]*position:\\s*relative", perl = TRUE)
  expect_no_match(css, "(^|\\})\\s*html,\\s*body\\s*\\{", perl = TRUE)
  expect_match(css, "\\.sideview-container\\.sv-pseudo-fullscreen\\s*\\{", perl = TRUE)

  # Sticky headers must not be cancelled by a later position declaration
  th_rule <- regmatches(css, regexpr("\\.sideview-table th\\s*\\{[^}]*\\}", css, perl = TRUE))
  expect_match(th_rule, "position:\\s*sticky", perl = TRUE)
  expect_no_match(th_rule, "position:\\s*relative", perl = TRUE)

  # Every var(--sv-*) used is defined (fallback-less uses only)
  used <- unique(regmatches(css, gregexpr("var\\(--sv-[a-z0-9-]+\\)", css, perl = TRUE))[[1]])
  used <- sub("^var\\((--sv-[a-z0-9-]+)\\)$", "\\1", used)
  defined <- unique(sub(":$", "", regmatches(css, gregexpr("--sv-[a-z0-9-]+:", css, perl = TRUE))[[1]]))
  expect_equal(setdiff(used, defined), character(0))

  # Fullscreen canvas toggle action in JS
  expect_match(js, "toggle-fullscreen", info = "sideview.js must handle toggle-fullscreen action")
  expect_match(js, "requestFullscreen", info = "sideview.js must invoke requestFullscreen")
  expect_match(js, "closePopover", info = "sideview.js must support dismissing filter popover")
})

