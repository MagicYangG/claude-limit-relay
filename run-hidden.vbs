' claude-preheat: run the given command with NO console window.
' A Task Scheduler console action flashes a cmd window on every tick (every
' scheduled preheat fire would pop one - observed live as periodic popups).
' This wscript shim stays in the interactive session, so BurntToast
' notifications still display - unlike an S4U principal, which would also
' hide the window but silences toasts.
Option Explicit
Dim sh, cmd, i
Set sh = CreateObject("WScript.Shell")
cmd = ""
For i = 0 To WScript.Arguments.Count - 1
    If i > 0 Then cmd = cmd & " "
    cmd = cmd & """" & WScript.Arguments(i) & """"
Next
sh.Run cmd, 0, False
