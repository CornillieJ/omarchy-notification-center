import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

import "components"

// A notification center for Omarchy: everything you were sent, still there
// when you go back for it.
//
// Omarchy already writes every notification to disk: one JSON file per popup
// under ~/.local/state/omarchy/notifications/, moved into history/ when it
// leaves the screen. That is where these come from, and nothing here writes to
// those directories. What it is not is a history you can read: it holds ten
// files, deletes the eleventh, and deletes the icon it was keeping for it at
// the same time. Ten is the right number for a service whose job is replaying
// the toasts you just missed, and far too few for the question this panel
// exists to answer, which is "what did that say".
//
// So `bin/notification-center` copies each file out of there the moment it
// lands, into an archive kept for as long as you asked for, icon and all. It
// follows the directory with inotify rather than polling it, so a notification
// is in the archive before its toast has finished appearing.
//
// Glyphs are \u escapes rather than literal characters, so the source survives
// editors and patches that mangle private-use codepoints.
Panel {
  id: root

  moduleName: "jankeesvw.notification-center"
  ipcTarget: "jankeesvw.notification-center"

  readonly property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ----------------------------------------------------------------- settings

  readonly property int panelWidth: setting("panelWidth", 420)
  readonly property int listHeight: setting("listHeight", 0)
  readonly property string badge: setting("badge", "Dot")
  readonly property int keepDays: setting("keepDays", 30)
  readonly property int maxItems: setting("maxItems", 1000)
  readonly property string clickAction: setting("clickAction", "Auto")
  readonly property bool showBody: setting("showBody", true)
  readonly property bool showPreview: setting("showPreview", true)

  // ------------------------------------------------------------- the service
  //
  // Only for Do Not Disturb, which belongs to whoever is receiving the
  // notifications rather than to whoever is keeping them. A cloned service is
  // enabled under its own id, so the built-in name has to be resolved to
  // whichever copy is actually running, or the toggle silently does nothing on
  // exactly the machines that cared enough to clone it.
  readonly property var notificationService: {
    var host = bar && bar.shell ? bar.shell : null
    if (!host || typeof host.serviceFor !== "function") return null
    var id = "omarchy.notifications"
    if (host.pluginRegistry && typeof host.pluginRegistry.resolveEnabledId === "function")
      id = host.pluginRegistry.resolveEnabledId(id)
    return host.serviceFor(id)
  }

  readonly property bool dnd: notificationService ? notificationService.doNotDisturb : false

  function toggleDnd() {
    if (notificationService) notificationService.setDoNotDisturb(!notificationService.doNotDisturb)
  }

  // ------------------------------------------------------------- the store
  //
  // The archive is a shell service, not a child of this widget. Omarchy
  // builds a bar per monitor, and a Process in here would be one watcher
  // per screen: unread and clear would stick to whichever copy you clicked.
  property var store: null

  function bindStore() {
    if (store) {
      pushSettings()
      return
    }
    var host = bar && bar.shell ? bar.shell : null
    if (!host || typeof host.serviceFor !== "function") return
    var s = host.serviceFor("jankeesvw.notification-center")
    if (!s) return
    store = s
    pushSettings()
    rebuild()
  }

  function pushSettings() {
    if (!store) return
    store.keepDays = keepDays
    store.maxItems = maxItems
    store.showPreview = showPreview
  }

  onBarChanged: bindStore()
  onKeepDaysChanged: pushSettings()
  onMaxItemsChanged: pushSettings()
  onShowPreviewChanged: pushSettings()

  Timer {
    interval: 200
    running: root.store === null
    repeat: true
    onTriggered: root.bindStore()
  }

  Connections {
    target: root.store
    function onEntryAdded(entry) { root.handleEntryAdded(entry) }
    function onEntriesReset() { root.rebuild() }
  }

  // -------------------------------------------------------------------- state

  readonly property var entries: store ? store.entries : []
  readonly property var hiddenRules: store ? store.hiddenRules : []
  // "list" is the ordinary view; "hidden" is the rules a card's "Hide these"
  // link wrote, not a second copy of every notification they ever matched.
  property string tab: "list"
  property string filter: ""
  // 0 off, 1 groups identical app+summary, 2 also requires the body to match.
  // Not reset when the panel closes, unlike tab/filter: this is a display
  // mode you set once, not a transient like an open search field.
  property int groupMode: 2
  // What the rows are marked against. Opening the center makes everything in
  // it read, so marking against `lastSeen` would mean the list never once
  // shows you which of these you had not seen, because the marks would be gone by the
  // time it finished drawing. This holds the reading from the moment before
  // you opened it, which is the question you were asking.
  property double readMark: 0
  readonly property bool loaded: store ? store.loaded : false
  property bool searching: false
  property double now: Date.now()

  readonly property int unread: store ? store.unread : 0
  readonly property double lastSeen: store ? store.lastSeen : 0

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.now = Date.now()
  }

  function startSearch() {
    searching = true
    Qt.callLater(function() { if (root.searching) search.forceActiveFocus() })
  }

  function endSearch() {
    searching = false
    filter = ""
    search.text = ""
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  Process { id: focusProc }

  function clearAll() {
    if (store) store.clearAll()
  }

  function clearEverything() {
    if (store) store.clearEverything()
  }

  function hide(entry) {
    if (store && entry) store.hide(entry.app, entry.summary)
  }

  // Dismissing a grouped card takes every notification folded into it, not
  // just the newest one it displays.
  function removeRow(row) {
    if (!store || !row) return
    var keys = (row.groupKeys && row.groupKeys.length) ? row.groupKeys : [row.key]
    for (var i = 0; i < keys.length; i++) store.remove(keys[i])
  }

  function unhide(rule) {
    if (store && rule) store.unhide(rule.app, rule.summary)
  }

  function handleEntryAdded(entry) {
    if (!entry || !entry.key) return
    if (root.opened && store) store.markSeen()
    if (!matches(entry)) return
    // Grouped mode may fold this into an existing row rather than add a new
    // one, which the insert-at-front shortcut below can't express: rebuild.
    if (root.groupMode === 0) rows.insert(0, rowFor(entry, 1, null))
    else root.rebuild()
    if (root.opened && list.atYBeginning) Qt.callLater(function() {
      if (root.opened) list.positionViewAtBeginning()
    })
  }

  // ----------------------------------------------------------------- the list

  ListModel { id: rows }

  function matches(entry) {
    if (filter === "") return true
    var needle = filter.toLowerCase()
    return String(entry.app || "").toLowerCase().indexOf(needle) >= 0
        || String(entry.summary || "").toLowerCase().indexOf(needle) >= 0
        || String(entry.body || "").toLowerCase().indexOf(needle) >= 0
  }

  function rowFor(entry, count, groupKeys) {
    return {
      key: String(entry.key || ""),
      app: String(entry.app || ""),
      appIcon: String(entry.appIcon || ""),
      summary: String(entry.summary || ""),
      body: String(entry.body || ""),
      image: String(entry.image || ""),
      preview: String(entry.preview || ""),
      file: String(entry.file || ""),
      glyph: String(entry.glyph || ""),
      urgency: Number(entry.urgency || 0),
      timestamp: Number(entry.timestamp || 0),
      day: dayOf(Number(entry.timestamp || 0)),
      time: Qt.formatDateTime(new Date(Number(entry.timestamp || 0)), "HH:mm"),
      count: Number(count || 1),
      groupKeys: groupKeys || [String(entry.key || "")]
    }
  }

  // Same app and summary always; the body too once groupMode asks for it.
  // JSON.stringify rather than a joined string: a notification's text is
  // chosen by whoever sent it, so a plain separator could be forged to
  // collide two different notifications into one key.
  function groupKeyFor(entry) {
    var parts = [String(entry.app || ""), String(entry.summary || "")]
    if (root.groupMode >= 2) parts.push(String(entry.body || ""))
    return JSON.stringify(parts)
  }

  function rebuild() {
    rows.clear()
    if (root.groupMode === 0) {
      for (var i = 0; i < entries.length; i++)
        if (matches(entries[i])) rows.append(rowFor(entries[i], 1, null))
      return
    }
    // entries is newest-first, so the first occurrence of a key encountered
    // here is also the newest: a group sits where its most recent notification
    // would have, under the day it arrived on.
    var order = []
    var buckets = {}
    for (var j = 0; j < entries.length; j++) {
      var entry = entries[j]
      if (!matches(entry)) continue
      var k = groupKeyFor(entry)
      var bucket = buckets[k]
      if (bucket) {
        bucket.count++
        bucket.keys.push(String(entry.key || ""))
      } else {
        buckets[k] = { entry: entry, count: 1, keys: [String(entry.key || "")] }
        order.push(k)
      }
    }
    for (var m = 0; m < order.length; m++) {
      var b = buckets[order[m]]
      rows.append(rowFor(b.entry, b.count, b.keys))
    }
  }

  onFilterChanged: rebuild()
  onGroupModeChanged: rebuild()

  // The heading a notification is filed under. Days rather than hours, because
  // what you remember about a notification you are hunting for is which day it
  // was, and because a list broken into hours is a list that is mostly
  // headings.
  function dayOf(timestamp) {
    var when = new Date(timestamp)
    var now = new Date()
    var midnight = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
    if (timestamp >= midnight) return "Today"
    if (timestamp >= midnight - 86400000) return "Yesterday"
    // Within the week the weekday is the better handle: "Tuesday" is how you
    // remember it, "17 August" is how you would have to work it out.
    if (timestamp >= midnight - 6 * 86400000) return Qt.formatDateTime(when, "dddd")
    if (when.getFullYear() === now.getFullYear()) return Qt.formatDateTime(when, "d MMMM")
    return Qt.formatDateTime(when, "d MMMM yyyy")
  }

  // --------------------------------------------------------------- activating

  // What a click on an old notification should do.
  //
  // Not what the notification asked for. A notification arrives carrying a
  // shell command, chosen by whoever sent it, and anything on this machine can
  // send one. Keeping that command and running it later is an attacker's
  // command waiting for a click, which is worth nothing next to the one thing
  // people actually want back: the picture. So what the store keeps is at most
  // an absolute path to an image, and that is opened by argument rather than
  // through a shell, so a hostile path is a file that fails to open instead of
  // a command that runs.
  function activate(row) {
    if (!row || clickAction === "Nothing") return
    if (clickAction === "Auto" && row.file !== "") {
      Quickshell.execDetached(["xdg-open", row.file])
      root.close()
      return
    }
    // The app name is on the notification too, so it is the sender's to choose,
    // and the focus helper matches it as a regular expression: an app calling
    // itself ".*" would focus whichever window that hit first. Only something
    // shaped like a name gets through.
    if (!/^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$/.test(row.app)) return
    // Chat apps rarely register an action and simply expect a click to bring
    // their window up. This is the helper the notification service uses for
    // the same fallback, so a click here lands where a click on the toast
    // would have.
    focusProc.command = [root.omarchyPath + "/bin/omarchy-hyprland-focus-app", row.app]
    focusProc.running = true
    root.close()
  }

  // ---------------------------------------------------------------- lifecycle

  Component.onCompleted: bindStore()

  onOpenedChanged: {
    if (!opened) {
      searching = false
      filter = ""
      search.text = ""
      tab = "list"
      return
    }
    now = Date.now()
    if (store) store.load()
    readMark = lastSeen
    if (store) store.markSeen()
  }

  // --------------------------------------------------------------------- bar

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    bar: root.bar

    // A bell, and a bell with a line through it while notifications are
    // silenced. The second is the same glyph the shell's own DND indicator
    // uses, so the bar never shows two different pictures of one state.
    // U+F009B (bell-off) and U+F009A (bell), written as surrogate pairs so the
    // source survives editors that mangle private-use codepoints. The first is
    // the glyph the shell's own DND indicator uses, so the bar never shows two
    // different pictures of one state.
    text: root.dnd ? "\uDB80\uDC9B" : "\uDB80\uDC9A"
    dimmed: root.dnd

    // The Highlight marker: no shape added beside the bell, the bell itself
    // recoloured. BarIconButton already draws its glyph in activeColor while
    // active, which is the same mechanism the bar's own indicators use to say
    // a thing wants you, so this is that state rather than a second drawing of
    // it. Accent instead of the inherited urgent, because unread mail is not
    // an emergency.
    active: root.badge === "Highlight" && root.unread > 0
    activeColor: Color.accent
    tooltipText: {
      if (root.dnd) return root.unread > 0
        ? "Silenced · " + root.unread + " new" : "Notifications silenced"
      if (root.unread === 1) return "1 new notification"
      if (root.unread > 1) return root.unread + " new notifications"
      return "Notifications"
    }

    onPressed: function(b) {
      // Right-click silences without opening anything, because deciding you
      // want quiet and wanting to read the backlog are opposite impulses.
      if (b === Qt.RightButton) {
        root.toggleDnd()
        return
      }
      root.toggle()
    }
  }

  // Where the panel hangs from: a zero-width point far past the right edge of
  // any screen. Invisible, in the layout for nothing, and read only for its
  // position; see the anchor comment on the panel itself.
  Item {
    id: rightAnchor
    anchors.top: button.top
    anchors.bottom: button.bottom
    x: 1000000
    width: 1
    visible: false
  }

  // The Dot marker, drawn over the bell rather than beside it: a bar that
  // changes width every time a message arrives is a bar that twitches all day.
  Rectangle {
    id: dot
    visible: root.badge === "Dot" && root.unread > 0
    anchors.right: button.right
    anchors.rightMargin: Style.space(3)
    anchors.top: button.top
    anchors.topMargin: Style.space(5)
    width: Style.space(6)
    height: width
    radius: width / 2
    color: Color.accent
  }

  Rectangle {
    id: countBadge
    visible: root.badge === "Count" && root.unread > 0
    anchors.right: button.right
    anchors.rightMargin: Style.space(1)
    anchors.top: button.top
    anchors.topMargin: Style.space(3)
    width: Math.max(countText.implicitWidth + Style.space(6), Style.space(12))
    height: Style.space(12)
    radius: height / 2
    color: Color.accent

    Text {
      textFormat: Text.PlainText
      id: countText
      anchors.centerIn: parent
      // Past ninety-nine the number has stopped being information and the
      // badge is only saying "a lot", which it can say in three characters.
      text: root.unread > 99 ? "99+" : String(root.unread)
      font.family: root.fontFamily
      font.pixelSize: Math.max(8, Style.font.caption - Style.space(3))
      font.bold: true
      color: Color.background
    }
  }

  // ------------------------------------------------------------------- panel

  KeyboardPanel {
    id: popup
    // Anchored to a point past the right edge of the screen rather than to the
    // bell. KeyboardPanel clamps its card inside the screen, so an anchor out
    // there always resolves to hard against the right edge, whatever the bar
    // has been rearranged into since. This is the one panel in the bar with a
    // fixed home: a notification center that opened in a different place
    // depending on how many widgets were to its left would be a notification
    // center you have to look for.
    anchorItem: rightAnchor
    bar: root.bar
    owner: root
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(root.panelWidth))
    // fittedContentHeight() clamps against availableCardHeight, which collapses
    // to its 120px minimum under a screen-sized bar window (see
    // usableCardHeight below), so the same fit is done here against the
    // corrected ceiling: the content plus the card insets, never taller than
    // the space the screen actually has.
    contentHeight: Math.round(Math.min(
      Math.max(popup.verticalContentInset, content.implicitHeight + popup.verticalContentInset),
      popup.usableCardHeight))

    // The stock omarchy bar window is only as tall as the bar strip, so the
    // screen minus that window is the space a panel has. Shibumi draws its
    // strip inside a screen-sized window instead, which makes KeyboardPanel
    // mistake the whole screen for the bar and collapse to its 120px safety
    // minimum - a card a few entries tall no matter how much room there is.
    // Measure the strip itself when the window is screen-sized; both bars
    // expose barSize, so this works under either host.
    readonly property real usableCardHeight: {
      if (barH >= screenH && root.bar && Number(root.bar.barSize) > 0)
        return Math.max(120, screenH - (Number(root.bar.barSize) + gap + margin))
      return availableCardHeight
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the search field has the focus it owns every key, including the
      // ones this would otherwise read as navigation.
      blocked: root.searching
      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) { list.flick(0, dy > 0 ? -900 : 900) }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        // "/" is the only key that starts a search, because a panel that
        // started filtering on any keypress would be a panel that swallows
        // whatever you were typing in the window underneath.
        if (text === "/") root.startSearch()
      }

      Column {
        id: content
        anchors.fill: parent
        spacing: Style.space(8)

        // -------------------------------------------------------- header

        Column {
          id: header
          width: parent.width
          // The action row has grown past what fits beside the title on one
          // line (Clear list and Clear current pushed it over): stacked
          // underneath, with room between, is the one layout that can't
          // overlap the title no matter how many buttons end up in it.
          spacing: Style.space(6)

          PanelSectionHeader {
            id: title
            text: root.tab === "hidden" ? "HIDDEN" : "NOTIFICATIONS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Row {
            id: actions
            anchors.right: parent.right
            spacing: Style.space(2)

            // A word rather than an icon, and a word that names the state: the
            // three modes read the same as the tooltip they cycle through, so
            // there is nothing to remember about what stage you are on.
            Button {
              anchors.verticalCenter: parent.verticalCenter
              text: root.groupMode === 0 ? "Group" : root.groupMode === 1 ? "Grouped" : "Grouped+"
              tooltipText: root.groupMode === 0
                ? "Group repeated notifications"
                : root.groupMode === 1
                  ? "Grouping identical app + summary · click to also match the body"
                  : "Grouping identical app + summary + body · click to turn off"
              foreground: root.groupMode > 0 ? Color.accent : root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              visible: root.tab === "list"
              onClicked: root.groupMode = (root.groupMode + 1) % 3
            }

            // Search is a button rather than a field standing open. An open
            // field takes the keyboard the moment the panel appears, and this
            // panel can be opened from a key binding while you are typing
            // somewhere else, which is exactly how it ends up eating a
            // sentence out of the window underneath.
            PanelActionButton {
              // Anchored rather than left to the Row, which stacks its
              // children from the top: an icon button and a text button are
              // not the same height, and the difference shows as a word
              // sitting above a row of glyphs.
              anchors.verticalCenter: parent.verticalCenter
              // U+F0349, nf-md-magnify.
              iconText: "\uDB80\uDF49"
              tooltipText: "Search these notifications  ( / )"
              foreground: root.searching ? Color.accent : root.foreground
              fontFamily: root.fontFamily
              visible: root.tab === "list" && root.entries.length > 0
              onClicked: root.searching ? root.endSearch() : root.startSearch()
            }

            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.dnd ? "\uDB80\uDC9B" : "\uDB80\uDC9A"
              tooltipText: root.dnd ? "Allow notifications" : "Silence notifications"
              foreground: root.dnd ? Color.accent : root.foreground
              fontFamily: root.fontFamily
              visible: root.tab === "list"
              enabled: root.notificationService !== null
              onClicked: root.toggleDnd()
            }

            // A word rather than a glyph. The other control in this row
            // silences and this one empties the panel, and a picture of a
            // broom is not the place to find out which is which.
            Button {
              anchors.verticalCenter: parent.verticalCenter
              text: "Clear list"
              tooltipText: "Empty the panel"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              visible: root.tab === "list"
              enabled: root.entries.length > 0
              onClicked: root.clearAll()
            }

            // Clear list empties this panel; Clear current takes Omarchy's
            // own notification history down with it, the one behind the
            // stock bell, and dismisses whatever toasts are on screen right
            // now too. Everything it drops is already sitting safe in this
            // panel's archive, so nothing is lost — only seen twice.
            Button {
              anchors.verticalCenter: parent.verticalCenter
              text: "Clear current"
              tooltipText: "Also empty Omarchy's own notification history and dismiss on-screen toasts"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              visible: root.tab === "list"
              enabled: root.entries.length > 0
              onClicked: root.clearEverything()
            }

            // The one control that shows in both tabs: it is how you get
            // between them. A word rather than a glyph, same reasoning as
            // Clear above it \u2014 this is not a common enough action to earn an
            // icon nobody would recognize on sight.
            Button {
              anchors.verticalCenter: parent.verticalCenter
              text: root.tab === "hidden" ? "Notifications" : "Hidden (" + root.hiddenRules.length + ")"
              tooltipText: root.tab === "hidden"
                ? "Back to notifications"
                : "Notifications you've hidden"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              enabled: root.tab === "hidden" || root.hiddenRules.length > 0
              onClicked: root.tab = (root.tab === "hidden" ? "list" : "hidden")
            }
          }
        }

        // -------------------------------------------------------- search

        TextField {
          id: search
          width: parent.width
          visible: root.tab === "list" && root.searching
          placeholderText: "Search"
          foreground: root.foreground
          onTextChanged: root.filter = text
          Keys.onEscapePressed: root.endSearch()
          Keys.onDownPressed: list.flick(0, -900)
          Keys.onUpPressed: list.flick(0, 900)
        }

        // ---------------------------------------------------------- list

        ListView {
          id: list
          width: parent.width
          // Grows with what it holds and stops at the bottom of the screen,
          // which is where macOS puts the end of its notification column. The
          // ceiling is what is left of the screen once the header, the search
          // field and the footer have had their share, so the panel fills the
          // display without ever being taller than it.
          //
          // Search is counted in whether it is showing or not: opening it must
          // not push the footer out through the bottom of the card.
          readonly property int cap: {
            if (root.listHeight > 0) return Style.space(root.listHeight)
            var chrome = header.height + search.implicitHeight + foot.implicitHeight
                       + content.spacing * 3
            return Math.max(Style.space(240),
                            popup.usableCardHeight - popup.verticalContentInset - chrome)
          }

          height: Math.min(contentHeight, cap)
          visible: root.tab === "list" && rows.count > 0
          clip: true
          model: rows
          spacing: Style.space(6)
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { id: listScroll; policy: ScrollBar.AsNeeded }

          // The scrollbar gets a lane of its own on the right. Sharing one
          // with the cards puts it on top of the dismiss button in the corner
          // of every one of them, and the button you are aiming at is the one
          // you miss.
          readonly property real lane: Style.space(10)

          section.property: "day"
          section.criteria: ViewSection.FullString
          section.delegate: Item {
            id: daySection
            required property string section
            width: list.width - list.lane
            height: dayLabel.implicitHeight + Style.space(14)

            PanelSectionHeader {
              id: dayLabel
              anchors.left: parent.left
              anchors.leftMargin: Style.space(2)
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(4)
              text: daySection.section.toUpperCase()
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
          }

          delegate: NotificationRow {
            id: row
            required property var model

            width: list.width - list.lane
            app: model.app
            appIcon: model.appIcon
            summary: model.summary
            body: model.body
            image: model.image
            preview: model.preview
            glyph: model.glyph
            timestamp: model.timestamp
            now: root.now
            urgency: model.urgency
            unread: model.timestamp > root.readMark
            count: model.count
            showBody: root.showBody
            showPreview: root.showPreview
            foreground: root.foreground
            fontFamily: root.fontFamily

            onClicked: root.activate(row.model)
            onRemoveRequested: root.removeRow(row.model)
            onHideRequested: root.hide(row.model)
          }
        }

        // --------------------------------------------------------- empty

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.tab === "list" && rows.count === 0
          horizontalAlignment: Text.AlignHCenter
          topPadding: Style.space(22)
          bottomPadding: Style.space(22)
          text: !root.loaded ? "Reading the archive\u2026"
              : root.filter !== "" ? "Nothing matches \u201c" + root.filter + "\u201d"
              : "Nothing has come in yet"
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
          opacity: 0.55
        }

        // ---------------------------------------------------------- foot

        Text {
          textFormat: Text.PlainText
          id: foot
          width: parent.width
          visible: root.tab === "list" && root.entries.length > 0 && root.filter === ""
          horizontalAlignment: Text.AlignHCenter
          topPadding: Style.space(2)
          text: root.entries.length === 1
            ? "1 notification kept"
            : root.entries.length + " notifications kept \u00b7 " + root.keepDays + " days"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
          opacity: 0.4
        }

        // -------------------------------------------------------- hidden
        //
        // What is hidden here is the rule ("Chromium" + "Calendar"), not a
        // second copy of every notification it has matched \u2014 this is meant
        // to answer "what did I tell it to stop showing me", not to be a
        // second archive.

        ListView {
          id: hiddenList
          width: parent.width
          readonly property int cap: {
            var chrome = header.height + hiddenFoot.implicitHeight + content.spacing * 2
            return Math.max(Style.space(160),
                            popup.usableCardHeight - popup.verticalContentInset - chrome)
          }
          height: Math.min(contentHeight, cap)
          visible: root.tab === "hidden" && root.hiddenRules.length > 0
          clip: true
          model: root.hiddenRules
          spacing: Style.space(6)
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          readonly property real lane: Style.space(10)

          delegate: Item {
            id: hiddenRow
            required property var modelData
            width: hiddenList.width - hiddenList.lane
            height: hiddenApp.implicitHeight + hiddenSummary.implicitHeight + Style.space(16)

            Rectangle {
              anchors.fill: parent
              radius: Style.space(10)
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
            }

            Text {
              id: hiddenApp
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: unhideLabel.left
              anchors.top: parent.top
              anchors.margins: Style.space(10)
              text: String(hiddenRow.modelData.app || "")
              elide: Text.ElideRight
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: root.foreground
              opacity: 0.5
            }

            Text {
              id: hiddenSummary
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              anchors.top: hiddenApp.bottom
              text: String(hiddenRow.modelData.summary || "")
              elide: Text.ElideRight
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              color: root.foreground
            }

            Text {
              id: unhideLabel
              textFormat: Text.PlainText
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(10)
              text: "Unhide"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              color: Color.accent
              opacity: unhideMouse.containsMouse ? 1.0 : 0.8

              MouseArea {
                id: unhideMouse
                anchors.fill: parent
                anchors.margins: -Style.space(4)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.unhide(hiddenRow.modelData)
              }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.tab === "hidden" && root.hiddenRules.length === 0
          horizontalAlignment: Text.AlignHCenter
          topPadding: Style.space(22)
          bottomPadding: Style.space(22)
          text: "Nothing hidden. \u201cHide these\u201d on a card adds it here."
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
          opacity: 0.55
        }

        Text {
          textFormat: Text.PlainText
          id: hiddenFoot
          width: parent.width
          visible: root.tab === "hidden" && root.hiddenRules.length > 0
          horizontalAlignment: Text.AlignHCenter
          topPadding: Style.space(2)
          text: root.hiddenRules.length === 1
            ? "1 rule hidden"
            : root.hiddenRules.length + " rules hidden"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
          opacity: 0.4
        }
      }
    }
  }
}
