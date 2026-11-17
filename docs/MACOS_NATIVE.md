# Giao diện macOS bằng SwiftUI/AppKit

Ứng dụng `ctdozlite Native` dùng giao diện SwiftUI/AppKit và một worker Rust riêng
để kết nối Zalo. Giao diện gửi lệnh, nhận kết quả và hiển thị dữ liệu; session,
mã hóa, HTTP/WebSocket và SQLite vẫn do Rust xử lý.

Bản native được xây dựng riêng với bản egui hiện có. Gói này có định danh ứng
dụng riêng, không tự thay `/Applications/ctdozlite.app` và không dùng trình cập
nhật của bản egui. Từ v0.0.12, gói phát hành là bản Universal chạy trên cả Mac Apple Silicon
và Mac Intel (macOS 14 trở lên); macOS tự chọn mã máy đúng với chip khi mở ứng dụng.

## Xây dựng và mở ứng dụng

Cần Rust, Xcode Command Line Tools và macOS 14 trở lên để xây dựng frontend.
Môi trường được kiểm tra trong đợt triển khai này là macOS 27 trên Apple Silicon; phần Intel được
chạy thử qua Rosetta. Bản Universal cần thêm target Rust `x86_64-apple-darwin`
(`rustup target add x86_64-apple-darwin`); `--host-arch` chỉ build cho chip của máy đang dùng, nhanh hơn khi phát triển.

```sh
bash packaging/package-native-macos.sh --debug
open -n "dist/Zalolite.app" --args --demo
```

Chế độ `--demo` dùng dữ liệu mẫu, không đọc session, cơ sở dữ liệu hay kết nối
tài khoản Zalo thật. Dùng chế độ này để xem giao diện và thử vòng đời cầu nối.

Để xây dựng bản tối ưu, bỏ `--debug`. Để chỉ đóng gói lại các binary đã xây dựng,
thêm `--no-build`. Gói mặc định chứa các helper native hiện có; tùy chọn
`--without-legacy-helpers` dành cho vòng kiểm tra giao diện nhanh và không thích
hợp để kiểm tra những tác vụ cần helper.

Mở ứng dụng bình thường để đăng nhập QR. Thư mục dữ liệu mặc định của bản native
tách khỏi bản egui. Không mở hai frontend cùng sử dụng một thư mục dữ liệu: mỗi
worker phải sở hữu session và store của nó.

## Ranh giới giữa Swift và Rust

Swift khởi chạy binary `Contents/Helpers/ctdozlite-core` bằng `Process`, truyền
đường dẫn dữ liệu bằng đối số riêng và giao tiếp qua pipe stdin/stdout. Không có
máy chủ HTTP cục bộ hay cổng mạng cho cầu nối này. stdout chỉ chứa JSON Lines;
chẩn đoán chạy qua stderr và không được dùng để hiển thị phản hồi thô của Zalo.

- Lệnh có `id` và `command` cùng các tham số có kiểu xác định.
- Kết quả cuối có `event: "result"`, `id`, `command`, `ok` và `data` hoặc lỗi an toàn.
- Sự kiện độc lập cập nhật session công khai, hội thoại, tin nhắn, QR và trạng thái.
- Sự kiện `ready` công bố phiên bản cầu nối và các khả năng đã triển khai.
- Session key, cookie, IMEI và mật khẩu không đi qua cầu nối.
- Thao tác mạng, SQLite, tệp và khởi chạy worker không chạy trên UI thread.
- Khi worker đóng hoặc không phản hồi, giao diện phải kết thúc trạng thái chờ
  và cho phép kết nối lại; không được báo gửi thành công trước kết quả của Rust.

Ví dụ lệnh yêu cầu nạp dữ liệu:

```json
{"id":"request-1","command":"bootstrap"}
```

Ví dụ kết quả:

```json
{"id":"request-1","event":"result","command":"bootstrap","ok":true,"data":{}}
```

## Phạm vi chuyển đổi và xác minh

Bản hiện tại có giao diện native cho đăng nhập QR, hội thoại, tin nhắn, ảnh/tệp,
trích dẫn, cảm xúc, thu hồi/xóa, chuyển tiếp, nhãn dán, hẹn giờ và nhập lịch sử.
Cuộc gọi thoại/video, đồng bộ từ điện thoại, nhật ký, chuyển đổi nhiều tài khoản,
proxy và tự cập nhật chưa có giao diện native tương đương bản egui. Không dùng
bản này thay hoàn toàn bản đang làm việc nếu cần các chức năng đó.

Khả năng kết nối thật phụ thuộc session và phản hồi từ Zalo. Build thành công,
test dữ liệu mẫu và ảnh giao diện không chứng minh các luồng Zalo thật đã được
xác minh. Từng tính năng native chỉ được bật khi worker công bố hỗ trợ; các chức
năng chưa chuyển đổi vẫn ở bản egui. Cần đối chiếu danh sách trong sự kiện
`ready` với `docs/TINH_NANG.md` trước khi dùng bản native làm bản thay thế hoàn toàn.

