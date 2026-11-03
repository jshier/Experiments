# `NSURLSessionWebSocketTask` Lifecycle, Delegate Surface, and Error-Handling Analysis

This document reverse-engineers `-[NSURLSession webSocketTaskWithRequest:]` and the
full lifetime of the resulting `__NSURLSessionWebSocketTask` (the private subclass
backing the public `URLSessionWebSocketTask` API), from creation through handshake,
message I/O, close/cancel, and final completion. It also documents several
**error-handling inconsistencies**, one of which is a concretely reproducible bug
in how transport-level errors lose diagnostic detail compared to ordinary
`URLSessionDataTask`/`UploadTask`/`DownloadTask` failures.

Analysis performed via Binary Ninja MCP against a disassembled/decompiled
`CFNetwork` extracted from the `dyld_shared_cache` (arm64e). All addresses below
are CFNetwork slide-independent offsets as reported by Binary Ninja for this
binary view; pseudo-Objective-C is reconstructed from Binary Ninja's decompiler
output, cleaned up for readability (renamed locals, resolved selector/string
literals, added comments) but otherwise faithful to the actual control flow.

---

## 1. Task Creation

### `-[NSURLSession webSocketTaskWithRequest:]` (`0x186e1d610`)

Thin trampoline into the session's local/proxy implementation:

```objc
- (NSURLSessionWebSocketTask *)webSocketTaskWithRequest:(NSURLRequest *)request {
    NSMutableURLRequest *mutableRequest = [request mutableCopy];
    return [self webSocketTaskForRequest:mutableRequest];  // dispatches to __NSURLSessionLocal
}
```

### `-[__NSURLSessionLocal webSocketTaskForRequest:]` (`0x186cea1d4`)

This is where CFNetwork silently rewrites the request to be a valid WebSocket
handshake, **only filling in headers the caller didn't already set** — the same
"fill-if-missing" pattern documented previously for ordinary reserved HTTP
headers (see `URLSession-Reserved-HTTP-Headers.md`):

```objc
- (id)webSocketTaskForRequest:(NSMutableURLRequest *)req {
    // The public entrypoint already did `mutableCopy`; this helper mutates in place.
    NSDictionary *headers = [req allHTTPHeaderFields];

    if (!headers[@"Sec-WebSocket-Version"])
        [req setValue:@"13" forHTTPHeaderField:@"Sec-WebSocket-Version"];

    if (!headers[@"Upgrade"])
        [req setValue:@"websocket" forHTTPHeaderField:@"Upgrade"];

    if (!headers[@"Connection"])
        [req setValue:@"Upgrade" forHTTPHeaderField:@"Connection"];

    if (!headers[@"Sec-WebSocket-Key"]) {
        uint8_t keyBytes[16];
        arc4random_buf(keyBytes, sizeof(keyBytes));
        NSString *key = [[[NSData alloc] initWithBytesNoCopy:keyBytes
                                                      length:sizeof(keyBytes)
                                                freeWhenDone:NO]
                            base64EncodedStringWithOptions:0];
        [req setValue:key forHTTPHeaderField:@"Sec-WebSocket-Key"];
    }

    if (!headers[@"Sec-WebSocket-Extensions"])
        [req setValue:@"permessage-deflate" forHTTPHeaderField:@"Sec-WebSocket-Extensions"];

    __NSCFTaskForClass *info = [[__NSCFTaskForClass alloc] initWithGroup:[self defaultTaskGroup]];
    info.taskClass = [__NSURLSessionWebSocketTask class];
    info.originalRequest = req;
    return [self taskForClassInfo:info];
}
```

**Note:** the `Sec-WebSocket-Key` is generated with `arc4random_buf` (CSPRNG),
not a weak RNG — no issue there.

### `-[__NSURLSessionWebSocketTask initWithOriginalRequest:ident:taskGroup:]` (`0x186e3b8b8`)

Sets up the task's internal queues and defaults:

```objc
- (id)initWithOriginalRequest:(NSURLRequest *)request
                          ident:(NSUInteger)ident
                      taskGroup:(dispatch_queue_t)queue {
    self = [super initWithOriginalRequest:request ident:ident taskGroup:queue];
    // NOTE: disassembly confirms these four are each `objc_alloc_init(NSMutableArray)` —
    // i.e. a fused [[NSMutableArray alloc] init] runtime call — NOT `+[NSMutableArray new]`.
    _pendingSendWork        = [[NSMutableArray alloc] init];
    _highPriorityPendingWork = [[NSMutableArray alloc] init];
    _delegateWork           = [[NSMutableArray alloc] init];
    _pendingReceiveWork     = [[NSMutableArray alloc] init];
    _webSocketHandshakeCompleted = NO;
    _closeCode              = 0;
    _maximumMessageSize     = 0x100000;          // 1 MiB default
    return self;
}
```

---

## 2. Resume and Handshake

