// GLM Usage Menubar — 菜单栏 + 桌面悬浮小组件，实时显示 GLM Coding Plan 剩余用量
// 数据源: GET {baseUrl}/api/monitor/usage/quota/limit (Authorization: <apiKey>)
// 单文件 AppKit 应用，零第三方依赖，swiftc 直接编译。

import AppKit
import Foundation
import ServiceManagement

// MARK: - API 模型

struct QuotaResponse: Decodable {
    struct UsageDetail: Decodable {
        let modelCode: String?
        let usage: Int?
    }

    struct Limit: Decodable {
        let type: String           // TOKENS_LIMIT = 5 小时编码窗口; TIME_LIMIT = MCP 调用配额
        let unit: Int?
        let number: Int?
        let usage: Int?            // 配额总量（计数型限制）
        let currentValue: Int?     // 已用次数
        let remaining: Int?        // 剩余次数
        let percentage: Int?       // 已用百分比
        let nextResetTime: Double? // 毫秒时间戳
        let usageDetails: [UsageDetail]?
    }

    struct Payload: Decodable {
        let level: String?
        let limits: [Limit]?
    }

    let code: Int?
    let msg: String?
    let data: Payload?
    let success: Bool?
}

// MARK: - 配置

struct AppConfig: Codable {
    var apiKey: String?
    var baseUrl: String?
    var intervalSeconds: Int?
    var panelVisible: Bool?
    var zcodeApiBase: String?
}

/// 悬浮窗位置等界面状态（与配置分开存储）
struct PanelState: Codable {
    var panelX: Double?
    var panelY: Double?
}

enum Config {
    static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".glm-usage-menubar")
    static let appConfigURL = configDir.appendingPathComponent("config.json")
    static let panelStateURL = configDir.appendingPathComponent("state.json")
    static let zcodeConfigURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".zcode/cli/config.json")
    static let defaultBaseURL = "https://open.bigmodel.cn"

    /// API Key 解析优先级: 环境变量 GLM_API_KEY > config.json > ~/.zcode/cli/config.json
    static func load() -> AppConfig {
        var cfg = AppConfig(apiKey: nil, baseUrl: nil, intervalSeconds: nil, panelVisible: nil, zcodeApiBase: nil)

        if let data = try? Data(contentsOf: appConfigURL),
           let parsed = try? JSONDecoder().decode(AppConfig.self, from: data) {
            cfg.apiKey = parsed.apiKey ?? cfg.apiKey
            cfg.baseUrl = parsed.baseUrl ?? cfg.baseUrl
            cfg.intervalSeconds = parsed.intervalSeconds ?? cfg.intervalSeconds
            cfg.panelVisible = parsed.panelVisible ?? cfg.panelVisible
            cfg.zcodeApiBase = parsed.zcodeApiBase ?? cfg.zcodeApiBase
        }

        if cfg.apiKey == nil,
           let data = try? Data(contentsOf: zcodeConfigURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let mcp = obj["mcp"] as? [String: Any],
           let servers = mcp["servers"] as? [String: Any],
           let zai = servers["zai-mcp-server"] as? [String: Any],
           let env = zai["env"] as? [String: Any],
           let key = env["Z_AI_API_KEY"] as? String {
            cfg.apiKey = key
        }

        cfg.apiKey = cfg.apiKey ?? ProcessInfo.processInfo.environment["GLM_API_KEY"]
        cfg.baseUrl = (cfg.baseUrl
            ?? ProcessInfo.processInfo.environment["GLM_BASE_URL"])
            ?? defaultBaseURL
        cfg.intervalSeconds = cfg.intervalSeconds
            ?? Int(ProcessInfo.processInfo.environment["GLM_INTERVAL"] ?? "") ?? 60
        return cfg
    }

    static func loadPanelState() -> PanelState {
        (try? JSONDecoder().decode(PanelState.self, from: Data(contentsOf: panelStateURL))) ?? PanelState()
    }

    static func savePanelState(_ state: PanelState) {
        let dir = panelStateURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: panelStateURL, options: .atomic)
        }
    }

    /// 创建配置文件模板（不存在时）
    static func createTemplateIfMissing() -> URL? {
        guard !FileManager.default.fileExists(atPath: appConfigURL.path) else { return appConfigURL }
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let template = """
        {
          "apiKey": "在这里填入你的 GLM Coding Plan API Key",
          "baseUrl": "\(defaultBaseURL)",
          "intervalSeconds": 60,
          "panelVisible": false
        }
        """
        try? template.write(to: appConfigURL, atomically: true, encoding: .utf8)
        return appConfigURL
    }
}

