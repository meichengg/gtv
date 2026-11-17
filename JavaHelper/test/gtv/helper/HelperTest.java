package gtv.helper;

import java.awt.event.InputMethodEvent;
import java.awt.font.TextAttribute;
import java.awt.font.TextHitInfo;
import java.awt.im.InputMethodHighlight;
import java.nio.charset.StandardCharsets;
import java.text.AttributedString;
import javax.swing.JTextArea;
import javax.swing.JTextField;
import javax.swing.JTextPane;
import javax.swing.SwingUtilities;
import javax.swing.text.JTextComponent;

/**
 * Bài thử của trợ thủ, chạy không cần màn hình (-Djava.awt.headless=true): JavaHelper/test.sh.
 * Mỗi bài đưa cho bộ nhận đúng InputMethodEvent mà AWT của JDK gốc tạo ra từ chuỗi bộ gõ gửi, rồi xem ô văn bản.
 */
public final class HelperTest {
    private static int failures;
    private static final Bridge bridge = Bridge.detached();

    public static void main(String[] args) throws Exception {
        SwingUtilities.invokeAndWait(HelperTest::run);
        if (failures > 0) {
            System.out.println(failures + " bài hỏng");
            System.exit(1);
        }
        System.out.println("mọi bài đều qua");
    }

    private static void check(String name, Object got, Object want) {
        if (!String.valueOf(got).equals(String.valueOf(want))) {
            failures++;
            System.out.println("HỎNG " + name + ": được " + got + ", cần " + want);
        } else {
            System.out.println("ok   " + name);
        }
    }

    private static String wire(int location, int length, String text) {
        return "\u007f" + (location < 0 ? "" : Integer.toString(location)) + "\u007f" + length + "\u007f" + text;
    }

    /** Như AWT: bộ nhận xem sự kiện trước; ô chỉ xử lý nếu chưa ai dùng nó. */
    private static void deliver(JTextComponent c, InputMethodEvent e) {
        bridge.eventDispatched(e);
        c.dispatchEvent(e);
    }

    /** Chuỗi bộ gõ chốt (`insertText`), như CInputMethod.insertText. */
    private static void commit(JTextComponent c, String s) {
        TextHitInfo caret = TextHitInfo.afterOffset(s.length() - 1);
        deliver(c, new InputMethodEvent(c, InputMethodEvent.INPUT_METHOD_TEXT_CHANGED, new AttributedString(s).getIterator(),
                                        s.length(), caret, caret));
    }

    /** Phần đang soạn (`setMarkedText`), như CInputMethod.dispatchText: có INPUT_METHOD_HIGHLIGHT. */
    private static void compose(JTextComponent c, String s) {
        AttributedString a = new AttributedString(s);
        if (!s.isEmpty()) {
            a.addAttribute(TextAttribute.INPUT_METHOD_HIGHLIGHT, InputMethodHighlight.UNSELECTED_RAW_TEXT_HIGHLIGHT);
        }
        deliver(c, new InputMethodEvent(c, InputMethodEvent.INPUT_METHOD_TEXT_CHANGED, a.getIterator(), 0,
                                        TextHitInfo.beforeOffset(s.length()), TextHitInfo.beforeOffset(0)));
    }

    /** Phím đi thẳng: Swing chèn ký tự tại con trỏ. */
    private static void type(JTextComponent c, String s) {
        c.replaceSelection(s);
    }

    private static void run() {
        wireFormat();
        for (JTextComponent c : new JTextComponent[] { new JTextArea(), new JTextField(), new JTextPane() }) {
            String kind = c.getClass().getSimpleName();
            words(c, kind);
            middle(c, kind);
            selection(c, kind);
            atCaret(c, kind);
            deletion(c, kind);
            outOfRange(c, kind);
            foreign(c, kind);
            readOnly(c, kind);
        }
        stateRecord();
    }

    private static void wireFormat() {
        Wire.Edit e = Wire.parse(wire(12, 3, "đẳng"));
        check("wire: vị trí", e.location, 12);
        check("wire: độ dài", e.length, 3);
        check("wire: chữ", e.text, "đẳng");
        e = Wire.parse(wire(-1, 0, "ư"));
        check("wire: tại con trỏ", e.location + "/" + e.length + "/" + e.text, "-1/0/ư");
        e = Wire.parse(wire(5, 2, ""));
        check("wire: chỉ xoá", e.location + "/" + e.length + "/" + e.text.length(), "5/2/0");
        check("wire: chữ thường", Wire.parse("đẳng"), null);
        check("wire: thiếu dấu ngăn", Wire.parse("\u007f12\u007f3"), null);
        check("wire: không phải số", Wire.parse("\u007fa\u007f3\u007fx"), null);
        check("wire: số quá dài", Wire.parse("\u007f1234567890\u007f3\u007fx"), null);
        check("wire: có độ dài mà không có vị trí", Wire.parse("\u007f\u007f3\u007fx"), null);
    }