### `_onqueue_resume` (`0x186e3e40c`)

Guards against the classic "resume after the task has already completed" misuse
and logs it via `os_log_fault` (a hard-fault-level log, i.e. Apple considers
this a serious API-contract violation worth flagging loudly), but **only on the
post-handshake path**. If the handshake has not completed yet, it simply calls
`super`'s `_onqueue_resume` to kick off the underlying HTTP request. If the
handshake *has* completed, a later `resume` no longer calls `super`: for states
other than the completed/canceling pair it resets state to `0` and re-enters
`_onqueue_ioTick`; for the completed/canceling pair it logs the misuse fault.

### `_onqueue_didReceiveResponse:completion:` (`0x186e3fb58`)

This is the handshake-validation core. The WebSocket handshake is **not**
implemented as a distinct protocol — it rides the exact same HTTP
request/response path as an ordinary data task. Once the HTTP response
arrives, this override inspects it before deciding whether to treat the
connection as a live WebSocket:

```objc
- (void)_onqueue_didReceiveResponse:(NSHTTPURLResponse *)response
                          completion:(void (^)(NSURLSessionResponseDisposition))completion {
    // Binary Ninja does not recover the block type cleanly here; disassembly shows
    // this completion callback is invoked immediately, once, before validation.
    completion(/* opaque inherited response-handling token */);
    self.response = response;

    if (response == nil || ![response isKindOfClass:[NSHTTPURLResponse class]]) {
        os_log_error(..., "No response for Web-Socket Handshake, failing task");
        [self _onqueue_cancelWebSocketTaskWithError:kNSURLErrorBadServerResponse]; // -1011
        return;
    }

    NSString *requestKey = [self.currentRequest valueForHTTPHeaderField:@"Sec-WebSocket-Key"];
    NSAssert(requestKey != nil, @"Sec-WebSocket-Key must be set"); // always true: auto-injected in step 1

    nw_ws_options_t options = nw_ws_create_options(nw_ws_version_13);
    self.wsOptions = options;
    nw_ws_options_set_auto_reply_ping(options, true);   // <-- see §6, dual ping mechanism
    nw_ws_options_set_skip_handshake(options, true);    // HTTP layer already did the handshake
    nw_ws_options_set_prepend_data(options, self->_extraBytes);
    nw_ws_options_set_maximum_message_size(options, _maximumMessageSize);
    self.protocolPicked = [response valueForHTTPHeaderField:@"Sec-WebSocket-Protocol"];

    // Only if the response named a protocol does CFNetwork walk the request's offered list,
    // splitting on "," and trimming whitespace per element.
    if (self.protocolPicked != nil) {
        for (NSString *proto in [[self.currentRequest valueForHTTPHeaderField:@"Sec-WebSocket-Protocol"]
                                    componentsSeparatedByString:@","]) {
            NSString *trimmed = [proto stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            nw_ws_options_add_subprotocol(options, trimmed.UTF8String);
        }
    }

    // *** Notable finding (see §7.4): permessage-deflate is enabled based on
    // whether the REQUEST set Sec-WebSocket-Extensions, not whether the
    // RESPONSE actually negotiated it. ***
    nw_ws_options_set_permessage_deflate(
        options,
        [self.currentRequest valueForHTTPHeaderField:@"Sec-WebSocket-Extensions"] != nil);

    NSUInteger reasonCode = 0;
    if (!nw_ws_validate_server_response_with_protocol_options(/* libnetwork transport */,
                                                              requestKey,
                                                              options,
                                                              &reasonCode)) {
        NSError *base = [self error:NSURLErrorDomain code:kNSURLErrorBadServerResponse]; // -1011
        NSMutableDictionary *userInfo = [[base userInfo] mutableCopy];
        userInfo[NSURLErrorWebSocketHandshakeFailureReasonKey] = @(reasonCode);
        self->_error = [NSURLError errorWithDomain:NSURLErrorDomain
                                              code:kNSURLErrorBadServerResponse
                                          userInfo:userInfo];
        [self _onqueue_ioTick];
        return;
    }

    if (self->_connectionForUpgrade == NULL) {
        os_log_error(..., "Connection not set before response is received, failing task");
        [self _onqueue_cancelWebSocketTaskWithError:kNSURLErrorNetworkConnectionLost]; // -1005
        return;
    }

    if (![self _needSendingMetrics]) {
        [self _onqueue_enableWebSocketFraming:self.protocolPicked];
    } else {
        [self _didSendMetrics];
        [self.session.delegateWrapper task:self
                  didFinishCollectingMetrics:self._metrics
                           completionHandler:^{
            [self _onqueue_enableWebSocketFraming:self.protocolPicked];
        }];
    }
}
```

**Important correction:** there is **no direct `statusCode` branch** in this
CFNetwork function. The observed code only rejects a missing/non-HTTP response
up front; status/protocol validation is delegated to the external
`nw_ws_validate_server_response_with_protocol_options(...)` call.