// MARK: - 用量获取

enum UsageState {
    case loading
    case loaded(QuotaResponse, Date)
    case failed(String, Date?)
}

final class UsageFetcher {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
    }

    func fetch(cfg: AppConfig, completion: @escaping (Result<QuotaResponse, Error>) -> Void) {
        guard let key = cfg.apiKey, !key.isEmpty, !key.contains("在这里") else {
            completion(.failure(UsageError.noApiKey))
            return
        }
        guard let url = URL(string: "\(cfg.baseUrl!)/api/monitor/usage/quota/limit") else {
            completion(.failure(UsageError.badURL))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // 该接口要求原始 Key 作为 Authorization 值（不带 Bearer 前缀）
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                completion(.failure(UsageError.badResponse))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
                completion(.failure(UsageError.http(http.statusCode, body)))
                return
            }
            do {
                completion(.success(try JSONDecoder().decode(QuotaResponse.self, from: data)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
}

enum UsageError: LocalizedError {
    case noApiKey
    case badURL
    case badResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .noApiKey:
            return "未找到 API Key（GLM_API_KEY / config.json / zcode 配置）"
        case .badURL:
            return "baseUrl 无效"
        case .badResponse:
            return "响应异常"
        case .http(let code, let body):
            switch code {
            case 401: return "401 未授权：API Key 无效或不具备 Coding Plan 权限"
            case 429: return "429 请求过于频繁"
            default: return "HTTP \(code) \(body)"
            }
        }
    }
}

// MARK: - 展示格式化

func timeString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
}

func resetTimeLabel(_ ms: Double?, now: Date) -> String? {
    guard let ms else { return nil }
    let date = Date(timeIntervalSince1970: ms / 1000)
    let formatter = DateFormatter()
    // 与智谱网页控制台一致，固定按北京时间显示
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) {
        formatter.dateFormat = "今天 HH:mm"
    } else {
        formatter.dateFormat = "MM-dd HH:mm"
    }
    let mins = max(0, Int(date.timeIntervalSince(now) / 60))
    let countdown: String
    if mins >= 1440 {
        countdown = "\(mins / 1440) 天 \(mins % 1440 / 60) 小时"
    } else if mins >= 60 {
        countdown = "\(mins / 60) 小时 \(mins % 60) 分"
    } else {
        countdown = "\(mins) 分钟"
    }
    return "\(formatter.string(from: date))（\(countdown)后）"
}

/// 依据状态生成标题文本与颜色（菜单栏与悬浮窗共用）
func titleText(for state: UsageState) -> (text: String, color: NSColor) {
    switch state {
    case .loading:
        return ("GLM …", .labelColor)
    case .failed:
        return ("GLM ⚠️", .systemYellow)
    case .loaded(let resp, _):
        let limit = resp.data?.limits?.first { $0.type == "TOKENS_LIMIT" }
        guard let used = limit?.percentage else { return ("GLM", .labelColor) }
        let remaining = max(0, 100 - used)
        let color: NSColor = remaining <= 5 ? .systemRed : remaining <= 20 ? .systemOrange : .labelColor
        // 标题 = 剩余百分比 + 紧凑倒计时（26m / 2h47m / 2d3h），随每轮轮询刷新
        guard let resetMs = limit?.nextResetTime else { return ("GLM \(remaining)%", color) }
        let reset = Date(timeIntervalSince1970: resetMs / 1000)
        let mins = max(0, Int(reset.timeIntervalSince(Date()) / 60))
        let countdown: String
        if mins >= 1440 {
            countdown = "\(mins / 1440)d\(mins % 1440 / 60)h"
        } else if mins >= 60 {
            countdown = "\(mins / 60)h\(mins % 60)m"
        } else {
            countdown = "\(mins)m"
        }
        return ("\(remaining)% \(countdown)", color)
    }
}

// MARK: - 悬浮 HUD 小组件

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// 悬浮窗按钮：单击弹菜单（原生 performClick → target/action，AXPress 可用），拖动移动
final class HUDButton: NSButton {
    var onMoved: (() -> Void)?

    /// 面板不会成为 key window，必须接受首击，否则点击仅用于激活窗口
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        var last = NSEvent.mouseLocation
        var moved = false
        while let ev = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if ev.type == .leftMouseUp {
                if moved {
                    onMoved?()
                } else {
                    performClick(nil)
                }
                return
            }
            let now = NSEvent.mouseLocation
            if !moved, abs(now.x - last.x) + abs(now.y - last.y) < 4 { continue }
            moved = true
            if let window {
                var origin = window.frame.origin
                origin.x += now.x - last.x
                origin.y += now.y - last.y
                window.setFrameOrigin(origin)
            }
            last = now
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        performClick(nil)
    }
}

