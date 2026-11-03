# URLSession Response-Header Special Behavior

Reverse-engineered from `CFNetwork` inside the `dyld_shared_cache_arm64e` (Binary Ninja, arm64e disassembly/decompilation via `binary-ninja-mcp`). This is the response-side counterpart to `URLSession-Reserved-HTTP-Headers.md`: it documents HTTP **response** headers that CFNetwork inspects and acts on internally — beyond simply handing them to the app via `-[NSHTTPURLResponse allHeaderFields]` — including cookie storage, transparent decompression, connection reuse, authentication challenges, and redirect handling.

## Method

Traced the response pipeline from the socket/stream layer up through delegate callbacks:

1. `HTTPConnection::_onqueue_responseHeadersArrived` (`0x186c70684`) — the first point after the status line + headers are fully parsed, before any body bytes are delivered.
2. `HTTPProtocol::updateCookieStoreDuringHeaderRead` (`0x186c7555c`) → `HTTPResponseMessage::copyCookiesStrings` (`0x186c7561c`) — cookie ingestion.
3. `CFURLDataDecoderCreateWithContentEncoding` (`0x186c8bd30`) — transparent content decoding.
4. `canKeepAlive` (`0x186c7159c`) — connection-reuse decision.
5. `AuthenticationState::updateWithResponse` (`0x186c739c8`) / `HTTPConnectionAuthenticator::updateWithResponse` (`0x186c70f28`) — 401/407 challenge handling.
6. `HTTPProtocol::attemptRedirection` (`0x186dc3014`) — 3xx redirect construction, the richest source of special-cased header behavior found.
7. Resolved every opaque 32-bit header-ID token (e.g. `0x13111358`) the same way as the request-header analysis: by indexing CFNetwork's internal `_gConstantCFStringValueTable` (`0x1e77adbb0`, 0x38-byte entries) and reading the pointed-to character buffer directly out of the binary, rather than guessing from context.

## Summary Table

