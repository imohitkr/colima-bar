import Foundation

/// The answers that the proxy writes itself: error pages in plain HTML. Pure.
enum DomainPage {
    enum Kind: Equatable, Sendable {
        /// 400
        case badRequest
        /// 404, for a name under our suffix. `known` holds the names that
        /// work now, as `host` or `host:port`, ready for a link.
        case notFound(host: String, profile: String, known: [String])
        /// 404, with no list.
        case foreign
        /// 408
        case timeout
        /// 431
        case headTooLarge
        /// 502
        case upstreamDown(host: String, container: String, containerPort: Int, hostPort: Int)
        /// 502, for a route to the port of the proxy itself.
        case selfLoop(host: String, container: String, hostPort: Int)
        /// 503
        case vmStopped(profile: String)
        /// 503
        case busy
    }

    static let maxKnown = 50

    static func response(_ kind: Kind, headOnly: Bool) -> Data {
        let (code, reason, title, body) = content(kind)
        let html = """
            <!doctype html><html lang="en"><head><meta charset="utf-8"><title>\(escape(title))</title>\
            <meta name="viewport" content="width=device-width, initial-scale=1">\
            <style>body{font:16px/1.5 -apple-system,system-ui,sans-serif;max-width:40rem;margin:4rem auto;padding:0 1rem;\
            color:#222;background:#fff}@media(prefers-color-scheme:dark){body{color:#ddd;background:#1e1e1e}a{color:#6cb6ff}}\
            h1{font-size:1.4rem}footer{margin-top:3rem;color:#888;font-size:.8rem}code{font-size:.9em}</style></head>\
            <body><h1>\(escape(title))</h1>\(body)<footer>ColimaBar container domains</footer></body></html>
            """
        let payload = Data(html.utf8)
        var head = "HTTP/1.1 \(code) \(reason)\r\n"
        head += "Content-Type: text/html; charset=utf-8\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        if !headOnly { out.append(payload) }
        return out
    }

    /// Escapes the five characters that matter in HTML text and attributes.
    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    private static func p(_ text: String) -> String { "<p>\(escape(text))</p>" }

    private static func content(_ kind: Kind) -> (Int, String, String, String) {
        switch kind {
        case .badRequest:
            return (400, "Bad Request", "Bad request", p("The request has no valid Host header."))
        case .notFound(let host, let profile, let known):
            var body = p("No running container of profile \(profile) has this name.")
            if known.isEmpty {
                body += p("No running container publishes a web port.")
            } else {
                body += p("Names that work now:")
                body +=
                    "<ul>"
                    + known.prefix(maxKnown).map { "<li><a href=\"http://\(escape($0))/\">\(escape($0))</a></li>" }
                    .joined() + "</ul>"
            }
            return (404, "Not Found", "No container at \(host)", body)
        case .foreign:
            return (
                404, "Not Found", "Unknown address",
                p("This address is not a container name. Use a name that ends in .localhost.")
            )
        case .timeout:
            return (408, "Request Timeout", "Request timeout", p("The request did not arrive in time."))
        case .headTooLarge:
            return (
                431, "Request Header Fields Too Large", "Request too large",
                p("The request head is larger than 64 KB.")
            )
        case .upstreamDown(let host, let container, let containerPort, let hostPort):
            return (
                502, "Bad Gateway", "Nothing answers for \(host)",
                p(
                    "\(host) points to the container \(container) on port \(containerPort) (localhost:\(hostPort)), but nothing answers there. Check the logs of the container."
                )
            )
        case .selfLoop(let host, let container, let hostPort):
            return (
                502, "Bad Gateway", "\(host) points to the proxy",
                p(
                    "\(host) points to the container \(container) on localhost:\(hostPort). That is the port of this proxy. Publish the container on another port."
                )
            )
        case .vmStopped(let profile):
            return (
                503, "Service Unavailable", "Colima is not running",
                p("Colima profile \(profile) is not running. Start it in ColimaBar, then load this page again.")
            )
        case .busy:
            return (
                503, "Service Unavailable", "Too many connections",
                p("The proxy has too many open connections. Try again.")
            )
        }
    }
}
