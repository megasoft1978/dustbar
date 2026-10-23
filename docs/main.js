(function () {
  var d = document, root = d.documentElement;
  function $(s, c) { return (c || d).querySelector(s); }
  function $$(s, c) { return [].slice.call((c || d).querySelectorAll(s)); }

  // Theme: manual override stored in localStorage; otherwise follows the system.
  var tbtn = $("#theme");
  function isDark() {
    var t = root.dataset.theme;
    return t ? t === "dark" : matchMedia("(prefers-color-scheme: dark)").matches;
  }
  // The video poster cannot follow the theme from CSS, so its src is swapped here (CSS-driven images use .on-light/.on-dark).
  function syncPoster() {
    var vid = $("#demo");
    if (vid) vid.poster = "assets/poster-" + (isDark() ? "dark" : "light") + ".png";
  }
  syncPoster();
  if (tbtn) tbtn.addEventListener("click", function () {
    var next = isDark() ? "light" : "dark";
    root.dataset.theme = next;
    try { localStorage.setItem("dustbar-theme", next); } catch (e) {}
    syncPoster();
  });
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", syncPoster);

  // Tabs (ARIA tabs pattern with arrow, Home and End keys). Each .tablist is its own set.
  $$(".tablist").forEach(function (list) {
    var tabs = $$('[role="tab"]', list);
    function select(tab, focus) {
      tabs.forEach(function (t) {
        var on = t === tab;
        t.setAttribute("aria-selected", on);
        t.tabIndex = on ? 0 : -1;
        $("#" + t.getAttribute("aria-controls")).hidden = !on;
      });
      if (focus) tab.focus();
    }
    tabs.forEach(function (tab, i) {
      tab.addEventListener("click", function () { select(tab); });
      tab.addEventListener("keydown", function (e) {
        var j = { ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: tabs.length - 1 }[e.key];
        if (j === undefined) return;
        e.preventDefault();
        select(tabs[(j + tabs.length) % tabs.length], true);
      });
    });
  });
  // Hero secondary CTA opens the Homebrew tab in the install section.
  var hb = $("#hero-brew");
  if (hb) hb.addEventListener("click", function () { $("#itab-brew").click(); });

  // Video: autoplay only if motion is allowed; otherwise poster plus a play button.
  var v = $("#demo"), pb = $("#play");
  if (v && pb) {
    var calm = matchMedia("(prefers-reduced-motion: reduce)").matches;
    v.controls = false;
    pb.hidden = false;
    var sync = function () { pb.hidden = !v.paused; };
    v.addEventListener("play", sync);
    v.addEventListener("pause", sync);
    pb.addEventListener("click", function () { v.play(); });
    v.addEventListener("click", function () { v.paused ? v.play() : v.pause(); });
    if (!calm) v.play().catch(function () {});
  }

  // Copy buttons: Clipboard API, then a hidden textarea, then select the text so Cmd+C works.
  $$(".copy").forEach(function (b) {
    b.addEventListener("click", function () {
      var code = $("code", b.parentNode), text = code.textContent;
      var done = function (ok) {
        b.textContent = ok ? "Copied" : "Press Cmd+C";
        setTimeout(function () { b.textContent = "Copy"; }, 1800);
      };
      var fallback = function () {
        var ta = d.createElement("textarea"), ok = false;
        ta.value = text; ta.setAttribute("readonly", ""); ta.style.cssText = "position:fixed;opacity:0";
        d.body.appendChild(ta); ta.select();
        try { ok = d.execCommand("copy"); } catch (e) {}
        d.body.removeChild(ta);
        if (!ok) { var r = d.createRange(), s = window.getSelection(); r.selectNodeContents(code); s.removeAllRanges(); s.addRange(r); }
        done(ok);
      };
      if (navigator.clipboard) navigator.clipboard.writeText(text).then(function () { done(true); }, fallback);
      else fallback();
    });
  });

  // Benchmarks: every number comes from benchmarks.json. Missing file keeps the dash placeholders.
  function n(x, f) { return x.toLocaleString("en-US", { minimumFractionDigits: f || 0, maximumFractionDigits: f || 0 }); }
  function set(k, val, sub) {
    var a = $('[data-v="' + k + '"]'), b = $('[data-s="' + k + '"]');
    if (a && val) a.textContent = val;
    if (b && sub) b.textContent = sub;
  }
  fetch("benchmarks.json").then(function (r) { return r.json(); }).then(function (j) {
    var ok = function (x) { return typeof x === "number"; };
    if (ok(j.binaryBytes)) set("binary", n(j.binaryBytes / 1e6, 1) + " MB", n(j.binaryBytes) + " bytes, release, stripped");
    if (ok(j.idleFootprintMB)) set("mem", n(j.idleFootprintMB, 1) + " MB", "Physical footprint after " + (j.idleSeconds || 60) + " s idle, popover closed");
    if (ok(j.idleCpuPct)) set("cpu", n(j.idleCpuPct, 1) + " %", "Mean over " + (j.idleSeconds || 60) + " s idle");
    if (ok(j.scan1MSeconds)) set("scan1", n(j.scan1MSeconds, 1) + " s", n(j.scan1MFiles) + " files, warm cache");
    if (ok(j.scan8MSeconds)) set("scan8", n(j.scan8MSeconds, 1) + " s", n(j.scan8MFiles) + " files, warm cache");
    if (ok(j.refreshSpeedup)) set("refresh", "~" + Math.round(j.refreshSpeedup) + "x", "20 changed folders on ~/Library: " + n(j.refreshIncrementalSeconds, 3) + " s vs " + n(j.refreshFullSeconds, 2) + " s full");
    var m = j.machine || {}, meta = $("#bench-meta");
    if (meta && m.cpu) meta.textContent = m.cpu + ", " + m.cores + " cores (" + m.model + "), macOS " + j.macos + ", measured " + String(j.date).slice(0, 10) + (j.warmCache ? ", warm cache" : "") + ".";
  }).catch(function () {});
})();
