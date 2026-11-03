# URLSession Background Sessions: Behavior and Capability Differences

Sources: disassembly of the iOS dyld shared cache (CFNetwork `__NSURLBackgroundSession`, `__NSCFBackgroundSessionTask`, `__NSCFURLSessionDelegateWrapper`; Binary Ninja addresses from the DSC build) and experiments in the iPhone 18 Pro iOS 27.0 simulator against local firewalk (`127.0.0.1:8080`). Harness: `App/main.swift`, `build.sh`, `run.sh`; logs in `output/`.

Per-delegate-method and per-task-type foreground vs background comparison: [URLSession-Delegate-Foreground-vs-Background.md](URLSession-Delegate-Foreground-vs-Background.md).

**Caveats.** Client-side code comes from the DSC (24A446). The daemon (`nsurlsessiond`, 24A446) was disassembled separately, see "Daemon-side analysis". The simulator runtime is 24A434, so its daemon may differ slightly from the disassembled one. App suspension/relaunch (wake) behavior was not exercised, because the simulator can't suspend the app the way a device does.

## Architecture

- `NSURLSession` with a background configuration becomes `__NSURLBackgroundSession`. Its tasks are `__NSCFBackgroundData/Download/UploadTask`.
- The client does no networking. It talks to `nsurlsessiond` over XPC (`createSessionWithConfiguration:…`, `resumeTaskWithIdentifier:withProperties:`, `cancelTaskWithIdentifier:`, `suspendTaskWithIdentifier:`). Every callback comes back as a `backgroundTask:…` XPC message, hops to the session queue, and goes through the shared `__NSCFURLSessionDelegateWrapper`.
- The session `createSession…` call is synchronous. At setup the client sends the daemon a **delegate-options** dictionary (`delegateOptions`, 0x18ce2e720) with six keys: WillBeginDelayedRequest, WillPerformRedirection, DidReceiveResponse, SessionAuthChallenge, TaskAuthChallenge, and WillSendRequestForEstablishedConnection. The daemon uses it to decide which callbacks are worth sending.
- Resume sends a property dict: `earliestBeginDate`, expected byte counts, the task-level resource timeout, cookies, `disableRetry`, and so on. `earliestBeginDate` is therefore enforced by the daemon.

## Delegate callbacks compared with default (foreground) sessions

| Callback | Background session behavior | Evidence |
|---|---|---|
| `willBeginDelayedRequest` | Fires for **every** task (even with no `earliestBeginDate`, or one in the past), right after start, on a background thread. With `earliestBeginDate` it fires when the date is reached. Foreground sessions fire it only for a delayed task. | `data`, `delayed` (2.078s for +2s), `delayedPast`, `multi` |
| `willBegin` disposition `.cancel` | The task completes with `-999`, `txns=0` metrics. | `delayedCancel` |
| `willPerformHTTPRedirection` | **Never called by default.** Redirects are followed automatically (cookies applied, auth header stripped when absent on the original). It is called only if the private `_overridesBackgroundSessionAutoRedirect` is set. Metrics still report `redirects=2`. | `redirect`; 0x18ced3af8 |
| `didReceiveChallenge` (task) | Called normally (Basic auth). | `auth` |
| `didReceiveResponse` | Called for data tasks. Not called for download tasks. | `data`, `download` |
| `didReceiveData` | Data tasks: normal. **Upload tasks:** the response body is written to a file by the daemon and delivered as one chunk (120611 B) after being read back (0x18ced450c). | `upload` |
| `didSendBodyData` | Called. | `upload` |
| Download `didWriteData` / `didFinishDownloadingTo` | Called. A 404 still "finishes" with an empty file and a nil error. A nil location becomes `-3000` (`NSURLErrorCannotCreateFile`). | `download404` |
| `didFinishCollecting` | Called before `didCompleteWithError`, including cancelled tasks (zero transactions). | all |
| `didCompleteWithError` | Always called once per task. | all |
| `taskIsWaitingForConnectivity` | **Never fired** in any experiment, even with `waitsForConnectivity = true` and an unreachable port or host. The daemon overrides the client's `waitsForConnectivity` to NO (see "Daemon-side analysis"). The client plumbing exists (`backgroundTask:hasConnectionWaitingWithError:`, 0x18ced3e40, forwarding to `task:_isWaitingForConnectionWithError:`), and the public callback is gated on the delegate implementing it. | `waits`, `badhost` |
| `didBecomeInvalidWithError` | Called with nil after `finishTasksAndInvalidate`, and after `invalidateAndCancel`. | `invalidate*` |
| `URLSessionDidFinishEventsForBackgroundURLSession` | Only sent when the app is woken, after `backgroundSessionDidFinishAppWake` (0x18ced5b30). Not observed in the foreground. | — |

