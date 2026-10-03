import QtQuick
import Quickshell
import Quickshell.Io
import Qt.labs.folderlistmodel
import qs.Commons

// Taskchy: a todo suite for Omarchy, themed by the current system theme.
// Three tabs along the top:
//
//   Todo      top-level todos (grouped and coloured) and each one's sub-todos
//   Task Log  what's being worked on, shifting across to do / doing / done,
//             and each todo's log (agents write to it with `taskchy`)
//   Progress  how far along every group and todo is; archive and restore
//
// Everything is plain markdown in ~/Documents/Taskchy (taskchy.py), so any
// notes app can open it too. Fully keyboard driven: press ? for the keys.
Item {
  id: tasks

  // set by the overlay: Esc with nothing to back out of calls it
  property var closeRequest: null
  // true while the overlay is open (polling only runs then)
  property bool active: true
  readonly property string script: Qt.resolvedUrl("taskchy.py").toString().replace("file://", "")

  // ---- look: everything follows the Omarchy theme --------------------------------
  readonly property color fg: Color.menu.text
  // the card's colour: the theme's panel colour (or black, a setting) at the
  // opacity the settings pick
  readonly property color base: tintMode === "black" ? Qt.rgba(0, 0, 0, 1)
    : Qt.rgba(Color.menu.background.r, Color.menu.background.g, Color.menu.background.b, 1)
  readonly property color bg: Qt.rgba(base.r, base.g, base.b, cardOpacity)
  // pop-ups over the page: the same colour, but solid
  readonly property color solid: base
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property string font: Style.font.family
  readonly property real fs: Style.fontScale
  readonly property int rad: Math.max(6, Style.cornerRadius)
  function px(n) { return Math.round(n * fs) }
  // a path with your home folder shown as ~
  readonly property string home: Quickshell.env("HOME") || ""
  function shortPath(p) { return home && (p === home || p.indexOf(home + "/") === 0) ? "~" + p.slice(home.length) : p }
  // where a row's group-colour bar sits (inside its rounded end)
  readonly property real barX: Math.min(10, Math.round(rad * 0.45))
  function tint(c, o) { return Util.alpha(c, o) }
  readonly property color dim: tint(fg, 0.6)
  readonly property color faint: tint(fg, 0.4)
  readonly property color surface: tint(fg, 0.03)
  readonly property color line: tint(fg, 0.12)
  readonly property color rowFill: tint(fg, 0.045)
  readonly property color hoverFill: tint(fg, 0.085)
  readonly property color selFill: tint(fg, 0.10)
  readonly property color cursorFill: tint(accent, 0.15)
  readonly property color armedFill: tint(urgent, 0.32)
  // a row's fill: the keyboard cursor > selected > hovered > idle
  function rowColor(cur, sel, hover, idle) {
    return cur ? cursorFill : sel ? selFill : hover ? hoverFill : (idle === undefined ? rowFill : idle)
  }

  // ---- remembered view state (folds, log view, picture folder) --------------------
  property var ui: ({})
  property bool uiLoaded: false
  onUiChanged: if (uiLoaded) uiSave.restart()
  Timer { id: uiSave; interval: 400; onTriggered: uiFile.setText(JSON.stringify(tasks.ui, null, 1) + "\n") }
  FileView {
    id: uiFile
    path: Quickshell.env("HOME") + "/.local/state/taskchy/ui.json"
    printErrors: false
    atomicWrites: true
    onLoaded: { try { tasks.ui = JSON.parse(text()) || ({}) } catch (e) { tasks.ui = ({}) } tasks.uiLoaded = true }
    onLoadFailed: tasks.uiLoaded = true
  }
  Process { running: true; command: ["mkdir", "-p", Quickshell.env("HOME") + "/.local/state/taskchy"] }

  property string folder: ""
  property var groupColors: ({})
  property var groupOrder: []                 // hand-set group order (taskchy group-order)
  property var supersMap: ({})                // super groups (groups of groups): {name: {color}}
  property var superOrderList: []
  property var todos: []
  property var archivedTodos: []
  property var logEntries: []
  property string error: ""

  // ---- ui state -----------------------------------------------------------------
  property string tab: "todo"                 // todo | log | progress
  property string selectedId: ""
  property string pane: "list"                // todo tab: list | subs
  property int subIndex: 0
  property bool showDone: true
  property bool showHelp: false
  property bool showSettings: false
  property int settingsIndex: 0

  // ---- settings (the gear, or ,) -------------------------------------------------
  // opacity-mode  "hyprland": the opacity Hyprland gives windows (decoration:active_opacity)
  //               "theme":    the theme's own panel transparency
  //               "full":     fully solid
  // tint-mode     "theme": the theme's panel colour · "black": black
  readonly property string opacityMode: ui && (ui["opacity-mode"] === "full" || ui["opacity-mode"] === "theme") ? ui["opacity-mode"] : "hyprland"
  readonly property string tintMode: ui && ui["tint-mode"] === "black" ? "black" : "theme"
  property real hyprOpacity: 1
  readonly property real cardOpacity: opacityMode === "full" ? 1 : opacityMode === "theme" ? Color.menu.background.a : hyprOpacity
  readonly property var settingsItems: [
    { key: "opacity-mode", value: "hyprland", section: "Background opacity", label: "Hyprland window opacity", detail: "same as your windows · " + Math.round(hyprOpacity * 100) + "%" },
    { key: "opacity-mode", value: "theme", label: "Theme transparency", detail: "the theme's own panel see-through · " + Math.round(Color.menu.background.a * 100) + "%" },
    { key: "opacity-mode", value: "full", label: "Full opacity", detail: "solid, nothing shows through · 100%" },
    { key: "tint-mode", value: "theme", section: "Background tint", label: "Theme", detail: "the theme's panel colour" },
    { key: "tint-mode", value: "black", label: "Black", detail: "a black background, whatever the theme" }
  ]
  function settingValue(key) { return key === "opacity-mode" ? opacityMode : tintMode }
  function applySetting(it) {
    if (!it) return
    var m = Object.assign({}, ui)
    m[it.key] = it.value
    ui = m
  }
  function openSettings() {
    showHelp = false
    settingsIndex = 0
    for (var i = 0; i < settingsItems.length; i++)
      if (settingsItems[i].key === "opacity-mode" && settingsItems[i].value === opacityMode) settingsIndex = i
    showSettings = true
    forceActiveFocus()
  }
  Process {
    id: hyprOpacityReader
    running: true
    command: ["hyprctl", "getoption", "decoration:active_opacity", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var v = Number(JSON.parse(text).float)
          if (isFinite(v) && v > 0) tasks.hyprOpacity = Math.min(1, v)
        } catch (e) {}
      }
    }
  }
  // re-read it every time Taskchy opens (Hyprland's setting may have changed)
  onActiveChanged: {
    if (active) { hyprOpacityReader.running = true; return }
    // closing Taskchy keeps what's being typed rather than dropping it
    if (subEdit.activeFocus) subEdit.commit()
    if (viewEditing) saveEdit()
  }
  property string armedDelete: ""             // press delete twice
  property var expanded: ({})                 // progress tab: "g:<group>" / "t:<id>"
  property int progressIndex: 0
  property string archiveQuery: ""
  property bool showNotes: false
  property string logPane: "list"             // log tab: list | lanes
  property string progressPane: "list"        // progress tab: list | archive
  property int logEntry: 0                    // which log entry, in the entries pane
  // ---- one log entry, opened over the whole panel (Enter) ----
  property var viewEntry: null                // the entry being read
  property bool viewEditing: false
  property string copiedNote: ""
  function openEntry(e, edit) {
    viewEntry = e
    viewEditing = false
    if (edit) startEdit()
  }
  // ---- pictures on sub-todos ----
  // the pictures of the sub-todo open in the viewer (live, so adds show up)
  readonly property var viewPics: viewEntry && viewEntry.isSub && selected && selected.subs[viewEntry.n]
    ? selected.subs[viewEntry.n].images || [] : []
  property int picIndex: -1                   // the picked picture in the viewer
  property string zoomPic: ""                 // a picture shown over everything
  property int armedPic: -1                   // d once: waiting for the second d
  onViewPicsChanged: if (picIndex >= viewPics.length) picIndex = viewPics.length - 1
  // pictures fold open under their sub-todo in the list (remembered; open by default)
  function picsKey(t, sb) { return "tasks-pics-shut:" + (t ? t.id : "") + ":" + (sb ? sb.text : "") }
  function picsOpen(t, sb) { return !(tasks.ui[picsKey(t, sb)]) }
  function togglePics(t, sb) {
    if (!sb || !(sb.images || []).length) return
    var m = Object.assign({}, tasks.ui), key = picsKey(t, sb)
    if (m[key]) delete m[key]; else m[key] = true
    tasks.ui = m
  }
  function addPicture(t, n, file) {
    if (t && file) act(["sub-image-add", t.id, String(n), String(file)])
  }
  function removePicture(n, k) {
    if (selected) act(["sub-image-remove", selected.id, String(n), String(k)])
    armedPic = -1
  }
  Timer { id: disarmPic; interval: 2500; onTriggered: tasks.armedPic = -1 }
  // the file picker (a drip panel): which sub-todo it adds to
  property var pickFor: null                  // { id, n }
  function openPicker(t, n) {
    if (!t || !t.subs[n]) return
    pickFor = { id: t.id, n: n }
    picker.open()
  }

  // a sub-todo, opened over the whole panel the same way (Enter on it)
  function openSub(t, i, edit) {
    if (!t || !t.subs[i]) return
    var st = t.subs[i].state
    openEntry({ isSub: true, n: i, text: t.subs[i].text, by: "", sub: "", time: "",
                where: "sub-todo " + (i + 1) + "  ·  " + (st === "done" ? "done" : st === "doing" ? "in progress" : "to do") }, edit)
  }
  function copyEntry(e) {
    if (!e) return
    Quickshell.execDetached(["wl-copy", "--", e.text])
    copiedNote = "copied to the clipboard"
    copiedTimer.restart()
  }
  function startEdit() {
    if (!viewEntry) return
    viewEditing = true
    viewEditor.text = viewEntry.text
    viewEditor.forceActiveFocus()
    viewEditor.cursorPosition = viewEditor.text.length
  }
  function saveEdit() {
    if (!viewEntry || (!selected && viewEntry.id === undefined)) return
    var text = viewEditor.text.trim()
    if (text === "" || text === viewEntry.text) { viewEditing = false; forceActiveFocus(); return }
    var before = viewEntry.text, n = viewEntry.n
    if (viewEntry.isSub) act(["sub-edit", selected.id, String(n), text, "--expect", before])
    else act(["log-edit", viewEntry.id !== undefined ? viewEntry.id : selected.id, String(n), text, "--expect", before])
    viewEntry = Object.assign({}, viewEntry, { text: text })
    viewEditing = false
    forceActiveFocus()
  }
  function closeEntry() { viewEntry = null; viewEditing = false; picIndex = -1; zoomPic = ""; armedPic = -1; forceActiveFocus() }
  // L: straight to the selected todo's log (first entry), from either tab
  property bool jumpToLog: false
  function firstEntryRow() {
    for (var i = 0; i < logDisplay.length; i++)
      if (logDisplay[i].kind === "entry" && (!logWide || logDisplay[i].e.id === selectedId)) return i
    for (var j = 0; j < logDisplay.length; j++) if (logDisplay[j].kind === "entry") return j
    return 0
  }
  // L in the Task Log: straight to the highlighted super group's, group's,
  // todo's or sub-todo's section of the log (switching the log's view to one
  // that has that section, and unfolding the way there)
  property var logJumpTo: null                // {what, name} of the heading to land on
  // L on the Todo tab: over to the Task Log with the same thing highlighted
  // there (super group, group, todo or sub-todo), then on to its section
  function jumpLogFromTodo(what, name) {
    tab = "log"
    if (what === "super" || what === "group") { logPane = "list"; logCursor = (what === "super" ? "s:" : "g:") + name }
    else if (what === "sub") { logPane = "lanes"; logCursor = ""; logSub = name }
    else { logPane = "list"; logCursor = "" }
    jumpLogHere()
  }
  function jumpLogHere() {
    var what = "", name = "", mode = logMode, vals = []
    if (logPane === "list" && logCursor.indexOf("s:") === 0) {
      what = "super"; name = logCursor.slice(2); mode = "super"; vals = [name]
    } else if (logPane === "list" && logCursor.indexOf("g:") === 0) {
      what = "group"; name = logCursor.slice(2)
      mode = logMode === "super" ? "super" : "group"
      vals = mode === "super" ? [superOf(name), name] : [name]
    } else if (logPane === "lanes" && selected && selected.subs[logSub]) {
      what = "sub"; name = logSub; mode = "sub"
    } else if (selected && logWide) {
      what = "todo"; name = selected.id
      var g = selected.group
      vals = logMode === "super" ? [superOf(g), g, name] : logMode === "group" ? [g, name] : [name]
    } else { jumpLog(); return }
    // the view, and every fold on the way down, in one go
    var m = Object.assign({}, tasks.ui)
    delete m["tasks-log-by-sub"]
    m["tasks-log-mode"] = mode
    if (what === "sub") delete m[sectionKey(selected.subs[logSub].text)]
    else {
      var levels = mode === "super" ? ["super", "group", "todo"] : mode === "group" ? ["group", "todo"] : ["todo"]
      var path = ""
      vals.forEach(function(v, i) {
        delete m["tasks-log-sec:" + mode + ":" + path + "/" + levels[i] + ":" + v]
        path += "/" + v
      })
    }
    tasks.ui = m
    logJumpTo = { what: what, name: name }
    tryLogJump()
  }
  function tryLogJump() {
    if (!logJumpTo) return
    for (var i = 0; i < logDisplay.length; i++) {
      var r = logDisplay[i]
      if (r.kind === "head" && r.what === logJumpTo.what && (r.what === "sub" ? r.i === logJumpTo.name : r.name === logJumpTo.name)) {
        logJumpTo = null
        logPane = "entries"
        logEntry = i
        // the section's heading at the top of the log, its entries below it
        Qt.callLater(function() { logList.positionViewAtIndex(i, ListView.Beginning) })
        return
      }
    }
    // not there (yet): wait for the log to load; if it has, there's nothing logged about it
    if (!(logWide ? logAllReader.running : logReader.running) && (logWide ? allLogEntries.length : true)) {
      if (logJumpTo.what === "sub") { logPane = "entries"; logEntry = 0 }
      logJumpTo = null
    }
  }
  function jumpLog() {
    if (!selected) return
    tab = "log"
    logCursor = ""
    logPane = "entries"
    logEntry = firstEntryRow()
    jumpToLog = true
    refresh()
  }
  onLogDisplayChanged: {
    if (jumpToLog && logDisplay.length) { logEntry = firstEntryRow(); jumpToLog = false }
    tryLogJump()
  }
  Timer { id: copiedTimer; interval: 1600; onTriggered: tasks.copiedNote = "" }
  property string progressFollow: ""          // re-find this row after a move ("g:…" / "t:…")
  // how the log is shown (s / S cycle it; remembered):
  //   time  - this todo's log, newest first      sub   - this todo's, by sub-todo
  //   todo  - every todo's log, by todo           group - by group › todo
  //   super - by super group › group › todo
  readonly property var logModes: ["time", "sub", "todo", "group", "super"]
  readonly property var logModeNames: ({ time: "newest first", sub: "by sub-todo", todo: "all · by todo", group: "all · by group", super: "all · by super group" })
  readonly property var logModeIcons: ({ time: "\uf017", sub: "\uf0ca", todo: "\uf0ae", group: "\uf07b", super: "\uf247" })
  readonly property string logMode: {
    var m = tasks.ui ? tasks.ui["tasks-log-mode"] : ""
    if (logModes.indexOf(m) >= 0) return m
    return tasks.ui["tasks-log-by-sub"] ? "sub" : "time"
  }
  readonly property bool logBySub: logMode === "sub"
  readonly property bool logWide: logMode === "todo" || logMode === "group" || logMode === "super"
  property var allLogEntries: []              // every todo's log (the "all · …" views)
  function toggleLogSort(back) {
    var m = Object.assign({}, tasks.ui)
    delete m["tasks-log-by-sub"]
    m["tasks-log-mode"] = logModes[(logModes.indexOf(logMode) + (back ? logModes.length - 1 : 1)) % logModes.length]
    tasks.ui = m
    logEntry = 0
  }
  onLogModeChanged: refresh()
  // the log's entries in the current view (the "all" views: newest first)
  readonly property var logShown: logWide
    ? allLogEntries.slice().sort(function(a, b) { return a.time < b.time ? 1 : a.time > b.time ? -1 : b.n - a.n })
    : logEntries
  // an entry's full tag: super group › group › todo  ↳ sub-todo
  function entryGroup(e) { return e.id !== undefined ? e.group : (selected ? selected.group : "") }
  function entryTag(e) {
    var grp = entryGroup(e)
    var title = e.id !== undefined ? e.title : (selected ? selected.title : "")
    var sup = grp ? superOf(grp) : ""
    return (sup ? sup + "  \u203a  " : "") + (grp ? grp + "  \u203a  " : "") + title + (e.sub ? "   \u21b3  " + e.sub : "")
  }
  // what the log shows: entries, and a heading per section (levels nest)
  readonly property var logDisplay: {
    var rows = []
    if (logWide) {
      // sections: super group › group › todo, as deep as the view goes;
      // sections come newest activity first, like the entries in them
      var levels = logMode === "super" ? ["super", "group", "todo"] : logMode === "group" ? ["group", "todo"] : ["todo"]
      var keyOf = function(e, what) { return what === "super" ? superOf(e.group) : what === "group" ? e.group : e.id }
      var build = function(list, depth, path) {
        if (depth === levels.length) {
          list.forEach(function(e) { rows.push({ kind: "entry", e: e, level: depth }) })
          return
        }
        var what = levels[depth], order = [], by = {}
        list.forEach(function(e) {
          var k = keyOf(e, what)
          if (!by[k]) { by[k] = []; order.push(k) }
          by[k].push(e)
        })
        // "not in a super group" / "no group" go last (sort isn't stable: keep first-seen order by hand)
        if (order.indexOf("") >= 0) { order.splice(order.indexOf(""), 1); order.push("") }
        order.forEach(function(k) {
          var mine = by[k], key = "tasks-log-sec:" + logMode + ":" + path + "/" + what + ":" + k
          var shut = sectionFolded(key)
          rows.push({ kind: "head", what: what, name: k, level: depth, key: key, count: mine.length, collapsed: shut,
                      label: what === "todo" ? mine[0].title : k !== "" ? k : what === "super" ? "Not in a super group" : "No group",
                      group: what === "todo" ? mine[0].group : what === "group" ? k : "" })
          if (!shut) build(mine, depth + 1, path + "/" + k)
        })
      }
      build(logShown, 0, "")
      return rows
    }
    if (!logBySub || !selected) return logEntries.map(function(e) { return { kind: "entry", e: e, level: 0 } })
    var used = {}
    selected.subs.forEach(function(sb, i) {
      var mine = logEntries.filter(function(e) { return e.sub === sb.text })
      if (!mine.length) return
      var key = sectionKey(sb.text), shut = sectionFolded(key)
      rows.push({ kind: "head", what: "sub", i: i, sub: sb, key: key, level: 0, label: sb.text, count: mine.length, collapsed: shut })
      mine.forEach(function(e) { used[logEntries.indexOf(e)] = true; if (!shut) rows.push({ kind: "entry", e: e, section: i, level: 1 }) })
    })
    var rest = logEntries.filter(function(e, n) { return !used[n] })
    if (rest.length) {
      var restKey = sectionKey(""), restShut = sectionFolded(restKey)
      rows.push({ kind: "head", what: "sub", i: -1, sub: null, key: restKey, level: 0, label: "About the whole todo", count: rest.length, collapsed: restShut })
      if (!restShut) rest.forEach(function(e) { rows.push({ kind: "entry", e: e, section: -1, level: 1 }) })
    }
    return rows
  }
  // the keyboard's stops in the log: every entry, and (by sub-todo) every
  // section heading too
  readonly property var logEntryRows: {
    var out = []
    for (var i = 0; i < logDisplay.length; i++) out.push(i)
    return out
  }
  readonly property var logPicked: logEntryRows.length ? logDisplay[logEntryRows[Math.min(logEntry, logEntryRows.length - 1)]] : null
  function sectionOf(row) { return !row ? undefined : row.kind === "head" ? row.i : row.section }
  // by sub-todo: move a section (i.e. its sub-todo) past the next section
  function moveSection(dir) {
    var sec = sectionOf(logPicked)
    if (sec === undefined || sec < 0 || !selected) return
    var secs = []
    logDisplay.forEach(function(r) { if (r.kind === "head" && r.i >= 0) secs.push(r.i) })
    var at = secs.indexOf(sec), nb = secs[at + dir]
    if (nb === undefined) return
    act(["sub-move", selected.id, String(sec), String(nb)])
  }
  // ---- folding log sections (per todo and sub-todo, remembered) ----
  function sectionKey(subText) { return "tasks-log-sec:" + selectedId + ":" + subText }
  function sectionFolded(key) { return !!(tasks.ui[key]) }
  function setSectionFolded(key, shut) {
    if (!key) return
    var m = Object.assign({}, tasks.ui)
    if (shut) m[key] = true
    else delete m[key]
    tasks.ui = m
  }
  // the heading a row sits under (-1: none)
  function parentHead(at) {
    var lv = logDisplay[at] ? logDisplay[at].level : 0
    for (var i = at - 1; i >= 0; i--)
      if (logDisplay[i].kind === "head" && logDisplay[i].level < lv) return i
    return -1
  }
  // fold the section the picked row is in, and rest on its heading; false if none
  function foldSectionOf(at) {
    var h = parentHead(at)
    if (h < 0) return false
    setSectionFolded(logDisplay[h].key, true)
    logEntry = h
    return true
  }
  onProgressRowsChanged: {
    if (progressFollow === "") return
    var nav = progressRows.filter(function(r) { return r.kind !== "sub" })
    for (var i = 0; i < nav.length; i++) {
      var key = nav[i].kind === "group" ? "g:" + nav[i].name : nav[i].kind === "super" ? "s:" + nav[i].name : "t:" + nav[i].t.id
      if (key === progressFollow) { progressIndex = i; progressFollow = ""; return }
    }
  }
  property int archiveIndex: 0               // a row of archiveRows (heading or todo)
  property int logSub: 0                      // which sub-todo, in the lanes

  implicitHeight: 620
  focus: true
  Component.onCompleted: forceActiveFocus()

  readonly property var selected: {
    for (var i = 0; i < todos.length; i++) if (todos[i].id === selectedId) return todos[i]
    return null
  }
  function colorOf(group) {
    return group && groupColors[group] ? groupColors[group].color : "transparent"
  }
  function pct(t) {
    if (t.done) return 1
    var n = t.subs.length
    return n === 0 ? 0 : t.counts.done / n
  }

  // ---- super groups: groups that hold other groups ----
  function superOf(g) {
    var sup = g && groupColors[g] ? groupColors[g].super : ""
    return sup && supersMap[sup] ? sup : ""
  }
  function superColor(n) { return supersMap[n] ? supersMap[n].color : tasks.fg }
  function superRank(n) { var i = superOrderList.indexOf(n); return i < 0 ? 100000 : i }
  // the (sorted) group names arranged under their supers: each super (in
  // super order) followed by its groups, then the groups not in one
  function arrangeGroups(names) {
    var bySup = {}, sups = [], plain = []
    names.forEach(function(n) {
      var sp = n ? superOf(n) : ""
      if (sp) { if (!bySup[sp]) { bySup[sp] = []; sups.push(sp) } bySup[sp].push(n) }
      else plain.push(n)
    })
    sups.sort(function(a, b) { return superRank(a) - superRank(b) || a.localeCompare(b) })
    var out = []
    sups.forEach(function(sp) {
      out.push({ kind: "super", name: sp, members: bySup[sp] })
      bySup[sp].forEach(function(n) { out.push({ kind: "g", name: n, depth: 1 }) })
    })
    plain.forEach(function(n) { out.push({ kind: "g", name: n, depth: 0 }) })
    return out
  }
  function superCollapsed(n, scope) { return groupCollapsed("super:" + n, scope) }
  function setSuperCollapsed(n, shut, scope) { setGroupCollapsed("super:" + n, shut, scope) }
  function moveSuper(n, dir) {
    var all = Object.keys(supersMap)
    all.sort(function(a, b) { return superRank(a) - superRank(b) || a.localeCompare(b) })
    var i = all.indexOf(n), j = i + dir
    if (i < 0 || j < 0 || j >= all.length) return false
    all.splice(i, 1); all.splice(j, 0, n)
    act(["super-order"].concat(all))
    return true
  }
  // the keys on a super heading (same as a group's); true if handled
  function superKeys(n, scope, k, txt, up, down, shift, move) {
    if ((up || down) && shift) { moveSuper(n, up ? -1 : 1); return true }
    if (up || down) { move(up ? -1 : 1); return true }
    if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space || txt === "z") { setSuperCollapsed(n, !superCollapsed(n, scope), scope); return true }
    if (k === Qt.Key_Right || txt === "l") { setSuperCollapsed(n, false, scope); return true }
    if (k === Qt.Key_Left || txt === "h") { setSuperCollapsed(n, true, scope); return true }
    if (txt === "e" || k === Qt.Key_F2) { startRenameSuper(n); return true }
    if (txt === "A") { archiveSuper(n); return true }
    if (txt === "d" || k === Qt.Key_Delete) { deleteSuperKey(n); return true }
    if (txt === "g") { openSuperMenu(n, tasks.width * 0.2, 120); return true }
    return false
  }
  property string armedSuper: ""
  Timer { id: disarmSuper; interval: 2500; onTriggered: tasks.armedSuper = "" }
  function deleteSuperKey(n) {
    if (armedSuper !== n) { armedSuper = n; disarmSuper.restart(); return }
    armedSuper = ""
    act(["super-delete", n])
  }
  property bool renamingIsSuper: false
  function startRenameSuper(n) {
    renamingIsSuper = true
    renamingGroup = n
    renameGroupInput.text = n
    renameGroupInput.selectAll()
    renameGroupInput.forceActiveFocus()
  }
  // Todo tab: rows grouped by group (alphabetical), ungrouped last.
  readonly property var todoRows: {
    var byGroup = {}, names = [], loose = []
    for (var i = 0; i < todos.length; i++) {
      var t = todos[i]
      if (t.done && !showDone) continue
      if (t.group) {
        if (!byGroup[t.group]) { byGroup[t.group] = []; names.push(t.group) }
        byGroup[t.group].push(t)
      } else loose.push(t)
    }
    sortGroups(names)
    var rows = [], shutSuper = false
    arrangeGroups(names).forEach(function(it) {
      if (it.kind === "super") {
        shutSuper = superCollapsed(it.name, "")
        var c = 0
        it.members.forEach(function(m) { c += byGroup[m].length })
        rows.push({ kind: "super", name: it.name, count: c, collapsed: shutSuper })
        return
      }
      if (it.depth && shutSuper) return
      var n = it.name, shut = groupCollapsed(n)
      rows.push({ kind: "group", name: n, count: byGroup[n].length, collapsed: shut, depth: it.depth })
      if (!shut) byGroup[n].forEach(function(t) { rows.push({ kind: "todo", t: t, depth: it.depth }) })
    })
    // loose todos get a heading (and can fold away) only beside real groups
    var looseShut = names.length > 0 && groupCollapsed("")
    if (loose.length && names.length) rows.push({ kind: "group", name: "", count: loose.length, collapsed: looseShut })
    if (!looseShut) loose.forEach(function(t) { rows.push({ kind: "todo", t: t }) })
    return rows
  }
  readonly property var todoOrder: todoRows.filter(function(r) { return r.kind === "todo" }).map(function(r) { return r.t.id })

  // ---- folding groups (remembered with the command centre's other sections) --
  // each tab remembers its own folds: scope "" (Todo), "progress", "log"
  function foldKey(name, scope) { return (scope ? "tasks-" + scope + "-group:" : "tasks-group:") + name }
  function groupCollapsed(name, scope) { return !!(tasks.ui[foldKey(name, scope)]) }
  function setGroupCollapsed(name, shut, scope) {
    var m = Object.assign({}, tasks.ui)
    if (shut) m[foldKey(name, scope)] = true
    else delete m[foldKey(name, scope)]
    tasks.ui = m
  }
  // the keyboard cursor in the todo list: a todo's id, or "g:<group>" when
  // it's resting on a group heading ("" = on the selected todo)
  property string cursor: ""
  readonly property string cursorKey: cursor !== "" ? cursor : selectedId
  readonly property var todoNav: todoRows.map(function(r) { return r.kind === "group" ? "g:" + r.name : r.kind === "super" ? "s:" + r.name : r.t.id })
  function moveCursor(d) {
    if (todoNav.length === 0) return
    var i = todoNav.indexOf(cursorKey)
    var key = todoNav[Math.max(0, Math.min(todoNav.length - 1, i < 0 ? 0 : i + d))]
    if (key.indexOf("g:") === 0 || key.indexOf("s:") === 0) cursor = key
    else { cursor = ""; selectedId = key }
  }
  function toggleGroup(name) {
    var shut = !groupCollapsed(name)
    setGroupCollapsed(name, shut)
    if (shut && selected && (selected.group || "") === name) cursor = "g:" + name
  }

  // Task Log tab: grouped and ordered like the Todo tab (loose ones last)
  readonly property var logRows: {
    var byGroup = {}, names = [], loose = []
    todos.forEach(function(t) {
      if (t.group) {
        if (!byGroup[t.group]) { byGroup[t.group] = []; names.push(t.group) }
        byGroup[t.group].push(t)
      } else loose.push(t)
    })
    sortGroups(names)
    var rows = [], shutSuper = false
    arrangeGroups(names).forEach(function(it) {
      if (it.kind === "super") {
        shutSuper = superCollapsed(it.name, "log")
        var c = 0
        it.members.forEach(function(m) { c += byGroup[m].length })
        rows.push({ kind: "super", name: it.name, count: c, collapsed: shutSuper })
        return
      }
      if (it.depth && shutSuper) return
      var n = it.name
      var shut = groupCollapsed(n, "log")
      rows.push({ kind: "group", name: n, count: byGroup[n].length, collapsed: shut, depth: it.depth })
      if (!shut) byGroup[n].forEach(function(t) { rows.push({ kind: "todo", t: t, depth: it.depth }) })
    })
    var looseShut = names.length > 0 && groupCollapsed("", "log")
    if (loose.length && names.length) rows.push({ kind: "group", name: "", count: loose.length, collapsed: looseShut })
    if (!looseShut) loose.forEach(function(t) { rows.push({ kind: "todo", t: t }) })
    return rows
  }
  property string logCursor: ""                // "g:<group>" on a heading, "" on the selected todo
  readonly property var logNav: logRows.map(function(r) { return r.kind === "group" ? "g:" + r.name : r.kind === "super" ? "s:" + r.name : r.t.id })
  function moveLogCursor(d) {
    if (logNav.length === 0) return
    var i = logNav.indexOf(logCursor !== "" ? logCursor : selectedId)
    var key = logNav[Math.max(0, Math.min(logNav.length - 1, i < 0 ? 0 : i + d))]
    if (key.indexOf("g:") === 0 || key.indexOf("s:") === 0) logCursor = key
    else { logCursor = ""; selectedId = key }
  }
  function toggleLogGroup(name) {
    var shut = !groupCollapsed(name, "log")
    setGroupCollapsed(name, shut, "log")
    if (shut && selected && (selected.group || "") === name) logCursor = "g:" + name
  }

  // Task Log tab: most recently active first
  readonly property var logOrder: {
    var a = todos.slice()
    a.sort(function(x, y) { return (y.counts.doing > 0) - (x.counts.doing > 0) || y.logMtime - x.logMtime || y.mtime - x.mtime })
    return a
  }

  // Progress tab rows (collapsible)
  readonly property var progressRows: {
    var byGroup = {}, names = []
    for (var i = 0; i < todos.length; i++) {
      var g = todos[i].group || ""
      if (!(g in byGroup)) { byGroup[g] = []; names.push(g) }
      byGroup[g].push(todos[i])
    }
    names.sort(function(a, b) { return (a === "") - (b === "") || tasks.groupRank(a) - tasks.groupRank(b) || a.localeCompare(b) })
    var rows = [], shutSuper = false
    function tally(list) {
      var units = 0, done = 0
      list.forEach(function(t) {
        var u = Math.max(1, t.subs.length)
        units += u
        done += t.done ? u : t.counts.done
      })
      return [units, done]
    }
    tasks.arrangeGroups(names).forEach(function(it) {
      if (it.kind === "super") {
        shutSuper = tasks.superCollapsed(it.name, "progress")
        var u = 0, d = 0, c = 0
        it.members.forEach(function(m) { var tl = tally(byGroup[m]); u += tl[0]; d += tl[1]; c += byGroup[m].length })
        rows.push({ kind: "super", name: it.name, pct: u ? d / u : 0, count: c, collapsed: shutSuper })
        return
      }
      if (it.depth && shutSuper) return
      var n = it.name, list = byGroup[n], tl = tally(list)
      rows.push({ kind: "group", name: n, pct: tl[0] ? tl[1] / tl[0] : 0, count: list.length, depth: it.depth })
      if (tasks.groupCollapsed(n, "progress")) return
      list.forEach(function(t) {
        rows.push({ kind: "todo", t: t, depth: it.depth })
        if (tasks.expanded["t:" + t.id]) t.subs.forEach(function(s) { rows.push({ kind: "sub", t: t, s: s, depth: it.depth }) })
      })
    })
    return rows
  }

  // ---- backend ------------------------------------------------------------------
  property var queue: []
  Process {
    id: runner
    stdout: StdioCollector { id: runOut }
    stderr: StdioCollector { onStreamFinished: if (text.trim() !== "") tasks.error = text.trim() }
    onExited: {
      var after = tasks.pendingThen
      tasks.pendingThen = null
      if (after) { try { after(JSON.parse(runOut.text)) } catch (e) {} }
      tasks.next()
      tasks.refresh()
    }
  }
  property var pendingThen: null
  // run taskchy.py with args, then (optionally) `then` with its JSON
  function act(args, then) {
    queue = queue.concat([{ args: args, then: then || null }])
    next()
  }
  function next() {
    if (runner.running || queue.length === 0) return
    var job = queue[0]
    queue = queue.slice(1)
    error = ""
    pendingThen = job.then
    runner.command = ["python3", script].concat(job.args)
    runner.running = true
  }

  Process {
    id: lister
    command: ["python3", tasks.script, "list"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var r = JSON.parse(text)
          tasks.folder = r.folder
          tasks.groupColors = r.groups
          tasks.groupOrder = r.groupOrder || []
          tasks.supersMap = r.supers || ({})
          tasks.superOrderList = r.superOrder || []
          tasks.todos = r.todos
          if (tasks.selectedId === "" || !tasks.selected) tasks.selectedId = tasks.todoOrder.length ? tasks.todoOrder[0] : ""
        } catch (e) { tasks.error = "couldn't read the notes folder" }
      }
    }
  }
  Process {
    id: archiveLister
    command: ["python3", tasks.script, "search", tasks.archiveQuery, "--archived"]
    stdout: StdioCollector {
      onStreamFinished: { try { tasks.archivedTodos = JSON.parse(text).todos.filter(function(t) { return t.archived }) } catch (e) {} }
    }
  }
  Process {
    id: logReader
    stdout: StdioCollector {
      onStreamFinished: { try { tasks.logEntries = JSON.parse(text).entries.slice().reverse() } catch (e) { tasks.logEntries = [] } }
    }
  }
  Process {
    id: logAllReader
    command: ["python3", tasks.script, "log-all"]
    stdout: StdioCollector {
      onStreamFinished: { try { tasks.allLogEntries = JSON.parse(text).entries } catch (e) { tasks.allLogEntries = [] } }
    }
  }
  function refresh() {
    if (!lister.running) lister.running = true
    if (tab === "log" && logWide && !logAllReader.running) logAllReader.running = true
    if (tab === "log" && selectedId !== "" && !logReader.running) {
      logReader.command = ["python3", script, "log-show", selectedId]
      logReader.running = true
    }
    if (tab === "progress" && !archiveLister.running) archiveLister.running = true
  }
  onTabChanged: refresh()
  onSelectedIdChanged: { logEntries = []; subIndex = 0; logSub = 0; logEntry = 0; if (tab === "log") refresh() }
  onArchiveQueryChanged: { refresh(); archiveIndex = 0 }
  onArchiveRowsChanged: if (archiveIndex >= archiveRows.length) archiveIndex = Math.max(0, archiveRows.length - 1)
  // the archive, by group (in group order, loose ones last), then by title
  readonly property var archiveSorted: archivedTodos.slice().sort(function(a, b) {
    var ga = a.group || "", gb = b.group || "", sa = superOf(ga), sb = superOf(gb)
    return (sa === "") - (sb === "") || superRank(sa) - superRank(sb) || sa.localeCompare(sb)
      || (ga === "") - (gb === "") || groupRank(ga) - groupRank(gb) || ga.localeCompare(gb) || a.title.localeCompare(b.title)
  })
  // what the archive list shows: super group › group headings, then the todos
  readonly property var archiveRows: {
    var rows = [], lastSup = null, last = null, shead = null, head = null
    var named = archiveSorted.some(function(t) { return !!t.group })
    archiveSorted.forEach(function(t, i) {
      var g = t.group || "", sp = superOf(g)
      if (sp !== lastSup) {
        shead = sp ? { kind: "shead", name: sp, count: 0, collapsed: superCollapsed(sp, "archive") } : null
        if (shead) rows.push(shead)
        lastSup = sp; last = null
      }
      if (shead) shead.count++
      var hidden = shead && shead.collapsed
      if (named && g !== last) {
        head = { kind: "head", name: g, count: 0, depth: sp ? 1 : 0, collapsed: groupCollapsed(g, "archive") }
        if (!hidden) rows.push(head)
      }
      last = g
      if (head) head.count++
      if (!hidden && !(head && head.collapsed)) rows.push({ kind: "todo", t: t, i: i, depth: head ? head.depth : 0 })
    })
    return rows
  }
  // the super heading an archive row sits under (-1: none)
  function archiveSuperRow(at) {
    for (var i = at - 1; i >= 0; i--) {
      if (archiveRows[i].kind === "shead") return i
      if (archiveRows[i].kind === "head" && !archiveRows[i].depth) return -1
    }
    return -1
  }
  // fold the group an archived row belongs to and rest on its heading
  function foldArchiveGroupOf(t) {
    var g = t.group || ""
    setGroupCollapsed(g, true, "archive")
    for (var i = 0; i < archiveRows.length; i++)
      if (archiveRows[i].kind === "head" && archiveRows[i].name === g) { archiveIndex = i; return }
  }
  function restoreArchived(a) { if (a) act(["unarchive", a.id]) }   // stays in the archive: restore several in a row
  // agents edit the files while you watch: keep polling while the tab is up
  Timer { interval: 2000; repeat: true; running: tasks.active; triggeredOnStart: true; onTriggered: tasks.refresh() }

  // ---- actions --------------------------------------------------------------------
  function select(delta, order) {
    if (order.length === 0) return
    var i = order.indexOf(selectedId)
    selectedId = order[Math.max(0, Math.min(order.length - 1, (i < 0 ? 0 : i + delta)))]
  }
  // ---- reordering -------------------------------------------------------------
  // every active todo's id, in stored order (what `order` rewrites)
  readonly property var storedOrder: todos.map(function(t) { return t.id })
  // put `id` before (after=false) or after `targetId`, joining targetId's group
  function placeTodo(id, targetId, after, group) {
    if (id === targetId) return
    var ids = storedOrder.filter(function(x) { return x !== id })
    var at = ids.indexOf(targetId)
    if (at < 0) return
    ids.splice(after ? at + 1 : at, 0, id)
    var moving = null
    for (var i = 0; i < todos.length; i++) if (todos[i].id === id) moving = todos[i]
    if (moving && group !== undefined && (moving.group || "") !== group) act(["group", id, group])
    act(["order"].concat(ids))
  }
  // swap a todo (default: the selected one) with its neighbour in its group
  function nudgeTodo(dir, id) {
    var t = null
    for (var k = 0; k < todos.length; k++) if (todos[k].id === (id || selectedId)) t = todos[k]
    if (!t) return false
    var same = todos.filter(function(x) { return (x.group || "") === (t.group || "") }).map(function(x) { return x.id })
    var i = same.indexOf(t.id), j = i + dir
    if (i < 0 || j < 0 || j >= same.length) return false
    placeTodo(t.id, same[j], dir > 0, t.group || "")
    return true
  }
  // ---- group order (shared by every tab) ----
  function groupRank(n) { var i = groupOrder.indexOf(n); return i < 0 ? 100000 : i }
  function sortGroups(names) { names.sort(function(a, b) { return groupRank(a) - groupRank(b) || a.localeCompare(b) }) }
  function allGroupNames() {
    var seen = {}, out = []
    Object.keys(groupColors).concat(todos.map(function(t) { return t.group || "" })).forEach(function(n) {
      if (n && !seen[n]) { seen[n] = true; out.push(n) }
    })
    sortGroups(out)
    return out
  }
  function moveGroup(name, dir) {
    if (!name) return false                  // "no group" always sits last
    var order = allGroupNames(), i = order.indexOf(name), j = i + dir
    if (i < 0 || j < 0 || j >= order.length) return false
    order.splice(i, 1)
    order.splice(j, 0, name)
    act(["group-order"].concat(order))
    return true
  }
  // move a sub-todo past its neighbour in the same lane
  function hopLane(dir) {
    var t = selected, order = ["todo", "doing", "done"]
    if (!t || !t.subs.length) return
    var at = order.indexOf(t.subs[Math.min(logSub, t.subs.length - 1)].state)
    for (var step = 1; step <= 2; step++) {
      var st = order[(at + dir * step + 3) % 3]
      for (var i = 0; i < t.subs.length; i++) if (t.subs[i].state === st) { logSub = i; return }
    }
  }
  function moveInLane(t, i, dir) {
    var st = t.subs[i].state, j = i + dir
    while (j >= 0 && j < t.subs.length && t.subs[j].state !== st) j += dir
    if (j < 0 || j >= t.subs.length) return
    act(["sub-move", t.id, String(i), String(j)])
    logSub = j
  }
  // drag state (todos: list rows; subs: sub rows)
  property string dragTodo: ""
  property int dragSub: -1
  property real dropY: -1                      // marker, in the list's coordinates

  // move a sub-todo one lane on (+1) or back (-1)
  function shift(t, i, dir) {
    var order = ["todo", "doing", "done"]
    var s = t.subs[i]
    var n = order[Math.max(0, Math.min(2, order.indexOf(s.state) + dir))]
    if (n !== s.state) act(["sub-set", t.id, String(i), n, "--expect", s.text])
  }
  function cycle(t, i) {
    var s = t.subs[i]
    var next = s.state === "todo" ? "doing" : s.state === "doing" ? "done" : "todo"
    act(["sub-set", t.id, String(i), next, "--expect", s.text])
  }
  function remove(id) {
    if (armedDelete !== id) { armedDelete = id; disarm.restart(); return }
    armedDelete = ""
    act(["delete", id])
  }
  Timer { id: disarm; interval: 2500; onTriggered: tasks.armedDelete = "" }
  // the same menu on a group heading: archive or delete the whole group
  function openSuperMenu(name, x, y) {
    menu.archived = false
    menu.todo = null
    menu.headGroup = ""
    menu.headSuper = name
    menu.armed = ""
    menu.x = Math.max(0, Math.min(tasks.width - menu.width, x))
    menu.y = Math.max(50, Math.min(tasks.height - menu.height, y))
    menu.index = 0
    menu.visible = true
    menu.forceActiveFocus()
  }
  function openGroupMenu(name, x, y) {
    if (!name) return                         // "no group" isn't a group
    menu.archived = false
    menu.todo = null
    menu.headSuper = ""
    menu.headGroup = name
    menu.armed = ""
    menu.x = Math.max(0, Math.min(tasks.width - menu.width, x))
    menu.y = Math.max(50, Math.min(tasks.height - menu.height, y))
    menu.index = 0
    menu.visible = true
    menu.forceActiveFocus()
  }
  function archiveGroup(name) { if (name) act(["group-archive", name]) }
  function archiveSuper(name) { if (name) act(["super-archive", name]) }
  // restore a whole group (or super group) from the archive; you stay in the archive
  function restoreGroup(name) { act(["group-restore", name]) }
  function restoreSuper(name) { if (name) act(["super-restore", name]) }
  // ---- rename (e) / delete (d d) the highlighted group, on any tab ----
  property string armedGroup: ""             // waiting for the second d
  property string renamingGroup: ""
  Timer { id: disarmGroup; interval: 2500; onTriggered: tasks.armedGroup = "" }
  function deleteGroupKey(name) {
    if (!name) return
    if (armedGroup !== name) { armedGroup = name; disarmGroup.restart(); return }
    armedGroup = ""
    act(["group-delete", name])
  }
  function startRenameGroup(name) {
    if (!name) return
    renamingGroup = name
    renameGroupInput.text = name
    renameGroupInput.selectAll()
    renameGroupInput.forceActiveFocus()
  }
  function finishRenameGroup(to) {
    var from = renamingGroup
    var isSuper = renamingIsSuper
    renamingGroup = ""
    renamingIsSuper = false
    forceActiveFocus()
    if (!to || to === from) return
    if (isSuper) {
      {
        var ms = Object.assign({}, tasks.ui)
        ;["", "progress", "log"].forEach(function(sc) {
          if (ms[foldKey("super:" + from, sc)]) { delete ms[foldKey("super:" + from, sc)]; ms[foldKey("super:" + to, sc)] = true }
        })
        tasks.ui = ms
      }
      if (cursor === "s:" + from) cursor = "s:" + to
      if (logCursor === "s:" + from) logCursor = "s:" + to
      act(["super-rename", from, to])
      return
    }
    // folds follow the group to its new name
    {
      var m = Object.assign({}, tasks.ui)
      ;["", "progress", "log", "archive"].forEach(function(sc) {
        if (m[foldKey(from, sc)]) { delete m[foldKey(from, sc)]; m[foldKey(to, sc)] = true }
      })
      tasks.ui = m
    }
    if (cursor === "g:" + from) cursor = "g:" + to
    if (logCursor === "g:" + from) logCursor = "g:" + to
    act(["group-rename", from, to])
  }
  function openMenu(t, x, y, archived) {
    menu.archived = !!archived
    menu.headGroup = ""
    menu.headSuper = ""
    menu.armed = ""
    menu.todo = t
    menu.x = Math.max(0, Math.min(tasks.width - menu.width, x))
    menu.y = Math.max(50, Math.min(tasks.height - menu.height, y))
    menu.index = 0
    menu.visible = true
    menu.forceActiveFocus()
  }

  // ---- keyboard --------------------------------------------------------------------
  Keys.onPressed: event => tasks.handleKey(event)
  // every key the view takes; a plain function, so a script can drive it too
  // (anything with key / text / modifiers / accepted will do for `event`)
  function handleKey(event) {
    var k = event.key, txt = event.text
    if (viewEntry) {
      // the entry viewer takes the keys while it's open
      var pics = viewPics
      if (zoomPic !== "") { if (k === Qt.Key_Escape || k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space || txt === "q") zoomPic = "" }
      else if (k === Qt.Key_Escape && picIndex >= 0) { picIndex = -1; armedPic = -1 }
      else if (k === Qt.Key_Escape || k === Qt.Key_Backspace || txt === "q") closeEntry()
      // pictures (a sub-todo's): p adds, ← → pick, Enter shows it big, d d removes
      else if (txt === "p" && viewEntry.isSub) openPicker(selected, viewEntry.n)
      else if ((k === Qt.Key_Right || txt === "l") && pics.length) { picIndex = Math.min(pics.length - 1, picIndex + 1); armedPic = -1 }
      else if ((k === Qt.Key_Left || txt === "h") && pics.length) { picIndex = Math.max(0, picIndex - 1); armedPic = -1 }
      else if ((k === Qt.Key_Return || k === Qt.Key_Enter) && picIndex >= 0 && pics[picIndex]) zoomPic = pics[picIndex].file
      else if ((txt === "d" || k === Qt.Key_Delete) && picIndex >= 0 && pics[picIndex]) {
        if (armedPic !== picIndex) { armedPic = picIndex; disarmPic.restart() }
        else removePicture(viewEntry.n, picIndex)
      }
      else if (txt === "c") copyEntry(viewEntry)
      else if (txt === "e") startEdit()
      else if (k === Qt.Key_Down || txt === "j") viewFlick.flick(0, -700)
      else if (k === Qt.Key_Up || txt === "k") viewFlick.flick(0, 700)
      else if (k === Qt.Key_PageDown || k === Qt.Key_Space) viewFlick.flick(0, -2200)
      else if (k === Qt.Key_PageUp) viewFlick.flick(0, 2200)
      event.accepted = true
      return
    }
    if (showSettings) {
      // the settings pop-up takes the keys while it's up
      if (k === Qt.Key_Escape || txt === "," || txt === "q") showSettings = false
      else if (k === Qt.Key_Up || txt === "k") settingsIndex = Math.max(0, settingsIndex - 1)
      else if (k === Qt.Key_Down || txt === "j") settingsIndex = Math.min(settingsItems.length - 1, settingsIndex + 1)
      else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) applySetting(settingsItems[settingsIndex])
      event.accepted = true; return
    }
    if (txt === ",") { openSettings(); event.accepted = true; return }
    if (txt === "?") { showHelp = !showHelp; event.accepted = true; return }
    if (showHelp) {
      // the keys sheet takes the keys while it's up
      if (k === Qt.Key_Escape || txt === "q") showHelp = false
      else if (k === Qt.Key_Left || txt === "h" || k === Qt.Key_Backtab) { helpSection = (helpSection + helpSections.length - 1) % helpSections.length; helpFlick.contentY = 0 }
      else if (k === Qt.Key_Right || txt === "l" || k === Qt.Key_Tab) { helpSection = (helpSection + 1) % helpSections.length; helpFlick.contentY = 0 }
      else if (k === Qt.Key_Down || txt === "j") helpFlick.flick(0, -700)
      else if (k === Qt.Key_Up || txt === "k") helpFlick.flick(0, 700)
      else if (k === Qt.Key_PageDown || k === Qt.Key_Space) helpFlick.flick(0, -2200)
      else if (k === Qt.Key_PageUp) helpFlick.flick(0, 2200)
      event.accepted = true; return
    }
    // in the Task Log's lanes, Tab / Shift+Tab hop between the three lanes
    // (skipping empty ones), onto the first sub-todo there
    if ((k === Qt.Key_Tab || k === Qt.Key_Backtab) && tab === "log" && logPane === "lanes" && selected) {
      hopLane(k === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? -1 : 1)
      event.accepted = true; return
    }
    if (k === Qt.Key_Tab || k === Qt.Key_Backtab) {
      var order = ["todo", "log", "progress"]
      tab = order[(order.indexOf(tab) + (k === Qt.Key_Backtab ? 2 : 1)) % 3]
      event.accepted = true; return
    }
    if (txt === "1" || txt === "2" || txt === "3") { tab = ["todo", "log", "progress"][Number(txt) - 1]; event.accepted = true; return }
    var up = k === Qt.Key_Up || txt === "k", down = k === Qt.Key_Down || txt === "j"
    // Esc with nothing to back out of closes Taskchy
    if (k === Qt.Key_Escape && !(tab === "todo" && pane === "subs") && !(tab === "log" && logPane !== "list")
        && !(tab === "progress" && progressPane === "archive") && !showHelp) {
      if (closeRequest) closeRequest()
      event.accepted = true; return
    }
    if (k === Qt.Key_Escape && showHelp) { showHelp = false; event.accepted = true; return }
    if (tab === "todo") {
      var t = selected
      if (pane === "list" && cursor.indexOf("s:") === 0) {
        // resting on a super group's heading
        if (txt === "L") jumpLogFromTodo("super", cursor.slice(2))
        else if (!superKeys(cursor.slice(2), "", k, txt, up, down, event.modifiers & Qt.ShiftModifier, moveCursor)) return
      } else if (pane === "list" && cursor !== "") {
        // resting on a group heading
        var gname = cursor.slice(2)
        if ((up || down) && (event.modifiers & Qt.ShiftModifier)) moveGroup(gname, up ? -1 : 1)
        else if (up || down) moveCursor(up ? -1 : 1)
        else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space || txt === "z") toggleGroup(gname)
        else if (k === Qt.Key_Right || txt === "l") { if (groupCollapsed(gname)) setGroupCollapsed(gname, false) }
        else if (k === Qt.Key_Left || txt === "h") { if (!groupCollapsed(gname)) setGroupCollapsed(gname, true) }
        else if (txt === "g") openGroupMenu(gname, tasks.width * 0.2, 120)
        else if (txt === "e" || k === Qt.Key_F2) startRenameGroup(gname)
        else if (txt === "d" || k === Qt.Key_Delete) deleteGroupKey(gname)
        else if (txt === "A") archiveGroup(gname)
        else if (txt === "L") jumpLogFromTodo("group", gname)
        else if (txt === "n") newInput.forceActiveFocus()
        else if (txt === "f") showDone = !showDone
        else return
      } else if (pane === "list") {
        var hasHead = t && todoNav.indexOf("g:" + (t.group || "")) >= 0
        if ((up || down) && (event.modifiers & Qt.ShiftModifier)) nudgeTodo(up ? -1 : 1)
        else if (up || down) moveCursor(up ? -1 : 1)
        // fold this todo's group away and rest on its heading
        else if ((k === Qt.Key_Left || txt === "h" || txt === "z") && hasHead) toggleGroup(t.group || "")
        else if (k === Qt.Key_Right || k === Qt.Key_Return || k === Qt.Key_Enter || txt === "l") {
          if (t && t.subs.length) { pane = "subs"; subIndex = Math.min(subIndex, t.subs.length - 1) } else if (t) subInput.forceActiveFocus()
        }
        else if (k === Qt.Key_Space && t) act(["done", t.id, t.done ? "false" : "true"])
        else if (txt === "n") newInput.forceActiveFocus()
        else if (txt === "a" && t) subInput.forceActiveFocus()
        else if ((txt === "e" || k === Qt.Key_F2) && t) { renameInput.text = t.title; renameInput.forceActiveFocus() }
        else if (txt === "g" && t) openMenu(t, tasks.width * 0.2, 120)
        else if (txt === "L" && t) jumpLogFromTodo("todo", t.id)
        else if (txt === "A" && t) act(["archive", t.id])
        else if ((txt === "d" || k === Qt.Key_Delete) && t) remove(t.id)
        else if (txt === "f") showDone = !showDone
        else if (txt === "J" || (k === Qt.Key_Down && (event.modifiers & Qt.ShiftModifier))) nudgeTodo(1)
        else if (txt === "K" || (k === Qt.Key_Up && (event.modifiers & Qt.ShiftModifier))) nudgeTodo(-1)
        else return
      } else {
        var n = t ? t.subs.length : 0
        if ((up || down) && (event.modifiers & Qt.ShiftModifier) && t) {
          var to = subIndex + (up ? -1 : 1)
          if (to >= 0 && to < n) { act(["sub-move", t.id, String(subIndex), String(to)]); subIndex = to }
        }
        else if (up) subIndex = Math.max(0, subIndex - 1)
        else if (down) subIndex = Math.min(n - 1, subIndex + 1)
        else if (k === Qt.Key_Left || k === Qt.Key_Escape || txt === "h") pane = "list"
        else if (k === Qt.Key_Space && t && n) cycle(t, subIndex)
        else if ((k === Qt.Key_Return || k === Qt.Key_Enter) && t && n) openSub(t, subIndex, false)
        else if (txt === "a" && t) subInput.forceActiveFocus()
        else if (txt === "L" && t && n) jumpLogFromTodo("sub", subIndex)
        else if (txt === "p" && t && n) openPicker(t, subIndex)
        else if (txt === "i" && t && n) togglePics(t, t.subs[subIndex])
        else if ((txt === "e" || k === Qt.Key_F2) && t && n) subEdit.begin(t, subIndex)
        else if ((txt === "d" || k === Qt.Key_Delete) && t && n) { act(["sub-delete", t.id, String(subIndex)]); subIndex = Math.max(0, subIndex - 1) }
        else if (txt === "K" && t && subIndex > 0) { act(["sub-move", t.id, String(subIndex), String(subIndex - 1)]); subIndex-- }
        else if (txt === "J" && t && subIndex < n - 1) { act(["sub-move", t.id, String(subIndex), String(subIndex + 1)]); subIndex++ }
        else return
      }
    } else if (tab === "log") {
      var lt = selected, ln = lt ? lt.subs.length : 0, ne = logEntryRows.length
      var shiftMove = (up || down) && (event.modifiers & Qt.ShiftModifier)
      if (txt === "w" && lt) logInput.forceActiveFocus()
      else if (txt === "L") jumpLogHere()
      else if (txt === "s" || txt === "S") toggleLogSort(txt === "S")
      else if (k === Qt.Key_PageDown) logList.flick(0, -1600)
      else if (k === Qt.Key_PageUp) logList.flick(0, 1600)
      else if (logPane === "entries") {
        // the log itself (by sub-todo, its section headings fold like groups)
        var lp = logPicked, onHead = lp && lp.kind === "head"
        if (shiftMove) { if (logBySub) moveSection(up ? -1 : 1) }
        else if (up && logEntry <= 0) logPane = ln ? "lanes" : "list"
        else if (up) logEntry--
        else if (down) logEntry = Math.min(ne - 1, logEntry + 1)
        else if (onHead && (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space || txt === "z")) setSectionFolded(lp.key, !lp.collapsed)
        else if (onHead && (k === Qt.Key_Right || txt === "l")) setSectionFolded(lp.key, false)
        else if (onHead && !lp.collapsed && (k === Qt.Key_Left || txt === "h")) setSectionFolded(lp.key, true)
        // ← on a folded heading: up to the heading it sits in (else back to the list)
        else if (onHead && (k === Qt.Key_Left || txt === "h") && parentHead(logEntryRows[logEntry]) >= 0) logEntry = parentHead(logEntryRows[logEntry])
        else if (lp && lp.kind === "entry" && (k === Qt.Key_Left || txt === "h" || txt === "z") && foldSectionOf(logEntryRows[logEntry])) {}
        else if (lp && lp.kind === "entry" && (k === Qt.Key_Return || k === Qt.Key_Enter)) openEntry(lp.e, false)
        else if (lp && lp.kind === "entry" && txt === "c") copyEntry(lp.e)
        else if (lp && lp.kind === "entry" && txt === "e") openEntry(lp.e, true)
        else if (k === Qt.Key_Left || k === Qt.Key_Escape || txt === "h") logPane = "list"
        else return
      }
      else if (logPane === "list" && logCursor.indexOf("s:") === 0) {
        if (!superKeys(logCursor.slice(2), "log", k, txt, up, down, shiftMove, moveLogCursor)) return
      }
      else if (logPane === "list" && logCursor !== "") {
        // resting on a group heading
        var lg = logCursor.slice(2)
        if (shiftMove) moveGroup(lg, up ? -1 : 1)
        else if (up || down) moveLogCursor(up ? -1 : 1)
        else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space || txt === "z") toggleLogGroup(lg)
        else if (txt === "g") openGroupMenu(lg, tasks.width * 0.1, 120)
        else if (txt === "e" || k === Qt.Key_F2) startRenameGroup(lg)
        else if (txt === "d" || k === Qt.Key_Delete) deleteGroupKey(lg)
        else if (txt === "A") archiveGroup(lg)
        else if (k === Qt.Key_Right || txt === "l") setGroupCollapsed(lg, false, "log")
        else if (k === Qt.Key_Left || txt === "h") setGroupCollapsed(lg, true, "log")
        else return
      }
      else if (logPane === "list") {
        var logHead = lt && logNav.indexOf("g:" + (lt.group || "")) >= 0
        if (shiftMove) nudgeTodo(up ? -1 : 1)
        else if (up || down) moveLogCursor(up ? -1 : 1)
        else if ((k === Qt.Key_Right || k === Qt.Key_Return || k === Qt.Key_Enter || txt === "l") && ln) { logPane = "lanes"; logSub = Math.min(logSub, ln - 1) }
        else if ((k === Qt.Key_Right || k === Qt.Key_Return || k === Qt.Key_Enter || txt === "l") && ne) { logPane = "entries"; logEntry = 0 }
        else if ((k === Qt.Key_Left || txt === "h" || txt === "z") && logHead) toggleLogGroup(lt.group || "")
        else return
      } else {
        if (shiftMove && ln) moveInLane(lt, logSub, up ? -1 : 1)
        else if (up) logSub = Math.max(0, logSub - 1)
        else if (down && logSub >= ln - 1 && ne) { logPane = "entries"; logEntry = 0 }   // on into the log
        else if (down) logSub = Math.min(ln - 1, logSub + 1)
        else if ((k === Qt.Key_Right || txt === "l" || k === Qt.Key_Space) && ln) shift(lt, logSub, 1)
        else if ((k === Qt.Key_Return || k === Qt.Key_Enter) && ln) openSub(lt, logSub, false)
        else if ((k === Qt.Key_Left || txt === "h") && ln) {
          if (lt.subs[logSub].state === "todo") logPane = "list"
          else shift(lt, logSub, -1)
        }
        else if (k === Qt.Key_Escape) logPane = "list"
        else return
      }
    } else {
      var rows = progressRows.filter(function(r) { return r.kind !== "sub" })
      var r = rows[Math.min(progressIndex, rows.length - 1)]
      var na = archivedTodos.length
      if (txt === "/") archiveInput.forceActiveFocus()
      else if (progressPane === "list" && r && r.kind === "super"
               && !(down && !(event.modifiers & Qt.ShiftModifier) && progressIndex >= rows.length - 1 && na)) {
        if ((up || down) && (event.modifiers & Qt.ShiftModifier)) progressFollow = "s:" + r.name
        if (!superKeys(r.name, "progress", k, txt, up, down, event.modifiers & Qt.ShiftModifier,
                       function(d) { progressIndex = Math.max(0, Math.min(rows.length - 1, progressIndex + d)) })) return
      }
      else if (progressPane === "list") {
        // down past the last row drops into the archive
        if ((up || down) && (event.modifiers & Qt.ShiftModifier) && r) {
          if (r.kind === "group" && moveGroup(r.name, up ? -1 : 1)) progressFollow = "g:" + r.name
          else if (r.kind === "todo" && nudgeTodo(up ? -1 : 1, r.t.id)) progressFollow = "t:" + r.t.id
        }
        else if (up) progressIndex = Math.max(0, progressIndex - 1)
        else if (down && progressIndex >= rows.length - 1 && na) { progressPane = "archive"; archiveIndex = Math.min(archiveIndex, archiveRows.length - 1) }
        else if (down) progressIndex = Math.min(rows.length - 1, progressIndex + 1)
        else if ((k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) && r) toggleExpand(r)
        // same folding keys as the Todo tab
        else if (r && r.kind === "group" && (k === Qt.Key_Right || txt === "l")) setGroupCollapsed(r.name, false, "progress")
        else if (r && r.kind === "group" && (k === Qt.Key_Left || txt === "h")) setGroupCollapsed(r.name, true, "progress")
        else if (r && r.kind === "group" && txt === "z") toggleExpand(r)
        else if (r && r.kind === "group" && txt === "g") openGroupMenu(r.name, tasks.width * 0.3, 120)
        else if (r && r.kind === "group" && (txt === "e" || k === Qt.Key_F2)) startRenameGroup(r.name)
        else if (r && r.kind === "group" && (txt === "d" || k === Qt.Key_Delete)) deleteGroupKey(r.name)
        else if (r && r.kind === "group" && txt === "A") archiveGroup(r.name)
        else if (r && r.kind === "todo" && (k === Qt.Key_Right || txt === "l")) { if (r.t.subs.length) setSubsOpen(r.t.id, true) }
        else if (r && r.kind === "todo" && (k === Qt.Key_Left || txt === "h")) {
          if (expanded["t:" + r.t.id]) setSubsOpen(r.t.id, false)
          else foldProgressGroupOf(r.t)
        }
        else if (r && r.kind === "todo" && txt === "z") foldProgressGroupOf(r.t)
        else if (txt === "A" && r && r.kind === "todo") act(["archive", r.t.id])
        else return
      } else {
        // up past the first archived list climbs back into the progress rows
        var ar = archiveRows[Math.min(archiveIndex, archiveRows.length - 1)]
        var nr = archiveRows.length
        if (up && archiveIndex <= 0) { progressPane = "list"; progressIndex = Math.max(0, rows.length - 1) }
        else if (up) archiveIndex--
        else if (down) archiveIndex = Math.min(nr - 1, archiveIndex + 1)
        // on a super group's heading: fold / unfold, r restores all of it
        else if (ar && ar.kind === "shead" && (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space || txt === "z")) setSuperCollapsed(ar.name, !ar.collapsed, "archive")
        else if (ar && ar.kind === "shead" && (k === Qt.Key_Right || txt === "l")) setSuperCollapsed(ar.name, false, "archive")
        else if (ar && ar.kind === "shead" && (k === Qt.Key_Left || txt === "h")) setSuperCollapsed(ar.name, true, "archive")
        else if (ar && ar.kind === "shead" && (txt === "r" || txt === "R")) restoreSuper(ar.name)
        else if (ar && ar.kind === "shead" && (txt === "e" || k === Qt.Key_F2)) startRenameSuper(ar.name)
        else if (ar && ar.kind === "shead" && (txt === "d" || k === Qt.Key_Delete)) deleteSuperKey(ar.name)
        // on a group's heading: fold / unfold, like everywhere else (r restores the group)
        else if (ar && ar.kind === "head" && (txt === "r" || txt === "R")) restoreGroup(ar.name)
        // ← on a folded group in a super group: up to the super group's heading
        else if (ar && ar.kind === "head" && ar.collapsed && (k === Qt.Key_Left || txt === "h") && archiveSuperRow(archiveIndex) >= 0) archiveIndex = archiveSuperRow(archiveIndex)
        else if (ar && ar.kind === "head" && (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space || txt === "z")) setGroupCollapsed(ar.name, !ar.collapsed, "archive")
        else if (ar && ar.kind === "head" && (k === Qt.Key_Right || txt === "l")) setGroupCollapsed(ar.name, false, "archive")
        else if (ar && ar.kind === "head" && (k === Qt.Key_Left || txt === "h")) setGroupCollapsed(ar.name, true, "archive")
        else if (ar && ar.kind === "head" && (txt === "e" || k === Qt.Key_F2)) startRenameGroup(ar.name)
        else if (ar && ar.kind === "head" && (txt === "d" || k === Qt.Key_Delete)) deleteGroupKey(ar.name)
        // on an archived todo
        else if (ar && ar.kind === "todo" && (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space || txt === "r")) restoreArchived(ar.t)
        else if (ar && ar.kind === "todo" && txt === "g") openMenu(ar.t, tasks.width * 0.3, tasks.height - 360, true)
        else if (ar && ar.kind === "todo" && (k === Qt.Key_Left || txt === "h" || txt === "z") && archiveRows.some(function(x) { return x.kind === "head" })) foldArchiveGroupOf(ar.t)
        else if (k === Qt.Key_Escape) progressPane = "list"
        else return
      }
    }
    event.accepted = true
  }
  function toggleExpand(r) {
    if (r.kind === "super") { setSuperCollapsed(r.name, !superCollapsed(r.name, "progress"), "progress"); return }
    if (r.kind === "group") { setGroupCollapsed(r.name, !groupCollapsed(r.name, "progress"), "progress"); return }
    setSubsOpen(r.t.id, !expanded["t:" + r.t.id])
  }
  function setSubsOpen(id, open) {
    var e = Object.assign({}, expanded)
    e["t:" + id] = open
    expanded = e
  }
  // fold a todo's group on the Progress tab and rest on its heading
  function foldProgressGroupOf(t) {
    var name = t.group || ""
    setGroupCollapsed(name, true, "progress")
    var nav = progressRows.filter(function(r) { return r.kind !== "sub" })
    for (var i = 0; i < nav.length; i++) if (nav[i].kind === "group" && nav[i].name === name) { progressIndex = i; return }
  }


  // ================================================================= pieces
  // a section label: small caps with an accent tick, like Lacquer's sections
  component Heading: Row {
    id: hd
    property string text: ""
    property color mark: tasks.accent
    property bool tick: true
    property bool strong: false
    spacing: 7
    Rectangle {
      visible: hd.tick
      width: 3; height: hdText.implicitHeight - 3; radius: 1.5
      color: hd.mark
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      id: hdText
      text: hd.text
      color: hd.strong ? tasks.fg : tasks.dim
      font.family: tasks.font
      font.pixelSize: tasks.px(10.5)
      font.bold: true
      font.letterSpacing: 1.1
      font.capitalization: Font.AllUppercase
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  component Btn: Rectangle {
    id: btn
    property string icon: ""
    property string text: ""
    property bool on: false
    property real size: 11
    signal clicked()
    height: Math.round(tasks.px(size) * 2.2)
    width: btnRow.implicitWidth + 18
    radius: tasks.rad
    color: btn.on ? tasks.tint(tasks.accent, 0.16) : btnMouse.containsMouse ? tasks.hoverFill : tasks.rowFill
    border.color: btn.on ? tasks.accent : btnMouse.containsMouse ? tasks.tint(tasks.fg, 0.25) : tasks.line
    border.width: 1
    Row {
      id: btnRow
      anchors.centerIn: parent
      spacing: 6
      Text { visible: btn.icon !== ""; text: btn.icon; color: btn.on ? tasks.accent : tasks.fg; font.family: tasks.font; font.pixelSize: tasks.px(btn.size); anchors.verticalCenter: parent.verticalCenter }
      Text { visible: btn.text !== ""; text: btn.text; color: btn.on ? tasks.accent : tasks.fg; font.family: tasks.font; font.pixelSize: tasks.px(btn.size); anchors.verticalCenter: parent.verticalCenter }
    }
    MouseArea { id: btnMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: btn.clicked() }
  }

  // a text box (Enter saves, Esc leaves)
  component Field: Rectangle {
    id: field
    property alias input: fieldInput
    property string placeholder: ""
    property string icon: ""
    // stay in the box after Enter (for typing several in a row)
    property bool keepFocus: false
    property bool clearOnEnter: true
    signal accepted(string text)
    signal entered()
    height: tasks.px(32)
    radius: tasks.rad
    color: fieldInput.activeFocus ? tasks.tint(tasks.fg, 0.07) : fieldMouse.containsMouse ? tasks.tint(tasks.fg, 0.06) : tasks.rowFill
    border.color: fieldInput.activeFocus ? tasks.accent : tasks.line
    border.width: 1
    Text {
      id: fieldIcon
      x: 11
      anchors.verticalCenter: parent.verticalCenter
      text: field.icon
      color: fieldInput.activeFocus ? tasks.accent : tasks.faint
      font.family: tasks.font
      font.pixelSize: tasks.px(11)
    }
    MouseArea { id: fieldMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.IBeamCursor; onClicked: fieldInput.forceActiveFocus() }
    TextInput {
      id: fieldInput
      x: fieldIcon.x + fieldIcon.implicitWidth + 9
      width: parent.width - x - 11
      anchors.verticalCenter: parent.verticalCenter
      color: tasks.fg
      selectionColor: tasks.tint(tasks.accent, 0.4)
      selectedTextColor: tasks.fg
      font.family: tasks.font
      font.pixelSize: tasks.px(12)
      clip: true
      // (Enter; also emitted by a script calling input.accepted())
      onAccepted: {
        var t = text.trim()
        if (field.clearOnEnter) text = ""
        if (t !== "") field.accepted(t)
        if (!field.keepFocus) tasks.forceActiveFocus()
        field.entered()
      }
      Keys.onEscapePressed: { text = ""; tasks.forceActiveFocus() }
      // Enter is handled here, not left to TextInput: it emits accepted() but
      // passes the key on, so the view's own Enter also ran (opening the
      // highlighted sub-todo while adding a new one)
      Keys.onReturnPressed: fieldInput.accepted()
      Keys.onEnterPressed: fieldInput.accepted()
      Text {
        visible: fieldInput.text === ""
        text: field.placeholder
        color: tasks.faint
        font: fieldInput.font
      }
    }
  }

  // a sub-todo's state: to do / in progress / done
  component StateBox: Rectangle {
    property string state3: "todo"
    width: tasks.px(16); height: width; radius: Math.min(5, tasks.rad / 2)
    color: state3 === "done" ? tasks.accent : state3 === "doing" ? tasks.tint(tasks.accent, 0.22) : "transparent"
    border.color: state3 === "todo" ? tasks.tint(tasks.fg, 0.45) : tasks.accent
    border.width: 1.5
    Text {
      anchors.centerIn: parent
      text: parent.state3 === "done" ? "" : parent.state3 === "doing" ? "" : ""
      color: parent.state3 === "done" ? tasks.bg : tasks.accent
      font.family: tasks.font
      font.pixelSize: tasks.px(8) }
  }

  component Meter: Rectangle {
    property real value: 0
    property color fill: tasks.accent
    height: tasks.px(6)
    radius: height / 2
    color: tasks.tint(tasks.fg, 0.1)
    Rectangle { width: parent.width * Math.max(0, Math.min(1, parent.value)); height: parent.height; radius: parent.radius; color: parent.fill }
  }

  // a group's colour
  component Dot: Rectangle {
    property color dot: "transparent"
    width: tasks.px(9); height: width; radius: width / 2
    color: dot
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
  }

  // a group's heading: click folds it, right-click opens its menu
  component GroupHead: Rectangle {
    id: gh
    property string name: ""
    property bool collapsed: false
    property int count: 0
    property int depth: 0
    property bool here: false
    property string unit: "todo"
    signal toggle()
    signal menu(real x, real y)
    readonly property bool armed: tasks.armedGroup !== "" && tasks.armedGroup === name
    radius: tasks.rad
    color: armed ? tasks.armedFill : here ? tasks.cursorFill : ghMouse.containsMouse ? tasks.hoverFill : "transparent"
    border.color: here ? tasks.accent : "transparent"
    border.width: here ? 1 : 0
    Row {
      x: 8 + gh.depth * 16
      spacing: 7
      anchors.verticalCenter: parent.verticalCenter
      Text { anchors.verticalCenter: parent.verticalCenter; text: gh.collapsed ? "" : ""; color: tasks.faint; font.family: tasks.font; font.pixelSize: tasks.px(8) }
      Dot { visible: !!gh.name; dot: tasks.colorOf(gh.name) }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: gh.armed ? "d again: delete group " + gh.name + " (its todos are kept)" : !gh.name ? "No group" : gh.name
        color: gh.armed ? tasks.fg : gh.here ? tasks.accent : tasks.dim
        font.family: tasks.font; font.pixelSize: tasks.px(10.5); font.bold: true
        font.letterSpacing: 1.1; font.capitalization: gh.armed ? Font.MixedCase : Font.AllUppercase
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: gh.collapsed
        text: gh.count + " " + gh.unit + (gh.count === 1 ? "" : "s")
        color: tasks.faint; font.family: tasks.font; font.pixelSize: tasks.px(10) }
    }
    MouseArea {
      id: ghMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: mouse => {
        if (mouse.button === Qt.RightButton) { var p = mapToItem(tasks, mouse.x, mouse.y); gh.menu(p.x, p.y) }
        else gh.toggle()
      }
    }
  }

  // a super group's heading (a group of groups)
  component SuperHead: Rectangle {
    id: sh
    property string name: ""
    property bool collapsed: false
    property int count: 0
    property bool here: false
    signal toggle()
    signal menu(real x, real y)
    readonly property bool armed: tasks.armedSuper !== "" && tasks.armedSuper === name
    radius: tasks.rad
    color: armed ? tasks.armedFill : here ? tasks.cursorFill : shMouse.containsMouse ? tasks.hoverFill : tasks.surface
    border.color: here ? tasks.accent : tasks.line
    border.width: 1
    Rectangle { x: tasks.barX; y: 7; width: 3; height: parent.height - 14; radius: 1.5; color: tasks.superColor(sh.name) }
    Row {
      x: tasks.barX + 11; spacing: 8
      anchors.verticalCenter: parent.verticalCenter
      Text { anchors.verticalCenter: parent.verticalCenter; text: sh.collapsed ? "" : ""; color: tasks.faint; font.family: tasks.font; font.pixelSize: tasks.px(8) }
      Text { anchors.verticalCenter: parent.verticalCenter; text: ""; color: tasks.superColor(sh.name); font.family: tasks.font; font.pixelSize: tasks.px(12) }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: sh.armed ? "d again: delete super group " + sh.name + " (its groups are kept)" : sh.name
        color: sh.here ? tasks.accent : tasks.fg
        font.family: tasks.font; font.bold: true; font.pixelSize: tasks.px(12.5) }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: sh.collapsed
        text: sh.count + (sh.count === 1 ? " todo" : " todos")
        color: tasks.faint; font.family: tasks.font; font.pixelSize: tasks.px(10) }
    }
    MouseArea {
      id: shMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: mouse => {
        if (mouse.button === Qt.RightButton) { var p = mapToItem(tasks, mouse.x, mouse.y); sh.menu(p.x, p.y) }
        else sh.toggle()
      }
    }
  }

  // a framed area (the roughouts' boxes)
  component Panel: Rectangle {
    property bool lit: false
    radius: tasks.rad
    color: tasks.surface
    border.color: lit ? tasks.tint(tasks.accent, 0.7) : tasks.line
    border.width: 1
  }

  // ================================================================= header
  readonly property real headerH: px(34)
  readonly property real tabsH: px(46)
  readonly property real contentTop: headerH + tabsH + px(14)
  readonly property real footerH: px(26)
  readonly property real bodyH: height - contentTop - footerH - px(8)

  Item {
    id: header
    width: parent.width
    height: tasks.headerH
    Row {
      spacing: 10
      anchors.verticalCenter: parent.verticalCenter
      Text { text: ""; color: tasks.accent; font.family: tasks.font; font.pixelSize: tasks.px(18); anchors.verticalCenter: parent.verticalCenter }
      Text { text: "Taskchy"; color: tasks.fg; font.family: tasks.font; font.pixelSize: tasks.px(18); font.bold: true; anchors.verticalCenter: parent.verticalCenter }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: tasks.todos.length + (tasks.todos.length === 1 ? " todo" : " todos")
          + (tasks.doingCount ? "  ·  " + tasks.doingCount + " in progress" : "")
        color: tasks.faint; font.family: tasks.font; font.pixelSize: tasks.px(11)
      }
    }
    Row {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: 8
      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, header.width * 0.55)
        elide: Text.ElideRight
        text: tasks.error !== "" ? "  " + tasks.error
          : tasks.armedGroup !== "" ? "d again: delete group " + tasks.armedGroup + " (its todos are kept)"
          : tasks.armedSuper !== "" ? "d again: delete super group " + tasks.armedSuper + " (its groups are kept)"
          : tasks.shortPath(tasks.folder)
        color: tasks.error !== "" || tasks.armedGroup !== "" || tasks.armedSuper !== "" ? tasks.urgent : tasks.faint
        font.family: tasks.font; font.pixelSize: tasks.px(11)
      }
      Btn { icon: ""; text: "keys  ?"; size: 10; on: tasks.showHelp; onClicked: tasks.showHelp = !tasks.showHelp }
      Btn {
        id: settingsBtn
        icon: ""; text: "settings  ,"; size: 10
        on: tasks.showSettings
        onClicked: { if (tasks.showSettings) tasks.showSettings = false; else tasks.openSettings() }
      }
      Btn { icon: ""; size: 10; onClicked: if (tasks.closeRequest) tasks.closeRequest() }
    }
  }
  readonly property int doingCount: {
    var n = 0
    todos.forEach(function(t) { n += t.counts.doing })
    return n
  }

  // the three tabs, one box split three ways
  Panel {
    id: tabBar
    y: tasks.headerH + px(6)
    width: parent.width
    height: tasks.tabsH
    Row {
      anchors.fill: parent
      anchors.margins: 4
      Repeater {
        model: [["todo", "Todo", "", "1"], ["log", "Task Log", "", "2"], ["progress", "Progress", "", "3"]]
        Rectangle {
          id: tabCell
          required property var modelData
          required property int index
          readonly property bool on: tasks.tab === modelData[0]
          width: (tabBar.width - 8) / 3
          height: parent.height
          radius: Math.max(4, tasks.rad - 3)
          color: on ? tasks.selFill : tabMouse.containsMouse ? tasks.tint(tasks.fg, 0.05) : "transparent"
          // the dividers between the three
          Rectangle { visible: tabCell.index > 0; x: -1; y: 8; width: 1; height: parent.height - 16; color: tasks.line }
          Rectangle {
            visible: tabCell.on
            anchors.bottom: parent.bottom; anchors.bottomMargin: 3
            anchors.horizontalCenter: parent.horizontalCenter
            width: tabLabel.implicitWidth + 30; height: 2; radius: 1
            color: tasks.accent
          }
          Row {
            id: tabLabel
            anchors.centerIn: parent
            spacing: 9
            Text { text: tabCell.modelData[2]; color: tabCell.on ? tasks.accent : tasks.dim; font.family: tasks.font; font.pixelSize: tasks.px(13); anchors.verticalCenter: parent.verticalCenter }
            Text { text: tabCell.modelData[1]; color: tabCell.on ? tasks.fg : tasks.dim; font.family: tasks.font; font.pixelSize: tasks.px(13); font.bold: tabCell.on; anchors.verticalCenter: parent.verticalCenter }
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: tasks.px(16); height: width; radius: 4
              color: "transparent"; border.color: tasks.line; border.width: 1
              Text { anchors.centerIn: parent; text: tabCell.modelData[3]; color: tasks.faint; font.family: tasks.font; font.pixelSize: tasks.px(9) }
            }
          }
          MouseArea { id: tabMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { tasks.tab = tabCell.modelData[0]; tasks.forceActiveFocus() } }
        }
      }
    }
  }

  // ================================================================= footer: the keys for where you are
  readonly property string hints: {
    var h
    if (viewEntry) h = "c copy · e edit" + (viewEntry.isSub ? " · p add picture · ← → pick picture · Enter show big · d d remove" : "") + " · ↑↓ scroll · Esc close"
    else if (tab === "todo") h = pane === "subs"
      ? "↑↓ pick · Space to do → doing → done · Enter open · a add · e edit · p picture · i fold pictures · d delete · Shift ↑↓ move · L log · ← back"
      : cursor.indexOf("s:") === 0 || cursor.indexOf("g:") === 0
        ? "Enter fold · e rename · d d delete · g menu · A archive all · Shift ↑↓ move · L log"
        : "↑↓ pick · → open · n new · a add sub-todo · Space finish · e rename · g group · A archive · d d delete · f finished · L log"
    else if (tab === "log") h = logPane === "lanes"
      ? "→ Space move on · ← back · Tab next lane · Enter open · w write · ↓ into the log"
      : logPane === "entries" ? "↑↓ pick · Enter open · c copy · e edit · ← z fold · s view · w write"
      : "↑↓ pick · → into the lanes · s log view · w write · L jump to its log"
    else h = progressPane === "archive"
      ? "↑↓ pick · Enter r restore · g menu · / search · ← z fold · ↑ Esc back"
      : "↑↓ pick · Enter expand · → ← open / fold · A archive · / search the archive · ↓ past the end: archive"
    return h + "   ·   Tab tabs · ? keys · , settings · Esc close"
  }
  Rectangle {
    y: tasks.height - tasks.footerH
    width: parent.width
    height: 1
    color: tasks.line
  }
  Text {
    y: tasks.height - tasks.footerH + px(7)
    width: parent.width
    elide: Text.ElideRight
    text: tasks.hints
    color: tasks.faint
    font.family: tasks.font
    font.pixelSize: tasks.px(10.5)
  }

  // ======================================================================== TODO
  Item {
    id: todoTab
    visible: tasks.tab === "todo"
    y: tasks.contentTop
    width: parent.width
    height: tasks.bodyH

    // left: add a todo, and the super groups / groups / todos under it
    Item {
      id: todoLeft
      width: Math.round(parent.width * 0.42)
      height: parent.height
      Row {
        id: newRow
        width: parent.width
        spacing: 8
        Field {
          id: newField
          width: parent.width - hideDone.width - 8
          placeholder: "add todo…  (n)"
          onAccepted: t => tasks.act(["add", t], function(r) { tasks.selectedId = r.id })
        }
        Btn {
          id: hideDone
          anchors.verticalCenter: parent.verticalCenter
          icon: tasks.showDone ? "" : ""
          text: "finished"
          size: 10.5
          on: tasks.showDone
          onClicked: tasks.showDone = !tasks.showDone
        }
      }
      Panel {
        y: newRow.height + 10
        width: parent.width
        height: parent.height - y
        lit: tasks.pane === "list"
        ListView {
          id: todoList
          anchors.fill: parent
          anchors.margins: 8
          clip: true
          spacing: 4
          boundsBehavior: Flickable.StopAtBounds
          model: tasks.todoRows
          currentIndex: {
            for (var i = 0; i < tasks.todoRows.length; i++)
              if (tasks.todoNav[i] === tasks.cursorKey) return i
            return -1
          }
          highlightFollowsCurrentItem: false
          onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
          Rectangle {
            z: 10
            visible: tasks.dragTodo !== "" && tasks.dropY >= 0
            y: tasks.dropY - 1
            width: parent.width; height: 2; radius: 1
            color: tasks.accent
          }
          delegate: Item {
            id: row
            required property var modelData
            required property int index
            width: todoList.width
            height: modelData.kind === "group" ? tasks.px(26) : modelData.kind === "super" ? tasks.px(30) : tasks.px(40)
            SuperHead {
              visible: row.modelData.kind === "super"
              anchors.fill: parent
              name: row.modelData.kind === "super" ? row.modelData.name : ""
              collapsed: !!row.modelData.collapsed
              count: row.modelData.count || 0
              here: row.modelData.kind === "super" && tasks.cursor === "s:" + row.modelData.name && tasks.pane === "list"
              onToggle: { tasks.pane = "list"; tasks.cursor = "s:" + name; tasks.setSuperCollapsed(name, !collapsed, ""); tasks.forceActiveFocus() }
              onMenu: (x, y) => { tasks.pane = "list"; tasks.cursor = "s:" + name; tasks.openSuperMenu(name, x, y) }
            }
            GroupHead {
              visible: row.modelData.kind === "group"
              anchors.fill: parent
              name: row.modelData.kind === "group" ? row.modelData.name : ""
              collapsed: !!row.modelData.collapsed
              count: row.modelData.count || 0
              depth: row.modelData.depth || 0
              here: row.modelData.kind === "group" && tasks.cursor === "g:" + row.modelData.name && tasks.pane === "list"
              onToggle: { tasks.pane = "list"; tasks.cursor = "g:" + name; tasks.forceActiveFocus(); tasks.toggleGroup(name) }
              onMenu: (x, y) => { tasks.pane = "list"; tasks.cursor = "g:" + name; tasks.forceActiveFocus(); tasks.openGroupMenu(name, x, y) }
            }
            // a todo
            Rectangle {
              id: todoCard
              visible: row.modelData.kind === "todo"
              anchors.fill: parent
              anchors.leftMargin: (row.modelData.depth || 0) * 16
              readonly property var t: row.modelData.t
              readonly property bool sel: !!t && t.id === tasks.selectedId
              readonly property bool cur: sel && tasks.pane === "list" && tasks.cursor === ""
              opacity: t && tasks.dragTodo === t.id ? 0.45 : 1
              radius: tasks.rad
              color: tasks.armedDelete !== "" && t && tasks.armedDelete === t.id ? tasks.armedFill
                : tasks.rowColor(cur, sel, todoMouse.containsMouse)
              border.color: cur ? tasks.accent : sel ? tasks.tint(tasks.accent, 0.45) : "transparent"
              border.width: 1
              Rectangle { x: tasks.barX; y: 9; width: 3; height: parent.height - 18; radius: 1.5; color: todoCard.t ? tasks.colorOf(todoCard.t.group) : "transparent" }
              Rectangle {
                id: doneBox
                x: tasks.barX + 12; anchors.verticalCenter: parent.verticalCenter
                width: tasks.px(15); height: width; radius: width / 2
                color: todoCard.t && todoCard.t.done ? tasks.accent : "transparent"
                border.color: todoCard.t && todoCard.t.done ? tasks.accent : tasks.tint(tasks.fg, 0.45); border.width: 1.5
                Text { anchors.centerIn: parent; visible: !!(todoCard.t && todoCard.t.done); text: ""; color: tasks.bg; font.family: tasks.font; font.pixelSize: tasks.px(8) }
                MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor
                  onClicked: tasks.act(["done", todoCard.t.id, todoCard.t.done ? "false" : "true"]) }
              }
              Text {
                x: doneBox.x + doneBox.width + 11
                width: parent.width - x - countText.width - 22
                anchors.verticalCenter: parent.verticalCenter
                text: todoCard.t ? todoCard.t.title : ""
                elide: Text.ElideRight
                color: todoCard.cur ? tasks.accent : tasks.fg
                opacity: todoCard.t && todoCard.t.done ? 0.5 : 1
                font.strikeout: todoCard.t ? todoCard.t.done : false
                font.family: tasks.font
                font.pixelSize: tasks.px(12.5)
                font.bold: todoCard.sel
              }
              Row {
                id: countText
                anchors.right: parent.right; anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                Text {
                  visible: !!todoCard.t && todoCard.t.counts.doing > 0
                  text: ""
                  color: tasks.accent; font.family: tasks.font; font.pixelSize: tasks.px(8)
                  anchors.verticalCenter: parent.verticalCenter }
                Text {
                  text: todoCard.t && todoCard.t.subs.length ? todoCard.t.counts.done + "/" + todoCard.t.subs.length : ""
                  color: tasks.faint
                  font.family: tasks.font; font.pixelSize: tasks.px(10.5)
                  anchors.verticalCenter: parent.verticalCenter }
              }
              MouseArea {
                id: todoMouse
                anchors.fill: parent
                anchors.leftMargin: doneBox.x + doneBox.width + 4
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: tasks.dragTodo !== "" ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                preventStealing: true
                property real pressY: 0
                property bool dragging: false
                onPressed: mouse => { pressY = mouse.y; dragging = false }
                onPositionChanged: mouse => {
                  if (!(mouse.buttons & Qt.LeftButton)) return
                  if (!dragging && Math.abs(mouse.y - pressY) > 6) { dragging = true; tasks.dragTodo = todoCard.t.id; tasks.selectedId = todoCard.t.id }
                  if (dragging) {
                    var p = mapToItem(todoList.contentItem, mouse.x, mouse.y)
                    var i = todoList.indexAt(20, p.y)
                    var it = i >= 0 ? todoList.itemAtIndex(i) : null
                    tasks.dropY = it ? (tasks.todoRows[i].kind === "group" || p.y < it.y + it.height / 2 ? it.y - 2 : it.y + it.height + 2) - todoList.contentY : -1
                  }
                }
                onReleased: mouse => {
                  if (!dragging) return
                  dragging = false
                  var p = mapToItem(todoList.contentItem, mouse.x, mouse.y)
                  var i = todoList.indexAt(20, p.y)
                  var rows = tasks.todoRows
                  if (i >= 0) {
                    var r = rows[i], it = todoList.itemAtIndex(i)
                    if (r.kind === "group") {
                      // on a group's heading: to the top of that group
                      var first = null
                      for (var q = 0; q < tasks.todos.length && !first; q++)
                        if ((tasks.todos[q].group || "") === r.name && tasks.todos[q].id !== tasks.dragTodo) first = tasks.todos[q]
                      if (first) tasks.placeTodo(tasks.dragTodo, first.id, false, r.name)
                      else if (r.name) tasks.act(["group", tasks.dragTodo, r.name])
                    } else if (r.kind === "todo") {
                      tasks.placeTodo(tasks.dragTodo, r.t.id, p.y > it.y + it.height / 2, r.t.group || "")
                    }
                  }
                  tasks.dragTodo = ""
                  tasks.dropY = -1
                }
                onClicked: mouse => {
                  tasks.cursor = ""
                  tasks.selectedId = todoCard.t.id
                  tasks.pane = "list"
                  tasks.forceActiveFocus()
                  if (mouse.button === Qt.RightButton) {
                    var p = mapToItem(tasks, mouse.x, mouse.y)
                    tasks.openMenu(todoCard.t, p.x, p.y)
                  }
                }
                onDoubleClicked: { renameInput.text = todoCard.t.title; renameInput.forceActiveFocus() }
              }
            }
          }
          Text {
            visible: tasks.todoRows.length === 0
            width: parent.width
            wrapMode: Text.Wrap
            text: tasks.todos.length ? "Every todo is finished — f shows them again." : "No todos yet. Type one above and press Enter."
            color: tasks.faint
            font.family: tasks.font; font.pixelSize: tasks.px(11.5)
          }
        }
      }
    }

    // right: the selected todo's sub-todos
    Panel {
      id: subPanel
      x: todoLeft.width + 14
      width: parent.width - x
      height: parent.height
      lit: tasks.pane === "subs"
      visible: tasks.selected !== null

      Column {
        id: subHead
        x: 14; y: 12
        width: parent.width - 28
        spacing: 8
        Field {
          id: subField
          width: parent.width
          placeholder: "add sub-todo…  (a)"
          keepFocus: true
          onAccepted: t => { if (tasks.selected) tasks.act(["sub-add", tasks.selected.id, t]) }
          Component.onCompleted: subInput = subField.input
        }
        Item {
          width: parent.width
          height: tasks.px(26)
          Text {
            visible: !renameInput.activeFocus
            width: parent.width
            anchors.verticalCenter: parent.verticalCenter
            text: tasks.selected ? tasks.selected.title : ""
            elide: Text.ElideRight
            color: tasks.fg
            font.family: tasks.font
            font.bold: true
            font.pixelSize: tasks.px(16) }
          Rectangle {
            visible: renameInput.activeFocus
            anchors.fill: parent; anchors.margins: -3
            radius: tasks.rad
            color: tasks.tint(tasks.fg, 0.07); border.color: tasks.accent; border.width: 1
          }
          TextInput {
            id: renameInput
            visible: activeFocus
            x: 6
            width: parent.width - 12
            anchors.verticalCenter: parent.verticalCenter
            color: tasks.fg
            selectionColor: tasks.tint(tasks.accent, 0.4)
            font.family: tasks.font
            font.pixelSize: tasks.px(15)
            font.bold: true
            Keys.onReturnPressed: { if (tasks.selected && text.trim() !== "") tasks.act(["rename", tasks.selected.id, text.trim()]); tasks.forceActiveFocus() }
            Keys.onEnterPressed: { if (tasks.selected && text.trim() !== "") tasks.act(["rename", tasks.selected.id, text.trim()]); tasks.forceActiveFocus() }
            Keys.onEscapePressed: tasks.forceActiveFocus()
          }
        }
        Row {
          spacing: 8
          Dot { visible: !!tasks.selected && tasks.selected.group !== ""; dot: tasks.selected ? tasks.colorOf(tasks.selected.group) : "transparent" }
          Text {
            text: tasks.selected ? (tasks.selected.group ? (tasks.superOf(tasks.selected.group) ? tasks.superOf(tasks.selected.group) + "  ›  " : "") + tasks.selected.group : "no group")
              + "  ·  " + tasks.selected.counts.done + " of " + tasks.selected.subs.length + " done"
              + (tasks.selected.counts.doing ? "  ·  " + tasks.selected.counts.doing + " in progress" : "") : ""
            color: tasks.dim
            font.family: tasks.font; font.pixelSize: tasks.px(10.5) }
        }
        Meter {
          width: parent.width
          value: tasks.selected ? tasks.pct(tasks.selected) : 0
          fill: tasks.selected && tasks.selected.group ? tasks.colorOf(tasks.selected.group) : tasks.accent
        }
      }
      ListView {
        id: subList
        x: 14; y: subHead.y + subHead.height + 12
        width: parent.width - 28
        height: parent.height - y - 10
        clip: true
        spacing: 4
        boundsBehavior: Flickable.StopAtBounds
        model: tasks.selected ? tasks.selected.subs : []
        currentIndex: tasks.subIndex
        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
        // a change reloads the list (which scrolls back to the top): stay on
        // the sub-todo you were on
        onModelChanged: keepSub.restart()
        // (the reload resets currentIndex and breaks its binding: put both back)
        Timer {
          id: keepSub; interval: 40
          onTriggered: {
            subList.currentIndex = Qt.binding(function() { return tasks.subIndex })
            if (tasks.subIndex >= 0 && tasks.subIndex < subList.count) subList.positionViewAtIndex(tasks.subIndex, ListView.Contain)
          }
        }
        Rectangle {
          z: 10
          visible: tasks.dragSub >= 0 && tasks.dropY >= 0
          y: tasks.dropY - 1
          width: parent.width; height: 2; radius: 1
          color: tasks.accent
        }
        delegate: Rectangle {
          id: subRow
          required property var modelData
          required property int index
          readonly property bool sel: tasks.pane === "subs" && index === tasks.subIndex
          width: subList.width
          readonly property var pics: modelData.images || []
          readonly property bool picsShown: pics.length > 0 && tasks.picsOpen(tasks.selected, modelData)
          readonly property real textH: Math.max(tasks.px(32), subText.implicitHeight + 14)
          height: textH + (picsShown ? tasks.px(72) : 0)
          radius: tasks.rad
          color: tasks.rowColor(sel, false, subMouse.containsMouse)
          border.color: sel ? tasks.accent : "transparent"
          border.width: 1
          opacity: tasks.dragSub === index ? 0.45 : 1
          StateBox {
            x: 10; y: (subRow.textH - height) / 2
            state3: subRow.modelData.state
            MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor
              onClicked: tasks.cycle(tasks.selected, subRow.index) }
          }
          Text {
            id: subText
            visible: !(subEdit.activeFocus && subEdit.index === subRow.index)
            x: tasks.px(16) + 22; width: parent.width - x - 10 - (subRow.pics.length ? picChip.width + 6 : 0)
            y: (subRow.textH - implicitHeight) / 2
            text: subRow.modelData.text
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            color: subRow.modelData.state === "doing" ? tasks.accent : tasks.fg
            opacity: subRow.modelData.state === "done" ? 0.5 : 1
            font.strikeout: subRow.modelData.state === "done"
            font.family: tasks.font
            font.pixelSize: tasks.px(12) }
          // its pictures: a chip that folds them (i), and a strip of thumbnails
          Rectangle {
            id: picChip
            z: 2
            visible: subRow.pics.length > 0
            anchors.right: parent.right; anchors.rightMargin: 8
            y: (subRow.textH - height) / 2
            width: chipText.implicitWidth + 14; height: tasks.px(20); radius: height / 2
            color: chipMouse.containsMouse ? tasks.hoverFill : tasks.rowFill
            border.color: tasks.line; border.width: 1
            Text {
              id: chipText
              anchors.centerIn: parent
              text: " " + subRow.pics.length + "  " + (subRow.picsShown ? "" : "")
              color: tasks.dim; font.family: tasks.font; font.pixelSize: tasks.px(9.5)
            }
            MouseArea { id: chipMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
              onClicked: tasks.togglePics(tasks.selected, subRow.modelData) }
          }
          Row {
            z: 2
            visible: subRow.picsShown
            x: subText.x; y: subRow.textH
            width: parent.width - x - 8
            height: tasks.px(64)
            spacing: 6
            clip: true
            Repeater {
              model: subRow.picsShown ? subRow.pics : []
              Rectangle {
                required property var modelData
                height: parent.height; width: Math.max(40, Math.min(140, thumb.implicitWidth > 0 ? height * thumb.implicitWidth / Math.max(1, thumb.implicitHeight) : height))
                radius: Math.max(4, tasks.rad - 2); clip: true
                color: tasks.rowFill; border.color: tasks.line; border.width: 1
                Image {
                  id: thumb
                  anchors.fill: parent; anchors.margins: 2
                  source: "file://" + parent.modelData.file
                  sourceSize.height: 128
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                  onClicked: tasks.zoomPic = parent.modelData.file }
              }
            }
          }
          MouseArea {
            id: subMouse
            anchors.fill: parent; anchors.leftMargin: 30
            anchors.bottomMargin: subRow.picsShown ? tasks.px(72) : 0
            anchors.rightMargin: subRow.pics.length ? picChip.width + 10 : 0
            hoverEnabled: true
            preventStealing: true
            cursorShape: tasks.dragSub >= 0 ? Qt.ClosedHandCursor : Qt.PointingHandCursor
            property real pressY: 0
            property bool dragging: false
            function target(mouse) {
              var p = mapToItem(subList.contentItem, mouse.x, mouse.y)
              var i = subList.indexAt(20, p.y)
              if (i < 0) i = p.y < 0 ? 0 : subList.count - 1
              return i
            }
            onPressed: mouse => { pressY = mouse.y; dragging = false }
            onPositionChanged: mouse => {
              if (!(mouse.buttons & Qt.LeftButton)) return
              if (!dragging && Math.abs(mouse.y - pressY) > 6) { dragging = true; tasks.dragSub = subRow.index; tasks.pane = "subs" }
              if (dragging) {
                var it = subList.itemAtIndex(target(mouse))
                var down = target(mouse) > subRow.index
                tasks.dropY = it ? (down ? it.y + it.height + 2 : it.y - 2) - subList.contentY : -1
              }
            }
            onReleased: mouse => {
              if (!dragging) return
              dragging = false
              var to = target(mouse)
              if (to !== subRow.index && tasks.selected) {
                tasks.act(["sub-move", tasks.selected.id, String(subRow.index), String(to)])
                tasks.subIndex = to
              }
              tasks.dragSub = -1
              tasks.dropY = -1
            }
            onClicked: { tasks.pane = "subs"; tasks.subIndex = subRow.index; tasks.forceActiveFocus() }
            onDoubleClicked: subEdit.begin(tasks.selected, subRow.index)
          }
        }
        Text {
          visible: subList.count === 0
          width: parent.width
          wrapMode: Text.Wrap
          text: "No sub-todos yet — a (or the box above) adds one. Each moves to do → in progress → done."
          color: tasks.faint
          font.family: tasks.font; font.pixelSize: tasks.px(11.5)
        }
      }
      // inline editor for a sub-todo (e / F2 / double-click)
      TextInput {
        id: subEdit
        property int index: -1
        visible: activeFocus
        x: subList.x + tasks.px(16) + 22
        y: subList.y + (subList.itemAtIndex(index) ? subList.itemAtIndex(index).y - subList.contentY + 8 : 0)
        width: subList.width - x + subList.x - 12
        color: tasks.fg
        selectionColor: tasks.tint(tasks.accent, 0.4)
        font.family: tasks.font
        font.pixelSize: tasks.px(12)
        Rectangle { anchors.fill: parent; anchors.margins: -5; z: -1; radius: Math.max(4, tasks.rad - 2); color: tasks.bg; border.color: tasks.accent; border.width: 1 }
        // the todo and text it was opened on, so the save lands on that row
        property string todoId: ""
        property string original: ""
        function begin(t, i) {
          if (!t || !t.subs[i]) return
          todoId = t.id; original = t.subs[i].text
          index = i; text = original
          forceActiveFocus()
        }
        // saves on Enter, and also when focus goes elsewhere or Taskchy closes
        function commit() {
          var v = text.trim(), id = todoId
          todoId = ""
          if (id !== "" && v !== "" && v !== original)
            tasks.act(["sub-edit", id, String(index), v, "--expect", original])
        }
        onActiveFocusChanged: if (!activeFocus) commit()
        Keys.onReturnPressed: { commit(); tasks.forceActiveFocus() }
        Keys.onEnterPressed: { commit(); tasks.forceActiveFocus() }
        Keys.onEscapePressed: { todoId = ""; tasks.forceActiveFocus() }
      }
    }
    Text {
      visible: tasks.selected === null
      x: todoLeft.width + 24; y: 30
      width: parent.width - x
      wrapMode: Text.Wrap
      text: "Pick a todo on the left, or add one — each opens into its own list of sub-todos."
      color: tasks.faint
      font.family: tasks.font; font.pixelSize: tasks.px(12) }
  }
  property var subInput: null
  property var logInput: null
  property alias newInput: newField.input

  // ===================================================================== TASK LOG
  Item {
    id: logTab
    visible: tasks.tab === "log"
    y: tasks.contentTop
    width: parent.width
    height: tasks.bodyH

    // the selected todo's sub-todos, shifting across as they're worked on
    Row {
      id: lanes
      width: parent.width
      height: Math.round(parent.height * 0.27)
      spacing: 10
      Repeater {
        model: [["todo", "To do", ""], ["doing", "In progress", ""], ["done", "Done", ""]]
        Panel {
          id: lane
          required property var modelData
          readonly property var items: tasks.selected ? tasks.selected.subs.filter(function(s) { return s.state === lane.modelData[0] }) : []
          readonly property bool hasPick: tasks.logPane === "lanes" && tasks.selected && tasks.selected.subs[tasks.logSub] && tasks.selected.subs[tasks.logSub].state === modelData[0]
          width: (lanes.width - 20) / 3
          height: lanes.height
          lit: hasPick
          Row {
            x: 12; y: 9
            spacing: 8
            Heading { text: lane.modelData[1]; mark: lane.modelData[0] === "doing" ? tasks.accent : lane.modelData[0] === "done" ? tasks.tint(tasks.accent, 0.5) : tasks.tint(tasks.fg, 0.3) }
            Text { text: lane.items.length; color: tasks.faint; font.family: tasks.font; font.pixelSize: tasks.px(10); anchors.verticalCenter: parent.verticalCenter }
          }
          ListView {
            id: laneList
            x: 8; y: tasks.px(30)
            width: parent.width - 16
            height: parent.height - y - 8
            clip: true
            spacing: 3
            model: lane.items
            // stay on the picked sub-todo when the lane reloads
            function keepPicked() {
              for (var i = 0; i < count; i++) if (model[i] && model[i].i === tasks.logSub) { positionViewAtIndex(i, ListView.Contain); return }
            }
            onModelChanged: keepLane.restart()
            Timer { id: keepLane; interval: 40; onTriggered: laneList.keepPicked() }
            // click moves it a lane on, right-click a lane back
            delegate: Rectangle {
              id: laneItem
              required property var modelData
              readonly property bool sel: tasks.logPane === "lanes" && tasks.logSub === modelData.i
              width: ListView.view.width
              height: laneText.implicitHeight + 8
              radius: Math.max(4, tasks.rad - 2)
              color: tasks.rowColor(sel, false, laneMouse.containsMouse, "transparent")
              border.color: sel ? tasks.accent : "transparent"
              border.width: 1
              Text {
                id: laneText
                x: 6; y: 4
                width: parent.width - 12
                text: laneItem.modelData.text
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                textFormat: Text.PlainText
                color: laneItem.sel ? tasks.accent : tasks.fg
                opacity: laneItem.modelData.state === "done" ? 0.6 : 1
                font.family: tasks.font
                font.pixelSize: tasks.px(11) }
              MouseArea {
                id: laneMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onClicked: mouse => {
                  tasks.logPane = "lanes"
                  tasks.logSub = laneItem.modelData.i
                  tasks.shift(tasks.selected, laneItem.modelData.i, mouse.button === Qt.RightButton ? -1 : 1)
                  tasks.forceActiveFocus()
                }
              }
            }
          }
          Text {
            visible: lane.items.length === 0
            x: 12; y: tasks.px(32)
            text: tasks.selected ? "nothing here" : "pick a todo"
            color: tasks.faint; font.family: tasks.font; font.pixelSize: tasks.px(10.5)
          }
        }
      }
    }

    // left: super groups / groups / todos, grouped like the Todo tab
    Panel {
      id: logLeft
      y: lanes.height + 12
      width: Math.round(parent.width * 0.3)
      height: parent.height - y
      lit: tasks.logPane === "list"
      ListView {
        id: logTodoList
        anchors.fill: parent
        anchors.margins: 8
        clip: true
        spacing: 4
        model: tasks.logRows
        delegate: Item {
          id: logRow
          required property var modelData
          width: logTodoList.width
          height: modelData.kind === "group" ? tasks.px(26) : modelData.kind === "super" ? tasks.px(30) : tasks.px(44)
          SuperHead {
            visible: logRow.modelData.kind === "super"
            anchors.fill: parent
            name: logRow.modelData.kind === "super" ? logRow.modelData.name : ""
            collapsed: !!logRow.modelData.collapsed
            count: logRow.modelData.count || 0
            here: logRow.modelData.kind === "super" && tasks.logCursor === "s:" + logRow.modelData.name && tasks.logPane === "list"
            onToggle: { tasks.logPane = "list"; tasks.logCursor = "s:" + name; tasks.setSuperCollapsed(name, !collapsed, "log"); tasks.forceActiveFocus() }
            onMenu: (x, y) => { tasks.logPane = "list"; tasks.logCursor = "s:" + name; tasks.openSuperMenu(name, x, y) }
          }
          GroupHead {
            visible: logRow.modelData.kind === "group"
            anchors.fill: parent
            name: logRow.modelData.kind === "group" ? logRow.modelData.name : ""
            collapsed: !!logRow.modelData.collapsed
            count: logRow.modelData.count || 0
            depth: logRow.modelData.depth || 0
            here: logRow.modelData.kind === "group" && tasks.logCursor === "g:" + logRow.modelData.name && tasks.logPane === "list"
            onToggle: { tasks.logPane = "list"; tasks.logCursor = "g:" + name; tasks.forceActiveFocus(); tasks.toggleLogGroup(name) }
            onMenu: (x, y) => { tasks.logPane = "list"; tasks.logCursor = "g:" + name; tasks.forceActiveFocus(); tasks.openGroupMenu(name, x, y) }
          }
          Rectangle {
            id: logCard
            visible: logRow.modelData.kind === "todo"
            anchors.fill: parent
            anchors.leftMargin: (logRow.modelData.depth || 0) * 16
            readonly property var t: logRow.modelData.kind === "todo" ? logRow.modelData.t : ({ id: "", title: "", group: "", counts: { doing: 0 }, logCount: 0 })
            readonly property bool sel: t.id === tasks.selectedId
            readonly property bool cur: sel && tasks.logCursor === "" && tasks.logPane === "list"
            radius: tasks.rad
            color: tasks.rowColor(cur, sel, logCardMouse.containsMouse)
            border.color: cur ? tasks.accent : sel ? tasks.tint(tasks.accent, 0.45) : "transparent"
            border.width: 1
            Rectangle { x: tasks.barX; y: 9; width: 3; height: parent.height - 18; radius: 1.5; color: tasks.colorOf(logCard.t.group) }
            Column {
              x: tasks.barX + 12; anchors.verticalCenter: parent.verticalCenter
              width: parent.width - x - 12
              spacing: 2
              Text { width: parent.width; elide: Text.ElideRight; text: logCard.t.title; color: logCard.cur ? tasks.accent : tasks.fg; font.family: tasks.font; font.pixelSize: tasks.px(12); font.bold: logCard.sel }
              Text {
                width: parent.width; elide: Text.ElideRight
                text: (logCard.t.counts.doing ? " " + logCard.t.counts.doing + " in progress  ·  " : "") + logCard.t.logCount + (logCard.t.logCount === 1 ? " log entry" : " log entries")
                color: tasks.faint; font.family: tasks.font; font.pixelSize: tasks.px(10) }
            }
            MouseArea { id: logCardMouse; anchors.fill: parent; hoverEnabled: true; onClicked: { tasks.logPane = "list"; tasks.logCursor = ""; tasks.selectedId = logCard.t.id; tasks.forceActiveFocus() } }
          }
        }
      }
    }

    // right: write in the log, and the log itself
    Panel {
      id: logRight
      x: logLeft.width + 14
      y: logLeft.y
      width: parent.width - x
      height: logLeft.height
      lit: tasks.logPane === "entries"

      Field {
        id: logField
        x: 12; y: 12
        width: parent.width - 24
        icon: ""
        // in the lanes, a note is about the sub-todo you've picked there
        readonly property var about: tasks.logPane === "lanes" && tasks.selected && tasks.selected.subs[tasks.logSub] ? tasks.selected.subs[tasks.logSub] : null
        placeholder: !tasks.selected ? "pick a todo to write in its log" : about ? "log about “" + about.text + "”…  (w)" : "log…  (w)"
        onAccepted: t => {
          if (!tasks.selected) return
          var args = ["log", tasks.selected.id, t, "--by", "you"]
          if (about) args = args.concat(["--sub", String(tasks.logSub)])
          tasks.act(args)
        }
        Component.onCompleted: logInput = logField.input
      }
      Heading {
        id: logHeading
        x: 14; y: logField.y + logField.height + 14
        text: "Log" + (tasks.logShown.length ? " — " + tasks.logShown.length + (tasks.logShown.length === 1 ? " entry" : " entries") : "")
        strong: tasks.logPane === "entries"
      }
      Btn {
        anchors.right: parent.right; anchors.rightMargin: 12
        anchors.verticalCenter: logHeading.verticalCenter
        icon: tasks.logModeIcons[tasks.logMode]
        text: tasks.logModeNames[tasks.logMode] + "  (s)"
        size: 10
        onClicked: { tasks.toggleLogSort(); tasks.forceActiveFocus() }
      }
      ListView {
        id: logList
        x: 12; y: logHeading.y + logHeading.height + 12
        width: parent.width - 24
        height: parent.height - y - 10
        clip: true
        spacing: 6
        boundsBehavior: Flickable.StopAtBounds
        model: tasks.logDisplay
        currentIndex: tasks.logPane === "entries" && tasks.logEntryRows.length ? tasks.logEntryRows[Math.min(tasks.logEntry, tasks.logEntryRows.length - 1)] : -1
        onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
        delegate: Item {
          id: logItem
          required property var modelData
          required property int index
          readonly property bool picked: tasks.logPane === "entries" && logList.currentIndex === index
          width: logList.width
          height: modelData.kind === "head" ? tasks.px(28) : entryBox.height
          // a section heading (by sub-todo / todo / group / super group): click or the keys fold it
          Rectangle {
            visible: logItem.modelData.kind === "head"
            anchors.fill: parent
            anchors.leftMargin: (logItem.modelData.level || 0) * 14
            radius: tasks.rad
            color: tasks.rowColor(logItem.picked, false, secMouse.containsMouse, "transparent")
            border.color: logItem.picked ? tasks.accent : "transparent"
            border.width: 1
            MouseArea {
              id: secMouse
              anchors.fill: parent
              hoverEnabled: true
              enabled: logItem.modelData.kind === "head"
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                tasks.logPane = "entries"
                tasks.logEntry = logItem.index
                tasks.setSectionFolded(logItem.modelData.key, !logItem.modelData.collapsed)
                tasks.forceActiveFocus()
              }
            }
          }
          Row {
            id: headRow
            visible: logItem.modelData.kind === "head"
            x: 8 + (logItem.modelData.level || 0) * 14
            spacing: 8
            anchors.verticalCenter: parent.verticalCenter
            readonly property string what: logItem.modelData.what || ""
            Text { anchors.verticalCenter: parent.verticalCenter; text: logItem.modelData.collapsed ? "" : ""; color: tasks.faint; font.family: tasks.font; font.pixelSize: tasks.px(8) }
            StateBox { anchors.verticalCenter: parent.verticalCenter; visible: !!logItem.modelData.sub; state3: logItem.modelData.sub ? logItem.modelData.sub.state : "todo" }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: headRow.what === "super" || headRow.what === "todo"
              text: headRow.what === "super" ? "" : ""
              color: headRow.what === "super" ? tasks.superColor(logItem.modelData.name) : tasks.colorOf(logItem.modelData.group || "") === "transparent" ? tasks.dim : tasks.colorOf(logItem.modelData.group || "")
              font.family: tasks.font; font.pixelSize: tasks.px(11)
            }
            Dot { visible: headRow.what === "group"; dot: tasks.colorOf(logItem.modelData.group || "") }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: logList.width - 60 - headRow.x
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: logItem.modelData.kind !== "head" ? "" : logItem.modelData.label
                + (logItem.modelData.collapsed ? "   ·   " + logItem.modelData.count + (logItem.modelData.count === 1 ? " entry" : " entries") : "")
              color: logItem.picked ? tasks.accent : tasks.fg
              font.family: tasks.font; font.bold: true; font.pixelSize: tasks.px(12) }
          }
          Rectangle {
            id: entryBox
            visible: logItem.modelData.kind === "entry"
            readonly property var e: logItem.modelData.kind === "entry" ? logItem.modelData.e : ({ time: "", by: "", sub: "", text: "" })
            x: (logItem.modelData.level || 0) * 14
            width: logList.width - x
            height: entryText.implicitHeight + tasks.px(58)
            radius: tasks.rad
            color: tasks.rowColor(logItem.picked, false, entryMouse.containsMouse)
            border.color: logItem.picked ? tasks.accent : "transparent"
            border.width: 1
            Row {
              x: 12; y: 8
              spacing: 8
              Text {
                text: entryBox.e.time
                color: tasks.dim
                font.family: tasks.font; font.pixelSize: tasks.px(10); font.bold: true
              }
              Rectangle {
                visible: !!entryBox.e.by
                anchors.verticalCenter: parent.verticalCenter
                width: byText.implicitWidth + 12; height: byText.implicitHeight + 2; radius: height / 2
                color: entryBox.e.by === "you" ? tasks.tint(tasks.fg, 0.08) : tasks.tint(tasks.accent, 0.16)
                Text { id: byText; anchors.centerIn: parent; text: entryBox.e.by; color: entryBox.e.by === "you" ? tasks.dim : tasks.accent; font.family: tasks.font; font.pixelSize: tasks.px(9.5); font.bold: true }
              }
            }
            // what it's about: super group › group › todo ↳ sub-todo
            Row {
              x: 12; y: tasks.px(26)
              width: parent.width - 24
              spacing: 7
              Rectangle { width: 3; height: aboutText.implicitHeight; radius: 1.5; color: tasks.colorOf(tasks.entryGroup(entryBox.e)) === "transparent" ? tasks.line : tasks.colorOf(tasks.entryGroup(entryBox.e)) }
              Text {
                id: aboutText
                width: parent.width - 12
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: tasks.entryTag(entryBox.e)
                color: tasks.dim
                font.family: tasks.font; font.pixelSize: tasks.px(10)
              }
            }
            Text {
              id: entryText
              x: 12; y: tasks.px(46)
              width: parent.width - 24
              text: entryBox.e.text
              wrapMode: Text.Wrap
              textFormat: Text.MarkdownText
              color: tasks.fg
              linkColor: tasks.accent
              font.family: tasks.font
              font.pixelSize: tasks.px(12) }
            MouseArea {
              id: entryMouse
              anchors.fill: parent
              hoverEnabled: true
              onClicked: { tasks.logPane = "entries"; tasks.logEntry = tasks.logEntryRows.indexOf(logItem.index); tasks.forceActiveFocus() }
              onDoubleClicked: tasks.openEntry(logItem.modelData.e, false)
            }
          }
        }
        Text {
          visible: tasks.logShown.length === 0
          width: parent.width
          wrapMode: Text.Wrap
          text: "Nothing logged yet. Write in the box above, or let an agent do it:\n  taskchy log <id> \"…\" --by claude      taskchy start / finish <id> <n>"
          color: tasks.faint
          font.family: tasks.font; font.pixelSize: tasks.px(11) }
      }
    }
  }

  // ===================================================================== PROGRESS
  Item {
    id: progressTab
    visible: tasks.tab === "progress"
    y: tasks.contentTop
    width: parent.width
    height: tasks.bodyH

    Panel {
      id: progressBox
      width: parent.width
      height: parent.height - archiveBox.height - 12
      lit: tasks.progressPane === "list"
      ListView {
        id: progressList
        anchors.fill: parent
        anchors.margins: 8
        clip: true
        spacing: 4
        boundsBehavior: Flickable.StopAtBounds
        model: tasks.progressRows
        currentIndex: {
          var n = -1
          for (var i = 0; i < tasks.progressRows.length; i++) {
            if (tasks.progressRows[i].kind === "sub") continue
            n++
            if (n === tasks.progressIndex) return i
          }
          return -1
        }
        onCurrentIndexChanged: if (currentIndex >= 0 && tasks.progressPane === "list") positionViewAtIndex(currentIndex, ListView.Contain)
        delegate: Rectangle {
          id: prow
          required property var modelData
          required property int index
          readonly property int navIndex: {
            var n = 0
            for (var i = 0; i < index; i++) if (tasks.progressRows[i].kind !== "sub") n++
            return n
          }
          readonly property bool sel: modelData.kind !== "sub" && navIndex === tasks.progressIndex && tasks.progressPane === "list"
          readonly property bool armed: modelData.kind === "group" && tasks.armedGroup !== "" && tasks.armedGroup === modelData.name
            || modelData.kind === "super" && tasks.armedSuper !== "" && tasks.armedSuper === modelData.name
          readonly property real indent: (modelData.kind === "todo" ? 18 : modelData.kind === "sub" ? 44 : 0) + (modelData.depth || 0) * 16
          readonly property real value: (modelData.kind === "group" || modelData.kind === "super") ? modelData.pct : modelData.kind === "todo" ? tasks.pct(modelData.t) : 0
          // (a ListView ignores its delegates' x: shift them over instead)
          transform: Translate { x: prow.indent }
          width: progressList.width - indent
          height: modelData.kind === "sub" ? tasks.px(24) : tasks.px(36)
          radius: tasks.rad
          color: modelData.kind === "sub" ? "transparent"
            : armed ? tasks.armedFill
            : tasks.rowColor(sel, false, prowMouse.containsMouse, modelData.kind === "todo" ? tasks.rowFill : modelData.kind === "super" ? tasks.surface : "transparent")
          border.color: sel ? tasks.accent : modelData.kind === "super" ? tasks.line : "transparent"
          border.width: 1

          // super group
          Rectangle { visible: prow.modelData.kind === "super"; x: tasks.barX; y: 8; width: 3; height: parent.height - 16; radius: 1.5; color: tasks.superColor(prow.modelData.name) }
          Row {
            visible: prow.modelData.kind === "super"
            x: tasks.barX + 11; anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            Text { text: prow.modelData.collapsed ? "" : ""; color: tasks.faint; font.family: tasks.font; font.pixelSize: tasks.px(8); anchors.verticalCenter: parent.verticalCenter }
            Text { text: ""; color: tasks.superColor(prow.modelData.name); font.family: tasks.font; font.pixelSize: tasks.px(12); anchors.verticalCenter: parent.verticalCenter }
            Text { text: prow.modelData.kind === "super" ? prow.modelData.name : ""; color: prow.sel ? tasks.accent : tasks.fg; font.family: tasks.font; font.bold: true; font.pixelSize: tasks.px(13); anchors.verticalCenter: parent.verticalCenter }
            Text { text: prow.modelData.kind !== "super" ? "" : prow.modelData.count + (prow.modelData.count === 1 ? " todo" : " todos"); color: tasks.faint; font.family: tasks.font; font.pixelSize: tasks.px(10.5); anchors.verticalCenter: parent.verticalCenter }
          }
          // group
          Row {
            visible: prow.modelData.kind === "group"
            x: 10; anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            Text { text: tasks.groupCollapsed(prow.modelData.name, "progress") ? "" : ""; color: tasks.faint; font.family: tasks.font; font.pixelSize: tasks.px(8); anchors.verticalCenter: parent.verticalCenter }
            Dot { visible: prow.modelData.name !== ""; dot: tasks.colorOf(prow.modelData.name) }
            Text { text: !prow.modelData.name ? "NO GROUP" : prow.modelData.name.toUpperCase(); color: prow.sel ? tasks.accent : tasks.dim; font.family: tasks.font; font.bold: true; font.letterSpacing: 1.1; font.pixelSize: tasks.px(11); anchors.verticalCenter: parent.verticalCenter }
            Text { text: prow.modelData.kind !== "group" ? "" : prow.modelData.count + (prow.modelData.count === 1 ? " todo" : " todos"); color: tasks.faint; font.family: tasks.font; font.pixelSize: tasks.px(10.5); anchors.verticalCenter: parent.verticalCenter }
          }
          // todo
          Row {
            visible: prow.modelData.kind === "todo"
            x: tasks.barX; anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            Rectangle { width: 3; height: tasks.px(18); radius: 1.5; color: prow.modelData.kind === "todo" ? tasks.colorOf(prow.modelData.t.group) : "transparent"; anchors.verticalCenter: parent.verticalCenter }
            Text { text: prow.modelData.kind === "todo" && prow.modelData.t.subs.length ? (tasks.expanded["t:" + prow.modelData.t.id] ? "" : "") : " "; color: tasks.faint; font.family: tasks.font; font.pixelSize: tasks.px(8); anchors.verticalCenter: parent.verticalCenter }
            Text {
              width: prow.width * 0.42
              elide: Text.ElideRight
              text: prow.modelData.kind === "todo" ? prow.modelData.t.title : ""
              color: prow.sel ? tasks.accent : tasks.fg; font.family: tasks.font; font.pixelSize: tasks.px(12)
              anchors.verticalCenter: parent.verticalCenter
            }
          }
          // sub
          Row {
            visible: prow.modelData.kind === "sub"
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            StateBox { state3: prow.modelData.kind === "sub" ? prow.modelData.s.state : "todo"; anchors.verticalCenter: parent.verticalCenter; scale: 0.85 }
            Text {
              text: prow.modelData.kind === "sub" ? prow.modelData.s.text : ""
              color: tasks.fg; font.family: tasks.font; font.pixelSize: tasks.px(11)
              opacity: prow.modelData.kind === "sub" && prow.modelData.s.state === "done" ? 0.5 : 1
              anchors.verticalCenter: parent.verticalCenter
            }
          }
          // progress bar and percentage (super groups, groups and todos)
          Meter {
            visible: prow.modelData.kind !== "sub"
            anchors.right: pctText.left; anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width * 0.3
            value: prow.value
            fill: prow.modelData.kind === "group" && prow.modelData.name !== "" ? tasks.colorOf(prow.modelData.name)
              : prow.modelData.kind === "super" ? tasks.superColor(prow.modelData.name)
              : prow.modelData.kind === "todo" && prow.modelData.t.group ? tasks.colorOf(prow.modelData.t.group) : tasks.accent
          }
          Text {
            id: pctText
            visible: prow.modelData.kind !== "sub"
            anchors.right: archiveBtn.visible ? archiveBtn.left : parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            width: tasks.px(38)
            horizontalAlignment: Text.AlignRight
            text: Math.round(100 * prow.value) + "%"
            color: prow.value >= 1 ? tasks.accent : tasks.fg; font.family: tasks.font; font.pixelSize: tasks.px(11.5); font.bold: true
          }
          Btn {
            id: archiveBtn
            visible: prow.modelData.kind === "todo" && tasks.pct(prow.modelData.t) >= 1
            anchors.right: parent.right; anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            icon: ""; text: "archive"; size: 9.5
            onClicked: tasks.act(["archive", prow.modelData.t.id])
          }
          MouseArea {
            id: prowMouse
            anchors.fill: parent
            anchors.rightMargin: archiveBtn.visible ? archiveBtn.width + 10 : 0
            hoverEnabled: true
            enabled: prow.modelData.kind !== "sub"
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: mouse => {
              tasks.progressPane = "list"
              tasks.progressIndex = prow.navIndex
              tasks.forceActiveFocus()
              var p = mapToItem(tasks, mouse.x, mouse.y)
              if (mouse.button !== Qt.RightButton) tasks.toggleExpand(prow.modelData)
              else if (prow.modelData.kind === "group") tasks.openGroupMenu(prow.modelData.name, p.x, p.y)
              else if (prow.modelData.kind === "super") tasks.openSuperMenu(prow.modelData.name, p.x, p.y)
              else if (prow.modelData.kind === "todo") tasks.openMenu(prow.modelData.t, p.x, p.y)
            }
          }
        }
      }
    }

    // the archive: search it, bring lists back
    Panel {
      id: archiveBox
      y: parent.height - height
      width: parent.width
      height: Math.round(parent.height * 0.32)
      lit: tasks.progressPane === "archive"
      Row {
        id: archiveHead
        x: 12; y: 10
        spacing: 12
        Heading { text: "Archive (" + tasks.archivedTodos.length + ")"; anchors.verticalCenter: parent.verticalCenter; strong: tasks.progressPane === "archive" }
        Field {
          id: archiveField
          width: Math.min(320, archiveBox.width * 0.4)
          icon: ""
          placeholder: "search the archive…  (/)"
          clearOnEnter: false
          onEntered: if (tasks.archiveRows.length) {
            tasks.progressPane = "archive"
            var first = 0
            while (first < tasks.archiveRows.length - 1 && tasks.archiveRows[first].kind !== "todo") first++
            tasks.archiveIndex = first
          }
          input.onTextChanged: tasks.archiveQuery = input.text
          Component.onCompleted: archiveInput = archiveField.input
        }
      }
      ListView {
        id: archiveList
        x: 10; y: archiveHead.y + archiveHead.height + 8
        width: parent.width - 20
        height: parent.height - y - 8
        clip: true
        spacing: 3
        model: tasks.archiveRows
        currentIndex: tasks.progressPane === "archive" ? tasks.archiveIndex : -1
        onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
        delegate: Item {
          id: arow
          required property var modelData
          required property int index
          readonly property bool here: tasks.progressPane === "archive" && index === tasks.archiveIndex
          width: ListView.view.width
          height: modelData.kind === "shead" ? tasks.px(30) : tasks.px(28)
          // a super group's heading: click folds it; restore all of it from here
          SuperHead {
            visible: arow.modelData.kind === "shead"
            anchors.fill: parent
            name: arow.modelData.kind === "shead" ? arow.modelData.name : ""
            collapsed: !!arow.modelData.collapsed
            count: arow.modelData.count || 0
            here: arow.modelData.kind === "shead" && arow.here
            onToggle: { tasks.progressPane = "archive"; tasks.archiveIndex = arow.index; tasks.setSuperCollapsed(name, !collapsed, "archive"); tasks.forceActiveFocus() }
            onMenu: (x, y) => { tasks.progressPane = "archive"; tasks.archiveIndex = arow.index; tasks.openSuperMenu(name, x, y) }
            Btn {
              anchors.right: parent.right; anchors.rightMargin: 4
              anchors.verticalCenter: parent.verticalCenter
              icon: ""; text: "restore all  (r)"; size: 9.5
              onClicked: tasks.restoreSuper(arow.modelData.name)
            }
          }
          GroupHead {
            visible: arow.modelData.kind === "head"
            anchors.fill: parent
            name: arow.modelData.kind === "head" ? arow.modelData.name : ""
            collapsed: !!arow.modelData.collapsed
            count: arow.modelData.count || 0
            depth: arow.modelData.depth || 0
            here: arow.modelData.kind === "head" && arow.here
            onToggle: { tasks.progressPane = "archive"; tasks.archiveIndex = arow.index; tasks.setGroupCollapsed(name, !collapsed, "archive"); tasks.forceActiveFocus() }
            onMenu: (x, y) => { tasks.progressPane = "archive"; tasks.archiveIndex = arow.index; tasks.forceActiveFocus(); tasks.openGroupMenu(name, x, y) }
            Btn {
              anchors.right: parent.right; anchors.rightMargin: 4
              anchors.verticalCenter: parent.verticalCenter
              icon: ""; text: "restore all  (r)"; size: 9.5
              onClicked: tasks.restoreGroup(arow.modelData.name)
            }
          }
          Rectangle {
            id: archCard
            visible: arow.modelData.kind === "todo"
            anchors.fill: parent
            anchors.leftMargin: (arow.modelData.depth || 0) * 14
            readonly property var t: arow.modelData.kind === "todo" ? arow.modelData.t : ({ id: "", title: "", group: "", counts: { done: 0 }, subs: [] })
            radius: tasks.rad
            color: tasks.rowColor(arow.here, false, archMouse.containsMouse, "transparent")
            border.color: arow.here ? tasks.accent : "transparent"
            border.width: 1
            Rectangle { x: tasks.barX; width: 3; height: parent.height - 12; radius: 1.5; anchors.verticalCenter: parent.verticalCenter; color: tasks.colorOf(archCard.t.group) }
            Text {
              x: 20; width: parent.width - restoreBtn.width - 30
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
              text: archCard.t.title + "  ·  " + archCard.t.counts.done + "/" + archCard.t.subs.length
              color: arow.here ? tasks.accent : tasks.fg; font.family: tasks.font; font.pixelSize: tasks.px(11.5) }
            MouseArea {
              id: archMouse
              anchors.fill: parent
              anchors.rightMargin: restoreBtn.width + 8
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              onClicked: mouse => {
                tasks.progressPane = "archive"
                tasks.archiveIndex = arow.index
                tasks.forceActiveFocus()
                if (mouse.button === Qt.RightButton) {
                  var p = mapToItem(tasks, mouse.x, mouse.y)
                  tasks.openMenu(archCard.t, p.x, p.y, true)
                }
              }
            }
            Btn {
              id: restoreBtn
              anchors.right: parent.right; anchors.rightMargin: 4
              anchors.verticalCenter: parent.verticalCenter
              icon: ""; text: "restore"; size: 9.5
              onClicked: tasks.restoreArchived(archCard.t)
            }
          }
        }
        Text {
          visible: tasks.archiveRows.length === 0
          width: parent.width
          text: tasks.archiveQuery !== "" ? "Nothing in the archive matches “" + tasks.archiveQuery + "”." : "Nothing archived yet — A archives a todo (or a whole group from its heading)."
          color: tasks.faint; font.family: tasks.font; font.pixelSize: tasks.px(11)
        }
      }
    }
  }
  property var archiveInput: null

  // ============================================================ right-click / g menu
  Rectangle {
    id: menu
    property var todo: null
    property int index: 0
    property bool archived: false          // opened on an archived todo
    property string headGroup: ""          // opened on a group heading
    property string headSuper: ""          // opened on a super group heading
    property string armed: ""              // group waiting for the second d
    readonly property var groupNames: tasks.allGroupNames()
    // items: each group, "no group", then actions (on a heading: group actions)
    readonly property var items: headSuper !== ""
      ? [{ kind: "archiveSuper", name: headSuper }, { kind: "renameSuper", name: headSuper }, { kind: "deleteSuper", name: headSuper }]
      : headGroup !== ""
      ? [{ kind: "archiveGroup", name: headGroup }, { kind: "renameGroup", name: headGroup }, { kind: "deleteGroup", name: headGroup }]
        .concat(Object.keys(tasks.supersMap).sort().map(function(sp) { return { kind: "intoSuper", name: sp } }))
        .concat(tasks.superOf(headGroup) ? [{ kind: "outOfSuper", name: tasks.superOf(headGroup) }] : [])
      : groupNames.map(function(g) { return { kind: "group", name: g } })
        .concat([{ kind: "group", name: "" }])
        .concat(archived ? [{ kind: "restore" }, { kind: "delete" }]
          : [{ kind: "rename" }, { kind: "archive" }]
            .concat(todo && todo.group ? [{ kind: "archiveGroup", name: todo.group }] : [])
            .concat([{ kind: "delete" }]))
    function deleteGroup(name) {
      if (!name) return
      if (armed !== name) { armed = name; return }      // d d, like deleting a todo
      armed = ""
      tasks.act(["group-delete", name])
      visible = false
      tasks.forceActiveFocus()
    }
    readonly property var arch: archived ? ["--archived"] : []
    visible: false
    z: 50
    width: tasks.px(260)
    height: menuCol.implicitHeight + 20
    radius: tasks.rad
    color: tasks.solid
    border.color: Color.menu.border
    border.width: 1
    function run(it) {
      if (it.kind === "archiveGroup") { tasks.archiveGroup(it.name); visible = false; tasks.forceActiveFocus(); return }
      if (it.kind === "renameGroup") { visible = false; tasks.startRenameGroup(it.name); return }
      if (it.kind === "intoSuper") { tasks.act(["super-set", headGroup, it.name]); visible = false; tasks.forceActiveFocus(); return }
      if (it.kind === "outOfSuper") { tasks.act(["super-set", headGroup, ""]); visible = false; tasks.forceActiveFocus(); return }
      if (it.kind === "renameSuper") { visible = false; tasks.startRenameSuper(it.name); return }
      if (it.kind === "archiveSuper") { tasks.archiveSuper(it.name); visible = false; tasks.forceActiveFocus(); return }
      if (it.kind === "deleteSuper") {
        if (armed !== "s:" + it.name) { armed = "s:" + it.name; return }
        armed = ""
        tasks.act(["super-delete", it.name]); visible = false; tasks.forceActiveFocus(); return
      }
      if (it.kind === "deleteGroup") { deleteGroup(it.name); return }
      if (!todo) return
      if (it.kind === "group") tasks.act(["group", todo.id, it.name].concat(arch))
      else if (it.kind === "restore") tasks.restoreArchived(todo)
      else if (it.kind === "rename") { renameInput.text = todo.title; tasks.selectedId = todo.id; tasks.tab = "todo"; visible = false; renameInput.forceActiveFocus(); return }
      else if (it.kind === "archive") tasks.act(["archive", todo.id])
      else if (it.kind === "delete") {
        if (armed !== "t:" + todo.id) { armed = "t:" + todo.id; return }
        armed = ""
        tasks.act(["delete", todo.id].concat(arch))
      }
      visible = false
      tasks.forceActiveFocus()
    }
    Keys.onPressed: event => {
      if (event.key === Qt.Key_Escape) { visible = false; tasks.forceActiveFocus() }
      else if (event.key === Qt.Key_Up || event.text === "k") index = Math.max(0, index - 1)
      else if (event.key === Qt.Key_Down || event.text === "j") index = Math.min(items.length - 1, index + 1)
      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) run(items[index])
      // d d on a group (or on a heading's menu) deletes the group
      else if ((event.text === "d" || event.key === Qt.Key_Delete) && items[index] && (items[index].kind === "group" || items[index].kind === "deleteGroup") && items[index].name)
        deleteGroup(items[index].name)
      else if ((event.text === "d" || event.key === Qt.Key_Delete) && headSuper !== "") run({ kind: "deleteSuper", name: headSuper })
      else if ((event.text === "e" || event.key === Qt.Key_F2) && headSuper !== "") run({ kind: "renameSuper", name: headSuper })
      else if ((event.text === "e" || event.key === Qt.Key_F2) && headGroup !== "") run({ kind: "renameGroup", name: headGroup })
      else if (event.text === "A" && headGroup !== "") { tasks.archiveGroup(headGroup); visible = false; tasks.forceActiveFocus() }
      else if (event.text === "n" && headSuper === "") groupInput.forceActiveFocus()
      else return
      event.accepted = true
    }
    Column {
      id: menuCol
      x: 10; y: 10
      width: parent.width - 20
      spacing: 2
      Heading {
        text: menu.headSuper !== "" ? "Super group · " + menu.headSuper
          : menu.headGroup !== "" ? "Group · " + menu.headGroup
          : menu.todo ? "Move to group" : "Group"
        bottomPadding: 4
      }
      Repeater {
        model: menu.items
        Rectangle {
          id: mi
          required property var modelData
          required property int index
          readonly property bool armedHere: menu.armed !== "" && ((modelData.kind === "group" || modelData.kind === "deleteGroup") && modelData.name === menu.armed
                                                            || modelData.kind === "deleteSuper" && "s:" + modelData.name === menu.armed
                                                            || modelData.kind === "delete" && menu.todo && "t:" + menu.todo.id === menu.armed)
          // a line between the groups and the actions
          readonly property bool firstAction: modelData.kind !== "group" && index > 0 && menu.items[index - 1].kind === "group"
          width: menuCol.width
          height: tasks.px(26) + (firstAction ? 7 : 0)
          color: "transparent"
          Rectangle { visible: mi.firstAction; y: 2; width: parent.width; height: 1; color: tasks.line }
          Rectangle {
            y: mi.firstAction ? 7 : 0
            width: parent.width; height: tasks.px(26)
            radius: Math.max(4, tasks.rad - 2)
            color: mi.armedHere ? tasks.armedFill : mi.index === menu.index ? Color.menu.selectedBackground : miMouse.containsMouse ? tasks.hoverFill : "transparent"
            Row {
              x: 8; anchors.verticalCenter: parent.verticalCenter
              spacing: 8
              Dot { visible: mi.modelData.kind === "group" && mi.modelData.name !== ""; dot: tasks.colorOf(mi.modelData.name) }
              Text {
                text: {
                  var it = mi.modelData
                  if (mi.armedHere) return "  d again: delete " + (it.kind === "deleteSuper" ? "super group " + it.name : it.kind === "delete" ? "this todo" : "group " + it.name)
                  if (it.kind === "intoSuper") return "  into super group " + it.name + (tasks.superOf(menu.headGroup) === it.name ? "  " : "")
                  if (it.kind === "outOfSuper") return "  out of super group " + it.name
                  if (it.kind === "renameSuper") return "  rename super group  (e)"
                  if (it.kind === "archiveSuper") return "  archive it all  (A)"
                  if (it.kind === "deleteSuper") return "  delete super group  (d d)"
                  if (it.kind === "archiveGroup") return "  archive the whole group" + (menu.headGroup !== "" ? "  (A)" : "")
                  if (it.kind === "renameGroup") return "  rename group  (e)"
                  if (it.kind === "deleteGroup") return "  delete group  (d d)"
                  if (it.kind === "group") return (it.name === "" ? "no group" : it.name) + (menu.todo && (menu.todo.group || "") === it.name ? "   " : "")
                  return it.kind === "rename" ? "  rename" : it.kind === "archive" ? "  archive"
                    : it.kind === "restore" ? "  restore" : "  delete  (twice)"
                }
                color: mi.index === menu.index ? Color.menu.selectedText : tasks.fg
                font.family: tasks.font; font.pixelSize: tasks.px(11.5) }
            }
            MouseArea { id: miMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { menu.index = mi.index; menu.run(mi.modelData) } }
          }
        }
      }
      Text {
        visible: menu.headGroup === "" && !menu.archived
        width: menuCol.width
        topPadding: 4
        wrapMode: Text.Wrap
        text: menu.headSuper !== "" ? "deleting a super group keeps its groups" : "d d on a group deletes it (its todos just lose the group)"
        color: tasks.faint
        font.family: tasks.font; font.pixelSize: tasks.px(9.5) }
      Item { width: 1; height: 4 }
      Field {
        visible: menu.headSuper === ""
        width: menuCol.width
        placeholder: menu.headGroup !== "" ? "new super group for it…  (n)" : "new group…  (n)"
        onAccepted: t => {
          if (menu.headGroup !== "") tasks.act(["super-set", menu.headGroup, t])
          else if (menu.todo) tasks.act(["group", menu.todo.id, t].concat(menu.arch))
          menu.visible = false; tasks.forceActiveFocus()
        }
        Component.onCompleted: groupInput = input
      }
    }
  }
  property var groupInput: null
  // click away closes the menu
  MouseArea {
    anchors.fill: parent
    z: 49
    visible: menu.visible
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: { menu.visible = false; tasks.forceActiveFocus() }
  }

  // ============================================================ one entry, over everything
  // A log entry or a sub-todo, for reading (and copying / editing / pictures).
  Rectangle {
    id: viewer
    visible: tasks.viewEntry !== null
    z: 58
    anchors.fill: parent
    radius: tasks.rad
    color: tasks.solid
    border.color: tasks.line
    border.width: 1
    MouseArea { anchors.fill: parent }       // nothing underneath takes clicks
    readonly property var e: tasks.viewEntry || ({ time: "", by: "", sub: "", text: "" })

    // header: when, who, what it's about, and the buttons
    Column {
      id: viewHead
      x: 22; y: 18
      width: parent.width - 44
      spacing: 10
      Row {
        width: parent.width
        spacing: 8
        Row {
          width: parent.width - viewButtons.width - 8
          anchors.verticalCenter: parent.verticalCenter
          spacing: 10
          Heading { text: viewer.e.isSub ? "Sub-todo" : "Log entry"; anchors.verticalCenter: parent.verticalCenter; strong: true }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: viewer.e.isSub ? viewer.e.where : viewer.e.time + (viewer.e.by ? "  ·  " + viewer.e.by : "")
            color: tasks.dim
            font.family: tasks.font; font.pixelSize: tasks.px(11)
          }
        }
        Row {
          id: viewButtons
          spacing: 6
          anchors.verticalCenter: parent.verticalCenter
          Btn { icon: ""; text: tasks.copiedNote !== "" ? "copied!" : "copy  c"; size: 10.5; on: tasks.copiedNote !== ""; onClicked: tasks.copyEntry(tasks.viewEntry) }
          Btn { visible: !tasks.viewEditing; icon: ""; text: "edit  e"; size: 10.5; onClicked: tasks.startEdit() }
          Btn { visible: !tasks.viewEditing && !!viewer.e.isSub; icon: ""; text: "add picture  p"; size: 10.5; onClicked: tasks.openPicker(tasks.selected, viewer.e.n) }
          Btn { visible: tasks.viewEditing; icon: ""; text: "save  Ctrl+S"; size: 10.5; on: true; onClicked: tasks.saveEdit() }
          Btn { visible: tasks.viewEditing; icon: ""; text: "cancel  Esc"; size: 10.5; onClicked: { tasks.viewEditing = false; tasks.forceActiveFocus() } }
          Btn { visible: !tasks.viewEditing; icon: ""; text: "close  Esc"; size: 10.5; onClicked: tasks.closeEntry() }
        }
      }
      Row {
        width: parent.width
        spacing: 8
        Rectangle { width: 3; height: viewAbout.implicitHeight; radius: 1.5; color: tasks.colorOf(tasks.entryGroup(viewer.e)) === "transparent" ? tasks.accent : tasks.colorOf(tasks.entryGroup(viewer.e)) }
        Text {
          id: viewAbout
          width: parent.width - 12
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: viewer.e.isSub ? (tasks.selected ? tasks.entryTag({ id: tasks.selected.id, title: tasks.selected.title, group: tasks.selected.group, sub: "" }) : "") : tasks.entryTag(viewer.e)
          color: tasks.dim
          font.family: tasks.font; font.pixelSize: tasks.px(11)
        }
      }
      Rectangle { width: parent.width; height: 1; color: tasks.line }
    }

    // reading
    Flickable {
      id: viewFlick
      visible: !tasks.viewEditing
      x: 22; y: viewHead.y + viewHead.height + 14
      width: parent.width - 44
      height: parent.height - y - 20
      clip: true
      contentHeight: viewCol.implicitHeight
      boundsBehavior: Flickable.StopAtBounds
      Column {
        id: viewCol
        width: viewFlick.width
        spacing: 18
        Text {
          id: viewText
          width: viewFlick.width
          text: viewer.e.text
          wrapMode: Text.Wrap
          textFormat: Text.MarkdownText
          color: tasks.fg
          linkColor: tasks.accent
          font.family: tasks.font
          font.pixelSize: tasks.px(15)
          lineHeight: 1.25
        }
        // a sub-todo's pictures
        Heading {
          visible: !!viewer.e.isSub
          text: tasks.viewPics.length ? "Pictures (" + tasks.viewPics.length + ")" : "No pictures yet — p adds one, or drop image files here"
        }
        Flow {
          visible: tasks.viewPics.length > 0
          width: parent.width
          spacing: 12
          Repeater {
            model: tasks.viewPics
            Item {
              id: pin
              required property var modelData
              required property int index
              readonly property bool picked: tasks.picIndex === index
              readonly property bool armed: tasks.armedPic === index
              width: Math.min(viewCol.width, tasks.px(220))
              height: frame.height + tasks.px(22)
              Rectangle {
                id: frame
                width: parent.width
                height: Math.max(80, Math.min(200, big.implicitHeight > 0 ? (width - 12) * big.implicitHeight / Math.max(1, big.implicitWidth) + 12 : 150))
                radius: tasks.rad
                color: tasks.rowFill
                border.color: pin.armed ? tasks.urgent : pin.picked ? tasks.accent : tasks.line
                border.width: pin.picked || pin.armed ? 2 : 1
                Image {
                  id: big
                  anchors.fill: parent; anchors.margins: 6
                  source: "file://" + pin.modelData.file
                  sourceSize.width: 440
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                  onClicked: { tasks.picIndex = pin.index; tasks.zoomPic = pin.modelData.file } }
                // remove (d d, or this)
                Rectangle {
                  anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 5
                  width: tasks.px(22); height: width; radius: width / 2
                  visible: pin.picked || pinHover.hovered
                  color: pin.armed ? tasks.urgent : tasks.bg
                  border.color: pin.armed ? tasks.urgent : tasks.line; border.width: 1
                  Text { anchors.centerIn: parent; text: ""; color: pin.armed ? tasks.bg : tasks.fg; font.family: tasks.font; font.pixelSize: tasks.px(10) }
                  MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { tasks.picIndex = pin.index; if (tasks.armedPic !== pin.index) { tasks.armedPic = pin.index; disarmPic.restart() } else tasks.removePicture(viewer.e.n, pin.index) } }
                }
              }
              HoverHandler { id: pinHover }
              Text {
                y: frame.height + 4
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideMiddle
                text: pin.armed ? "d again: remove it" : pin.modelData.name
                color: pin.armed ? tasks.urgent : tasks.dim
                font.family: tasks.font; font.pixelSize: tasks.px(10.5)
              }
            }
          }
        }
      }
    }
    // drop image files onto a sub-todo to pin them to it
    DropArea {
      anchors.fill: parent
      enabled: !!viewer.e.isSub && !tasks.viewEditing
      keys: ["text/uri-list"]
      onDropped: drop => {
        if (!drop.hasUrls) return
        for (var i = 0; i < drop.urls.length; i++) tasks.addPicture(tasks.selected, viewer.e.n, decodeURIComponent(String(drop.urls[i]).replace(/^file:\/\//, "")))
        drop.acceptProposedAction()
      }
      Rectangle {
        anchors.fill: parent; anchors.margins: 14
        visible: parent.containsDrag
        radius: tasks.rad
        color: tasks.tint(tasks.accent, 0.08)
        border.color: tasks.accent; border.width: 2
        Text { anchors.centerIn: parent; text: "  drop to add it to this sub-todo"; color: tasks.accent; font.family: tasks.font; font.pixelSize: tasks.px(18) }
      }
    }

    // editing: the raw markdown
    Rectangle {
      visible: tasks.viewEditing
      x: 18; y: viewHead.y + viewHead.height + 10
      width: parent.width - 36
      height: parent.height - y - 18
      radius: tasks.rad
      color: tasks.tint(tasks.fg, 0.05)
      border.color: tasks.accent
      border.width: 1
      Flickable {
        id: editFlick
        anchors.fill: parent
        anchors.margins: 12
        clip: true
        contentHeight: viewEditor.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        TextEdit {
          id: viewEditor
          width: editFlick.width
          wrapMode: TextEdit.Wrap
          textFormat: TextEdit.PlainText
          selectByMouse: true
          color: tasks.fg
          selectionColor: tasks.tint(tasks.accent, 0.4)
          font.family: tasks.font
          font.pixelSize: tasks.px(13)
          onCursorRectangleChanged: {
            if (cursorRectangle.y < editFlick.contentY) editFlick.contentY = cursorRectangle.y
            else if (cursorRectangle.y + cursorRectangle.height > editFlick.contentY + editFlick.height)
              editFlick.contentY = cursorRectangle.y + cursorRectangle.height - editFlick.height
          }
          Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) { tasks.viewEditing = false; tasks.forceActiveFocus(); event.accepted = true }
            else if ((event.key === Qt.Key_S || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
              tasks.saveEdit(); event.accepted = true
            }
          }
        }
      }
    }
  }

  // ============================================================ rename a group
  Rectangle {
    anchors.fill: parent
    z: 56
    visible: tasks.renamingGroup !== ""
    color: tasks.tint(tasks.bg, 0.5)
    radius: tasks.rad
    MouseArea { anchors.fill: parent; onClicked: { tasks.renamingGroup = ""; tasks.renamingIsSuper = false; tasks.forceActiveFocus() } }
  }
  Rectangle {
    visible: tasks.renamingGroup !== ""
    z: 57
    anchors.centerIn: parent
    width: tasks.px(380)
    height: renameCol.implicitHeight + 28
    radius: tasks.rad
    color: tasks.solid
    border.color: Color.menu.border
    border.width: 1
    Column {
      id: renameCol
      x: 14; y: 14
      width: parent.width - 28
      spacing: 10
      Heading { text: (tasks.renamingIsSuper ? "Rename super group · " : "Rename group · ") + tasks.renamingGroup }
      Rectangle {
        width: parent.width
        height: tasks.px(32)
        radius: tasks.rad
        color: tasks.tint(tasks.fg, 0.07)
        border.color: tasks.accent
        border.width: 1
        TextInput {
          id: renameGroupInput
          x: 11
          width: parent.width - 22
          anchors.verticalCenter: parent.verticalCenter
          color: tasks.fg
          selectionColor: tasks.tint(tasks.accent, 0.4)
          font.family: tasks.font
          font.pixelSize: tasks.px(12.5)
          clip: true
          Keys.onReturnPressed: tasks.finishRenameGroup(text.trim())
          Keys.onEnterPressed: tasks.finishRenameGroup(text.trim())
          Keys.onEscapePressed: { tasks.renamingGroup = ""; tasks.renamingIsSuper = false; tasks.forceActiveFocus() }
        }
      }
      Text { text: "Enter renames · Esc cancels"; color: tasks.faint; font.family: tasks.font; font.pixelSize: tasks.px(10) }
    }
  }

  // ================================================================ settings
  MouseArea {
    anchors.fill: parent
    z: 54
    visible: tasks.showSettings
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: { tasks.showSettings = false; tasks.forceActiveFocus() }
  }
  Rectangle {
    id: settingsPop
    visible: tasks.showSettings
    z: 55
    anchors.right: parent.right
    y: tasks.headerH + 2
    width: tasks.px(330)
    height: settingsCol.implicitHeight + 24
    radius: tasks.rad
    color: tasks.solid
    border.color: Color.menu.border
    border.width: 1
    MouseArea { anchors.fill: parent }
    Column {
      id: settingsCol
      x: 12; y: 12
      width: parent.width - 24
      spacing: 4
      Repeater {
        model: tasks.settingsItems
        Column {
          id: opt
          required property var modelData
          required property int index
          readonly property bool chosen: tasks.settingValue(modelData.key) === modelData.value
          readonly property bool here: tasks.settingsIndex === index
          width: settingsCol.width
          spacing: 4
          Heading { visible: !!opt.modelData.section; text: opt.modelData.section || ""; topPadding: opt.index > 0 ? 8 : 0; bottomPadding: 2 }
          Rectangle {
            width: parent.width
            height: optCol.implicitHeight + 14
            radius: Math.max(4, tasks.rad - 2)
            color: tasks.rowColor(opt.here, false, optMouse.containsMouse, "transparent")
            border.color: opt.here ? tasks.accent : "transparent"
            border.width: 1
            Rectangle {
              id: radio
              x: 10; anchors.verticalCenter: parent.verticalCenter
              width: tasks.px(14); height: width; radius: width / 2
              color: "transparent"
              border.color: opt.chosen ? tasks.accent : tasks.tint(tasks.fg, 0.45); border.width: 1.5
              Rectangle { anchors.centerIn: parent; visible: opt.chosen; width: parent.width - 6; height: width; radius: width / 2; color: tasks.accent }
            }
            Column {
              id: optCol
              x: radio.x + radio.width + 10
              width: parent.width - x - 10
              anchors.verticalCenter: parent.verticalCenter
              spacing: 2
              Text { text: opt.modelData.label; color: opt.chosen ? tasks.accent : tasks.fg; font.family: tasks.font; font.pixelSize: tasks.px(12); font.bold: opt.chosen }
              Text { text: opt.modelData.detail; color: tasks.faint; font.family: tasks.font; font.pixelSize: tasks.px(10) }
            }
            MouseArea {
              id: optMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: { tasks.settingsIndex = opt.index; tasks.applySetting(opt.modelData); tasks.forceActiveFocus() }
            }
          }
        }
      }
      Text {
        width: parent.width
        topPadding: 6
        wrapMode: Text.Wrap
        text: "↑↓ pick · Enter choose · Esc close"
        color: tasks.faint; font.family: tasks.font; font.pixelSize: tasks.px(10)
      }
    }
  }

  // ================================================================ keys help
  Rectangle {
    anchors.fill: parent
    z: 59
    visible: tasks.showHelp
    color: tasks.tint(tasks.bg, 0.6)
    radius: tasks.rad
    MouseArea { anchors.fill: parent; onClicked: tasks.showHelp = false }
  }
  // one section at a time (the tab you're on first): chips or ← → switch
  property int helpSection: 0
  readonly property var helpSections: [
    ["Everywhere", [["Tab  1 2 3", "switch tabs"], ["?", "this help"], [",", "settings"], ["Esc", "back out, or close Taskchy"], ["Shift ↑↓", "move the highlighted todo, sub-todo, group or log section"]]],
    ["Todo · list", [["↑ ↓  j k", "pick a todo"], ["→  Enter", "open its sub-todos"], ["n", "new todo"], ["a", "add a sub-todo"],
                     ["Space", "mark finished"], ["e  F2", "rename"], ["g  right-click", "group menu"], ["A", "archive"], ["d d", "delete"], ["f", "show / hide finished"],
                     ["J K  Shift ↑↓  drag", "move a todo (drag: into another group, too)"], ["←  z", "fold its group"], ["L", "jump to its log"]]],
    ["Group & super group headings", [["Enter  Space  →  ←  click", "fold / unfold"], ["e", "rename"], ["d d", "delete (todos / groups are kept)"], ["A", "archive everything in it"],
                                      ["g  right-click", "menu: archive, rename, delete, into / out of a super group"], ["n  in the g menu", "new group / new super group"]]],
    ["Todo · sub-todos", [["↑ ↓", "pick"], ["Space", "to do → in progress → done"], ["Enter", "open it (c copy · e edit)"], ["p", "add a picture"], ["i", "fold its pictures"], ["a", "add"], ["e", "edit"],
                          ["d", "delete"], ["J K  Shift ↑↓  drag", "move"], ["←  Esc", "back to the list"]]],
    ["Task Log", [["↑ ↓", "pick a todo"], ["→  Enter", "into its lanes, then ↓ on into the log"], ["→  Space  /  ←", "move a sub-todo a lane on / back"], ["Tab  Shift+Tab", "hop lanes"],
                  ["Enter", "open a sub-todo or entry"], ["c  e", "copy / edit an entry"], ["s  S", "log view: newest first · by sub-todo · all by todo · by group · by super group"],
                  ["←  z  /  →  Enter", "fold / unfold a section"], ["L", "jump to the highlighted thing's section of the log"], ["w", "write in the log (about the picked sub-todo)"], ["PgUp PgDn", "scroll the log"],
                  ["click / right-click a lane item", "move it on / back"]]],
    ["Progress", [["↑ ↓", "pick"], ["Enter  Space", "expand / collapse"], ["→  ←", "open / close a todo, then fold its group"], ["A", "archive"], ["↓ past the end", "into the archive"],
                  ["/", "search the archive"], ["Enter  r", "restore (you stay in the archive)"], ["r  on a heading", "restore the whole group / super group"], ["g  right-click", "group, restore or delete an archived list"], ["↑ at the top  Esc", "back up"]]]
          ]
  onShowHelpChanged: if (showHelp) { helpSection = tab === "log" ? 4 : tab === "progress" ? 5 : 1; helpFlick.contentY = 0 }
  Rectangle {
    visible: tasks.showHelp
    z: 60
    anchors.centerIn: parent
    width: Math.min(parent.width - 40, tasks.px(720))
    height: Math.min(parent.height - 40, helpHead.height + helpFlick.contentHeight + helpFoot.implicitHeight + 46)
    radius: tasks.rad
    color: tasks.solid
    border.color: Color.menu.border
    border.width: 1
    MouseArea { anchors.fill: parent; onClicked: tasks.showHelp = false }
    Flow {
      id: helpHead
      x: 16; y: 14
      width: parent.width - 32
      spacing: 6
      Repeater {
        model: tasks.helpSections
        Btn {
          required property var modelData
          required property int index
          text: modelData[0]
          size: 10
          on: tasks.helpSection === index
          onClicked: { tasks.helpSection = index; helpFlick.contentY = 0 }
        }
      }
    }
    Flickable {
      id: helpFlick
      x: 16; y: helpHead.y + helpHead.height + 12
      width: parent.width - 32
      height: Math.max(0, parent.height - y - helpFoot.implicitHeight - 22)
      clip: true
      contentHeight: helpGrid.implicitHeight
      boundsBehavior: Flickable.StopAtBounds
      // key | what it does, two pairs to a row
      Grid {
        id: helpGrid
        width: helpFlick.width
        columns: width > tasks.px(520) ? 2 : 1
        columnSpacing: 20
        rowSpacing: 6
        Repeater {
          model: (tasks.helpSections[tasks.helpSection] || ["", []])[1]
          Row {
            required property var modelData
            width: (helpGrid.width - (helpGrid.columns - 1) * helpGrid.columnSpacing) / helpGrid.columns
            spacing: 8
            readonly property real keyW: Math.min(tasks.px(130), width * 0.42)
            Text {
              width: parent.keyW
              wrapMode: Text.Wrap
              text: parent.modelData[0]
              color: tasks.accent; font.family: tasks.font; font.pixelSize: tasks.px(11); font.bold: true
            }
            Text {
              width: parent.width - parent.keyW - 8
              wrapMode: Text.Wrap
              text: parent.modelData[1]
              color: tasks.dim; font.family: tasks.font; font.pixelSize: tasks.px(11)
            }
          }
        }
      }
    }
    Text {
      id: helpFoot
      x: 16
      anchors.bottom: parent.bottom; anchors.bottomMargin: 12
      width: parent.width - 32
      wrapMode: Text.Wrap
      text: "← → sections · ↑↓ scroll · Esc or ? closes · text boxes: Enter saves, Esc leaves · todos are plain markdown in "
        + tasks.shortPath(tasks.folder) + " (agents: taskchy --help)"
      color: tasks.faint
      font.family: tasks.font; font.pixelSize: tasks.px(10) }
  }

  // ================================================== a picture, shown big
  Rectangle {
    id: zoom
    z: 62
    anchors.fill: parent
    visible: tasks.zoomPic !== ""
    color: tasks.solid
    radius: tasks.rad
    Image {
      anchors.fill: parent; anchors.margins: 28
      source: tasks.zoomPic !== "" ? "file://" + tasks.zoomPic : ""
      fillMode: Image.PreserveAspectFit
      asynchronous: true
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; anchors.bottomMargin: 8
      text: "Esc / Enter / click to close"
      color: tasks.faint; font.family: tasks.font; font.pixelSize: tasks.px(10.5)
    }
    MouseArea { anchors.fill: parent; onClicked: { tasks.zoomPic = ""; tasks.forceActiveFocus() } }
    // Esc works here even from the sub-todo list (the view's keys see the viewer's zoom only)
    focus: visible
    Keys.onPressed: event => { tasks.zoomPic = ""; tasks.forceActiveFocus(); event.accepted = true }
    onVisibleChanged: if (visible && !tasks.viewEntry) forceActiveFocus()
  }

  // ================================================== pick a picture
  FocusScope {
    id: picker
    z: 61
    anchors.fill: parent
    visible: false
    readonly property string home: Quickshell.env("HOME")
    property string dir: ""
    function open() {
      var last = tasks.ui ? tasks.ui["tasks-pic-dir"] : ""
      dir = last || (home + "/Pictures")
      visible = true
      grid.currentIndex = 0
      grid.forceActiveFocus()
    }
    function close() {
      visible = false
      tasks.forceActiveFocus()
    }
    function go(path) {
      dir = path
      grid.currentIndex = 0
      var m = Object.assign({}, tasks.ui); m["tasks-pic-dir"] = path; tasks.ui = m
    }
    function up() { if (dir !== "/") go(dir.replace(/\/[^\/]+\/?$/, "") || "/") }
    function choose(i) {
      if (i < 0 || i >= files.count) return
      var path = files.get(i, "filePath")
      if (files.get(i, "fileIsDir")) { go(path); return }
      var t = null
      for (var k = 0; k < tasks.todos.length; k++) if (tasks.todos[k].id === tasks.pickFor.id) t = tasks.todos[k]
      tasks.addPicture(t, tasks.pickFor.n, path)
      close()
    }
    FolderListModel {
      id: files
      folder: picker.dir !== "" ? "file://" + picker.dir : ""
      nameFilters: ["*.png", "*.jpg", "*.jpeg", "*.webp", "*.gif", "*.bmp", "*.svg", "*.PNG", "*.JPG", "*.JPEG"]
      showDirs: true
      showDirsFirst: true
      showDotAndDotDot: false
      showHidden: false
      sortField: FolderListModel.Name
    }
    // dim the rest; a click outside closes it
    Rectangle { anchors.fill: parent; color: tasks.tint(tasks.bg, 0.6); radius: tasks.rad
      MouseArea { anchors.fill: parent; onClicked: picker.close() } }

    Rectangle {
      id: pickCard
      anchors.centerIn: parent
      width: Math.min(parent.width - 40, tasks.px(700))
      height: Math.min(parent.height - 40, tasks.px(500))
      radius: tasks.rad
      color: tasks.solid
      border.color: Color.menu.border
      border.width: 1
      MouseArea { anchors.fill: parent }
      Column {
        x: 16; y: 16
        width: pickCard.width - 32
        spacing: 10
        Row {
          width: parent.width
          spacing: 8
          Heading { id: pickHeading; anchors.verticalCenter: parent.verticalCenter; text: "Pick a picture" }
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - pickHeading.width - upBtn.width - homeBtn.width - 24; height: tasks.px(26); radius: tasks.rad
            color: tasks.rowFill; border.color: tasks.line; border.width: 1
            Text {
              x: 10; width: parent.width - 20; anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideLeft
              text: picker.dir.replace(picker.home, "~")
              color: tasks.dim; font.family: tasks.font; font.pixelSize: tasks.px(10.5)
            }
          }
          Btn { id: upBtn; icon: ""; text: "up  ⌫"; size: 10; onClicked: { picker.up(); grid.forceActiveFocus() } }
          Btn { id: homeBtn; icon: ""; text: "~"; size: 10; onClicked: { picker.go(picker.home); grid.forceActiveFocus() } }
        }
        GridView {
          id: grid
          width: parent.width
          height: pickCard.height - 32 - tasks.px(26) - tasks.px(20) - 20
          clip: true
          cellWidth: Math.floor(width / Math.max(1, Math.floor(width / tasks.px(116))))
          cellHeight: tasks.px(112)
          model: files
          boundsBehavior: Flickable.StopAtBounds
          keyNavigationEnabled: true
          highlightFollowsCurrentItem: false
          delegate: Item {
            id: cell
            required property int index
            required property string fileName
            required property string filePath
            required property bool fileIsDir
            readonly property bool here: GridView.isCurrentItem
            width: grid.cellWidth; height: grid.cellHeight
            Rectangle {
              anchors.fill: parent; anchors.margins: 4
              radius: tasks.rad
              color: tasks.rowColor(cell.here, false, cellMouse.containsMouse)
              border.color: cell.here ? tasks.accent : tasks.line; border.width: 1
              Text {
                visible: cell.fileIsDir
                anchors.horizontalCenter: parent.horizontalCenter; y: 14
                text: ""; color: cell.here ? tasks.accent : tasks.dim; font.family: tasks.font; font.pixelSize: tasks.px(38)
              }
              Image {
                visible: !cell.fileIsDir
                x: 6; y: 6; width: parent.width - 12; height: parent.height - tasks.px(34)
                source: cell.fileIsDir ? "" : "file://" + cell.filePath
                sourceSize.height: 140
                fillMode: Image.PreserveAspectFit
                asynchronous: true
              }
              Text {
                x: 6; y: parent.height - tasks.px(22); width: parent.width - 12
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideMiddle
                text: cell.fileName
                color: cell.here ? tasks.accent : tasks.fg; font.family: tasks.font; font.pixelSize: tasks.px(9.5); font.bold: cell.fileIsDir
              }
            }
            MouseArea {
              id: cellMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: { grid.currentIndex = cell.index; picker.choose(cell.index) }
            }
          }
          onCurrentIndexChanged: positionViewAtIndex(currentIndex, GridView.Contain)
          Keys.onPressed: event => {
            var k = event.key, txt = event.text
            if (k === Qt.Key_Escape || txt === "q") picker.close()
            else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) picker.choose(currentIndex)
            else if (k === Qt.Key_Backspace || txt === "-") picker.up()
            else if (txt === "~") picker.go(picker.home)
            else if (txt === "h") moveCurrentIndexLeft()
            else if (txt === "l") moveCurrentIndexRight()
            else if (txt === "k") moveCurrentIndexUp()
            else if (txt === "j") moveCurrentIndexDown()
            else return
            event.accepted = true
          }
          Text {
            visible: files.count === 0 && files.status === FolderListModel.Ready
            anchors.centerIn: parent
            text: "No pictures or folders here  (⌫ goes up)"
            color: tasks.faint; font.family: tasks.font; font.pixelSize: tasks.px(11.5)
          }
        }
        Text {
          text: "arrows / hjkl pick · Enter opens a folder or adds the picture · ⌫ up · ~ home · Esc closes"
          color: tasks.faint; font.family: tasks.font; font.pixelSize: tasks.px(10)
        }
      }
    }
  }
}
