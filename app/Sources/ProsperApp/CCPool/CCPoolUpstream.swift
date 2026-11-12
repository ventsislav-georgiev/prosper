import Foundation

/// Callbacks of one upstream attempt. Called on URLSession's delegate queue; implementations hop
/// to their own queue. `decide` must be called exactly once per response.
protocol CCPoolUpstreamHandler: AnyObject, Sendable {
    func upstreamResponse(_ response: HTTPURLResponse, decide: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    func upstreamData(_ data: Data)
    func upstreamDone(_ error: Error?)
}

/// One URLSession per account (errata: B17 replaced): ephemeral, no cookies, no cache, its own
/// connection pool, so one organisation's connection never serves another. Streaming uses the
/// delegate data callbacks (errata C2); the response callback is the replay decision point.
final class CCPoolUpstream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: URLSession] = [:]
    private var handlers: [ObjectIdentifier: CCPoolUpstreamHandler] = [:]

    static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 900
        return c
    }

    private func session(for accountID: String) -> URLSession {
        lock.withLock {
            if let s = sessions[accountID] { return s }
            let q = OperationQueue()
            q.maxConcurrentOperationCount = 1
            let s = URLSession(configuration: Self.configuration(), delegate: self, delegateQueue: q)
            sessions[accountID] = s
            return s
        }
    }

    /// Start `request` on the account's session; the handler gets every callback of this task.
    func start(_ request: URLRequest, accountID: String, handler: CCPoolUpstreamHandler) -> URLSessionDataTask {
        let task = session(for: accountID).dataTask(with: request)
        lock.withLock { handlers[ObjectIdentifier(task)] = handler }
        task.resume()
        return task
    }

    /// Drop an account's session (its pooled connections go with it).
    func drop(accountID: String) {
        lock.withLock { sessions.removeValue(forKey: accountID) }?.invalidateAndCancel()
    }

    func invalidateAll() {
        let all = lock.withLock { () -> [URLSession] in
            defer { sessions.removeAll() }
            return Array(sessions.values)
        }
        all.forEach { $0.invalidateAndCancel() }
    }

    private func handler(_ task: URLSessionTask) -> CCPoolUpstreamHandler? {
        lock.withLock { handlers[ObjectIdentifier(task)] }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let h = handler(dataTask) else { return completionHandler(.cancel) }
        h.upstreamResponse(http, decide: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handler(dataTask)?.upstreamData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let h = lock.withLock { handlers.removeValue(forKey: ObjectIdentifier(task)) }
        h?.upstreamDone(error)
    }

    /// Never follow a redirect: the 3xx goes to the client as-is, like the Python proxy.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    /// A streamed body cannot be re-read; URLSession then fails the task instead of resending.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void) {
        completionHandler(nil)
    }
}
