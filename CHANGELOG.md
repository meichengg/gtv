# Nhật ký thay đổi

Mỗi phiên bản là một mục `## <phiên bản> — <ngày>`. Nội dung của mục được dùng nguyên văn làm release
note trên trang GitHub Releases (workflow `Release`). Phiên bản phải khớp `MARKETING_VERSION` trong
`project.yml`.

## 1.12 — 2026-11-05

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
- Chế độ V/E giữ cố định: đổi ứng dụng, quay lại sau ô mật khẩu / màn hình khoá không làm nhảy chế độ. Người dùng tự
  đổi (⌘⇧, ⌃Space, 🌐, menu bộ gõ, kể cả khi đang ở bộ gõ khác) thì theo.

### Sửa lỗi
- macOS 27: ⌘⇧Z, ⌘⇧4, ⌘⇧← / → (chọn chữ), ⌘⇧ + click bị hiểu nhầm là phím tắt đổi chế độ, và có lúc lựa chọn chế độ của
  người dùng bị đảo lại sau khi đổi ứng dụng (macOS 27 chỉ cập nhật thời điểm sự kiện mỗi 0,5 s cho ứng dụng khác, GTV
  không còn dựa vào đó).
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

### Lưu ý
- vim / nvim, vi-mode của shell: ở normal mode các phím là lệnh — chuyển sang tiếng Anh (⌘⇧) khi gõ lệnh, hoặc dùng
  plugin tự đổi bộ gõ (vd. im-select.nvim với `com.gtv.inputmethod.GTV.en` / `com.gtv.inputmethod.GTV.vi`).
- macOS 27, phím do chương trình gõ hoặc điều khiển từ xa (Chrome Remote Desktop…): GTV chưa phân biệt được ⌘⇧ + phím chữ
  với ⌘⇧ trơn; bàn phím thật thì được.

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
