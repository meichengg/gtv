package gtv.helper;

import java.awt.AWTEvent;
import java.awt.Component;
import java.awt.EventQueue;
import java.awt.KeyboardFocusManager;
import java.awt.TextArea;
import java.awt.TextComponent;
import java.awt.Toolkit;
import java.awt.event.AWTEventListener;
import java.awt.event.InputMethodEvent;
import java.awt.font.TextHitInfo;
import java.beans.PropertyChangeEvent;
import java.beans.PropertyChangeListener;
import java.text.AttributedCharacterIterator;
import java.text.AttributedString;
import java.text.CharacterIterator;
import java.awt.Window;
import javax.swing.AbstractButton;
import javax.swing.JComboBox;
import javax.swing.JList;
import javax.swing.JMenuBar;
import javax.swing.JRootPane;
import javax.swing.JScrollBar;
import javax.swing.JScrollPane;
import javax.swing.JSlider;
import javax.swing.JSplitPane;
import javax.swing.JTabbedPane;
import javax.swing.JTable;
import javax.swing.JToolBar;
import javax.swing.JTree;
import javax.swing.event.DocumentEvent;
import javax.swing.event.DocumentListener;
import javax.swing.table.JTableHeader;
import javax.swing.text.Caret;
import javax.swing.text.Document;
import javax.swing.text.JTextComponent;

/**
 * Nhận lệnh thay chữ của bộ gõ GTV trong máy ảo Java chạy JDK gốc.
 *
 * <p>Bộ gõ gửi chữ bằng InputMethodKit ({@code insertText}); AWT của JDK gốc chuyển nguyên chuỗi đó thành một
 * {@link InputMethodEvent} đã chốt nhưng bỏ mất vùng cần thay. GTV vì thế ghi vùng cần thay vào đầu chuỗi (xem
 * {@link Wire}); lớp này đọc nó trên luồng sự kiện, trước khi ô nhập liệu thấy sự kiện:
 * <ol>
 * <li>chọn đúng vùng cần thay trong ô ({@code JTextComponent.select} — như {@code CInputMethod.selectRange} của JetBrains
 *     Runtime),</li>
 * <li>phát lại sự kiện đã chốt chỉ còn phần chữ: ô chèn nó đè lên vùng chọn theo đúng đường của chữ bộ gõ chốt.</li>
 * </ol>
 * Không có gì "đang soạn": không gạch chân, con trỏ đứng sau chữ, phím tắt và mũi tên tới ứng dụng như thường.
 *
 * <p>Sự kiện của bộ gõ khác (không mang phần đầu của GTV) đi qua nguyên vẹn.
 *
 * <p>{@link StateFile} cho GTV biết trợ thủ có mặt và ô đang giữ focus là loại gì ({@link #kind}).
 */
public final class Bridge implements AWTEventListener, PropertyChangeListener, Runnable {
    private static Bridge installed;

    private final StateFile state = new StateFile();
    private Component focus;
    private int serial;
    /** Loại ô vừa ghi cho bộ gõ (bài thử đọc). */
    char published;

    private Bridge() {}

    /** Cho bài thử: một bộ nhận không gắn vào AWT. */
    static Bridge detached() {
        return new Bridge();
    }

    /** Gắn vào AWT (một lần), trên luồng sự kiện. */
    public static synchronized void install() {
        if (installed != null) return;
        installed = new Bridge();
        EventQueue.invokeLater(installed);
    }

    @Override public void run() {
        try {
            Toolkit.getDefaultToolkit().addAWTEventListener(this, AWTEvent.INPUT_METHOD_EVENT_MASK);
            KeyboardFocusManager kfm = KeyboardFocusManager.getCurrentKeyboardFocusManager();
            kfm.addPropertyChangeListener("permanentFocusOwner", this);
            focus = kfm.getPermanentFocusOwner();
            watch(null, focus);
            state.open();
            publish();
        } catch (Throwable e) {
            // ứng dụng chạy như chưa có trợ thủ
        }
    }

