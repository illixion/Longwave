#if MOONLIGHT_ENABLED
import Foundation
import os
import Network
@preconcurrency import Security

/// HTTP/HTTPS client for GameStream server communication.
/// Handles server info, app list, launch/quit, and pairing HTTP endpoints.
actor NvHTTPClient {
    let hostname: String
    let httpPort: UInt16
    private(set) var httpsPort: UInt16

    private let cryptoManager: CryptoManager
    private var serverCertDER: Data?

    /// Fixed unique ID shared across all Moonlight clients
    private static let uniqueId = "0123456789ABCDEF"
    private static let deviceName = "roth"

    init(hostname: String, httpPort: UInt16 = 47989, httpsPort: UInt16 = 47984, cryptoManager: CryptoManager = .shared) {
        self.hostname = hostname
        self.httpPort = httpPort
        self.httpsPort = httpsPort
        self.cryptoManager = cryptoManager
    }

    /// Store the server certificate for TLS verification.
    func setServerCert(_ certDER: Data) async throws {
        self.serverCertDER = certDER
    }

    func updateHttpsPort(_ port: UInt16) {
        self.httpsPort = port
    }

    // MARK: - Server Info

    func getServerInfo() async throws -> ServerInfo {
        // Use NWConnection for all requests — bypasses ATS entirely.
        // Try TLS (HTTPS) first if paired, otherwise plain HTTP.
        let data: Data
        if serverCertDER != nil {
            do {
                data = try await nwRawRequest("serverinfo", port: httpsPort, useTLS: true)
            } catch {
                data = try await nwRawRequest("serverinfo", port: httpPort)
            }
        } else {
            data = try await nwRawRequest("serverinfo", port: httpPort)
        }

        // Parse with display mode-aware parser
        let result = ServerInfoXMLParser().parse(data: data)
        let xml = result.xml
        try xml.verifyStatus()

        var info = ServerInfo()
        info.hostname = xml.elements["hostname"] ?? ""
        info.uuid = xml.elements["uniqueid"] ?? ""
        info.mac = xml.elements["mac"] ?? ""
        info.localAddress = xml.elements["LocalIP"] ?? ""
        info.remoteAddress = xml.elements["ExternalIP"] ?? ""
        info.pairStatus = xml.elements["PairStatus"] == "1"
        info.currentGameId = Int(xml.elements["currentgame"] ?? "0") ?? 0
        info.appVersion = xml.elements["appversion"] ?? ""
        info.gfeVersion = xml.elements["GfeVersion"] ?? ""
        info.gpuModel = xml.elements["gputype"] ?? ""
        info.serverCodecModeSupport = Int(xml.elements["ServerCodecModeSupport"] ?? "1") ?? 1
        info.maxLumaPixelsHEVC = Int(xml.elements["MaxLumaPixelsHEVC"] ?? "0") ?? 0
        info.displayModes = result.displayModes

        if let portStr = xml.elements["HttpsPort"], let port = UInt16(portStr), port > 0 {
            info.httpsPort = port
            if self.httpsPort != port {
                self.httpsPort = port
            }
        }

        if let state = xml.elements["state"] {
            info.isNvidiaServerSoftware = state.contains("MJOLNIR")
        }

        return info
    }

    // MARK: - App List

    func getAppList() async throws -> [MoonlightApp] {
        guard serverCertDER != nil else { throw MoonlightError.notPaired }

        let data = try await nwRawRequest("applist", port: httpsPort, useTLS: true)

        // Parse app list XML with specialized parser
        let parser = AppListXMLParser()
        let result = parser.parse(data: data)
        AppLog.nvHTTPClient.line("applist: \(data.count) bytes, status=\(parser.lastStatusCode ?? "none"), parsed \(result.count) app(s)")
        if result.isEmpty, let body = String(data: data, encoding: .utf8) {
            AppLog.nvHTTPClient.line("applist empty — body: \(body.prefix(600))")
        }
        return result
    }

    // MARK: - Launch / Resume / Quit

    func launchApp(appId: Int, width: Int, height: Int, fps: Int,
                   bitrate: Int, riKey: Data, riKeyId: Int32,
                   localAudioPlayMode: Bool, surroundAudioInfo: Int,
                   supportedVideoFormats: Int, optimizeGameSettings: Bool) async throws -> String {
        guard serverCertDER != nil else { throw MoonlightError.notPaired }

        var args: [(String, String)] = [
            ("appid", String(appId)),
            ("mode", "\(width)x\(height)x\(fps)"),
            ("additionalStates", "1"),
            ("sops", optimizeGameSettings ? "1" : "0"),
            ("rikey", riKey.hexString),
            ("rikeyid", String(riKeyId)),
            ("localAudioPlayMode", localAudioPlayMode ? "1" : "0"),
            ("surroundAudioInfo", String(surroundAudioInfo)),
            ("remoteControllersBitmap", "0"),
            ("gcmap", "0"),
            ("corever", "1"),
        ]

        // Add HDR params if 10-bit formats are in the supported list
        // VIDEO_FORMAT_MASK_10BIT = 0xAA00 (all 10-bit VIDEO_FORMAT_* flags)
        let videoFormat10BitMask = 0xAA00
        if supportedVideoFormats & videoFormat10BitMask != 0 {
            args.append(("hdrMode", "1"))
            args.append(("clientHdrCapVersion", "0"))
            args.append(("clientHdrCapSupportedFlagsInUint32", "0"))
            args.append(("clientHdrCapMetaDataId", "NV_STATIC_METADATA_TYPE_1"))
            args.append(("clientHdrCapDisplayData", "0x0x0x0x0x0x0x0x0x0x0"))
        }

        let xml = try await nwRequest("launch", args: args, port: httpsPort, useTLS: true, timeout: 120)
        AppLog.nvHTTPClient.line("launch app=\(appId) mode=\(width)x\(height)x\(fps) sops=\(optimizeGameSettings) → status=\(xml.rootAttributes["status_code"] ?? "?") msg=\(xml.rootAttributes["status_message"] ?? xml.elements["status_message"] ?? "-") gamesession=\(xml.elements["gamesession"] ?? "-") sessionUrl0=\(xml.elements["sessionUrl0"] != nil)")
        try xml.verifyStatus()

        guard let sessionUrl = xml.elements["sessionUrl0"] else {
            throw MoonlightError.invalidResponse
        }
        return sessionUrl
    }

    func resumeApp(riKey: Data, riKeyId: Int32, surroundAudioInfo: Int) async throws -> String {
        guard serverCertDER != nil else { throw MoonlightError.notPaired }

        let args: [(String, String)] = [
            ("rikey", riKey.hexString),
            ("rikeyid", String(riKeyId)),
            ("surroundAudioInfo", String(surroundAudioInfo)),
            ("corever", "1"),
        ]

        let xml = try await nwRequest("resume", args: args, port: httpsPort, useTLS: true, timeout: 30)
        AppLog.nvHTTPClient.line("resume → status=\(xml.rootAttributes["status_code"] ?? "?") msg=\(xml.rootAttributes["status_message"] ?? xml.elements["status_message"] ?? "-") sessionUrl0=\(xml.elements["sessionUrl0"] != nil)")
        try xml.verifyStatus()

        guard let sessionUrl = xml.elements["sessionUrl0"] else {
            throw MoonlightError.invalidResponse
        }
        return sessionUrl
    }

    func quitApp() async throws {
        guard serverCertDER != nil else { throw MoonlightError.notPaired }

        let xml = try await nwRequest("cancel", port: httpsPort, useTLS: true, timeout: 30)
        AppLog.nvHTTPClient.line("quit → status=\(xml.rootAttributes["status_code"] ?? "?") msg=\(xml.rootAttributes["status_message"] ?? xml.elements["status_message"] ?? "-")")
        try xml.verifyStatus()
    }

    // MARK: - Pairing Endpoints (called by NvPairingManager)

    /// Send a pairing request. Returns parsed XML elements.
    /// Pass `timeout: nil` for the default (5s), or `timeout: 0` for indefinite wait (getservercert).
    /// Pass `useHTTPS: true` for the final pair challenge (step 6).
    func pairRequest(args: [(String, String)], timeout: TimeInterval? = nil, useHTTPS: Bool = false) async throws -> XMLResponse {
        var allArgs = [("devicename", Self.deviceName), ("updateState", "1")]
        allArgs.append(contentsOf: args)

        let effectiveTimeout: TimeInterval = timeout == 0 ? 300 : (timeout ?? 5)
        if useHTTPS {
            // Final pair challenge uses TLS via NWConnection (bypasses ATS)
            return try await nwRequest("pair", args: allArgs, port: httpsPort, useTLS: true, timeout: effectiveTimeout)
        } else {
            // Pre-pairing steps: plain HTTP via NWConnection
            return try await nwRequest("pair", args: allArgs, port: httpPort, timeout: effectiveTimeout)
        }
    }

    func unpair() async throws {
        let xml = try await nwRequest("unpair", port: httpPort)
        try xml.verifyStatus()
    }

    // MARK: - HTTP Internals

    /// NWConnection-based request → parsed XML. Used for all server communication.
    private func nwRequest(_ command: String, args: [(String, String)] = [],
                           port: UInt16, useTLS: Bool = false, timeout: TimeInterval = 5) async throws -> XMLResponse {
        let data = try await nwRawRequest(command, args: args, port: port, useTLS: useTLS, timeout: timeout)
        return SimpleXMLParser().parse(data: data)
    }

    // MARK: - ATS-Free HTTP via NWConnection

    /// Build a URL string for the given command (used by both URLSession and NWConnection paths).
    private func buildURL(command: String, args: [(String, String)], useHTTPS: Bool) -> URL? {
        let scheme = useHTTPS ? "https" : "http"
        let port = useHTTPS ? httpsPort : httpPort

        var components = URLComponents()
        components.scheme = scheme
        components.host = hostname
        components.port = Int(port)
        components.path = "/\(command)"

        var queryItems = [
            URLQueryItem(name: "uniqueid", value: Self.uniqueId),
            URLQueryItem(name: "uuid", value: UUID().uuidString.replacingOccurrences(of: "-", with: "")),
        ]
        for (key, value) in args {
            queryItems.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = queryItems
        return components.url
    }

    /// Perform a raw HTTP GET using NWConnection (Network.framework), bypassing URLSession and ATS entirely.
    /// - Parameters:
    ///   - command: The API endpoint (e.g. "serverinfo", "pair")
    ///   - args: Additional query parameters
    ///   - port: Target port
    ///   - useTLS: If true, connects with TLS (accepts any server cert, presents client cert if available)
    ///   - timeout: Request timeout in seconds
    private func nwRawRequest(_ command: String, args: [(String, String)] = [],
                              port: UInt16, useTLS: Bool = false, timeout: TimeInterval = 5) async throws -> Data {
        guard let url = buildURL(command: command, args: args, useHTTPS: false) else {
            throw MoonlightError.networkError(URLError(.badURL))
        }

        // Build HTTP/1.1 GET request
        let pathAndQuery = url.query.map { "\(url.path)?\($0)" } ?? url.path
        let httpRequest = "GET \(pathAndQuery) HTTP/1.1\r\nHost: \(hostname):\(port)\r\nConnection: close\r\n\r\n"

        // Configure NWParameters for TCP or TLS
        let parameters: NWParameters
        if useTLS {
            parameters = await self.nwTLSParameters()
        } else {
            parameters = .tcp
        }

        return try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(hostname),
                port: NWEndpoint.Port(rawValue: port)!,
                using: parameters
            )

            var resumed = false
            let resume: (Result<Data, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(with: result)
            }

            // Timeout
            let timeoutItem = DispatchWorkItem { resume(.failure(URLError(.timedOut))) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Send HTTP request
                    let requestData = httpRequest.data(using: .utf8)!
                    connection.send(content: requestData, completion: .contentProcessed { error in
                        if let error {
                            timeoutItem.cancel()
                            resume(.failure(error))
                            return
                        }

                        // Receive entire response
                        self.nwReceiveAll(connection: connection) { result in
                            timeoutItem.cancel()
                            switch result {
                            case .success(let responseData):
                                // Strip HTTP headers — find \r\n\r\n
                                if let headerEnd = responseData.range(of: Data("\r\n\r\n".utf8)) {
                                    resume(.success(responseData.suffix(from: headerEnd.upperBound)))
                                } else {
                                    resume(.success(responseData))
                                }
                            case .failure(let error):
                                resume(.failure(error))
                            }
                        }
                    })
                case .failed(let error):
                    timeoutItem.cancel()
                    resume(.failure(error))
                case .cancelled:
                    timeoutItem.cancel()
                default:
                    break
                }
            }

            connection.start(queue: .global())
        }
    }

    /// Build NWParameters for TLS that accepts any server certificate and presents the client identity.
    private func nwTLSParameters() async -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        let secOptions = tlsOptions.securityProtocolOptions

        // Accept any server certificate (bypass ATS trust evaluation for self-signed Sunshine certs)
        sec_protocol_options_set_verify_block(secOptions, { _, _, completionHandler in
            completionHandler(true)
        }, .global())

        // Present client certificate for TLS mutual auth (required by Sunshine)
        do {
            let identity = try await cryptoManager.getClientSecIdentity()
            if let secIdentity = sec_identity_create(identity) {
                sec_protocol_options_set_local_identity(secOptions, secIdentity)
            } else {
                AppLog.nvHTTPClient.line("WARNING: sec_identity_create returned nil — TLS client auth will fail")
            }
        } catch {
            AppLog.nvHTTPClient.line("ERROR: Failed to get client identity for TLS: \(error)")
        }

        return NWParameters(tls: tlsOptions)
    }

    /// Accumulate all data from an NWConnection until EOF.
    private nonisolated func nwReceiveAll(connection: NWConnection, accumulated: Data = Data(),
                                          completion: @escaping (Result<Data, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, error in
            var data = accumulated
            if let content { data.append(content) }

            if let error {
                completion(.failure(error))
            } else if isComplete {
                completion(.success(data))
            } else {
                self.nwReceiveAll(connection: connection, accumulated: data, completion: completion)
            }
        }
    }
}