Các kiểm tra bắt buộc trước khi chuyển tài khoản làm việc sang bản native:

1. QR, khôi phục session, mất mạng, session hết hạn và đăng xuất.
2. Gửi nhận cá nhân/nhóm, lịch sử cũ, trích dẫn, ảnh/tệp, cảm xúc và thu hồi.
3. Nhập tiếng Việt, gõ kết hợp IME, Return/Shift-Return, dán nội dung, phím tắt.
4. Thoát ứng dụng khi đang chờ phản hồi, worker bị đóng và dữ liệu không ghi được.
5. Các tính năng mở rộng được worker công bố hỗ trợ, dùng tài khoản kiểm tra và
   nội dung do người kiểm tra chủ động chọn gửi.

Quyết định kiến trúc: [ADR-0004](adr/0004-native-macos-frontend.md).

## Giao diện Liquid Glass

Trên macOS 26 trở lên, các thanh điều khiển dùng `glassEffect` của SwiftUI; khi
người dùng bật Giảm độ trong suốt, ứng dụng dùng nền đặc để giữ độ tương phản.
Thanh bên cố định vùng tìm kiếm/bộ lọc ở phía trên. Có thanh điều hướng, lọc chưa
đọc, tìm nội dung trong hội thoại, xem ảnh/tệp và tìm bạn theo số điện thoại.
Các thao tác hiện có vẫn được bật theo khả năng worker công bố.

Khi danh sách server thay mã hội thoại, giao diện bỏ lựa chọn đã lỗi thời và
không hiển thị lỗi đọc cũ đè lên hội thoại đang mở. Worker gửi lại danh sách mới
trước khi từ chối yêu cầu đọc dùng mã cũ; thao tác gửi vẫn yêu cầu mã chính xác.

Để xuất ảnh kiểm tra chỉ bằng dữ liệu mẫu, mở ứng dụng với `--demo --snapshot`
kèm đường dẫn PNG. Chế độ xuất ảnh không hoạt động với tài khoản thật.

## Nhập bản xuất `.zl.zip` của Zalo PC

Khóa xuất của Zalo PC có thể khác `dkey` của phiên Native dù cùng tài khoản.
Bộ nhập kiểm tra header tar bằng khóa phiên trước, sau đó chỉ đọc bản ghi
`0_sync_cross_state_backup` thuộc đúng UID trong Local Storage của Zalo PC trên
máy này. Khóa phải vượt kiểm tra checksum của tệp trước khi mở store để ghi.
Không ghi đè khóa đăng nhập, không truyền khóa sang Swift và không mở kho tin
nhắn của Zalo để tìm khóa. Máy không có metadata xuất phù hợp sẽ nhận thông báo
thiếu khóa phù hợp, thay vì kết luận chắc chắn người dùng xuất sai tài khoản.

Sau khi thay bản ứng dụng, thoát bản Native đang chạy rồi mở bản trong `dist`.
Đăng nhập tài khoản đã xuất tệp và chọn lại tệp trong Đồng bộ & sao lưu.
Chỉ tin nhắn được nhập; media trong archive vẫn được bỏ qua. Lần kiểm tra sửa
lỗi đã đọc toàn bộ một tệp thật vào SQLite trong bộ nhớ, không sửa lịch sử đang
sử dụng. Bằng chứng: `re-notes/50_export_key_scope.md`.

## Hiệu năng với lịch sử lớn

Bản tối ưu dùng một lượt chuẩn bị bố cục transcript, giải mã snapshot có kiểu
trên hàng đợi transport, bỏ snapshot trùng và cô lập bong bóng khỏi trạng thái
ô soạn. Danh sách hội thoại được cache theo bộ lọc. Rust bỏ ghi lại store/cache
khi snapshot không thay đổi. Worker giữ khóa riêng trên thư mục dữ liệu; app
mới kích hoạt phiên đang có thay vì tạo thêm phiên cùng bundle ID.

Benchmark release trên dữ liệu mẫu: lọc/phân nhóm 2.000 tin media từ khoảng
350,24 ms xuống 0,95 ms; ghi snapshot không đổi 5.000 tin từ 19,20 ms xuống
8,07 ms. Đây là tác vụ riêng, không phải độ trễ cuộn hoặc gõ của toàn ứng dụng.
Bằng chứng và giới hạn: `output/native-performance-20261111/benchmark.json`.
Nếu đã mở nhiều phiên cũ, cần thoát hết trước khi mở bản tối ưu; bản mới không
cưỡng bức tắt phiên cũ vì có thể còn bản nháp chưa lưu.

