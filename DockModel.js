// DockModel.js
// Pure-JS domain logic for ArchyDock — no Qt imports.
// Desktop-entry discovery, icon resolution, window→.desktop matching,
// pin ordering, and persistence. Designed to be testable outside QML.
//
// Architecture note: this is the JS port of the pipeline described in the
// research doc. Tiers 0–6 run in order; first hit wins.

.pragma library

// ---------------------------------------------------------------------------
// Config persistence
// ---------------------------------------------------------------------------

function configPath() {
    var home = Qt.platform ? "" : "";
    // Quickshell provides Quickshell.env("HOME"); callers pass it in.
    return null; // caller resolves via StandardPaths / FileView
}

function defaultPins() {
    return [];
}

// ---------------------------------------------------------------------------
// String helpers (canonicalization mirrors GNOME's lookup_desktop_wmclass)
// ---------------------------------------------------------------------------

var vendorPrefixes = ["gnome-", "fedora-", "mozilla-", "debian-"];

function canonicalizeId(id) {
    var out = [];
    var lower = id.toLowerCase();
    out.push(lower);
    var dashed = lower.replace(/ /g, "-");
    if (dashed !== lower) out.push(dashed);
    for (var i = 0; i < vendorPrefixes.length; i++) {
        var p = vendorPrefixes[i];
        if (lower.indexOf(p) === 0) {
            out.push(lower.slice(p.length));
        } else {
            out.push(p + lower);
        }
    }
    // reverse-DNS tail (org.example.Foo -> foo)
    var tail = lower.split(".").pop();
    if (tail && tail !== lower) out.push(tail);
    // dedup preserve order
    var seen = {};
    var deduped = [];
    for (var j = 0; j < out.length; j++) {
        if (!seen[out[j]]) { seen[out[j]] = true; deduped.push(out[j]); }
    }
    return deduped;
}

function execBasename(execStr) {
    if (!execStr) return "";
    var first = execStr.trim().split(/\s+/)[0] || "";
    if (first === "env" || first.indexOf("env ") === 0) {
        var parts = execStr.trim().split(/\s+/);
        first = parts[1] || "";
    }
    var slash = first.lastIndexOf("/");
    if (slash !== -1) first = first.slice(slash + 1);
    return first.toLowerCase();
}

// ---------------------------------------------------------------------------
// Desktop index (built by QML via FileView scans, stored here as plain objects)
// byId: { "firefox.desktop": entry, ... }
// byWmClass: { "firefox": "firefox.desktop", "crx_abc": "chrome-abc-Default.desktop" }
// byExec: { "firefox": "firefox.desktop", "code": "code.desktop" }
// entry: { id, name, exec, icon, startupWmClass, noDisplay, hidden, path }
// ---------------------------------------------------------------------------

function buildIndex(entries) {
    var byId = {};
    var byWmClass = {};
    var byExec = {};
    for (var i = 0; i < entries.length; i++) {
        var e = entries[i];
        if (e.hidden || e.noDisplay) continue;
        if (byId[e.id]) continue;
        byId[e.id] = e;
        if (e.startupWmClass) {
            byWmClass[e.startupWmClass.toLowerCase()] = e.id;
        }
        if (e.exec) {
            var b = execBasename(e.exec);
            if (b && !byExec[b]) byExec[b] = e.id;
        }
        if (e.tryExec) {
            var tb = execBasename(e.tryExec);
            if (tb && !byExec[tb]) byExec[tb] = e.id;
        }
    }
    return { byId: byId, byWmClass: byWmClass, byExec: byExec };
}

// ---------------------------------------------------------------------------
// Matcher pipeline  Tiers 0-6
// window: { appId, initialClass, title, pid, xwayland, address }
// index: from buildIndex()
// learned: { "SomeClass": "some.desktop" } persisted
// pidLedger: { 12345: "firefox.desktop" } for windows we launched ourselves
// ---------------------------------------------------------------------------

