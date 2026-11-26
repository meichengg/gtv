# Nhật ký thay đổi

Mỗi phiên bản là một mục `## <phiên bản> — <ngày>`. Nội dung của mục được dùng nguyên văn làm release
note trên trang GitHub Releases (workflow `Release`). Phiên bản phải khớp `MARKETING_VERSION` trong
`project.yml`.

## 1.14 — 2026-11-26

### Thay đổi
- **Bộ gõ InputMethodKit thuần — bỏ hẳn phím ⌫ giả.** Từ 1.13, ở Java / Qt 5 / GTK / winit / LibreOffice và các ô tự vẽ, GTV
  để phím đi thẳng rồi gửi phím ⌫ + chữ mới bằng `CGEventPost` (cần quyền Trợ năng). Cách đó phải đoán thứ tự giữa phím thật và
  phím giả; đoán sai là hoãn mãi lần sửa — `d9a38ng` ra nguyên văn (Burp Suite). Nay GTV không gửi một sự kiện phím nào: mọi
  chữ tới ứng dụng qua đúng giao tiếp của bộ gõ (`insertText`, `setMarkedText`). Không còn mục xin quyền Trợ năng trong menu;
  quyền đã cấp cho GTV có thể gỡ (Cài đặt hệ thống → Quyền riêng tư & Bảo mật → Trợ năng).
- Các ứng dụng đó (Java chạy JDK gốc như Burp Suite / Ghidra khi chưa nạp trợ thủ Java — xem dưới —, Qt 5, GTK, winit, LibreOffice, Emacs, MacVim, ô tự vẽ không cho
  biết con trỏ) trở lại cách của 1.12: soạn từ đang gõ bằng marked text của InputMethodKit — cách duy nhất các bộ công cụ
  này cho bộ gõ sửa chữ đã gõ. Trong lúc gõ một từ, ứng dụng tự vẽ gạch chân cho phần đang soạn (bộ gõ không tắt được: macOS
  chuyển phần đang soạn cho ô kèm kiểu tô sáng của hệ thống, không phải thuộc tính bộ gõ đưa — đo ở IME Lab).
- **Java chạy JDK gốc: gõ thẳng qua trợ thủ Java.** Soạn từng từ trong Burp Suite rất khó chịu: ô đổi tên tab gạch chân từ
  đang soạn, ô soạn request để con trỏ ở đầu từ, và AWT bỏ qua phím tắt / mũi tên / ⌥⌫ bấm ngay sau từ. GTV nay kèm
  `gtv-java-helper.jar` (mã nguồn: `JavaHelper/`): nạp nó vào máy ảo của ứng dụng bằng một dòng
  `-javaagent:/Users/<tên>/Library/GTV/gtv-java-helper.jar` trong tham số JVM (đường dẫn đầy đủ — Java không hiểu `~`; menu GTV
  chép sẵn đúng dòng này. Burp Suite: `user.vmoptions`; Ghidra: `VMARGS` trong `support/launch.properties`; cần Java 11 trở
  lên, máy ảo cũ hơn bỏ qua trợ thủ) thì AWT nhận vùng cần thay của bộ gõ như JetBrains Runtime — GTV thay chữ trực tiếp, không còn
  gì "đang soạn". Trợ thủ chỉ đọc vùng cần thay GTV ghi ở đầu chuỗi gửi, chọn đúng vùng đó trong ô văn bản rồi cho ô chèn
  chữ; chữ của bộ gõ khác đi qua nguyên vẹn. Trợ thủ cũng báo cho GTV ô nào đang giữ focus trong cửa sổ Java: sang ô khác
  thì GTV bắt đầu từ mới, và ở ô không nhận chữ (bảng, cây, nút, ô chỉ đọc) phím đi thẳng tới ứng dụng. Menu GTV có mục *Gõ thẳng trong … (Java)…* khi đang ở ứng dụng Java chưa có trợ
  thủ (chép sẵn dòng cấu hình). IME Lab (JDK 25, Swing): 21/21 bài, kể cả gõ cách nhau 3 ms, ⌥⌫ rồi gõ tiếp, mũi tên / ⌘A
  ngay sau từ, và đổi sang ô khác trong cùng cửa sổ — không một sự kiện soạn nào.
- Menu: *Dùng gạch chân cho …* / *Gạch chân khi gõ trong …* / *Luôn dùng gạch chân* đổi tên thành *Soạn từng từ trong …* /
  *Luôn soạn từng từ* (cài đặt cũ giữ nguyên).
- Java chạy JetBrains Runtime (IntelliJ, Android Studio, ứng dụng Compose Desktop…): gõ thẳng như ô thường, không soạn,
  không gạch chân — AWT của JetBrains Runtime chọn đúng vùng cần thay trước khi chèn (`CInputMethod.selectRange`). GTV nhận ra
  bằng tên hàm đó trong `libawt_lwawt.dylib` của bộ Java mà ứng dụng đang chạy.

### Lưu ý
- Lần ra lỗi chỉ gặp trên máy thật: `defaults write com.gtv.inputmethod.GTV trace -bool true` bật nhật ký sự kiện
  `~/Library/Logs/GTV-trace.log` (tối đa 1 MB) — gắn / rời ô, đường gõ của từng phím (chỉ ghi loại phím: chữ / số / cách…,
  không bao giờ ghi chữ đã gõ), mỗi lần đổi chế độ kèm lý do. Tắt: `defaults delete com.gtv.inputmethod.GTV trace`.
