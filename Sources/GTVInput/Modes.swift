import AppKit
import Carbon
import InputMethodKit

/// Chế độ Tiếng Việt / Tiếng Anh của GTV.
///
/// Đây là 2 input mode của cùng bộ gõ GTV ("<id>.vi", "<id>.en"). Chuyển chế độ bằng cách chọn input mode đó
/// (`InputSources.selectMode`, TISSelectInputSource): bộ gõ không bị gỡ ra hay gắn lại, nên chuyển tức thì, không nháy
/// cửa sổ, và ⌘⇧ luôn do bộ gõ bắt được.
///
/// Ứng dụng loại trừ: khi GTV được gắn vào ô nhập liệu của ứng dụng trong danh sách thì chuyển sang
/// tiếng Anh; khi sang ứng dụng khác thì khôi phục tiếng Việt nếu trước đó đang gõ tiếng Việt.
final class Modes {
    static let shared = Modes()

    private(set) var vietnamese: Bool
    /// Đang ở ứng dụng loại trừ và trước đó đang gõ tiếng Việt.
    private var restoreVietnamese = false
    private var clientBundleID = ""
    /// Ứng dụng của ô đang gắn có nằm trong danh sách loại trừ không, theo lần xét gần nhất (xem `exclusionChanged`).
    private var clientExcluded = false
    /// Đã nhận thông báo đổi bộ gõ nào từ lúc tiến trình khởi động chưa. Chưa thì `lastSourceIsGTV` = false chỉ là "chưa
    /// biết", không phải "người dùng đang ở bộ gõ khác".
    private var sourceNotified = false
    /// Từ lúc tạm dừng (khoá / ngủ) đã thấy màn hình khoá hiện chưa (xem `pollUnlock`).
    private var lockSeen = false
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
    /// Ô vừa gắn chưa báo chế độ lần nào. InputMethodKit báo chế độ của ô (setValue) ngay sau mỗi lần gắn; lời báo đầu tiên đó
    /// là của hệ thống (chế độ nó nhớ cho ô / cửa sổ ấy), không phải người dùng chọn — kể cả khi ứng dụng bận và nó tới muộn
    /// hơn `activationWindow` (ứng dụng Java nặng như Burp Suite: cả giây).
    private var awaitingFirstReport = false
    /// Quá bấy nhiêu giây sau lần gắn mà chưa có lời báo nào thì thôi chờ.
    private static let firstReportWindow: TimeInterval = 5

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
            self?.sourceChangeNotified()
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

    /// Hạn tự dò màn hình khoá sau mỗi lần tạm dừng.
    private static let lockWatch: TimeInterval = 12 * 3600

    private func suspend(_ reason: String) {
        DebugLog.event("tạm dừng theo dõi (\(reason)), gtvInUse=\(gtvInUse), hiện tại=\(InputSources.currentID ?? "-")")
        suspended = true
        pendingLeaveGTV?.cancel()
        pendingLeaveGTV = nil
        // Không trông vào thông báo mở khoá / thức dậy (máy macOS 27 của người dùng có lúc không nhận được): từ đây tự dò —
        // thấy màn hình khoá hiện rồi hết thì coi là đã mở khoá. Chưa từng thấy khoá (chỉ tắt màn hình) thì chờ thông báo.
        watchLock(seen: Self.lockScreenShowing)
    }

    /// Thức dậy / mở khoá. Thông báo "mở khoá" có thể đến trước khi hệ thống kịp tắt cờ "màn hình khoá" (thấy khi gập máy
    /// rồi mở lại), nên nếu còn khoá thì dò tiếp mỗi 0,5 giây tới khi hết khoá (không giới hạn 2 phút như trước: để màn hình
    /// khoá hiện lâu hơn rồi mới nhập mật khẩu thì GTV kẹt ở trạng thái tạm dừng, mở khoá xong vẫn ở ABC).
    private func resume(_ reason: String) {
        let locked = Self.lockScreenShowing
        DebugLog.event("tiếp tục (\(reason)), màn hình khoá=\(locked), gtvInUse=\(gtvInUse), hiện tại=\(InputSources.currentID ?? "-")")
        if locked {
            watchLock(seen: true)
            return
        }
        unlockDeadline = nil
        lockSeen = false
        unlocked()
    }

    /// Dò màn hình khoá mỗi 0,5 giây (tối đa `lockWatch`), khôi phục GTV khi nó đã hiện rồi hết. `seen`: đang thấy nó hiện.
    private func watchLock(seen: Bool) {
        if seen { lockSeen = true }
        let startPolling = unlockDeadline == nil
        unlockDeadline = Date().addingTimeInterval(Self.lockWatch)
        if startPolling { pollUnlock() }
    }