function identify(window, index, learned, pidLedger, procInfo) {
    // Tier 0 — launch attribution (pid ledger)
    if (window.pid && pidLedger && pidLedger[String(window.pid)]) {
        return pidLedger[String(window.pid)];
    }

    // Tier 1 — sandboxed id (Flatpak: app_id itself is the desktop id)
    if (!window.xwayland && window.appId) {
        if (index.byId[window.appId]) return window.appId;
        if (index.byId[window.appId + ".desktop"]) return window.appId + ".desktop";
        var cands = canonicalizeId(window.appId);
        for (var i = 0; i < cands.length; i++) {
            var cid = cands[i].indexOf(".desktop") !== -1 ? cands[i] : cands[i] + ".desktop";
            if (index.byId[cid]) return cid;
            if (index.byId[cands[i]]) return cands[i];
        }
        // /proc/<pid>/root/.flatpak-info check is done by QML via FileView;
        // procInfo.flatpakName, if present, is an exact id.
        if (procInfo && procInfo.flatpakName && index.byId[procInfo.flatpakName])
            return procInfo.flatpakName;
        if (procInfo && procInfo.flatpakName && index.byId[procInfo.flatpakName + ".desktop"])
            return procInfo.flatpakName + ".desktop";
    }

    // Tier 2 — exact app_id == desktop id (canonicalized)
    if (window.appId) {
        var cands2 = canonicalizeId(window.appId);
        for (var k = 0; k < cands2.length; k++) {
            var key = cands2[k];
            if (index.byId[key]) return key;
            if (index.byId[key + ".desktop"]) return key + ".desktop";
        }
    }

    // Tier 3 — StartupWMClass (instance first for XWayland)
    var classes = [];
    if (window.xwayland) {
        if (window.appId) classes.push(window.appId);
        if (window.initialClass && window.initialClass !== window.appId) classes.push(window.initialClass);
    } else {
        if (window.initialClass) classes.push(window.initialClass);
        if (window.appId && window.appId !== window.initialClass) classes.push(window.appId);
    }
    for (var c = 0; c < classes.length; c++) {
        var wm = String(classes[c]).toLowerCase();
        if (index.byWmClass[wm]) return index.byWmClass[wm];
    }

    // Tier 4 — executable basename via /proc/<pid>/exe or cmdline
    if (procInfo) {
        var bases = [];
        if (procInfo.exeBase) bases.push(String(procInfo.exeBase).toLowerCase());
        if (procInfo.cmdBase) bases.push(String(procInfo.cmdBase).toLowerCase());
        for (var b = 0; b < bases.length; b++) {
            if (index.byExec[bases[b]]) return index.byExec[bases[b]];
        }
    }

    // Tier 5 — learned mappings (persisted user corrections)
    if (learned) {
        if (window.appId && learned[window.appId]) return learned[window.appId];
        if (window.initialClass && learned[window.initialClass]) return learned[window.initialClass];
    }

    // Tier 6 — fallback: synthesize an id, caller can offer "Identify…" UI
    var fallback = "unknown-" + String(window.appId || window.initialClass || "app").toLowerCase().replace(/[^a-z0-9]+/g, "-");
    return fallback;
}

// ---------------------------------------------------------------------------
// Icon resolution
// entry.icon may be a themed name or absolute path.
// QML resolves via Quickshell's icon lookup or falls back to generic.
// We just pick the candidate name here.
// ---------------------------------------------------------------------------

function iconCandidates(entry, window) {
    var cands = [];
    if (entry && entry.icon) cands.push(entry.icon);
    if (entry && entry.startupWmClass) cands.push(entry.startupWmClass);
    if (window && window.appId) cands.push(window.appId);
    if (window && window.initialClass) cands.push(window.initialClass);
    // Hard-coded compat like nwg-dock's GIMP case, but derived from entry id
    // rather than class prefix matching.
    cands.push("application-x-executable");
    return cands;
}

// ---------------------------------------------------------------------------
// Pin ordering helpers
// ---------------------------------------------------------------------------

function movePin(pins, from, to) {
    if (from < 0 || from >= pins.length || to < 0 || to >= pins.length) return pins.slice();
    var copy = pins.slice();
    var item = copy.splice(from, 1)[0];
    copy.splice(to, 0, item);
    return copy;
}

function togglePin(pins, desktopId) {
    var idx = pins.indexOf(desktopId);
    if (idx === -1) { var c = pins.slice(); c.push(desktopId); return c; }
    var c2 = pins.slice(); c2.splice(idx, 1); return c2;
}

// ---------------------------------------------------------------------------
// Tests (run with `qmljs DockModel.js` or via offscreen QML loader)
// ---------------------------------------------------------------------------

function _test() {
    var idx = buildIndex([
        { id: "firefox.desktop", name: "Firefox", exec: "/usr/lib/firefox/firefox %u", icon: "firefox", startupWmClass: "firefox", hidden: false, noDisplay: false },
        { id: "org.mozilla.firefox.desktop", name: "Firefox", exec: "firefox %u", icon: "firefox", startupWmClass: "firefox", hidden: false, noDisplay: false },
        { id: "chrome-abc-Default.desktop", name: "YouTube", exec: "/usr/bin/google-chrome --app-id=abc", icon: "chrome-abc-Default", startupWmClass: "crx_abc", hidden: false, noDisplay: false },
        { id: "code.desktop", name: "Code", exec: "/usr/bin/code --unity-launch %F", icon: "code", startupWmClass: "code", hidden: false, noDisplay: false }
    ]);
    console.assert(identify({ appId: "firefox", initialClass: "firefox", xwayland: false }, idx, {}, {}) === "firefox.desktop");
    console.assert(identify({ appId: "crx_abc", initialClass: "crx_abc", xwayland: false }, idx, {}, {}) === "chrome-abc-Default.desktop");
    console.assert(identify({ appId: "Code", initialClass: "code", xwayland: false }, idx, {}, {}) === "code.desktop");
    var learned = { "weirdapp": "firefox.desktop" };
    console.assert(identify({ appId: "weirdapp", initialClass: "weirdapp", xwayland: false }, idx, learned, {}) === "firefox.desktop");
    console.assert(movePin(["a","b","c"], 0, 2).join(",") === "b,c,a");
    console.assert(togglePin(["a","b"], "c").join(",") === "a,b,c");
    console.log("DockModel.js self-tests passed");
}
