package gtv.helper;

import java.lang.instrument.Instrumentation;

/**
 * Trợ thủ Java của GTV — điểm vào khi nạp bằng {@code -javaagent:gtv-java-helper.jar}.
 *
 * <p>AWT của JDK gốc (mọi bản OpenJDK, trừ JetBrains Runtime) bỏ qua vùng cần thay mà bộ gõ gửi kèm chữ
 * ({@code insertText:replacementRange:}), nên bộ gõ chỉ còn cách soạn từng từ (phần chữ đang soạn do Swing tự gạch chân,
 * phím tắt / mũi tên bị AWT nuốt khi đang soạn). JetBrains Runtime thì chọn đúng vùng đó trước khi chèn
 * ({@code CInputMethod.selectRange}). Trợ thủ này làm đúng việc ấy cho JDK gốc, ngay trong máy ảo của ứng dụng: xem
 * {@link Bridge}.
 *
 * <p>Lớp này không được đụng tới lớp AWT nào: {@code premain} chạy trước {@code main} của ứng dụng, nạp AWT ở đây là khởi
 * động AWT trước khi ứng dụng kịp đặt cấu hình của nó (headless, tên ứng dụng, thanh menu…). Chỉ khi ứng dụng đã tự tạo
 * bộ công cụ AWT thì {@link Bridge} mới được nạp, trên luồng sự kiện.
 *
 * <p>Riêng lớp này được dịch cho Java 8 (xem {@code build.sh}) và chỉ dùng API của Java 8: máy ảo cũ hơn Java 11 vẫn nạp
 * được nó — rồi nó tự thôi ({@link #supported}). Các lớp còn lại cần Java 11; nếu chính lớp điểm vào cũng vậy thì mọi máy
 * ảo Java 8–10 có dòng {@code -javaagent} này (vd. qua {@code JAVA_TOOL_OPTIONS}) chết ngay lúc khởi động.
 */
public final class Agent {
    private static boolean started;

    private Agent() {}

    public static void premain(String args, Instrumentation inst) {
        start(inst);
    }

    public static void agentmain(String args, Instrumentation inst) {
        start(inst);
    }

    private static synchronized void start(final Instrumentation inst) {
        if (started) return;
        started = true;
        try {
            String os = System.getProperty("os.name", "");
            if (!os.toLowerCase().contains("mac") || !supported(System.getProperty("java.specification.version"))) return;
            Thread t = new Thread(new Runnable() {
                @Override public void run() { waitForAwt(inst); }
            }, "GTV Java helper");
            t.setDaemon(true);
            t.setPriority(Thread.MIN_PRIORITY);
            t.start();
        } catch (Throwable e) {
            // Trợ thủ không bao giờ được làm ứng dụng không khởi động được.
        }
    }

    /** Máy ảo Java 11 trở lên ("1.8" là Java 8; từ Java 9 là "9", "10", "11"…). */
    static boolean supported(String specification) {
        if (specification == null || specification.startsWith("1.")) return false;
        try {
            int dot = specification.indexOf('.');
            return Integer.parseInt(dot < 0 ? specification : specification.substring(0, dot)) >= 11;
        } catch (RuntimeException e) {
            return false;
        }
    }

    /** Đợi ứng dụng tự tạo bộ công cụ AWT của macOS rồi mới gắn {@link Bridge}. */
    private static void waitForAwt(Instrumentation inst) {
        try {
            long waited = 0;
            while (!toolkitLoaded(inst)) {
                long step = waited < 60_000 ? 250 : 2_000;       // ứng dụng dòng lệnh không bao giờ mở AWT: hỏi thưa dần
                Thread.sleep(step);
                waited += step;
            }
            // Bộ công cụ có thể đang được tạo dở trên luồng khác: invokeLater đợi nó xong.
            Class<?> bridge = Class.forName("gtv.helper.Bridge");
            bridge.getMethod("install").invoke(null);
        } catch (Throwable e) {
            // bỏ qua: ứng dụng chạy như chưa có trợ thủ
        }
    }

    private static boolean toolkitLoaded(Instrumentation inst) {
        if (inst == null) return true;
        for (Class<?> c : inst.getAllLoadedClasses()) {
            if ("sun.lwawt.macosx.LWCToolkit".equals(c.getName())) return true;
        }
        return false;
    }
}
