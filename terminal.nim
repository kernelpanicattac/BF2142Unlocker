#[
  TODO: Encapsulate and refactor or rewrite!
  Currently:
    Do not create multiple processes or multiple forked processes.
    Only one process and one forked process is allowed.
]#

import gintro/[gtk, glib, gobject, gio]

import strutils
import os

when defined(linux):
  import gintro/vte # Requierd for terminal (linux only feature)
  export vte
elif defined(windows):
  import osproc
  import streams
  import winim
  import getprocessbyname # requierd for getPidByName (processname)
  import stdoutreader # requierd for read stdoutput form another process
  import gethwndbypid # requierd for getHWndByPid to hide forked process
  type
    Terminal* = ref object of ScrolledWindow
  proc newTerminal*(): Terminal =
    var textView = newTextView()
    textView.wrapMode = WrapMode.wordChar
    textView.editable = false
    var scrolledWindow = newScrolledWindow(textView.getHadjustment(), textView.getVadjustment())
    scrolledWindow.propagateNaturalHeight = true
    scrolledWindow.add(textView)
    result = cast[Terminal](scrolledWindow)
    result.styleContext.addClass("terminal")
  proc textView(terminal: Terminal): TextView =
    return cast[TextView](terminal.getChild())
  proc buffer(terminal: Terminal): TextBuffer =
    return terminal.textView.getBuffer()
  proc `text=`(terminal: Terminal, text: string) =
    terminal.buffer.setText(text, text.len)
  proc text(terminal: Terminal): string =
    var startIter: TextIter
    var endIter: TextIter
    terminal.buffer.getStartIter(startIter)
    terminal.buffer.getEndIter(endIter)
    return terminal.buffer.getText(startIter, endIter, true)
  proc visible*(terminal: Terminal): bool =
    return terminal.textView.visible
  proc `visible=`*(terminal: Terminal, visible: bool) =
    cast[ScrolledWindow](terminal).visible = visible # TODO: Need to be casted otherwise it will visible infix proc
    terminal.textView.visible = visible

when defined(windows):
  # ... I know, it's ugly.
  proc addTextColorizedWorkaround(terminal: Terminal, text: string, scrollDown: bool = false) =
    var buffer: string
    var textLineSplit: seq[string] = text.splitLines()
    for idx, line in textLineSplit:
      var lineSplit: seq[string]

      if line.len < 3:
        buffer.add(glib.markupEscapeText(line.cstring, line.len))
        if idx + 1 != textLineSplit.high: # TODO: Why?
          buffer.add("\n")
        continue

      lineSplit.add(line[0..2])
      if not (lineSplit[0] in @["###", "<==", "==>"]):
        buffer.add(glib.markupEscapeText(line.cstring, line.len))
        if idx + 1 != textLineSplit.high: # TODO: Why?
          buffer.add("\n")
        continue

      lineSplit.add(line[4..^1].split(':', 1))
      var colorPrefix, colorServer: string
      const FORMATTED_COLORIZE: string = """<span foreground="$#">$#</span> <span foreground="$#">$#:</span>$#"""
      case lineSplit[0]:
        of "###":
          colorPrefix = "blue"
        of "<==", "==>":
          colorPrefix = "green"
        else:
          colorPrefix = "red"
      case lineSplit[1]:
        of "LOGIN":
          colorServer = "darkcyan"
        of "LOGIN_UDP":
          colorServer = "goldenrod"
        of "UNLOCK":
          colorServer = "darkmagenta"
        else:
          colorServer = "red"
      buffer.add(FORMATTED_COLORIZE % [
        colorPrefix,
        glib.markupEscapeText(lineSplit[0], lineSplit[0].len),
        colorServer,
        glib.markupEscapeText(lineSplit[1], lineSplit[1].len),
        glib.markupEscapeText(lineSplit[2], lineSplit[2].len)
      ])

      if idx + 1 != textLineSplit.high:
        buffer.add("\n")

    var iterEnd: TextIter
    terminal.buffer.getEndIter(iterEnd)
    terminal.buffer.insertMarkup(iterEnd, buffer, buffer.len)
    if scrollDown:
      terminal.buffer.placeCursor(iterEnd)
      var mark: TextMark = terminal.buffer.getInsert()
      terminal.textView.scrollMarkOnScreen(mark)

proc clear*(terminal: Terminal) =
  when defined(linux):
    terminal.reset(true, true)
  elif defined(windows):
    var iterStart, iterEnd: TextIter
    terminal.buffer.getStartIter(iterStart)
    terminal.buffer.getEndIter(iterEnd)
    terminal.buffer.delete(iterStart, iterEnd)
##########################