| Header | Behavior | Where in CFNetwork | Notes |
|---|---|---|---|
| **Set-Cookie** | Parsed out of the response as soon as headers arrive (before the body is read) and written into the session's cookie storage | `HTTPProtocol::updateCookieStoreDuringHeaderRead` (`0x186c7555c`) → `HTTPResponseMessage::copyCookiesStrings`/`__CFHTTPCookieCreateCookiesWithResponseMessage` | Gated by a per-transaction "already handled" flag (bit `0x2` of a state field) so redirects don't double-store; ultimately governed by the session's `HTTPCookieStorage`/`httpCookieAcceptPolicy`, same as request-side Cookie injection |
| **Content-Encoding** | Body is **transparently decompressed** before being delivered to the delegate/completion handler; the app never sees the compressed bytes | `CFURLDataDecoderCreateWithContentEncoding` (`0x186c8bd30`): encoding id `3` → raw-inflate (`inflateInit2_` with `windowBits=-15`, i.e. **gzip**), id `5` → zlib inflate (`inflateInit_`, i.e. **deflate**), id `6` → `compression_stream_init` (**br**/Brotli) | Recognized encodings still return `NULL` if the decoder object fails its post-init readiness check; otherwise the caller gets a live decoder and the app-visible bytes are plaintext |
| **Content-Length** | If `Content-Length` is present, the response is classified as "known length" (`K`); otherwise CFNetwork uses the response's precomputed chunked flag to choose "chunked" (`C`) vs "unknown length" (`U`) | `HTTPConnection::_onqueue_responseHeadersArrived` (`0x186c70684`) | An "unknown length" (`U`) HTTP/1.x response can't be kept alive — the connection must be closed after the body, since there's no other way to know where the response ends |
| **Connection** / **Proxy-Connection** | Consulted to decide whether the TCP connection can be reused: exact `"close"` disables reuse, exact `"keep-alive"` enables it, exact `"upgrade"` disables it, and comma-separated token lists are only accepted when they contain `keep-alive` and not `close`; only if neither header is present does CFNetwork fall back to HTTP-version defaults | `canKeepAlive` (`0x186c7159c`), called from `_onqueue_responseHeadersArrived` | Header IDs resolved: `Connection` = `0x11c152db`, `Proxy-Connection` = `0x13a21397` — `Proxy-Connection` is checked first (proxied connections), then `Connection` |
| **Keep-Alive** | Hand-parsed and used only for a reuse-timeout override: CFNetwork accepts either a bare positive integer token or `timeout=<positive int>` inside the comma-separated list | `HTTPConnection::_onqueue_responseHeadersArrived` (`0x186c70684`), reads the header via `_CFHTTPMessageCopyHeaderFieldValue` and tokenizes on `,` then `=` | `max=M` is **not** consumed here; if no valid timeout is found, no explicit reuse-timeout override is applied (the pool falls back to its default idle timeout) |
| **Upgrade** | On a `101 Switching Protocols`, the mere presence of `Upgrade` causes the connection to be taken out of ordinary HTTP request reuse | `HTTPConnection::_onqueue_responseHeadersArrived` (`0x186c70684`); header ID `0x14a0f418` resolved to `"Upgrade"` | This code path does **not** validate the header value; it sets a flag and calls `_onqueue_doNotAllowMoreRequests`, and a `101` also bypasses the normal keep-alive/content-framing path |
| **WWW-Authenticate** / **Proxy-Authenticate** | Parsed into an `HTTPAuthentication` object that drives the `-URLSession:task:didReceiveChallenge:completionHandler:` delegate callback; `407`/`401` are handled with distinct proxy-vs-origin logic | `AuthenticationState::updateWithResponse` (`0x186c739c8`) → `HTTPAuthentication::updateFromResponse`, `AuthenticationState::_isLikelyForProxy` (`0x186c7115c`) | A `407` response received when the connection isn't already known to be a proxy tunnel logs `"Received unexpected proxy response"` — CFNetwork treats that as an anomaly worth flagging even though it still attempts to authenticate |
| **Location** | Read only on redirect-eligible status codes; percent-escaped and resolved against the session request URL (`currentRequest` on newer SDKs, `originalRequest` on older ones) to build the redirect target | `HTTPProtocol::attemptRedirection` (`0x186dc3014`); header ID `0x13111358` resolved to `"Location"` | A missing or empty `Location` on a 3xx response **cancels the redirect** entirely (the response is delivered to the app as a normal, terminal response instead); an unparseable escaped URL takes the separate `sendError(-0x3f2)` failure path |
| **Location → file scheme** | If the resolved redirect target's scheme is `"file"`, the redirect is unconditionally rejected with an internal error, regardless of same-origin status | `HTTPProtocol::attemptRedirection` (`0x186dc3014`): `CFStringCompare(scheme, "file")` → `HTTPProtocol::sendError(arg1, -0x44e)` | Hard-coded security guard against an HTTP response redirecting the app into reading local files |
| **(redirect) Authorization** / **Proxy-Authorization** | Unconditionally stripped from the request object before the redirected request is dispatched | `HTTPProtocol::attemptRedirection` (`0x186dc3014`): `_CFURLRequestSetHTTPHeaderFieldValue(cf, <Authorization table entry>, nullptr)` and same for `Proxy-Authorization` | Not a data loss — both are recomputed for the *new* destination later via the same async credential-injection path used on the original request (`asynchronouslyAddAuthenticatorHeadersAndContinue`), so credentials for the new host/realm are added back if available; credentials for the old host are simply not carried over |
| **(redirect) Origin** | `Origin` is cleared only when `haveTheSameOrigin(originalURL, redirectURL)` is false (i.e. scheme, host, or port differs) | `HTTPProtocol::attemptRedirection` (`0x186dc3014`), immediately after the origin check | Raw disassembly resolves the literal as `_kCFHTTPHeaderOrigin` (`0x1e77b1f10`), so this is not a guess |
| **(redirect) Content-Length / Content-Type / body** | Cleared, along with the request body/body-stream, whenever the redirect forces a method change to `GET` | `HTTPProtocol::attemptRedirection` (`0x186dc3014`), `label_186dc32d4` | Triggered unconditionally for `303 See Other`; also triggered for `301`/`302` when the pre-redirect request method is `POST` (confirmed by the `_kCFHTTPMethodPost` compare in raw disassembly) |
| **HSTS policy (private state, not a header)** | The original request's private HSTS policy object is copied onto the new redirected request | `HTTPProtocol::attemptRedirection` (`0x186dc3014`), `_copyHSTSPolicy` | Ensures HSTS upgrade-to-HTTPS enforcement isn't lost across a redirect chain |

## Detail: Content-Encoding transparent decompression

```objc
// CFURLDataDecoderCreateWithContentEncoding(allocator, encodingID)
URLDataDecoder *CFURLDataDecoderCreateWithContentEncoding(CFAllocatorRef allocator, int32_t encodingID) {
    URLDataDecoder *decoder = NULL;

    switch (encodingID) {
        case 3: // "gzip"    -> raw DEFLATE, windowBits = -15 (no zlib/gzip header re-parsing needed)
            decoder = URLDataDecoderHolder_new();
            inflateInit2_(&decoder->zstream, -15, ZLIB_VERSION, sizeof(z_stream));
            break;
        case 5: // "deflate" -> standard zlib-wrapped DEFLATE
            decoder = URLDataDecoderHolder_new();
            inflateInit_(&decoder->zstream, ZLIB_VERSION, sizeof(z_stream));
            break;
        case 6: // "br"      -> Apple's `compression` framework, Brotli decode mode
            decoder = URLDataDecoderHolder_new();
            compression_stream_init(&decoder->cstream, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI);
            break;
        default:
            return NULL; // unrecognized Content-Encoding is *not* decoded — passed through as-is
    }

    if (!decoder->vtable->isReady(decoder)) {  // post-init virtual check in the real binary
        CFRelease(decoder);
        return NULL;
    }

    return decoder;
}
```

