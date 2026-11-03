# URLSession Reserved / Auto-Managed HTTP Headers

Reverse-engineered from `CFNetwork` inside the `dyld_shared_cache_arm64e` (Binary Ninja, arm64e disassembly/decompilation via `binary-ninja-mcp`). This documents which HTTP headers set via `-[NSMutableURLRequest setValue:forHTTPHeaderField:]` are silently overridden, filled-in, or otherwise treated specially by `URLSession`'s built-in HTTP stack, and exactly where/how in CFNetwork this happens.

## Method

1. Located the canonicalization entry point that runs on every task before a connection is created:
   `-[__NSURLSessionLocal _onqueue_canonicalizeTaskAndCreateConnection:]` → `_createCanonicalRequestForTask:` → `-[NSURLProtocol canonicalRequestForRequest:task:]` → **`HTTPProtocol::_createCanonicalRequest`** (`0x186db8b5c`).
2. Decompiled the private helper `addHeaderIfMissing(CFURLRequest*, HeaderID, defaultValueBlock, suppressedHeaderSet)` (`0x186db96b8`) that this function calls repeatedly.
3. Decompiled `URLRequest::_setHTTPBodyParts` (`0x186d6b940`) / `FormContentLengthWithArray` (`0x186c457c4`) / `HTTPMessage::setHeaderFieldScalarValue` (`0x186c4594c`), which govern body-derived headers.
4. Decompiled `HTTPProtocol::asynchronouslyAddCookiesAndContinue` (`0x186c4be6c`) and `HTTPProtocol::asynchronouslyAddAuthenticatorHeadersAndContinue` (`0x186c4dc70`), which run *after* canonicalization, immediately before the socket stream is opened.
5. Header names in CFNetwork are represented internally as opaque 32-bit "header ID" tokens (e.g. `0x1201d2fd`), not raw strings. These tokens index into a global constant table, `_gConstantCFStringValueTable` (`0x1e77adbb0`), whose entries are 0x38-byte, 7-qword `CFString`-like records: `{isa, flags, charsPtr, length, tokenQword, extra, extra}`; in the entries sampled here, the low 32 bits of `tokenQword` matched the observed header/value token. Reading this table directly (`bn_memory_read` over the computed entry addresses, then the pointed-to char buffers) definitively resolved every header ID referenced below (e.g. index 284 → `0x11c152db` → `"Connection"`, index 298 → `0x12a09330` → `"Host"`, index 288 → `0x1201d2fd` → `"Content-Length"`), rather than relying only on inferred default values.

## Summary Table