## Timeouts and failures

- **Unreachable target (`127.0.0.1:1` or `.invalid` host):** the error is **`-1001` timed out**, not `-1004` or `-1003`. Without `waitsForConnectivity` it takes about 11 s. With `waitsForConnectivity` and `timeoutIntervalForResource = 6` it takes about 6.5 s, which is the resource timeout. There is no `taskIsWaitingForConnectivity` in either case. The daemon forces `waitsForConnectivity` off, so the NO-case timing is consistent. Why the failure surfaces as `-1001` rather than a connection error was not decoded.
- **`timeoutIntervalForRequest = 2` with a server that responds after 8 s:** the request still succeeded after 8 s, so the request timer is not enforced as an idle timeout here.
- **`timeoutIntervalForResource = 2`:** fails at about 2.2 s with `-1001`.
- **`earliestBeginDate` + `timeoutIntervalForRequest = 1`:** the delay (3 s) is not counted against the timeout and the task succeeds.
- **`downloadTask(withResumeData:)` with invalid data:** fails at once with `-3003` (`NSURLErrorCannotWriteToFile`), and no `willBegin` fires.
- **`uploadTask(withStreamedRequest:)`:** `willBegin` fires, then the task is cancelled with `-999`. Streamed bodies are not supported, and no exception is thrown.
- **Disconnect from the daemon:** tasks fail with `-997` (`BackgroundSessionWasDisconnected`). If the private `_allowsRetryForBackgroundDataTasks` is set, data tasks are retried. `-996` (`BackgroundSessionInUseByAnotherProcess`) invalidates the session.

## Task lifecycle

- **Suspend/resume:** `suspend()` set state to suspended immediately. A resumed task restarts from the point of resume, because the 2 s response only arrived after `resume()`.
- **Never-resumed tasks:** they appear in `getAllTasks` with state suspended.
- **`cancel()`:** completes the task with `-999` after `didFinishCollecting`.
- **`getTasksWithCompletionHandler`:** reports the task, and it is delivered before `willBegin`.
- **Same identifier, two sessions in one process:** only the first session's task was started, and its delegate got the callbacks. The second session was not exercised with a task, so its behavior is unverified. Avoid duplicate identifiers.
- **Reconnect after exit:** a 200 B download finished before the app could exit, so the relaunch scenario found 0 tasks. The run does not exercise reattachment.
- **Concurrency:** `multi` with `httpMaximumConnectionsPerHost = 1` ran the three tasks serially, in order.
- **`isDiscretionary`:** no visible difference in the simulator, because there are no system conditions to gate on.
- **No delegate:** the task is accepted and no callbacks can occur. The daemon would still run it.

## Unsupported APIs (all throw `NSGenericException` and crash the app)

| API | Reason string |
|---|---|
| Any `…completionHandler:` task factory (data/download) | Completion handler blocks are not supported in background sessions. Use a delegate instead. |
| `uploadTask(with:from: Data)` | Upload tasks from NSData are not supported in background sessions. |
| `task.delegate = …` | Task delegate is not supported on background session task |
| `webSocketTask(…)` | WebSocket tasks are not supported in background sessions |
| `streamTask(…)` | Stream tasks are not supported in background sessions |
| AVAssetDownloadURLSession without the media-asset-download entitlement | NSGenericException at setup (from disassembly) |

