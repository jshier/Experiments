# URLSession delegate behavior: foreground vs background sessions

Companion to [URLSession-Background-Sessions-Report.md](URLSession-Background-Sessions-Report.md) (architecture, daemon, app wake).

**Scope:** every `URLSession*Delegate` method × every task type, default (foreground) vs `.background(withIdentifier:)` session.

**Sources**
- **Disassembly:** iOS 27.0.x (24A446): the dyld shared cache client (`__NSURLBackgroundSession`, `__NSCFLocalSessionTask`) and `nsurlsessiond`. Addresses are DSC unless prefixed `d:`.
- **Experiment:** `App/main.swift`, iOS 27.0 simulator (24A434), local firewalk server. Each scenario ran in both modes (`./run.sh <name>` and `SUFFIX=.fg ./run.sh <name> fg`). Logs are in `output/` (`*.fg.log` is foreground).
- **Tags:** **[E]** observed in the experiment. **[D]** disassembly only. Both tags means the two agree.

**Limits.** The simulator was used, so wake and relaunch behavior is untested. Firewalk has no Range, 1xx or response-size >100 KB support. Resume data and informational responses are therefore **[D]** only. AV-asset tasks are not covered.

## 1. How the paths differ

- **Foreground:** the task talks to the loader in-process. `__NSCFLocalSessionTask` interprets dispositions itself.
- **Background:** each callback hops through `nsurlsessiond` over XPC. The client handler (`-[__NSURLBackgroundSession backgroundTask:…]`) dispatches to the session queue and calls a wrapper (`task+0x2a0`, else `+0x298`). The wrapper checks `respondsToSelector:` and calls `runDelegateBlock:`.
  - The daemon owns the real `NSURLSession`. Its configuration has no cookie storage, no URL cache and `waitsForConnectivity = NO` (`d:0x100048b60`). The app process keeps cookies and credentials.
  - The client forwards the delegate's raw integers (dispositions, challenge results) to the daemon. It never interprets them. [D]

## 2. Method × behavior matrix

"Same" means the call order, arguments and results matched in the experiment. Task types: **D** data, **U** upload (`fromFile:`), **DL** download, **S** stream, **WS** web socket.

### Session-level and task-level callbacks

| Delegate method | Foreground | Background | Evidence |
|---|---|---|---|
| `didBecomeInvalidWithError` | after in-flight tasks end, error nil | same. **Client-driven**: the app sends `invalidateWithReply:` and runs the callback itself. The daemon's own method only logs (`d:0x100054278`) | [E][D] |
| Create a task after `finishTasksAndInvalidate` | throws `NSGenericException` "Task created in a session that has been invalidated" | **no throw**; only `didBecomeInvalid(nil)` was logged in the 2 s window (task outcome not observed beyond that) | [E] |
| `urlSession(_:didReceive:)` (session challenge) | called for server-trust / connection-level challenges | the daemon has no session-level method. Session challenges arrive through the task method. The client picks the session delegate if `isSessionChallenge` and it is implemented (`0x18ced34c8`). The daemon answers default handling itself when the client implements neither level | [D] |
| `task:didReceive:` (challenge) | called | called. All four dispositions behave the same (`useCredential` 200, `cancel` -999, `performDefaultHandling` 401, `rejectProtectionSpace` 401). POST-with-file retry resends the body: two `didSendBodyData`, `prevFailures=0` | [E] |
| Challenge, extra background behavior | none | (a) if the client substituted a stored default credential into the challenge and the delegate answers `.performDefaultHandling`, the reply is rewritten to `.useCredential` with that stored credential (`0x18ced36e4`). (b) With no client and wakes impossible, the daemon default-handles. (c) An unanswered challenge is auto-cancelled (`(2,nil)`) when drained | [D] |
| `willBeginDelayedRequest` | **never** fires, because `earliestBeginDate` is ignored (`delayed`: task ran at once) | fires for **every** task, once, even with no `earliestBeginDate`. `.cancelRequest` → -999 | [E][D] |
| `taskIsWaitingForConnectivity` | fires with `waitsForConnectivity = true` against an unreachable host | **never** fires. The daemon forces `waitsForConnectivity = NO` and the client never calls the public selector (only the SPI `_isWaitingForConnectionWithError:`) | [E][D] |
| `willPerformHTTPRedirection` | called per hop (`/redirect/2`: 2 calls). Returning `nil` stops the redirect: the app gets the 302, no body | **never called**; auto-follows. Returning `nil` is impossible. The delegate is consulted only if `_overridesBackgroundSessionAutoRedirect` is set (`0x18ced3af8`) | [E][D] |
| `didReceiveInformationalResponse` | per 1xx | forwarded through XPC (`0x18ced3f24`), no gating seen | [D] |
| `needNewBodyStream` | called for `uploadTask(withStreamedRequest:)` | called, same call. `needNewBodyStreamFromOffset:` is reachable only as an offset-0 fallback; the daemon never asks for an offset | [E][D] |
| `didSendBodyData` | called | called. Same totals, including the auth-retry resend | [E] |
| `didFinishCollecting` (metrics) | called, also for failed tasks | called, but **skipped when metrics are nil**. Failures such as an unsupported scheme or resume-data errors deliver no metrics (`badScheme`) | [E][D] |
| `didCompleteWithError` | called | called. See the error and property differences in §3 | [E] |
| Silent retry | none | a data task failing with -997 (daemon lost the client) is retried without a callback if `_allowsRetryForBackgroundDataTasks` (`0x18ce60664`) | [D] |