// MARK: - 重置券（ZCode 账号 OAuth 登录后可用）

struct ResetCredentials: Codable {
    var zcodeJwt: String
    var bigmodelAccess: String
    var userName: String
}

enum CredentialsStore {
    static let url = Config.configDir.appendingPathComponent("credentials.json")

    static func load() -> ResetCredentials? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ResetCredentials.self, from: data)
    }

    static func save(_ creds: ResetCredentials) {
        try? FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(creds) else { return }
        try? data.write(to: url, options: .atomic)
        // 令牌文件仅本人可读写
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// /api/v1/coding-plan/reset/status 的 data 段
struct ResetStatus: Decodable {
    let fiveHourExpireAts: [Date]
    let weekExpireAts: [Date]
    let lastFiveHourUsedAt: Date?
    let lastWeekUsedAt: Date?

    init(fiveHour: [Date], week: [Date], lastFiveHour: Date?, lastWeek: Date?) {
        fiveHourExpireAts = fiveHour
        weekExpireAts = week
        lastFiveHourUsedAt = lastFiveHour
        lastWeekUsedAt = lastWeek
    }
}

private struct ResetStatusEnvelope: Decodable {
    struct Voucher: Decodable { let expire_at: Double }
    struct History: Decodable { let used_at: Double }
    struct Payload: Decodable {
        let available_five_hour_resets: [Voucher]?
        let available_week_resets: [Voucher]?
        let latest_five_hour_reset_history: History?
        let latest_week_reset_history: History?
    }
    let code: Int
    let msg: String?
    let data: Payload?

    var status: ResetStatus? {
        guard let d = data else { return nil }
        // expire_at/used_at 为毫秒 epoch（兼容秒），直接用会得到公元 5 万年的日期
        func toDate(_ v: Double) -> Date {
            v > 1e12 ? Date(timeIntervalSince1970: v / 1000) : Date(timeIntervalSince1970: v)
        }
        return ResetStatus(
            fiveHour: (d.available_five_hour_resets ?? []).map { toDate($0.expire_at) },
            week: (d.available_week_resets ?? []).map { toDate($0.expire_at) },
            lastFiveHour: d.latest_five_hour_reset_history.map { toDate($0.used_at) },
            lastWeek: d.latest_week_reset_history.map { toDate($0.used_at) }
        )
    }
}

enum ResetError: LocalizedError {
    case unauthorized
    case message(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "登录已过期，请重新登录 ZCode 账号"
        case .message(let m): return m
        }
    }
}

final class ResetClient {
    static let shared = ResetClient()
    private let session: URLSession

