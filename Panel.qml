import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Services
import qs.Windows
import qs.Components
import "archydock.js" as JS

PanelWindow {
    id: root
    property bool opened: true
    property string position: (settings.position || "bottom").toLowerCase()
    property bool isVertical: position === "left" || position === "right"
    property int iconSize: settings.iconSize ?? 48
    property int spacing: settings.spacing ?? 2

    readonly property var settings: ArchydockSettings
    readonly property var desktopIndex: DesktopEntries.index
    readonly property var pinnedIds: root.settings.pinned ?? []
    readonly property var runningApps: HyprlandState.toplevels?.values ?? []
    readonly property var unpinnedRunning: {
        var pinneds = {};
        for (var i = 0; i < pinnedIds.length; i++) pinneds[pinnedIds[i]] = true;
        var result = [];
        for (var j = 0; j < runningApps.length; j++) {
            var a = runningApps[j];
            if (!a || !a.desktopId) continue;
            if (!pinneds[a.desktopId]) result.push(a);
        }
        return result;
    }
    readonly property string launcherDesktop: settings.launcher ?? "org.gnome.Nautilus.desktop"
    readonly property string launcherIconName: {
        var entry = desktopIndex.byPath[launcherDesktop];
        return (entry && entry.icon) || "system-file-manager";
    }

    color: "transparent"
    implicitWidth: 10
    implicitHeight: 10
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    WlrLayershell.layer: WlrLayer.Background
    WlrLayershell.exclusionMode: ExclusionMode.Ignore
    mask: Region { item: null }

    function savePins() {
        root.settings.pinned = root.pinnedIds;
        settingsStub.settingsData = JSON.stringify(root.settings, null, 2);
        settingsStub.reload();
    }

    function launchDesktop(desktopId) {
        var entry = desktopIndex.byId[desktopId];
        if (entry && entry.path) {
            launchProc.command = [entry.path];
            launchProc.running = true;
            noteLaunch(desktopId, 0);
            return;
        }
        var base = desktopId.replace(/\.desktop$/, "");
        launchProc.command = ["gtk-launch", base];
        launchProc.running = true;
        noteLaunch(desktopId, 0);
    }

    function noteLaunch(desktopId, code) {
        if (code !== 0) return;
        var pinArr = root.pinnedIds;
        for (var k = 0; k < pinArr.length; k++) {
            if (pinArr[k] === desktopId) return;
        }
        var pinned = root.pinnedIds;
        pinned.push(desktopId);
        root.pinnedIds = pinned;
        savePins();
    }

    QsProcess { id: focusProc; }

    QsProcess {
        id: launchProc
        onRunningChanged: {
            if (!running && desktopId != null) noteLaunch(desktopId, exitCode);
            function noteLaunch(desktopId, code) {
                if (code !== 0) return;
                var pinned = root.pinnedIds;
                pinned.push(desktopId);
                root.pinnedIds = pinned;
                savePins();
            }
        }
    }

    SignalShortcut {
        name: "archydock-toggle"
        onPressed: root.opened = !root.opened
    }

    SettingsStub {
        id: settingsStub
        name: "archydock"
        path: "archydock.json"

        Component.onCompleted: {
            reload();
            settingsStub.readConfig();
            var data = settingsStub.readConfig();
            if (typeof data === "string" && data.length > 0) {
                try {
                    var parsed = JSON.parse(data);
                    for (var key in parsed) {
                        if (parsed.hasOwnProperty(key)) {
                            root.settings[key] = parsed[key];
                        }
                    }
                } catch (e) {}
            }
        }

        onFileChanged: {
            var data = settingsStub.readConfig();
            if (typeof data === "string" && data.length > 0) {
                try {
                    var parsed = JSON.parse(data);
                    for (var key in parsed) {
                        if (parsed.hasOwnProperty(key)) {
                            root.settings[key] = parsed[key];
                        }
                    }
                } catch (e) {}
            }
        }
    }

    // ----------------------------------------------------------- dock card
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
                visible: {
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

        Column {
            id: colLayout
            visible: root.isVertical
            anchors.centerIn: parent
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
                visible: {
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

    // ----------------------------------------------------------- context menu
    Item {
        id: contextMenu
        visible: false

        required property string desktopId
        property point openAt

        function openFor(desktopId, at) {
            contextMenu.desktopId = desktopId;
            contextMenu.openAt = at;
            contextMenu.visible = true;
        }

        PanelWindow {
            visible: contextMenu.visible
            color: "transparent"
            implicitWidth: 10
            implicitHeight: 10
            anchors { top: true; bottom: true; left: true; right: true }
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.exclusionMode: ExclusionMode.Ignore
            mask: Region { item: null }

            MouseArea {
                anchors.fill: parent
                onClicked: contextMenu.visible = false
            }

            BorderSurface {
                x: contextMenu.openAt.x
                y: contextMenu.openAt.y
                border.width: 0
                padding: root.padding
                color: Color.elevated

                Column {
                    spacing: 2

                    ContextMenuItem {
                        text: "Unpin from dock"
                        visible: root.pinnedIds.indexOf(contextMenu.desktopId) !== -1
                        onClicked: {
                            var next = DockModel.removePin(root.pinnedIds, contextMenu.desktopId);
                            root.pinnedIds = next; savePins();
                            contextMenu.visible = false;
                        }
                    }

                    ContextMenuItem {
                        text: "Quit running app"
                        visible: {
                            for (var i=0;i<root.runningApps.length;i++) if (root.runningApps[i].desktopId === contextMenu.desktopId) return true;
                            return false;
                        }
                        onClicked: {
                            for (var i=0;i<root.runningApps.length;i++) if (root.runningApps[i].desktopId === contextMenu.desktopId) {
                                focusProc.command = ["hyprctl","dispatch","closewindow","address:" + root.runningApps[i].address];
                                focusProc.running = true;
                            }
                            contextMenu.visible = false;
                        }
                    }
                }
            }
        }
    }

    // ----------------------------------------------------------- settings panel
    Item {
        id: settingsContext
        visible: false

        function openFor() { settingsContext.visible = true; }

        PanelWindow {
            visible: settingsContext.visible
            color: "transparent"
            implicitWidth: 10
            implicitHeight: 10
            anchors { top: true; bottom: true; left: true; right: true }
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.exclusionMode: ExclusionMode.Ignore
            mask: Region { item: null }

            MouseArea {
                anchors.fill: parent
                onClicked: settingsContext.visible = false
            }

            PopupCard {
                bar: dockCard
                border.width: 0
                color: Color.elevated
                padding: root.padding

                Column {
                    spacing: root.padding

                    PanelSectionHeader { text: "Position" }

                    ButtonGroup {
                        options: ["Bottom","Top","Left","Right"]
                        value: root.position.charAt(0).toUpperCase() + root.position.slice(1)
                        changed: function(val) {
                            root.position = val.toLowerCase();
                            root.settings.position = root.position;
                            settingsStub.settingsData = JSON.stringify(root.settings, null, 2);
                            settingsStub.reload();
                        }
                    }

                    PanelSeparator {}

                    PanelSectionHeader { text: "Icon size" }

                    PanelSlider {
                        value: root.iconSize
                        minimum: 32
                        maximum: 96
                        step: 4
                        moved: function(val) { root.iconSize = val; }
                        released: function(val) {
                            root.iconSize = val;
                            root.settings.iconSize = val;
                            settingsStub.settingsData = JSON.stringify(root.settings, null, 2);
                            settingsStub.reload();
                        }
                    }

                    PanelSeparator {}

                    PanelSectionHeader { text: "Icon spacing" }

                    PanelSlider {
                        value: root.spacing
                        minimum: 0
                        maximum: 12
                        step: 1
                        moved: function(val) { root.spacing = val; }
                        released: function(val) {
                            root.spacing = val;
                            root.settings.spacing = val;
                            settingsStub.settingsData = JSON.stringify(root.settings, null, 2);
                            settingsStub.reload();
                        }
                    }

                    PanelSeparator {}

                    PanelSectionHeader { text: "Launcher" }

                    Row {
                        spacing: 6
                        anchors.horizontalCenter: parent.horizontalCenter

                        Text {
                            text: root.launcherDesktop
                            color: Color.popups.text
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            width: 180
                            elide: Text.ElideRight
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                            text: "change"
                            color: Color.accent
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    launcherDialog.opened = true;
                                    settingsContext.visible = false;
                                }
                            }
                        }
                    }

                    PanelSeparator {}

                    ToggleSwitch {
                        text: "Enabled"
                        checked: root.opened
                        onToggled: {
                            root.opened = checked;
                            root.settings.enabled = checked;
                            settingsStub.settingsData = JSON.stringify(root.settings, null, 2);
                            settingsStub.reload();
                        }
                    }

                    PanelSeparator {}

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 10

                        Text {
                            text: "Save"
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            color: Color.accent
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: settingsContext.visible = false
                            }
                        }
                    }

                    Item { width: 1; height: 1 }
                }
            }
        }
    }

    // ----------------------------------------------------------- launcher picker
    Item {
        id: launcherDialog
        property bool opened: false

        PanelWindow {
            visible: launcherDialog.opened
            color: "transparent"
            implicitWidth: 10
            implicitHeight: 10
            anchors { top: true; bottom: true; left: true; right: true }
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.exclusionMode: ExclusionMode.Ignore
            mask: Region { item: null }

            MouseArea {
                anchors.fill: parent
                onClicked: launcherDialog.opened = false
            }

            PopupCard {
                bar: dockCard
                border.width: 0
                color: Color.elevated
                padding: root.padding

                Column {
                    spacing: 8
                    width: 300

                    PanelSectionHeader { text: "Choose launcher app" }

                    Repeater {
                        model: DesktopEntries.installed
                        delegate: Item {
                            width: parent.width
                            height: 28
                            visible: !modelData.noDisplay

                            Row {
                                anchors.fill: parent
                                spacing: 8

                                Image {
                                    source: "image://icon/" + (modelData.icon || "application-x-executable")
                                    width: 20; height: 20
                                    anchors.verticalCenter: parent.verticalCenter
                                    fillMode: Image.PreserveAspectFit
                                }

                                Text {
                                    text: modelData.name || modelData.fileName
                                    color: Color.popups.text
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    width: parent.width - 28
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: {
                                    root.launcherDesktop = modelData.fileName;
                                    root.settings.launcher = modelData.fileName;
                                    settingsStub.settingsData = JSON.stringify(root.settings, null, 2);
                                    settingsStub.reload();
                                    launcherDialog.opened = false;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