### `_onqueue_enableWebSocketFraming:` (`0x186e3e560`)

```objc
- (void)_onqueue_enableWebSocketFraming:(NSString *)negotiatedProtocol {
    // Fire the "handshake succeeded" delegate callback BEFORE the connection
    // is actually reconfigured to speak WS frames:
    [self.session.delegateWrapper webSocketTask:self didOpenWithProtocol:negotiatedProtocol];
    os_log_debug(..., "%{public}@ handshake successful", self._loggableDescription);

    nw_connection_modify_connected_protocol_stack(self->_connectionForUpgrade, ^(nw_protocol_stack_t stack) {
        nw_protocol_stack_prepend_application_protocol(stack, self.wsOptions);
    });

    [self->_connectionForUpgrade setProperty:viabilityChangedBlock
                                      forKey:__kCFStreamPropertyConnectionViabilityChangedBlock];
    self->_webSocketHandshakeCompleted = YES;
    [self _onqueue_ioTick];  // start draining any send/receive/ping calls queued before open
}
```

**Delegate fired here:** `URLSession:webSocketTask:didOpenWithProtocol:`

---

## 3. Message I/O — Send / Receive / Ping

All three follow the same pattern: **if the task already has a stored error
(ivar at offset `0x3d0`), short-circuit immediately with that stored error**;
otherwise perform the operation via `nw_connection_send` / register a receive
handler on the `nw_connection`.

### `sendMessage:completionHandler:` block invokes (`0x186e3bb94`, `0x186e3bda8`)

```objc
void send_block_invoke(__NSURLSessionWebSocketTask *self, NSURLSessionWebSocketMessage *msg,
                       void (^completion)(NSError *)) {
    if (self->_error != nil) {
        [self.session runDelegateBlock:^{ completion(self->_error); }];
        return;
    }

    [self->_pendingSendWork addObject:^{
        if (self->_error != nil) {
            [self.session runDelegateBlock:^{ completion(self->_error); }];
            return;
        }

        nw_content_context_t ctx = nw_content_context_create("websocketSend");
        nw_ws_metadata_t meta =
            nw_ws_create_metadata(msg.type == NSURLSessionWebSocketMessageTypeString
                                      ? nw_ws_opcode_text
                                      : nw_ws_opcode_binary);

        dispatch_data_t payload =
            (msg.type == NSURLSessionWebSocketMessageTypeString)
                ? [[msg.string dataUsingEncoding:NSUTF8StringEncoding] _createDispatchData]
                : [msg.data _createDispatchData];

        nw_content_context_set_metadata_for_protocol(ctx, meta);
        nw_connection_send(self->_connectionForUpgrade, payload, ctx, true, /* completion block */);
    }];
    [self _onqueue_ioTick];
}
```

### `_onqueue_receiveMessageWithCompletionHandler:` (`0x186e3d04c`)

Same existing-error short-circuit, then sets `_readInProgress = YES` and
registers `nw_connection_receive_message(...)` on the upgraded connection. The
actual decode happens in the block invoke below.

### `_onqueue_receiveMessageWithCompletionHandler:_block_invoke_3` (`0x186e3f3d0`) — message decode

This is where most of the **error-handling inconsistencies** originate (see §7
for the full analysis); reconstructed:

```objc
void receive_decode_block_invoke(__NSURLSessionWebSocketTask *self,
                                 dispatch_data_t content, nw_content_context_t ctx,
                                 bool isComplete, nw_error_t nwErr,
                                 void (^completion)(NSURLSessionWebSocketMessage *, NSError *)) {
    NSURLSessionWebSocketMessage *message = nil;
    nw_ws_opcode_t opcode = -1;
    nw_ws_metadata_t meta = NULL;

    if (content != nil) {
        meta = nw_content_context_copy_protocol_metadata(ctx, nw_protocol_ws);
        if (meta != NULL) opcode = nw_ws_metadata_get_opcode(meta);
    }

    if (nwErr != NULL && (meta == NULL || (self->_expectsReplyFlag & 1) == 0 || content == nil)) {
        os_log_error(..., "Read completed with an error %@", nwErr);
        // Preserves the ORIGINAL nw_error's native domain/detail — unlike §7.3 below!
        self->_error = (NSError *)nw_error_copy_cf_error(nwErr);
    } else if (content == nil && self->_expectsReplyFlag == 1) {
        self->_error = [self error:NSPOSIXErrorDomain code:ENOTCONN];   // 0x39 == 57
    }

    if (self->_error == nil) {
        switch (opcode) {
            case nw_ws_opcode_text: {
                NSString *text = [[NSString alloc] initWithData:(content ?: dispatch_data_empty)
                                                          encoding:NSUTF8StringEncoding];
                if (text == nil) {
                    os_log_error(..., "String data is not UTF-8 encoded");
                    self->_error = [self error:NSURLErrorDomain code:kNSURLErrorCannotDecodeContentData]; // -1016
                } else {
                    message = [[NSURLSessionWebSocketMessage alloc] initWithString:text];
                }
                break;
            }

            case nw_ws_opcode_binary:
                message = [[NSURLSessionWebSocketMessage alloc] initWithData:(content ?: dispatch_data_empty)];
                break;

            case nw_ws_opcode_close:
                self->_closeCode = nw_ws_metadata_get_close_code(meta);
                self->_closeReason = content ?: dispatch_data_empty;
                // A NORMAL, EXPECTED close is represented as a POSIX ENOTCONN "error" —
                // same code as the unexpected-EOF case above! See §7.2.
                self->_error = [self error:NSPOSIXErrorDomain code:ENOTCONN]; // 0x39 == 57
                break;

            case nw_ws_opcode_ping:
            case nw_ws_opcode_pong:
                [self _onqueue_receiveMessageWithCompletionHandler:completion];
                return;

            default:
                os_log_fault(..., "Read unkown opcode %d", opcode); // sic: Apple's own typo
                break; // no message, no new error
        }
    }

    [self->_delegateWork addObject:^{
        completion(message, self->_error);
    }];
    self->_readInProgress = NO;
    [self _onqueue_ioTick];
}
```

