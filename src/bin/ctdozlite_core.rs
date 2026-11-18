//! Headless JSON-lines worker owned by the native macOS application.

#[cfg(unix)]
fn lock_data_directory() -> std::io::Result<std::fs::File> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .open(".native-worker.lock")?;
    extern "C" {
        fn flock(fd: std::os::raw::c_int, operation: std::os::raw::c_int) -> std::os::raw::c_int;
    }
    // SAFETY: the owned file keeps this valid descriptor alive until process exit;
    // LOCK_EX|LOCK_NB never blocks and the OS releases the advisory lock on close.
    if unsafe { flock(file.as_raw_fd(), 2 | 4) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(file)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let demo = args.iter().any(|arg| arg == "--demo");
    if args.iter().any(|arg| arg == "--help" || arg == "-h") {
        eprintln!(
            "ctdozlite-core --data-dir <thư mục> [--demo]\nCầu nối JSON-lines cho giao diện macOS.\nctdozlite-core --mcp [--data-dir <thư mục>]\nCầu nối MCP chỉ đọc cho trợ lý AI."
        );
        return;
    }
    // `--mcp`: read-only bridge for a local AI assistant. It never takes the worker lock, so it
    // runs beside the open app, and it only reads the conversations shared in ai_bridge.json.
    if args.iter().any(|arg| arg == "--mcp") {
        let Ok(directory) = zalo_rust::data_dir::initialize(&args) else {
            eprintln!("Không mở được thư mục dữ liệu của Zalolite.");
            std::process::exit(2);
        };
        if zalo_rust::ai_bridge::run_stdio(&directory).is_err() {
            std::process::exit(1);
        }
        return;
    }
    if !demo {
        if !args
            .iter()
            .any(|arg| arg == "--data-dir" || arg.starts_with("--data-dir="))
        {
            eprintln!("Cần chỉ định --data-dir cho phiên ứng dụng.");
            std::process::exit(2);
        }
        if zalo_rust::data_dir::initialize(&args).is_err() {
            eprintln!("Không mở được thư mục dữ liệu riêng của ứng dụng.");
            std::process::exit(2);
        }
    }
    #[cfg(unix)]
    let _data_lock = if !demo {
        match lock_data_directory() {
            Ok(file) => Some(file),
            Err(_) => {
                eprintln!("Thư mục dữ liệu đang được một phiên Native khác sử dụng. Hãy đóng phiên đó trước.");
                std::process::exit(2)
            }
        }
    } else {
        None
    };
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(_) => {
            eprintln!("Không khởi tạo được luồng xử lý.");
            std::process::exit(1);
        }
    };
    if runtime
        .block_on(zalo_rust::native_core::run_stdio(demo))
        .is_err()
    {
        eprintln!("Kết nối với giao diện đã đóng.");
        std::process::exit(1);
    }
}
