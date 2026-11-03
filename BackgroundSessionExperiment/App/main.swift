import UIKit

let base = "http://127.0.0.1:8080"
let t0 = Date()
func log(_ s: String) {
    let t = String(format: "%7.3f", Date().timeIntervalSince(t0))
    let th = Thread.isMainThread ? "main" : "bg"
    print("[\(t)] [\(th)] \(s)")
    fflush(stdout)
}
func desc(_ e: Error?) -> String {
    guard let e = e as NSError? else { return "nil" }
    return "\(e.domain)#\(e.code) (\(e.localizedDescription))"
}

let isFG = CommandLine.arguments.contains("fg")

func headerSummary(_ data: Data) -> String {
    guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let hs = j["headers"] as? [[String: String]] else { return "(no header echo)" }
    let keep: Set<String> = ["cookie", "user-agent", "accept", "accept-language", "accept-encoding", "authorization", "content-length", "content-type", "connection"]
    return hs.compactMap { h in
        guard let n = h["name"], keep.contains(n.lowercased()) else { return nil }
        return "\(n)=\(h["value"] ?? "")"
    }.joined(separator: "; ")
}

final class Delegate: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, URLSessionStreamDelegate, URLSessionWebSocketDelegate {
    var willBeginDisposition: URLSession.DelayedRequestDisposition = .continueLoading
    var responseDisposition: URLSession.ResponseDisposition = .allow
    var followRedirects = true
    var challengeDisposition: URLSession.AuthChallengeDisposition = .useCredential
    var onDone: (() -> Void)?
    var pending = 0
    let tag: String
    var bodies: [Int: Data] = [:]
    var chunks: [Int: [Int]] = [:]
    var writes: [Int: [Int64]] = [:]
    var sends: [Int: [Int64]] = [:]
    var showHeaders = false
    init(tag: String) { self.tag = tag }

