# Nguồn gốc và giấy phép

Zalolite là dự án được phát triển và duy trì độc lập bởi **lebad280324**.
Repo được tách từ checkout ctdozlite với các thay đổi Zalolite đã tích hợp;
lịch sử Git được giữ lại để ghi nhận đóng góp và phục vụ truy vết.

## Mã kế thừa

Một số thành phần Rust, công cụ và tài liệu bắt nguồn từ
[ctdozlite](https://github.com/ctdoteam1110/ctdozlite), có thông báo bản quyền
`Copyright (c) 2026 ctdoteam1110 / thanhdo1110`, theo `MIT OR Apache-2.0`.
Giữ nguyên quyền tác giả của các phần đó; xem [LICENSE-MIT](LICENSE-MIT),
[LICENSE-APACHE](LICENSE-APACHE) và [NOTICE](NOTICE).

## Phát triển Zalolite

Các thay đổi trong checkout Zalolite bao gồm giao diện SwiftUI/AppKit,
cầu nối worker Rust qua JSON Lines, transcript AppKit/CoreText, lịch sử phân
trang, tìm kiếm và các cải tiến chức năng chat. Danh sách này mô tả phạm vi
thay đổi, không tuyên bố mọi dòng trong các module liên quan đều do một tác giả viết.
Các phần đóng góp Zalolite được phát hành theo `MIT OR Apache-2.0`.

## Thành phần khác

Các dependency trong `Cargo.lock` vẫn theo giấy phép riêng của từng thư viện.
Thông báo giấy phép tài nguyên đi kèm được giữ cùng tài nguyên; helper đóng gói
có các tài nguyên nguồn mở riêng. Giấy phép của repo không thay thế giấy phép
của dependency, font, icon hoặc media do người dùng tải từ Zalo.

Zalolite không phải sản phẩm chính thức của Zalo/VNG và không tuyên bố được
Zalo/VNG hoặc tác giả ctdozlite bảo trợ.