Two subtleties worth calling out because they're easy to miss in decompiler-only
output:

* **Ping/Pong control opcodes are swallowed and the read is re-armed** by
  recursively calling `_onqueue_receiveMessageWithCompletionHandler:` — they do
  not surface to app code as `NSURLSessionWebSocketMessage` values.
* The completion handler is **not** called inline from this block; instead the
  result is queued onto `_delegateWork`, `_readInProgress` is cleared, and
  `_onqueue_ioTick` later drains that queue.

### `sendPingWithPongReceiveHandler:` block invoke (`0x186e3d370`)

Same stored-error short-circuit pattern, except the short-circuit path directly
invokes the app's pong handler with the stored error. Otherwise it enqueues a
high-priority work item (`_highPriorityPendingWork`) that later sends the ping
and waits for the connection layer's matching pong.

---

## 4. Close and Cancel

### `_sendCloseCode:reason:` (`0x186e3d87c`) → `_onqueue_sendCloseCode:reason:cancel:` (`0x186e3daac`)

`_sendCloseCode:reason:` itself is just a `dispatch_async` wrapper onto the
task's work queue. The actual work happens in `_onqueue_sendCloseCode:reason:cancel:`.

```objc
- (void)_onqueue_sendCloseCode:(NSURLSessionWebSocketCloseCode)code
                          reason:(NSData *)reason
                          cancel:(BOOL)cancel {
    if (self->_error != nil) return;

    if (cancel) {
        self->_closeCode = code;
        self->_closeReason = reason;
        self->_error = [self error:NSURLErrorDomain code:kNSURLErrorCancelled]; // -999
    }

    nw_content_context_t ctx = nw_content_context_create("websocketCloseWithCodeAndReason");
    nw_content_context_set_is_final(ctx, true);
    nw_ws_metadata_t meta = nw_ws_create_metadata(nw_ws_opcode_close);
    if (code != 0) nw_ws_metadata_set_close_code(meta, code);
    nw_content_context_set_metadata_for_protocol(ctx, meta);
    dispatch_data_t payload = reason ? [reason _createDispatchData] : dispatch_data_empty;
    nw_connection_send(self->_connectionForUpgrade, payload, ctx, true, /* completion block */);
}
```

### `cancelWithCloseCode:reason:` / `cancel` block invokes (`0x186e3ddf8`, `0x186e3e114`)

```objc
void cancelWithCloseCode_block_invoke(__NSURLSessionWebSocketTask *self,
                                      NSURLSessionWebSocketCloseCode code,
                                      NSData *reason) {
    if (self.state == 3) return;
    self.state = 2;

    if (!self->_webSocketHandshakeCompleted) {
        // Handshake never finished — nothing to gracefully close, skip straight to teardown.
        os_log(..., "Cancelling task immediately without sending a close frame");
        self->_error = [self error:NSURLErrorDomain code:kNSURLErrorCancelled]; // -999
        [super _onqueue_cancel];
    } else {
        [self->_pendingSendWork addObject:^{
            [self _onqueue_sendCloseCode:code reason:reason cancel:YES];
        }];
        [self _onqueue_ioTick];
    }
}

void cancel_block_invoke(__NSURLSessionWebSocketTask *self) {
    if (self.state == 3) return;

    if (!self->_webSocketHandshakeCompleted) {
        os_log(..., "Cancelling task immediately without sending a close frame");
        self->_error = [self error:NSURLErrorDomain code:kNSURLErrorCancelled]; // -999
        [super _onqueue_cancel];
    } else {
        self.state = 2;
        [self->_pendingSendWork addObject:^{
            [self _onqueue_sendCloseCode:0 reason:nil cancel:YES];
        }];
        [self _onqueue_ioTick];
    }
}
```