- Java chạy JDK gốc không có trợ thủ: đổi sang ô khác bằng chương trình (không click) trong lúc một từ còn đang soạn thì Java
  không báo cho bộ gõ — từ đó có thể bị chép sang ô mới.
- Gỡ GTV (`uninstall.sh`) không xoá `~/Library/GTV/gtv-java-helper.jar`: ứng dụng Java còn dòng `-javaagent` trỏ tới nó sẽ
  không khởi động được nếu file mất. Xoá dòng đó trước rồi mới xoá file.
- Ô tự vẽ không cho biết con trỏ mà GTV chưa biết (không còn phím ⌫ giả để sửa): từ đầu tiên sau khi ô nhận focus / sau
  click ra nguyên văn, các từ sau được soạn bằng marked text.
- Firefox / Zen không cho bộ gõ hỏi đồng bộ sang trang (Chromium thì được): sau ba phím xoá / phím tắt liền nhau mà con trỏ
  không đổi, từ đầu gõ lại có thể hiện nguyên văn một thoáng rồi mới thành chữ có dấu. Trang đang rất chậm mà bấm ⌘-phím tắt
  ngay sau phím dấu thì phím tắt đó có thể bị bỏ qua một lần.

### Sửa lỗi
- **Gõ ra số / chữ không dấu như đang ở tiếng Anh** sau ⌘Tab, ⌥⌫ hay lúc gõ nhanh, tới lần đổi ứng dụng kế tiếp mới hết
  (macOS 27, Burp Suite): máy đã thật sự nhảy sang English (GTV). Ngay sau khi bộ gõ được gắn vào một ô, macOS có thể chọn
  lại chế độ nó nhớ cho ô / cửa sổ đó; GTV giữ chế độ của mình trừ khi người dùng "có thao tác" — mà thao tác tính cả ⌘ ⌥ ⇧,
  Tab, ⌫, mũi tên và click, đúng những thứ người dùng bấm quanh lúc đổi ứng dụng. Nay chỉ phím macOS dùng để đổi bộ gõ mới
  tính (⌃ của ⌃Space, 🌐 / fn, Caps Lock); click chỉ tính ở chỗ không phải vừa kích hoạt. Lời báo chế độ đầu tiên sau mỗi lần
  gắn không bao giờ là người dùng chọn, kể cả khi ứng dụng bận và nó tới muộn hơn 0,6 s.
- Java chạy JetBrains Runtime: focus sang một ô trống khác trong cùng cửa sổ mà không click (bộ gõ không được gắn lại) thì từ
  đầu tiên ở ô mới ra nguyên văn (`d9a38ng`), các từ sau bị soạn từng từ — GTV tưởng ô không cho biết con trỏ. Ô Java gõ trực
  tiếp luôn báo đúng con trỏ: nay GTV đọc lại từ ở chỗ mới.
- Chế độ V/E có lúc lệch với biểu tượng rồi "tự nhảy" ở lần đổi ứng dụng kế tiếp, sau khi đổi chế độ bằng menu bộ gõ,
  ⌃Space / 🌐 hay công cụ chọn bộ gõ (không phải phím tắt ⌘⇧ của GTV): thông báo đổi bộ gõ của hệ thống có lúc tới khi GTV
  đọc bộ gõ hiện tại vẫn còn ra chế độ cũ, và GTV coi đó là người dùng vừa chọn lại chế độ cũ. Nay GTV chờ một nhịp (80 ms)
  sau thông báo rồi mới đọc, một lần cho cả loạt thông báo của cùng một lần đổi.
- Bộ gõ khởi động lại lúc một ô nhập liệu đang mở (vd. sau khi cập nhật): ô đó chưa áp dụng cài đặt riêng của ứng dụng (loại
  trừ, soạn từng từ, terminal) cho tới khi đổi sang ứng dụng khác. (Từ bản gốc 1.11.2.)
- **Xoá từ vừa gõ (⌥⌫) hay cả dòng (⌘⌫) rồi gõ lại ngay thì ra số / chữ không dấu** (VNI lẫn Telex; Claude, Zalo, VS Code và
  mọi ô web của Chrome / Electron): sau phím xoá hay click, bộ gõ chưa có bằng chứng từ mới nằm ở đâu trong bản sao văn bản
  của Chromium nên bỏ hẳn việc thêm dấu cho từ đó — và cho mọi từ sau, tới khi ngừng gõ hơn 1 s. Nay từ đó tạm đi nguyên văn
  rồi được thay bằng chữ có dấu ngay khi trang cho thấy nó nằm ở đâu (thường ở phím thứ hai, thứ ba), các từ sau gõ như
  thường. Chữ chèn trong một phím chưa tới trang thì không thay theo vị trí ngay trong phím đó (IME Lab: "đ9ẳng").
