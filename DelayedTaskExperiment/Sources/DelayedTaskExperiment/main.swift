import Foundation

// Usage: DelayedTaskExperiment <scenario> [args]
// Exercises willBeginDelayedRequest / taskIsWaitingForConnectivity against firewalk (127.0.0.1:8080).

let base = "http://127.0.0.1:8080"
let t0 = Date()
func log(_ s: String) {
    let e = String(format: "%7.3f", Date().timeIntervalSince(t0))
    print("[\(e)] \(s)")
    fflush(stdout)
}

func describe(_ error: Error?) -> String {
    guard let error else { return "nil" }
    let ns = error as NSError
    var s = "\(ns.domain) \(ns.code) \"\(ns.localizedDescription)\""
    let keys = ns.userInfo.keys.map { "\($0)" }.sorted()
    s += " userInfoKeys=\(keys)"
    if let r = ns.userInfo["_NSURLErrorRelatedURLSessionTaskErrorKey"] { s += " related=\(r)" }
    if let c = ns.userInfo["_kCFStreamErrorCodeKey"] { s += " streamCode=\(c)" }
    if let c = ns.userInfo["_kCFStreamErrorDomainKey"] { s += " streamDomain=\(c)" }
    if let u = ns.underlyingErrors.first { s += " underlying=\((u as NSError).domain)/\((u as NSError).code)" }
    return s
}

enum DelayedDisposition { case `continue`, newRequest, cancel, never, afterDelay(TimeInterval), twice }

final class Delegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    var implementWillBegin = true
    var implementWaiting = true
    var disposition: DelayedDisposition = .continue
    let done = DispatchSemaphore(value: 0)
    var willBeginCount = 0
    var waitingCount = 0

    override func responds(to aSelector: Selector!) -> Bool {
        let name = NSStringFromSelector(aSelector)
        if name == "URLSession:task:willBeginDelayedRequest:completionHandler:" && !implementWillBegin { return false }
        if name == "URLSession:taskIsWaitingForConnectivity:" && !implementWaiting { return false }
        return super.responds(to: aSelector)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willBeginDelayedRequest request: URLRequest,
                    completionHandler: @escaping (URLSession.DelayedRequestDisposition, URLRequest?) -> Void) {
        willBeginCount += 1
        log("willBeginDelayedRequest #\(willBeginCount) url=\(request.url!) main=\(Thread.isMainThread) state=\(task.state.rawValue)")
        switch disposition {
        case .continue: completionHandler(.continueLoading, nil)
        case .newRequest:
            var r = request; r.url = URL(string: "\(base)/get?replaced=1")!
            completionHandler(.useNewRequest, r)
        case .cancel: completionHandler(.cancel, nil)
        case .never: log("(not calling completionHandler)")
        case let .afterDelay(d):
            DispatchQueue.global().asyncAfter(deadline: .now() + d) {
                log("calling completionHandler after \(d)s")
                completionHandler(.continueLoading, nil)
            }
        case .twice:
            completionHandler(.continueLoading, nil)
            completionHandler(.continueLoading, nil)
        }
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        waitingCount += 1
        log("taskIsWaitingForConnectivity #\(waitingCount) state=\(task.state.rawValue)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let m = metrics.transactionMetrics.last
        log("metrics: fetchStart=\(fmt(m?.fetchStartDate)) connectStart=\(fmt(m?.connectStartDate)) reqStart=\(fmt(m?.requestStartDate)) respEnd=\(fmt(m?.responseEndDate)) taskInterval=\(String(format: "%.3f", metrics.taskInterval.duration))")
    }

    func fmt(_ d: Date?) -> String { d.map { String(format: "%.3f", $0.timeIntervalSince(t0)) } ?? "nil" }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        log("didReceiveResponse status=\((response as? HTTPURLResponse)?.statusCode ?? -1) url=\(response.url!)")
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        log("didCompleteWithError: \(describe(error))")
        done.signal()
    }
}

struct Options {
    var delay: TimeInterval = 0
    var requestTimeout: TimeInterval = 60
    var resourceTimeout: TimeInterval = 7 * 24 * 3600
    var waits = false
    var url = "\(base)/get"
    var willBegin = true
    var waiting = true
    var disposition: DelayedDisposition = .continue
    var background = false
    var cancelAfter: TimeInterval?
    var suspendFor: TimeInterval?
    var perRequestTimeout: TimeInterval?
    var wait: TimeInterval = 20
}

func run(_ name: String, _ o: Options) {
    log("=== \(name): delay=\(o.delay) reqTimeout=\(o.requestTimeout) resTimeout=\(o.resourceTimeout) waits=\(o.waits) url=\(o.url) willBegin=\(o.willBegin) waiting=\(o.waiting)")
    let cfg: URLSessionConfiguration = o.background
        ? .background(withIdentifier: "delayed-exp-\(UUID().uuidString)")
        : .ephemeral
    cfg.timeoutIntervalForRequest = o.requestTimeout
    cfg.timeoutIntervalForResource = o.resourceTimeout
    cfg.waitsForConnectivity = o.waits
    let d = Delegate()
    d.implementWillBegin = o.willBegin
    d.implementWaiting = o.waiting
    d.disposition = o.disposition
    let session = URLSession(configuration: cfg, delegate: d, delegateQueue: nil)
    var req = URLRequest(url: URL(string: o.url)!)
    if let t = o.perRequestTimeout { req.timeoutInterval = t }
    let task = session.dataTask(with: req)
    log("task class = \(type(of: task))")
    if o.delay > 0 { task.earliestBeginDate = Date().addingTimeInterval(o.delay) }
    task.resume()
    log("resumed; state=\(task.state.rawValue)")
    if let c = o.cancelAfter {
        DispatchQueue.global().asyncAfter(deadline: .now() + c) { log("cancel()"); task.cancel() }
    }
    if let s = o.suspendFor {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { log("suspend()"); task.suspend() }
        DispatchQueue.global().asyncAfter(deadline: .now() + s) { log("resume()"); task.resume() }
    }
    if d.done.wait(timeout: .now() + o.wait) == .timedOut {
        log("!! no completion within \(o.wait)s; state=\(task.state.rawValue) willBegin=\(d.willBeginCount) waiting=\(d.waitingCount)")
    }
    log("final: state=\(task.state.rawValue) willBegin=\(d.willBeginCount) waiting=\(d.waitingCount) error=\(describe(task.error))")
    session.invalidateAndCancel()
}