Also from disassembly: custom `NSURLRequest` subclasses throw `NSInvalidArgumentException`, and a nil identifier is rejected ("Background session configuration must have a non-nil identifier"). An **empty-string** identifier did not crash in the simulator.

## Lifecycle and app wake (from disassembly only)

- The session observes `UIApplicationDidEnterBackground` (drops the daemon's "boost"), `WillEnterForeground` (boost), and the private `…AppWasResumedForBackgroundSession` notification.
- It registers a `com.apple.nsurlsessiond.started` notify handler to reconnect after a daemon restart.
- `backgroundSessionDidStartAppWake` / `DidFinishAppWake` bracket a wake, and the finish is deferred while auth-header requests are outstanding.
- `URLSessionDidFinishEventsForBackgroundURLSession` is delivered only from the app-wake-finish block, so a foreground app never sees it.

## Daemon-side analysis (`nsurlsessiond`, build 24A446, disassembled)

The daemon is itself an `NSURLSession` client. Addresses are from the 24A446 `nsurlsessiond` binary.

**Session class** (`-[NDSessionManager createSessionWithConfiguration:…]`, 0x1000040e8): AV asset downloads get `NDAVBackgroundSession`. Otherwise `usesClassicLoadingMode` selects `NDBackgroundSession` (classic CFNetwork loader), and its absence selects `NDNWBackgroundSession` (Network.framework loader). Which one the simulator used was not determined.
- A connect to an identifier that already has a connected client fails with `-996` plus `kNSURLSessionImmediateInvalidationError`.
- An existing identifier with no connected client is reconnected: options are updated and `getTasksForReconnection` supplies the task list.
- An extension without a shared container identifier fails with `-995`.

**Why `taskIsWaitingForConnectivity` never fired.** Both session classes build their configuration (0x100048b60 NW, 0x1000074bc classic) by copying selected client settings onto a fresh default configuration, and both call `setWaitsForConnectivity:NO`.
- Also set: cookie storage and URL cache nil (cookies are handled client-side), `preventsIdleSleepOnceConnected = YES`, and `networkServiceType = background` when the app can be suspended (unless feature flag `CFNetwork/background_session_default_network_service_type` is on).
- `timeoutIntervalForRequest` is copied. `timeoutIntervalForResource` is copied when non-zero.
- The classic session still forwards the loader's private waiting event: `URLSession:task:_isWaitingForConnectionWithReason:` (0x1000413f4) sends `backgroundTask:hasConnectionWaitingWithError:` with an `NSTCPConnectionConditionsUnmetReasonErrorDomain` error. The client then calls the public delegate method only if the delegate implements it. Whether the loader emits that event with `waitsForConnectivity` off was not determined, so a waiting callback is possible in principle on the classic path only.

**Delayed requests.**
- `handleEarliestBeginDate…` (0x10000a2b4, classic): with no date or a past date, it continues immediately. Otherwise it sets `resumedAndWaitingForEarliestBeginDate` and uses `dispatch_after` at the date. When the timer fires it re-checks that the task and its info still exist, and ignores stale timers.
- The NW path (`_resumeTask:` 0x10004f64c) starts the `NDTaskMonitor` at resume only when `earliestBeginDate` is nil. Otherwise the monitor is started when the delayed-request step completes.
- `willBeginDelayedRequest` (0x100054564 NW, 0x10000a6f0 classic) is sent **at most once per task** (`respondedToWillBeginDelayedRequestCallback`), as XPC `backgroundTask:willBeginDelayedRequest:reply:` (callback type 9).
- The daemon skips it and continues loading unchanged in two cases: the client's delegate options didn't declare it, or the client isn't running and the app doesn't support wakes ("client is not running and doesn't support wakes, continuing load").
- If the client isn't running but the app supports wakes and the session sends launch events, the callback is queued with wake requirement 2, which can relaunch the app.

**Callback queue and app wake** (`NDCallbackQueue`, `performCallback:` 0x100017910). Types: 0 didComplete, 2 challenge, 3 start app wake, 4 finish app wake, 5 willSendRequestForEstablishedConnection, 6 open file, 9 willBeginDelayedRequest, 0xa auth headers, plus AV asset types. If a client proxy is connected the callback is sent immediately. Otherwise it is held, and `wakeUpClient:` may relaunch the app. A wake is **not** attempted if any of these hold:
- the wake requirement is 0 (**completion alone never wakes the app**);
- `sessionSendsLaunchEvents` is NO;
- the app doesn't support wakes (a later `performWake:uponNotification:` registration with `NDUserEventAgentConnection` is made if it may later);
- the session is obliterated;
- the client is already connected;
- background updates (Background App Refresh) are disabled.

Otherwise the daemon queues a start-wake callback at the front and a finish-wake callback at the back, then asks the application proxy to wake it. A failure logs "Failed to wake app". `didFinishEventsForBackgroundURLSession` comes from the finish-wake callback.

**Redirects** (0x1000555bc). With a connected client the daemon sends `willPerformHTTPRedirection`. Without one it follows the redirect itself. The client auto-follows unless `_overridesBackgroundSessionAutoRedirect` is set, matching the experiment. A redirect target blocked by the tracker policy (`errorIfBlockedTracker:url:`, `_ne_tracker_check_is_hostname_blocked`) cancels the task with `NWURLError` `-1004`.

**Task scheduling.**
- `startTasksIfAllowed` (0x10004c694, NW) starts waiting tasks only while fewer than 8 are active, so about **8 tasks run concurrently per session**, and the rest wait in the daemon. `HTTPMaximumConnectionsPerHost` can lower that further.
- `NDTaskMonitor` records transferred bytes in 1 s buckets. After 10 buckets and 15 s, `calculateThroughput` compares the average rate with `currentThroughputThreshold`. If it is lower, the session's `taskMonitor:retryTask:reason:` calls `stopAndRetryWithError:` with `NWURLError -999`. Whether the retry is visible to the app was not determined.

**Completion** (0x1000563bc). The daemon stores metrics and trailers, queues the completion callback with wake requirement 0, suppresses the wake when the error is in the `_nsurlsessiond` domain or is -997 and the client can be suspended, deletes upload temporary files, and keeps the downloaded file only when the error carries resume data. It then starts any waiting tasks.

**Entitlement sanitizing** (`copyAndSanitizeClientConfiguration:` 0x100003968). Without the matching private entitlement, the daemon silently clears `_sourceApplicationBundleIdentifier`, `_respectsAllowsCellularAccessForDiscretionaryTasks`, `_allowsPowerNapScheduling`, `_connectionPoolName`, `_duetPreauthorized` and `_maximumWatchCellularTransferSize`. It also restricts `_directoryForDownloadedFiles` and `pathToDownloadTaskFile` to safe locations unless the daemon is privileged.

**Not yet decoded:** discretionary scheduling details, `cancelTasksRequiringClientConnectionAndResumeUnstartedTasks`, and the full pending-callback replay on reconnect.

## Practical conclusions

1. `willBeginDelayedRequest` is not a signal of an actual delay on a background session. It fires for every task, and it is the only way to modify or cancel a request before it starts.
2. Don't rely on `willPerformHTTPRedirection` or `taskIsWaitingForConnectivity` for background sessions. The daemon forces `waitsForConnectivity = NO`.
3. Network failures surface as `-1001` after the resource timeout, not as fast `-1004` failures. Set `timeoutIntervalForResource` deliberately.
4. Use delegate-based, file-based tasks only. Wrap factory calls defensively, because violations crash.
5. Not verified: wake relaunch, long-lived reconnect, and device-only behavior.