// MARK: - XML Parsing

struct XMLResponse: Sendable {
    let elements: [String: String]
    let rootAttributes: [String: String]

    nonisolated func verifyStatus() throws {
        guard let statusStr = rootAttributes["status_code"] else {
            throw MoonlightError.invalidResponse
        }

        // Parse as unsigned first (GFE can return 0xFFFFFFFF), then check for 200
        let status: Int
        if let unsigned = UInt32(statusStr) {
            status = Int(Int32(bitPattern: unsigned))
        } else if let signed = Int(statusStr) {
            status = signed
        } else {
            throw MoonlightError.invalidResponse
        }

        guard status == 200 else {
            let message = rootAttributes["status_message"] ?? elements["status_message"] ?? "Unknown error (code: \(status))"
            throw MoonlightError.serverError(message)
        }
    }
}

/// SAX-style XML parser that extracts flat key-value pairs from XML elements.
private class SimpleXMLParser: NSObject, XMLParserDelegate {
    private nonisolated(unsafe) var elements: [String: String] = [:]
    private nonisolated(unsafe) var rootAttributes: [String: String] = [:]
    private nonisolated(unsafe) var currentElement: String?
    private nonisolated(unsafe) var currentText: String = ""

    nonisolated func parse(data: Data) -> XMLResponse {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return XMLResponse(elements: elements, rootAttributes: rootAttributes)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if elementName == "root" {
            rootAttributes = attributes
        }
        currentElement = elementName
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if !currentText.isEmpty {
            elements[elementName] = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        currentElement = nil
    }
}

/// Parses the /serverinfo XML response, including flat key-value elements and nested <DisplayMode> entries.
private class ServerInfoXMLParser: NSObject, XMLParserDelegate {
    private nonisolated(unsafe) var elements: [String: String] = [:]
    private nonisolated(unsafe) var rootAttributes: [String: String] = [:]
    private nonisolated(unsafe) var displayModes: [DisplayMode] = []
    private nonisolated(unsafe) var currentElement: String?
    private nonisolated(unsafe) var currentText: String = ""
    private nonisolated(unsafe) var insideDisplayMode = false
    private nonisolated(unsafe) var currentWidth: Int = 0
    private nonisolated(unsafe) var currentHeight: Int = 0
    private nonisolated(unsafe) var currentRefreshRate: Int = 0