Every received chunk of body data is piped through this decoder before being handed to `-URLSession:dataTask:didReceiveData:` or accumulated for a completion-handler-based task. The app-visible `NSData` is always plaintext; there is no API to opt out of this and see the raw compressed bytes for `gzip`/`deflate`/`br`. Unrecognized encodings fall through untouched.

## Detail: redirect handling (`HTTPProtocol::attemptRedirection`, `0x186dc3014`)

```objc
// Runs once _onqueue_responseHeadersArrived recognizes a 3xx status and redirects aren't disabled.
BOOL HTTPProtocol::attemptRedirection(HTTPProtocol *self, CFHTTPMessageRef response) {
    if (task.isCancelled || !self->currentRequest) return NO;

    NSString *location = [HTTPMessage copyLastHeaderFieldValue:response header:kLocation]; // "Location"
    if (location == nil || location.length == 0) {
        self->wantsRedirect = NO;
        return YES; // deliver response as-is; no redirect attempted
    }

    NSString *escaped = CFURLCreateStringByAddingPercentEscapes(location, ...);
    NSURLRequest *baseRequest =
        dyld_program_sdk_at_least(...) ? task.currentRequest : task.originalRequest;
    NSURL *redirectURL = resolveAgainstRequestURL(escaped, baseRequest);
    if (redirectURL == nil) {
        [self sendError:-0x3f2];
        [self destroyReadStream];
        return NO;
    }

    NSURL *absoluteRedirectURL = redirectURL.absoluteURL;
    if ([absoluteRedirectURL.scheme isEqualToString:@"file"]) {
        [self sendError:kCFURLErrorRedirectToNonExistentLocationLikely]; // -0x44e
        return NO; // hard block: never redirect an HTTP(S) load into file://
    }

    NSMutableURLRequest *redirected = [self->currentRequest mutableCopy];
    redirected.URL = absoluteRedirectURL;

    NSInteger status = CFHTTPMessageGetResponseStatusCode(response);
    if (status == 303 ||                                   // See Other: always GET, drop body
        ((status == 301 || status == 302) && [redirected.HTTPMethod isEqualToString:@"POST"])) {
        redirected.HTTPMethod = @"GET";
        redirected.HTTPBody = nil;
        [redirected _setHTTPBodyParts:nil knownLength:0];
        redirected.HTTPBodyStream = nil;
        [redirected setValue:nil forHTTPHeaderField:@"Content-Length"];
        [redirected setValue:nil forHTTPHeaderField:@"Content-Type"];
    }

    if (!haveTheSameOrigin(self->currentRequest.URL, absoluteRedirectURL)) {
        [redirected setValue:nil forHTTPHeaderField:@"Origin"];
    }
    [redirected setValue:nil forHTTPHeaderField:@"Authorization"];
    [redirected setValue:nil forHTTPHeaderField:@"Proxy-Authorization"];

    redirected._shouldPipelineHTTP = /* preserved/recomputed from original request's HTTP/1.1 pipelining eligibility */;
    redirected._inner.hstsPolicy = [task _copyHSTSPolicy]; // carry HSTS enforcement forward

    HTTPProtocol::updateForHeader(self, response); // final header bookkeeping before handoff

    NSURLRequest *finalRedirected = [NSURLRequest _initWithCFURLRequest:redirected];
    id<NSURLProtocol> protocolClass = [session _protocolClassForRequest:finalRedirected];
    if (protocolClass) {
        finalRedirected = [protocolClass canonicalRequestForRequest:finalRedirected task:task];
        // <- re-enters the *request*-header canonicalization pipeline: Accept/Accept-Language/
        //    Accept-Encoding/Content-Type defaults are re-applied fill-if-missing exactly as for
        //    the original request.
    }

    [client URLProtocol:self wasRedirectedToRequest:finalRedirected redirectResponse:response];
    // -> eventually surfaces as -URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:
    return YES;
}
```

## Caveats / Confidence

- **High confidence**: Set-Cookie ingestion timing, Content-Encoding transparent decompression algorithms (gzip/deflate/br mapping), Connection/Proxy-Connection keep-alive logic, Keep-Alive timeout parsing, Upgrade handling on 101, Location-driven redirect construction, malformed-`Location` failure path, `file:` scheme redirect block, unconditional stripping of Authorization/Proxy-Authorization on redirect, cross-origin stripping of `Origin`, POST→GET rewrite on 301/302 and 303, HSTS policy carry-over, header-name resolution for every header listed (via direct table read).
- **Not covered**: HTTP/2 and HTTP/3 response-header handling (pseudo-headers, `:status`, etc.) — this analysis followed the classic `HTTPProtocol`/`HTTPResponseMessage` HTTP/1.1-oriented code path, matching the scope of the request-header write-up.
