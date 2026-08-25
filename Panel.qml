import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

Item {
    id: root

    property bool opened: true
    property string position: "bottom"
    property bool isVertical: position === "left" || position === "right"
    property int iconSize: 48
    property int spacing: 2
    property int padding: 8

    readonly property var toplevels: ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    readonly property var apps: DesktopEntries.applications ? DesktopEntries.applications.values : []
    readonly property var pinnedIds: loadPins()

    // Running apps mapped to desktopId
    property var runningMap: ({})

    function appIdForToplevel(tl) {
        var appId = tl.appId || ""
        return appId
    }

    function updateRunning() {
        var map = {}
        for (var i = 0; i < toplevels.length; i++) {
            var tl = toplevels[i]
            var id = appIdForToplevel(tl)
            if (id) {
                if (!map[id]) map[id] = { count: 0, toplevel: tl }
                map[id].count++
            }
        }
        runningMap = map
    }

    onToplevelsChanged: updateRunning()

    function findAppEntry(appId) {
        for (var i = 0; i < apps.length; i++) {
            var e = apps[i]
            if (e.id === appId) return e
        }
        return null
    }

    function iconForEntry(entry) {
        if (!entry) return "application-x-executable"
        return entry.icon || "application-x-executable"
    }

    function iconSource(iconName) {
        var v = iconName || "application-x-executable"
        return "image://icon/" + v
    }

    function loadPins() {
        try {
            var req = new XMLHttpRequest()
            req.open("GET", "file://" + root.configPath(), false)
            req.send()
            if (req.status === 200 && req.responseText) {
                var data = JSON.parse(req.responseText)
                return data.pinned || []
            }
        } catch (e) {}
        return []
    }

    property var savedData: ({})

    function configPath() {
        return (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/archydock.json"
    }

    function saveConfig() {
        savedData.pinned = pinnedIds
        savedData.position = position
        savedData.iconSize = iconSize
        savedData.spacing = spacing
        savedData.opened = opened
        var req = new XMLHttpRequest()
        req.open("PUT", "file://" + configPath(), false)
        req.send(JSON.stringify(savedData, null, 2))
    }

    FileView {
        path: root.configPath()
        onLoaded: {
            try {
                var data = JSON.parse(content)
                if (data.pinned) root.savedData = data
            } catch (e) {}
        }
        onFileChanged: reload()
    }

    Process {
        id: launchProc
        property string pendingDesktopId: ""
        onRunningChanged: {
            if (!running && exitCode === 0 && pendingDesktopId) {
                root.addPin(pendingDesktopId)
                pendingDesktopId = ""
            }
        }
    }

    Process { id: focusProc }

    function launchApp(desktopId) {
        launchProc.pendingDesktopId = desktopId
        launchProc.command = ["gtk-launch", desktopId]
        launchProc.running = true
    }

    function addPin(desktopId) {
        if (pinnedIds.indexOf(desktopId) !== -1) return
        var next = pinnedIds.slice()
        next.push(desktopId)
        savedData.pinned = next
        saveConfig()
    }

    function removePin(desktopId) {
        var next = []
        for (var i = 0; i < pinnedIds.length; i++) {
            if (pinnedIds[i] !== desktopId) next.push(pinnedIds[i])
        }
        savedData.pinned = next
        saveConfig()
    }

    function movePin(from, to) {
        var next = pinnedIds.slice()
        var item = next.splice(from, 1)[0]
        next.splice(to, 0, item)
        savedData.pinned = next
        saveConfig()
    }

    property var unpinnedRunning: []

    function updateUnpinned() {
        var pinned = {}
        for (var i = 0; i < pinnedIds.length; i++) pinned[pinnedIds[i]] = true
        var result = []
        var seen = {}
        var keys = Object.keys(runningMap)
        for (var j = 0; j < keys.length; j++) {
            var k = keys[j]
            if (!pinned[k] && !seen[k]) {
                seen[k] = true
                var entry = findAppEntry(k)
                result.push({ desktopId: k, name: entry ? entry.name : k, icon: iconForEntry(entry), count: runningMap[k].count })
            }
        }
        unpinnedRunning = result
    }

    onRunningMapChanged: updateUnpinned()
    onPinnedIdsChanged: updateUnpinned()

    function togglePin(desktopId) {
        if (pinnedIds.indexOf(desktopId) !== -1) removePin(desktopId)
        else addPin(desktopId)
    }

    function closeApp(desktopId) {
        var info = runningMap[desktopId]
        if (info && info.toplevel) info.toplevel.close()
    }

    function focusApp(desktopId) {
        var info = runningMap[desktopId]
        if (info && info.toplevel) info.toplevel.activate()
    }

    function hasSeparator() {
        if (unpinnedRunning.length === 0) return false
        for (var i = 0; i < pinnedIds.length; i++) {
            if (runningMap[pinnedIds[i]]) return true
        }
        return false
    }

    // ----------------------------------------------------------- dock
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
                return rowLayout.implicitWidth + root.padding * 2 + borderLeft + borderRight;
            }
            height: {
                if (root.isVertical) return colLayout.implicitHeight + root.padding * 2 + borderTop + borderBottom;
                return root.iconSize + root.padding * 2 + borderTop + borderBottom;
            }
            border.width: 0
            padding: root.padding
            color: Color.elevated

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
            }

            Row {
                id: rowLayout
                visible: !root.isVertical
                anchors.centerIn: parent
                spacing: root.spacing

                Repeater {
                    model: root.pinnedIds
                    delegate: DockIcon {
                        required property string modelData
                        required property int index
                        desktopId: modelData
                        entry: root.findAppEntry(modelData)
                        isRunning: !!root.runningMap[modelData]
                        isPinned: true
                        iconSize: root.iconSize
                        onClicked: {
                            if (root.runningMap[modelData]) root.focusApp(modelData)
                            else root.launchApp(modelData)
                        }
                        onRightClicked: ctxMenu.openFor(modelData, "pin", mapToGlobal(0, 0))
                        dragIndex: index
                        onDragMove: function(from, to) { root.movePin(from, to) }
                    }
                }

                Rectangle {
                    visible: root.hasSeparator()
                    width: 1; height: root.iconSize * 0.6
                    anchors.verticalCenter: parent.verticalCenter
                    color: Util.alpha(Color.popups.text, 0.16)
                    radius: 1
                }

                Repeater {
                    model: root.unpinnedRunning
                    delegate: DockIcon {
                        required property var modelData
                        desktopId: modelData.desktopId
                        entry: root.findAppEntry(modelData.desktopId)
                        isRunning: true
                        isPinned: false
                        iconSize: root.iconSize
                        onClicked: root.focusApp(modelData.desktopId)
                        onRightClicked: ctxMenu.openFor(modelData.desktopId, "unpinned", mapToGlobal(0, 0))
                    }
                }

                DockLauncher {
                    iconSize: root.iconSize
                    onOpenSettings: settingsPanel.open()
                }

                Item {
                    visible: root.pinnedIds.length === 0 && root.unpinnedRunning.length === 0
                    width: phText.implicitWidth + 20; height: root.iconSize
                    Text {
                        id: phText
                        anchors.centerIn: parent
                        text: "Pin an app to begin"
                        color: Util.alpha(Color.popups.text, 0.55)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                    }
                }
            }

            Column {
                id: colLayout
                visible: root.isVertical
                anchors.centerIn: parent
                spacing: root.spacing

                Repeater {
                    model: root.pinnedIds
                    delegate: DockIcon {
                        required property string modelData
                        required property int index
                        desktopId: modelData
                        entry: root.findAppEntry(modelData)
                        isRunning: !!root.runningMap[modelData]
                        isPinned: true
                        iconSize: root.iconSize
                        onClicked: {
                            if (root.runningMap[modelData]) root.focusApp(modelData)
                            else root.launchApp(modelData)
                        }
                        onRightClicked: ctxMenu.openFor(modelData, "pin", mapToGlobal(0, 0))
                        dragIndex: index
                        onDragMove: function(from, to) { root.movePin(from, to) }
                    }
                }

                Rectangle {
                    visible: root.hasSeparator()
                    width: root.iconSize * 0.6; height: 1
                    anchors.horizontalCenter: parent.horizontalCenter
                    color: Util.alpha(Color.popups.text, 0.16)
                    radius: 1
                }

                Repeater {
                    model: root.unpinnedRunning
                    delegate: DockIcon {
                        required property var modelData
                        desktopId: modelData.desktopId
                        entry: root.findAppEntry(modelData.desktopId)
                        isRunning: true
                        isPinned: false
                        iconSize: root.iconSize
                        onClicked: root.focusApp(modelData.desktopId)
                        onRightClicked: ctxMenu.openFor(modelData.desktopId, "unpinned", mapToGlobal(0, 0))
                    }
                }

                DockLauncher {
                    iconSize: root.iconSize
                    onOpenSettings: settingsPanel.open()
                }
            }
        }
    }

    // ----------------------------------------------------------- context menu
    Item {
        id: ctxMenu
        visible: false
        property string targetId: ""
        property string menuType: ""
        property point openAt

        function openFor(id, type, pos) {
            targetId = id; menuType = type; openAt = pos; visible = true
        }

        PanelWindow {
            visible: ctxMenu.visible
            color: "transparent"
            implicitWidth: 10; implicitHeight: 10
            anchors { top: true; bottom: true; left: true; right: true }
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.exclusionMode: ExclusionMode.Ignore
            mask: Region { item: null }

            MouseArea { anchors.fill: parent; onClicked: ctxMenu.visible = false }

            BorderSurface {
                x: ctxMenu.openAt.x; y: ctxMenu.openAt.y
                border.width: 0; padding: root.padding; color: Color.elevated

                Column {
                    spacing: 2
                    CtxMenuItem {
                        text: "Unpin"
                        visible: root.pinnedIds.indexOf(ctxMenu.targetId) !== -1
                        onClicked: { root.removePin(ctxMenu.targetId); ctxMenu.visible = false }
                    }
                    CtxMenuItem {
                        text: "Pin"
                        visible: root.pinnedIds.indexOf(ctxMenu.targetId) === -1
                        onClicked: { root.addPin(ctxMenu.targetId); ctxMenu.visible = false }
                    }
                    CtxMenuItem {
                        text: "Close"
                        visible: !!root.runningMap[ctxMenu.targetId]
                        onClicked: { root.closeApp(ctxMenu.targetId); ctxMenu.visible = false }
                    }
                }
            }
        }
    }

    // ----------------------------------------------------------- settings
    Item {
        id: settingsPanel
        visible: false
        function open() { visible = true }

        PanelWindow {
            visible: settingsPanel.visible
            color: "transparent"
            implicitWidth: 10; implicitHeight: 10
            anchors { top: true; bottom: true; left: true; right: true }
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.exclusionMode: ExclusionMode.Ignore
            mask: Region { item: null }

            MouseArea { anchors.fill: parent; onClicked: settingsPanel.visible = false }

            BorderSurface {
                anchors.centerIn: parent
                width: settingsCol.implicitWidth + root.padding * 4
                height: settingsCol.implicitHeight + root.padding * 4
                border.width: 0; padding: root.padding; color: Color.elevated

                Column {
                    id: settingsCol
                    anchors.centerIn: parent
                    width: 300
                    spacing: root.padding

                    PanelSectionHeader { text: "Position" }
                    ButtonGroup {
                        options: ["Bottom", "Top", "Left", "Right"]
                        value: root.position.charAt(0).toUpperCase() + root.position.slice(1)
                        changed: function(val) {
                            root.position = val.toLowerCase()
                            root.saveConfig()
                        }
                    }

                    PanelSeparator {}

                    PanelSectionHeader { text: "Icon Size" }
                    PanelSlider {
                        value: root.iconSize
                        minimum: 32; maximum: 96; step: 4
                        moved: function(val) { root.iconSize = val }
                        released: function(val) { root.iconSize = val; root.saveConfig() }
                    }

                    PanelSeparator {}

                    PanelSectionHeader { text: "Spacing" }
                    PanelSlider {
                        value: root.spacing
                        minimum: 0; maximum: 12; step: 1
                        moved: function(val) { root.spacing = val }
                        released: function(val) { root.spacing = val; root.saveConfig() }
                    }

                    PanelSeparator {}

                    ToggleSwitch {
                        label: "Enabled"
                        checked: root.opened
                        onToggled: {
                            root.opened = !root.opened
                            root.saveConfig()
                        }
                    }

                    PanelSeparator {}

                    Item { width: 1; height: 1 }
                }
            }
        }
    }
}

