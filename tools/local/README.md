# Test cục bộ trên máy thật (Burp / Java Swing)

Chỉ chạy khi người dùng cho phép dùng máy (cửa sổ test nổi lên trước, gõ phím giả). Mọi file lớn / build nằm trên
`/Volumes/HDD_2/Downloads/gtv-work/local` (SSD đầy); file ô test ghi ra scratchpad trên SSD (ổ HDD chậm làm luồng giao
diện của Java đứng).

- `install-debug.sh`: build GTVInput Debug (có `~/Library/Logs/GTV-debug.log` — ghi phím, xoá sau khi xong), ký bằng chứng chỉ
  của fork (giữ quyền Trợ năng), thay vào bộ gõ đang cài. Cần keychain tạm `sign/` (dựng từ mục `gtv-fork` trong login keychain).
- `run.py`: `start_swing()` mở `SwingFieldT.java` bằng JRE của Burp; `run_case()` gõ vào app Swing; `run_burp()` gõ vào ô đang
  focus của Burp (đọc lại qua AX). Bộ gõ nhận cài đặt mới qua `notifyutil -p com.gtv.lab.reload` (bản Debug).
- `cases.py`, `words.py`: các bài và từ vựng cho đợt gõ ngẫu nhiên.
- Công cụ (biên dịch bằng `swiftc -O`): `front`, `activate <pid>`, `click x y [n]`, `axval <pid> [role]`, `axdump`, `winlist`,
  `probe` (quyền của tiến trình đang chạy), cùng `tools/lab/driver.swift` (`drv`) và `tools/lab/is.swift` (`is`).
- Burp: chỉ gõ trong một tab Repeater mới (nút "+" → New HTTP tab), đóng tab khi xong.
