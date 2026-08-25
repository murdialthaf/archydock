import QtQuick
import qs.Commons

Rectangle {
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