### `_onqueue_cancelWebSocketTaskWithError:` (`0x186e3ea90`)

Generic helper used by the handshake-failure paths above:

```objc
- (void)_onqueue_cancelWebSocketTaskWithError:(NSInteger)code {
    self->_error = [self error:NSURLErrorDomain code:code];
    [self _onqueue_ioTick];
}
```

### `_onqueue_ioTick` (`0x186e3c12c`) — the state machine

Runs after every state change (open, send/receive/ping completions, close
requested, error set). The real function is much larger than the earlier
summary suggested; the faithful high-level shape is:

```objc
- (void)_onqueue_ioTick {
    dispatch_assert_queue(self.workQueue);

    if (self.state == 3) {
        // Already completed. Newer linked SDKs still drain queued work items
        // (high-priority, send, receive, then delegate); older ones just clear
        // some queues and drop the work.
        drainOrDiscardCompletedStateQueuesDependingOnLinkedSDK(self);
        return;
    }

    if (self.state != 0 && self.state != 2) {
        os_log_debug(..., "%@ is not yet connected or suspended. Deferring work",
                     self._loggableDescription);
        return;
    }

    if (!self->_webSocketHandshakeCompleted && self->_error == nil) {
        os_log_debug(..., "%@ handshake not yet complete. Deferring work",
                     self._loggableDescription);
        return;
    }

    drainCopy(self->_highPriorityPendingWork);
    drainCopy(self->_delegateWork);

    if (!self->_readInProgress) {
        id nextReceive = [self->_pendingReceiveWork firstObject];
        if (nextReceive) {
            [self->_pendingReceiveWork removeObjectAtIndex:0];
            nextReceive();
        }
    }

    drainCopy(self->_pendingSendWork);

    if (self->_error != nil || self->_closeCode != 0) {
        scheduleTransportCompletionCheckOnConnectionQueue();

        if (self->_closeCode != 0) {
            [self.session.delegateWrapper webSocketTask:self
                                       didCloseWithCode:self->_closeCode
                                                 reason:self->_closeReason];
            [self _onqueue_cancel_with_error:nil];
        } else {
            [self _onqueue_cancel_with_error:self->_error];
        }
    }
}
```

**Delegate fired here (conditionally):** `URLSession:webSocketTask:didCloseWithCode:reason:`
— but the actual gate is **`_closeCode != 0`**, not "`_error == nil`". So a
received Close frame (which *also* stashes `ENOTCONN` in `_error`) still fires
`didCloseWithCode:reason:` and then tears the task down with **`nil` final
error**. Raw transport failures, by contrast, have `_closeCode == 0`, so they
skip `didCloseWithCode:reason:` and complete with the stored error.

---

## 5. Underlying Connection Failure

### `-[__NSURLSessionWebSocketTask connection:didFinishLoadingWithError:]` (`0x186e40504`)

This override intercepts the base class's normal "the underlying connection
finished (with a transport error)" notification:

```objc
- (void)connection:(id)connection didFinishLoadingWithError:(NSError *)error {
    // *** Extracts ONLY the integer code — see §7.3 for why this is a bug. ***
    [self _onqueue_cancelWebSocketTaskWithError:error.code];
}
```

Recall `_onqueue_cancelWebSocketTaskWithError:` (§4) rebuilds a brand-new error
via `[self error:NSURLErrorDomain code:code]`, which itself is:

### `-[__NSCFLocalSessionTask error:code:]` (`0x186c60bf4`)

```objc
- (NSError *)error:(NSString *)domain code:(NSInteger)code {
    return [NSError _web_errorWithDomain:domain code:code URL:self.currentRequest.URL];
}
```

`_web_errorWithDomain:code:URL:` only populates `NSErrorFailingURLKey` /
`NSErrorFailingURLStringKey` (+ a localized description looked up from the
code) — **no `NSUnderlyingErrorKey`, no original `userInfo`, no certificate
chain, no CFNetwork/CFStream sub-error info.**

---

## 6. Delegate & Closure API Summary