| Header | Behavior | Where in CFNetwork | Can the app override it? |
|---|---|---|---|
| **Accept** | Filled with `*/*` **only if missing** | `_createCanonicalRequest` → `addHeaderIfMissing(0x1120d294, …)` | Yes — fully honored if set |
| **Accept-Language** | Filled with `__CFNetworkCopyPreferredLanguageCode()` result **only if missing** | `_createCanonicalRequest` → `addHeaderIfMissing(0x1141f2a0, …)` | Yes — fully honored if set |
| **Accept-Encoding** | Filled with `"gzip, deflate"` (or `"gzip, deflate, br"` for HTTPS on newer SDKs) **only if missing** | `_createCanonicalRequest` → `addHeaderIfMissing(0x1131f298, …)` | Yes — fully honored if set |
| **Content-Type** | Filled with `"application/x-www-form-urlencoded"` **only if missing on POST requests whose request message already has body/body-part/body-stream state** | `_createCanonicalRequest` → `addHeaderIfMissing(0x1221930e, …)` | Yes — fully honored if set |
| **If-Modified-Since** / conditional validators | Added from the cached-response metadata **only if missing** (cache revalidation) | `HTTPProtocol::updateHTTPMessageWithCondtionalHeaders` (`0x186ca630c`) | Yes — only added when absent |
| **Content-Length** | **Always computed and force-set** from the actual body size, discarding any app-supplied value | `URLRequest::_setHTTPBodyParts` (`0x186d6b940`) → `FormContentLengthWithArray` + `HTTPMessage::setHeaderFieldScalarValue` (hardcodes header ID `0x1201d2fd`) | **No** — recomputed whenever a body/body-stream is attached |
| **Transfer-Encoding** | **Always force-set to `"chunked"`** when the body length can't be determined up front (e.g. an `NSInputStream` body part), and the framework removes `Content-Length` in that case (and vice versa) | Same function as above; sets header ID `0x1492340f` to value token `0x15c0f492` (resolved via `_gConstantCFStringValueTable` to `"chunked"`) and removes the other header | **No** — mutually exclusive with Content-Length, chosen by the framework |
| **Cookie** | System `HTTPCookieStorage` cookies for the request's URL are fetched and written with an **unconditional set/overwrite** (`_CFHTTPMessageSetMultipleHeaderFields`) whenever `HTTPShouldHandleCookies`/`httpCookieAcceptPolicy` allows it | `HTTPProtocol::asynchronouslyAddCookiesAndContinue` (`0x186c4be6c`) + block invoke (`0x186cb1614`) → `-[__NSURLSessionLocal _getCookieHeadersForTask:completionHandler:]` → `XCookieStorage::getRequestHeaderFieldsForTask` | **Effectively no** if cookie handling is enabled — the stored cookie jar wins. Only reliably overridden by disabling cookie handling on the session configuration |
| **Authorization** / **Proxy-Authorization** | When credentials are available (from a prior challenge / keychain / `URLCredentialStorage`), the computed auth header is written with the same unconditional `_CFHTTPMessageSetMultipleHeaderFields` merge | `HTTPProtocol::asynchronouslyAddAuthenticatorHeadersAndContinue` (`0x186c4dc70`) + block invoke (`0x186c50fac`) → `-[NSURLSession _getAuthenticationHeadersForResponse:completionHandler:]` | **No**, once the stack has credentials for the protection space — it will overwrite a manually supplied header on retries/challenge responses |
| **Host** | **Never read, written, or overridden anywhere in CFNetwork's own request-construction, canonicalization, or wire-serialization code.** Whatever the app sets (or doesn't set) for `Host` is passed straight through untouched. | See "Detail: Host Header" below — traced through `_createCanonicalRequest`, both `HTTPRequestMessage`/`HTTPRequest` constructors, and the actual wire serializer `HTTPMessage::copySerializedHeaders` (`0x186c6bee4`); header ID `0x12a09330` (`Host`) does not appear as an argument to any header-set/header-read call in any of them | **Yes, fully** — CFNetwork's own code never touches it. (If the app omits it, CFNetwork's own code does not add a default either; any origin-derived `Host`/HTTP-2 `:authority` value must come from the underlying `nw_connection`/Network.framework transport layer, which lives outside this binary and was not reachable for further decompilation.) |
| **Connection** / **Proxy-Connection** | Not set via `addHeaderIfMissing` or any other audited canonicalization/body-path function here; however, this file did not fully decompile the final serializer / stream setup responsible for the wire bytes. | Header IDs `0x11c152db` (`Connection`) / `0x13a21397` (`Proxy-Connection`) resolved from `_gConstantCFStringValueTable`, but no `setHeaderFieldStringValue`/`addHeaderIfMissing` call site references them were found in the audited functions | **Undetermined from the audited functions here** |

## Detail: Content-Length / Transfer-Encoding (`URLRequest::_setHTTPBodyParts`, `0x186d6b940`)

Simplified reconstruction:

```objc
// Called whenever -setHTTPBody:/-setHTTPBodyStream:/multipart body parts are attached to a request.
void URLRequest::_setHTTPBodyParts(URLRequest *self, CFArrayRef bodyParts, int64_t knownLength) {
    HTTPMessage *msg = self->_httpMessage ?: URLRequest::createHTTPRequest(self);

    if (bodyParts == NULL) {
        // No body: strip any body-size headers entirely.
        [msg removeHeaderFieldValue:kHeaderTransferEncoding]; // "Transfer-Encoding"
        [msg removeHeaderFieldValue:kHeaderContentLength];    // "Content-Length"
        return;
    }

    int64_t computedLength = FormContentLengthWithArray(bodyParts); // sums CFData/file sizes; -1 if a stream part exists

    if (computedLength - knownLength < 0) {
        // Length not knowable up-front (e.g. NSInputStream body) -> stream chunked.
        [msg setHeaderFieldStringValue:kHeaderTransferEncoding value:@"chunked"]; // actual call passes value token 0x15c0f492
        [msg removeHeaderFieldValue:kHeaderContentLength]; // any user-set Content-Length is discarded
    } else {
        // Length known -> always recomputed from the actual body, never taken from the app's header.
        [msg setHeaderFieldScalarValue:(computedLength - knownLength)]; // hardcoded to Content-Length (0x1201d2fd)
        [msg removeHeaderFieldValue:kHeaderTransferEncoding];
    }
}
```