- **VS Code (và mọi ô web dùng EditContext): gõ dở một từ, xoá bằng ⌥⌫ / ⌘⌫ rồi gõ lại thì ra số, các từ sau cũng vậy tới khi
  ⏎ / ⌘Tab.** Ô EditContext chỉ báo lại chữ cho phía trình duyệt khi con trỏ đổi chỗ; phím dấu thay một chữ bằng chữ cùng độ
  dài (ê → ế) nên bộ gõ đọc thấy chữ cũ hơn một lần sửa. Bấm phím xoá đúng lúc đó thì bản trước kết luận "không biết trang đã
  báo gì" và mọi từ sau đi nguyên văn — không còn đường nào lấy lại bằng chứng vị trí khi gõ liền tay. Nay:
  - bộ gõ nhận ra bộ đệm đang ở một trạng thái cũ của chính chuỗi vừa gõ (chậm vài phím / lần sửa cũng được) và biết chắc
    khi nào trang đã báo tác dụng của phím xoá — từ gõ lại được sửa dấu ngay như thường;
  - đầu chuỗi chưa đáng tin (có click / phím tắt bộ gõ không thấy ngay trước) thì bộ gõ lấy bằng chứng từ chính nội dung:
    bộ đệm cho thấy trọn chữ đang gõ ở cùng một chỗ qua hai phím liền (hoặc sau khi ngừng gõ 1 s) là đủ;
  - từ lỡ đi nguyên văn trong lúc chờ bằng chứng không bị bỏ nữa: có bằng chứng thì nó và các từ sau nó được thay lại bằng
    chữ có dấu trong một lần sửa;
  - phím dấu đầu tiên của một chuỗi chưa đáng tin chỉ bị giữ tối đa 70 ms (trước: 250 ms).
  Bằng chứng kiểu cũ "bộ đệm khớp một trạng thái cũ của chuỗi, dài từ hai ký tự" bị siết thành "khớp trọn chuỗi": dạng cũ có
  thể trùng hợp với đuôi của từ vừa gõ lại và sửa nhầm chỗ.
- **Ô web (VS Code, Claude, Zalo, Chrome…): gõ lại sau ⌘⌫ / ⌥⌫ / click thì thấy chữ thô ("d9…") hiện ra rồi mới nhảy thành chữ
  có dấu.** Sau một phím bộ gõ không biết tác dụng mà con trỏ của bộ đệm không đổi (⌘⌫ bấm hai lần — lần sau không còn gì để
  xoá, nhiều phím tắt liền nhau, click) thì không có gì cho biết trang đã xử lý nó chưa; bản trước cho phím dấu đi nguyên
  văn rồi sửa lại khi có bằng chứng — đúng chữ nhưng thấy nhảy. Nay ngay sau phím ĐẦU của một chuỗi chưa có bằng chứng, bộ
  gõ hỏi ô một câu mà Chromium phải hỏi sang trang rồi chờ trả lời ("ký tự ở điểm này trên màn hình" — câu bộ gõ có cửa sổ
  gợi ý vẫn hỏi; không gửi phím, không đổi gì trong trang). Có trả lời nghĩa là trang đã xử lý xong mọi phím / click trước
  đó; một nhịp sau, con trỏ của bộ đệm là con trỏ thật. Việc này nằm gọn giữa hai phím (chừng 15 ms), nên phím dấu kế tiếp
  sửa đúng chỗ ngay — không chữ thô nào ra trang. Cũng nhờ vậy phím dấu là phím thứ hai của từ ("đ", "á") sau một lúc nghỉ
  ra dấu ngay, không còn bị giữ tới phím kế tiếp. Trang treo không trả lời thì bộ gõ về cách cũ (không bao giờ sửa nhầm chỗ).
- **Telegram (và mọi ô chat tự xử lý ⏎ trước bộ gõ): từ đầu của tin kế tiếp ra nguyên văn, gõ lại ở đầu ô thì bị gạch chân.**
  ⏎ gửi tin không tới bộ gõ; ô bị xoá trắng, bộ gõ còn giữ từ cuối của tin vừa gửi mà con trỏ đã về 0 — và kết luận nhầm "ô
  không cho biết con trỏ" (ô mù): phần còn lại của từ đi nguyên văn, từ sau gõ ở đầu ô được soạn bằng marked text. Nay ô đã
  từng báo con trỏ ở vị trí khác 0 thì không bao giờ bị coi là ô mù: con trỏ về đầu ô là chữ đã bị xoá thật, phím kế tiếp bắt
  đầu từ mới ở đó. (IME Lab, ô chat thử: bản trước ra `tiếng việt⏎d9a38ng cấp`.)
- **Firefox, Zen và các trình duyệt Gecko: gõ nhanh — nhất là ngay sau khi chuyển ứng dụng — hay trang chậm thì có từ không
  nhận dấu.** Gecko trả lời bộ gõ từ một bộ đệm ở tiến trình cha, chỉ cập nhật khi trang báo về; phím sau tới trước lúc đó thì
  bộ gõ thấy con trỏ "chưa nhích" và cho phần còn lại của từ đi nguyên văn (IME Lab, Firefox thật: `đo61i` khi gõ 3 ms / phím,
  `d9a38ng` / `ho5c` khi trang bận). Nay ô web của Gecko đi cùng đường với Chromium — bộ gõ tự giữ vị trí chuỗi đang gõ, bộ đệm
  chỉ để đối chiếu — với các khác biệt của Gecko: bộ đệm không tự đoán (thấy một ký tự của chuỗi là trang đã báo), không hỏi
  đồng bộ sang trang được, và bước "đặt vùng chọn" của một lần thay bị bỏ qua khi vùng thay trùng vùng chọn trình duyệt đang
  nhớ (bộ gõ nới vùng thay một ký tự để nó không trùng).
- Firefox / Zen: gõ dở một từ rồi bấm ⌘⌫ thì ⌘⌫ không xoá gì — bộ gõ khôi phục từ gõ dở ngay trong keyDown của ⌘⌫ làm Gecko
  nuốt chính phím tắt đó. Ở Gecko bộ gõ không sửa chữ trong keyDown của phím không ra chữ.
