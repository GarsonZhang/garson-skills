Option Explicit

Dim arguments
Dim mode
Dim rotWrapper
Dim sapGuiAuto
Dim application

Set arguments = WScript.Arguments

If arguments.Count < 1 Then
  Fail 2, "Usage: list | open <system> <client> <transaction> [connection-index session-index]"
End If

mode = LCase(CStr(arguments(0)))

On Error Resume Next
Set rotWrapper = CreateObject("SapROTWr.SapROTWrapper")

If Err.Number <> 0 Then
  Dim createRotError
  createRotError = Err.Description
  Err.Clear
  On Error GoTo 0
  Fail 3, "Cannot create SAP ROT wrapper: " & createRotError
End If

Set sapGuiAuto = rotWrapper.GetROTEntry("SAPGUI")

If Err.Number <> 0 Then
  Dim getRotError
  getRotError = Err.Description
  Err.Clear
  On Error GoTo 0
  Fail 3, "Cannot read SAP GUI ROT entry: " & getRotError
End If

On Error GoTo 0

If sapGuiAuto Is Nothing Then
  Fail 3, "SAP GUI ROT entry was not found"
End If

On Error Resume Next
Set application = sapGuiAuto.GetScriptingEngine

If Err.Number <> 0 Then
  Dim scriptingError
  scriptingError = Err.Description
  Err.Clear
  On Error GoTo 0
  Fail 3, "SAP GUI scripting engine is unavailable: " & scriptingError
End If

On Error GoTo 0

Select Case mode
  Case "list"
    ListSessions application
  Case "open"
    OpenTransaction application, arguments
  Case Else
    Fail 2, "Unknown mode: " & mode
End Select

' 输出结构化错误并以非零代码退出，避免调用方把 VBScript 运行时错误误判为成功。
Sub Fail(ByVal exitCode, ByVal message)
  WScript.StdErr.WriteLine "ERROR; Code=" & exitCode & "; Message=" & message
  WScript.Quit exitCode
End Sub

' 列出所有已登录会话及其稳定定位信息；本过程只读取 SAP GUI 状态。
Sub ListSessions(ByRef guiApplication)
  Dim connectionIndex
  Dim sessionIndex
  Dim connection
  Dim session
  Dim sessionCount

  sessionCount = 0

  For connectionIndex = 0 To guiApplication.Children.Count - 1
    Set connection = guiApplication.Children(CInt(connectionIndex))

    For sessionIndex = 0 To connection.Children.Count - 1
      Set session = connection.Children(CInt(sessionIndex))
      PrintSession session, connectionIndex, sessionIndex
      sessionCount = sessionCount + 1
    Next
  Next

  If sessionCount = 0 Then
    Fail 4, "No logged-in SAP GUI session was found"
  End If
End Sub

' 输出单个会话的系统、客户端、用户、事务和窗口标题，供后续精确选择。
Sub PrintSession(ByRef session, ByVal connectionIndex, ByVal sessionIndex)
  WScript.Echo _
    "ConnectionIndex=" & connectionIndex & _
    "; SessionIndex=" & sessionIndex & _
    "; System=" & session.Info.SystemName & _
    "; Client=" & session.Info.Client & _
    "; User=" & session.Info.User & _
    "; Transaction=" & session.Info.Transaction & _
    "; Title=" & session.FindById("wnd[0]").Text
End Sub

' 判断会话是否与目标系统和客户端完全匹配；系统名比较不区分大小写。
Function SessionMatches(ByRef session, ByVal targetSystem, ByVal targetClient)
  SessionMatches = _
    StrComp(CStr(session.Info.SystemName), targetSystem, vbTextCompare) = 0 And _
    StrComp(CStr(session.Info.Client), targetClient, vbTextCompare) = 0
End Function

' 将非负整数参数转换为 SAP COM 集合索引；无效输入直接终止，避免选错会话。
Function ParseIndex(ByVal rawValue, ByVal argumentName)
  Dim indexPattern

  Set indexPattern = New RegExp
  indexPattern.Pattern = "^[0-9]+$"

  If Not indexPattern.Test(CStr(rawValue)) Then
    Fail 2, argumentName & " must be a non-negative integer"
  End If

  ParseIndex = CLng(rawValue)
End Function

' 在有限时间内等待 SAP 会话结束忙碌状态；超时后停止，避免脚本无限挂起。
Sub WaitUntilReady(ByRef session, ByVal maximumAttempts)
  Dim attempt

  For attempt = 1 To maximumAttempts
    If Not session.Busy Then
      Exit Sub
    End If

    WScript.Sleep 100
  Next

  Fail 7, "SAP GUI session remained busy for too long"
