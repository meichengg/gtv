#!/bin/bash
# Gỡ GTV.
set -u

# Trước khi xoá file: GTV.app chọn lại bàn phím ABC (nếu đang ở GTV), tắt các nguồn nhập của GTV (để macOS không giữ
# một bộ gõ đã bị xoá làm bộ gõ đang chọn, cũng không mở lại nó) và gỡ mục "Mở khi đăng nhập". GTV.app đời cũ không
# hiểu --uninstall (sẽ cài lại bộ gõ) nên chỉ chạy bản có GTVSupportsUninstall.
done_cleanup=0
for app in "/Applications/GTV.app" "$HOME/Applications/GTV.app"; do
    if [ "$(/usr/libexec/PlistBuddy -c 'Print :GTVSupportsUninstall' "$app/Contents/Info.plist" 2>/dev/null)" = "true" ]; then
        "$app/Contents/MacOS/GTV" --uninstall && done_cleanup=1
        break
    fi
done
if [ "$done_cleanup" = 0 ]; then
    echo "Nếu đang dùng GTV, hãy chuyển sang bộ gõ khác (phím 🌐 hoặc Control + Space) và gỡ GTV khỏi Cài đặt hệ thống →"
    echo "Bàn phím → Nguồn đầu vào, Cài đặt chung → Mục đăng nhập."
fi

pkill -x GTVInput 2>/dev/null || true
pkill -x GTV 2>/dev/null || true
rm -rf "/Applications/GTV.app" "$HOME/Applications/GTV.app"
rm -rf "$HOME/Library/Input Methods/GTVInput.app" "$HOME/Library/Input Methods/GTV.app"
# Cài đặt của bộ gõ, của GTV.app (Sparkle), bộ đệm (Sparkle, chỗ chép tạm khi cập nhật)
defaults delete com.gtv.inputmethod.GTV 2>/dev/null || true
defaults delete com.gtv.GTV 2>/dev/null || true
rm -rf "$HOME/Library/Caches/com.gtv.inputmethod.GTV" "$HOME/Library/Caches/com.gtv.GTV" \
       "$HOME/Library/HTTPStorages/com.gtv.inputmethod.GTV" "$HOME/Library/HTTPStorages/com.gtv.GTV"
# File trạng thái của trợ thủ Java (mỗi tiến trình Java một file nhỏ, tên là pid): chỉ dọn file của tiến trình đã thoát.
# File của ứng dụng Java đang chạy thì để nguyên — xoá nó thì cài lại GTV xong, ứng dụng đó "mất" trợ thủ (quay về soạn
# từng từ) tới lần đổi ô kế tiếp.
STATE="$HOME/Library/GTV/state"
if [ -d "$STATE" ]; then
    for f in "$STATE"/*; do
        [ -f "$f" ] || continue
        pid="${f##*/}"
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        kill -0 "$pid" 2>/dev/null || rm -f "$f"
    done
fi
# Trợ thủ Java (~/Library/GTV/gtv-java-helper.jar): KHÔNG xoá — ứng dụng Java nào còn dòng -javaagent trỏ tới nó trong tham số
# JVM sẽ không khởi động được nếu file mất.
JAR="$HOME/Library/GTV/gtv-java-helper.jar"
if [ -f "$JAR" ]; then
    echo "Còn giữ $JAR (trợ thủ Java của GTV)."
    echo "Nếu bạn đã thêm dòng  -javaagent:$JAR  vào tham số JVM của ứng dụng Java nào (Burp Suite: user.vmoptions,"
    echo "Ghidra: support/launch.properties…), hãy xoá dòng đó TRƯỚC rồi mới xoá file này — không thì ứng dụng đó không mở được."
fi
echo "Đã gỡ GTV. Nếu GTV vẫn còn trong danh sách bộ gõ, hãy đăng xuất rồi đăng nhập lại."
