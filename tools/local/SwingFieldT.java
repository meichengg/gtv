// Ô nhập liệu Java Swing (JTextArea) cho IME Lab — chỉ chạy trên máy ảo CI.
//   java SwingField.java <file>: ghi nội dung ô ra <file> mỗi khi đổi (cả lúc đang có marked text); <file>.ready khi ô có
//   focus. Ứng dụng Java (Burp Suite, IntelliJ…) bỏ qua cách thay chữ trực tiếp của GTV: GTV phải nhận ra và gõ bằng marked
//   text (JavaDetector).
import java.awt.Desktop;
import java.awt.event.WindowAdapter;
import java.awt.event.WindowEvent;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import javax.swing.JFrame;
import javax.swing.JScrollPane;
import javax.swing.JTextArea;
import javax.swing.SwingUtilities;
import javax.swing.event.DocumentEvent;
import javax.swing.event.DocumentListener;

public class SwingFieldT {
    static void write(Path p, String s) {
        try {
            Files.write(p, s.getBytes(StandardCharsets.UTF_8));
        } catch (Exception e) {
            e.printStackTrace();
        }
    }

    static synchronized void append(Path p, String line) {
        try {
            Files.write(p, (System.nanoTime() / 1000000 + " " + line + "\n").getBytes(StandardCharsets.UTF_8),
                        java.nio.file.StandardOpenOption.CREATE, java.nio.file.StandardOpenOption.APPEND);
        } catch (Exception e) {
            e.printStackTrace();
        }
    }

    public static void main(String[] args) throws Exception {
        Path out = Paths.get(args[0]);
        Path ready = Paths.get(args[0] + ".ready");
        // Lab tạo file này để xoá chữ trong ô (không dùng phím tắt: đó cũng là thứ cần kiểm tra).
        Path clear = Paths.get(args[0] + ".clear");
        // Nhật ký sự kiện Java nhận (phím, bộ gõ) để biết phím nào tới / bị nuốt.
        Path events = Paths.get(args[0] + ".events");
        SwingUtilities.invokeAndWait(() -> {
            JFrame frame = new JFrame("GTV Local Swing");
            JTextArea area = new JTextArea(6, 40);
            area.setFont(area.getFont().deriveFont(18f));
            area.getDocument().addDocumentListener(new DocumentListener() {
                void dump() {
                    write(out, area.getText());
                    append(Paths.get(args[0] + ".timeline"), area.getText().replace("\n", "\\n") + "\u0001" + area.getCaretPosition()
                        + "\u0001" + (area.getInputContext() != null ? "ic" : "-"));
                }
                public void insertUpdate(DocumentEvent e) { dump(); }
                public void removeUpdate(DocumentEvent e) { dump(); }
                public void changedUpdate(DocumentEvent e) { dump(); }
            });
            area.addKeyListener(new java.awt.event.KeyAdapter() {
                void log(String kind, java.awt.event.KeyEvent e) {
                    append(events, kind + " code=" + e.getKeyCode() + " char=" + (int) e.getKeyChar()
                        + " mods=" + e.getModifiersEx() + " caret=" + area.getCaretPosition());
                }
                @Override public void keyPressed(java.awt.event.KeyEvent e) { log("P", e); }
                @Override public void keyTyped(java.awt.event.KeyEvent e) { log("T", e); }
            });
            area.addInputMethodListener(new java.awt.event.InputMethodListener() {
                @Override public void inputMethodTextChanged(java.awt.event.InputMethodEvent e) {
                    StringBuilder b = new StringBuilder();
                    java.text.AttributedCharacterIterator it = e.getText();
                    if (it != null) for (char c = it.first(); c != java.text.CharacterIterator.DONE; c = it.next()) b.append(c);
                    append(events, "IM committed=" + e.getCommittedCharacterCount() + " text=" + b);
                }
                @Override public void caretPositionChanged(java.awt.event.InputMethodEvent e) { }
            });
            // Mọi KeyEvent / InputMethodEvent AWT nhận (trước khi tới ô): phân biệt "phím không được phát" với "phím bị nuốt
            // trong Java".
            java.awt.Toolkit.getDefaultToolkit().addAWTEventListener(e -> {
                if (e instanceof java.awt.event.KeyEvent) {
                    java.awt.event.KeyEvent k = (java.awt.event.KeyEvent) e;
                    append(events, "AWT key id=" + k.getID() + " code=" + k.getKeyCode() + " char=" + (int) k.getKeyChar()
                        + " consumed=" + k.isConsumed());
                } else if (e instanceof java.awt.event.InputMethodEvent) {
                    java.awt.event.InputMethodEvent m = (java.awt.event.InputMethodEvent) e;
                    append(events, "AWT im id=" + m.getID() + " committed=" + m.getCommittedCharacterCount());
                }
            }, java.awt.AWTEvent.KEY_EVENT_MASK | java.awt.AWTEvent.INPUT_METHOD_EVENT_MASK);
            frame.add(new JScrollPane(area));
            frame.setDefaultCloseOperation(JFrame.EXIT_ON_CLOSE);
            frame.addWindowFocusListener(new WindowAdapter() {
                @Override public void windowGainedFocus(WindowEvent e) {
                    area.requestFocusInWindow();
                    write(ready, "ready");
                }
                @Override public void windowLostFocus(WindowEvent e) {
                    try { Files.deleteIfExists(ready); } catch (Exception ex) { ex.printStackTrace(); }
                }
            });
            new javax.swing.Timer(50, e -> {
                if (Files.exists(clear)) {
                    try { Files.deleteIfExists(clear); } catch (Exception ex) { ex.printStackTrace(); }
                    area.setText("");
                    write(out, "");
                }
            }).start();
            frame.pack();
            frame.setLocation(240, 360);
            write(out, "");
            frame.setVisible(true);
            frame.toFront();
            area.requestFocusInWindow();
            try {
                Desktop.getDesktop().requestForeground(true);
            } catch (Exception e) {
                e.printStackTrace();
            }
        });
    }
}
