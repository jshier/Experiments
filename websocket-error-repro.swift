// websocket-error-repro.swift
//
// Demonstrates that URLSessionWebSocketTask discards the rich NSError detail
// (domain, userInfo, underlying-error chain) that an equivalent
// URLSessionDataTask preserves for the *same* underlying transport failure.
//
// Root cause (found via CFNetwork disassembly):
//   -[__NSURLSessionWebSocketTask connection:didFinishLoadingWithError:]
//   calls -[__NSCFLocalSessionTask _onqueue_cancelWebSocketTaskWithError:]
//   with only `error.code`, which reconstructs a *brand new* NSError via
//   `-error:code:` (-> `+[NSError _web_errorWithDomain:code:URL:]`) using a
//   hardcoded NSURLErrorDomain and the current request's URL. The original
//   NSError object (its real domain, userInfo, NSUnderlyingErrorKey chain,
//   and localized failure reason) is thrown away.
//
// Run with:  swift websocket-error-repro.swift
// (macOS, needs network access to self-signed.badssl.com)

import Foundation

let host = "self-signed.badssl.com"
let httpsURL = URL(string: "https://\(host)/")!
let wssURL = URL(string: "wss://\(host)/")!

func describe(_ label: String, _ error: NSError?) {
    print("=== \(label) ===")
    guard let error else {
        print("  (no error!)")
        return
    }
    print("  domain: \(error.domain)")
    print("  code:   \(error.code)")
    print("  localizedDescription: \(error.localizedDescription)")
    let keys = error.userInfo.keys.sorted()
    print("  userInfo keys (\(keys.count)): \(keys)")
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
        print("  underlying: domain=\(underlying.domain) code=\(underlying.code) desc=\(underlying.localizedDescription)")
    } else {
        print("  underlying: <none>")
    }
    print()
}

let session = URLSession(configuration: .ephemeral)
let group = DispatchGroup()

// 1) Plain data task hitting the same TLS failure.
group.enter()
var dataTaskError: NSError?
let dataTask = session.dataTask(with: httpsURL) { _, _, error in
    dataTaskError = error as NSError?
    group.leave()
}
dataTask.resume()

// 2) WebSocket task hitting the identical TLS failure on the same host.
group.enter()
var wsError: NSError?
let wsTask = session.webSocketTask(with: wssURL)
wsTask.resume()
wsTask.receive { result in
    if case .failure(let error) = result {
        wsError = error as NSError
    }
    group.leave()
}

group.wait()

describe("URLSessionDataTask (https) error", dataTaskError)
describe("URLSessionWebSocketTask (wss) error", wsError)

if let d = dataTaskError, let w = wsError {
    let dataKeyCount = d.userInfo.keys.count
    let wsKeyCount = w.userInfo.keys.count
    print("Summary: dataTask userInfo keys=\(dataKeyCount), webSocketTask userInfo keys=\(wsKeyCount)")
    if wsKeyCount < dataKeyCount {
        print("REPRODUCED: WebSocketTask error carries strictly less diagnostic detail than the equivalent DataTask error for the identical underlying TLS failure.")
    } else {
        print("NOT REPRODUCED on this OS/runtime: error detail appears equivalent.")
    }
}