    struct Result {
        let xml: XMLResponse
        let displayModes: [DisplayMode]
    }

    nonisolated func parse(data: Data) -> Result {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return Result(
            xml: XMLResponse(elements: elements, rootAttributes: rootAttributes),
            displayModes: displayModes
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if elementName == "root" {
            rootAttributes = attributes
        } else if elementName == "DisplayMode" {
            insideDisplayMode = true
            currentWidth = 0
            currentHeight = 0
            currentRefreshRate = 0
        }
        currentElement = elementName
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if insideDisplayMode {
            switch elementName {
            case "Width": currentWidth = Int(trimmed) ?? 0
            case "Height": currentHeight = Int(trimmed) ?? 0
            case "RefreshRate": currentRefreshRate = Int(trimmed) ?? 0
            case "DisplayMode":
                if currentWidth > 0 && currentHeight > 0 && currentRefreshRate > 0 {
                    displayModes.append(DisplayMode(
                        width: currentWidth,
                        height: currentHeight,
                        refreshRate: currentRefreshRate
                    ))
                }
                insideDisplayMode = false
            default: break
            }
        } else if !trimmed.isEmpty {
            elements[elementName] = trimmed
        }

        currentElement = nil
    }
}

/// Parses the /applist XML response containing multiple <App> elements.
private class AppListXMLParser: NSObject, XMLParserDelegate {
    private nonisolated(unsafe) var apps: [MoonlightApp] = []
    private nonisolated(unsafe) var currentAppId: Int = 0
    private nonisolated(unsafe) var currentAppName: String = ""
    private nonisolated(unsafe) var currentHdr: Bool = false
    private nonisolated(unsafe) var currentCollector: Bool = false
    private nonisolated(unsafe) var insideApp = false
    private nonisolated(unsafe) var currentElement: String?
    private nonisolated(unsafe) var currentText: String = ""
    private nonisolated(unsafe) var rootAttributes: [String: String] = [:]
    /// The root element's `status_code` attribute from the last parse (for diagnostics).
    nonisolated(unsafe) var lastStatusCode: String?

    nonisolated func parse(data: Data) -> [MoonlightApp] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()

        lastStatusCode = rootAttributes["status_code"]

        // Verify status first
        if let statusStr = rootAttributes["status_code"],
           let status = Int(statusStr), status != 200 {
            return []
        }

        return apps
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if elementName == "root" {
            rootAttributes = attributes
        } else if elementName == "App" {
            insideApp = true
            currentAppId = 0
            currentAppName = ""
            currentHdr = false
            currentCollector = false
        }
        currentElement = elementName
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if insideApp {
            switch elementName {
            case "AppTitle": currentAppName = trimmed
            case "ID": currentAppId = Int(trimmed) ?? 0
            case "IsHdrSupported": currentHdr = trimmed == "1"
            case "IsAppCollectorGame": currentCollector = trimmed == "1"
            case "App":
                if currentAppId != 0 && !currentAppName.isEmpty {
                    apps.append(MoonlightApp(
                        id: currentAppId,
                        name: currentAppName,
                        hdrSupported: currentHdr,
                        isAppCollectorGame: currentCollector
                    ))
                }
                insideApp = false
            default: break
            }
        }

        currentElement = nil
    }
}
#endif
