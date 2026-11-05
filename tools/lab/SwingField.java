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

public class SwingField {
    static void write(Path p, String s) {
        try {
            Files.write(p, s.getBytes(StandardCharsets.UTF_8));
        } catch (Exception e) {
            e.printStackTrace();
        }
    }

    public static void main(String[] args) throws Exception {
        Path out = Paths.get(args[0]);
        Path ready = Paths.get(args[0] + ".ready");
        // Lab tạo file này để xoá chữ trong ô (không dùng phím tắt: đó cũng là thứ cần kiểm tra).
        Path clear = Paths.get(args[0] + ".clear");
        SwingUtilities.invokeAndWait(() -> {
            JFrame frame = new JFrame("GTV Lab Swing");
            JTextArea area = new JTextArea(6, 40);
            area.setFont(area.getFont().deriveFont(18f));
            area.getDocument().addDocumentListener(new DocumentListener() {
                void dump() { write(out, area.getText()); }
                public void insertUpdate(DocumentEvent e) { dump(); }
                public void removeUpdate(DocumentEvent e) { dump(); }
                public void changedUpdate(DocumentEvent e) { dump(); }
            });
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
