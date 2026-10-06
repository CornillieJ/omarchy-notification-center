import QtQuick
import Quickshell
import Quickshell.Io

// The archive, mounted once for the shell.
//
// Omarchy builds a bar per monitor. If the watcher and the in-memory list
// lived on the widget, each screen would have its own lastSeen and its own
// entries, and marking read or clearing on one would leave the other as it
// was. The on-disk store is already shared; this is the QML owner of the
// processes that talk to it.
Item {
  id: root
  width: 0
  height: 0
  visible: false

  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property var barWidgetRegistry: null
  property string omarchyPath: ""

  property int keepDays: 30
  property int maxItems: 1000
  property bool showPreview: true
  property int pageSize: 500

  property var entries: []
  property double lastSeen: 0
  property bool loaded: false
  property var hiddenRules: []

  readonly property bool watching: watchProc.running

  readonly property int unread: {
    var count = 0
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].timestamp > lastSeen) count++
      else break
    }
    return count
  }

  readonly property string script:
    Qt.resolvedUrl("bin/notification-center").toString().replace(/^file:\/\//, "")

  readonly property var storeEnvironment: ({
    "NC_KEEP_DAYS": String(root.keepDays),
    "NC_MAX_ITEMS": String(root.maxItems),
    "NC_PREVIEWS": root.showPreview ? "1" : "0"
  })

  signal entryAdded(var entry)
  signal entriesReset()

  function storeCommand(args) {
    return [root.script].concat(args)
  }

  function differsFrom(data) {
    if (data.length !== entries.length) return true
    if (data.length === 0) return false
    return String(data[0].key) !== String(entries[0].key)
  }

  function load() {
    if (listProc.running) return
    listProc.command = root.storeCommand(["list", String(root.pageSize)])
    listProc.running = true
  }

  function readSeen() {
    if (seenProc.running) return
    seenProc.command = root.storeCommand(["seen"])
    seenProc.running = true
  }

  function markSeen() {
    var stamp = Date.now()
    root.lastSeen = stamp
    if (markProc.running) return
    markProc.command = root.storeCommand(["seen", String(stamp)])
    markProc.running = true
  }

  function remove(key) {
    if (!key) return
    var next = []
    for (var i = 0; i < entries.length; i++)
      if (entries[i].key !== key) next.push(entries[i])
    entries = next
    entriesReset()
    Quickshell.execDetached(root.storeCommand(["remove", String(key)]))
  }

  // Detached, like remove and seed above it: a clear that arrives while the
  // previous one is still running used to return early and never happen, so
  // the list came back on the next sync and the button looked broken.
  function clearAll() {
    entries = []
    entriesReset()
    Quickshell.execDetached(root.storeCommand(["clear"]))
  }

  // The other clear: this archive, plus Omarchy's own notification history.
  function clearEverything() {
    entries = []
    entriesReset()
    Quickshell.execDetached(root.storeCommand(["clear-all"]))
  }

  function loadHidden() {
    if (hiddenProc.running) return
    hiddenProc.command = root.storeCommand(["hidden"])
    hiddenProc.running = true
  }

  // Exact on (app, summary): see the "why" on cmd_hide in the store script.
  // Updates entries here as well as hiddenRules, since a rule made from a
  // card already in the list takes that card out of the list too.
  function hide(app, summary) {
    if (!app && !summary) return
    var nextEntries = []
    for (var i = 0; i < entries.length; i++)
      if (entries[i].app !== app || entries[i].summary !== summary) nextEntries.push(entries[i])
    entries = nextEntries
    entriesReset()
    hiddenRules = hiddenRules.concat([{ app: app, summary: summary, createdAt: Date.now() }])
    Quickshell.execDetached(root.storeCommand(["hide", String(app), String(summary)]))
    reloadAfterHide.restart()
  }

  function unhide(app, summary) {
    var next = []
    for (var i = 0; i < hiddenRules.length; i++)
      if (hiddenRules[i].app !== app || hiddenRules[i].summary !== summary) next.push(hiddenRules[i])
    hiddenRules = next
    Quickshell.execDetached(root.storeCommand(["unhide", String(app), String(summary)]))
  }

  function absorb(line) {
    var entry
    try {
      entry = JSON.parse(line)
    } catch (e) {
      return
    }
    if (!entry || !entry.key) return
    // close_write and moved_to both fire for one popup; the second is dropped
    // by key. One watcher for the shell, so this is no longer a per-screen race.
    for (var i = 0; i < entries.length; i++)
      if (entries[i].key === entry.key) return

    var next = [entry].concat(entries)
    if (next.length > pageSize) next = next.slice(0, pageSize)
    entries = next
    entryAdded(entry)
  }

  Process {
    id: watchProc
    command: root.storeCommand(["watch"])
    environment: root.storeEnvironment
    running: true
    stdout: SplitParser {
      onRead: function(line) { root.absorb(line) }
    }
    onExited: restartWatch.restart()
  }

  Timer {
    id: restartWatch
    interval: 30000
    onTriggered: if (!watchProc.running) watchProc.running = true
  }

  Timer {
    interval: 10000
    running: true
    repeat: true
    // hiddenRules needs the same periodic catch-up as entries: hide/unhide
    // normally reload both right away (see reloadAfterHide), but a rule
    // written from outside this instance — the CLI directly, or another
    // screen's copy of this service — only shows up here on the next poll.
    onTriggered: { root.load(); root.loadHidden() }
  }

  Process {
    id: listProc
    environment: root.storeEnvironment
    stdout: StdioCollector {
      onStreamFinished: {
        var data
        try {
          data = JSON.parse(text)
        } catch (e) {
          return
        }
        if (!Array.isArray(data)) return
        var wasLoaded = root.loaded
        root.loaded = true
        if (wasLoaded && !root.differsFrom(data)) return
        root.entries = data
        root.entriesReset()
      }
    }
  }

  Process {
    id: seenProc
    environment: root.storeEnvironment
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          if (data.ok === true) root.lastSeen = Number(data.seen) || 0
        } catch (e) {
        }
      }
    }
  }

  Process { id: markProc; environment: root.storeEnvironment }

  Process {
    id: hiddenProc
    environment: root.storeEnvironment
    stdout: StdioCollector {
      onStreamFinished: {
        var data
        try {
          data = JSON.parse(text)
        } catch (e) {
          return
        }
        if (Array.isArray(data)) root.hiddenRules = data
      }
    }
  }

  // The store's own hide/unhide run detached (see hide() above), so the rule
  // file and the reachived archive need a moment before load()/loadHidden()
  // read anything back that matches what just happened.
  Timer {
    id: reloadAfterHide
    interval: 400
    onTriggered: { root.load(); root.loadHidden() }
  }

  Component.onCompleted: {
    readSeen()
    load()
    loadHidden()
  }

  IpcHandler {
    target: "jankeesvw.notification-center.test"

    function seed(count: int): string {
      Quickshell.execDetached(root.storeCommand(["seed", String(count > 0 ? count : 25)]))
      reloadAfterSeed.restart()
      return "seeding " + count
    }

    function clear(): string {
      root.clearAll()
      return "cleared"
    }

    function reload(): string {
      root.load()
      return "reloading"
    }

    function state(): string {
      return JSON.stringify({
        entries: root.entries.length,
        newest: root.entries.length > 0 ? root.entries[0].summary : "",
        unread: root.unread,
        watching: watchProc.running,
        loaded: root.loaded,
        lastSeen: root.lastSeen
      })
    }
  }

  Timer {
    id: reloadAfterSeed
    interval: 600
    onTriggered: root.load()
  }
}