End Sub

' 在精确匹配的会话中打开事务；多个匹配会话时要求调用方提供明确索引。
Sub OpenTransaction(ByRef guiApplication, ByRef commandArguments)
  Dim targetSystem
  Dim targetClient
  Dim targetTransaction
  Dim transactionPattern
  Dim connectionIndex
  Dim sessionIndex
  Dim requestedConnectionIndex
  Dim requestedSessionIndex
  Dim useRequestedIndex
  Dim connection
  Dim session
  Dim targetSession
  Dim matchCount
  Dim commandField
  Dim modalWindow
  Dim actualTransaction

  If commandArguments.Count <> 4 And commandArguments.Count <> 6 Then
    Fail 2, "Usage: open <system> <client> <transaction> [connection-index session-index]"
  End If

  targetSystem = UCase(CStr(commandArguments(1)))
  targetClient = CStr(commandArguments(2))
  targetTransaction = UCase(CStr(commandArguments(3)))

  Set transactionPattern = New RegExp
  transactionPattern.Pattern = "^[A-Z0-9_/-]+$"

  If Len(targetSystem) = 0 Or Len(targetClient) = 0 Then
    Fail 2, "System and client are required"
  End If

  If Len(targetTransaction) = 0 Or Not transactionPattern.Test(targetTransaction) Then
    Fail 2, "Transaction contains unsupported characters"
  End If

  If Left(targetTransaction, 2) = "/N" Or Left(targetTransaction, 2) = "/O" Then
    Fail 2, "Pass the transaction code without an /n or /o command prefix"
  End If

  useRequestedIndex = commandArguments.Count = 6
  matchCount = 0

  If useRequestedIndex Then
    requestedConnectionIndex = ParseIndex(commandArguments(4), "connection-index")
    requestedSessionIndex = ParseIndex(commandArguments(5), "session-index")

    If requestedConnectionIndex >= guiApplication.Children.Count Then
      Fail 5, "Connection index is outside the current SAP GUI collection"
    End If

    Set connection = guiApplication.Children(CInt(requestedConnectionIndex))

    If requestedSessionIndex >= connection.Children.Count Then
      Fail 5, "Session index is outside the selected SAP connection"
    End If

    Set targetSession = connection.Children(CInt(requestedSessionIndex))

    If Not SessionMatches(targetSession, targetSystem, targetClient) Then
      Fail 5, "Selected session does not match system " & targetSystem & " and client " & targetClient
    End If
  Else
    For connectionIndex = 0 To guiApplication.Children.Count - 1
      Set connection = guiApplication.Children(CInt(connectionIndex))

      For sessionIndex = 0 To connection.Children.Count - 1
        Set session = connection.Children(CInt(sessionIndex))

        If SessionMatches(session, targetSystem, targetClient) Then
          Set targetSession = session
          matchCount = matchCount + 1
        End If
      Next
    Next

    If matchCount = 0 Then
      Fail 5, "No session matches system " & targetSystem & " and client " & targetClient
    End If

    If matchCount > 1 Then
      Fail 6, "Multiple sessions match; run list and pass connection-index and session-index"
    End If
  End If

  If targetSession.Busy Then
    Fail 7, "Selected SAP GUI session is busy"
  End If

  Set modalWindow = targetSession.FindById("wnd[1]", False)

  If Not modalWindow Is Nothing Then
    Fail 8, "Selected session already has a modal window: " & modalWindow.Text
  End If

  Set commandField = targetSession.FindById("wnd[0]/tbar[0]/okcd", False)

  If commandField Is Nothing Then
    Fail 8, "Transaction command field is not available in the selected session"
  End If

  commandField.Text = "/n" & targetTransaction
  targetSession.FindById("wnd[0]").SendVKey 0
  WaitUntilReady targetSession, 300

  Set modalWindow = targetSession.FindById("wnd[1]", False)

  If Not modalWindow Is Nothing Then
    Fail 8, "SAP displayed a modal window after opening the transaction: " & modalWindow.Text
  End If

  actualTransaction = UCase(CStr(targetSession.Info.Transaction))

  If StrComp(actualTransaction, targetTransaction, vbTextCompare) <> 0 Then
    Fail 9, "Transaction did not open; actual transaction is " & actualTransaction
  End If

  WScript.Echo _
    "OK; System=" & targetSession.Info.SystemName & _
    "; Client=" & targetSession.Info.Client & _
    "; Transaction=" & targetSession.Info.Transaction & _
    "; Title=" & targetSession.FindById("wnd[0]").Text
End Sub