    init() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        session = URLSession(configuration: c)
    }

    private var base: String { Config.load().zcodeApiBase ?? "https://zcode.z.ai" }

    private static func randomHex(bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return b.map { String(format: "%02x", $0) }.joined()
    }

    private func get(_ url: URL, headers: [String: String], completion: @escaping (Result<Data, ResetError>) -> Void) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        session.dataTask(with: req) { data, resp, error in
            Self.handle(data: data, resp: resp, error: error, completion: completion)
        }.resume()
    }

    private func post(_ url: URL, headers: [String: String], body: [String: Any], completion: @escaping (Result<Data, ResetError>) -> Void) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        session.dataTask(with: req) { data, resp, error in
            Self.handle(data: data, resp: resp, error: error, completion: completion)
        }.resume()
    }

    private static func handle(data: Data?, resp: URLResponse?, error: Error?, completion: @escaping (Result<Data, ResetError>) -> Void) {
        DispatchQueue.main.async {
            if let error {
                completion(.failure(.message(error.localizedDescription)))
                return
            }
            guard let http = resp as? HTTPURLResponse, let data else {
                completion(.failure(.message("响应异常")))
                return
            }
            if http.statusCode == 401 {
                completion(.failure(.unauthorized))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
                completion(.failure(.message("HTTP \(http.statusCode) \(body)")))
                return
            }
            completion(.success(data))
        }
    }

    /// 双令牌请求头（与 ZCode 客户端一致）
    private static func resetHeaders(_ creds: ResetCredentials) -> [String: String] {
        [
            "Authorization": "Bearer \(creds.zcodeJwt)",
            "X-Bigmodel-Authorization": "Bearer \(creds.bigmodelAccess)",
            "Bigmodel-Target-Type": "PERSONAL",
        ]
    }

    // MARK: OAuth 登录

    struct LoginSession {
        let flowId: String
        let authorizeURL: URL
        let nonce: String
        let pollInterval: TimeInterval
        let expiresAt: Date
    }

    enum PollOutcome {
        case pending
        case ready(zcodeJwt: String, bigmodelAccess: String, userName: String?)
    }

    func startInit(completion: @escaping (Result<LoginSession, ResetError>) -> Void) {
        let nonce = Self.randomHex(bytes: 32)
        post(
            URL(string: "\(base)/api/v1/oauth/cli/init")!,
            headers: ["Authorization": "Bearer \(nonce)"],
            body: ["provider": "bigmodel"]
        ) { result in
            switch result {
            case .failure(let e):
                completion(.failure(e))
            case .success(let data):
                struct InitResp: Decodable {
                    let code: Int
                    let msg: String?
                    let data: Payload?
                    struct Payload: Decodable {
                        let flow_id: String?
                        let authorize_url: String?
                        let expires_at: Double?
                        let poll_interval_sec: Double?
                    }
                }
                if let resp = try? JSONDecoder().decode(InitResp.self, from: data),
                   code0(resp.code), let d = resp.data,
                   let flowId = d.flow_id, let auth = d.authorize_url, let url = URL(string: auth) {
                    let interval = TimeInterval(d.poll_interval_sec ?? 2)
                    // expires_at 单位不定（毫秒/秒 epoch 或相对秒数），按量级自适应
                    let expires: Date
                    if let v = d.expires_at {
                        if v > 1e12 {
                            expires = Date(timeIntervalSince1970: v / 1000)
                        } else if v > 1e8 {
                            expires = Date(timeIntervalSince1970: v)
                        } else {
                            expires = Date().addingTimeInterval(v)
                        }
                    } else {
                        expires = Date().addingTimeInterval(600)
                    }
                    completion(.success(LoginSession(
                        flowId: flowId, authorizeURL: url, nonce: nonce,
                        pollInterval: max(1, interval), expiresAt: expires
                    )))
                } else {
                    completion(.failure(.message("初始化登录失败")))
                }
            }
        }
    }

    func poll(flowId: String, nonce: String, completion: @escaping (Result<PollOutcome, ResetError>) -> Void) {
        get(
            URL(string: "\(base)/api/v1/oauth/cli/poll/\(flowId)")!,
            headers: ["Authorization": "Bearer \(nonce)"]
        ) { result in
            switch result {
            case .failure(let e):
                completion(.failure(e))
            case .success(let data):
                struct PollResp: Decodable {
                    let code: Int
                    let msg: String?
                    let data: Payload?
                    struct Payload: Decodable {
                        let status: String?
                        let token: String?
                        let bigmodel: Bigmodel?
                        let user: User?
                        struct Bigmodel: Decodable {
                            let access_token: String?
                            let accessToken: String?
                        }
                        struct User: Decodable {
                            let name: String?
                            let email: String?
                            let user_id: String?
                        }
                    }
                }
                guard let resp = try? JSONDecoder().decode(PollResp.self, from: data), code0(resp.code) else {
                    completion(.failure(.message("查询授权响应无效")))
                    return
                }
                switch resp.data?.status {
                case "pending", nil:
                    completion(.success(.pending))
                case "failed":
                    completion(.failure(.message("浏览器授权失败")))
                case "ready":
                    let d = resp.data!
                    let access = d.bigmodel?.access_token ?? d.bigmodel?.accessToken
                    guard let jwt = d.token, let access, !access.isEmpty else {
                        completion(.failure(.message("授权响应缺少令牌")))
                        return
                    }
                    let name = d.user?.name ?? d.user?.email
                    completion(.success(.ready(zcodeJwt: jwt, bigmodelAccess: access, userName: name)))
                default:
                    completion(.failure(.message("查询授权响应无效")))
                }
            }
        }
    }

    // MARK: 券查询 / 使用

    func fetchStatus(creds: ResetCredentials, completion: @escaping (Result<ResetStatus, ResetError>) -> Void) {
        get(
            URL(string: "\(base)/api/v1/coding-plan/reset/status")!,
            headers: Self.resetHeaders(creds)
        ) { result in
            switch result {
            case .failure(let e):
                completion(.failure(e))
            case .success(let data):
                if let envelope = try? JSONDecoder().decode(ResetStatusEnvelope.self, from: data),
                   envelope.code == 0, let status = envelope.status {
                    completion(.success(status))
                } else {
                    completion(.failure(.message("重置券响应无效")))
                }
            }
        }
    }

    func useVoucher(creds: ResetCredentials, type: String, completion: @escaping (Result<Void, ResetError>) -> Void) {
        post(
            URL(string: "\(base)/api/v1/coding-plan/reset/use")!,
            headers: Self.resetHeaders(creds),
            body: ["idempotency_key": Self.randomHex(bytes: 16), "reset_type": type]
        ) { result in
            switch result {
            case .failure(let e):
                completion(.failure(e))
            case .success(let data):
                struct UseResp: Decodable {
                    let code: Int
                    let msg: String?
                    let data: Payload?
                    struct Payload: Decodable { let used: Bool? }
                }
                if let resp = try? JSONDecoder().decode(UseResp.self, from: data), resp.code == 0, resp.data?.used == true {
                    completion(.success(()))
                } else {
                    let msg = (try? JSONDecoder().decode(UseResp.self, from: data))?.msg ?? "使用失败"
                    completion(.failure(.message(msg)))
                }
            }
        }
    }
}

