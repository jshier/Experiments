# URLSession delayed tasks: `willBeginDelayedRequest` and `taskIsWaitingForConnectivity`

Method: static analysis of the iOS 27.0.x dyld shared cache (24A446) with Binary Ninja, backed by runtime experiments in this directory.
The experiments ran on macOS 27.0.1 (26A434) against firewalk (`127.0.0.1:8080`).
Addresses are from the iOS DSC. macOS 27 may differ, so treat addresses as pointers rather than guarantees.
Raw experiment output is in `output/`: `nw/`, `nw-wfc/`, `classic-wfc/` and loose files.
Harness: `Sources/DelayedTaskExperiment/main.swift`, run with `.build/debug/DelayedTaskExperiment <scenario>`.
Set `CFN_USE_NW_LOADER=1` to select the NW loader.

## 1. Key finding: three loading stacks behave differently

| Stack | Task class | When selected | `earliestBeginDate` / `willBeginDelayedRequest` | `taskIsWaitingForConnectivity` |
|---|---|---|---|---|
| Classic CFNetwork (**default today** for foreground sessions) | `__NSCFLocalDataTask` | default | **Ignored.** The task starts immediately and the delegate is never called (callers of `__NSCFURLSessionDelegateWrapper task:willBeginDelayedRequest:` exist only for background-session and AV asset paths). | Works, once per task. |
| NW loader | `NWURLSessionDataTask` | `CFN_USE_NW_LOADER=1`, a `ForceNWLoader.plist`, feature flag `CFNetwork/nw_loader_third_party_apps` (non-`com.apple.` apps), or `!usesClassicLoadingMode` | **Honored.** | Works, once per task. |
| Background session | `__NSCFBackgroundDataTask` | `URLSessionConfiguration.background` (the daemon `nsurlsessiond` owns the timer) | Honored. The callback arrives about 2.015 s after resume on a background thread. | Not delivered in simulator tests. The daemon forces `waitsForConnectivity` off (see the background-sessions report). |

`_CFNUseNWLoader` (block at 0x18cd8c018) checks, in order:
- env `CFN_USE_NW_LOADER`: "1" enables, "0" disables;
- the development ForceNWLoader.plist (keyed by progname);
- the feature flag, for third-party apps whose `LSBundleRecord.developerType == 3`.

`-[NSURLSessionConfiguration _usesNWLoader]` is `!usesClassicLoadingMode`.
`proxiesRequireNWLoader` forces the NW loader when `nw_proxy_config_stack_requires_http_protocols` is true.

Practical consequence: an app can see different delayed-task behavior depending on which stack the OS picks.
Today a foreground session ignores `earliestBeginDate`. The NW loader honors it.

## 2. `urlSession(_:task:willBeginDelayedRequest:completionHandler:)`

### 2.1 What delays a task, and what starts it

The only trigger is `URLSessionTask.earliestBeginDate`. It is a plain atomic copy property at offset 0x238.
`waitsForConnectivity` does not delay the start. It only affects what happens after a connection attempt is unsatisfied (§3).

Flow, NW loader:
1. `-[NWURLSessionTask resume]` (0x1827e5f80) dispatches async onto the task queue (block 0x1827e6b24).
   - It sets state=1 (suspended) and calls `-[NWURLSession taskStarted:]`. Because it is async, `task.state` reads **1** right after `resume()` returns (classic reads 0).
   - It computes `earliestBeginDate.timeIntervalSinceNow`.
2. If the delay is ≤ 0 (a past date), it runs the completion block `.25` (0x1827e6e68) immediately. **There is no delegate call.**
3. If the delay is > 0, `dispatch_after(delay)` runs the `startDelayTimer:completionHandler:` block (0x182f6c1e0).
   - If the task state (+0x138) is 2 (completed, for example after cancel), the block skips everything and the delegate is not called.
   - Otherwise it reads `currentRequest`, then calls `delegateFor_willBeginDelayedRequest` (0x1831bbf54).
   - If the delegate lacks the method, the completion runs with (0, nil), meaning continue. The delay is still honored with no callback.
   - Otherwise it creates an `NWURLSessionDelegateDeallocBomb` and calls the delegate on the delegate queue (`NWURLSessionDelegateWrapper task:willBeginDelayedRequest:completionHandler:`, invoke 0x1831bcf64, invoke_2 0x1831bd03c).
4. Completion handler (0x182f6c514), by disposition:
   - `.continueLoading` (0) continues.
   - `.useNewRequest` (1) stores the request in the copy property at +0x40. A **nil** request is treated as cancel.
   - `.cancel` (2) completes the task with `NSURLErrorDomain -999`. The same happens for `useNewRequest` with a nil request.