- **Ô web có gợi ý tự điền bôi đen sau con trỏ** (thanh địa chỉ, ô tìm kiếm có gợi ý — Chrome, Electron, Firefox): phím dấu
  mất hẳn (`tie61ng` ra "tieng") hay gợi ý dính lại thành chữ thật. Nay phím dấu thay luôn cả phần gợi ý đang bôi đen, như
  khi gõ đè lên nó.
- Gõ ngay lúc ô vừa được gắn (vừa mở Raycast, vừa chuyển ứng dụng): ô còn trả lời tạm "con trỏ ở 0" làm từ đầu tiên mất dấu
  và bị coi là ô mù. Nay phím được giữ lại tối đa 70 ms chờ ô trả lời thật rồi mới sửa; ô mù thật thì như trước.
- Ô thường báo chậm hơn phím (bộ đệm phía ứng dụng): bộ gõ có thể đọc lại từ theo bản chụp cũ rồi sửa lệch một ký tự
  (`ca61p` ra "cáp" và thừa "6"). Nay không bắt đầu từ ở vị trí mà dấu cách vừa gõ chưa hiện trước con trỏ, không đọc lại từ
  khi ô đang cho thấy một trạng thái cũ của chính từ đó, và trong một đợt ô báo chậm thì các từ gõ liền tay đi nguyên văn.
- Bật nhật ký (`trace`): ghi thêm quyết định của bộ gõ ở ô web (chuỗi mới đáng tin hay chưa, phím đi nguyên văn chờ trang, sửa
  lại khi có bằng chứng) và ở ô thường (ô báo chậm, giữ phím chờ ô trả lời, ô mù) — vẫn không ghi chữ đã gõ. File nhật ký có
  sẵn mà không mở được thì bỏ dòng đó, không ghi đè cả file.
- Ô thường (gõ trực tiếp): mất dấu từ đang gõ đúng ở phím kết thúc từ (ô chat tự xoá sau khi bấm Gửi rồi tin sau mở đầu bằng
  dấu ngoặc / nháy; ô báo chậm lúc bấm dấu cách liền tay) không còn làm cả từ SAU đi nguyên văn. Từ đang đi nguyên văn bị
  ⌫ hết rồi gõ lại thì gõ như thường.
- Ô thường: chữ tổ hợp (NFD — tên file của Finder) ngay trước con trỏ làm phím dấu ra thô ("ngươi2"); ⌫ vào giữa một từ
  tiếng Anh dài (hơn 12 chữ) hay có chữ lạ rồi gõ tiếp bị thêm dấu như bắt đầu từ mới ("responsibilitié").
- Ghostty: ⏎ / ⇥ bấm liền tay sau phím cuối (lần sửa còn chờ gửi) chạy lệnh chưa được khôi phục — `user` ⏎ chạy "ủe".
- Phím tắt ba phím bổ trợ (⌥⌘⇧V, ⌃⌘⇧4…) làm V/E tự đổi khi nhả phím thừa trước rồi mới nhả ⌘⇧: lần nhả đó trông như nhấn
  tổ hợp đổi Anh/Việt "trơn".
- Từ viết tắt có đ: `d9c` / `ddc` ra "đc" (không bị trả về phím gõ), `D9H` "ĐH"; đ không đứng đầu gõ được — `HD9` "HĐ",
  `QD9` "QĐ", `ND9-CP` "NĐ-CP", `SD9T` "SĐT" (Telex: `HDD`, `QDD`…; gõ lặp `HDDD` ra "HDD").
- Gõ được "Kạn" (Bắc Kạn), "Kông" (Kông Chro), "Kô", "Kơ" (Kơ nia) và vần "oao" (ngoáo ộp).
- VNI: số không áp dụng được gõ ngay sau số vừa thành dấu nghĩa là đang gõ một con số — `i18n`, `e19`, `to19` ra nguyên văn
  (trước: "í8n"). Số áp dụng được vẫn là dấu như mọi bộ gõ VNI (`a10` ra "a", `u23` ra "ủ": gõ lặp số đầu — `u223` — để ra
  "u23").
- Telex: `keeper`, `deeper`, `downward`… ra "keper", "donward" (phím lặp không liền nhau huỷ mũ / móc rồi không khôi phục).
- Từ có sẵn đặt dấu thanh theo kiểu kia (hoà / hòa, thuý / thúy) hay đặt lệch (qúa) không nạp lại được để gõ tiếp.
- Bật nhật ký (`trace`) rồi đĩa đầy: mỗi lần ghi lỗi ném NSException làm bộ gõ chết ở mỗi phím. Nay ghi ở luồng nền, lỗi ghi
  bị bỏ qua.
- Thêm / bỏ một ứng dụng KHÁC khỏi danh sách loại trừ lúc đang tự chọn tiếng Anh thì bị bật tiếng Việt; bộ gõ khởi động lại
  (cập nhật) lúc đang ở ứng dụng loại trừ thì kẹt tiếng Anh ở mọi ứng dụng.
- Màn hình khoá hiện quá 2 phút mà thông báo mở khoá không tới (macOS 27): mở khoá xong máy ở lại ABC. Nay GTV tự dò tới khi
  hết khoá.