| API | Kind | Fires when |
|---|---|---|
| `URLSession:webSocketTask:didOpenWithProtocol:` | delegate | Handshake validation succeeded, metrics (if any) have been reported, and `_onqueue_enableWebSocketFraming:` is about to reconfigure the connection for WS framing |
| `URLSession:webSocketTask:didCloseWithCode:reason:` | delegate | `_onqueue_ioTick` reaches final teardown with **`_closeCode != 0`** — including peer Close frames and `cancelWithCloseCode:reason:` |
| `URLSession:task:didCompleteWithError:` | delegate (inherited) | Always fires at final teardown via `_onqueue_cancel_with_error:`, whether or not `didCloseWithCode:reason:` fired — this is the one callback guaranteed to always fire |
| `sendMessage:completionHandler:` | closure | Per-message; short-circuits with the stored task error if one already exists |
| `receiveMessageWithCompletionHandler:` | closure | Per-call; delivers the next decoded message/opcode-derived error, or the stored task error if one already exists |
| `sendPingWithPongReceiveHandler:` | closure | App-initiated Ping frame's matching Pong (or short-circuited stored error) |
| `cancel` / `cancelWithCloseCode:reason:` | app-initiated | Sets `NSURLErrorCancelled` (-999) and either sends a close frame (if handshake complete) or tears down immediately (if not) |
| **auto-reply-ping (`nw_ws_options_set_auto_reply_ping`)** | *not app-visible* | libnetwork automatically answers inbound Pings from the *server* with a Pong at the connection layer — entirely separate from, and invisible to, `sendPingWithPongReceiveHandler:` (which is only for App-initiated outbound pings) |

---

## 7. Error-Handling Inconsistencies

The user's core ask was: *"see if there are any errors handled in one way that
isn't in another."* Four concrete inconsistencies were found:

### 7.1 — Domain choice varies by failure path, with no obvious rule

| Failure | Domain | Code | Extra detail preserved? |
|---|---|---|---|
| Handshake: missing / non-HTTP response | `NSURLErrorDomain` | `-1011` (`NSURLErrorBadServerResponse`) | URL only |
| Handshake: `nw_ws_validate_server_response_with_protocol_options` rejects | `NSURLErrorDomain` | `-1011` | **Yes** — `NSURLErrorWebSocketHandshakeFailureReasonKey` |
| Handshake: connection not yet set when response arrives (internal-consistency guard) | `NSURLErrorDomain` | `-1005` (`NSURLErrorNetworkConnectionLost`) | URL only — arguably the wrong code family for what is really an internal-state assertion, not a "connection lost" |
| App cancel (`cancel`/`cancelWithCloseCode:reason:`) | `NSURLErrorDomain` | `-999` (`NSURLErrorCancelled`) | URL only |
| Receive: read failed, no `nw_error`, "expects reply" flag set | **`NSPOSIXErrorDomain`** | `57` (`ENOTCONN`) | URL only |
| Receive: read failed **with** an `nw_error` present | *whatever `nw_error_copy_cf_error` returns* (POSIX/DNS/TLS/etc.) | native | **Yes** — full native CFError preserved |
| Receive: text message fails UTF-8 decode | `NSURLErrorDomain` | `-1016` (`NSURLErrorCannotDecodeContentData`) | URL only |
| Receive: **normal, expected** Close frame from peer | **`NSPOSIXErrorDomain`** | `57` (`ENOTCONN`) | URL only — the *same code as an unexpected EOF*, despite this being a successful protocol event, not a failure |
| Connection-level transport failure (`connection:didFinishLoadingWithError:`) | `NSURLErrorDomain` (forced) | *original error's raw `.code`, reinterpreted under a different domain* | **No** — see §7.3 |

Three completely different "shapes" of error are produced for what a caller
would reasonably consider related situations: normalized `NSURLErrorDomain`
codes with only a URL, `NSPOSIXErrorDomain` codes reused for both real errors
*and* a totally normal close, and (in exactly one place) an untouched native
`nw_error`-derived CFError.

### 7.2 — A *successful* protocol event (peer-initiated close) is represented as an "error"

Receiving an ordinary, expected `Close` frame from the peer is modeled
internally as `NSError(domain: NSPOSIXErrorDomain, code: ENOTCONN)`, stored in
the *same* `_error` ivar used for genuine failures. This is the same code
used for "read failed with no explanation" (§7.1 row 5) — so from the
`receiveMessageWithCompletionHandler:` completion handler's perspective, a
perfectly ordinary "the peer said goodbye" is indistinguishable from an
unexplained I/O failure by domain/code alone (the caller must separately
inspect `task.closeCode`/`closeReason` to tell the difference).

Yet `_onqueue_ioTick` later sees the nonzero `_closeCode`, fires
`didCloseWithCode:reason:`, and tears the task down via
`_onqueue_cancel_with_error:nil`. So the *same event* is surfaced as
`ENOTCONN` at the per-receive API layer, but as a clean/nil-error close at the
final task-completion layer.

### 7.3 — Confirmed, reproducible bug: `connection:didFinishLoadingWithError:` discards all error detail

This is the headline finding. Compare:

* §7.1 row "Receive: read failed **with** an `nw_error` present" — preserves
  the **entire native `CFError`** (domain, code, and full `userInfo` including
  certificate chains, underlying `NSPOSIXError`/DNS/TLS sub-errors, etc.) via
  `nw_error_copy_cf_error`.