5. Continuation, block `.25`, which runs after the handler is called:
   - checks `_startTimeoutDate` and creates the start timer, error -1001, if it has already passed;
   - starts the resource timer (`startResourceTimer` / `createTimerWithTimeout:`, from `timeoutIntervalForResource`);
   - calls `restartRequestTimer`, `prepareNextRequest:forTask:error:` and `startNextLoad` (0x1827e6304).

So a delayed task starts when:
- the delay timer fires **and**
- the delegate has called the completion handler. There is no framework-side timeout on the handler.

Events that end a delayed task early:
- `cancel()`, which gives -999 with no delegate call;
- the session being invalidated;
- the delegate returning `.cancel`.

### 2.2 Timeouts and the delay

The request timer and the resource timer both start **after** the delay and after the completion handler is called, not at `resume()`.

| Experiment (NW loader) | Result |
|---|---|
| delay 5 s, `timeoutIntervalForRequest` 2 s | No timeout. The request ran after the delay. |
| delay 5 s, `timeoutIntervalForResource` 3 s | No timeout. |
| delay 2 s, resource 3 s, URL `/delay/3` | -1001 at t≈5.04 s (3 s after the delay ended). |
| Handler called 3 s late | The request started only after the handler fired (≈5.26 s). No timeout. |
| `cancel()` during the delay | -999. `willBegin` never fires. Metrics are nil. |
| Suspend during the delay | `willBegin` still fires, with `task.state==1`. The request proceeds. The response arrives while suspended, and `didCompleteWithError` is deferred until `resume()`. |
| `useNewRequest` | The response URL was the replacement (`/get?replaced=1`). |
| `.cancel` disposition | -999 about 6 ms later. The userInfo keys are `NSErrorFailingURLKey` and `NSLocalizedDescription`. |

Consequence: the resource timeout (default 7 days) does not bound the total wall-clock time of a delayed task.
The only overall bound is `earliestBeginDate` plus the timeouts.
The delay timer is not subject to the 1.6e7 s cap that `createTimerWithTimeout:` applies. That cap applies to the request and resource timers.

Metrics quirk: `fetchStartDate` is about 0.01 s (at `resume()`), but `requestStartDate` is at about the delay end.

### 2.3 Failure modes and API misuse

The completion handler is guarded by `NWURLSessionDelegateDeallocBomb` (the classic path uses `__NSCFDeallocBomb`). Both misuses below **crash the process** (SIGABRT, `abort_with_payload`):

| Misuse | Crash message | Crash site |
|---|---|---|
| Handler released without being called (for example the delegate drops it) | `API MISUSE: NSURLSession delegate method willBeginDelayedRequest completion handler not called ...` | `-[NWURLSessionDelegateDeallocBomb dealloc]` |
| Handler called twice | `API MISUSE: NSURLSession delegate method ... completion handler called more than once ...` | `-[NWURLSessionDelegateDeallocBomb disarm]` from block_invoke_2 |

Reproduced with the `delay2-never` and `delay2-twice` scenarios (exit 134). The first `disarm` runs on the first call and the second call trips the check.
Block_invoke_3 (0x1831bd0fc) forwards to the task-queue continuation.

New or changed error cases:
- There is **no new `NSURLError` code** for delayed tasks.
- Cancel gives `NSURLErrorCancelled` (-999). A timeout gives `NSURLErrorTimedOut` (-1001).
- A new `_NSURLErrorNWPathKey` userInfo key (and `_NSURLErrorNWResolutionReportKey` for DNS) appears on NW-loader errors, alongside the usual keys.
- Classic errors carry `NSErrorFailingURLStringKey`, `_kCFStreamErrorCodeKey` and a `_NSURLErrorFailingURLSessionTaskErrorKey` task description. NW-loader errors do not.
- ATS rejection (-1022) for plain-http non-local hosts happens before any wait.

## 3. `urlSession(_:taskIsWaitingForConnectivity:)`

### 3.1 When it fires

It is delivered only if `configuration.waitsForConnectivity == true`, and **at most once per task**.

Classic stack:
- The `Tube` receives a connection-waiting notification: `Tube::connectionWaitingNotification` (0x18ce6800c) sets state 5 and stores the unmet-conditions reason at +0x120.
- The chain is `HTTPProtocol::handleConnectionWaitingNotification` (0x18ce6859c) → `URLProtocol::sendConnectionWaiting` → `URLConnectionLoader::protocolConnectionWaiting` (0x18cf44268, which logs "Connection Waiting") → `SessionConnectionLoadable::_loaderClientEvent_ConnectionWaiting` → `-[__NSCFLocalSessionTask _onqueue_connectionWaitingWithReason:]` (0x18ce81080).
  - `HTTPProtocol::handleConnectionWaitingNotification` also stamps an activity timestamp at +0x20.
  - Each of these has no direct xref callers, so the links are via vtables and blocks.