## Bố cục chat và đính kèm

Thao tác tin nhắn nằm trong menu chuột phải. Avatar/viên tên nổi trên
nội dung và toolbar nền được ẩn. Ô nhập dùng material có lớp nền đậm để nội dung
đang soạn không lẫn chữ phía sau; các nút nổi giữ hiệu ứng kính. Thanh bên có khung bo góc riêng; cửa sổ
vẫn dùng traffic lights native. Ảnh được hiển thị theo tỷ lệ, không lặp thẻ CDN
hay nhãn `[Hình ảnh]` khi đã có thumbnail; caption thực vẫn được giữ.

Dán ảnh (kể cả clipboard có URL đi kèm) và kéo file vào chat sẽ thêm vào khay
đính kèm. Chỉ bấm Gửi/Return mới gửi, cho phép kiểm tra đúng hội thoại trước.
Kiểm tra giao diện bằng dữ liệu mẫu: `output/ui-five-fixes-20261111/`.

## Bổ sung độ rõ và phản hồi (11/11/2026)

- Nền chung xuyên suốt cửa sổ; danh sách là thẻ riêng, có tay kéo đổi rộng không
  vẽ đường chia. Dùng góc cửa sổ native, không thêm lớp mask bo góc. Avatar lớn hơn, viên tên
  có chiều rộng theo tên, tối đa hai dòng trong bề rộng khung chat.
- Trả lời, ảnh và tệp chờ gửi nằm trong cùng ô soạn. Ảnh chỉ hiện thumbnail;
  tệp có thumbnail Quick Look, tên, loại và dung lượng. Hỗ trợ file URL chuẩn,
  danh sách `NSFilenamesPboardType`, URI list và đường dẫn tệp tuyệt đối tồn tại
  do clipboard history phục hồi. Clipy chưa được thử trực tiếp trên phiên thật.
- `TranscriptModel` tách khỏi bản nháp; kiểm thử 100 lần thay nội dung bản nháp
  không phát cập nhật model transcript. Tìm trong nội dung đã tải chờ 160 ms rồi
  lọc ngoài main actor. Ảnh inline được ImageIO thu nhỏ (720 px), cache tối đa
  48 MB/160 ảnh, tối đa bốn lượt tải đồng thời và giới hạn 20 MB mỗi lượt.
- Thao tác tin nhắn dùng menu chuột phải. Chuyển động nhẹ cho chọn
  hội thoại, nhấn nút, khay tệp/trả lời và nút gửi; tôn trọng Giảm chuyển động.

Ảnh dữ liệu mẫu và kết quả kiểm tra: `output/ui-readable-20261111/`.
Các số đo trên chưa chứng minh độ mượt toàn ứng dụng với tài khoản thật.

## Bố cục và thao tác chat đợt tiếp theo (11/11/2026)

- Ô soạn trống cao 44 pt, đồng đều với nút thêm bên cạnh; emoji nằm trong ô
  nhập. Khi có nhiều dòng, trả lời hoặc đính kèm, ô mở rộng có giới hạn và nền
  dễ đọc, còn các nút dùng Liquid Glass. Bỏ ô tìm kiếm thường trực trên danh sách.
- Nút tìm kiếm ở cùng thanh công cụ với lọc/soạn; khi mở tạm ẩn hai nút kia.
  Popover tự thu khi nhấn ra ngoài, hỗ trợ liên hệ/hội thoại, tin nhắn và tệp.
  Tìm tin/tệp trong SQLite trên worker, chờ gõ 220 ms; bỏ kết quả đến muộn.
  Tệp được tìm theo tên/metadata đã lưu, không tìm bên trong nội dung tài liệu.
- Trang thông tin thay vùng chat ở toàn bề rộng, giữ danh sách và bản nháp;
  đóng bằng X/Quay lại/Esc. Avatar lớn, nút hành động và thư viện/thành viên.
- Bảng thêm nội dung có danh thiếp, định dạng chữ, nhắc hẹn, chọn đánh dấu tin
  quan trọng, nhãn dán, trả lời nhanh và hẹn giờ gửi. Định dạng bôi đậm/nghiêng/
  gạch chân/gạch ngang dùng bộ chuyển textProperties đã có của Rust.
- Danh thiếp gửi UID liên hệ qua API Zalo PC có bằng chứng ở
  `re-notes/52_native_contact_send.md`; chưa thử gửi bằng tài khoản thật.
  Nhắc hẹn/đánh dấu là chức năng lưu trên máy. Chưa có capability sửa nội dung
  tin đã gửi vì chưa xác định được API đủ rõ; menu không hiển thị nút giả.

Bằng chứng kiểm tra: `output/chat-rework-20261111/`.

## Vùng cuộn hội thoại phủ toàn khung (11/11/2026)