    /**
     * Ô giữ focus đổi (kể cả giữa hai ô trong cùng cửa sổ: bộ gõ không thấy việc đó), hoặc ô đang giữ focus đổi sang sửa được
     * / chỉ đọc / tắt (nút Edit không lấy focus, ô tự mở khoá khi có dữ liệu): loại ô ghi cho bộ gõ phải theo kịp, không thì
     * ô vừa cho sửa vẫn bị coi là "không nhận chữ" tới lần đổi focus sau.
     */
    @Override public void propertyChange(PropertyChangeEvent event) {
        try {
            if (!"permanentFocusOwner".equals(event.getPropertyName())) {
                if (event.getSource() == focus) publish();
                return;
            }
            Object now = event.getNewValue();
            Component next = now instanceof Component ? (Component) now : null;
            if (next == focus) return;
            watch(focus, next);
            focus = next;
            serial++;
            publish();
        } catch (Throwable e) {
            // bỏ qua
        }
    }

    private void watch(Component old, Component next) {
        for (String property : new String[] {"editable", "enabled"}) {
            if (old != null) old.removePropertyChangeListener(property, this);
            if (next != null) next.addPropertyChangeListener(property, this);
        }
    }

    private void publish() {
        published = kind(focus);
        state.write(published, serial);
    }

    /**
     * Ô đang giữ focus là loại gì với bộ gõ:
     * D — ô văn bản Swing / AWT đang cho sửa: thay chữ trực tiếp;
     * N — không nhận chữ (bảng, cây, danh sách, nút, tab, ô văn bản chỉ đọc, không ô nào): phím ở đó là lệnh của ứng dụng,
     *     bộ gõ để phím đi thẳng — soạn từ ở đó chỉ làm AWT nuốt phím và hiện cửa sổ soạn nổi;
     * C — còn lại (ô tự vẽ của ứng dụng): bộ gõ soạn từng từ như khi không có trợ thủ.
     */
    static char kind(Object c) {
        if (editableText(c)) return 'D';
        if (c == null || c instanceof JTextComponent || c instanceof TextComponent) return 'N';
        if (c instanceof Component && ((Component) c).getInputMethodRequests() != null) return 'C';
        if (c instanceof JTable || c instanceof JTree || c instanceof JList || c instanceof AbstractButton
                || c instanceof JTabbedPane || c instanceof JRootPane || c instanceof Window || c instanceof JComboBox
                || c instanceof JScrollBar || c instanceof JSlider || c instanceof JMenuBar || c instanceof JSplitPane
                || c instanceof JToolBar || c instanceof JTableHeader || c instanceof JScrollPane) {
            return 'N';
        }
        return 'C';
    }

    /** Ô văn bản Swing / AWT đang cho sửa: thay chữ trực tiếp được. */
    static boolean editableText(Object c) {
        if (c instanceof JTextComponent) {
            JTextComponent t = (JTextComponent) c;
            return t.isEditable() && t.isEnabled();
        }
        if (c instanceof TextComponent) {
            TextComponent t = (TextComponent) c;
            return t.isEditable() && t.isEnabled();
        }
        return false;
    }

    @Override public void eventDispatched(AWTEvent event) {
        try {
            if (event instanceof InputMethodEvent) handle((InputMethodEvent) event);
        } catch (Throwable e) {
            // bỏ qua: không bao giờ làm hỏng luồng sự kiện của ứng dụng
        }
    }

    private void handle(InputMethodEvent e) {
        if (e.getID() != InputMethodEvent.INPUT_METHOD_TEXT_CHANGED || e.isConsumed()) return;
        AttributedCharacterIterator it = e.getText();
        int committed = e.getCommittedCharacterCount();
        if (it == null || committed <= 0 || it.first() != Wire.MARK) return;
        StringBuilder b = new StringBuilder(committed);
        for (char c = it.first(); c != CharacterIterator.DONE && b.length() < committed; c = it.next()) b.append(c);
        Wire.Edit edit = Wire.parse(b.toString());
        // Chuỗi mang phần đầu của GTV không bao giờ được tới ô nhập liệu nguyên văn — kể cả khi phần đầu hỏng (Swing chỉ bỏ
        // ký tự DEL, các chữ số của vị trí / độ dài sẽ thành chữ trong văn bản).
        e.consume();
        if (edit == null) return;
        Object source = e.getSource();
        if (source instanceof Component) apply((Component) source, edit);
    }

