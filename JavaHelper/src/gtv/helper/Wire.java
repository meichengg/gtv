package gtv.helper;

/**
 * Phần đầu GTV ghi trước chữ gửi cho ô Java khi trong máy ảo có trợ thủ:
 *
 * <pre>  DEL [vị trí] DEL [độ dài] DEL chữ</pre>
 *
 * DEL là U+007F; vị trí và độ dài là số thập phân tính theo UTF-16 (đơn vị {@code char} của Java) trong văn bản của ô.
 * Bỏ trống vị trí: chèn tại con trỏ (đè lên vùng đang chọn nếu có). Chữ có thể rỗng (chỉ xoá vùng đó).
 *
 * <p>Chuỗi bắt đầu bằng DEL thì không bộ gõ nào khác gửi. GTV chỉ gửi dạng này khi file trạng thái của máy ảo cho biết
 * trợ thủ đang có mặt: không có trợ thủ thì ô Swing chỉ bỏ riêng ký tự DEL (DefaultKeyTypedAction bỏ ký tự điều khiển),
 * các chữ số của vị trí / độ dài và phần chữ vẫn vào văn bản — đừng dựa vào Swing làm lớp an toàn. Trợ thủ nuốt mọi
 * chuỗi chốt bắt đầu bằng DEL, kể cả khi phần đầu không đọc được ({@code Bridge.handle}).
 */
final class Wire {
    static final char MARK = '\u007f';
    /** Giới hạn cho vị trí / độ dài (tránh tràn số với chuỗi lạ). */
    private static final int MAX_DIGITS = 9;

    static final class Edit {
        /** -1: tại con trỏ. */
        final int location;
        final int length;
        final String text;

        Edit(int location, int length, String text) {
            this.location = location;
            this.length = length;
            this.text = text;
        }
    }

    private Wire() {}

    /** null nếu chuỗi không đúng dạng của GTV. */
    static Edit parse(String s) {
        if (s.isEmpty() || s.charAt(0) != MARK) return null;
        int second = s.indexOf(MARK, 1);
        if (second < 0) return null;
        int third = s.indexOf(MARK, second + 1);
        if (third < 0) return null;
        int location = number(s, 1, second);
        int length = number(s, second + 1, third);
        if (location == BAD || length == BAD) return null;
        if (length == EMPTY) length = 0;
        if (location == EMPTY) {
            if (length != 0) return null;
            location = -1;
        }
        return new Edit(location, length, s.substring(third + 1));
    }

    private static final int EMPTY = -1;
    private static final int BAD = -2;

    private static int number(String s, int from, int to) {
        if (from == to) return EMPTY;
        if (to - from > MAX_DIGITS) return BAD;
        int n = 0;
        for (int i = from; i < to; i++) {
            char c = s.charAt(i);
            if (c < '0' || c > '9') return BAD;
            n = n * 10 + (c - '0');
        }
        return n;
    }
}
