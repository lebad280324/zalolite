# Zalolite

Ứng dụng Zalo cho **macOS Apple Silicon**, dùng giao diện **SwiftUI/AppKit**
và worker **Rust**. Được phát triển và duy trì độc lập bởi
[lebad280324](https://github.com/lebad280324).

- [Tải bản phát hành](https://github.com/lebad280324/zalolite/releases)
- [Báo lỗi](https://github.com/lebad280324/zalolite/issues)
- [Giao diện và kiến trúc native](docs/MACOS_NATIVE.md)
- [Nguồn gốc và giấy phép](THIRD_PARTY_NOTICES.md)

## Cài đặt

Yêu cầu Mac Apple Silicon (M1 trở lên), macOS 14 trở lên. Hiệu ứng Liquid Glass
sử dụng macOS 26 trở lên.

Tải DMG ở Releases, mở rồi kéo **Zalolite.app** vào **Applications**; hoặc giải
nén ZIP. Thoát bản Zalolite cũ trước khi mở bản mới. Mỗi bản phát hành cung cấp
`SHA256SUMS.txt` để đối chiếu các tệp tải về.

Ứng dụng hiện được ký ad-hoc và chưa được Apple notarize. Nếu macOS chặn lần
mở đầu, dùng **System Settings → Privacy & Security → Open Anyway** sau khi
xác minh nguồn tải và checksum.

## Chức năng

Giao diện native cho hội thoại, tìm kiếm, trả lời, ảnh/tệp, nhãn dán, cảm xúc,
thông tin hội thoại và nhập bản sao lưu Zalo PC. Transcript dùng AppKit/CoreText,
lịch sử phân trang và cache media. Rust xử lý session, giao thức mạng và SQLite.

Kiểm thử tự động dùng dữ liệu mẫu; không chứng minh mọi luồng tài khoản Zalo
thật đã được kiểm tra. Xem ghi chú từng bản phát hành để biết kết quả, giới hạn
và chức năng chưa xác minh. Hiện chỉ cung cấp gói macOS arm64.

## Build từ mã nguồn

Cần Rust, Xcode Command Line Tools và SDK macOS có SwiftUI/AppKit.

```sh
CMAKE_POLICY_VERSION_MINIMUM=3.5 cargo test --locked
swift test --build-system native --package-path native/macos/CTDoNative \
  --scratch-path target/swift-native --configuration release --disable-sandbox
CTDOZLITE_SWIFT_BUILD_SYSTEM=native bash packaging/package-native-macos.sh
open dist/Zalolite.app
```

Để thử bằng dữ liệu mẫu, không kết nối tài khoản thật:

```sh
open -n dist/Zalolite.app --args --demo
```

Một số định danh crate, binary và bundle vẫn dùng tên `ctdozlite` để giữ tương
thích. Mã và tài liệu egui/TUI cũ được giữ để truy vết; sản phẩm phát hành của
repo này là **Zalolite native macOS**. Bản native không dùng trình tự cập nhật
của giao diện egui kế thừa.

## Giấy phép và ghi nhận

Mã dự án theo **MIT OR Apache-2.0**; xem [LICENSE-MIT](LICENSE-MIT) và
[LICENSE-APACHE](LICENSE-APACHE). Một số thành phần bắt nguồn từ
[ctdozlite](https://github.com/ctdoteam1110/ctdozlite); bản quyền và lịch sử
đóng góp được giữ lại. Phần đóng góp Zalolite được ghi nhận riêng cho lebad280324.
Chi tiết trong [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) và [NOTICE](NOTICE).

Zalolite là dự án độc lập, không phải ứng dụng chính thức của Zalo/VNG.