    static void apply(Component target, Wire.Edit edit) {
        if (target instanceof JTextComponent) {
            applySwing((JTextComponent) target, edit);
            return;
        }
        if (target instanceof TextComponent) {
            TextComponent t = (TextComponent) target;
            if (!t.isEditable() || !t.isEnabled()) return;
            if (edit.location >= 0) t.select(edit.location, edit.location + edit.length);
            if (edit.text.isEmpty()) {
                // Chỉ xoá: ô AWT thuần không có "thay vùng chọn bằng chuỗi rỗng" qua sự kiện của bộ gõ.
                int from = t.getSelectionStart(), to = t.getSelectionEnd();
                if (from == to) return;
                if (t instanceof TextArea) {
                    ((TextArea) t).replaceRange("", from, to);
                } else {
                    String text = t.getText();
                    t.setText(text.substring(0, from) + text.substring(to));
                }
                t.setCaretPosition(from);
                return;
            }
        }
        // Ô khác (tự vẽ): không chọn được vùng cần thay — ít nhất chữ tới nơi, không kèm phần đầu.
        if (edit.text.isEmpty()) return;
        commit(target, edit.text);
    }

    private static void commit(Component target, String text) {
        TextHitInfo caret = TextHitInfo.afterOffset(text.length() - 1);
        target.dispatchEvent(new InputMethodEvent(target, InputMethodEvent.INPUT_METHOD_TEXT_CHANGED,
                                                  new AttributedString(text).getIterator(), text.length(), caret, caret));
    }

    /**
     * Ô văn bản Swing: chọn vùng cần thay rồi để chính ô chèn chữ đè lên. Ô từ chối lần sửa (DocumentFilter chỉ nhận số /
     * hex, KeyListener nuốt chữ ngoài ASCII, JFormattedTextField…) thì văn bản không đổi nhưng vùng vừa chọn còn nguyên —
     * phím kế tiếp của người dùng sẽ thay mất nó ("be" + ê bị từ chối + f → "bf"): trả con trỏ / vùng chọn về như trước.
     */
    private static void applySwing(JTextComponent t, Wire.Edit edit) {
        if (!t.isEditable() || !t.isEnabled()) return;
        Caret caret = t.getCaret();
        int dot = caret == null ? -1 : caret.getDot(), mark = caret == null ? -1 : caret.getMark();
        boolean selected = false;
        if (edit.location >= 0) {
            int end = t.getDocument().getLength();
            int from = Math.min(edit.location, end);
            int to = Math.min(edit.location + edit.length, end);
            if (t.getSelectionStart() != from || t.getSelectionEnd() != to) {
                t.select(from, to);
                selected = true;
            }
        }
        final boolean[] changed = {false};
        DocumentListener listener = new DocumentListener() {
            @Override public void insertUpdate(DocumentEvent e) { changed[0] = true; }
            @Override public void removeUpdate(DocumentEvent e) { changed[0] = true; }
            @Override public void changedUpdate(DocumentEvent e) { changed[0] = true; }
        };
        Document document = t.getDocument();
        document.addDocumentListener(listener);
        try {
            if (edit.text.isEmpty()) {
                if (t.getSelectionStart() != t.getSelectionEnd()) t.replaceSelection("");
            } else {
                commit(t, edit.text);
            }
        } finally {
            document.removeDocumentListener(listener);
            if (selected && !changed[0] && caret != null && t.getDocument() == document) {
                int end = document.getLength();
                if (mark >= 0 && mark <= end && dot >= 0 && dot <= end) {
                    caret.setDot(mark);
                    if (dot != mark) caret.moveDot(dot);
                }
            }
        }
    }
}
