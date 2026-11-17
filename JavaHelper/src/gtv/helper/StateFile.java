package gtv.helper;

import java.io.File;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;

/**
 * Điều trợ thủ báo cho bộ gõ GTV (một tiến trình khác), qua một file nhỏ:
 * {@code ~/Library/Caches/com.gtv.inputmethod.GTV/java/<pid>}, một bản ghi 64 byte ASCII ghi đè tại chỗ:
 *
 * <pre>  GTVJ1 &lt;D|C|N&gt; &lt;số lần đổi focus&gt; &lt;giây khởi động tiến trình&gt;</pre>
 *
 * D: ô đang giữ focus là ô văn bản sửa được — GTV thay chữ trực tiếp qua trợ thủ; N: ô không nhận chữ (bảng, nút, ô chỉ đọc…) —
 * GTV để phím đi thẳng; C: ô tự vẽ — GTV soạn từng từ như khi không có trợ thủ (xem {@code Bridge.kind}). Số lần đổi focus cho GTV biết con trỏ đã sang ô khác trong cùng cửa sổ (bộ gõ không thấy việc đó). Giây khởi
 * động để GTV không nhầm file cũ của một tiến trình đã thoát có cùng pid.
 */
final class StateFile {
    static final int SIZE = 64;

    private RandomAccessFile file;
    private File path;

    void open() {
        try {
            File dir = new File(System.getProperty("user.home"), "Library/Caches/com.gtv.inputmethod.GTV/java");
            dir.mkdirs();
            sweep(dir);
            path = new File(dir, Long.toString(ProcessHandle.current().pid()));
            file = new RandomAccessFile(path, "rw");
            file.setLength(SIZE);
            final File mine = path;
            Runtime.getRuntime().addShutdownHook(new Thread(new Runnable() {
                @Override public void run() { mine.delete(); }
            }, "GTV Java helper cleanup"));
        } catch (Throwable e) {
            file = null;
        }
    }

    void write(char kind, int serial) {
        if (file == null) return;
        try {
            file.seek(0);
            file.write(record(kind, serial, startSeconds()));
        } catch (Throwable e) {
            // bộ gõ đọc bản ghi cũ: tệ nhất là một từ soạn theo kiểu cũ
        }
    }

    static byte[] record(char kind, int serial, long start) {
        StringBuilder b = new StringBuilder(SIZE);
        b.append("GTVJ1 ").append(kind).append(' ').append(serial & 0x7fffffff).append(' ').append(start);
        while (b.length() < SIZE - 1) b.append(' ');
        b.setLength(SIZE - 1);
        b.append('\n');
        return b.toString().getBytes(StandardCharsets.US_ASCII);
    }

    private static long startSeconds() {
        try {
            return ProcessHandle.current().info().startInstant().map(i -> i.getEpochSecond()).orElse(0L);
        } catch (Throwable e) {
            return 0;
        }
    }

    /** Xoá file của các tiến trình đã thoát (thoát đột ngột thì không kịp tự xoá). */
    private static void sweep(File dir) {
        File[] files = dir.listFiles();
        if (files == null) return;
        for (File f : files) {
            try {
                long pid = Long.parseLong(f.getName());
                if (!ProcessHandle.of(pid).isPresent()) f.delete();
            } catch (Throwable e) {
                // tên lạ: để nguyên
            }
        }
    }
}
