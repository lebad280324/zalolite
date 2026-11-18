# Trợ lý AI: hỏi AI về tin nhắn Zalo

Zalolite có thể cho trợ lý AI trên máy Mac của bạn (Codex, Claude Code, Claude Desktop) **đọc những hội thoại
bạn chọn**. Sau đó bạn hỏi ngay trong trợ lý, ví dụ:

> Đọc tin nhắn nhóm Kinh doanh 3 ngày qua, liệt kê những việc tôi đã nhận nhưng chưa hoàn thành.

Zalolite không cần API key, không cần tài khoản AI riêng. Trợ lý bạn đang dùng lo phần suy nghĩ; Zalolite chỉ
cung cấp tin nhắn của các hội thoại được phép.

## An toàn và quyền riêng tư

- **Tắt theo mặc định.** Không có gì được đọc cho tới khi bạn bật và chọn hội thoại.
- **Chỉ những hội thoại bạn chọn.** Hội thoại khác luôn bị từ chối, kể cả khi trợ lý biết mã của nó.
- **Chỉ đọc.** Trợ lý không gửi, xóa hay sửa được tin nhắn, không dùng phiên đăng nhập Zalo và không kết nối mạng
  qua Zalolite. Nó chỉ đọc lịch sử đã lưu trên máy.
- **Tắt là dừng ngay.** Tắt công tắc, bỏ chọn hội thoại hoặc đăng xuất thì mọi yêu cầu sau đó đều bị từ chối.
- **Nội dung rời khỏi máy khi bạn hỏi.** Phần tin nhắn trợ lý đọc được gửi tới dịch vụ AI (OpenAI, Anthropic…)
  để phân tích, theo điều khoản của dịch vụ đó. Chỉ chia sẻ những hội thoại bạn chấp nhận điều này.

## Bạn cần

- Zalolite **0.0.15** trở lên, đặt trong thư mục **Applications** (đường dẫn kết nối trỏ tới đó; nếu sau này
  chuyển app sang chỗ khác thì làm lại bước 2).
- Một trong các trợ lý: **Codex** (app hoặc dòng lệnh), **Claude Code** hoặc **Claude Desktop**.

## Bước 1: Bật chia sẻ và chọn hội thoại

1. Mở Zalolite → **Cài đặt** (⌘,) → **Trợ lý AI**.
2. Bật **Cho phép trợ lý AI đọc hội thoại được chọn**.
3. Bấm **Chọn hội thoại…**, tìm và đánh dấu các nhóm hoặc người bạn muốn trợ lý theo dõi, rồi bấm **Xong**.

Cũng có thể nhấp chuột phải vào một hội thoại trong danh sách → **Chia sẻ với trợ lý AI**.

## Bước 2: Kết nối trợ lý

Trong **Cài đặt → Trợ lý AI → Kết nối với trợ lý**, mở **Lệnh kết nối thủ công**. Mỗi dòng có nút **Chép** với
đúng đường dẫn của máy bạn. Chọn cách ứng với trợ lý bạn dùng:

**Codex (app)**

1. Bấm **Chép** ở dòng *Codex (app)*.
2. Mở file cấu hình của Codex: trong Terminal chạy `open -e ~/.codex/config.toml`
   (nếu chưa có file, tạo bằng `mkdir -p ~/.codex && touch ~/.codex/config.toml` rồi mở lại).
3. Dán đoạn vừa chép vào **cuối file**, lưu lại.

Đoạn này có dạng:

```toml
[mcp_servers.zalolite]
command = "/Applications/Zalolite.app/Contents/Helpers/ctdozlite-core"
args = [ "--mcp", "--data-dir", "/Users/<tên-bạn>/Library/Application Support/ctdozlite-native" ]
startup_timeout_sec = 15
```

**Codex (dòng lệnh)** hoặc **Claude Code**: bấm **Chép** ở dòng tương ứng, dán vào Terminal và nhấn Return.

**Claude Desktop**: mở Claude → **Settings → Developer → Edit Config**, đưa mục `zalolite` trong đoạn vừa chép vào
phần `mcpServers` của file (giữ nguyên các mục khác), lưu lại.

Quay lại trang Trợ lý AI trong Zalolite: dòng của trợ lý vừa kết nối sẽ hiện **Đã kết nối**.

## Bước 3: Mở lại trợ lý và hỏi

Thoát hẳn trợ lý rồi mở lại để nó nạp `zalolite`. Lần đầu, trợ lý có thể hỏi bạn cho phép dùng công cụ
`zalolite`; hãy cho phép.

Một vài câu hỏi mẫu:

- *Dùng zalolite, liệt kê các hội thoại được chia sẻ.*
- *Đọc tin nhắn nhóm Kinh doanh 3 ngày qua, liệt kê những việc tôi đã nhận nhưng chưa hoàn thành.*
- *Tóm tắt những gì trưởng nhóm gửi trong nhóm Dự án từ thứ Hai đến hôm nay.*
- *Tìm các tin có chữ "báo giá" trong tuần này và cho biết ai đang chờ tôi trả lời.*

Trợ lý có ba công cụ: liệt kê hội thoại được chia sẻ, đọc tin theo khoảng thời gian, và tìm theo từ khóa.
Trợ lý chỉ đọc tin nhắn chữ đã lưu trong Zalolite; nội dung bên trong tệp đính kèm (PDF, Word…) không đọc được.

## Khi gặp lỗi

| Trợ lý báo | Cách xử lý |
| :--- | :--- |
| *Zalolite chưa bật chia sẻ với trợ lý AI* | Làm lại bước 1. |
| *Chưa có hội thoại nào được chia sẻ* | Bấm **Chọn hội thoại…** và chọn ít nhất một hội thoại. |
| *Hội thoại này chưa được chia sẻ* | Hội thoại đó chưa nằm trong danh sách; thêm nó ở bước 1 nếu muốn. |
| Không thấy công cụ `zalolite` | Kiểm tra đoạn cấu hình đã lưu, rồi thoát hẳn và mở lại trợ lý. |
| Lỗi không tìm thấy chương trình | Zalolite đã bị chuyển chỗ; chép lại cấu hình ở bước 2 và thay đoạn cũ. |
| Thiếu tin gần đây | Mở Zalolite để nó tải tin mới; trợ lý chỉ đọc những gì Zalolite đã lưu. |

## Ngừng sử dụng

- **Tạm dừng:** tắt công tắc trong **Cài đặt → Trợ lý AI**. Trợ lý vẫn còn mục `zalolite` nhưng mọi yêu cầu bị
  từ chối.
- **Gỡ hẳn:** xóa mục `[mcp_servers.zalolite]` trong `~/.codex/config.toml`, chạy `claude mcp remove zalolite`,
  hoặc xóa mục `zalolite` trong cấu hình Claude Desktop.
