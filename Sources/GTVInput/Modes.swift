import AppKit
import Carbon
import InputMethodKit

/// Chế độ Tiếng Việt / Tiếng Anh của GTV.
///
/// Đây là 2 input mode của cùng bộ gõ GTV ("<id>.vi", "<id>.en"). Chuyển chế độ bằng
/// `selectMode` trên ô nhập liệu đang dùng (API chính thức của InputMethodKit): bộ gõ không bị gỡ ra
/// hay gắn lại, nên chuyển tức thì, không nháy cửa sổ, và ⌘⇧ luôn do bộ gõ bắt được.
///
/// Ứng dụng loại trừ: khi GTV được gắn vào ô nhập liệu của ứng dụng trong danh sách thì chuyển sang
/// tiếng Anh; khi sang ứng dụng khác thì khôi phục tiếng Việt nếu trước đó đang gõ tiếng Việt.
final class Modes {
    static let shared = Modes()

    private(set) var vietnamese: Bool
    /// Đang ở ứng dụng loại trừ và trước đó đang gõ tiếng Việt.
    private var restoreVietnamese = false
    private weak var client: AnyObject?
    private var clientBundleID = ""
    /// GTV có đang được chọn không, bỏ qua lần đổi sang ABC do màn hình khoá (để khôi phục khi mở khoá).
    private var gtvInUse = InputSources.isGTVSelected
    /// Máy đang khoá màn hình hoặc đang ngủ: không coi các lần đổi bộ gõ lúc này là do người dùng.
    private var suspended = false
    /// Đổi sang bộ gõ khác chỉ được ghi nhận sau một lúc: khi gập máy, macOS có thể chuyển sang ABC
    /// trước khi kịp báo khoá/ngủ.
    private var pendingLeaveGTV: DispatchWorkItem?
    /// Hạn chờ màn hình hết khoá (đang chờ nếu khác nil).
    private var unlockDeadline: Date?
    /// Lúc GTV vừa được gắn vào một ô nhập liệu (đổi ứng dụng / ô nhập liệu, hoặc quay lại GTV từ bộ gõ khác).
    private var activatedAt: TimeInterval = 0
    /// Lúc một ứng dụng vừa được kích hoạt (NSWorkspace).
    private var appActivatedAt: TimeInterval = 0
    /// Ngay sau khi đổi ứng dụng / ô nhập liệu, macOS (hoặc ứng dụng) có thể tự chọn một chế độ khác của GTV
    /// (bộ gõ nhớ theo từng ứng dụng / cửa sổ). Lần đổi trong khoảng này mà người dùng không bấm phím hay click
    /// gì kể từ lúc kích hoạt thì không phải do người dùng: giữ nguyên chế độ của GTV.
    private static let activationWindow: TimeInterval = 0.6
    /// Bộ gõ đang chọn (theo thông báo gần nhất) có phải GTV không. Lúc tiến trình vừa khởi động coi như chưa: macOS khởi động
    /// GTV khi người dùng chọn một chế độ của nó từ bộ gõ khác (thông báo của lần chọn đó tới trước khi GTV kịp nghe) — lần gắn
    /// đầu tiên là lần quay lại GTV, lựa chọn đó (setValue) quyết định, GTV không chọn đè chế độ đã lưu.
    private var lastSourceIsGTV = false
    /// Lần rời GTV gần nhất là do hệ thống (ô mật khẩu, khoá màn hình, đổi ứng dụng), không phải người dùng tự
    /// chọn bộ gõ khác: lần quay lại GTV sau đó cũng do hệ thống, giữ chế độ của GTV. Người dùng tự chọn bộ gõ
    /// khác rồi tự chọn lại một chế độ của GTV thì theo lựa chọn đó.
    private var leftGTVBySystem = false
    /// Chế độ vừa bị bỏ qua vì do hệ thống chọn, và lúc đó: ứng dụng chọn lại chế độ này ngay sau đó (không có
    /// thao tác nào của người dùng) cũng bỏ qua.
    private var rejected: (on: Bool, at: TimeInterval)?
    /// Các lần GTV tự chọn một chế độ của nó trong 1 giây gần nhất (xem `select`, `ownSelection`).
    private var selfSelected: [(id: String, at: TimeInterval)] = []