### Data-task callbacks (D; U for responses)

| Delegate method | Foreground | Background | Evidence |
|---|---|---|---|
| `didReceive response` | called | called, same | [E] |
| Disposition `.cancel` | -999; `recv=0` | same | [E] |
| Disposition `.becomeDownload` | `didBecomeDownloadTask` (state at call: suspended), then download callbacks | same callbacks (state at call: running). The daemon performs the conversion | [E] |
| Disposition `.becomeStream` | `didBecomeStreamTask` fires | **cancelled -999**; `didBecomeStreamTask` never fires. No client or daemon code can deliver it | [E][D] |
| `didReceive data` chunking | multiple chunks (100 KB: 2) | one chunk (100 KB: 1). The daemon forwards what its own NSURLSession gives it, without coalescing | [E][D] |
| `willCacheResponse` | called after the data, **even when the response was cancelled** | **never called.** No client handler exists; the daemon passes through and its URL cache is nil | [E][D] |
| `didBecomeDownloadTask` | as above | as above. Only for `taskKind==2`; an upload's response-to-file does not send it | [E][D] |
| `didBecomeStreamTask` | see above | never | [E][D] |

### Upload (U) specifics

| Behavior | Foreground | Background | Evidence |
|---|---|---|---|
| Response delivery | `didReceiveResponse` then chunked `didReceiveData` | the daemon turns the response into a download file. The client **reads the whole file, delivers one `didReceiveData`, then deletes it**. **`didReceiveResponse` is not called**; the response is only available as `task.response`. (12 MB echo: one 12 MB chunk vs 61 chunks.) Memory scales with response size | [E][D] |
| Upload from `Data` (`uploadTask(with:from:)`) | works | throws `NSGenericException` | [E] |
| Streamed upload | `needNewBodyStream`, then -1103 with my stub body | same, -1103 | [E] |

### Download (DL) specifics

| Behavior | Foreground | Background | Evidence |
|---|---|---|---|
| `didReceiveResponse` | **not called** for download tasks | not called | [E] |
| `didWriteData` | called | called. Only forwarded for `taskKind==0` | [E][D] |
| `didFinishDownloadingTo` location | app `tmp/` | `Library/…/Downloads/<bundle id>/` | [E] |
| File lifetime | deleted after the delegate returns (`exists`=false 0.4 s later) | same. The client unlinks the file after the wrapper returns unless `_pathToDownloadTaskFile` is set | [E][D] |
| Non-2xx status (404/400) | `didFinishDownloadingTo` with an empty body, then complete with nil error | same | [E] |
| `didResumeAtOffset` | called on resume | forwarded only if the daemon task is `expectingResumeCallback` | [D] |
| Resume-data failure (`downloadTask(withResumeData:)` with junk) | -1002; **task id differs** (2) | -3003; no metrics | [E] |
| Resume data on failure | in `NSURLSessionDownloadTaskResumeData` | same key, plus the file is moved to a temp location (`moveFileToTempForBackgroundResumeData:`). The daemon deletes the file only when there is no resume data | [D] |

### Stream (S) and web-socket (WS) tasks

| Delegate method | Foreground | Background | Evidence |
|---|---|---|---|
| `streamTask(withHostName:port:)`, stream delegates | `readClosed`, `writeClosed` fired; the task completes with nil, id 0 | `NSGenericException` "Stream tasks are not supported in background sessions" | [E] |
| `webSocketTask(with:)`, `didOpenWithProtocol`, `didCloseWith` | open and close 1000, then completes with status 101 | `NSGenericException` "WebSocket tasks are not supported…" | [E] |
| `didBecomeInputStream` / `betterRouteDiscovered` | not exercised | n/a | – |

### App-wake and session lifecycle

| Delegate method | Foreground | Background | Evidence |
|---|---|---|---|
| `urlSessionDidFinishEvents(forBackgroundURLSession:)` | never | only after an app wake (`DidFinishAppWake`, `0x18ced53fc`); it never fired in any simulator run | [D] |
| `application(_:handleEventsForBackgroundURLSession:)` | n/a | wake only. Not testable in the simulator | [D] |

## 3. Behavior outside callbacks