`HTTPMessage::setHeaderFieldScalarValue` (`0x186c4594c`) hardcodes the header key to `0x1201d2fd` ("Content-Length") and formats the value with `CFStringCreateWithFormat(@"%lld", value)`, then calls `HTTPHeaderDict::setValue`, an unconditional overwrite — there is no "if missing" check anywhere in this path. Any `Content-Length` the app sets via `setValue:forHTTPHeaderField:` is discarded the moment a body is attached.

## Detail: fill-if-missing defaults (`addHeaderIfMissing`, `0x186db96b8`)

```objc
static void addHeaderIfMissing(CFURLRequest *request, HTTPHeaderID headerID,
                                CFStringRef (^defaultValueBlock)(void),
                                NSSet *suppressedAutoAddedHTTPHeaders) {
    if ([suppressedAutoAddedHTTPHeaders containsObject:HeaderNameStringForID(headerID)]) return;
    CFStringRef value = defaultValueBlock();
    if (!value) return;

    HTTPMessage *msg = _CFURLRequestGetHTTPRequestMessage(request);
    if (!msg) msg = URLRequest::createHTTPRequest(request); // lazily materialized here if needed

    if (!HTTPMessage::hasHeaderField(msg, headerID))
        HTTPMessage::setHeaderFieldStringValue(msg, headerID, value);

    CFRelease(value);
}
```

Two non-obvious details from the raw disassembly:

- The suppression set is a set of header-name `CFString` objects looked up via `_gConstantCFStringValueTable`, not a set of raw 32-bit header tokens.
- `addHeaderIfMissing` evaluates the default-value block **before** checking whether the header is already present.

This confirms **Accept, Accept-Language, Accept-Encoding, and Content-Type are not forcibly overridden** — CFNetwork only supplies a sensible default when the app hasn't set a value. The `Content-Type` case is narrower than the other three: in `HTTPProtocol::_createCanonicalRequest`, it is only attempted on the observed POST path when the request message already has body/body-part/body-stream state.

## Detail: Cookie / Authorization injection (post-canonicalization)

Both run asynchronously, right before the socket stream is opened, and both funnel through the same primitive:

```objc
// HTTPProtocol::asynchronouslyAddCookiesAndContinue (0x186c4be6c)
[session _getCookieHeadersForTask:task completionHandler:^(NSDictionary *cookieHeaders) {
    _CFHTTPMessageSetMultipleHeaderFields(httpMessage, (CFDictionaryRef)cookieHeaders); // unconditional set
    continueOpeningConnection();
}];

// HTTPProtocol::asynchronouslyAddAuthenticatorHeadersAndContinue (0x186c4dc70)
[session _getAuthenticationHeadersForResponse:nil completionHandler:^(NSDictionary *authHeaders) {
    _CFHTTPMessageSetMultipleHeaderFields(httpMessage, (CFDictionaryRef)authHeaders); // unconditional set
    continueOpeningConnection();
}];
```

`HTTPProtocol::asynchronouslyAddAuthenticatorHeadersAndContinue` also has a fast path that directly applies a previously prepared header dictionary without issuing the async lookup above. In the raw disassembly the auth side is also slightly more indirect than the cookie side: block `0x186c50fac` packages the returned dictionary/request state into a second continuation block, rather than calling `_CFHTTPMessageSetMultipleHeaderFields` inline itself.

For ordinary string→string header dictionaries like the cookie/auth maps on these paths, `_CFHTTPMessageSetMultipleHeaderFields` tail-calls `HTTPMessage::setMultipleHeaderFields`, which iterates the dictionary and calls `HTTPMessage::setHeaderFieldStringValue` per key — an overwrite, not an append. (There is also a separate special `__hhaa__` path inside `HTTPMessage::setMultipleHeaderFields` for array-valued encoded header data, but that is not what the cookie/auth paths here use.) So a matching cookie/credential from the system stores replaces whatever the app put in the request's `Cookie`/`Authorization` field (this only happens when the session actually has cookies/credentials to contribute; if cookie handling is disabled or no credential exists, the app's header passes through untouched).

## Detail: Host Header — Finalized Conclusion

This was previously left "undetermined" pending decompilation of the actual wire serializer. That work is now done; the conclusion is **CFNetwork's own code never touches the `Host` header**, established by tracing every plausible injection point:

1. **Canonicalization (`HTTPProtocol::_createCanonicalRequest`, `0x186db8b5c`)** — fully decompiled. It calls `addHeaderIfMissing(result, headerID, defaultValueBlock, suppressedSet)` exactly four times, with header IDs `0x1120d294` (Accept), `0x1141f2a0` (Accept-Language), `0x1131f298` (Accept-Encoding), and conditionally `0x1221930e` (Content-Type, POST-with-body only). Header ID `0x12a09330` (`Host`) never appears as an argument anywhere in this function.

