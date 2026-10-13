' CleanIT launcher - starts CleanIT as administrator without any console window.
Option Explicit
Dim fso, dir, args, i, extra
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
extra = ""
For i = 0 To WScript.Arguments.Count - 1
    extra = extra & " """ & WScript.Arguments(i) & """"
Next
args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\CleanIT.ps1""" & extra
CreateObject("Shell.Application").ShellExecute "powershell.exe", args, dir, "runas", 0