    /** "d9a38ng " gõ kiểu VNI: mỗi phím dấu là một lần thay phần đuôi của từ. */
    private static void words(JTextComponent c, String kind) {
        c.setText("");
        type(c, "d");
        commit(c, wire(0, 1, "đ"));
        type(c, "a");
        commit(c, wire(1, 1, "ả"));
        commit(c, wire(1, 1, "ẳ"));
        type(c, "n");
        type(c, "g");
        type(c, " ");
        check(kind + ": đẳng", c.getText(), "đẳng ");
        check(kind + ": con trỏ sau chữ", c.getCaretPosition(), 5);
        type(c, "c");
        type(c, "a");
        commit(c, wire(6, 1, "â"));
        type(c, "p");
        commit(c, wire(6, 2, "ấp"));
        check(kind + ": đẳng cấp", c.getText(), "đẳng cấp");
        check(kind + ": con trỏ cuối", c.getCaretPosition(), 8);
        check(kind + ": không còn vùng chọn", c.getSelectionStart() == c.getSelectionEnd(), true);
    }

    /** Sửa một từ nằm giữa văn bản: chữ phía sau giữ nguyên. */
    private static void middle(JTextComponent c, String kind) {
        c.setText("GET /toan HTTP/1.1");
        c.setCaretPosition(9);
        commit(c, wire(6, 3, "oán"));
        check(kind + ": giữa văn bản", c.getText(), "GET /toán HTTP/1.1");
        check(kind + ": con trỏ giữa văn bản", c.getCaretPosition(), 9);
    }

    /** Vùng đang bôi đen sau từ cũng bị thay (GTV gộp nó vào vùng cần thay). */
    private static void selection(JTextComponent c, String kind) {
        c.setText("abcXYZ");
        c.select(3, 6);
        commit(c, wire(2, 4, "ô"));
        check(kind + ": thay cả vùng chọn", c.getText(), "abô");
    }

    private static void atCaret(JTextComponent c, String kind) {
        c.setText("nh");
        c.setCaretPosition(2);
        commit(c, wire(-1, 0, "ư"));
        check(kind + ": chèn tại con trỏ", c.getText(), "như");
        c.select(0, 3);
        commit(c, wire(-1, 0, "ơ"));
        check(kind + ": chèn đè vùng chọn", c.getText(), "ơ");
    }

    private static void deletion(JTextComponent c, String kind) {
        c.setText("hoàn");
        c.setCaretPosition(4);
        commit(c, wire(1, 3, ""));
        check(kind + ": chỉ xoá", c.getText(), "h");
        check(kind + ": con trỏ sau khi xoá", c.getCaretPosition(), 1);
    }

    /** Vị trí vượt quá văn bản (ô vừa bị ứng dụng đổi): cắt vào trong, không ném lỗi. */
    private static void outOfRange(JTextComponent c, String kind) {
        c.setText("ab");
        commit(c, wire(10, 4, "x"));
        check(kind + ": vị trí ngoài văn bản", c.getText(), "abx");
    }

    /** Bộ gõ khác (soạn từng từ rồi chốt, như tiếng Nhật) không bị đụng tới. */
    private static void foreign(JTextComponent c, String kind) {
        c.setText("");
        compose(c, "v");
        compose(c, "vi");
        check(kind + ": đang soạn hiện trong ô", c.getText(), "vi");
        commit(c, "việt");
        check(kind + ": chốt phần đang soạn", c.getText(), "việt");
        commit(c, "!");
        check(kind + ": chốt chữ thường", c.getText(), "việt!");
    }

    private static void readOnly(JTextComponent c, String kind) {
        c.setText("abc");
        c.setEditable(false);
        commit(c, wire(0, 3, "x"));
        check(kind + ": ô chỉ đọc", c.getText(), "abc");
        check(kind + ": ô chỉ đọc không phải ô gõ thẳng", Bridge.editableText(c), false);
        c.setEditable(true);
        check(kind + ": ô sửa được là ô gõ thẳng", Bridge.editableText(c), true);
    }

    private static void stateRecord() {
        byte[] r = StateFile.record(true, 42, 1794900000L);
        check("bản ghi: 64 byte", r.length, 64);
        check("bản ghi: nội dung", new String(r, StandardCharsets.US_ASCII).trim(), "GTVJ1 D 42 1794900000");
        check("bản ghi: xuống dòng cuối", r[63], (byte) '\n');
        check("bản ghi: ô khác", new String(StateFile.record(false, 0, 0), StandardCharsets.US_ASCII).trim(), "GTVJ1 C 0 0");
    }
}
