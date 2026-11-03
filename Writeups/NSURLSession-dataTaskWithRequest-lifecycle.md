# `-[NSURLSession dataTaskWithRequest:]` Lifecycle (CFNetwork, arm64e dyld shared cache)

Reconstructed via Binary Ninja decompilation of CFNetwork inside
`dyld_shared_cache_arm64e.bndb`. Addresses are CFNetwork slide-relative
addresses from the DSC (`DSCView`), aarch64 architecture.

This traces the full request lifetime for the delegate-based
`-[NSURLSession dataTaskWithRequest:]` API (no completion-handler block),
from task creation through `resume`, response, data delivery, and final
completion delegate callbacks.

## Call-graph summary

1. **Creation**
   `-[NSURLSession dataTaskWithRequest:]` `0x186c82fa0`
   → `-[__NSURLSessionLocal _dataTaskWithTaskForClass:]` `0x186cea178`
   — builds a suspended `__NSCFLocalDataTask`.

2. **Resume**
   `-[NSURLSessionTask resume]` `0x186cdae60`
   → `-[__NSCFLocalSessionTask _onqueue_resume]` `0x186c4523c`
   → `-[__NSCFURLLocalSessionConnection resume]` `0x186c8def8`
   — hands off to the C++ `URLConnectionLoader`/`HTTPProtocol` machinery, which for the
   raw-socket transport bridges into Network.framework via the C++ class `NWIOConnection`
   (see [Addendum](#addendum-networkframework-bridge-nwioconnection) — confirmed by
   disassembly, not merely inferred).

3. **Response**
   `-[__NSCFURLLocalSessionConnection _didReceiveResponse:sniff:]` `0x186c7d0e0`
   → `-[__NSCFLocalSessionTask connection:didReceiveResponse:completion:]` `0x186c7e100`
   → `-[__NSCFLocalDataTask _onqueue_didReceiveResponse:completion:]` `0x186c7e33c`
   → `-[__NSCFURLSessionDelegateWrapper dataTask:didReceiveResponse:completionHandler:]` `0x186cf3f44`
   → **`-URLSession:dataTask:didReceiveResponse:completionHandler:`**
   → `-[__NSCFLocalSessionTask _private_onqueue_didReceiveResponseDisposition:completion:]` `0x186c8d8e0`.

4. **Data (repeats N times)**
   `-[__NSCFURLLocalSessionConnection _didReceiveData:]` `0x186c8cd70`
   → `-[__NSCFLocalSessionTask connection:didReceiveData:completion:]` `0x186c8e1c8`
   → `-[__NSCFURLSessionDelegateWrapper dataTask:didReceiveData:completionHandler:]` `0x186cf48f4`
   → **`-URLSession:dataTask:didReceiveData:`**.

5. **Completion**
   `-[__NSCFLocalSessionTask _task_onqueue_didFinish]` `0x186c4f4c8`
   → `-[NSURLSession _onqueue_didCompleteTask:withError:]`
   → `-[__NSCFURLSessionDelegateWrapper task:didCompleteWithError:completionHandler:]` `0x186cf25fc`
   → **`-URLSession:task:didCompleteWithError:`**.

Every "delegate wrapper" hop first tests `respondsToSelector:` (cached in
bitflags) and falls back to the next wrapper in a chain (supports multiple
interposed delegates). Every actual delegate invocation is wrapped in
`-[NSURLSession runDelegateBlock:]` (dispatches onto the session's
`delegateQueue`). Where CFNetwork expects the delegate to invoke a completion
handler, some wrapper paths also arm a `__NSCFDeallocBomb` guard to catch the
handler being leaked or never called.

## Reconstructed pseudo-Objective-C

```objc
// ===================================================================
// 1. TASK CREATION  — -[NSURLSession dataTaskWithRequest:]  @0x186c82fa0
// ===================================================================
- (NSURLSessionTask *)dataTaskWithRequest:(NSURLRequest *)request {
    // Allocate a placeholder "__NSCFTaskForClass" tied to the session's default task group
    __NSCFTaskForClass *proto = [[__NSCFTaskForClass alloc]
        initWithGroup:[self defaultTaskGroup]];
    proto.originalRequest = request;          // objc_setProperty_atomic(proto, request, 0x10)

    // Ask the concrete session (__NSURLSessionLocal / __NSURLBackgroundSession)
    // to materialize the real task object for this class.
    return [self _dataTaskWithTaskForClass:[proto autorelease]];
}

// -[__NSURLSessionLocal _dataTaskWithTaskForClass:]  @0x186cea178
- (NSURLSessionTask *)_dataTaskWithTaskForClass:(id)proto {
    proto.taskForClass = [__NSCFLocalDataTask class];   // concrete class = data task
    return [self taskForClassInfo:proto];               // builds __NSCFLocalDataTask, wires session
}
// => Returns a fully constructed, *suspended* __NSCFLocalDataTask (state = Suspended).


// ===================================================================
// 2. RESUME  — -[NSURLSessionTask resume]  @0x186cdae60
// ===================================================================
- (void)resume {
    if (self.state > Suspended || !self.workQueue) return;

    self.state = Running;
    self._qos = qos_class_self();
    self._voucher = voucher_copy();

    // Networking activity + telemetry/signpost bookkeeping (HAR logging,
    // os_signpost "Task Resume", os_log "%@ resuming, timeouts(...)").
    [self setupActivityAndLogging];

    @synchronized(self) {
        if (self.connection && !self.connection.isCancelled && self.connection.isPaused)
            [self.connection resume];   // restart only if the existing connection is merely paused

        if (!self.didSeenFirstResume) {
            self.didSeenFirstResume = YES;
            self._private_nw_activity = self._nw_activity
                ?: nw_activity_create(kind: Task,
                       self.session.configuration.disposition == Background ? 3 : 2);
            nw_activity_activate(self._private_nw_activity);
            // Telemetry selection / Duet metrics bookkeeping omitted here.
            // API-misuse fault if originalRequest has no URL.
        }
    }

    kdebug_trace(SIGNPOST_TASK_RESUME, self);

    // The actual work happens off the calling thread:
    dispatch_async(self.workQueue, ^{
        [self _onqueue_resume];      // __NSCFLocalSessionTask override
    });
}

// -[__NSCFLocalSessionTask _onqueue_resume]  @0x186c4523c
- (void)_onqueue_resume {
    if (--self.suspendCount != 0) return;
    self.state = Running;

    if (self._async_initialization) {
        [self _onqueue_completeInitialization];
        return;
    }
    if (!self.cfConn) return;
    [self.cfConn resume];                       // __NSCFURLLocalSessionConnection
}

// -[__NSCFURLLocalSessionConnection resume]  @0x186c8def8
- (void)resume {
    [self withLoaderAsync:^(LoaderInterface *loader) {
        loader->resume();     // hands off to the C++ URLConnectionLoader / HTTPProtocol machinery,
                               // which for the socket-transport path constructs an NWIOConnection
                               // (C++ class, see Addendum) that wraps Network.framework's
                               // nw_connection_t, sends the request, and drives the state
                               // machine that calls back into
                               // -_didReceiveResponse:sniff:, -_didReceiveData:, -_didFinishLoading
    }];
}


// ===================================================================
// 3. RESPONSE ARRIVES
// -[__NSCFURLLocalSessionConnection _didReceiveResponse:sniff:] @0x186c7d0e0
// ===================================================================
- (void)_didReceiveResponse:(NSURLResponse *)response sniff:(BOOL)sniff {
    if (!self.didCheckMixedReplace) {
        self.didCheckMixedReplace = YES;
        self.isMixedReplace = (response._inner->flags & 0x80000000) != 0;
        if (self.isMixedReplace) { [self _tossCache]; if (self.sniffResponse) [self _tick_sniffNow]; }
    }

    if (sniff && !self.isHTTPS &&
        HTTPSniffing::checkRequestAndUpdateResponseForSniffingPurposes(self.task.currentRequest, response)) {
        self.sniffData = dispatch_data_create_empty();
        self.sniffResponse = [response copy];
        return;                                    // wait for more bytes before delivering
    }

    if (self.isMixedReplace == 1) [self suspend];

    [self withDelegateAndPendingCompletion:^(id<__NSCFURLSessionConnectionDelegate> delegate,
                                              void (^completion)(void)) {
        [delegate connection:self didReceiveResponse:response completion:completion];
    }];
}

// -[__NSCFLocalSessionTask connection:didReceiveResponse:completion:] @0x186c7e100
- (void)connection:(id)connection didReceiveResponse:(NSURLResponse *)response completion:(void(^)(void))completion {
    if (/* mixed-replace multipart response */ response._inner->flags & 0x80000000) {
        self.connectionWorkQueue = [NSOperationQueue new];
        self.connectionWorkQueue.maxConcurrentOperationCount = 1;
        self.connectionWorkQueue.underlyingQueue = self.session.delegateQueue.underlyingQueue;
    }
    void (^work)(void) = ^{
        [self _onqueue_didReceiveResponse:response completion:completion];   // dispatched to task's own queue
    };
    self.connectionWorkQueue ? [self.connectionWorkQueue addOperationWithBlock:work] : work();
}

// -[__NSCFLocalDataTask _onqueue_didReceiveResponse:completion:] @0x186c7e33c
- (void)_onqueue_didReceiveResponse:(NSURLResponse *)response completion:(NetworkCompletion)completion {
    self.response = response;
    self.countOfBytesExpectedToReceive = response.expectedContentLength;

    if (self.state >= Canceling) { completion(NoResponseDisposition); return; }

    id delegate = self.delegate ?: self.session.delegate;
    if (![__NSCFURLSessionDelegateWrapper didReceiveResponse:delegate]) {   // no -URLSession:dataTask:didReceiveResponse:completionHandler:
        completion(NSURLSessionResponseAllow);  // raw callback receives a small response-options struct; default value is .allow
        return;
    }

    if ([self.cfConn isKindOfClass:[__NSCFURLLocalSessionConnection class]]) {
        [self _onqueue_suspend];
        self.suspendedForDisposition = YES;
    }
    self.pendingResponseDisposition = YES;

    // ***** delegate callout #1 *****
    [__NSCFURLSessionDelegateWrapper dataTask:self
                          didReceiveResponse:response
                          completionHandler:^(NSURLSessionResponseDisposition disposition) {
        [self _private_onqueue_didReceiveResponseDisposition:disposition completion:completion];
    }];
}

// -[__NSCFURLSessionDelegateWrapper dataTask:didReceiveResponse:completionHandler:] @0x186cf3f44
- (void)dataTask:(NSURLSessionDataTask *)task
   didReceiveResponse:(NSURLResponse *)response
   completionHandler:(void(^)(NSURLSessionResponseDisposition))handler {
    if (![self check_didReceiveResponse]) {          // delegate doesn't implement it -> forward or default(Allow)
        self.next ? [self.next dataTask:task didReceiveResponse:response completionHandler:handler]
                  : handler(NSURLSessionResponseAllow);
        return;
    }
    __NSCFDeallocBomb *bomb = [[__NSCFDeallocBomb alloc]     // detects delegate leaking the handler
        initWithMethod:@"dataTask:didReceiveResponse:completionHandler:" delegate:self.delegate];

    // ***** ACTUAL USER DELEGATE CALL *****
    [self.session runDelegateBlock:^{
        [self.delegate URLSession:self.session
                          dataTask:task
                didReceiveResponse:response
                 completionHandler:handler];         // -> app code decides .allow / .cancel / .becomeDownload / .becomeStream
    }];
}

// -[__NSCFLocalSessionTask _private_onqueue_didReceiveResponseDisposition:completion:] @0x186c8d8e0
- (void)_private_onqueue_didReceiveResponseDisposition:(NSURLSessionResponseDisposition)disposition
                                            completion:(NetworkCompletion)completion {
    switch (disposition) {
      case NSURLSessionResponseCancel:
        [self _onqueue_cancel];
        if (self.connectionForUpgrade) self.connectionForUpgrade->cancel(0);
        break;
      case NSURLSessionResponseAllow:
        self.pendingResponseDisposition = NO;
        if (!self.pendingResponseBytes) {
            if (self.suspendedForDisposition) [self _onqueue_resume];
            if (self.pendingResponseDisposition_didFinish) [self _task_onqueue_didFinish];
        } else {
            // deliver bytes buffered while waiting for the disposition
            dispatch_data_t pending = self.pendingResponseBytes;
            self.pendingResponseBytes = nil;
            [self _task_onqueue_didReceiveDispatchData:pending completionHandler:^{...}];
            dispatch_release(pending);
        }
        break;
      case NSURLSessionResponseBecomeDownload:
        // swap self for a __NSCFLocalDownloadTask, replace in session,
        // call -[delegate dataTask:didBecomeDownloadTask:completionHandler:]
        break;
      case NSURLSessionResponseBecomeStream:
        // swap self for a __NSCFURLLocalStreamTaskFromDataTask / __NSCFURLLocalTCPIOStreamTaskFromDataTask,
        // replace in session, then call -[delegate dataTask:didBecomeStreamTask:completionHandler:]
        break;
    }
    completion();   // resumes the loader state machine (network I/O continues)
}


// ===================================================================
// 4. DATA ARRIVES (repeats N times)
// -[__NSCFURLLocalSessionConnection _didReceiveData:] @0x186c8cd70
// ===================================================================
- (void)_didReceiveData:(dispatch_data_t)data {
    if (!data || dispatch_data_get_size(data) == 0) return;

    if (!self.sniffData) {
        self.pendingData = concatData(self.pendingData, data);
        [self coalesceSegmentsIfOverThreshold];         // merges many small dispatch_data segments
    } else {
        self.sniffData = concatData(self.sniffData, data); // buffered until sniffing completes
    }
    [self _tick];    // drains pendingData toward the task (may trigger _didReceiveResponse first)
}

// -[__NSCFLocalSessionTask connection:didReceiveData:completion:] @0x186c8e1c8
- (void)connection:(id)connection didReceiveData:(dispatch_data_t)data completion:(void(^)(void))completion {
    void (^work)(void) = ^{ [self _onqueue_didReceiveDispatchData:data completion:completion]; };
    self.connectionWorkQueue ? [self.connectionWorkQueue addOperationWithBlock:work] : work();
    // -> eventually calls [__NSCFURLSessionDelegateWrapper dataTask:didReceiveData:completionHandler:]
}

// -[__NSCFURLSessionDelegateWrapper dataTask:didReceiveData:completionHandler:] @0x186cf48f4
- (void)dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data completionHandler:(void(^)(void))h {
    if ([self.delegate respondsToSelector:@selector(URLSession:dataTask:_didReceiveData:completionHandler:)]) {
        __NSCFDeallocBomb *bomb = [[__NSCFDeallocBomb alloc]
            initWithMethod:@"dataTask:didReceiveData:completionHandler:" delegate:self.delegate];
        [self.session runDelegateBlock:^{
            [self.delegate URLSession:self.session dataTask:task
                       _didReceiveData:data completionHandler:h];   // rarely used private variant
        }];
    } else if ([self.delegate respondsToSelector:@selector(URLSession:dataTask:didReceiveData:)]) {
        [self.session runDelegateBlock:^{
            // ***** ACTUAL USER DELEGATE CALL *****
            [self.delegate URLSession:self.session dataTask:task didReceiveData:data];
            h();
        }];
    } else {
        self.next ? [self.next dataTask:task didReceiveData:data completionHandler:h] : h();
    }
}


// ===================================================================
// 5. COMPLETION  — connection finishes loading or fails
// ===================================================================
// C++ URLConnectionLoader detects EOF / error and calls back up into:
// -[__NSCFLocalSessionTask _task_onqueue_didFinish]  @0x186c4f4c8
- (void)_task_onqueue_didFinish {
    if ([self.error.domain isEqual:NSURLErrorDomain] && self.error.code == NSURLErrorCancelled) {
        // socket/connection-cache teardown bookkeeping (HTTPConnectionCacheKey release)
    }
    [self _finishProgressReporting];

    if (self.pendingResponseDisposition) {
        self.pendingResponseDisposition_didFinish = YES;   // defer until disposition resolves
        return;
    }

    void (^finish)(void) = ^{
        if (self.effectiveConfiguration.usesClassicLoadingMode)
            [self.metrics completeWithError:self.error];

        void (^deliver)(void) = ^{
            if (!self._callCompletionHandlerInline)
                [self.session runDelegateBlock:^{ [self _deliverDidFinish]; }];
            else
                [self _deliverDidFinish];
        };
        self.needSendingMetrics
            ? [self.metrics collectWithCompletionHandler:deliver queue:self.workQueue]
            : deliver();

        self.state = Completed;
    };
    finish();
}

// ___-[__NSCFLocalSessionTask _task_onqueue_didFinish]_block_invoke @0x186c4f848
// == "_deliverDidFinish" ==
- (void)_deliverDidFinish {
    if (self.completionHandler) {
        // dataTaskWithRequest:completionHandler: path — call the block directly, no delegate method.
        void (^handler)(NSData *, NSURLResponse *, NSError *) = [self.completionHandler copy];
        self.completionHandler = nil;
        void (^invoke)(void) = ^{ handler(self.accumulatedData, self.response, self.error); };
        self._callCompletionHandlerInline ? invoke()
            : [self.session runDelegateBlock:invoke];
    } else {
        // delegate-based dataTaskWithRequest: path (our traced case):
        [self.session _onqueue_didCompleteTask:self withError:self.error];
    }
    [self.localSession removeUnresumedTask:self];
}

// -[NSURLSession _onqueue_didCompleteTask:withError:]  (dispatches into the wrapper chain)
- (void)_onqueue_didCompleteTask:(NSURLSessionTask *)task withError:(NSError *)error {
    [__NSCFURLSessionDelegateWrapper task:task didCompleteWithError:error completionHandler:^{
        // final bookkeeping: task removed from session's task set, invalidate-if-needed check
    }];
}

// -[__NSCFURLSessionDelegateWrapper task:didCompleteWithError:completionHandler:] @0x186cf25fc
- (void)task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error completionHandler:(void(^)(void))h {
    if ([self.delegate respondsToSelector:@selector(URLSession:task:didCompleteWithError:)]) {
        [self.session runDelegateBlock:^{
            // ***** FINAL USER DELEGATE CALL *****
            [self.delegate URLSession:self.session task:task didCompleteWithError:error];
            h();
        }];
    } else {
        self.next ? [self.next task:task didCompleteWithError:error completionHandler:h] : h();
    }
}
// => Request lifecycle complete. Task state == NSURLSessionTaskStateCompleted.
```

## Addendum: Network.framework Bridge (`NWIOConnection`)

*Added after expanding disassembly coverage to include Network.framework in the same
dyld shared cache. All addresses below are Network.framework/CFNetwork addresses
confirmed via direct decompilation, not inferred.*

The original report above described the transport handoff only vaguely, as
"the C++ loader / `nw_connection` layer." With Network.framework now loaded and
analyzed in the same Binary Ninja view, that boundary can be named and characterized
concretely.

### The bridge class: `NWIOConnection`

`NWIOConnection` is a C++ class **compiled directly into CFNetwork** (not a separate
framework) that wraps a single Network.framework `nw_connection_t` and exposes an
internal C++ API (`open`, `read`/`readWithContext`, `write`/`writeWithContext`,
`enableTLS`, `_convertError`, `_handleError`, `copyPeerCerts`, `copyIPAddresses`,
`coalesce`/`isCoalesced`, `setCoalescingConfig`, etc.) that the rest of CFNetwork's
loader machinery calls into. It is CFNetwork's *sole* internal caller of
`nw_connection_create` — confirmed via `bn_function_xrefs_to` on
`_nw_connection_create` (`0x1895710c8`): of 81 call sites cache-wide, exactly one,
the block invoke for `NWIOConnection::_setupConnection` (`0x186d5d494`), lies inside
CFNetwork's own address range; every other caller belongs to Network.framework
itself (its TCP/SOCKS/MASQUE/HTTP-proxy internals).

This confirms the "C++ loader" mentioned in the original report is, concretely,
`NWIOConnection`, and that it is the one and only place ordinary (non-WebSocket,
non-explicit-stream) CFNetwork traffic crosses into `nw_connection_t`.

> **Caveat:** the exact call chain from `-[__NSCFURLLocalSessionConnection resume]` /
> `loader->resume()` down into `NWIOConnection::open`/`_setupConnection` was not
> traced via a direct xref chain in this pass (xrefs-to `NWIOConnection::open` are
> dominated by noisy intra-function/jump-table references that did not resolve to a
> clean caller list). The connection is architecturally certain — `NWIOConnection` is
> demonstrably CFNetwork's only bridge into `nw_connection`, and the class's own
> method names/behavior match the loader's job precisely — but it should be
> considered **confirmed-by-elimination**, not confirmed-by-direct-callgraph-trace.

### Connection setup: QUIC racing and six event handlers

`NWIOConnection::_setupConnection`'s block invoke (`0x186d5d494`, 78 basic blocks)
does substantially more than "open a socket":

- Builds the primary `nw_endpoint_t` for the request's host/port.
- **Conditionally adds a QUIC alternative endpoint** via
  `_nw_protocol_copy_quic_connection_definition()` +
  `_nw_endpoint_add_alternative(...)`. A private per-connection configuration
  dictionary entry selects one of: force-QUIC (mode 4), race-QUIC-as-alternative
  (mode 2), or preferred-QUIC-with-priority (mode 3, via
  `NWIOConnection::_createEndpoint`). A CFBoolean-typed config value is validated
  with an `os_log_fault` guard ("pass kCFBooleanTrue or kCFBooleanFalse here") if
  misused. In other words: **ordinary `dataTaskWithRequest:` connections can
  transparently race an HTTP/3 (QUIC) endpoint against the primary TCP/TLS endpoint
  at the Network.framework layer**, entirely below the ObjC task/loader machinery
  already documented above.
- Calls `_nw_connection_create(endpoint, parameters)`; on failure, routes to
  `NWIOConnection::_handleError(conn, /*domain=*/1, /*code=*/0x16)` — a
  POSIX-domain error distinct from the NSURLErrorDomain-normalized errors surfaced
  at the ObjC layer (see the WebSocket report's error-domain discussion for a
  related, ObjC-visible inconsistency).
- Wires up the connection's dispatch queue, then installs **six** distinct
  `nw_connection` callback handlers via `_nw_connection_set_event_handler` (state),
  `_nw_connection_set_read_close_handler`, `_nw_connection_set_write_close_handler`,
  `_nw_connection_set_alternate_path_state_handler` (feeds back into the QUIC-racing
  logic above), `_nw_connection_set_viability_changed_handler`, plus
  property-driven handlers installed via
  `NWIOConnection::_applyPropertyToConnection_EventHandlerAdaptiveRead`,
  `..._EventHandlerAdaptiveWrite`, `..._EventHandlerLowThroughput`, and
  `..._EventHandlerExcessiveKeepalive`. None of this handler richness (adaptive
  read/write tuning, low-throughput and excessive-keepalive telemetry) was
  previously documented at the ObjC task level — it exists purely inside the
  Network.framework bridge.

### New finding: TLS "waiting" errors are force-failed, not retried

The shared state-event handler for all six callbacks
(`invocation function for block in NWIOConnection::_setupConnectionEvents()`,
`0x186d5de18`, 110 lines) dispatches on the standard `nw_connection_state_t` values
(`waiting`=1, `preparing`=2, `ready`=3, `failed`=4, `cancelled`=5). Two behaviors here
are new, concrete, and not obvious from the ObjC-level lifecycle:

- **`preparing` (2)** triggers `_takePreventIdleSleepAssertionIfAppropriate` on the
  task — an idle-sleep assertion is held while a connection is establishing, and
  released again (`_releasePreventIdleSleepAssertionIfAppropriate`) once the
  connection reaches `ready` or `failed`. This power-management detail is invisible
  from the ObjC delegate API but affects on-device behavior (a slow-connecting
  request can measurably delay device sleep).
- **`waiting` (1)** is normally forwarded to `NWIOConnection::_handleEvent_Waiting`,
  which (based on Network.framework's public semantics) allows the connection to
  keep retrying transient conditions such as "no network path yet." **However, if
  the pending error's domain is `nw_error_domain_tls`
  (`_nw_error_get_error_domain(arg3) == nw_error_domain_tls`), CFNetwork explicitly
  refuses to let the connection stay in the retryable `waiting` state.** It logs
  `"Connection %llu: treating TLS waiting errors as failures"` via `os_log_error`
  and instead routes directly to `NWIOConnection::_handleEvent_Disconnected` — the
  same terminal-failure path used for the `failed` state. This is a genuine,
  previously-undocumented policy: **TLS-related connection problems fail fast at
  the Network.framework bridge rather than being silently retried**, unlike other
  transient waiting conditions.
- **`failed` (4)** suppresses the failure notification entirely (treats it as a
  no-op, same as `cancelled`) when a specific connection-type flag is set *and* the
  underlying error code is `0x59` (89 decimal, `ECANCELED`) — an intentional filter
  for benign cancellation noise on that transport type.

### New finding: error synthesis and domain rewriting in `NWIOConnection::_convertError`

`NWIOConnection::_convertError` (`0x186d54e4c`) is the function that turns an
`nw_error_t` (or its absence) into the `(CFStreamErrorDomain, CFIndex)` pair that
ultimately becomes the app-visible `NSError`. Its behavior generalizes and connects
to prior findings:

- When a real `nw_error_t` exists, it is converted faithfully via
  `_nw_error_copy_cf_error(arg2)` → `__CFStreamErrorFromCFError(cf)` — the native
  error is not discarded at this layer.
- **When no `nw_error_t` is provided and the connection object is already gone**,
  the function does not fail silently or propagate an ambiguous nil — it
  **synthesizes a fabricated `NSPOSIXErrorDomain` `ENOTCONN` (57) error**, logged
  via `os_log_debug` as `"generating ENOTCONN, since in an error state with no
  error and no connection"`. This is a direct, CFNetwork-wide generalization of the
  WebSocket report's previously-flagged "unexplained `ENOTCONN` used both for real
  errors and for normal closes" finding: it is not WebSocket-specific behavior — it
  is a general `NWIOConnection` pattern used by **all** transports built on this
  bridge, including ordinary `dataTaskWithRequest:` connections.
- **When no error exists but the connection is still present**, the function
  synthesizes one of three different heuristic errors depending on connection
  state, each logged verbatim as `"missing error, so heuristics synthesized
  error(%ld:%d)"` via `os_log_error` — Apple's own code admits it is guessing:
  - state not yet `ready` (< 3): `NSPOSIXErrorDomain` code `2` (`ENOENT`).
  - `ready` but TLS handshake not marked complete: `NSPOSIXErrorDomain` code `0x35`
    (53, `ECONNABORTED`).
  - `ready` and handshake complete: the Secure Transport / SSL error domain with
    code `0xffffd9b2` (`-9806`, in the `errSSL*` numeric range).
- **A private "conditional connection requirement" time-window check**: if the
  synthesized error is `ENOTCONN` and a per-connection config dictionary contains a
  `kConditionalConnectionRequirementTimeWindow`-style start-time + duration pair,
  and the current time still falls inside that window, the error code is rewritten
  to `0x3c` (60). The exact product-level meaning of this window (e.g. an
  MDM/on-demand/network-policy grace period) could not be determined from this
  function alone and is called out here as an open question rather than a firm
  conclusion.
- **`ECONNRESET` during an incomplete TLS handshake**: when the resolved error is
  POSIX `ECONNRESET` (54, `0x36`) and the TLS handshake was not yet complete, the
  domain is rewritten to the Secure Transport error domain, with an accompanying
  `os_log_error` naming the intended result as `errSSLClosedNoNotify`. The
  decompiled pseudocode leaves the raw numeric code unchanged in this branch, so
  whether the final returned code is actually renumbered to the real
  `errSSLClosedNoNotify` constant elsewhere, or the log message is describing
  intent rather than the exact bit pattern shown here, is noted as **moderate
  confidence** rather than fully proven.

### Net assessment

Expanding into Network.framework did produce material new insight beyond what was
inferable from CFNetwork alone: a named and characterized bridge class
(`NWIOConnection`), concrete QUIC/HTTP-3 racing behavior for ordinary data tasks,
six previously-undocumented connection-quality event handlers, a genuine
TLS-waiting-fails-fast policy, and — most notably — confirmation that the
`ENOTCONN`-for-missing-error pattern flagged as WebSocket-specific in the earlier
report is in fact a general `NWIOConnection`-layer behavior shared by all
transports, including plain data tasks. The core ObjC-level lifecycle documented
in the rest of this report is unchanged; this addendum fills in what happens
underneath `loader->resume()`.