| Behavior | Foreground | Background | Evidence |
|---|---|---|---|
| `earliestBeginDate` | ignored | honored (daemon timer) | [E][D] |
| Unreachable host, `waitsForConnectivity` on or off | on: waiting callback, then -1001 after `timeoutIntervalForResource`. Off: **-1004 / -1003 immediately** | **-1001 after the timeout in every case** (6.6 s with the short test timeout, 10.7 s without waits). `waitsForConnectivity` is forced off. The daemon sets `_automaticRetry = 1` and a scheduling delay on its tasks (`configureTask:withTaskInfo:`, `d:0x10004c00c`), which are probable but unconfirmed causes of the -1001 | [E] cause [D, unconfirmed] |
| Bad scheme (`foo://x/y`) | -1002; `originalRequest` kept; metrics delivered | -1002; **`originalRequest`/`currentRequest` nil**; no metrics | [E] |
| HTTP cache | `URLCache` used. A repeat request reported `fetchType=3` (local cache) | no cache. Every request was `fetchType=1` | [E] |
| Cookies | stored and applied | same, in the app process. `Set-Cookie` landed in shared storage, and was sent on the next request | [E][D] |
| Un-resumed task in `getAllTasks` | not returned (0) | returned (1, state suspended) | [E] |
| `suspend()`/`resume()` | works | works. State is local; `backgroundTaskDidSuspend` sets suspended | [E][D] |
| `cancel()` of a running task | -999, state `.canceling` | same | [E] |
| Completion-handler task factories | work | `NSGenericException` | [E] |
| `task.delegate` (per-task delegate) | works | `NSGenericException` | [E] |
| No delegate | task runs, results discarded | `URLSession(configuration:)` with no delegate does **not** throw in this run; the task ran, nothing observable | [E] |
| Empty identifier | accepted (default config) | accepted at construction (not an error here) | [E] |

## 4. Differences that matter

1. **Absent in background:** `willCacheResponse`, `didBecomeStreamTask`, `taskIsWaitingForConnectivity`, `willPerformHTTPRedirection` (unless the private override is set), `didReceiveResponse` for uploads, and the stream and web-socket delegates.
2. **Background only:** `willBeginDelayedRequest`, `urlSessionDidFinishEvents`, and `earliestBeginDate` support.
3. **Thrown, not delivered:** stream, web-socket, completion-handler, `Data` upload and `task.delegate` all throw `NSGenericException` in background sessions.
4. **Dispositions.** `.becomeStream` degrades to -999. A redirect cannot be refused.
5. **Error codes.** Offline background tasks fail with -1001, never -1004/-1003, even with `waitsForConnectivity` off.
6. **Upload responses** arrive as one `didReceiveData` (read from a file, no `didReceiveResponse`). The data chunking differs.
7. **Cache.** No `URLCache` and no `willCacheResponse`.
8. **Task properties.** A failed background task may leave `originalRequest` nil and deliver no metrics.
9. **Invalidated sessions** swallow new tasks silently instead of throwing.

## 5. Caveats and open items

- **Not tested:** wake/relaunch, `didFinishEvents`, `handleEventsForBackgroundURLSession`, resume data, 1xx responses, AV-asset tasks, discretionary scheduling effects (`discretionary` behaved the same here), device-only networking (cellular, `allowsCellularAccess`).
- **`-997` retry** and the **challenge auto-answers** are disassembly-only (they need the client to disappear).
- Daemon class selection is confirmed (`d:0x1000040e8`): `NDNWBackgroundSession` (default), `NDBackgroundSession` (classic loading mode), `NDAVBackgroundSession`.
- `willBeginDelayedRequest` reply block (`d:0x100054a74`) is verified: `.useNewRequest` with a request sets the current request; every disposition then marks the callback as responded and is forwarded unchanged to the daemon's session (`.cancelRequest` cancels).
- Redirect reply (`d:0x1000559c8`) forwards a nil request unchanged (don't follow), only reachable when `_overridesBackgroundSessionAutoRedirect` is set.
- Wake suppression (`d:0x100017688`, `d:0x1000563bc`): the wake is suppressed when the error is in the `_nsurlsessiond` domain or is NSURLError -997, and the client can be suspended.
- A separate XPC path, `willRetryBackgroundDataTask:withError:transactionMetrics:` (`0x18ced4390`), reaches the private `URLSession:_willRetryBackgroundDataTask:withError:` delegate method with a -1005 error. This is the private -997 retry (`0x18cece840`); it is not public API.
- The `-1001` cause, `.becomeDownload` task state, the foreground `didResumeAtOffset`/`didReceiveInformationalResponse` paths, and nil-redirect behavior remain unexercised.
- Experiments reused a persistent shared URLCache, so foreground `/get` runs may show `fetchType=3` (local cache).
- Daemon callback types 5, 6, 0xa, 0xb and 0xc: queueing paths not traced. Type 1 (download/upload-response file finished) is now identified.
- Whether the daemon's NSURLSession would act on disposition 3: the experiment shows cancel (-999).
- Why background data arrives as a single 100 KB chunk is not established: the daemon does no coalescing in the code read, so it comes from the daemon's loader or the XPC path.
- Firewalk limits (>100 KB returns 400) kept the large-body tests at 100 KB (data/download) and 2 MB (upload).