- `_onqueue_connectionWaitingWithReason:` always calls the private `task:_isWaitingForConnectionWithError:` with an NSError in `NSTCPConnectionConditionsUnmetReasonErrorDomain` (code is the reason). That happens whether or not `waitsForConnectivity` is set.
- It then calls the public delegate method only if the group config has `waitsForConnectivity` and the flag at +0x37e is not yet set (it sets it).
- `TCPIO_Establish::connectionWaitingNotification` (0x18cf0ac08) has the same once-only gating (flag at +0x40).

NW loader:
- `-[NWURLSessionTask loaderWaitingForConnectivity]` (0x182f6ce68) logs "Waiting for connectivity".
- It is reached via `objc_msgSend` from the `NWURLLoaderHTTP configureAndStartConnection:` block (0x18270bfc0, 1573 pseudo-C lines).
  - That block switches on the `nw_connection` state; `arg2 == 3` is the waiting state, at line 141 of the decompilation.
- If `configuration.waitsForConnectivity` is set, **the request-timeout timer is disabled** (`_requestTimeoutTimer` set to -1, never).
- It then calls `taskIsWaitingForConnectivity:` on the delegate queue if implemented.

Which conditions count as "waiting" (runtime, both stacks):

| Scenario | Waiting fired? | Outcome |
|---|---|---|
| Closed port (`127.0.0.1:1`, ECONNREFUSED), wfc=true | Yes, at 0.016 s | Hangs until the resource timeout, then -1001 |
| Same, wfc=false | No | Immediate -1004 |
| Unresolvable host (`nonexistent.invalid`), wfc=true | Yes, at 0.016 s | Hangs until the resource timeout, then -1001 (the NW case also carries `_NSURLErrorNWResolutionReportKey`) |
| Same, wfc=false | No | Immediate -1003 |
| Blackhole (`https://192.0.2.1`, wfc=true) | **No** | NW: -1001 at about 3.57 s (the request timeout fires). Classic: -1001 at about 8.0 s (the request timeout is ignored for the connect phase; the resource timeout applies) |

So waiting means connection **establishment failed or is unsatisfiable** (DNS failure, refused, no route), not merely slow. A connection that is merely slow is not "waiting".

### 3.2 Timeouts while waiting

- The request timeout (`timeoutIntervalForRequest`) does **not** end a waiting task. It is disabled in the NW loader and not applied in classic (wfc-refused with a 3 s request timeout and a 6 s resource timeout ended at 6.55 s).
- Only the resource timeout (default **7 days**) ends it, with `NSURLErrorTimedOut` (-1001).
  - The timeout fired about 0.55 s after the nominal time in these runs. The overshoot is consistent, and probably timer coalescing or a retry interval, but its cause is not confirmed.
- `cancel()` while waiting gives -999 (3.16 s case).
- A delegate that does not implement `taskIsWaitingForConnectivity:` still waits. The behavior is the same, with no callback.
- **The task does not recover** from a refused port. A listener started on the same port at t=4 s did not rescue the task, which timed out on the resource timer (both stacks). The path was still satisfied, so only a path change (for example Wi-Fi restored) would plausibly retry. This is untested.

### 3.3 Interplay with `earliestBeginDate` (NW loader)

`wfc-refused-delay2` gave:
- `willBegin` fires at 2.017 s;
- `taskIsWaitingForConnectivity` follows at 2.028 s;
- the resource timer (8 s) starts after the delay, so the timeout fires at 10.56 s.

In classic the delay is ignored: waiting fires at 0.016 s and the timeout at 8.58 s.

## 4. Practical guidance

1. Do not rely on `earliestBeginDate` for foreground default sessions today. It is a no-op on the classic stack. Use a background session or implement your own timer.
2. Always call the `willBeginDelayedRequest` completion handler exactly once. Never drop it or call it twice, or the process aborts.
3. When `waitsForConnectivity` is true, set `timeoutIntervalForResource` to a sensible bound. The 7-day default otherwise governs, and `timeoutIntervalForRequest` does not apply.
4. Expect `taskIsWaitingForConnectivity` for DNS or refused failures. Do not expect it for slow or blackholed connections.
5. Do not assume `task.state == .running` right after `resume()` under the NW loader. It reads suspended (1) until the queue hop completes.

## 5. Gaps and deferred experiments

- Per the instruction to focus on disassembly, these are untested or only partly traced:
  - recovery from a changing network path (Wi-Fi off/on, airplane mode), which needs a controlled path-change setup;
  - the exact `nw_connection` state to waiting mapping and unmet-conditions reason values;
  - background-session `waitsForConnectivity`: see the background-sessions report (the daemon forces it off);
  - whether the 0.55 s overshoot on the resource timeout is a fixed offset;
  - `nowfc-testnet-https` as a baseline for the blackhole case, to confirm the classic request timeout (3 s) is ignored for the connect phase even without wfc;
  - macOS 27 binaries versus the iOS 27 DSC addresses.
- The dealloc-bomb crashes and macOS behaviors were observed on macOS 27, not iOS.