* §5's `connection:didFinishLoadingWithError:` — takes an already-normalized
  `NSError` (produced upstream by the ordinary HTTP/connection stack, the same
  kind of error a plain `URLSessionDataTask` would receive) and **extracts
  only its integer `.code`**, discarding its domain, its full `userInfo`
  (including `NSUnderlyingErrorKey`, certificate chain, and CFNetwork/CFStream
  sub-error codes), and its localized description — then rebuilds a bare
  `{NSURLErrorDomain, code, URL only}` error via `-error:code:`.

**These are two different code paths in the exact same class, for the exact
same general category of event (an underlying-transport failure), that handle
error-detail preservation in opposite ways** — one keeps everything, the
other keeps almost nothing.

This is user-visible and easy to demonstrate: performing a `wss://` connection
to a host with an invalid TLS certificate produces an `NSError` with *far*
less diagnostic detail than performing an `https://` request to the identical
host. See `websocket-error-repro.swift` in this directory — running it
against `self-signed.badssl.com` reproduces the following live on macOS:

```
=== URLSessionDataTask (https) error ===
  domain: NSURLErrorDomain
  code:   -1202
  userInfo keys (12): [NSErrorClientCertificateStateKey, NSErrorFailingURLKey,
    NSErrorFailingURLStringKey, NSErrorPeerCertificateChainKey,
    NSLocalizedDescription, NSLocalizedRecoverySuggestion,
    NSURLErrorFailingURLPeerTrustErrorKey, NSUnderlyingError,
    _NSURLErrorFailingURLSessionTaskErrorKey,
    _NSURLErrorRelatedURLSessionTaskErrorKey,
    _kCFStreamErrorCodeKey, _kCFStreamErrorDomainKey]
  underlying: domain=kCFErrorDomainCFNetwork code=-1202

=== URLSessionWebSocketTask (wss) error ===
  domain: NSURLErrorDomain
  code:   -1202
  userInfo keys (4): [NSErrorFailingURLKey, NSErrorFailingURLStringKey,
    NSLocalizedDescription, NSLocalizedRecoverySuggestion]
  underlying: <none>

Summary: dataTask userInfo keys=12, webSocketTask userInfo keys=4
REPRODUCED: WebSocketTask error carries strictly less diagnostic detail than
the equivalent DataTask error for the identical underlying TLS failure.
```

Both requests fail against the *identical host, at the identical TLS
handshake stage*, with the same numeric code (`-1202`,
`NSURLErrorServerCertificateUntrusted`) — yet the WebSocket task's error is
missing `NSUnderlyingError`, the peer certificate chain
(`NSErrorPeerCertificateChainKey`), the trust-evaluation detail
(`NSURLErrorFailingURLPeerTrustErrorKey`), the CFStream sub-error codes, and
the client-certificate state. Any app or diagnostic tool that inspects
`error.userInfo[NSUnderlyingErrorKey]` to distinguish *why* a WebSocket
connection failed (e.g. cert pinning failure vs. DNS failure vs. connection
reset) cannot do so — that information is silently dropped before the error
ever reaches `URLSession:task:didCompleteWithError:`.

### 7.4 — permessage-deflate negotiated from the wrong side (moderate confidence)

