' run-hidden.vbs -- launch a command completely invisibly (no console flash).
'
' Task Scheduler cannot hide the console of bash.exe or powershell.exe when
' invoked directly. Wrapping the command in wscript + VBS is the standard
' workaround: WshShell.Run(cmd, 0, false) creates the process with SW_HIDE
' and no console window is ever displayed.
'
' Usage:
'   wscript.exe run-hidden.vbs "<full command line>"
'
' The single argument is passed verbatim to WshShell.Run.
Option Explicit
If WScript.Arguments.Count < 1 Then WScript.Quit 1
Dim shell
Set shell = CreateObject("WScript.Shell")
' 0 = SW_HIDE, False = do not wait for completion
shell.Run WScript.Arguments(0), 0, False