let scenario = CommandLine.arguments.dropFirst().first ?? "help"
var o = Options()
switch scenario {
case "baseline": run(scenario, o)
case "delay2": o.delay = 2; run(scenario, o)
case "delay2-nodelegate": o.delay = 2; o.willBegin = false; run(scenario, o)
case "past-date": o.delay = -5; run(scenario, o)
case "delay2-wfc": o.delay = 2; o.waits = true; run(scenario, o)
case "delay2-newrequest": o.delay = 2; o.disposition = .newRequest; run(scenario, o)
case "delay2-cancel": o.delay = 2; o.disposition = .cancel; run(scenario, o)
case "delay2-never": o.delay = 2; o.disposition = .never; o.wait = 8; run(scenario, o)
case "delay2-never-reqtimeout3": o.delay = 2; o.disposition = .never; o.requestTimeout = 3; o.wait = 10; run(scenario, o)
case "delay2-late": o.delay = 2; o.disposition = .afterDelay(3); run(scenario, o)
case "delay2-twice": o.delay = 2; o.disposition = .twice; run(scenario, o)
case "delay5-reqtimeout2": o.delay = 5; o.requestTimeout = 2; run(scenario, o)
case "delay5-restimeout3": o.delay = 5; o.resourceTimeout = 3; run(scenario, o)
case "delay5-restimeout3-wfc": o.delay = 5; o.resourceTimeout = 3; o.waits = true; run(scenario, o)
case "delay2-restimeout3-slow": o.delay = 2; o.resourceTimeout = 3; o.url = "\(base)/delay/3"; run(scenario, o)
case "delay5-cancel1": o.delay = 5; o.cancelAfter = 1; run(scenario, o)
case "delay2-suspend": o.delay = 2; o.suspendFor = 4; run(scenario, o)
case "delay2-perreq-timeout1": o.delay = 2; o.perRequestTimeout = 1; run(scenario, o)
case "bg-delay2": o.delay = 2; o.background = true; run(scenario, o)
case "wfc-invalid-host": o.waits = true; o.url = "https://nonexistent.invalid/"; o.requestTimeout = 5; o.wait = 12; run(scenario, o)
case "nowfc-invalid-host": o.url = "https://nonexistent.invalid/"; o.requestTimeout = 5; run(scenario, o)
case "wfc-refused": o.waits = true; o.url = "http://127.0.0.1:1/"; o.requestTimeout = 5; o.wait = 12; run(scenario, o)
case "wfc-testnet": o.waits = true; o.url = "https://192.0.2.1/"; o.requestTimeout = 4; o.wait = 15; run(scenario, o)
case "nowfc-testnet": o.url = "https://192.0.2.1/"; o.requestTimeout = 4; o.wait = 15; run(scenario, o)
case "wfc-testnet-restimeout6": o.waits = true; o.url = "https://192.0.2.1/"; o.requestTimeout = 4; o.resourceTimeout = 6; o.wait = 15; run(scenario, o)
case "wfc-ok": o.waits = true; run(scenario, o)
case "nowfc-refused": o.url = "http://127.0.0.1:1/"; o.requestTimeout = 5; run(scenario, o)
case "wfc-refused-restimeout6": o.waits = true; o.url = "http://127.0.0.1:1/"; o.requestTimeout = 3; o.resourceTimeout = 6; o.wait = 12; run(scenario, o)
case "wfc-refused-nodelegate": o.waits = true; o.waiting = false; o.url = "http://127.0.0.1:1/"; o.requestTimeout = 3; o.resourceTimeout = 6; o.wait = 12; run(scenario, o)
case "wfc-refused-cancel": o.waits = true; o.url = "http://127.0.0.1:1/"; o.cancelAfter = 3; o.wait = 8; run(scenario, o)
case "wfc-refused-delay2": o.waits = true; o.delay = 2; o.url = "http://127.0.0.1:1/"; o.resourceTimeout = 8; o.wait = 12; run(scenario, o)
case "wfc-refused-listen":
    // Task waits on a closed port; a listener is then started on that port to see whether the task recovers.
    let port = 18089
    let cfgURL = "http://127.0.0.1:\(port)/"
    DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
        log("starting python listener on \(port)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", "/tmp"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 14) { p.terminate() }
    }
    o.waits = true; o.url = cfgURL; o.requestTimeout = 3; o.resourceTimeout = 12; o.wait = 14; run(scenario, o)
case "wfc-dns": o.waits = true; o.url = "https://nonexistent.invalid/"; o.requestTimeout = 3; o.resourceTimeout = 8; o.wait = 12; run(scenario, o)
case "nowfc-dns": o.url = "https://nonexistent.invalid/"; o.requestTimeout = 3; run(scenario, o)
case "wfc-testnet-https": o.waits = true; o.url = "https://192.0.2.1/"; o.requestTimeout = 3; o.resourceTimeout = 8; o.wait = 12; run(scenario, o)
case "nowfc-testnet-https": o.url = "https://192.0.2.1/"; o.requestTimeout = 3; o.wait = 12; run(scenario, o)
default:
    print("scenarios: see source")
}