`_onqueue_didReceiveResponse:completion:` decides whether to enable
`nw_ws_options_set_permessage_deflate` based on whether the **outgoing
request** has a `Sec-WebSocket-Extensions` header set (which, per §1, CFNetwork
auto-sets to `"permessage-deflate"` if the app didn't supply one) — **not**
based on whether the **response** actually contains a
`Sec-WebSocket-Extensions` header confirming the server agreed to use it.
This means, as decompiled, deflate could be enabled locally even if the
server's handshake response omitted the extension entirely.

**Caveat:** `nw_ws_validate_server_response_with_protocol_options` (an
external/opaque libnetwork symbol, not resident in the CFNetwork binary view
and therefore not decompilable here) may perform its own cross-check between
the negotiated `options` and the actual response headers, and reject the
handshake (via the §3/§7.1 handshake-failure path) if there's a mismatch. This
was **not independently confirmed** — flagging this finding as moderate rather
than high confidence.

---

## 8. Deviations From "Typical" WebSocket Implementations

* **The handshake is not a distinct WebSocket-specific code path** — it's
  performed by CFNetwork's ordinary HTTP request/response machinery, and only
  *after* an HTTP response object exists and
  `nw_ws_validate_server_response_with_protocol_options(...)` accepts it does
  the code call
  `nw_connection_modify_connected_protocol_stack` to splice WebSocket framing
  into the *already-established* `nw_connection`. Most WebSocket client
  implementations treat the handshake as part of a single, dedicated
  WebSocket-connection object rather than reusing a general-purpose HTTP task
  object and "upgrading it in place."
* **Two independent ping/pong mechanisms coexist**: `nw_ws_options_set_auto_reply_ping(true)`
  makes the network layer automatically Pong any inbound Ping from the peer,
  entirely outside the app's visibility — completely separate from
  `sendPingWithPongReceiveHandler:`, which is only for *app-initiated* outbound
  pings. This dual mechanism (one automatic/invisible, one explicit/app-driven)
  is not something apps typically need to reason about with other WebSocket
  client libraries, where the app usually owns all ping/pong logic (or the
  library exposes a single unified mechanism).
* **`didCloseWithCode:reason:` is not delivered for every termination** — it
  fires when `_closeCode != 0` (§4), which includes peer Close frames and
  explicit `cancelWithCloseCode:reason:`, but not raw transport failures or a
  plain `cancel` that never put a close code on the task.
* **A received Close frame is modeled as a POSIX `ENOTCONN` error** (§7.2)
  rather than as a distinct "closed" signal or a WebSocket-specific
  NSURLError code — most other implementations surface a clean/expected close
  via a dedicated enum case or a nil-error "stream ended" signal, not a
  generic POSIX connection error reused from unrelated failure conditions.
* **Default `maximumMessageSize` (1 MiB) is a private/internal default**, not
  independently overridable except via the public
  `URLSessionWebSocketTask.maximumMessageSize` property (which does map to
  this same ivar/`nw_ws_options` call) — consistent with, not a deviation
  from, the documented public API, but worth noting as the actual default
  discovered on-disk.
* Minor curiosity: Apple's own log string for an unrecognized WebSocket opcode
  has a typo — `"Read unkown opcode %d"` (missing the `n` in "unknown").

---

## 9. Reproducer

See `websocket-error-repro.swift` in this directory. It performs, on the same
host (`self-signed.badssl.com`, a public test domain that intentionally serves
an untrusted certificate):

1. A plain `URLSessionDataTask` `https://` request, capturing the completion
   error's full `userInfo`.
2. A `URLSessionWebSocketTask` `wss://` connection + `receive`, capturing the
   resulting error's `userInfo`.

Run with:

```sh
swift websocket-error-repro.swift
```

Confirmed output (macOS, live network) demonstrates the WebSocket task's error
has 4 `userInfo` keys vs. the data task's 12, missing `NSUnderlyingErrorKey`,
the peer certificate chain, the trust-evaluation error, and CFStream
sub-error codes — i.e., §7.3 is a real, currently-reproducible behavior, not
merely a decompiler artifact.

---

## 10. Function Address Reference

| Function | Address |
|---|---|
| `-[NSURLSession webSocketTaskWithRequest:]` | `0x186e1d610` |
| `-[__NSURLSessionLocal webSocketTaskForRequest:]` | `0x186cea1d4` |
| `-[__NSURLSessionWebSocketTask initWithOriginalRequest:ident:taskGroup:]` | `0x186e3b8b8` |
| `_onqueue_resume` | `0x186e3e40c` |
| `_onqueue_didReceiveResponse:completion:` | `0x186e3fb58` |
| `_onqueue_enableWebSocketFraming:` | `0x186e3e560` |
| `sendMessage:completionHandler:` block invokes | `0x186e3bb94`, `0x186e3bda8` |
| `_onqueue_receiveMessageWithCompletionHandler:` | `0x186e3d04c` |
| `_onqueue_receiveMessageWithCompletionHandler:` decode block invoke | `0x186e3f3d0` |
| `sendPingWithPongReceiveHandler:` block invoke | `0x186e3d370` |
| `_sendCloseCode:reason:` | `0x186e3d87c` |
| `_onqueue_sendCloseCode:reason:cancel:` | `0x186e3daac` |
| `cancelWithCloseCode:reason:` block invoke | `0x186e3ddf8` |
| `cancel` block invoke | `0x186e3e114` |
| `_onqueue_cancelWebSocketTaskWithError:` | `0x186e3ea90` |
| `_onqueue_ioTick` | `0x186e3c12c` |
| `-[__NSURLSessionWebSocketTask connection:didFinishLoadingWithError:]` | `0x186e40504` |
| `-[__NSCFLocalSessionTask error:code:]` | `0x186c60bf4` |
| `-[__NSCFURLSessionDelegateWrapper webSocketTask:didCloseWithCode:reason:]` | `0x186cf6f38` |
| `dealloc` | `0x186e3e31c` |

---

## 11. Confidence Notes

* All findings in §§1–6 and 7.1–7.3 are based on direct decompilation of
  CFNetwork functions and are high confidence; §7.3 is additionally confirmed
  by a live, runnable reproducer against real network behavior (§9).
* §7.4 (permessage-deflate) is moderate confidence — the possibility that
  `nw_ws_validate_server_response_with_protocol_options` independently
  enforces correctness (in code outside CFNetwork, not available for
  decompilation here) was not ruled out.
* Behavior described is specific to the disassembled CFNetwork build; exact
  offsets, and potentially some behaviors, may differ across OS versions.