    private func pollUnlock() {
        guard let deadline = unlockDeadline else { return }
        let showing = Self.lockScreenShowing
        if showing { lockSeen = true }
        if lockSeen, !showing {
            unlockDeadline = nil
            lockSeen = false
            DebugLog.event("màn hình đã hết khoá")
            unlocked()
        } else if suspended, Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.pollUnlock() }
        } else {
            unlockDeadline = nil
            lockSeen = false
        }
    }

    private func unlocked() {
        suspended = false
        for delay in [0.0, 0.5, 1.0, 2.0, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.restoreGTV() }
        }
    }

    private func restoreGTV() {
        guard gtvInUse, !suspended, !Self.lockScreenShowing, !InputSources.isGTVSelected else { return }
        DebugLog.event("khôi phục GTV (\(vietnamese ? "vi" : "en")), đang ở \(InputSources.currentID ?? "-")")
        select(vietnamese ? InputSources.vietnameseID : InputSources.englishID)
    }

    private static var isScreenLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Màn hình khoá đang hiện: cờ của phiên, hoặc cửa sổ đăng nhập đang ở trước (cờ có lúc tắt / bật lệch với màn hình thật).
    private static var lockScreenShowing: Bool {
        isScreenLocked || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow"
    }


    /// Lần xử lý thông báo đổi bộ gõ đang hẹn (xem `sourceChangeNotified`).
    private var sourceCheck: DispatchWorkItem?
    /// Chờ bấy nhiêu giây sau thông báo đổi bộ gõ rồi mới đọc bộ gõ hiện tại.
    private static let sourceSettle: TimeInterval = 0.08

    /// Thông báo đổi bộ gõ của hệ thống. Không đọc bộ gõ hiện tại ngay trong lúc nhận: khi bộ gõ do tiến trình khác chọn (menu bộ
    /// gõ, ⌃Space, công cụ chọn bộ gõ), lần đọc ngay lúc đó có lúc còn ra bộ gõ CŨ — IME Lab 44072909915: ô báo `setValue .en`,
    /// 10 ms sau thông báo tới mà đọc ra `.vi`, GTV coi đó là người dùng chọn lại tiếng Việt (hệ thống thì ở tiếng Anh; lệch
    /// tới lần đổi ứng dụng kế tiếp thì chế độ "tự nhảy"). Một lần đổi cũng thường báo nhiều lần. Nên chờ một nhịp rồi xử lý
    /// một lần, theo trạng thái đã yên.
    private func sourceChangeNotified() {
        sourceCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.sourceCheck = nil
            self?.systemInputSourceChanged()
        }
        sourceCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sourceSettle, execute: work)
    }

    private func systemInputSourceChanged() {
        // Phím gõ ở bộ gõ khác / phím đổi bộ gõ không tới GTV: đặt lại sổ phím — trừ khi đây chỉ là lần GTV tự chọn lại chế độ
        // của nó (không có phím nào đi vòng; đặt lại sẽ quên phím đi vòng vừa thấy, vd. ⌫ ở Terminal.app).
        let own = InputSources.currentID.map(ownSelection) ?? false
        if !own { KeyWatch.shared.rebase() }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? clientBundleID
        DebugLog.event("bộ gõ đổi -> \(InputSources.currentID ?? "-"), front=\(front), tạm dừng=\(suspended)")
        let wasGTV = lastSourceIsGTV
        lastSourceIsGTV = InputSources.isGTVSelected
        sourceNotified = true
        if !suspended, !lastSourceIsGTV, front == "com.apple.loginwindow" || Self.isScreenLocked {
            // Màn hình khoá đã chuyển sang ABC mà thông báo khoá chưa tới — hoặc không bao giờ tới (máy macOS 27 của người dùng:
            // mở khoá xong máy ở lại ABC). Tự coi là đang khoá và tự chờ mở khoá (tối đa 12 giờ), không trông vào thông báo.
            suspend("màn hình khoá, chưa có thông báo")
            watchLock(seen: true)
        }
        if wasGTV && !lastSourceIsGTV {
            leftGTVBySystem = suspended || front == "com.apple.loginwindow" || Self.isScreenLocked
                || IsSecureEventInputEnabled() || appSwitchedBySystem
            DebugLog.event("rời GTV: \(leftGTVBySystem ? "do hệ thống" : "người dùng chọn bộ gõ khác")")
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
                    if Self.lockScreenShowing {
                        // Lần đổi sang ABC tới trước khi màn hình kịp báo khoá, và thông báo khoá không tới: không phải người
                        // dùng rời GTV.
                        self.suspend("màn hình khoá sau khi rời GTV, chưa có thông báo")
                        self.watchLock(seen: true)
                        return
                    }
                    self.gtvInUse = false
                    DebugLog.event("ghi nhận: người dùng đã rời GTV")
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

    /// Người dùng có làm thao tác CHỌN BỘ GÕ sau thời điểm `t` không: bấm phím mà macOS dùng để đổi bộ gõ — ⌃ (⌃Space,
    /// ⌃⌥Space), 🌐 / fn, Caps Lock — hoặc (`clicks`) click chuột (menu bộ gõ). macOS / ứng dụng tự chọn lại chế độ khi kích
    /// hoạt thì không có thao tác nào như vậy.
    ///
    /// Phím khác không tính: ⌘ ⌥ ⇧, Tab, ⌫, mũi tên, ⏎ là thứ người dùng bấm suốt quanh lúc đổi ứng dụng (⌘Tab, ⌘V, ⌥⌫,
    /// chữ hoa…) mà không hề chọn bộ gõ — bản trước tính cả chúng, nên chế độ hệ thống tự chọn lại cho ứng dụng vừa kích hoạt
    /// bị coi là người dùng chọn: gõ ra số / chữ không dấu cho tới lần đổi ứng dụng sau. Click ngay sau khi kích hoạt (bấm
    /// vào ô, bấm đúp đổi tên tab) cũng vậy: chỉ tính ở chỗ không phải vừa kích hoạt (`clicks`).
    ///
    /// Đọc liên tục từ lúc kích hoạt (`LiveInput`, cập nhật ngay trên mọi phiên bản macOS). Thời điểm sự kiện của
    /// WindowServer chỉ dùng trên macOS 26: macOS 27 công bố chúng mỗi 0,5 s, làm tròn xuống — sự kiện vừa xảy ra trông như
    /// chưa xảy ra.
    private static func userInput(since t: TimeInterval, clicks: Bool = true) -> Bool {
        let live = LiveInput.shared
        live.sample()
        let log = live.log
        let end = now
        if log.sourceKeyPressed(from: t, to: end) { return true }                             // ⌃, fn / 🌐, caps lock
        guard clicks else { return false }
        if log.history.contains(where: { $0.key == nil && $0.at >= t }) { return true }      // click
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
        DebugLog.event("giữ chế độ \(vietnamese ? "vi" : "en"): \(id == InputSources.vietnameseID ? "vi" : "en") là lần GTV tự chọn (\(source))")
        syncSystemMode()
    }

    /// Ở ứng dụng loại trừ, hệ thống báo chế độ tiếng Việt: chỉ nhớ để khôi phục tiếng Việt khi rời ứng dụng nếu người dùng
    /// đang ở tiếng Việt hoặc tự chọn nó — ứng dụng / macOS tự chọn lại tiếng Việt (nhớ theo ứng dụng) không được biến chế độ
    /// tiếng Anh của người dùng thành tiếng Việt.
    private var wantsVietnameseHere: Bool {
        vietnamese || Self.userInput(since: max(activatedAt, appActivatedAt), clicks: false)
    }

    /// Vừa đổi ứng dụng mà người dùng chưa thao tác gì sau đó.
    private var appSwitchedBySystem: Bool {
        Self.now - appActivatedAt < Self.activationWindow && !Self.userInput(since: appActivatedAt, clicks: false)
    }

    /// GTV vừa được gắn vào ô nhập liệu (hoặc vừa đổi ứng dụng) và người dùng chưa thao tác gì sau đó.
    private var activatedBySystem: Bool {
        if Self.now - activatedAt < Self.activationWindow && !Self.userInput(since: activatedAt, clicks: false) { return true }
        return appSwitchedBySystem
    }

    /// Hệ thống báo đang ở chế độ `on`. Theo nếu do người dùng đổi (menu bộ gõ, ⌃Space, 🌐, công cụ chọn bộ gõ);
    /// chọn lại chế độ của GTV nếu do hệ thống chọn — giữ chế độ cố định:
    /// - quay lại GTV sau khi hệ thống chuyển sang bộ gõ khác (ô mật khẩu, khoá màn hình) hoặc do đổi ứng dụng;
    /// - ngay sau khi đổi ứng dụng / ô nhập liệu mà người dùng chưa thao tác gì;
    /// - ứng dụng chọn lại chế độ vừa bị bỏ qua (người dùng chưa thao tác gì từ lúc đó).
    private func adopt(_ on: Bool, from source: String, returning: Bool, firstReport: Bool = false) {
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
        } else if firstReport, !Self.userInput(since: activatedAt, clicks: false) {
            reason = "lời báo đầu tiên của ô vừa gắn (\(clientBundleID), muộn \(String(format: "%.2f", Self.now - activatedAt)) s)"
        }
        if let reason {
            DebugLog.event("giữ chế độ \(vietnamese ? "vi" : "en"): bỏ qua \(on ? "vi" : "en") do hệ thống chọn (\(source), \(reason))")
            rejected = (on, Self.now)
            LiveInput.shared.keep(for: 2.5)                       // xem `userInput(since:)`
            syncSystemMode()
            return
        }
        DebugLog.event("chế độ -> \(on ? "vi" : "en") (\(source)\(returning ? ", người dùng chọn lại GTV" : ""))")
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
        clientBundleID = bundleID
        activatedAt = Self.now
        awaitingFirstReport = true
        LiveInput.shared.keep(for: Self.activationWindow + 0.5)   // xem `userInput(since:)`
        clientExcluded = isExcluded(bundleID)
        if clientExcluded {
            if vietnamese {
                restoreVietnamese = true
                set(false)
            }
        } else if restoreVietnamese {
            restoreVietnamese = false
            // Người dùng tự rời GTV rồi tự chọn lại một chế độ của nó ở ứng dụng này: lựa chọn đó quyết định (`adopt`), không
            // khôi phục đè. Chưa có thông báo đổi bộ gõ nào từ lúc khởi động (bộ gõ khởi động lại — cập nhật — khi đang ở ứng
            // dụng loại trừ, hệ thống vẫn ở English (GTV) suốt) thì không phải trường hợp đó: khôi phục tiếng Việt, không thì
            // kẹt tiếng Anh ở mọi ứng dụng.
            if lastSourceIsGTV || leftGTVBySystem || !sourceNotified { set(true) }
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
        let firstReport = awaitingFirstReport && Self.now - activatedAt < Self.firstReportWindow
        awaitingFirstReport = false
        if ownSelection(modeID) {
            ownSelectionArrived(modeID, from: "setValue")
            return
        }
        let on = modeID != InputSources.englishID
        // Ứng dụng đang nhận phím (như đường thông báo đổi bộ gõ), không nhất thiết là ứng dụng của ô gắn gần nhất.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? clientBundleID
        if on && isExcluded(currentApp(front: front)) {
            // Ứng dụng loại trừ không gõ tiếng Việt: trả về tiếng Anh.
            if wantsVietnameseHere { restoreVietnamese = true }
            vietnamese = false
            syncSystemMode()
            return
        }
        adopt(on, from: "setValue", returning: !lastSourceIsGTV, firstReport: firstReport)
    }

    /// Người dùng chuyển Anh/Việt (phím tắt, menu).
    func toggle() {
        if !InputSources.isGTVSelected {
            // Menu biểu tượng V/E khi đang ở bộ gõ khác: mục "Gõ tiếng Việt" đang không tích, bấm vào là muốn gõ
            // tiếng Việt — chọn GTV ở chế độ tiếng Việt, không đổi ngầm chế độ đã nhớ.
            DebugLog.event("toggle khi đang ở \(InputSources.currentID ?? "-"): chọn GTV tiếng Việt")
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
        DebugLog.event("toggle -> \(vietnamese ? "en" : "vi")")
        set(!vietnamese)
    }

    /// Kiểm tra lại sau một lúc: nếu hệ thống vẫn chưa ở đúng chế độ thì chọn lại.
    private func verifySystemMode(retries: Int, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            let mode = vietnamese ? InputSources.vietnameseID : InputSources.englishID
            guard InputSources.isGTVSelected, InputSources.currentID != mode else {
                DebugLog.event("kiểm tra sau \(delay)s: khớp (\(InputSources.currentID ?? "-"))")
                return
            }
            DebugLog.event("kiểm tra sau \(delay)s: CHƯA khớp (\(InputSources.currentID ?? "-")), chọn lại \(mode)")
            select(mode)
            if retries > 0 { verifySystemMode(retries: retries - 1, delay: 0.3) }
        }
    }

    /// Người dùng thêm/bỏ ứng dụng khỏi danh sách loại trừ.
    private func exclusionChanged() {
        guard !clientBundleID.isEmpty else { return }
        let was = clientExcluded
        clientExcluded = isExcluded(clientBundleID)
        if clientExcluded {
            if vietnamese {
                restoreVietnamese = true
                set(false)
            }
        } else if was, !vietnamese {
            // Vừa bỏ loại trừ chính ứng dụng đang dùng: người dùng muốn gõ tiếng Việt ở đây. (Thêm / bỏ ứng dụng KHÁC khi
            // đang tự chọn tiếng Anh ở ứng dụng này thì không đụng tới chế độ.)
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