// ---------------------------------------------------------------- DockIcon
component DockIcon : Item {
    id: iconRoot
    property string desktopId: ""
    property var entry: null
    property bool isRunning: false
    property bool isPinned: false
    property int iconSize: 44
    property int dragIndex: -1
    signal clicked()
    signal rightClicked(var globalPos)
    signal dragMove(int from, int to)

    property string iconName: {
        if (entry && entry.icon) return entry.icon
        return "application-x-executable"
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
        source: {
            var name = iconRoot.iconName
            if (name && name.indexOf("/") === 0) return "file://" + name
            return "image://icon/" + (name || "application-x-executable")
        }
        fillMode: Image.PreserveAspectFit
        smooth: true
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
        onClicked: function(ev) {
            if (ev.button === Qt.LeftButton) iconRoot.clicked()
            else if (ev.button === Qt.RightButton) iconRoot.rightClicked(mapToGlobal(ev.x, ev.y))
        }
    }
}

// ---------------------------------------------------------------- DockLauncher
component DockLauncher : Item {
    id: launcherRoot
    property int iconSize: 44
    signal openSettings()

    width: iconSize; height: iconSize

    Rectangle {
        anchors.fill: parent
        radius: 10
        color: launchMouse.containsMouse ? Util.alpha(Color.accent, 0.18) : "transparent"
    }

    Image {
        anchors.centerIn: parent
        width: launcherRoot.iconSize - 12; height: width
        source: "image://icon/system-file-manager"
        fillMode: Image.PreserveAspectFit
        smooth: true
    }

    MouseArea {
        id: launchMouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: function(ev) {
            if (ev.button === Qt.LeftButton) {
                var proc = launchProcComponent.createObject(launcherRoot)
                proc.command = ["xdg-open", "file:///"]
                proc.running = true
            } else if (ev.button === Qt.RightButton) {
                launcherRoot.openSettings()
            }
        }
    }

    Component {
        id: launchProcComponent
        Process {}
    }
}

// ---------------------------------------------------------------- CtxMenuItem
component CtxMenuItem : Rectangle {
    id: ctxItemRoot
    property string text: ""
    signal clicked()

    width: 160; height: 28; radius: 6
    color: ctxItemMouse.containsMouse ? Util.alpha(Color.accent, 0.18) : "transparent"

    Text {
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left; anchors.leftMargin: 8
        text: ctxItemRoot.text
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
    }

    MouseArea {
        id: ctxItemMouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: ctxItemRoot.clicked()
    }
}
