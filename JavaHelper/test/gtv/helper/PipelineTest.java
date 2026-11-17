package gtv.helper;

import java.awt.EventQueue;
import java.awt.Toolkit;
import java.awt.event.InputMethodEvent;
import java.awt.font.TextHitInfo;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.text.AttributedString;
import javax.swing.JTextArea;
import javax.swing.JTextField;
import javax.swing.text.JTextComponent;

/**
 * Trợ thủ trong đường đi thật của AWT (không phải -Djava.awt.headless): gắn như lúc nạp bằng -javaagent, rồi đưa sự kiện của
 * bộ gõ vào hàng đợi sự kiện của hệ thống — bộ nhận của trợ thủ phải thấy trước ô văn bản và giữ phần đầu không cho tới ô.
 * Không mở cửa sổ nào (chạy với -Dapple.awt.UIElement=true thì cũng không hiện trên Dock): JavaHelper/test.sh --awt.
 */
public final class PipelineTest {
    private static int failures;

    private static void check(String name, Object got, Object want) {
        if (!String.valueOf(got).equals(String.valueOf(want))) {
            failures++;
            System.out.println("HỎNG " + name + ": được " + got + ", cần " + want);
        } else {
            System.out.println("ok   " + name);
        }
    }

    private static void post(JTextComponent c, String s) throws Exception {
        TextHitInfo caret = TextHitInfo.afterOffset(s.length() - 1);
        Toolkit.getDefaultToolkit().getSystemEventQueue().postEvent(
            new InputMethodEvent(c, InputMethodEvent.INPUT_METHOD_TEXT_CHANGED, new AttributedString(s).getIterator(),
                                 s.length(), caret, caret));
        EventQueue.invokeAndWait(() -> { });
    }

    public static void main(String[] args) throws Exception {
        Toolkit.getDefaultToolkit();
        Agent.agentmain(null, null);
        JTextArea area = new JTextArea();
        JTextField field = new JTextField();
        // Agent gắn Bridge trên một luồng riêng rồi qua luồng sự kiện: đợi tới khi file trạng thái có mặt.
        File state = new File(System.getProperty("user.home"),
                              "Library/GTV/state/" + ProcessHandle.current().pid());
        for (int i = 0; i < 100 && !state.exists(); i++) Thread.sleep(50);
        check("file trạng thái có mặt", state.exists(), true);
        EventQueue.invokeAndWait(() -> { });
        String record = new String(Files.readAllBytes(state.toPath()), StandardCharsets.US_ASCII);
        check("file trạng thái dài 64 byte", record.length(), 64);
        check("chưa ô nào giữ focus: phím đi thẳng", record.startsWith("GTVJ1 N 0 "), true);
        long start = Long.parseLong(record.trim().split(" ")[3]);
        long now = System.currentTimeMillis() / 1000;
        check("giờ khởi động tiến trình hợp lý", start > now - 600 && start <= now + 5, true);

        EventQueue.invokeAndWait(() -> area.setText("d"));
        post(area, "\u007f0\u007f1\u007fđ");
        check("thay chữ qua hàng đợi sự kiện", area.getText(), "đ");
        EventQueue.invokeAndWait(() -> area.replaceSelection("a"));
        post(area, "\u007f1\u007f1\u007fẳng");
        check("thay phần đuôi", area.getText(), "đẳng");
        check("con trỏ sau chữ", area.getCaretPosition(), 4);
        post(area, "\u007f\u007f\u007f ");
        check("chèn tại con trỏ", area.getText(), "đẳng ");
        post(area, "cấp");
        check("chữ của bộ gõ khác đi qua", area.getText(), "đẳng cấp");

        EventQueue.invokeAndWait(() -> field.setText("tuyet"));
        post(field, "\u007f3\u007f2\u007fệt");
        check("ô một dòng", field.getText(), "tuyệt");
        System.out.println(failures == 0 ? "mọi bài đều qua" : failures + " bài hỏng");
        System.exit(failures == 0 ? 0 : 1);
    }
}