private func code0(_ code: Int) -> Bool { code == 0 }

// MARK: - 菜单栏控制器

final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var state: UsageState = .loading
    private var timer: Timer?
    private let fetcher = UsageFetcher()
    private var cfg = Config.load()
    private var panelState = Config.loadPanelState()
    private var hudPanel: HUDPanel?
    private var hudButton: HUDButton?

    // 重置券状态
    private var credentials: ResetCredentials?
    private var resetStatus: ResetStatus?
    private enum ResetSession { case loggedOut, awaitingBrowser, expired, failed(String) }
    private var resetSession: ResetSession = .loggedOut
    private var loginPollTimer: Timer?
    private var loginFlowId: String?
    private var loginNonce: String?
    private var loginExpiresAt: Date?
    private let loginItem = NSMenuItem(title: "🔑 登录 ZCode 账号（查看重置券）", action: #selector(startResetLogin), keyEquivalent: "")
    private let accountLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let fiveHourLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let weekLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lastUsedLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let useVoucherItem = NSMenuItem(title: "⚡ 使用一张 5 小时重置券", action: #selector(useFiveHourVoucher), keyEquivalent: "")
    private let logoutResetItem = NSMenuItem(title: "退出重置券登录", action: #selector(logoutReset), keyEquivalent: "")

    // 菜单条目（打开菜单时刷新标题）
    private let statusLine = NSMenuItem(title: "加载中…", action: nil, keyEquivalent: "")
    private let tokensLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let tokensResetLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let timeLimitLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let timeLimitResetLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let detailsStart = NSMenuItem.separator()
    private var detailItems: [NSMenuItem] = []
    private let footerLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var panelToggleItem: NSMenuItem?

    override init() {
        super.init()
        credentials = CredentialsStore.load()
        buildMenu()
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        render()
        if cfg.panelVisible ?? false {
            showPanel()
        }
        refresh()
        scheduleTimer()
    }

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        tokensLine.isEnabled = false
        tokensResetLine.isEnabled = false
        menu.addItem(tokensLine)
        menu.addItem(tokensResetLine)
        menu.addItem(.separator())

        timeLimitLine.isEnabled = false
        timeLimitResetLine.isEnabled = false
        menu.addItem(timeLimitLine)
        menu.addItem(timeLimitResetLine)

        detailsStart.isEnabled = false
        menu.addItem(detailsStart)

        // 重置券区
        loginItem.target = self
        menu.addItem(loginItem)
        for item in [accountLine, fiveHourLine, weekLine, lastUsedLine] {
            item.isEnabled = false
            menu.addItem(item)
        }
        useVoucherItem.target = self
        menu.addItem(useVoucherItem)
        logoutResetItem.target = self
        menu.addItem(logoutResetItem)

        menu.addItem(.separator())
        footerLine.isEnabled = false
        menu.addItem(footerLine)
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let panelItem = NSMenuItem(title: "显示悬浮窗", action: #selector(togglePanel), keyEquivalent: "p")
        panelItem.target = self
        menu.addItem(panelItem)
        panelToggleItem = panelItem

        let configItem = NSMenuItem(title: "编辑配置…", action: #selector(editConfig), keyEquivalent: ",")
        configItem.target = self
        menu.addItem(configItem)

        let loginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(loginItem)

        let quitItem = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        // 不直接设置 statusItem.menu：菜单被状态项占有时，悬浮窗 popUp 会静默失败。
        // 两个入口统一走手动 popUp。
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        menu.popUp(positioning: nil, at: .zero, in: button)
    }

    // MARK: 轮询

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = max(10, Double(cfg.intervalSeconds ?? 60))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc func refresh() {
        // 静默刷新：轮询期间保留旧值，拿到新结果才原地更新，避免状态栏闪烁
        fetchResetStatus()
        fetcher.fetch(cfg: cfg) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let resp):
                    self.state = .loaded(resp, Date())
                case .failure(let error):
                    // 已有数据时静默保留（菜单里可见上次刷新时间），仅首次拉取失败才显示错误
                    if case .loading = self.state {
                        self.state = .failed(error.localizedDescription, Date())
                    }
                }
                self.render()
            }
        }
    }

    // MARK: 渲染

    private func render() {
        let (text, color) = titleText(for: state)
        if let button = statusItem.button {
            button.attributedTitle = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: color,
                ]
            )
        }
        renderPanel(text: text, color: color)
    }

    /// 打开菜单时刷新各条目标题
    func menuWillOpen(_ menu: NSMenu) {
        cfg = Config.load()
        switch state {
        case .loading:
            statusLine.title = "正在查询用量…"
            tokensLine.title = ""
            tokensResetLine.title = ""
            timeLimitLine.title = ""
            timeLimitResetLine.title = ""
            detailsStart.isHidden = true
            setDetailItems([])
        case .failed(let message, let at):
            var line = "⚠️ 查询失败: \(message)"
            if let at { line += "（\(timeString(at))）" }
            statusLine.title = line + " — 请检查「编辑配置…」中的 API Key"
            tokensLine.title = ""
            tokensResetLine.title = ""
            timeLimitLine.title = ""
            timeLimitResetLine.title = ""
            detailsStart.isHidden = true
            setDetailItems([])
        case .loaded(let resp, _):
            let level = (resp.data?.level ?? "未知").uppercased()
            statusLine.title = "GLM Coding Plan · \(level) 套餐"
            let now = Date()
            let tokens = resp.data?.limits?.first { $0.type == "TOKENS_LIMIT" }
            if let tokens {
                if let used = tokens.percentage {
                    tokensLine.title = "  5 小时 Token 窗口: 已用 \(used)%，剩余 \(max(0, 100 - used))%"
                } else {
                    tokensLine.title = "  5 小时 Token 窗口: 暂无数据"
                }
                tokensResetLine.title = resetTimeLabel(tokens.nextResetTime, now: now).map { "  ↻ 重置于 \($0)" } ?? ""
            } else {
                tokensLine.title = "  5 小时 Token 窗口: 无数据（Key 可能不含 Coding Plan 权限）"
                tokensResetLine.title = ""
            }

            let timeLimit = resp.data?.limits?.first { $0.type == "TIME_LIMIT" }
            if let timeLimit, let used = timeLimit.currentValue, let total = timeLimit.usage {
                let remaining = timeLimit.remaining ?? max(0, total - used)
                timeLimitLine.title = "  MCP 工具调用: 已用 \(used)/\(total)，剩余 \(remaining)"
                timeLimitResetLine.title = resetTimeLabel(timeLimit.nextResetTime, now: now).map { "  ↻ 重置于 \($0)" } ?? ""
                let details = (timeLimit.usageDetails ?? [])
                    .filter { ($0.usage ?? 0) > 0 }
                    .map { "      \($0.modelCode ?? "?") · \($0.usage ?? 0)" }
                setDetailItems(details)
                detailsStart.isHidden = details.isEmpty
            } else {
                timeLimitLine.title = "  MCP 工具调用: 暂无数据"
                timeLimitResetLine.title = ""
                detailsStart.isHidden = true
                setDetailItems([])
            }
        }
        let interval = max(10, cfg.intervalSeconds ?? 60)
        if case .loaded(_, let at) = state {
            footerLine.title = "上次刷新 \(timeString(at)) · 每 \(interval) 秒自动刷新"
        } else {
            footerLine.title = "每 \(interval) 秒自动刷新 · 数据源 \(cfg.baseUrl ?? Config.defaultBaseURL)"
        }
        renderResetMenuItems()
        panelToggleItem?.title = (hudPanel == nil) ? "显示悬浮窗" : "隐藏悬浮窗"
    }

    // MARK: 重置券菜单渲染与动作

    private func dateShort(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        // 与智谱网页控制台一致，固定按北京时间显示
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: date)
    }

    private func resetLine(_ label: String, _ dates: [Date]) -> String {
        guard let earliest = dates.min() else { return "  \(label): 无" }
        return "  \(label): \(dates.count) 张（最早 \(dateShort(earliest)) 到期）"
    }

    private func renderResetMenuItems() {
        var awaiting = false
        if case .awaitingBrowser = resetSession { awaiting = true }

        loginItem.isHidden = credentials != nil || awaiting
        loginItem.isEnabled = !loginItem.isHidden
        if credentials == nil, !awaiting {
            switch resetSession {
            case .expired:
                loginItem.title = "🔑 登录已过期，点击重新登录（重置券）"
            case .failed(let message):
                loginItem.title = "登录失败：\(message)（点击重试）"
            default:
                loginItem.title = "🔑 登录 ZCode 账号（查看重置券）"
            }
        }

        let hasCreds = credentials != nil
        accountLine.isHidden = !hasCreds
        let hasStatus = hasCreds && resetStatus != nil
        fiveHourLine.isHidden = !hasStatus
        weekLine.isHidden = !hasStatus
        lastUsedLine.isHidden = !hasStatus
        useVoucherItem.isHidden = !hasStatus || (resetStatus?.fiveHourExpireAts.isEmpty ?? true)
        useVoucherItem.isEnabled = !useVoucherItem.isHidden
        logoutResetItem.isHidden = !hasCreds

        if let creds = credentials {
            accountLine.title = "👤 \(creds.userName.isEmpty ? "已登录" : creds.userName)"
            if let s = resetStatus {
                fiveHourLine.title = resetLine("5 小时重置券", s.fiveHourExpireAts)
                weekLine.title = resetLine("周重置券", s.weekExpireAts)
                var parts: [String] = []
                if let d = s.lastFiveHourUsedAt { parts.append("5h \(dateShort(d))") }
                if let d = s.lastWeekUsedAt { parts.append("周 \(dateShort(d))") }
                lastUsedLine.title = parts.isEmpty ? "  最近使用: 从未" : "  最近使用: \(parts.joined(separator: " · "))"
            } else if awaiting {
                fiveHourLine.title = "  券信息: 等待授权…"
            } else {
                fiveHourLine.title = "  券信息: 加载中…"
            }
        }
    }

    private func fetchResetStatus() {
        guard let creds = credentials else { return }
        ResetClient.shared.fetchStatus(creds: creds) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let status):
                self.resetStatus = status
            case .failure(let error):
                if case .unauthorized = error {
                    CredentialsStore.clear()
                    self.credentials = nil
                    self.resetStatus = nil
                    self.resetSession = .expired
                }
                // 其他失败静默保留旧值
            }
            self.render()
        }
    }

    @objc private func startResetLogin() {
        resetSession = .awaitingBrowser
        ResetClient.shared.startInit { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.resetSession = .failed(error.localizedDescription)
            case .success(let session):
                NSWorkspace.shared.open(session.authorizeURL)
                self.armLoginPolling(session)
            }
        }
    }

    private func armLoginPolling(_ session: ResetClient.LoginSession) {
        loginPollTimer?.invalidate()
        loginFlowId = session.flowId
        loginNonce = session.nonce
        loginExpiresAt = session.expiresAt
        loginPollTimer = Timer.scheduledTimer(withTimeInterval: session.pollInterval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if Date() >= (self.loginExpiresAt ?? Date()) {
                timer.invalidate()
                self.resetSession = .failed("授权超时，请重试")
                return
            }
            guard let flowId = self.loginFlowId, let nonce = self.loginNonce else { timer.invalidate(); return }
            ResetClient.shared.poll(flowId: flowId, nonce: nonce) { [weak self] result in
                guard let self else { return }
                var awaiting = false
                if case .success(.pending) = result { awaiting = true }
                if awaiting { return }
                switch result {
                case .success(.pending):
                    break
                case .failure(let error):
                    timer.invalidate()
                    self.resetSession = .failed(error.localizedDescription)
                case .success(.ready(let jwt, let access, let name)):
                    timer.invalidate()
                    let creds = ResetCredentials(zcodeJwt: jwt, bigmodelAccess: access, userName: name ?? "")
                    CredentialsStore.save(creds)
                    self.credentials = creds
                    self.resetStatus = nil
                    self.resetSession = .loggedOut
                    self.fetchResetStatus()
                }
                self.render()
            }
        }
    }

    @objc private func logoutReset() {
        loginPollTimer?.invalidate()
        CredentialsStore.clear()
        credentials = nil
        resetStatus = nil
        resetSession = .loggedOut
        render()
    }

    @objc private func useFiveHourVoucher() {
        guard let creds = credentials else { return }
        let alert = NSAlert()
        alert.messageText = "使用一张 5 小时重置券？"
        alert.informativeText = "将立即重置当前 5 小时 Token 窗口，并消耗一张重置券。此操作不可撤销。"
        alert.addButton(withTitle: "使用")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ResetClient.shared.useVoucher(creds: creds, type: "FIVE_HOUR") { [weak self] result in
            guard let self else { return }
            let notice = NSAlert()
            switch result {
            case .success:
                notice.messageText = "已使用重置券，Token 窗口已重置"
                self.refresh()
            case .failure(let error):
                notice.messageText = "使用失败"
                notice.informativeText = error.localizedDescription
                if case .unauthorized = error {
                    CredentialsStore.clear()
                    self.credentials = nil
                    self.resetStatus = nil
                    self.resetSession = .expired
                }
            }
            notice.runModal()
        }
    }

    /// 复用 detail 条目，避免每次重建菜单
    private func setDetailItems(_ titles: [String]) {
        while detailItems.count > titles.count, let last = detailItems.popLast() {
            menu.removeItem(last)
        }
        while detailItems.count < titles.count {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isEnabled = false
            let insertAt = menu.index(of: detailsStart) + 1 + detailItems.count
            menu.insertItem(item, at: insertAt)
            detailItems.append(item)
        }
        for (item, title) in zip(detailItems, titles) {
            item.title = title
        }
    }

    // MARK: 悬浮窗

    private func showPanel() {
        if hudPanel != nil {
            hudPanel?.orderFrontRegardless()
            return
        }
        let button = HUDButton()
        button.isBordered = false
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        button.alignment = .center
        button.target = self
        button.action = #selector(panelButtonClicked(_:))

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(effect, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            effect.topAnchor.constraint(equalTo: button.topAnchor),
            effect.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])

        let panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 150, height: 34),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.contentView = button
        button.onMoved = { [weak self, weak panel] in
            guard let window = panel else { return }
            self?.panelState.panelX = window.frame.midX
            self?.panelState.panelY = window.frame.midY
            Config.savePanelState(self?.panelState ?? PanelState())
        }
        hudPanel = panel
        hudButton = button

        positionPanel(panel)
        panel.orderFrontRegardless()
    }

    private func hidePanel() {
        hudPanel?.orderOut(nil)
        hudPanel = nil
        hudButton = nil
    }

    private func positionPanel(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        let workArea = mouseScreen?.visibleFrame ?? NSRect(x: 100, y: 100, width: 1200, height: 800)
        var center = NSPoint(
            x: panelState.panelX ?? (workArea.maxX - 120),
            y: panelState.panelY ?? (workArea.maxY - 110)
        )
        center.x = min(max(center.x, workArea.minX + 40), workArea.maxX - 40)
        center.y = min(max(center.y, workArea.minY + 20), workArea.maxY - 20)
        panel.setFrame(
            NSRect(x: center.x - 75, y: center.y - 17, width: 150, height: 34),
            display: true
        )
    }

    private func renderPanel(text: String, color: NSColor) {
        guard let button = hudButton else { return }
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: color,
            ]
        )
    }

    private func popupMenu(for panel: NSPanel) {
        let location = NSPoint(x: 0, y: panel.contentView!.bounds.height + 4)
        menu.popUp(positioning: nil, at: location, in: panel.contentView)
    }

    @objc private func panelButtonClicked(_ sender: NSButton) {
        guard let panel = hudPanel else { return }
        popupMenu(for: panel)
    }

    @objc private func togglePanel() {
        if hudPanel == nil {
            showPanel()
        } else {
            hidePanel()
        }
    }

    // MARK: 动作

    @objc private func editConfig() {
        guard let url = Config.createTemplateIfMissing() else { return }
        NSWorkspace.shared.open(url)
    }

    private var launchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else {
            showAlert("此功能需要 macOS 13 及以上版本。")
            return
        }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert("设置登录启动失败: \(error.localizedDescription)")
        }
        if let item = menu.items.first(where: { $0.action == #selector(toggleLaunchAtLogin) }) {
            item.state = launchAtLoginEnabled ? .on : .off
        }
    }

    private func showAlert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }
}

// MARK: - 启动

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = StatusBarController()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // 不显示 Dock 图标
app.run()
