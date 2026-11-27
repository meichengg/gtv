package gtv.helper;

/**
 * Máy ảo "đang chạy" cho bài thử tự nạp trợ thủ (test.sh): không có dòng -javaagent nào. In "ready" khi đã chạy, rồi chờ
 * luồng của trợ thủ xuất hiện (in "agent") — bộ gõ nạp nó từ bên ngoài, qua cổng attach — tới khi bị dừng.
 */
public final class AttachTarget {
    private AttachTarget() {}

    public static void main(String[] args) throws Exception {
        System.out.println("ready");
        boolean seen = false;
        while (true) {
            if (!seen) {
                for (Thread t : Thread.getAllStackTraces().keySet()) {
                    if ("GTV Java helper".equals(t.getName())) seen = true;
                }
                if (seen) System.out.println("agent");
            }
            Thread.sleep(50);
        }
    }
}