- **Java gõ trực tiếp (IntelliJ / Android Studio và các ứng dụng JetBrains Runtime; Burp Suite / Ghidra có trợ thủ): từ được
  sửa lúc hết từ bị mất chữ.** Telex gõ từ tiếng Anh rồi dấu cách (`keeper ` ra "ke ", `user ` ra "u "), `thuwor ` / VNI
  `thu7o3 ` ("thuở" ra "th "), ⌫ làm dời dấu (`hoafn` ⌫ ra "hòan"). JetBrains Runtime chỉ giữ chữ của lần chèn cuối trong mỗi
  phím — dấu cách đè mất chữ bộ gõ vừa đưa và xoá luôn vùng đã chọn; AWT gốc thì bỏ phím ⌫ / ⏎ bấm cùng lần sửa. Nay ở các ô
  này lần sửa cuối từ đi chung với chữ của phím kết thúc từ trong một lần thay, ⌫ dời dấu do bộ gõ tự xoá. Phím kết thúc từ
  không ra chữ (⏎, ⇥, mũi tên) thì không sửa gì trong phím đó: chữ để nguyên như đang hiện.
- Trợ thủ Java: máy ảo Java 8–10 có dòng `-javaagent` không còn chết lúc khởi động (trợ thủ tự thôi ở đó); ô từ chối chữ có
  dấu (ô chỉ nhận số / hex) không còn bị bôi đen vùng vừa định thay — phím sau không xoá mất chữ; ô đang giữ focus chuyển
  từ chỉ đọc sang sửa được thì gõ có dấu ngay, không phải click sang ô khác rồi quay lại.
- Cập nhật ngầm lúc đang ở English (GTV) có thể chọn lại Tiếng Việt (GTV); cập nhật bằng rsync (ổ HFS+) hỏng giữa chừng bị coi
  là đã xong. Phát hành: bài thử trợ thủ Java hỏng không làm đỏ CI; chạy lại lượt Release của commit cũ phát hành mã cũ với số
  build mới nhất.

### Đồng bộ với bản gốc
- Ghép bản gốc S0nnyHoang/gtv 1.11.2. Chế độ terminal của bản gốc (gửi DEL + chữ mới) đã có ở đây từ 1.12 với phần nhận biết
  phím / click đi vòng bộ gõ, nên giữ cách của bản này.

## 1.13.1 — 2026-11-08

### Sửa lỗi
- Burp / Java / Qt 5 / GTK (gõ bằng phím ⌫ giả): có máy gõ dấu không ra ("d9a38ng" ra nguyên văn, "đẳng" ra "đ"). Hệ thống
  báo một phím (Return) kẹt ở trạng thái "đang nhấn" — do ứng dụng khác gửi phím nhấn mà không gửi phím nhả — và GTV coi đó là
  phím người dùng chưa tới ứng dụng nên hoãn mọi lần sửa dấu. Giờ phím kẹt không còn được tính; lần hoãn (khi có phím thật
  của người dùng chưa tới) cũng không bao giờ kéo dài quá 1,5 s dù người dùng gõ liền.
- Phím tắt đổi Anh/Việt (⌘⇧…) không ăn khi hệ thống báo một phím kẹt như trên: GTV tưởng đang giữ phím khác lúc nhấn tổ hợp.
  Giờ phím "đang giữ" quá 2 s mà không lặp (nút chuột: quá 10 s) không còn tính.

## 1.13 — 2026-11-06

### Thay đổi
- Java (Burp Suite, IntelliJ không chạy JBR, Ghidra…), Qt 5, GTK, winit, LibreOffice: gõ không gạch chân, con trỏ luôn ở
  sau chữ. GTV gõ thẳng như ở ô thường rồi sửa dấu bằng phím ⌫ + chữ mới gửi vào ô. Cần quyền Trợ năng: menu bộ gõ →
  *Gõ không gạch chân trong Java, Qt 5, GTK…: cấp quyền Trợ năng…* (cấp một lần — bản phát hành giờ ký bằng chứng chỉ cố
  định nên quyền giữ qua các lần cập nhật). Chưa cấp thì gõ bằng gạch chân như trước.
  - Ứng dụng chậm (phím thật tới trước phím sửa), gõ nhanh, ⌫ ngay sau phím dấu: GTV dựng lại chữ thật trong ô theo đúng
    thứ tự ứng dụng xử lý rồi sửa đúng phần lệch.
  - Người dùng đã bấm ⌫ / mũi tên / ⏎ / click / ⌘… mà phím đó chưa tới ứng dụng: GTV hoãn phím sửa (không bao giờ xoá lố
    vào chữ có sẵn hay xoá ở chỗ con trỏ mới); không chắc thì để chữ nguyên văn.
- Ô tự vẽ không cho biết con trỏ (GPUI, terminal nhúng…): nhận ra ở phím sửa đầu tiên rồi gõ bằng phím ⌫ giả (không gạch
  chân); chưa có quyền Trợ năng thì từ sau gạch chân thay vì ra nguyên văn. Đổi ô / click thì nhận lại từ đầu.
- Bỏ mọi chỗ làm một ứng dụng lúc gạch chân lúc không (một lần đọc con trỏ {0,0} không còn bật gạch chân cho cả cửa sổ về
  sau). Danh sách gạch chân mặc định cũ (Alacritty, Warp, các terminal) đã bị lưu vào cài đặt được gỡ một lần.