when defined(windows):
  type
    TimerData = ref object
      terminal: Terminal

  # TODO: There are no multiple Terminals possible. That's because the two global channels.
  # These Channel should be in scope. This is not possible. Adding a global pragma doesn't resolve this.
  # This could be solved with a macro. Creating the channels on compiletime with different names.
  var thread: system.Thread[Process]
  var threadForked: system.Thread[int]
  var channelReplaceText: Channel[string]
  var channelAddText: Channel[string]
  var channelTerminateForked: Channel[bool]
  var channelStopTimerAdd: Channel[bool]
  var channelStopTimerReplace: Channel[bool]
  channelReplaceText.open()
  channelTerminateForked.open()
  channelStopTimerReplace.open()
  channelAddText.open()
  channelStopTimerAdd.open()

  proc timerReplaceTerminalText(timerData: TimerData): bool =
    if channelStopTimerReplace.tryRecv().dataAvailable:
      return SOURCE_REMOVE
    var (hasData, data) = channelReplaceText.tryRecv()
    if hasData:
      timerData.terminal.text = data
    return SOURCE_CONTINUE

  proc timerAddTerminalText(timerData: TimerData): bool =
    if channelStopTimerAdd.tryRecv().dataAvailable:
      return SOURCE_REMOVE
    var (hasData, data) = channelAddText.tryRecv()
    if hasData:
      timerData.terminal.addTextColorizedWorkaround(data, scrollDown = true)
    return SOURCE_CONTINUE

  proc isProcessAlive(pid: int): bool =
    var exitCode: DWORD
    var hndl: HANDLE = OpenProcess(PROCESS_ALL_ACCESS, true, pid.DWORD)
    return hndl > 0 and GetExitCodeProcess(hndl, unsafeAddr exitCode).bool and exitCode == STILL_ACTIVE

  proc terminateThread*() = # TODO
    channelStopTimerAdd.send(true)

  proc terminateForkedThread*(pid: int) = # TODO
    channelStopTimerReplace.send(true)
    if isProcessAlive(pid):
      channelTerminateForked.send(true)

proc startProcess*(terminal: Terminal, command: string, params: string = "", workingDir: string = os.getCurrentDir(), env: string = "", searchForkedProcess: bool = false): int = # TODO: processId should be stored and not returned
  when defined(linux):
    var argv: seq[string] = command.strip().splitWhitespace()
    if params != "":
      argv.add(params)
    discard terminal.spawnSync(
      ptyFlags = {PtyFlag.noLastlog},
      workingDirectory = workingDir,
      argv = argv,
      envv = env.strip().splitWhitespace(),
      spawnFlags = {glib.SpawnFlag.doNotReapChild},
      childSetup = nil,
      childSetupData = nil,
      childPid = result
    )
  elif defined(windows):
    var process: Process
    if searchForkedProcess == true: # TODO: store command in variable
      process = startProcess(
        command = """cmd /c """" & workingDir / command & "\" " & params,
        workingDir = workingDir,
        options = {poStdErrToStdOut, poEvalCommand, poEchoCmd}
      )
    else:
      process = startProcess(
        command = workingDir / command & " " & params,
        workingDir = workingDir,
        options = {poStdErrToStdOut, poEvalCommand, poEchoCmd}
      )
    result = process.processID
    if searchForkedProcess:
      var tryCounter: int = 0
      while tryCounter <= 10: # TODO: if result == 0 after all tries rais an exception
        result = getPidByName(command)
        if result > 0: break
        tryCounter.inc()
        sleep(500)

    if searchForkedProcess:
      var timerDataReplaceText: TimerData = TimerData(terminal: terminal)
      discard timeoutAdd(250, timerReplaceTerminalText, timerDataReplaceText)
      threadForked.createThread(proc (processId: int) {.thread.} =
        var hwnd: HWND = getHWndByPid(processId)
        while hwnd == 0: # Wait until window is accessible
          sleep(250)
          hwnd = getHWndByPid(processId)
        var exitCode: DWORD
        var hndl: HANDLE = OpenProcess(PROCESS_ALL_ACCESS, true, processId.DWORD)
        # ShowWindow(hwnd, SW_HIDE) # TODO: Add checkbox to GUI
        while true:
          if channelTerminateForked.tryRecv().dataAvailable:
            discard CloseHandle(hndl)
            return
          if hndl > 0 and GetExitCodeProcess(hndl, unsafeAddr exitCode).bool and exitCode == STILL_ACTIVE:
            var stdoutTuple: tuple[lastError: uint32, stdout: string] = readStdOut(processId)
            if stdoutTuple.lastError == 0:
              channelReplaceText.send(stdoutTuple.stdout)
            elif stdoutTuple.lastError == ERROR_INVALID_HANDLE:
              # TODO: Sometimes it fails with invalid handle.
              # Maybe this happens when the process get's killed during reading the stdout in this thread.
              discard
            else:
              channelReplaceText.send("ERROR: " & $stdoutTuple.lastError & "\n" & osErrorMsg(stdoutTuple.lastError.OSErrorCode))
          else:
            discard CloseHandle(hndl)
            channelReplaceText.send(dgettext("gui", "GAMESERVER_CRASHED"))
            return
          sleep(250)
      , (result))
    else:
      var timerDataAddText: TimerData = TimerData(terminal: terminal)
      discard timeoutAdd(250, timerAddTerminalText, timerDataAddText)
      thread.createThread(proc (process: Process) {.thread.} =
        var exitCode: DWORD
        var hndl: HANDLE = OpenProcess(PROCESS_ALL_ACCESS, true, process.processId.DWORD)
        while true:
          if hndl > 0 and GetExitCodeProcess(hndl, unsafeAddr exitCode).bool and exitCode == STILL_ACTIVE:
            if process.outputStream.isNil:
              return
            channelAddText.send(process.outputStream.readAll())
          sleep(250)
      , (process))
##########################

when isMainModule:
  proc appActivate (app: Application) =
    let window = newApplicationWindow(app)
    window.title = "Terminal"
    window.defaultSize = (250, 50)
    let terminal: Terminal = newTerminal()
    terminal.text = "TEST: Hallo, was geht?\n"
    terminal.addTextColorizedWorkaround("ARSCH:  Gut und dir?\n")
    window.add(terminal)
    window.showAll()
    when defined(linux):
      discard # TODO: implement
    elif defined(windows):
      discard
      # terminal.editable = false # TODO: must be done after terminal/textview is visible

  proc main =
    let app = newApplication("org.gtk.example")
    connect(app, "activate", appActivate)
    discard app.run()

  main()