    private init() {
        // Giữ chế độ người dùng chọn lần trước (bộ gõ có thể khởi động lại khi cập nhật, hay khi đang ở ABC).
        vietnamese = UserDefaults.standard.object(forKey: "vietnameseMode") as? Bool
            ?? (InputSources.currentID != InputSources.englishID)
        NotificationCenter.default.addObserver(forName: .gtvExcludedAppsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.exclusionChanged()
        }
        // macOS không phải lúc nào cũng báo cho bộ gõ (setValue) khi đổi chế độ, vd. khi ứng dụng đang
        // dùng không có ô nhập liệu nào đang focus: nghe thêm thông báo đổi bộ gõ của toàn hệ thống.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in
            self?.systemInputSourceChanged()
        }
        // Màn hình khoá luôn chuyển sang ABC để gõ mật khẩu, và macOS thường không trả lại bộ gõ bên
        // thứ ba khi mở khoá: tự chọn lại GTV.
        // Gập máy / máy ngủ cũng vậy (khi thức dậy màn hình thường bị khoá).
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.suspend("khoá màn hình")
        }
        dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.resume("mở khoá")
        }
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.appActivatedAt = Self.now
            LiveInput.shared.keep(for: Self.activationWindow + 0.5)   // xem `userInput(since:)`
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            wnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                self?.suspend(n.name.rawValue)
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            wnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                self?.resume(n.name.rawValue)
            }
        }
    }

    private func suspend(_ reason: String) {
        DebugLog.write("tạm dừng theo dõi (\(reason)), gtvInUse=\(gtvInUse), hiện tại=\(InputSources.currentID ?? "-")")
        suspended = true
        pendingLeaveGTV?.cancel()
        pendingLeaveGTV = nil
    }

    /// Thức dậy / mở khoá. Thông báo "mở khoá" có thể đến trước khi hệ thống kịp tắt cờ "màn hình
    /// khoá" (thấy khi gập máy rồi mở lại), nên nếu còn khoá thì kiểm tra lại mỗi 0,5 giây, tối đa
    /// 2 phút (đủ thời gian nhập mật khẩu).
    private func resume(_ reason: String) {
        let locked = Self.isScreenLocked
        DebugLog.write("tiếp tục (\(reason)), màn hình khoá=\(locked), gtvInUse=\(gtvInUse), hiện tại=\(InputSources.currentID ?? "-")")
        if locked {
            let startPolling = unlockDeadline == nil
            unlockDeadline = Date().addingTimeInterval(120)
            if startPolling { pollUnlock() }
            return
        }
        unlockDeadline = nil
        unlocked()
    }

    private func pollUnlock() {
        guard let deadline = unlockDeadline else { return }
        if !Self.isScreenLocked {
            unlockDeadline = nil
            DebugLog.write("màn hình đã hết khoá")
            unlocked()
        } else if Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.pollUnlock() }
        } else {
            unlockDeadline = nil
        }
    }

    private func unlocked() {
        suspended = false
        for delay in [0.0, 0.5, 1.0, 2.0, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.restoreGTV() }
        }
    }

    private func restoreGTV() {
        guard gtvInUse, !suspended, !Self.isScreenLocked, !InputSources.isGTVSelected else { return }
        DebugLog.write("khôi phục GTV (\(vietnamese ? "vi" : "en")), đang ở \(InputSources.currentID ?? "-")")
        select(vietnamese ? InputSources.vietnameseID : InputSources.englishID)
    }

    private static var isScreenLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }


    private func systemInputSourceChanged() {
        // Phím gõ ở bộ gõ khác / phím đổi bộ gõ không tới GTV: đặt lại sổ phím — trừ khi đây chỉ là lần GTV tự chọn lại chế độ
        // của nó (không có phím nào đi vòng; đặt lại sẽ quên phím đi vòng vừa thấy, vd. ⌫ ở Terminal.app).
        let own = InputSources.currentID.map(ownSelection) ?? false
        if !own { KeyWatch.shared.rebase() }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? clientBundleID
        DebugLog.write("bộ gõ đổi -> \(InputSources.currentID ?? "-"), front=\(front), tạm dừng=\(suspended)")
        let wasGTV = lastSourceIsGTV
        lastSourceIsGTV = InputSources.isGTVSelected
        if wasGTV && !lastSourceIsGTV {
            leftGTVBySystem = suspended || front == "com.apple.loginwindow" || Self.isScreenLocked
                || IsSecureEventInputEnabled() || appSwitchedBySystem
            DebugLog.write("rời GTV: \(leftGTVBySystem ? "do hệ thống" : "người dùng chọn bộ gõ khác")")
        }
        if !suspended && front != "com.apple.loginwindow" && !Self.isScreenLocked {
            pendingLeaveGTV?.cancel()
            pendingLeaveGTV = nil
            if InputSources.isGTVSelected {
                gtvInUse = true
            } else if gtvInUse {
                // Người dùng tự chọn bộ gõ khác? Chỉ tin sau 3 giây không có khoá/ngủ.
                let work = DispatchWorkItem { [weak self] in
                    guard let self, !self.suspended, !InputSources.isGTVSelected else { return }
                    self.gtvInUse = false
                    DebugLog.write("ghi nhận: người dùng đã rời GTV")
                }
                pendingLeaveGTV = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
            }
        }
        guard InputSources.isGTVSelected, let id = InputSources.currentID else { return }
        guard id == InputSources.vietnameseID || id == InputSources.englishID else {
            syncSystemMode()   // bộ gõ "cha" được chọn: chọn lại chế độ
            return
        }
        if own {
            ownSelectionArrived(id, from: "thông báo đổi bộ gõ")
            return
        }
        if id == InputSources.vietnameseID && isExcluded(currentApp(front: front)) {
            if wantsVietnameseHere { restoreVietnamese = true }
            vietnamese = false
            syncSystemMode()
            return
        }
        adopt(id == InputSources.vietnameseID, from: "thông báo đổi bộ gõ", returning: !wasGTV)
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Người dùng có bấm phím (kể cả phím bổ trợ, 🌐/fn) hay click chuột sau thời điểm `t` không. Chọn chế độ bằng
    /// menu bộ gõ, ⌃Space, 🌐… luôn có thao tác như vậy; macOS / ứng dụng tự chọn lại khi kích hoạt thì không.
    /// - Bộ gõ nhận phím sau đó; phím bổ trợ, phím đặc biệt, nút chuột đọc liên tục từ lúc kích hoạt (`LiveInput`, cập nhật
    ///   ngay trên mọi phiên bản macOS).
    /// - macOS 26: thêm thời điểm sự kiện của WindowServer. macOS 27 chỉ công bố chúng mỗi 0,5 s, làm tròn xuống — sự kiện
    ///   vừa xảy ra trông như chưa xảy ra: không dùng được.
    /// Phím bộ gõ đã nhận không bao giờ là thao tác đổi bộ gõ (⌃Space, 🌐 do hệ thống giữ lại): không tính — một lời báo đổi
    /// chế độ của hệ thống tới sau phím đầu tiên (gõ ngay khi ô vừa hiện) không được coi là người dùng chọn.
    private static func userInput(since t: TimeInterval) -> Bool {
        let live = LiveInput.shared
        live.sample()
        let log = live.log
        let end = now
        if log.history.contains(where: { $0.key == nil && $0.at >= t }) { return true }      // click
        if log.pending.contains(where: { $0.key != nil && $0.at >= t }) { return true }      // phím đặc biệt đi vòng bộ gõ
        if log.flagsPressed(from: t, to: end) { return true }                                 // ⌃ ⌥ ⌘ fn, caps lock
        guard KeyWatch.shared.counterMode == .exact else { return false }
        let age = end - t
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        return types.contains { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) < age }
    }

    /// Ứng dụng đang nhận phím: ô được gắn gần nhất nếu lần gắn đó mới hơn lần đổi ứng dụng (bảng kiểu Spotlight / Raycast /
    /// Alfred không làm đổi ứng dụng phía trước), không thì ứng dụng phía trước.
    private func currentApp(front: String) -> String {
        !clientBundleID.isEmpty && activatedAt >= appActivatedAt ? clientBundleID : front
    }

    /// Chọn chế độ của GTV (ghi lại để thông báo đổi bộ gõ do chính lần chọn này gây ra không bị coi là người dùng đổi).
    private func select(_ id: String) {
        let now = Self.now
        selfSelected.removeAll { now - $0.at >= 1 }
        selfSelected.append((id, now))
        LiveInput.shared.keep(for: 1.5)                       // xem `ownSelection`
        InputSources.selectMode(id)
    }

    /// Hệ thống báo chế độ `id` mà chính GTV vừa chọn (`select`, trong 1 giây — thường tới 2 lần: setValue và thông báo
    /// đổi bộ gõ), và người dùng không thao tác gì từ lần chọn đó. Có thao tác (⌃Space, 🌐, menu bộ gõ — kể cả chọn lại đúng
    /// chế độ GTV vừa chọn sau khi đã đổi sang chế độ kia) thì đây là lựa chọn của người dùng.
    private func ownSelection(_ id: String) -> Bool {
        let now = Self.now
        guard let own = selfSelected.last(where: { $0.id == id && now - $0.at < 1 }) else { return false }
        return !Self.userInput(since: own.at)
    }

    /// Lời báo cho lần GTV tự chọn không bao giờ là người dùng chọn. Lúc GTV chọn, chế độ đó khớp với GTV; nếu giờ đã
    /// khác thì người dùng vừa chọn chế độ kia ngay trong lúc đó (vd. từ ABC chọn "Tiếng Việt (GTV)": macOS gắn GTV vào ô
    /// — GTV chọn lại chế độ cũ — rồi mới báo chế độ người dùng chọn; lời báo cho lần GTV chọn tới sau cùng, lab
    /// 42055281996): giữ lựa chọn của người dùng, chọn lại cho khớp.
    private func ownSelectionArrived(_ id: String, from source: String) {
        guard (id == InputSources.vietnameseID) != vietnamese else { return }
        DebugLog.write("giữ chế độ \(vietnamese ? "vi" : "en"): \(id == InputSources.vietnameseID ? "vi" : "en") là lần GTV tự chọn (\(source))")
        syncSystemMode()
    }

    /// Ở ứng dụng loại trừ, hệ thống báo chế độ tiếng Việt: chỉ nhớ để khôi phục tiếng Việt khi rời ứng dụng nếu người dùng
    /// đang ở tiếng Việt hoặc tự chọn nó — ứng dụng / macOS tự chọn lại tiếng Việt (nhớ theo ứng dụng) không được biến chế độ
    /// tiếng Anh của người dùng thành tiếng Việt.
    private var wantsVietnameseHere: Bool {
        vietnamese || Self.userInput(since: max(activatedAt, appActivatedAt))
    }

    /// Vừa đổi ứng dụng mà người dùng chưa thao tác gì sau đó.
    private var appSwitchedBySystem: Bool {
        Self.now - appActivatedAt < Self.activationWindow && !Self.userInput(since: appActivatedAt)
    }

    /// GTV vừa được gắn vào ô nhập liệu (hoặc vừa đổi ứng dụng) và người dùng chưa thao tác gì sau đó.
    private var activatedBySystem: Bool {
        if Self.now - activatedAt < Self.activationWindow && !Self.userInput(since: activatedAt) { return true }
        return appSwitchedBySystem
    }

    /// Hệ thống báo đang ở chế độ `on`. Theo nếu do người dùng đổi (menu bộ gõ, ⌃Space, 🌐, công cụ chọn bộ gõ);
    /// chọn lại chế độ của GTV nếu do hệ thống chọn — giữ chế độ cố định:
    /// - quay lại GTV sau khi hệ thống chuyển sang bộ gõ khác (ô mật khẩu, khoá màn hình) hoặc do đổi ứng dụng;
    /// - ngay sau khi đổi ứng dụng / ô nhập liệu mà người dùng chưa thao tác gì;
    /// - ứng dụng chọn lại chế độ vừa bị bỏ qua (người dùng chưa thao tác gì từ lúc đó).
    private func adopt(_ on: Bool, from source: String, returning: Bool) {
        guard on != vietnamese else {
            // Người dùng tự chọn lại GTV ở đúng chế độ đang có (vd. "English (GTV)" khi đang chờ khôi phục tiếng Việt sau ứng
            // dụng loại trừ): lựa chọn đó thắng, không khôi phục đè nữa.
            if returning, !leftGTVBySystem, !appSwitchedBySystem {
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? clientBundleID
                if !isExcluded(currentApp(front: front)) { restoreVietnamese = false }
            }
            return
        }
        var reason: String?
        if let r = rejected, r.on == on, Self.now - r.at < 2, !Self.userInput(since: r.at) {
            // Cùng một lần đổi được báo nhiều lần (thông báo + setValue), hoặc ứng dụng chọn lại.
            reason = "chọn lại chế độ vừa bỏ qua"
        } else if returning {
            if leftGTVBySystem {
                reason = "quay lại sau khi hệ thống chuyển sang bộ gõ khác"
            } else if appSwitchedBySystem {
                reason = "quay lại do đổi ứng dụng"
            }
        } else if activatedBySystem {
            reason = "vừa gắn vào \(clientBundleID)"
        }
        if let reason {
            DebugLog.write("giữ chế độ \(vietnamese ? "vi" : "en"): bỏ qua \(on ? "vi" : "en") do hệ thống chọn (\(source), \(reason))")
            rejected = (on, Self.now)
            LiveInput.shared.keep(for: 2.5)                       // xem `userInput(since:)`
            syncSystemMode()
            return
        }
        DebugLog.write("chế độ -> \(on ? "vi" : "en") (\(source)\(returning ? ", người dùng chọn lại GTV" : ""))")
        rejected = nil
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? clientBundleID
        if !isExcluded(currentApp(front: front)) { restoreVietnamese = false }   // người dùng đã chọn: không khôi phục đè lên
        set(on, updateSystem: false)
    }

    private func isExcluded(_ bundleID: String) -> Bool {
        Settings.shared.excludedApps.contains(bundleID)
    }

    /// GTV được gắn vào một ô nhập liệu.
    func clientActivated(_ client: Client, bundleID: String) {
        self.client = client
        clientBundleID = bundleID
        activatedAt = Self.now
        LiveInput.shared.keep(for: Self.activationWindow + 0.5)   // xem `userInput(since:)`
        if isExcluded(bundleID) {
            if vietnamese {
                restoreVietnamese = true
                set(false)
            }
        } else if restoreVietnamese {
            restoreVietnamese = false
            // Người dùng tự rời GTV rồi tự chọn lại một chế độ của nó ở ứng dụng này: lựa chọn đó quyết định (`adopt`), không
            // khôi phục đè.
            if lastSourceIsGTV || leftGTVBySystem { set(true) }
        }
        // Vừa chọn lại GTV từ bộ gõ khác: chế độ người dùng (hoặc hệ thống) chọn tới ngay sau (setValue, thông báo đổi bộ
        // gõ) và `adopt` quyết định theo hay giữ; chọn lại chế độ cũ ngay ở đây sẽ đè lên lựa chọn của người dùng. Bộ gõ "cha"
        // được chọn (không chế độ nào) thì luôn chọn lại.
        let current = InputSources.currentID
        let parentSelected = InputSources.isGTVSelected
            && current != InputSources.vietnameseID && current != InputSources.englishID
        if lastSourceIsGTV || parentSelected { syncSystemMode() }
    }

    /// Khi chuyển ứng dụng, macOS có lúc chọn bộ gõ GTV "cha" thay vì một chế độ (biểu tượng không
    /// còn cho biết V hay E), hoặc chọn chế độ khác với trạng thái của GTV: chọn lại cho khớp.
    /// Chạy sau, ngoài lúc macOS đang báo sự kiện cho bộ gõ.
    private func syncSystemMode() {
        DispatchQueue.main.async { [self] in
            let mode = vietnamese ? InputSources.vietnameseID : InputSources.englishID
            if InputSources.isGTVSelected && InputSources.currentID != mode {
                select(mode)
            }
        }
    }

    /// macOS báo đổi chế độ (menu bộ gõ, phím 🌐, Ctrl+Space, hoặc do chính GTV gọi `selectMode`).
    func modeSelected(_ modeID: String) {
        if ownSelection(modeID) {
            ownSelectionArrived(modeID, from: "setValue")
            return
        }
        let on = modeID != InputSources.englishID
        if on && isExcluded(clientBundleID) {
            // Ứng dụng loại trừ không gõ tiếng Việt: trả về tiếng Anh.
            if wantsVietnameseHere { restoreVietnamese = true }
            vietnamese = false
            syncSystemMode()
            return
        }
        adopt(on, from: "setValue", returning: !lastSourceIsGTV)
    }

    /// Người dùng chuyển Anh/Việt (phím tắt, menu).
    func toggle() {
        if !InputSources.isGTVSelected {
            // Menu biểu tượng V/E khi đang ở bộ gõ khác: mục "Gõ tiếng Việt" đang không tích, bấm vào là muốn gõ
            // tiếng Việt — chọn GTV ở chế độ tiếng Việt, không đổi ngầm chế độ đã nhớ.
            DebugLog.write("toggle khi đang ở \(InputSources.currentID ?? "-"): chọn GTV tiếng Việt")
            restoreVietnamese = false
            set(true, updateSystem: false)
            InputSources.selectMode(InputSources.vietnameseID)
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? clientBundleID
        let app = currentApp(front: front)
        if !vietnamese && isExcluded(app) { return }
        if !isExcluded(app) { restoreVietnamese = false }
        if Settings.shared.playSwitchSound { NSSound.beep() }
        DebugLog.write("toggle -> \(vietnamese ? "en" : "vi")")
        set(!vietnamese)
    }

    /// Kiểm tra lại sau một lúc: nếu hệ thống vẫn chưa ở đúng chế độ thì chọn lại.
    private func verifySystemMode(retries: Int, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            let mode = vietnamese ? InputSources.vietnameseID : InputSources.englishID
            guard InputSources.isGTVSelected, InputSources.currentID != mode else {
                DebugLog.write("kiểm tra sau \(delay)s: khớp (\(InputSources.currentID ?? "-"))")
                return
            }
            DebugLog.write("kiểm tra sau \(delay)s: CHƯA khớp (\(InputSources.currentID ?? "-")), chọn lại \(mode)")
            select(mode)
            if retries > 0 { verifySystemMode(retries: retries - 1, delay: 0.3) }
        }
    }

    /// Người dùng thêm/bỏ ứng dụng khỏi danh sách loại trừ.
    private func exclusionChanged() {
        guard !clientBundleID.isEmpty else { return }
        if isExcluded(clientBundleID) {
            if vietnamese {
                restoreVietnamese = true
                set(false)
            }
        } else if !vietnamese {
            // Vừa bỏ loại trừ ứng dụng đang dùng: người dùng muốn gõ tiếng Việt ở đây.
            restoreVietnamese = false
            set(true)
        }
    }

    private func set(_ on: Bool, updateSystem: Bool = true) {
        guard on != vietnamese else { return }
        vietnamese = on
        // Lưu chế độ người dùng muốn: chế độ tiếng Anh tạm thời ở ứng dụng loại trừ không tính.
        UserDefaults.standard.set(on || restoreVietnamese, forKey: "vietnameseMode")
        if updateSystem {
            syncSystemMode()
            verifySystemMode(retries: 1, delay: 0.3)
        }
        NotificationCenter.default.post(name: .gtvSettingsChanged, object: nil)
    }
}
