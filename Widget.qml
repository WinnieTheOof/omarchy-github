import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// GitHub at a glance. The bar shows the GitHub mark with the number of local
// commits not yet pushed (↑) and upstream commits not yet pulled (↓); the mark
// turns red while CI fails on a tracked branch and yellow while work is
// unpushed. The popup lists recent repos (plus every repo that needs a push or
// pull) with their commit history and push / pull / lazygit / open actions,
// the viewer's PRs and review requests, and the contribution graph.
//
// Data: local.sh (git only, polled), remote.sh (one gh GraphQL call, polled
// slowly), action.sh (stage/stage-file/commit/push/pull/fetch/lazygit). IPC: omarchy-shell mulm.github toggle
Panel {
  id: root
  moduleName: "mulm.github"
  ipcTarget: "mulm.github"

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, ""))
  readonly property var roots: String(setting("roots", "~/Projects")).split(",").map(s => s.trim()).filter(s => s !== "")
  readonly property int maxRepos: Math.max(1, Number(setting("maxRepos", 8)) || 8)
  readonly property int localIntervalMs: Math.max(2, Number(setting("localIntervalSec", 10)) || 10) * 1000
  readonly property int remoteIntervalMs: Math.max(30, Number(setting("remoteIntervalSec", 180)) || 180) * 1000
  readonly property int fetchIntervalMin: Math.max(0, Number(setting("fetchIntervalMin", 15)) || 0)
  readonly property bool barNotifications: setting("barNotifications", false) === true

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  property var localRepos: []
  property var remote: ({})
  property string remoteError: ""
  property real lastRemoteMs: 0
  property real lastFetchMs: 0
  property bool remoteRequested: false
  property real nowSec: Date.now() / 1000
  property bool showAll: false
  property string expandedPath: ""
  signal commitSucceeded(string repoPath)
  property int cursorIndex: 0
  property bool cursorActive: false
  property string pendingAction: ""   // "<kind>:<path>" while action.sh runs
  property var hoverDay: null

  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property color faint: Qt.darker(fg, 1.9)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color red: bar ? bar.urgent : Commons.Color.urgent
  property color yellow: Commons.Color.accent
  property color green: "#8fbf6a"
  property color blue: "#7aa2f7"

  // ---------- derived state ----------
  readonly property var remoteRepos: remote && remote.repos ? remote.repos : ({})
  readonly property var repos: {
    var rr = remoteRepos
    var list = localRepos.map(r => Object.assign({}, r, { gh: r.slug && rr[r.slug] ? rr[r.slug] : null }))
    list.sort((a, b) => b.lastCommit - a.lastCommit)
    return list
  }
  readonly property var shownRepos: showAll
    ? repos
    : repos.filter((r, i) => i < maxRepos || r.ahead > 0 || r.behind > 0 || r.conflicts > 0)
  readonly property var unpushedRepos: repos.filter(r => r.ahead > 0 && r.remote !== "")
  readonly property var behindRepos: repos.filter(r => r.behind > 0)
  readonly property var failingRepos: repos.filter(r => r.gh && (r.gh.ci === "FAILURE" || r.gh.ci === "ERROR"))
  readonly property int totalAhead: unpushedRepos.reduce((n, r) => n + r.ahead, 0)
  readonly property int totalBehind: behindRepos.reduce((n, r) => n + r.behind, 0)
  readonly property int notifications: remote && remote.notifications !== undefined ? Number(remote.notifications) : -1
  readonly property string notificationLabel: notifications >= 50 ? "50+" : (notifications > 0 ? String(notifications) : "")
  readonly property var weeks: remote && remote.contributions ? remote.contributions.weeks || [] : []
  readonly property var prs: remote && remote.prs ? remote.prs.slice(0, 5) : []
  readonly property var reviews: remote && remote.reviews ? remote.reviews.slice(0, 5) : []
  readonly property bool fetching: fetchProc.running

  readonly property color markColor: failingRepos.length > 0 ? red
    : (totalAhead > 0 ? yellow : (bar ? bar.barForeground : Commons.Color.foreground))

  readonly property string barText: {
    var t = "󰊤"
    if (totalAhead > 0) t += " ↑" + totalAhead
    if (totalBehind > 0) t += " ↓" + totalBehind
    if (barNotifications && notificationLabel !== "") t += " 󰂚" + notificationLabel
    return t
  }

  readonly property string summary: {
    var parts = []
    if (unpushedRepos.length) parts.push(unpushedRepos.length + (unpushedRepos.length === 1 ? " repo" : " repos") + " to push")
    if (behindRepos.length) parts.push(behindRepos.length + " to pull")
    if (failingRepos.length) parts.push("CI failing: " + failingRepos.map(r => r.name).join(", "))
    if (!parts.length) parts.push(localRepos.length ? "everything pushed" : "no repos found")
    return parts.join(" · ")
  }

  // ---------- helpers ----------
  function pickHue(raw, targetHue, tolerance, fallback) {
    var best = null, bestScore = Infinity
    var re = /^\s*([a-z_0-9]+)\s*=\s*"(#[0-9a-fA-F]{6})"/gm, m
    while ((m = re.exec(String(raw || ""))) !== null) {
      var c = Qt.color(m[2])
      if (c.hslHue < 0 || c.hslSaturation < 0.3 || c.hslLightness < 0.35 || c.hslLightness > 0.85) continue
      var score = Math.abs(c.hslHue * 360 - targetHue)
      if (score < bestScore) { bestScore = score; best = c }
    }
    return best && bestScore <= tolerance ? best : fallback
  }

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function age(sec) {
    var d = Math.max(0, nowSec - Number(sec || 0))
    if (!sec) return "never"
    if (d < 60) return "now"
    if (d < 3600) return Math.floor(d / 60) + "m"
    if (d < 86400) return Math.floor(d / 3600) + "h"
    if (d < 86400 * 30) return Math.floor(d / 86400) + "d"
    if (d < 86400 * 365) return Math.floor(d / 86400 / 30) + "mo"
    return Math.floor(d / 86400 / 365) + "y"
  }

  function ciGlyph(state) {
    if (state === "SUCCESS") return "󰄬"
    if (state === "FAILURE" || state === "ERROR") return "󰅖"
    if (state === "PENDING" || state === "EXPECTED") return "󰦖"
    return ""
  }
  function ciColor(state) {
    if (state === "SUCCESS") return green
    if (state === "FAILURE" || state === "ERROR") return red
    return yellow
  }
  function ciLabel(state) {
    if (state === "SUCCESS") return "CI passing"
    if (state === "FAILURE" || state === "ERROR") return "CI failing"
    if (state === "PENDING" || state === "EXPECTED") return "CI running"
    return ""
  }

  function levelColor(level) {
    if (!level) return alpha(fg, 0.08)
    return alpha(green, [0.3, 0.5, 0.75, 1.0][Math.min(4, level) - 1])
  }

  function repoUrl(repo, suffix) {
    if (!repo || !repo.slug) return ""
    return "https://github.com/" + repo.slug + (suffix || "")
  }

  function openUrl(url) {
    if (!url) return
    Quickshell.execDetached(["omarchy-launch-browser", url])
    close()
  }

  // ---------- refresh ----------
  function refreshLocal() {
    if (localProc.running) return
    localProc.command = [pluginDir + "/local.sh"].concat(roots)
    localProc.running = true
  }

  function refreshRemote() {
    if (remoteProc.running) return
    remoteProc.command = [pluginDir + "/remote.sh"].concat(
      repos.filter(r => r.slug && r.branch && r.branch !== "(detached)").map(r => r.slug + ":" + r.branch))
    remoteProc.running = true
  }

  function runFetch() {
    if (fetchProc.running) return
    var paths = repos.filter(r => r.remote !== "").map(r => r.path)
    if (!paths.length) return
    fetchProc.command = [pluginDir + "/action.sh", "fetch"].concat(paths)
    fetchProc.running = true
  }

  function refreshAll() {
    refreshLocal()
    refreshRemote()
    runFetch()
  }

  function applyLocal(text) {
    var list
    try { list = JSON.parse(String(text || "[]")) } catch (e) { return }
    if (!Array.isArray(list)) return
    localRepos = list
    nowSec = Date.now() / 1000
    if (cursorIndex >= shownRepos.length) cursorIndex = Math.max(0, shownRepos.length - 1)
    if (!remoteRequested) {
      remoteRequested = true
      refreshRemote()
    }
  }

  function applyRemote(text) {
    var data
    try { data = JSON.parse(String(text || "")) } catch (e) { remoteError = "unexpected response"; return }
    if (!data || data.ok !== true) {
      remoteError = data && data.error ? String(data.error).split("\n")[0] : "GitHub unreachable"
      return
    }
    remote = data
    remoteError = ""
    lastRemoteMs = Date.now()
  }

  // ---------- actions ----------
  function isPending(kind, repo) { return repo && pendingAction === kind + ":" + repo.path }

  function runAction(kind, repo, argument) {
    if (!repo || actionProc.running) return
    if (kind === "commit" && (!repo.staged || repo.conflicts || !argument)) return
    if (kind === "push" && !(repo.ahead > 0 && repo.remote !== "")) return
    if (kind === "pull" && !(repo.behind > 0)) return
    if (kind === "stage-file" && (repo.conflicts || !argument || !argument.length)) return
    pendingAction = kind + ":" + repo.path
    var command = [pluginDir + "/action.sh", kind, repo.path]
    if (kind === "commit") command.push(argument)
    if (kind === "stage-file") command = command.concat(argument)
    actionProc.command = command
    actionProc.running = true
  }

  function lazygit(repo) {
    if (!repo) return
    Quickshell.execDetached([pluginDir + "/action.sh", "lazygit", repo.path])
    close()
  }

  function toggleExpanded(repo) {
    if (!repo) return
    expandedPath = expandedPath === repo.path ? "" : repo.path
  }

  // ---------- keyboard ----------
  function cursorRepo() { return cursorActive ? shownRepos[cursorIndex] : null }

  function moveCursor(dy) {
    if (!shownRepos.length) return
    if (!cursorActive) { cursorActive = true; cursorIndex = Math.min(cursorIndex, shownRepos.length - 1) }
    else cursorIndex = Math.max(0, Math.min(shownRepos.length - 1, cursorIndex + dy))
    Qt.callLater(ensureCursorVisible)
  }

  function ensureCursorVisible() {
    var item = repoRepeater.itemAt(cursorIndex)
    if (!item) return
    var p = item.mapToItem(column, 0, 0)
    var h = Math.min(item.height, flick.height)
    if (p.y < flick.contentY) flick.contentY = p.y
    else if (p.y + h > flick.contentY + flick.height) flick.contentY = p.y + h - flick.height
  }

  function handleKey(t) {
    var repo = cursorRepo()
    if (t === "r") refreshAll()
    else if (t === "f") runFetch()
    else if (t === "a") showAll = !showAll
    else if (t === "p") runAction("push", repo)
    else if (t === "u") runAction("pull", repo)
    else if (t === "g") lazygit(repo)
    else if (t === "o") openUrl(repoUrl(repo, ""))
  }

  onOpenedChanged: {
    if (!opened) return
    cursorActive = false
    hoverDay = null
    refreshLocal()
    if (Date.now() - lastRemoteMs > 60000) refreshRemote()
    if (Date.now() - lastFetchMs > 5 * 60000) runFetch()
  }

  // ---------- processes & timers ----------
  FileView {
    path: Commons.Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.yellow = root.pickHue(text(), 48, 20, Commons.Color.accent)
      root.green = root.pickHue(text(), 115, 35, "#8fbf6a")
      root.blue = root.pickHue(text(), 210, 30, "#7aa2f7")
    }
  }

  Process {
    id: localProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyLocal(text) }
  }

  Process {
    id: remoteProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyRemote(text) }
  }

  Process {
    id: fetchProc
    onExited: { root.lastFetchMs = Date.now(); root.refreshLocal() }
  }

  Process {
    id: actionProc
    onExited: function(exitCode) {
      if (exitCode === 0 && root.pendingAction.startsWith("commit:"))
        root.commitSucceeded(root.pendingAction.slice("commit:".length))
      if (/^(push|pull):/.test(root.pendingAction)) remoteDelay.restart()
      root.pendingAction = ""
      root.refreshLocal()
    }
  }

  // CI and the remote branch only settle a moment after a push lands.
  Timer { id: remoteDelay; interval: 4000; onTriggered: root.refreshRemote() }

  Timer {
    interval: root.opened ? Math.min(3000, root.localIntervalMs) : root.localIntervalMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshLocal()
  }

  Timer {
    interval: root.remoteIntervalMs
    running: root.remoteRequested
    repeat: true
    onTriggered: root.refreshRemote()
  }

  Timer {
    interval: Math.max(1, root.fetchIntervalMin) * 60000
    running: root.fetchIntervalMin > 0
    repeat: true
    onTriggered: root.runFetch()
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: root.nowSec = Date.now() / 1000
  }

  // ---------- bar button ----------
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    horizontalMargin: 7
    foreground: root.markColor
    tooltipText: root.opened ? "" : "GitHub — " + root.summary
      + (root.notificationLabel !== "" ? "\n" + root.notificationLabel + " unread notifications" : "")
      + "\nClick: open · Right-click: fetch all"
    onPressed: function(b) {
      if (b === Qt.RightButton) root.runFetch()
      else root.toggle()
    }
  }

  // ---------- popup ----------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(470))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.toggleExpanded(root.cursorRepo())
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { root.handleKey(t) }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: column
          width: flick.width
          spacing: Style.space(14)

          // ---------- hero ----------
          PanelHero {
            foreground: root.fg
            fontFamily: root.fontFamily
            title: root.remote.login || "GitHub"
            meta: root.remoteError !== "" ? "offline · " + root.summary : root.summary
            detail: root.notificationLabel !== "" ? "󰂚 " + root.notificationLabel : ""
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "󰊤"
                color: root.markColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              PanelActionButton {
                iconText: root.fetching || remoteProc.running ? "󰦖" : "󰑐"
                tooltipText: "Refresh and fetch (r)"
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: root.refreshAll()
              }
            }
          }

          // ---------- contribution graph ----------
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.weeks.length > 0

            Item {
              id: heat
              width: parent.width
              readonly property int gap: Style.space(3)
              readonly property int cell: Style.space(11)
              readonly property int step: cell + gap
              readonly property int count: Math.min(root.weeks.length, Math.floor((width + gap) / step))
              readonly property var shown: root.weeks.slice(root.weeks.length - count)
              implicitHeight: 7 * step - gap

              Row {
                id: heatRow
                anchors.right: parent.right
                spacing: heat.gap

                Repeater {
                  model: heat.shown

                  Item {
                    id: week
                    required property var modelData
                    width: heat.cell
                    height: heat.implicitHeight

                    Repeater {
                      model: week.modelData

                      Rectangle {
                        required property var modelData
                        y: modelData.wd * heat.step
                        width: heat.cell
                        height: heat.cell
                        radius: Math.min(2, Style.cornerRadius)
                        color: root.levelColor(modelData.l)
                        border.width: root.hoverDay && root.hoverDay.d === modelData.d ? 1 : 0
                        border.color: root.fg
                      }
                    }
                  }
                }
              }

              MouseArea {
                anchors.fill: heatRow
                hoverEnabled: true
                onExited: root.hoverDay = null
                onPositionChanged: function(mouse) {
                  var week = heat.shown[Math.floor(mouse.x / heat.step)]
                  var wd = Math.floor(mouse.y / heat.step)
                  root.hoverDay = week ? (week.filter(d => d.wd === wd)[0] || null) : null
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              elide: Text.ElideRight
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              text: {
                var c = root.remote.contributions || {}
                if (root.hoverDay) {
                  var n = root.hoverDay.c
                  var day = new Date(root.hoverDay.d + "T12:00:00")
                  return (n === 0 ? "No" : n) + (n === 1 ? " contribution" : " contributions") + " on "
                    + day.toLocaleDateString(Qt.locale("en_US"), "ddd, MMM d yyyy")
                }
                return c.total + " contributions in the last year · " + c.today + " today · "
                  + c.streak + (c.streak === 1 ? " day" : " days") + " streak"
              }
            }
          }

          // ---------- repositories ----------
          PanelSeparator { foreground: root.fg }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: reposHeader.implicitHeight

              PanelSectionHeader {
                id: reposHeader
                text: "REPOSITORIES"
                foreground: root.fg
                fontFamily: root.fontFamily
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: reposHeader.verticalCenter
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                text: root.fetching ? "fetching…"
                  : (root.lastFetchMs > 0 ? "fetched " + root.age(root.lastFetchMs / 1000) + (root.age(root.lastFetchMs / 1000) === "now" ? "" : " ago") : "")
              }
            }

            Text {
              visible: root.shownRepos.length === 0
              textFormat: Text.PlainText
              text: "No git repos in " + root.roots.join(", ")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              id: repoRepeater
              model: root.shownRepos

              RepoRow {
                required property var modelData
                required property int index
                width: parent.width
                repo: modelData
                rowIndex: index
              }
            }
          }

          // ---------- pull requests ----------
          PanelSeparator {
            foreground: root.fg
            visible: root.prs.length + root.reviews.length > 0
          }

          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.prs.length + root.reviews.length > 0

            PanelSectionHeader {
              text: "PULL REQUESTS"
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.reviews.map(p => Object.assign({ reviewRequested: true }, p)).concat(root.prs)

              PrRow {
                required property var modelData
                width: parent.width
                pr: modelData
              }
            }
          }

          // ---------- footer ----------
          PanelSeparator { foreground: root.fg }

          Row {
            id: footer
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing * 3) / 4

            Button {
              width: footer.cellWidth
              iconText: "󰂚"
              text: root.notificationLabel !== "" ? "Inbox " + root.notificationLabel : "Inbox"
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.openUrl("https://github.com/notifications")
            }
            Button {
              width: footer.cellWidth
              iconText: "󰓦"
              text: root.fetching ? "Fetching" : "Fetch"
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              enabled: !root.fetching
              onClicked: root.runFetch()
            }
            Button {
              width: footer.cellWidth
              iconText: "\uf401"
              text: root.showAll ? "Recent" : "All " + root.repos.length
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              active: root.showAll
              onClicked: root.showAll = !root.showAll
            }
            Button {
              width: footer.cellWidth
              iconText: "󰏌"
              text: "Profile"
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.openUrl("https://github.com/" + (root.remote.login || ""))
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            visible: root.remoteError !== ""
            text: "GitHub: " + root.remoteError
            color: root.red
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: "↵ commits · p push · u pull · g lazygit · o open · f fetch · a all"
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // ---------- components ----------
  component RepoRow: Column {
    id: rowRoot
    property var repo: ({})
    property int rowIndex: 0

    readonly property bool selected: root.cursorActive && root.cursorIndex === rowIndex
    readonly property bool expanded: root.expandedPath === repo.path
    readonly property bool hot: selected || rowMouse.containsMouse || actionsHovered
    property bool actionsHovered: false
    readonly property int changes: repo.fileCount || 0
    readonly property string ci: repo.gh ? repo.gh.ci : ""

    spacing: 0

    CursorSurface {
      id: surface
      width: parent.width
      implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX
      hasCursor: rowRoot.selected || rowMouse.containsMouse
      current: rowRoot.expanded
      foreground: root.fg

      MouseArea {
        id: rowMouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onContainsMouseChanged: if (containsMouse) {
          root.cursorActive = true
          root.cursorIndex = rowRoot.rowIndex
        }
        onClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) root.lazygit(rowRoot.repo)
          else root.toggleExpanded(rowRoot.repo)
        }
      }

      Item {
        id: rowContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(8)
        implicitHeight: Math.max(repoIcon.implicitHeight, info.implicitHeight, rightCluster.implicitHeight)

        Text {
          id: repoIcon
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(18)
          text: rowRoot.repo.gh && rowRoot.repo.gh.private ? "󰌾" : (rowRoot.repo.slug ? "\uf401" : "󰘬")
          color: rowRoot.repo.ahead > 0 && rowRoot.repo.remote !== "" ? root.yellow : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }

        Column {
          id: info
          anchors.left: repoIcon.right
          anchors.leftMargin: Style.space(6)
          anchors.right: rightCluster.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            elide: Text.ElideRight
            text: rowRoot.repo.name
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: rowRoot.expanded
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            elide: Text.ElideRight
            text: "󰘬 " + rowRoot.repo.branch + ((rowRoot.repo.commits || []).length ? "  " + rowRoot.repo.commits[0].subject : "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Row {
          id: rightCluster
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          Badge { visible: rowRoot.repo.conflicts > 0; text: "!" + rowRoot.repo.conflicts; color: root.red; tip: "merge conflicts" }
          Badge { visible: rowRoot.repo.ahead > 0; text: "↑" + rowRoot.repo.ahead; color: root.yellow; tip: rowRoot.repo.remote !== "" ? "commits to push" : "local commits (no remote)" }
          Badge { visible: rowRoot.repo.behind > 0; text: "↓" + rowRoot.repo.behind; color: root.blue; tip: "commits to pull" }
          Badge { visible: rowRoot.changes > 0; text: "●" + rowRoot.changes; color: root.fg; tip: strings.t("stagedCount").arg(rowRoot.repo.staged) }
          Badge { visible: rowRoot.ci !== ""; text: root.ciGlyph(rowRoot.ci); color: root.ciColor(rowRoot.ci); tip: root.ciLabel(rowRoot.ci) + " on " + rowRoot.repo.branch }

          Text {
            visible: !rowRoot.hot
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.age(rowRoot.repo.lastCommit)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            width: Style.space(26)
            horizontalAlignment: Text.AlignRight
          }

          Row {
            visible: rowRoot.hot
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            RowAction {
              visible: rowRoot.repo.ahead > 0 && rowRoot.repo.remote !== ""
              iconText: root.isPending("push", rowRoot.repo) ? "󰦖" : "󰅧"
              tooltipText: "Push " + rowRoot.repo.ahead + (rowRoot.repo.ahead === 1 ? " commit (p)" : " commits (p)")
              hoverColor: root.yellow
              enabled: !actionProc.running
              onClicked: root.runAction("push", rowRoot.repo)
            }
            RowAction {
              visible: rowRoot.repo.behind > 0
              iconText: root.isPending("pull", rowRoot.repo) ? "󰦖" : "󰅢"
              tooltipText: "Pull --ff-only (u)"
              hoverColor: root.blue
              enabled: !actionProc.running
              onClicked: root.runAction("pull", rowRoot.repo)
            }
            RowAction {
              iconText: "󰆍"
              tooltipText: "Open in lazygit (g)"
              onClicked: root.lazygit(rowRoot.repo)
            }
            RowAction {
              visible: rowRoot.repo.slug !== ""
              iconText: "󰏌"
              tooltipText: "Open on GitHub (o)"
              onClicked: root.openUrl(root.repoUrl(rowRoot.repo, ""))
            }
          }
        }
      }
    }

    // ---------- expanded: details + commit history ----------
    Column {
      visible: rowRoot.expanded
      width: parent.width
      leftPadding: Style.space(34)
      rightPadding: Style.space(8)
      topPadding: Style.space(4)
      bottomPadding: Style.space(8)
      spacing: Style.space(2)

      readonly property real innerWidth: width - leftPadding - rightPadding

      Row {
        width: parent.innerWidth
        spacing: Style.space(6)

        LinkButton {
          text: strings.t("stageAll")
          enabled: !actionProc.running && rowRoot.repo.conflicts === 0
                   && (rowRoot.repo.modified > 0 || rowRoot.repo.untracked > 0)
          onClicked: root.runAction("stage", rowRoot.repo)
        }

        LinkButton {
          text: strings.t("push")
          enabled: !actionProc.running && rowRoot.repo.ahead > 0 && rowRoot.repo.remote !== ""
          onClicked: root.runAction("push", rowRoot.repo)
        }

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: strings.t("stagedCount").arg(Commons.I18n.formatNumber(rowRoot.repo.staged || 0))
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Row {
        visible: rowRoot.changes > 0
        width: parent.innerWidth
        spacing: Style.space(6)

        Rectangle {
          width: parent.width - commitButton.width - parent.spacing
          height: Style.space(28)
          radius: Style.space(4)
          color: "transparent"
          border.color: root.dim

          TextInput {
            id: commitMessage
            anchors.fill: parent
            anchors.margins: Style.space(5)
            verticalAlignment: TextInput.AlignVCenter
            color: root.fg
            selectionColor: root.blue
            clip: true
            maximumLength: 240
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            onAccepted: if (commitButton.enabled) commitButton.clicked()
            Keys.onEscapePressed: keyCatcher.forceActiveFocus()
          }

          Connections {
            target: root
            function onCommitSucceeded(repoPath) {
              if (repoPath === rowRoot.repo.path) commitMessage.clear()
            }
          }

          Text {
            anchors.fill: commitMessage
            verticalAlignment: Text.AlignVCenter
            visible: commitMessage.text.length === 0
            text: strings.t("commitMessage")
            color: root.dim
            font: commitMessage.font
          }
        }

        LinkButton {
          id: commitButton
          text: strings.t("commit")
          anchors.verticalCenter: parent.verticalCenter
          enabled: !actionProc.running && rowRoot.repo.staged > 0 && rowRoot.repo.conflicts === 0
                   && commitMessage.text.trim().length > 0
          onClicked: {
            root.runAction("commit", rowRoot.repo, commitMessage.text.trim())
            keyCatcher.forceActiveFocus()
          }
        }
      }

      Repeater {
        model: rowRoot.expanded ? (rowRoot.repo.files || []) : []

        Item {
          id: fileRow
          required property var modelData
          width: parent.innerWidth
          implicitHeight: Math.max(fileText.implicitHeight, stageFileButton.visible ? stageFileButton.implicitHeight : 0)

          Text {
            id: fileText
            anchors.left: parent.left
            anchors.right: stageFileButton.visible ? stageFileButton.left : parent.right
            anchors.rightMargin: stageFileButton.visible ? Style.space(6) : 0
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: strings.t(fileRow.modelData.status).arg(fileRow.modelData.path.slice(0, 1024))
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          LinkButton {
            id: stageFileButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: strings.t("stageFile")
            visible: !!(fileRow.modelData.stagePaths || []).length
            enabled: !actionProc.running && rowRoot.repo.conflicts === 0
            onClicked: root.runAction("stage-file", rowRoot.repo, fileRow.modelData.stagePaths)
          }
        }
      }

      Text {
        visible: rowRoot.changes > (rowRoot.repo.files || []).length
        textFormat: Text.PlainText
        text: strings.t("visibleFiles").arg((rowRoot.repo.files || []).length).arg(rowRoot.changes)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        width: parent.innerWidth
        elide: Text.ElideRight
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        text: {
          var r = rowRoot.repo, parts = []
          parts.push(r.upstream ? "↔ " + r.upstream : (r.remote ? "no upstream" : "no remote"))
          if (r.remote) parts.push("fetched " + root.age(r.fetchedAt) + (r.fetchedAt && root.age(r.fetchedAt) !== "now" ? " ago" : ""))
          if (r.untracked) parts.push(r.untracked + " untracked")
          if (r.stash) parts.push(r.stash + (r.stash === 1 ? " stash" : " stashes"))
          if (r.gh) parts.push(r.gh.prs + " PRs · " + r.gh.issues + " issues")
          return parts.join(" · ")
        }
      }

      Repeater {
        model: rowRoot.repo.commits || []

        Item {
          id: commitRow
          required property var modelData
          required property int index
          readonly property bool unpushed: index < rowRoot.repo.ahead
          readonly property bool linkable: rowRoot.repo.slug !== "" && !unpushed
          width: parent.innerWidth
          implicitHeight: commitText.implicitHeight + Style.space(4)

          Rectangle {
            anchors.fill: parent
            anchors.leftMargin: -Style.space(4)
            anchors.rightMargin: -Style.space(4)
            radius: Style.cornerRadius
            color: commitMouse.containsMouse && commitRow.linkable ? Style.hoverFillFor(root.fg, Commons.Color.accent) : "transparent"
          }

          Text {
            id: hashText
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: (commitRow.unpushed ? "↑ " : "  ") + commitRow.modelData.hash
            color: commitRow.unpushed ? root.yellow : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            id: commitText
            textFormat: Text.PlainText
            anchors.left: hashText.right
            anchors.leftMargin: Style.space(8)
            anchors.right: commitAge.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            text: commitRow.modelData.subject
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            id: commitAge
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.age(commitRow.modelData.time)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            id: commitMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: commitRow.linkable ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: if (commitRow.linkable) root.openUrl(root.repoUrl(rowRoot.repo, "/commit/" + commitRow.modelData.hash))
          }

          PanelToolTip {
            visible: commitMouse.containsMouse
            text: commitRow.modelData.author + " · " + new Date(commitRow.modelData.time * 1000).toLocaleString(Qt.locale("en_US"), "ddd MMM d yyyy, HH:mm")
              + (commitRow.unpushed ? "\nnot pushed yet" : (commitRow.linkable ? "\nclick to open on GitHub" : ""))
            fontFamily: root.fontFamily
          }
        }
      }

      Row {
        visible: rowRoot.repo.slug !== ""
        topPadding: Style.space(4)
        spacing: Style.space(6)

        LinkButton { iconText: "\uf417"; text: "History"; onClicked: root.openUrl(root.repoUrl(rowRoot.repo, "/commits/" + rowRoot.repo.branch)) }
        LinkButton { iconText: "󰦖"; text: "Actions"; onClicked: root.openUrl(root.repoUrl(rowRoot.repo, "/actions")) }
        LinkButton { iconText: "\uf407"; text: "PRs"; onClicked: root.openUrl(root.repoUrl(rowRoot.repo, "/pulls")) }
        LinkButton { iconText: "\udb80\udc28"; text: "Issues"; onClicked: root.openUrl(root.repoUrl(rowRoot.repo, "/issues")) }
      }
    }
  }

  component PrRow: CursorSurface {
    id: prRow
    property var pr: ({})
    readonly property string ci: pr.ci || ""

    implicitHeight: prContent.implicitHeight + Style.spacing.rowPaddingX
    hasCursor: prMouse.containsMouse
    foreground: root.fg

    MouseArea {
      id: prMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.cursorActive = false
      onClicked: root.openUrl(prRow.pr.url)
    }

    Item {
      id: prContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: prInfo.implicitHeight

      Text {
        id: prIcon
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(18)
        text: "\uf407"
        color: prRow.ci !== "" ? root.ciColor(prRow.ci) : (prRow.pr.draft ? root.dim : root.green)
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
      }

      Column {
        id: prInfo
        anchors.left: prIcon.right
        anchors.leftMargin: Style.space(6)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          elide: Text.ElideRight
          text: "#" + prRow.pr.number + " " + prRow.pr.title
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
        Text {
          textFormat: Text.PlainText
          width: parent.width
          elide: Text.ElideRight
          color: prRow.pr.reviewRequested ? root.yellow : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          text: {
            var p = prRow.pr, parts = [p.repo]
            if (p.reviewRequested) parts.push("review requested")
            if (p.draft) parts.push("draft")
            if (p.review === "APPROVED") parts.push("approved")
            else if (p.review === "CHANGES_REQUESTED") parts.push("changes requested")
            if (prRow.ci !== "") parts.push(root.ciLabel(prRow.ci))
            if (p.updatedAt) parts.push("updated " + root.age(Date.parse(p.updatedAt) / 1000) + " ago")
            return parts.join(" · ")
          }
        }
      }
    }
  }

  component Badge: Text {
    id: badge
    property string tip: ""
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.bold: true
  }

  component RowAction: PanelActionButton {
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    foreground: root.fg
    fontFamily: root.fontFamily
    onHovered: function(isHovered) {
      // Keep the row's action cluster up while the pointer moves onto it.
      var row = parent ? parent.parent : null
      while (row && row.actionsHovered === undefined) row = row.parent
      if (row) row.actionsHovered = isHovered
    }
  }

  component LinkButton: Button {
    fontSize: Style.font.caption
    iconSize: Style.font.bodySmall
    foreground: root.fg
    fontFamily: root.fontFamily
    horizontalPadding: Style.space(6)
    verticalPadding: Style.space(2)
    bordered: true
  }
}