Transcript phủ toàn bộ cột hội thoại, kể cả phía sau tiêu đề và ô soạn nổi.
Khoảng cuộn đầu/cuối tự cập nhật theo chiều cao các thanh điều khiển, tìm kiếm,
trả lời và đính kèm, để tin ở hai đầu vẫn đọc được. Nút về tin mới nhất nằm
trên ô soạn; chuyển đến tin tìm thấy chừa khoảng dưới tiêu đề.

## Căn lề media và thông báo (11/11/2026)

Ảnh giữ tỷ lệ, bám lề trái khi nhận và lề phải khi gửi; giờ gửi đi cùng phần
ảnh thực. Thẻ tệp trong bong bóng dùng cùng lề nội dung.
Tin mới từ push/poll cập nhật số chưa đọc; tải lịch sử, tin gửi và gói trùng
không làm tăng số đếm. Dấu chưa đọc thủ công vẫn hiện khi số đếm bằng không.
Thông báo tôn trọng cài đặt app, quyền macOS, hội thoại tắt thông báo/ẩn và
không báo lại lịch sử lúc khởi động. Chi tiết: `re-notes/57_native_unread_media_alignment.md`.

## Tìm kiếm gần đây và nhập ngay khi trả lời (12/11/2026)

Mở tìm kiếm bằng nút hoặc ⌘K sẽ đưa bàn phím vào ô tìm kiếm sau khi ô được
gắn vào cửa sổ. Ô trống hiển thị tối đa 12 từ khóa gần đây theo từng tài khoản;
lưu khi xác nhận, mở kết quả, đóng tìm kiếm hoặc xóa nội dung ô. Có thể chọn lại,
xóa từng mục hoặc xóa tất cả. Chế độ demo không ghi lịch sử vào tài khoản thật.

Chọn trả lời bằng menu, vuốt hoặc nhấp đúp sẽ đưa con trỏ vào ô soạn mà không
xóa bản nháp hay thay vùng chọn. Yêu cầu focus chỉ xảy ra theo thao tác trả lời,
không lặp lại ở mỗi lượt vẽ hoặc khi gõ ở nơi khác.

## Cập nhật phần mềm

**Cài đặt → Cập nhật phần mềm** (hoặc menu **Zalolite → Kiểm tra cập nhật…**) hỏi
`https://api.github.com/repos/lebad280324/zalolite/releases/latest`. Bản mới chỉ xuất hiện khi có
một GitHub Release (không phải bản nháp hay pre-release) với tag dạng `v0.0.11`, có tệp
gói ZIP chạy được trên chip của máy và `SHA256SUMS.txt`. Ứng dụng ưu tiên
`Zalolite-<phiên-bản>-macos-universal.zip`; nếu không có thì chỉ nhận gói đúng chip (`-macos-arm64.zip` hoặc
`-macos-x86_64.zip`), không bao giờ tải gói của chip khác. Mỗi commit mới không tự thành bản cập nhật.

Khi người dùng chọn **Tải và cài đặt**, ứng dụng:

1. Tải `SHA256SUMS.txt` và gói ZIP từ `github.com` qua HTTPS.
2. Đối chiếu SHA-256, giải nén bằng `ditto`, kiểm tra bundle ID, đúng số phiên bản, có mã máy cho chip hiện tại
   và `codesign --verify --deep --strict`.
3. Thoát; một script nhỏ chờ tiến trình kết thúc, thay `Zalolite.app` (khôi phục bản cũ nếu không thay được) rồi mở bản mới.

Nếu thư mục chứa ứng dụng không cho ghi, gói đã kiểm tra được mở trong Finder để người dùng tự kéo vào
Applications. Kiểm tra tự động chạy tối đa một lần mỗi ngày khi mở ứng dụng và có thể tắt; chế độ `--demo`
không tự kiểm tra. Mã SHA-256 nằm cùng bản phát hành, nên chỉ chống tệp hỏng hoặc bị thay trên đường truyền,
không thay được việc bảo vệ tài khoản GitHub phát hành.

Phát hành bản mới: tăng `version` trong `Cargo.toml`, chạy `packaging/package-native-macos.sh`, rồi
`packaging/make-native-release.sh` để tạo ZIP, DMG và `SHA256SUMS.txt` trong `dist/`. Script in sẵn lệnh
`gh release create v<phiên-bản> …` để đăng Release lên `lebad280324/zalolite`. Với bản Universal, script tạo thêm
một bản sao `-macos-arm64.zip` cùng nội dung để Zalolite 0.0.11 (chỉ biết tên đó) vẫn tự cập nhật được.

Giữ `version` của bản build thử không thấp hơn bản đã phát hành: trình cập nhật coi bản thấp hơn là bản cũ và
sẽ đề nghị thay nó bằng bản trên GitHub.
