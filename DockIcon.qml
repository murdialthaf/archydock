import QtQuick
import qs.Commons

Item {
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
