import QtQuick
import qs.Commons

Item {
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
                launcherProc.running = true
            } else if (ev.button === Qt.RightButton) {
                launcherRoot.openSettings()
            }
        }
    }

    Process {
        id: launcherProc
        command: ["xdg-open", "file:///"]
    }
}