2. **Message construction (`HTTPRequestMessage::HTTPRequestMessage` `0x186c3d80c`, `HTTPRequest::HTTPRequest` `0x186c3d668`)** — both constructors were re-checked at the disassembly level. The one non-obvious argument in `HTTPRequest::HTTPRequest` (rendered by the decompiler as a repeated `"Pg="` placeholder — a known artifact where Binary Ninja fails to resolve a `_gConstantCFStringValueTable` entry to readable text) was resolved directly via `bn_memory_read`: it is the literal string `"HTTP/1.1"` (the protocol-version string passed down for the request line), **not** anything Host-related. Neither constructor writes to the header dictionary at all.

3. **Wire serialization (`HTTPMessage::copySerializedHeaders`, `0x186c6bee4`)** — the actual function that turns the in-memory header dictionary into the bytes written to the socket. It does nothing but concatenate the request/status line, call `HTTPHeaderDict::visitHeaders` to walk whatever key/value pairs already exist in the dictionary, and append `CRLF`s. There is no header-specific logic of any kind here — it will faithfully serialize a `Host` header if and only if one is already present in the dictionary at this point.

4. **`HTTPWriteFilter::transmitHeader` (`0x186ccd3cc`)** — the only CFNetwork function found that calls `CFURLCopyHostName` (checked all 56 call sites of that import via `bn_function_xrefs_to`). Fully decompiled: it uses the request's host name purely to set a **`CFWriteStream`/`CFReadStream` property** (an internal NTLM-connection-affinity/keep-alive cache key, `CFWriteStreamSetProperty(stream, "Pg=", hostName)` — again a table-resolved constant, not an HTTP header write) — it never calls `HTTPMessage::setHeaderFieldStringValue`/`setHeaderFieldScalarValue` with the `Host` header ID. This function is unrelated to writing the wire `Host:` header line.

5. No function in this CFNetwork binary has a symbol name containing `"authority"` (searched via `bn_function_search`), so the HTTP/2 `:authority` pseudo-header equivalent is not implemented in CFNetwork proper either — it, and any implicit `Host`-from-URL insertion for HTTP/1.1, must be the responsibility of the underlying `nw_connection`/Network.framework transport (outside this binary, not reachable for decompilation here, consistent with the same kind of external-boundary caveat noted for `nw_ws_validate_server_response_with_protocol_options` in the WebSocket lifecycle report).

**Net effect for app developers:** setting `Host` manually via `-[NSMutableURLRequest setValue:forHTTPHeaderField:]` is honored as-is by every layer of CFNetwork that was reachable for analysis — nothing here silently overrides or ignores it. This is a stronger and different conclusion than the (also true, and separately handled) Network.framework/HTTP transport behavior of deriving a default `Host`/`:authority` from the URL when the app doesn't set one.

## Caveats / Confidence

- **High confidence**: Content-Length, Transfer-Encoding, Accept, Accept-Language, Accept-Encoding, Content-Type — directly observed default values and/or hardcoded header-set logic.
- **High confidence**: **Host** — now conclusively traced end-to-end (canonicalization → construction → wire serialization → the one function calling `CFURLCopyHostName`) with no CFNetwork code path found that reads or writes it; see "Detail: Host Header" above.
- **High confidence** on header-name resolution for all headers listed (Host, Connection, Proxy-Connection, Cookie, Set-Cookie, Authorization, Proxy-Authorization, User-Agent, etc.) — resolved directly from `_gConstantCFStringValueTable`, not inferred.
- **Moderate confidence**: Connection — absence of any header-dict write in the audited functions strongly suggests the interesting behavior lives later in serialization / stream setup, but this file did **not** individually decompile the exact call site that emits that final wire-level header (unlike Host, which now has its serialization call site conclusively ruled out).
- **Moderate confidence**: Cookie/Authorization overwrite semantics — confirmed the primitive used is a `set`, not an `add`/append, but whether it's called at all (and thus whether it clobbers an app value) depends on runtime state (cookie storage contents, cached credentials) not visible from static disassembly alone.
- **Not covered**: `WWW-Authenticate`/`Proxy-Authenticate` (response-only headers, not request-side), and any header behavior specific to HTTP/2 or HTTP/3 transports (this analysis followed the classic `HTTPProtocol`/`HTTPMessage` HTTP/1.1-oriented code path).
