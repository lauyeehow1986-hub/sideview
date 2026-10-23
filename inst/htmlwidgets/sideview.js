/**
 * sideview.js - HTMLWidget binding for Sideview
 * Connects the htmlwidgets lifecycle to the Sideview 2D Infinite Canvas engine.
 */

HTMLWidgets.widget({

  name: 'sideview',

  type: 'output',

  factory: function(el, width, height) {

    var engine = null;

    return {

      renderValue: function(x) {
        // Tear down the previous engine (global listeners, observers, popovers)
        // before re-rendering, e.g. when a Shiny output updates.
        var previous = engine || el._sideviewInstance;
        if (previous && typeof previous.destroy === 'function') {
          try { previous.destroy(); } catch (e) {}
        }
        engine = null;
        el.innerHTML = '';
        el.classList.add('sideview-container');

        // Embedded mode: the widget sizes to its element and the mouse wheel
        // scrolls the page unless Ctrl/Cmd is held.
        var options = Object.assign({
          snapThreshold: 20,
          snapToEdge: true,
          minScale: 0.15,
          maxScale: 3.5,
          mode: 'embedded',
          cards: []
        }, x.options || {});

        if (x.cards && Array.isArray(x.cards)) {
          options.cards = x.cards;
        }

        // Initialize Sideview instance on this container element
        if (typeof window.Sideview !== 'undefined' && typeof window.Sideview.Engine === 'function') {
          engine = new window.Sideview.Engine(el, options);
        } else if (typeof window.initSideview === 'function') {
          engine = window.initSideview(el, options);
        } else {
          console.error('Sideview engine not found. Ensure sideview.js is loaded.');
        }

        el._sideviewInstance = engine;
      },

      resize: function(width, height) {
        if (engine && typeof engine.updateConnectors === 'function') {
          engine.updateConnectors();
        }
      }

    };
  }
});
