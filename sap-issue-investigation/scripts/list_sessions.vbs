Option Explicit

' 只读列会话；忙碌会话不能读取 Info，避免被等待调试的原调用阻塞。
Dim rot, gui, engine, conn, session, ci, si, busy, failure, failures, count
failures = 0
count = 0
On Error Resume Next
Set rot = CreateObject("SapROTWr.SapROTWrapper")
If Err.Number <> 0 Then Fail "Cannot create SAP ROT wrapper: " & Err.Description
Set gui = rot.GetROTEntry("SAPGUI")
If Err.Number <> 0 Then Fail "Cannot get SAP GUI ROT entry: " & Err.Description
If gui Is Nothing Then Fail "SAP GUI ROT entry not found"
Set engine = gui.GetScriptingEngine
If Err.Number <> 0 Then Fail "Scripting engine unavailable: " & Err.Description
On Error GoTo 0

For ci = 0 To engine.Children.Count - 1
  Set conn = engine.Children(CInt(ci))
  For si = 0 To conn.Children.Count - 1
    Set session = conn.Children(CInt(si))
    count = count + 1
    On Error Resume Next
    Err.Clear
    busy = session.Busy
    failure = Err.Description
    If Err.Number <> 0 Then
      WScript.Echo "ConnectionIndex=" & ci & "; SessionIndex=" & si & "; ERROR=" & failure
      failures = failures + 1
      Err.Clear
    ElseIf busy Then
      WScript.Echo "ConnectionIndex=" & ci & "; SessionIndex=" & si & "; Busy=True"
    Else
      WScript.Echo "ConnectionIndex=" & ci & "; SessionIndex=" & si & "; Busy=False" & _
        "; System=" & session.Info.SystemName & "; Client=" & session.Info.Client & _
        "; Transaction=" & session.Info.Transaction & "; Title=" & session.FindById("wnd[0]").Text
      If Err.Number <> 0 Then Fail "Cannot read idle session: " & Err.Description
    End If
    On Error GoTo 0
  Next
Next
If count = 0 Then Fail "No SAP sessions found"
If failures > 0 Then Fail "Some session states could not be read"

Sub Fail(ByVal message)
  WScript.StdErr.WriteLine "ERROR; " & message
  WScript.Quit 2
End Sub