    func urlSession(_ s: URLSession, didBecomeInvalidWithError e: Error?) { log("\(tag) session.didBecomeInvalidWithError \(desc(e))") }
    func urlSession(_ s: URLSession, task: URLSessionTask, willBeginDelayedRequest r: URLRequest, completionHandler ch: @escaping (URLSession.DelayedRequestDisposition, URLRequest?) -> Void) {
        log("\(tag) willBeginDelayedRequest id=\(task.taskIdentifier) \(r.url!.path) -> disposition \(willBeginDisposition.rawValue)")
        ch(willBeginDisposition, nil)
    }
    func urlSession(_ s: URLSession, taskIsWaitingForConnectivity t: URLSessionTask) { log("\(tag) taskIsWaitingForConnectivity id=\(t.taskIdentifier)") }
    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest n: URLRequest, completionHandler ch: @escaping (URLRequest?) -> Void) {
        log("\(tag) willPerformHTTPRedirection id=\(task.taskIdentifier) \(r.statusCode) -> \(n.url!) follow=\(followRedirects)"); ch(followRedirects ? n : nil)
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didReceive c: URLAuthenticationChallenge, completionHandler ch: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        log("\(tag) task.didReceiveChallenge id=\(task.taskIdentifier) \(c.protectionSpace.authenticationMethod) prevFailures=\(c.previousFailureCount) -> \(challengeDisposition.rawValue)")
        ch(challengeDisposition, challengeDisposition == .useCredential ? URLCredential(user: "u", password: "p", persistence: .none) : nil)
    }
    func urlSession(_ s: URLSession, didReceive c: URLAuthenticationChallenge, completionHandler ch: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        log("\(tag) session.didReceiveChallenge \(c.protectionSpace.authenticationMethod)"); ch(.performDefaultHandling, nil)
    }
    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive r: URLResponse, completionHandler ch: @escaping (URLSession.ResponseDisposition) -> Void) {
        log("\(tag) didReceiveResponse id=\(dataTask.taskIdentifier) \((r as? HTTPURLResponse)?.statusCode ?? -1) len=\(r.expectedContentLength) -> disposition \(responseDisposition.rawValue)"); ch(responseDisposition)
    }
    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive d: Data) {
        bodies[dataTask.taskIdentifier, default: Data()].append(d)
        chunks[dataTask.taskIdentifier, default: []].append(d.count)
        if chunks[dataTask.taskIdentifier]!.count <= 3 { log("\(tag) didReceiveData id=\(dataTask.taskIdentifier) \(d.count)B received=\(dataTask.countOfBytesReceived)") }
    }
    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didBecome dl: URLSessionDownloadTask) { log("\(tag) didBecomeDownloadTask old=\(dataTask.taskIdentifier) new=\(dl.taskIdentifier) state=\(dataTask.state.rawValue)") }
    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didBecome st: URLSessionStreamTask) { log("\(tag) didBecomeStreamTask") }
    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, willCacheResponse r: CachedURLResponse, completionHandler ch: @escaping (CachedURLResponse?) -> Void) {
        log("\(tag) willCacheResponse id=\(dataTask.taskIdentifier) storage=\(r.storagePolicy.rawValue)"); ch(r)
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, needNewBodyStream ch: @escaping (InputStream?) -> Void) {
        log("\(tag) needNewBodyStream id=\(task.taskIdentifier)"); ch(InputStream(data: Data(repeating: 9, count: 1000)))
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, needNewBodyStreamFrom offset: Int64, completionHandler ch: @escaping (InputStream?) -> Void) {
        log("\(tag) needNewBodyStreamFrom id=\(task.taskIdentifier) offset=\(offset)"); ch(nil)
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didReceiveInformationalResponse r: HTTPURLResponse) { log("\(tag) didReceiveInformationalResponse \(r.statusCode)") }
    func urlSession(_ s: URLSession, task: URLSessionTask, didSendBodyData b: Int64, totalBytesSent t: Int64, totalBytesExpectedToSend e: Int64) {
        sends[task.taskIdentifier, default: []].append(t)
        if sends[task.taskIdentifier]!.count <= 3 { log("\(tag) didSendBodyData id=\(task.taskIdentifier) +\(b) \(t)/\(e) task.sent=\(task.countOfBytesSent)") }
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didFinishCollecting m: URLSessionTaskMetrics) {
        let t = m.transactionMetrics.first
        log("\(tag) didFinishCollecting id=\(task.taskIdentifier) txns=\(m.transactionMetrics.count) redirects=\(m.redirectCount) proto=\(t?.networkProtocolName ?? "nil") fetchType=\(t?.resourceFetchType.rawValue ?? -1) reused=\(t?.isReusedConnection ?? false) remote=\(t?.remoteAddress != nil) dns=\(t?.domainLookupStartDate != nil) connect=\(t?.connectStartDate != nil) reqStart=\(t?.requestStartDate != nil) respBodyBytes=\(t?.countOfResponseBodyBytesReceived ?? -1) reqBodyBytes=\(t?.countOfRequestBodyBytesSent ?? -1) interval=\(String(format: "%.2f", m.taskInterval.duration))")
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) {
        let id = task.taskIdentifier
        log("\(tag) didCompleteWithError id=\(id) \(desc(e)) status=\((task.response as? HTTPURLResponse)?.statusCode ?? -1) recv=\(task.countOfBytesReceived)/\(task.countOfBytesExpectedToReceive) sent=\(task.countOfBytesSent)/\(task.countOfBytesExpectedToSend) orig=\(task.originalRequest?.url?.path ?? "nil") cur=\(task.currentRequest?.url?.path ?? "nil") resp=\(task.response?.url?.path ?? "nil") progress=\(task.progress.fractionCompleted)")
        if let c = chunks[id] { log("\(tag) data summary id=\(id) chunks=\(c.count) bytes=\(c.reduce(0, +)) max=\(c.max() ?? 0)") }
        if let w = writes[id] { log("\(tag) write summary id=\(id) calls=\(w.count) last=\(w.last ?? 0)") }
        if let w = sends[id] { log("\(tag) send summary id=\(id) calls=\(w.count) last=\(w.last ?? 0)") }
        if showHeaders, let b = bodies[id] { log("\(tag) request headers: \(headerSummary(b))") }
        if let ue = (e as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { log("\(tag) resumeData bytes=\(ue.count)") }
        pending -= 1; if pending <= 0 { onDone?() }
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData b: Int64, totalBytesWritten t: Int64, totalBytesExpectedToWrite e: Int64) {
        writes[downloadTask.taskIdentifier, default: []].append(t)
        if writes[downloadTask.taskIdentifier]!.count <= 3 { log("\(tag) download.didWriteData +\(b) \(t)/\(e)") }
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset o: Int64, expectedTotalBytes e: Int64) { log("\(tag) download.didResumeAtOffset \(o)/\(e)") }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo l: URL) {
        let data = try? Data(contentsOf: l)
        let comps = l.pathComponents.suffix(3).joined(separator: "/")
        log("\(tag) download.didFinishDownloadingTo .../\(comps) size=\(data?.count ?? -1) resp=\((downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1)")
        if showHeaders, let d = data { log("\(tag) request headers: \(headerSummary(d))") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { log("\(self.tag) download file exists after delegate returned: \(FileManager.default.fileExists(atPath: l.path))") }
    }
    func urlSession(_ s: URLSession, streamTask: URLSessionStreamTask, didBecome i: InputStream, outputStream o: OutputStream) { log("\(tag) stream.didBecomeInputStream") }
    func urlSession(_ s: URLSession, readClosedFor streamTask: URLSessionStreamTask) { log("\(tag) stream.readClosed") }
    func urlSession(_ s: URLSession, writeClosedFor streamTask: URLSessionStreamTask) { log("\(tag) stream.writeClosed") }
    func urlSession(_ s: URLSession, betterRouteDiscoveredFor streamTask: URLSessionStreamTask) { log("\(tag) stream.betterRouteDiscovered") }
    func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol p: String?) { log("\(tag) websocket.didOpen protocol=\(p ?? "nil")") }
    func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith code: URLSessionWebSocketTask.CloseCode, reason: Data?) { log("\(tag) websocket.didClose \(code.rawValue)") }
    func urlSessionDidFinishEvents(forBackgroundURLSession s: URLSession) { log("\(tag) urlSessionDidFinishEvents(forBackgroundURLSession:)") }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var keep: [Any] = []
    func application(_ a: UIApplication, handleEventsForBackgroundURLSession id: String, completionHandler: @escaping () -> Void) {
        log("app.handleEventsForBackgroundURLSession \(id)"); completionHandler()
    }
    func application(_ a: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool { true }
    func application(_ a: UIApplication, configurationForConnecting c: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let cfg = UISceneConfiguration(name: "Default", sessionRole: c.role)
        cfg.delegateClass = SceneDelegate.self
        return cfg
    }
    func start() {
        let scenario = CommandLine.arguments.dropFirst().first ?? "data"
        log("launch scenario=\(scenario)")
        DispatchQueue.main.async { self.run(scenario) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { log("TIMEOUT exit"); exit(0) }
    }

    func make(_ id: String, tag: String, _ tweak: (URLSessionConfiguration) -> Void = { _ in }) -> (URLSession, Delegate) {
        let c = isFG ? URLSessionConfiguration.default : URLSessionConfiguration.background(withIdentifier: id)
        if !isFG { c.sessionSendsLaunchEvents = true }
        tweak(c)
        let d = Delegate(tag: (isFG ? "FG " : "BG ") + tag)
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1
        let s = URLSession(configuration: c, delegate: d, delegateQueue: q)
        keep.append(s); keep.append(d)
        return (s, d)
    }
    func finish(_ d: Delegate, _ n: Int) {
        d.pending = n
        d.onDone = { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { log("DONE"); exit(0) } }
    }
    func req(_ p: String) -> URLRequest { URLRequest(url: URL(string: base + p)!) }
    func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }

    func run(_ sc: String) {
        let id = "exp.\(sc).\(UInt32.random(in: 0...99999))"
        switch sc {
        case "data":
            let (s, d) = make(id, tag: "data"); finish(d, 1)
            s.dataTask(with: req("/get")).resume()
        case "redirect":
            let (s, d) = make(id, tag: "redirect"); finish(d, 1)
            s.dataTask(with: req("/redirect/2")).resume()
        case "download":
            let (s, d) = make(id, tag: "download"); finish(d, 1)
            s.downloadTask(with: req("/bytes/5000")).resume()
        case "download404":
            let (s, d) = make(id, tag: "dl404"); finish(d, 1)
            s.downloadTask(with: req("/status/404")).resume()
        case "upload":
            let (s, d) = make(id, tag: "upload"); finish(d, 1)
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("up.bin")
            try! Data(repeating: 7, count: 20000).write(to: f)
            var r = req("/post"); r.httpMethod = "POST"
            s.uploadTask(with: r, fromFile: f).resume()
        case "auth":
            let (s, d) = make(id, tag: "auth"); finish(d, 1)
            s.dataTask(with: req("/basic-auth/u/p")).resume()
        case "delayed":
            let (s, d) = make(id, tag: "delayed"); finish(d, 1)
            let t = s.dataTask(with: req("/get")); t.earliestBeginDate = Date().addingTimeInterval(2)
            log("resume w/ earliestBeginDate +2s"); t.resume()
        case "delayedCancel":
            let (s, d) = make(id, tag: "delayedCancel"); d.willBeginDisposition = .cancel; finish(d, 1)
            let t = s.dataTask(with: req("/get")); t.earliestBeginDate = Date().addingTimeInterval(1)
            t.resume()
        case "delayedPast":
            let (s, d) = make(id, tag: "delayedPast"); finish(d, 1)
            let t = s.dataTask(with: req("/get")); t.earliestBeginDate = Date().addingTimeInterval(-5)
            t.resume()
        case "delayedDownload":
            let (s, d) = make(id, tag: "delayedDL"); finish(d, 1)
            let t = s.downloadTask(with: req("/bytes/100")); t.earliestBeginDate = Date().addingTimeInterval(2)
            t.resume()
        case "delayedTimeout":
            let (s, d) = make(id, tag: "delayedTO", { $0.timeoutIntervalForRequest = 1 }); finish(d, 1)
            let t = s.dataTask(with: req("/get")); t.earliestBeginDate = Date().addingTimeInterval(3)
            t.resume()
        case "delayedCancelTask":
            let (s, d) = make(id, tag: "delayedCancelTask"); finish(d, 1)
            let t = s.dataTask(with: req("/get")); t.earliestBeginDate = Date().addingTimeInterval(5)
            t.resume(); after(1) { log("cancel() while delayed"); t.cancel() }
        case "waits":
            let (s, d) = make(id, tag: "waits", { $0.waitsForConnectivity = true; $0.timeoutIntervalForResource = 6 }); finish(d, 1)
            s.dataTask(with: URLRequest(url: URL(string: "http://127.0.0.1:1/")!)).resume()
        case "nowaits":
            let (s, d) = make(id, tag: "nowaits"); finish(d, 1)
            s.dataTask(with: URLRequest(url: URL(string: "http://127.0.0.1:1/")!)).resume()
        case "badhost":
            let (s, d) = make(id, tag: "badhost", { $0.waitsForConnectivity = true; $0.timeoutIntervalForResource = 6 }); finish(d, 1)
            s.dataTask(with: URLRequest(url: URL(string: "http://nonexistent.invalid/")!)).resume()
        case "badhostNoWait":
            let (s, d) = make(id, tag: "badhostNW"); finish(d, 1)
            s.dataTask(with: URLRequest(url: URL(string: "http://nonexistent.invalid/")!)).resume()
        case "requestTimeout":
            let (s, d) = make(id, tag: "reqTO", { $0.timeoutIntervalForRequest = 2 }); finish(d, 1)
            s.dataTask(with: req("/delay/8")).resume()
        case "resourceTimeout":
            let (s, d) = make(id, tag: "resTO", { $0.timeoutIntervalForResource = 2 }); finish(d, 1)
            s.dataTask(with: req("/delay/8")).resume()
        case "cancel":
            let (s, d) = make(id, tag: "cancel"); finish(d, 1)
            let t = s.dataTask(with: req("/delay/5")); t.resume()
            after(1) { log("cancel()"); t.cancel() }
        case "suspend":
            let (s, d) = make(id, tag: "suspend"); finish(d, 1)
            let t = s.dataTask(with: req("/delay/2")); t.resume()
            after(0.5) { t.suspend(); log("suspend() -> state=\(t.state.rawValue)") }
            after(3) { log("state=\(t.state.rawValue) resume()"); t.resume() }
        case "neverResumed":
            let (s, _) = make(id, tag: "neverResumed")
            let t = s.dataTask(with: req("/get")); log("created id=\(t.taskIdentifier) state=\(t.state.rawValue), not resumed")
            s.getAllTasks { ts in log("getAllTasks -> \(ts.count)"); exit(0) }
        case "getTasks":
            let (s, d) = make(id, tag: "getTasks"); finish(d, 1)
            s.dataTask(with: req("/delay/2")).resume()
            s.getTasksWithCompletionHandler { dt, ut, dl in log("getTasks data=\(dt.count) up=\(ut.count) down=\(dl.count)") }
        case "invalidateFinish":
            let (s, d) = make(id, tag: "invFinish"); d.pending = 1
            s.dataTask(with: req("/delay/1")).resume()
            s.finishTasksAndInvalidate()
            after(4) { log("DONE"); exit(0) }
        case "invalidateCancel":
            let (s, d) = make(id, tag: "invCancel"); d.pending = 1
            s.dataTask(with: req("/delay/5")).resume()
            after(1) { log("invalidateAndCancel()"); s.invalidateAndCancel() }
            after(4) { log("DONE"); exit(0) }
        case "sameId":
            let fixed = "exp.sameId.fixed"
            let (s1, _) = make(fixed, tag: "first")
            let (s2, _) = make(fixed, tag: "second")
            s1.dataTask(with: req("/delay/1")).resume(); _ = s2
            after(4) { log("DONE"); exit(0) }
        case "completionHandler":
            let (s, _) = make(id, tag: "ch")
            s.dataTask(with: req("/get")) { _, _, _ in }.resume()
        case "downloadCompletionHandler":
            let (s, _) = make(id, tag: "dch")
            s.downloadTask(with: req("/get")) { _, _, _ in }.resume()
        case "uploadData":
            let (s, _) = make(id, tag: "upData")
            s.uploadTask(with: req("/post"), from: Data([1, 2, 3])).resume()
        case "taskDelegate":
            let (s, d) = make(id, tag: "taskDel")
            let t = s.dataTask(with: req("/get")); t.delegate = d
        case "websocket":
            let (s, d) = make(id, tag: "ws"); finish(d, 1)
            let t = s.webSocketTask(with: URL(string: "ws://127.0.0.1:8080/websocket/echo")!)
            t.resume()
            t.send(.string("hi")) { e in log("ws send error=\(desc(e))") }
            t.receive { r in log("ws receive \(r)"); t.cancel(with: .normalClosure, reason: nil) }
        case "stream":
            let (s, d) = make(id, tag: "stream"); d.pending = 99
            let t = s.streamTask(withHostName: "127.0.0.1", port: 8080)
            t.resume()
            t.write(Data("GET /get HTTP/1.0\r\n\r\n".utf8), timeout: 5) { e in log("stream write error=\(desc(e))") }
            t.readData(ofMinLength: 1, maxLength: 4096, timeout: 5) { dat, eof, e in log("stream read \(dat?.count ?? -1)B eof=\(eof) error=\(desc(e))"); t.closeRead(); t.closeWrite(); self.after(0.5) { log("DONE"); exit(0) } }
        case "uploadStream":
            let (s, d) = make(id, tag: "upStream"); finish(d, 1)
            s.uploadTask(withStreamedRequest: req("/post")).resume()
        case "cache":
            let (s, d) = make(id, tag: "cache"); finish(d, 2)
            let p = "/response-headers?Cache-Control=max-age=60&ETag=%22x%22"
            s.dataTask(with: req(p)).resume()
            after(1) { s.dataTask(with: self.req(p)).resume() }
        case "cookies":
            let (s, d) = make(id, tag: "cookies"); finish(d, 2); d.showHeaders = true
            s.dataTask(with: req("/response-headers?Set-Cookie=bgexp%3D1")).resume()
            after(1) {
                log("shared cookies=\(HTTPCookieStorage.shared.cookies?.map { $0.name } ?? []) session cookies=\(s.configuration.httpCookieStorage?.cookies?.map { $0.name } ?? [])")
                s.dataTask(with: self.req("/get")).resume()
            }
        case "redirectCancel":
            let (s, d) = make(id, tag: "redirCancel"); finish(d, 1); d.followRedirects = false
            s.dataTask(with: req("/redirect/1")).resume()
        case "respCancel":
            let (s, d) = make(id, tag: "respCancel"); finish(d, 1); d.responseDisposition = .cancel
            s.dataTask(with: req("/get")).resume()
        case "respDownload":
            let (s, d) = make(id, tag: "respDl"); finish(d, 1); d.responseDisposition = .becomeDownload
            s.dataTask(with: req("/bytes/5000")).resume()
        case "respStream":
            let (s, d) = make(id, tag: "respStream"); finish(d, 1); d.responseDisposition = .becomeStream
            s.dataTask(with: req("/get")).resume()
        case "authCancel":
            let (s, d) = make(id, tag: "authCancel"); finish(d, 1); d.challengeDisposition = .cancelAuthenticationChallenge
            s.dataTask(with: req("/basic-auth/u/p")).resume()
        case "authDefault":
            let (s, d) = make(id, tag: "authDefault"); finish(d, 1); d.challengeDisposition = .performDefaultHandling
            s.dataTask(with: req("/basic-auth/u/p")).resume()
        case "authReject":
            let (s, d) = make(id, tag: "authReject"); finish(d, 1); d.challengeDisposition = .rejectProtectionSpace
            s.dataTask(with: req("/basic-auth/u/p")).resume()
        case "authUpload":
            let (s, d) = make(id, tag: "authUpload"); finish(d, 1)
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("up2.bin")
            try! Data(repeating: 7, count: 5000).write(to: f)
            var r = req("/basic-auth/u/p"); r.httpMethod = "POST"
            s.uploadTask(with: r, fromFile: f).resume()
        case "uploadBig":
            let (s, d) = make(id, tag: "upBig"); finish(d, 1)
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("up3.bin")
            try! Data(repeating: 7, count: 2_000_000).write(to: f)
            var r = req("/post"); r.httpMethod = "POST"
            s.uploadTask(with: r, fromFile: f).resume()
        case "downloadBig":
            let (s, d) = make(id, tag: "dlBig"); finish(d, 1)
            s.downloadTask(with: req("/bytes/100000")).resume()
        case "dataBig":
            let (s, d) = make(id, tag: "dataBig"); finish(d, 2)
            s.dataTask(with: req("/bytes/100000")).resume()
            s.dataTask(with: req("/stream/50")).resume()
        case "badScheme":
            let (s, d) = make(id, tag: "badScheme"); finish(d, 1)
            s.dataTask(with: URLRequest(url: URL(string: "foo://x/y")!)).resume()
        case "headers":
            let (s, d) = make(id, tag: "headers"); finish(d, 2); d.showHeaders = true
            let t = s.dataTask(with: req("/get")); t.taskDescription = "desc"; t.resume()
            s.downloadTask(with: req("/get")).resume()
        case "taskProps":
            let (s, d) = make(id, tag: "props"); finish(d, 1)
            let t = s.dataTask(with: req("/get"))
            log("pre-resume state=\(t.state.rawValue) prio=\(t.priority) earliest=\(String(describing: t.earliestBeginDate)) expectedRecv=\(t.countOfBytesClientExpectsToReceive) expectedSend=\(t.countOfBytesClientExpectsToSend) prefersIncremental=\(t.prefersIncrementalDelivery)")
            t.priority = 0.9; t.countOfBytesClientExpectsToReceive = 100; t.resume()
            log("post-resume state=\(t.state.rawValue) prio=\(t.priority) tid=\(t.taskIdentifier)")
            after(0.05) { log("t+50ms state=\(t.state.rawValue)") }
        case "cancelRunning":
            let (s, d) = make(id, tag: "cancelRun"); finish(d, 1)
            let t = s.dataTask(with: req("/delay/5")); t.resume()
            after(1) { log("cancel() at state=\(t.state.rawValue)"); t.cancel(); log("state after cancel=\(t.state.rawValue)") }
        case "invalidateAfter":
            let (s, d) = make(id, tag: "invAfter"); d.pending = 99
            s.finishTasksAndInvalidate()
            s.dataTask(with: req("/get")).resume()
            after(2) { log("DONE"); exit(0) }
        case "noIdentifier":
            let c = isFG ? URLSessionConfiguration.default : URLSessionConfiguration.background(withIdentifier: "")
            _ = URLSession(configuration: c); log("created session with empty identifier"); after(1) { log("DONE"); exit(0) }
        case "noDelegate":
            let c = isFG ? URLSessionConfiguration.default : URLSessionConfiguration.background(withIdentifier: id)
            let s = URLSession(configuration: c)
            s.dataTask(with: req("/get")).resume()
            log("no-delegate session task resumed"); after(3) { log("DONE"); exit(0) }
        case "resumeData":
            let (s, d) = make(id, tag: "dlResume"); finish(d, 1)
            s.downloadTask(withResumeData: Data([1, 2, 3])).resume()
        case "multi":
            let (s, d) = make(id, tag: "multi", { $0.httpMaximumConnectionsPerHost = 1 }); finish(d, 3)
            for i in 0..<3 { s.dataTask(with: req("/delay/\(i)")).resume() }
        case "discretionary":
            let (s, d) = make(id, tag: "discr", { $0.isDiscretionary = true }); finish(d, 1)
            s.dataTask(with: req("/get")).resume()
        case "reconnect":
            // phase 1 (arg2 = "start"): start download on a fixed id then exit before it ends. phase 2: relaunch, reattach.
            let phase = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "start"
            let (s, d) = make("exp.reconnect.fixed", tag: "reconnect-\(phase)")
            if phase == "start" {
                s.downloadTask(with: req("/bytes/200")).resume(); after(0.2) { log("exiting before completion"); exit(0) }
            } else {
                d.pending = 99
                s.getAllTasks { ts in log("getAllTasks existing=\(ts.count)") }
                after(6) { log("DONE"); exit(0) }
            }
        default: log("unknown scenario"); exit(2)
        }
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        window = UIWindow(windowScene: ws)
        window?.rootViewController = UIViewController(); window?.makeKeyAndVisible()
        (UIApplication.shared.delegate as! AppDelegate).start()
    }
    func sceneDidEnterBackground(_ scene: UIScene) { log("scene.didEnterBackground") }
    func sceneWillEnterForeground(_ scene: UIScene) { log("scene.willEnterForeground") }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