### Sửa lỗi
- Chrome / Electron (VS Code, Slack, Discord, Claude, Zalo…): gõ nhanh hay trang chậm ra "đa38ng", "đả8ng", mất dấu lúc
  được lúc không. Chromium chỉ cho bộ gõ thấy bản sao văn bản cập nhật sau khi trang xử lý xong; GTV giờ tự giữ vị trí của
  cả chuỗi gõ liền (kể cả mọi ⌫) và chỉ dùng bản sao để nhận ra trang chậm / chữ bị đổi / con trỏ đã dời.
- Chrome / Electron: trang xoá ô sau khi gửi tin, trang tự đổi chữ (Notion "->" → "→", dấu đầu dòng), click lùi vào giữa
  văn bản, gõ chèn trước chữ có sẵn (VS Code tự đóng ngoặc / nháy), ⌫ lùi về từ trước rồi gõ dấu, gõ ngay sau ⏎ / mũi tên:
  không sửa nhầm chỗ, chữ đã xoá không sống lại. Lúc không chắc vị trí (trang rất chậm ngay sau click / ⏎), phím dấu đi
  nguyên văn thay vì đoán.

## 1.12 — 2026-11-06

### Thay đổi
- Terminal (Ghostty, iTerm2, Terminal.app, Rex, Muxy, kitty, WezTerm): gõ thẳng, không còn gạch chân. Phím tới shell
  ngay khi gõ nên gợi ý lệnh của fish / zsh hiện đúng và Ctrl+E nhận cả gợi ý (trước đây chỉ hoàn thành phần chữ đang
  gạch chân). Khi thêm dấu, GTV gửi một lần "xoá + chữ mới" xuống shell, không nháy chữ. Muốn gõ có gạch chân như
  trước: menu bộ gõ → *Gạch chân khi gõ trong …*.
- Terminal: GTV tự biết khi có phím hay click không qua bộ gõ (⌘V, mũi tên và Ctrl+A ở iTerm2, Tab ở Muxy, ⌫ / Tab /
  mũi tên ở Terminal.app, click dời con trỏ ở Ghostty…) nên không xoá nhầm chữ không phải do nó gõ (vd. dán giữa một từ
  rồi gõ dấu). Không event tap, không cần quyền: trong lúc gõ, GTV đọc trạng thái phím đặc biệt và nút chuột của hệ
  thống. iTerm2, Terminal.app: sau ⌫ / click thì đọc lại từ trên màn hình để gõ tiếp.
- Thanh Find, command palette… trong app terminal gõ như ô văn bản thường.
- Herdr: gõ thẳng xuống shell như Ghostty / Muxy (không gạch chân); thanh Find và ô prompt gõ như ô văn bản thường.
- Ứng dụng chưa kiểm chứng có ô tự vẽ không cho biết con trỏ (GPUI, terminal nhúng, ứng dụng Rust…): không còn từ nào ra
  nguyên văn (`d9a82ng`) — từ bắt đầu khi ô báo con trỏ ở đầu được gõ bằng gạch chân, cách đúng ở mọi ô; ô có con trỏ giả
  (ô chat trong game SDL) cũng vậy từ từ thứ hai.
- Kaku (bản fork của WezTerm) và Iruka (SwiftTerm): gõ thẳng xuống shell như các terminal khác.
- Ứng dụng GTK (CherryTree, GIMP, Inkscape…) và winit (egui, iced, Alacritty…): gõ được dấu (gạch chân trong lúc gõ một từ).
  Trước đây GTK mất cả từ khi gõ dấu cách, winit nuốt dấu cách / ⏎ ngay sau từ.
- Terminal SwiftTerm nhúng trong ứng dụng khác (SSH client, agent…): gõ bằng gạch chân thay vì ra chữ rác.
- Ứng dụng Flutter (LocalSend, RustDesk, Reqable…): ô văn bản gõ trực tiếp như trước; terminal xterm.dart gõ bằng gạch chân.
- Chế độ V/E giữ cố định: đổi ứng dụng, quay lại sau ô mật khẩu / màn hình khoá không làm nhảy chế độ. Người dùng tự
  đổi (⌘⇧, ⌃Space, 🌐, menu bộ gõ, kể cả khi đang ở bộ gõ khác) thì theo.

### Sửa lỗi
- macOS 27: ⌘⇧Z, ⌘⇧4, ⌘⇧← / → (chọn chữ), ⌘⇧ + click bị hiểu nhầm là phím tắt đổi chế độ, và có lúc lựa chọn chế độ của
  người dùng bị đảo lại sau khi đổi ứng dụng (macOS 27 chỉ cập nhật thời điểm sự kiện mỗi 0,5 s cho ứng dụng khác, GTV
  không còn dựa vào đó).
- Đang ở bộ gõ khác (ABC…) chọn "Tiếng Việt (GTV)" / "English (GTV)" trong menu bộ gõ có lúc lại ra chế độ cũ: lời báo cho
  lần GTV tự chọn lại chế độ cũ tới sau lựa chọn của người dùng và bị coi là người dùng chọn; GTV khởi động theo lựa chọn
  đó, hay vừa rời ứng dụng loại trừ, cũng chọn đè. Đổi chế độ hai lần liền tay (⌘⇧ rồi ⌃Space…) không còn bị đảo lại.
- Ứng dụng loại trừ được macOS chọn lại tiếng Việt (nhớ theo ứng dụng) không còn làm chế độ tiếng Anh thành tiếng Việt khi
  rời ứng dụng đó.
