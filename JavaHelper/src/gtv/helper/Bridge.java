package gtv.helper;

import java.awt.AWTEvent;
import java.awt.Component;
import java.awt.EventQueue;
import java.awt.KeyboardFocusManager;
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
 * <p>{@link StateFile} cho GTV biết trợ thủ có mặt và ô đang giữ focus có phải ô văn bản sửa được không.
 */
public final class Bridge implements AWTEventListener, PropertyChangeListener, Runnable {
    private static Bridge installed;

    private final StateFile state = new StateFile();
    private Component focus;
    private int serial;

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
            state.open();
            publish();
        } catch (Throwable e) {
            // ứng dụng chạy như chưa có trợ thủ
        }
    }

    /** Ô giữ focus đổi (kể cả giữa hai ô trong cùng cửa sổ: bộ gõ không thấy việc đó). */
    @Override public void propertyChange(PropertyChangeEvent event) {
        try {
            Object now = event.getNewValue();
            Component next = now instanceof Component ? (Component) now : null;
            if (next == focus) return;
            focus = next;
            serial++;
            publish();
        } catch (Throwable e) {
            // bỏ qua
        }
    }

    private void publish() {
        state.write(editableText(focus), serial);
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
        if (edit == null) return;
        // Chuỗi mang phần đầu của GTV không bao giờ được tới ô nhập liệu nguyên văn.
        e.consume();
        Object source = e.getSource();
        if (source instanceof Component) apply((Component) source, edit);
    }

    static void apply(Component target, Wire.Edit edit) {
        if (target instanceof JTextComponent) {
            JTextComponent t = (JTextComponent) target;
            if (!t.isEditable() || !t.isEnabled()) return;
            if (edit.location >= 0) {
                int end = t.getDocument().getLength();
                int from = Math.min(edit.location, end);
                int to = Math.min(edit.location + edit.length, end);
                if (t.getSelectionStart() != from || t.getSelectionEnd() != to) t.select(from, to);
            }
            if (edit.text.isEmpty()) {
                if (t.getSelectionStart() != t.getSelectionEnd()) t.replaceSelection("");
                return;
            }
        } else if (target instanceof TextComponent) {
            TextComponent t = (TextComponent) target;
            if (!t.isEditable() || !t.isEnabled()) return;
            if (edit.location >= 0) t.select(edit.location, edit.location + edit.length);
        }
        // Ô khác (tự vẽ): không chọn được vùng cần thay — ít nhất chữ tới nơi, không kèm phần đầu.
        if (edit.text.isEmpty()) return;
        TextHitInfo caret = TextHitInfo.afterOffset(edit.text.length() - 1);
        target.dispatchEvent(new InputMethodEvent(target, InputMethodEvent.INPUT_METHOD_TEXT_CHANGED,
                                                  new AttributedString(edit.text).getIterator(), edit.text.length(),
                                                  caret, caret));
    }
}
