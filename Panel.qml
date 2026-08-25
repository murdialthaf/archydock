import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "DockModel.js" as DockModel

// ArchyDock v0.2.0 — persistent dock panel for Hyprland/Omarchy
// Features: correct .desktop identification, draggable pins, progressive
// icon fallback, all 4 dock positions, GUI settings, launcher button.
Item {
    id: root

    property var shell: null

    // Persisted state
    property var pinnedIds: []
    property var learnedMap: ({})
    property var runningApps: []

    // Appearance
    property int iconSize: 44
    property int spacing: 8
    property int padding: 12
    property int radius: 18
    property bool autohide: false
    property string position: "bottom"

    // Launcher
    property string launcherDesktop: "nwg-drawer.desktop"
    property string launcherIconName: "view-app-grid-symbolic"

    // Runtime
    property bool opened: true
    property bool isVertical: position === "left" || position === "right"

    function open(payloadJson) {
        try {
            var p = JSON.parse(payloadJson || "{}");
            if (p.pins) pinnedIds = p.pins;
        } catch (e) {}
        opened = true;
    }
    function close() { opened = false; }
    function toggle() { opened = !opened; }

    // ------------------------------------------------------------------ Ipc
    IpcHandler {
        target: "archydock"
        function open(payloadJson: string): string { root.open(payloadJson); return "ok"; }
        function close(): string { root.close(); return "ok"; }
        function toggle(): string { root.toggle(); return root.opened ? "open" : "closed"; }
        function state(): string { return root.opened ? "open" : "closed"; }
        function pins(): string { return JSON.stringify(root.pinnedIds); }
        function pin(id: string): string {
            var next = DockModel.togglePin(root.pinnedIds, id);
            root.pinnedIds = next; savePins();
            return JSON.stringify(next);
        }
        function reorder(from: int, to: int): string {
            var next = DockModel.movePin(root.pinnedIds, from, to);
            root.pinnedIds = next; savePins();
            return JSON.stringify(next);
        }
        function ping(): string { return "ok"; }
    }

    // ------------------------------------------------------------ persistence
    Process {
        id: ensureConfigDir
        command: ["bash","-lc","mkdir -p \"$HOME/.config/archydock\""]
    }

    FileView {
        id: configFile
        path: Quickshell.env("HOME") + "/.config/archydock/config.json"
        watchChanges: true
        onFileChanged: reloadConfig()
        onLoaded: reloadConfig()
        onLoadFailed: function(err) {
            if (String(err).indexOf("No such file") !== -1) {
                ensureConfigDir.running = true;
                saveTimer.restart();
            }
        }
    }

    Timer { id: saveTimer; interval: 120; repeat: false; onTriggered: savePins() }

    function reloadConfig() {
        try {
            var txt = configFile.text();
            if (!txt) return;
            var obj = JSON.parse(txt);
            if (Array.isArray(obj.pinnedIds)) pinnedIds = obj.pinnedIds.slice();
            if (obj.learnedMap && typeof obj.learnedMap === "object") learnedMap = obj.learnedMap;
            if (obj.iconSize) iconSize = obj.iconSize;
            if (obj.spacing !== undefined) spacing = obj.spacing;
            if (obj.padding !== undefined) padding = obj.padding;
            if (obj.radius !== undefined) radius = obj.radius;
            if (obj.position) position = obj.position;
            if (obj.autohide !== undefined) autohide = obj.autohide;
            if (obj.launcherDesktop) launcherDesktop = obj.launcherDesktop;
        } catch (e) { console.warn("ArchyDock: bad config.json", e); }
    }

    function savePins() {
        ensureConfigDir.running = true;
        var payload = JSON.stringify({
            pinnedIds: pinnedIds,
            learnedMap: learnedMap,
            iconSize: iconSize,
            spacing: spacing,
            padding: padding,
            radius: radius,
            position: position,
            autohide: autohide,
            launcherDesktop: launcherDesktop
        }, null, 2);
        Qt.callLater(function(){ configFile.setText(payload); });
    }

    // ----------------------------------------------------------- desktop index
    property var desktopIndex: ({ byId: {}, byWmClass: {}, byExec: {} })
    property var desktopEntries: []
    property bool desktopReady: false

    Process {
        id: desktopScanProc
        command: ["bash", "-lc",
            "set -o pipefail; "
          + "dirs=\"${XDG_DATA_HOME:-$HOME/.local/share}/applications\"; "
          + "IFS=: read -ra _dirs <<< \"${XDG_DATA_DIRS:-/usr/local/share:/usr/share}\"; "
          + "for d in \"${_dirs[@]}\"; do dirs+=\" $d/applications\"; done; "
          + "dirs+=\" /var/lib/flatpak/exports/share/applications $HOME/.local/share/flatpak/exports/share/applications\"; "
          + "cnt=0; for d in $dirs; do [ -d \"$d\" ] || continue; "
          + "for f in \"$d\"/*.desktop; do [ -f \"$f\" ] || continue; "
          + "id=$(basename \"$f\"); "
          + "name=$(grep -m1 '^Name=' \"$f\" 2>/dev/null | cut -d= -f2- | tr -d '|' | head -c 80); "
          + "execv=$(grep -m1 '^Exec=' \"$f\" 2>/dev/null | cut -d= -f2- | tr -d '|' | head -c 180); "
          + "icon=$(grep -m1 '^Icon=' \"$f\" 2>/dev/null | cut -d= -f2- | tr -d '|' | head -c 120); "
          + "wm=$(grep -m1 '^StartupWMClass=' \"$f\" 2>/dev/null | cut -d= -f2- | tr -d '|' | head -c 80); "
          + "nodisp=$(grep -m1 '^NoDisplay=' \"$f\" 2>/dev/null | cut -d= -f2-); "
          + "hidden=$(grep -m1 '^Hidden=' \"$f\" 2>/dev/null | cut -d= -f2-); "
          + "echo \"$id|$name|$execv|$icon|$wm|$nodisp|$hidden\"; "
          + "cnt=$((cnt+1)); [ $cnt -ge 500 ] && break 2; "
          + "done; done | head -n 600"
        ]
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = (text || "").trim().split("\n").filter(function(x){ return x.length>0; });
                var entries = [];
                for (var i=0;i<lines.length;i++) {
                    var parts = lines[i].split("|");
                    if (parts.length < 7) continue;
                    var id = parts[0];
                    if (!id || id.indexOf(".desktop")===-1) continue;
                    entries.push({
                        id: id,
                        name: parts[1] || id.replace(".desktop",""),
                        exec: parts[2] || "",
                        tryExec: "",
                        icon: parts[3] || "",
                        startupWmClass: parts[4] || "",
                        noDisplay: String(parts[5]).toLowerCase()==="true",
                        hidden: String(parts[6]).toLowerCase()==="true",
                        path: id
                    });
                }
                desktopEntries = entries;
                desktopIndex = DockModel.buildIndex(entries);
                desktopReady = true;
                recomputeRunning();
            }
        }
        stderr: StdioCollector { onStreamFinished: { if (text) console.warn("ArchyDock desktop scan:", text.slice(0,400)); } }
    }

    // -------------------------------------------------------------- Hyprland
    property var hyprClients: []
    property string hyprError: ""

    Process {
        id: hyprProc
        command: ["hyprctl", "-j", "clients"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var arr = JSON.parse(text || "[]");
                    hyprError = "";
                    var next = [];
                    for (var i=0;i<arr.length;i++) {
                        var c = arr[i];
                        if (!c.mapped || c.hidden) continue;
                        next.push({
                            appId: c.class || "",
                            initialClass: c.initialClass || c.class || "",
                            title: c.title || "",
                            pid: c.pid || 0,
                            xwayland: !!c.xwayland,
                            address: c.address || ""
                        });
                    }
                    hyprClients = next;
                    recomputeRunning();
                } catch (e) { hyprError = String(e).slice(0,120); console.warn("ArchyDock: hyprctl parse", e, text ? text.slice(0,300) : ""); }
            }
        }
        stderr: StdioCollector { onStreamFinished: { if (text) { hyprError = text.slice(0,120); console.warn("ArchyDock hyprctl:", text.slice(0,400)); } } }
    }

    Process {
        id: hyprCheckProc
        command: ["bash","-lc","command -v hyprctl >/dev/null 2>&1 && hyprctl -j clients >/dev/null 2>&1 && echo ok || echo missing"]
        stdout: StdioCollector { onStreamFinished: {
                if ((text||"").trim() !== "ok") {
                    hyprError = "hyprctl not found — dock shows pinned apps only";
                    console.warn("ArchyDock:", hyprError);
                }
            }
        }
    }

    // Derived filtered model
    property var unpinnedRunning: []

    function updateUnpinned() {
        var out = [];
        for (var i=0;i<runningApps.length;i++) if (pinnedIds.indexOf(runningApps[i].desktopId)===-1) out.push(runningApps[i]);
        unpinnedRunning = out;
    }
    onRunningAppsChanged: updateUnpinned()
    onPinnedIdsChanged: updateUnpinned()

    Timer {
        id: pollTimer
        interval: 900
        repeat: true
        running: root.opened
        onTriggered: hyprProc.running = true
        Component.onCompleted: { desktopScanProc.running = true; hyprProc.running = true; hyprCheckProc.running = true; }
    }

    // pidLedger
    property var pidLedger: ({})
    property var pidLedgerByDesktop: ({})

    function noteLaunch(desktopId, pidHint) {
        var now = Date.now();
        pidLedgerByDesktop[desktopId] = now;
    }

    function recomputeRunning() {
        if (!desktopReady) return;
        var now = Date.now();
        for (var k in pidLedgerByDesktop) {
            if (now - pidLedgerByDesktop[k] > 8000) delete pidLedgerByDesktop[k];
        }
        var next = [];
        var seen = {};
        for (var i=0;i<hyprClients.length;i++) {
            var w = hyprClients[i];
            var did = DockModel.identify(w, desktopIndex, learnedMap, pidLedger, null);
            if (did.indexOf("unknown-")===0) {
                var best = null, bestAge = Infinity;
                for (var ld in pidLedgerByDesktop) {
                    var age = now - pidLedgerByDesktop[ld];
                    if (age < bestAge) { bestAge = age; best = ld; }
                }
                if (best && !seen[best]) did = best;
            }
            if (seen[did]) {
                for (var g=0;g<next.length;g++) if (next[g].desktopId===did) { next[g].addresses.push(w.address); break; }
                continue;
            }
            seen[did] = true;
            var entry = desktopIndex.byId[did];
            var iconCands = DockModel.iconCandidates(entry, w);
            next.push({
                desktopId: did,
                appId: w.appId,
                title: w.title,
                address: w.address,
                addresses: [w.address],
                xwayland: w.xwayland,
                iconName: iconCands[0] || "application-x-executable"
            });
        }
        runningApps = next;
    }

    // ------------------------------------------------------------------ dock
    PanelWindow {
        id: dockWindow
        visible: root.opened
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.namespace: "archydock"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Auto
        mask: Region { item: dockCard }

        BorderSurface {
            id: dockCard
            x: {
                if (root.position === "left") return Style.space(12);
                if (root.position === "right") return parent.width - width - Style.space(12);
                return (parent.width - width) / 2;
            }
            y: {
                if (root.position === "bottom") return parent.height - height - Style.space(12);
                if (root.position === "top") return Style.space(12);
                return (parent.height - height) / 2;
            }
            width: {
                if (root.isVertical) return root.iconSize + root.padding * 2 + borderLeft + borderRight;
                return layoutLoader.implicitWidth + root.padding * 2 + borderLeft + borderRight;
            }
            height: {
                if (root.isVertical) return layoutLoader.implicitHeight + root.padding * 2 + borderTop + borderBottom;
                return root.iconSize + root.padding * 2 + borderTop + borderBottom;
            }
            color: Util.alpha(Color.background, 0.92)
            borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(1)))
            radius: root.radius

            // Right-click on background opens settings
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.RightButton
                onClicked: settingsContext.opened = true
                z: -1
            }

            // Layout switches between Row (bottom/top) and Column (left/right)
            Loader {
                id: layoutLoader
                anchors.centerIn: parent
                active: true
                sourceComponent: root.isVertical ? verticalLayout : horizontalLayout
            }

            Component {
                id: horizontalLayout
                Row {
                    spacing: root.spacing

                    Repeater {
                        model: root.pinnedIds
                        delegate: DockIcon {
                            desktopId: modelData
                            iconName: {
                                var entry = root.desktopIndex.byId[modelData];
                                return (DockModel.iconCandidates(entry, null)[0]) || "application-x-executable";
                            }
                            isRunning: {
                                for (var i=0;i<root.runningApps.length;i++) if (root.runningApps[i].desktopId === modelData) return true;
                                return false;
                            }
                            isPinned: true
                            iconSize: root.iconSize
                            onClicked: {
                                for (var i=0;i<root.runningApps.length;i++) if (root.runningApps[i].desktopId === desktopId) {
                                    focusProc.command = ["hyprctl","dispatch","focuswindow","address:" + root.runningApps[i].address];
                                    focusProc.running = true; return;
                                }
                                launchDesktop(desktopId);
                            }
                            onRightClicked: contextMenu.openFor(desktopId, mapToGlobal(0,0))
                            dragIndex: index
                            onDragMove: function(from,to){
                                var next = DockModel.movePin(root.pinnedIds, from, to);
                                root.pinnedIds = next; savePins();
                            }
                        }
                    }

                    Rectangle {
                        visible: pinnedSeparatorVisible
                        property bool pinnedSeparatorVisible: {
                            if (root.runningApps.length===0) return false;
                            for (var i=0;i<root.runningApps.length;i++) {
                                if (root.pinnedIds.indexOf(root.runningApps[i].desktopId)===-1) return true;
                            }
                            return false;
                        }
                        width: 1; height: root.iconSize * 0.6
                        anchors.verticalCenter: parent.verticalCenter
                        color: Util.alpha(Color.popups.text, 0.16)
                        radius: 1
                    }

                    Repeater {
                        model: root.unpinnedRunning
                        delegate: DockIcon {
                            desktopId: modelData.desktopId
                            iconName: modelData.iconName
                            isRunning: true
                            isPinned: false
                            iconSize: root.iconSize
                            onClicked: {
                                focusProc.command = ["hyprctl","dispatch","focuswindow","address:" + modelData.address];
                                focusProc.running = true;
                            }
                            onRightClicked: contextMenu.openFor(modelData.desktopId, mapToGlobal(0,0))
                        }
                    }

                    // Launcher button
                    Item {
                        width: root.iconSize; height: root.iconSize
                        Rectangle {
                            anchors.fill: parent
                            radius: 10
                            color: launcherMouse.containsMouse ? Util.alpha(Color.accent, 0.18) : "transparent"
                        }
                        Image {
                            anchors.centerIn: parent
                            width: root.iconSize - 12; height: width
                            source: "image://icon/" + root.launcherIconName
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                        }
                        MouseArea {
                            id: launcherMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            onClicked: function(ev) {
                                if (ev.button === Qt.LeftButton) {
                                    var base = root.launcherDesktop.replace(/\.desktop$/, "");
                                    launchProc.command = ["gtk-launch", base];
                                    launchProc.running = true;
                                    noteLaunch(root.launcherDesktop, 0);
                                } else if (ev.button === Qt.RightButton) {
                                    settingsContext.opened = true;
                                }
                            }
                        }
                    }

                    Item {
                        visible: root.pinnedIds.length===0 && root.runningApps.length===0
                        width: placeholder.width; height: placeholder.height
                        Text {
                            id: placeholder
                            anchors.centerIn: parent
                            text: "ArchyDock — pin an app to begin"
                            color: Util.alpha(Color.popups.text, 0.55)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                        }
                    }
                }
            }

            Component {
                id: verticalLayout
                Column {
                    spacing: root.spacing

                    Repeater {
                        model: root.pinnedIds
                        delegate: DockIcon {
                            desktopId: modelData
                            iconName: {
                                var entry = root.desktopIndex.byId[modelData];
                                return (DockModel.iconCandidates(entry, null)[0]) || "application-x-executable";
                            }
                            isRunning: {
                                for (var i=0;i<root.runningApps.length;i++) if (root.runningApps[i].desktopId === modelData) return true;
                                return false;
                            }
                            isPinned: true
                            iconSize: root.iconSize
                            onClicked: {
                                for (var i=0;i<root.runningApps.length;i++) if (root.runningApps[i].desktopId === desktopId) {
                                    focusProc.command = ["hyprctl","dispatch","focuswindow","address:" + root.runningApps[i].address];
                                    focusProc.running = true; return;
                                }
                                launchDesktop(desktopId);
                            }
                            onRightClicked: contextMenu.openFor(desktopId, mapToGlobal(0,0))
                            dragIndex: index
                            onDragMove: function(from,to){
                                var next = DockModel.movePin(root.pinnedIds, from, to);
                                root.pinnedIds = next; savePins();
                            }
                        }
                    }

                    Rectangle {
                        visible: pinnedSeparatorVisible
                        property bool pinnedSeparatorVisible: {
                            if (root.runningApps.length===0) return false;
                            for (var i=0;i<root.runningApps.length;i++) {
                                if (root.pinnedIds.indexOf(root.runningApps[i].desktopId)===-1) return true;
                            }
                            return false;
                        }
                        width: root.iconSize * 0.6; height: 1
                        anchors.horizontalCenter: parent.horizontalCenter
                        color: Util.alpha(Color.popups.text, 0.16)
                        radius: 1
                    }

                    Repeater {
                        model: root.unpinnedRunning
                        delegate: DockIcon {
                            desktopId: modelData.desktopId
                            iconName: modelData.iconName
                            isRunning: true
                            isPinned: false
                            iconSize: root.iconSize
                            onClicked: {
                                focusProc.command = ["hyprctl","dispatch","focuswindow","address:" + modelData.address];
                                focusProc.running = true;
                            }
                            onRightClicked: contextMenu.openFor(modelData.desktopId, mapToGlobal(0,0))
                        }
                    }

                    // Launcher button (vertical)
                    Item {
                        width: root.iconSize; height: root.iconSize
                        Rectangle {
                            anchors.fill: parent
                            radius: 10
                            color: launcherMouseV.containsMouse ? Util.alpha(Color.accent, 0.18) : "transparent"
                        }
                        Image {
                            anchors.centerIn: parent
                            width: root.iconSize - 12; height: width
                            source: "image://icon/" + root.launcherIconName
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                        }
                        MouseArea {
                            id: launcherMouseV
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            onClicked: function(ev) {
                                if (ev.button === Qt.LeftButton) {
                                    var base = root.launcherDesktop.replace(/\.desktop$/, "");
                                    launchProc.command = ["gtk-launch", base];
                                    launchProc.running = true;
                                    noteLaunch(root.launcherDesktop, 0);
                                } else if (ev.button === Qt.RightButton) {
                                    settingsContext.opened = true;
                                }
                            }
                        }
                    }

                    Item {
                        visible: root.pinnedIds.length===0 && root.runningApps.length===0
                        width: placeholderV.width; height: placeholderV.height
                        Text {
                            id: placeholderV
                            anchors.centerIn: parent
                            text: "ArchyDock"
                            color: Util.alpha(Color.popups.text, 0.55)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                        }
                    }
                }
            }
        }
    }

    // ----------------------------------------------------------- context menu
    Item {
        id: contextMenu
        property string targetId: ""
        property var targetGlobalPos: null
        property bool opened: false
        function openFor(id, globalPos) {
            targetId = id;
            targetGlobalPos = globalPos;
            opened = true;
            closeTimer.restart();
        }
        function doPinToggle() {
            var next = DockModel.togglePin(root.pinnedIds, targetId);
            root.pinnedIds = next; savePins(); opened = false;
        }
        function doNewWindow() {
            launchDesktop(targetId); opened = false;
        }
        function doCloseAll() {
            for (var i=0;i<root.runningApps.length;i++) if (root.runningApps[i].desktopId===targetId) {
                var addrs = root.runningApps[i].addresses || [root.runningApps[i].address];
                for (var a=0;a<addrs.length;a++) {
                    closeProc.command = ["hyprctl","dispatch","closewindow","address:" + addrs[a]];
                    closeProc.running = true;
                }
            }
            opened = false;
        }
        Timer { id: closeTimer; interval: 3200; onTriggered: contextMenu.opened = false }
    }

    PanelWindow {
        id: menuWindow
        visible: contextMenu.opened
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.namespace: "archydock-menu"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        mask: Region { item: menuCard }

        MouseArea {
            anchors.fill: parent
            onClicked: contextMenu.opened = false
        }

        BorderSurface {
            id: menuCard
            x: {
                if (root.position === "left") return Style.space(12) + root.iconSize + root.padding + Style.space(8);
                if (root.position === "right") return parent.width - width - Style.space(12) - root.iconSize - root.padding - Style.space(8);
                return (parent.width - width) / 2;
            }
            y: {
                if (root.position === "bottom") return parent.height - height - root.iconSize - root.padding - Style.space(20);
                if (root.position === "top") return root.iconSize + root.padding + Style.space(20);
                return (parent.height - height) / 2;
            }
            width: menuCol.implicitWidth + Style.space(20)
            height: menuCol.implicitHeight + Style.space(16)
            color: Util.alpha(Color.background, 0.98)
            borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(1)))
            radius: Style.cornerRadius

            Column {
                id: menuCol
                anchors.centerIn: parent
                spacing: Style.space(6)
                width: parent.width - Style.space(20)

                property bool isPinned: root.pinnedIds.indexOf(contextMenu.targetId) !== -1
                property string label: {
                    var e = root.desktopIndex.byId[contextMenu.targetId];
                    return e ? e.name : contextMenu.targetId.replace(".desktop","").replace("unknown-","");
                }

                Text {
                    text: menuCol.label
                    color: Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                    width: parent.width
                }
                Rectangle { width: parent.width; height: 1; color: Util.alpha(Color.popups.text, 0.12) }

                Repeater {
                    model: [
                        { text: menuCol.isPinned ? "Unpin" : "Pin", action: function(){ contextMenu.doPinToggle(); } },
                        { text: "New window", action: function(){ contextMenu.doNewWindow(); } },
                        { text: "Close all windows", action: function(){ contextMenu.doCloseAll(); } }
                    ]
                    delegate: Rectangle {
                        width: menuCol.width; height: 28; radius: 6
                        color: ma.containsMouse ? Util.alpha(Color.accent, 0.18) : "transparent"
                        Text { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.leftMargin: 8; text: modelData.text; color: Color.popups.text; font.family: Style.font.family; font.pixelSize: Style.font.body }
                        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: modelData.action() }
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------- settings menu
    Item {
        id: settingsContext
        property bool opened: false
    }

    PanelWindow {
        id: settingsWindow
        visible: settingsContext.opened
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.namespace: "archydock-settings"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        mask: Region { item: settingsCard }

        MouseArea {
            anchors.fill: parent
            onClicked: settingsContext.opened = false
        }

        BorderSurface {
            id: settingsCard
            anchors.centerIn: parent
            width: settingsCol.implicitWidth + Style.space(40)
            height: settingsCol.implicitHeight + Style.space(40)
            color: Util.alpha(Color.popups.background, 0.98)
            borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(1)))
            radius: Style.cornerRadius

            Column {
                id: settingsCol
                anchors.centerIn: parent
                width: parent.width - Style.space(40)
                spacing: Style.space(14)

                Text {
                    text: "ArchyDock Settings"
                    color: Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.heading
                    font.bold: true
                }

                Rectangle { width: parent.width; height: 1; color: Util.alpha(Color.popups.text, 0.12) }

                // Position
                PanelSectionHeader { text: "Position" }
                ButtonGroup {
                    width: parent.width
                    options: ["Bottom", "Top", "Left", "Right"]
                    value: {
                        var map = { bottom: "Bottom", top: "Top", left: "Left", right: "Right" };
                        return map[root.position] || "Bottom";
                    }
                    onChanged: function(val) {
                        root.position = val.toLowerCase();
                        savePins();
                    }
                }

                // Icon Size
                PanelSectionHeader { text: "Icon Size" }
                Row {
                    spacing: Style.space(8)
                    width: parent.width
                    Text {
                        text: root.iconSize + "px"
                        color: Color.popups.text
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        width: 50
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    PanelSlider {
                        width: parent.width - 58
                        minimum: 24; maximum: 80; step: 4
                        integer: true
                        value: root.iconSize
                        onMoved: function(val) { root.iconSize = val; }
                        onReleased: function(val) { root.iconSize = val; savePins(); }
                    }
                }

                // Spacing
                PanelSectionHeader { text: "Spacing" }
                Row {
                    spacing: Style.space(8)
                    width: parent.width
                    Text {
                        text: root.spacing + "px"
                        color: Color.popups.text
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        width: 50
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    PanelSlider {
                        width: parent.width - 58
                        minimum: 4; maximum: 20; step: 2
                        integer: true
                        value: root.spacing
                        onMoved: function(val) { root.spacing = val; }
                        onReleased: function(val) { root.spacing = val; savePins(); }
                    }
                }

                // Padding
                PanelSectionHeader { text: "Padding" }
                Row {
                    spacing: Style.space(8)
                    width: parent.width
                    Text {
                        text: root.padding + "px"
                        color: Color.popups.text
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        width: 50
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    PanelSlider {
                        width: parent.width - 58
                        minimum: 4; maximum: 24; step: 2
                        integer: true
                        value: root.padding
                        onMoved: function(val) { root.padding = val; }
                        onReleased: function(val) { root.padding = val; savePins(); }
                    }
                }

                // Corner Radius
                PanelSectionHeader { text: "Corner Radius" }
                Row {
                    spacing: Style.space(8)
                    width: parent.width
                    Text {
                        text: root.radius + "px"
                        color: Color.popups.text
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        width: 50
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    PanelSlider {
                        width: parent.width - 58
                        minimum: 0; maximum: 24; step: 2
                        integer: true
                        value: root.radius
                        onMoved: function(val) { root.radius = val; }
                        onReleased: function(val) { root.radius = val; savePins(); }
                    }
                }

                Rectangle { width: parent.width; height: 1; color: Util.alpha(Color.popups.text, 0.12) }

                // Autohide
                Row {
                    width: parent.width
                    spacing: Style.space(8)
                    Text {
                        text: "Autohide"
                        color: Color.popups.text
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Item { width: parent.width - 140; height: 1 }
                    ToggleSwitch {
                        checked: root.autohide
                        onToggled: { root.autohide = !root.autohide; savePins(); }
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------- process handlers
    Process { id: focusProc }
    Process { id: closeProc }
    Process { id: launchProc }

    function launchDesktop(desktopId) {
        var base = String(desktopId).replace(/\.desktop$/,"");
        launchProc.command = ["gtk-launch", base];
        launchProc.running = true;
        noteLaunch(desktopId, 0);
    }

    Component.onCompleted: {}
}

// ---------------------------------------------------------------- DockIcon
// Inline component with progressive icon fallback chain.
// When Image fails, cycles through DockModel.iconCandidates() entries
// before showing a styled initial glyph.
component DockIcon : Item {
    id: iconRoot
    property string desktopId: ""
    property string iconName: "application-x-executable"
    property bool isRunning: false
    property bool isPinned: false
    property int iconSize: 44
    property int dragIndex: -1
    signal clicked()
    signal rightClicked(var globalPos)
    signal dragMove(int from, int to)

    // Progressive icon fallback
    property int fallbackIndex: 0
    property var entry: root.desktopIndex.byId[desktopId]
    property var allCandidates: {
        var e = root.desktopIndex.byId[desktopId];
        return DockModel.iconCandidates(e, null);
    }

    width: iconSize; height: iconSize

    Rectangle {
        anchors.fill: parent
        radius: 10
        color: iconMouse.containsMouse ? Util.alpha(Color.accent, 0.18) : "transparent"
        border.width: 0
    }

    Image {
        id: iconImg
        anchors.centerIn: parent
        width: iconRoot.iconSize - 12
        height: width
        source: (iconRoot.iconName && iconRoot.iconName.charAt(0) === "/") ? ("file://" + iconRoot.iconName) : ("image://icon/" + iconRoot.iconName)
        fillMode: Image.PreserveAspectFit
        smooth: true
        onStatusChanged: function(status) {
            if (status === Image.Error) {
                iconRoot.fallbackIndex++;
                if (iconRoot.fallbackIndex < iconRoot.allCandidates.length) {
                    var next = iconRoot.allCandidates[iconRoot.fallbackIndex];
                    iconImg.source = (next && next.charAt(0) === "/")
                        ? ("file://" + next)
                        : ("image://icon/" + next);
                } else {
                    fallbackText.visible = true;
                }
            }
        }
    }

    Text {
        id: fallbackText
        visible: false
        anchors.centerIn: parent
        text: {
            var e = root.desktopIndex.byId[iconRoot.desktopId];
            var name = e ? e.name : iconRoot.desktopId;
            return name ? name.charAt(0).toUpperCase() : "?";
        }
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: iconRoot.iconSize * 0.45
        font.bold: true
    }

    Rectangle {
        visible: iconRoot.isRunning
        width: 6; height: 6; radius: 3
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 2
        color: Color.accent
        border.color: Util.alpha(Color.background, 0.9)
        border.width: 1
    }

    MouseArea {
        id: iconMouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        drag.target: iconRoot.dragIndex >= 0 ? parent : undefined
        drag.axis: Drag.XAxis
        onClicked: function(ev) {
            if (ev.button === Qt.LeftButton) iconRoot.clicked();
            else if (ev.button === Qt.RightButton) iconRoot.rightClicked(mapToGlobal(ev.x, ev.y));
        }
        onPressAndHold: if (iconRoot.isPinned) Drag.active = true
    }

    DropArea {
        enabled: iconRoot.isPinned
        anchors.fill: parent
        onDropped: function(drop) {
            if (drop.source && drop.source.dragIndex !== undefined) {
                iconRoot.dragMove(drop.source.dragIndex, iconRoot.dragIndex);
            }
        }
    }

    Drag.active: iconMouse.drag.active
    Drag.hotSpot.x: width/2; Drag.hotSpot.y: height/2
    Drag.source: iconRoot
}