- Gạch chân (ứng dụng chọn gạch chân, *Luôn dùng gạch chân*): xoá lùi rồi gõ tiếp trong một từ ra sai (`anht⌫f`).
- Gõ ngay khi ô nhập liệu vừa hiện (TinyCast, Spotlight-style: ⌘Space rồi gõ liền `d9a38ng`) có lúc ra `d9ẳng`: lời báo
  chế độ mà macOS gửi sau mỗi lần gắn bộ gõ, tới sau phím đầu tiên, làm GTV quên chữ vừa gõ.
- Ứng dụng Java (Burp Suite, IntelliJ, Ghidra… — AWT / Swing / JavaFX / Compose Desktop) không gõ được dấu: Java bỏ qua
  cách thay chữ trực tiếp, GTV tự nhận ra và gõ bằng marked text (có gạch chân trong lúc gõ một từ, như bộ gõ tiếng
  Nhật / Trung — cách duy nhất Java hỗ trợ). Từ đang gạch chân được chốt sau 1 giây không gõ: Java nuốt phím ←, ⌘A, ⌘S,
  Esc… nếu bộ gõ chốt từ ngay lúc phím đó tới.
- Qt 5 (VLC 3, KeePassXC, Wireshark, VirtualBox 6…), LibreOffice, Emacs, MacVim: không ra dấu, có lúc chèn "ư" vào giữa từ
  ("awesome" → "aưesome"). Các ứng dụng này bỏ qua cách thay chữ trực tiếp: GTV tự nhận ra và gõ bằng marked text.
- Chrome, Electron (VS Code, Slack, Claude…): ⌫ làm dời dấu thanh xoá mất hai ký tự (kiểu dấu cũ: `hoafn⌫` ra `hò`
  thay vì `hòa`).
- Gõ rất nhanh khi trang web xử lý chậm: không bao giờ sửa sai chỗ (đảo thứ tự `nhw` → `nưh`, xoá chữ sau từ) — GTV thấy
  ô chưa cập nhật thì để các chữ còn lại của từ đi nguyên văn.
- Chọn một mục trong menu bộ gõ khi đang có chữ gạch chân làm mất chữ đó.
- Spotlight / Raycast / Alfred mở trên một ứng dụng bị loại trừ: không bật được tiếng Việt.
- Hiếm: ứng dụng tự chốt phần gạch chân (đổi ô, click mà bộ gõ không thấy) rồi gõ tiếp thì chữ bị nhân đôi.
- Terminal: ⏎ / ⇥ ngay sau ← / ↑ / click có thể chạy một lệnh đã bị sửa sai (`echo àa`, xoá chữ của lệnh lấy từ lịch sử).
  Từ không phải tiếng Việt kết thúc bằng ⏎ / ⇥ nay cũng được khôi phục (`nvm use⏎` chạy `nvm use`, không phải `nvm úe`).
- Terminal qua ssh chậm (in lại 200–300 ms), ứng dụng toàn màn hình (Claude Code…): không còn mất dấu khi gõ liền tay.
- Ghostty: ⏎ / ⌫ / ⇥ ngay sau ⌘V hay click không còn bị nuốt. ⇧⇥ tới shell.
- macOS 27: ⌘⇧ + phím bấm nhanh (⌘⇧Z…) không đổi chế độ nhầm; dừng tay giữa từ quá 5 giây trong iTerm2 / Terminal.app
  không mất từ.
- Gõ nhầm rồi ⌫ giữa từ tiếng Việt ra lại đúng chữ (`tieengd⌫s` → `tiếng`, không còn `tieengs`); ⌫ trong từ tiếng Anh
  không tắt tự khôi phục (`sr⌫erver` → `server`).
- Telex: từ tiếng Anh có chữ cái gõ lặp được khôi phục đúng (`sorry`, `password`, `message`, `coffee`, `worry`, `cheese`…);
  gõ được `ngoèo`, `khoèo`, `thuở` (`thuwor`), `Đắk Lắk`, `Krông Pắk`, `goòng`, `moóc`.
- Unicode tổ hợp: ⌫ rồi gõ tiếp dấu vào từ có dấu đã gõ xong hoạt động như với Unicode dựng sẵn.

### Cài đặt / cập nhật
- Cập nhật bộ gõ nguyên khối: chép và kiểm bản mới trước, rồi mới thay và tắt bản cũ — lỗi giữa chừng (vd. đĩa đầy) thì
  bộ gõ cũ vẫn chạy. Không bao giờ cài đè bằng bản cũ hơn (mở một GTV.app cũ thì hỏi trước).
- Bộ gõ tự chạy GTV.app ngầm (vd. sau khi Sparkle cài bản mới) không còn giành bộ gõ khác người dùng đang dùng.
- Tự cập nhật đọc bản phát hành của repo này (meichengg/gtv), ký bằng khoá riêng.
- "Chọn GTV khi đăng nhập" hiện đúng trạng thái thật; mục đăng nhập người dùng đã gỡ không bị thêm lại.

### Lưu ý
- vim / nvim, vi-mode của shell: ở normal mode các phím là lệnh — chuyển sang tiếng Anh (⌘⇧) khi gõ lệnh, hoặc dùng
  plugin tự đổi bộ gõ (vd. im-select.nvim với `com.gtv.inputmethod.GTV.en` / `com.gtv.inputmethod.GTV.vi`).
- macOS 27, phím do chương trình gõ hoặc điều khiển từ xa (Chrome Remote Desktop…): GTV chưa phân biệt được ⌘⇧ + phím chữ
  với ⌘⇧ trơn; bàn phím thật thì được.

## 1.11.2 — 2026-11-11 (bản gốc)

### Thay đổi
- Terminal (Terminal, iTerm2, Ghostty, kitty, Alacritty, WezTerm, Warp…): gõ tiếng Việt không còn gạch
  chân. Chữ được gửi xuống shell ngay nên gợi ý tự động (zsh-autosuggestions, fish…) hiện bình thường,
  không phải bấm Tab.
- Menu GTV: thêm "Chế độ terminal cho <ứng dụng>" để bật cho terminal chưa có trong danh sách. Nếu một
  terminal gõ bị lỗi, bật "Dùng gạch chân cho <ứng dụng>" để quay lại cách cũ.

### Sửa lỗi
- Sau khi GTV cập nhật hoặc khởi động lại, cửa sổ đang mở chưa áp dụng cài đặt riêng của ứng dụng
  (loại trừ, gạch chân) cho tới khi chuyển sang ứng dụng khác.

## 1.11.1 — 2026-10-12

### Sửa lỗi
- Xoá lùi vào một từ đã gõ xong rồi gõ tiếp dấu không có tác dụng (vd. `hoir ` → xoá còn `hoi` → gõ `r`
  ra `hoir` thay vì `hỏi`).

## 1.11 — 2026-10-09

### Tính năng mới
- Tự động cập nhật: GTV tự kiểm tra bản mới khi khởi động và mỗi 24 giờ. Khi có bản mới, hiện thông
  báo kèm nội dung cập nhật, có thể cài ngay, bỏ qua phiên bản đó hoặc nhắc sau.
- Menu GTV: thêm "Kiểm tra cập nhật…" và tuỳ chọn "Tự động kiểm tra cập nhật".

## 1.10.5 — 2026-10-06

### Sửa lỗi
- Telex: gõ `ww`, `[[`, `]]` trong ô nhập liệu của trang web (Chrome, ô "Ask Google"…) và các ứng dụng
  Electron như Claude desktop ra `ưw`, `ơ[`, `ư]` thay vì `w`, `[`, `]`.

## 1.10.4 — 2026-10-05

### Sửa lỗi
- Telegram Desktop: gõ `[[`, `]]`, `ww` ra `ơ[`, `ư]`, `ưw`.

## 1.10.3 — 2026-10-05

### Thay đổi
- Telex: gõ `[` hai lần ra dấu `[` (thay vì `ơơ`), tương tự `]` → `]`, `{` → `{`, `}` → `}`.

## 1.10.2 — 2026-10-03

### Sửa lỗi
- Sau khi gập máy (hoặc máy ngủ) rồi mở lại, bộ gõ ở lại ABC thay vì quay về GTV.

## 1.10.1 — 2026-10-03

### Thay đổi
- Kiểu viết thân mật luôn bật, bỏ tuỳ chọn trong menu.

## 1.10 — 2026-10-03

### Tính năng mới
- Hỗ trợ kiểu viết thân mật: `zậy`, `zị`, `dzô`, `qá` (phụ âm đầu `z`, `dz`, `q` không cần `u`).

## 1.9.3 — 2026-10-02

### Sửa lỗi
- Khoá màn hình rồi mở khoá, bộ gõ ở lại ABC thay vì quay về GTV.

## 1.9.2 — 2026-10-02

### Tính năng mới
- Hiện phiên bản trong menu GTV.

## 1.9 — 2026-10-02

### Thay đổi
- Icon bộ gõ cùng kích thước với icon ABC; icon ứng dụng trong danh sách loại trừ.
- Lần cài đầu: nếu không bật được bộ gõ, hiện hướng dẫn thêm bằng tay.

## 1.8 — 2026-10-02

### Tính năng mới
- Tự chọn GTV khi đăng nhập (tắt được trong menu).

## 1.7 — 2026-10-02

### Thay đổi
- Tiếng Anh là một chế độ của GTV ("English (GTV)"): chuyển Anh/Việt không còn nháy cửa sổ.
- Âm báo của hệ thống khi chuyển Anh/Việt (tắt được trong menu).

## 1.6 — 2026-10-02

### Thay đổi
- Phím chuyển Anh/Việt mặc định là ⌘⇧ (Command + Shift); thêm lựa chọn ⌥⇧.
- Mặc định đặt dấu kiểu cũ (`hòa`, `thúy`).
- Danh sách ứng dụng loại trừ hiện dạng menu con.

## 1.5 — 2026-10-02

### Thay đổi
- Mọi cài đặt nằm trong menu bộ gõ của macOS; biểu tượng V/E riêng thành tuỳ chọn.
- Ứng dụng loại trừ không bao giờ gõ tiếng Việt.

## 1.4 — 2026-10-02

### Tính năng mới
- Ứng dụng không gõ tiếng Việt (vd. IDE): tự chuyển sang tiếng Anh khi dùng ứng dụng đó.

## 1.0 – 1.3 — 2026-10-02

### Tính năng mới
- Bộ gõ tiếng Việt cho macOS: Telex, VNI, Telex đơn giản; Unicode dựng sẵn, Unicode tổ hợp, TCVN3.
- Không gạch chân chữ đang gõ; không lỗi "dđ" ở thanh địa chỉ trình duyệt.
- Tự khôi phục từ tiếng Anh, bỏ dấu tự do, gõ lặp để huỷ dấu.
- App riêng: mở GTV là tự cài và chọn bộ gõ; phím tắt chuyển Anh/Việt.
