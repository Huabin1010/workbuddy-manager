//! Windows 桌面壳：本地服务 + 应用窗口 + 任务栏托盘。
//! 关闭窗口只是藏起来，从托盘「退出」才会停掉服务。

#![windows_subsystem = "windows"]

use std::fs::{self, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::Duration;

use tao::dpi::LogicalSize;
use tao::event::{Event, StartCause, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoop};
use tao::window::{Icon as WindowIcon, WindowBuilder};
use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon as TrayIcon, TrayIconBuilder};
use wry::WebViewBuilder;

const ICON_PNG: &[u8] = include_bytes!("../../../../web/public/favicon/android-chrome-512x512.png");

fn main() {
    if already_running() {
        message(
            "WorkBuddy Manager",
            "管理台已经在运行。\n请到任务栏右下角的图标里选择「打开主窗口」。",
        );
        return;
    }

    let (mut child, port, first_password) = match start_server() {
        Ok(started) => started,
        Err(err) => {
            message("WorkBuddy 管理台启动失败", &err);
            return;
        }
    };

    if !wait_until_ready(port, &mut child) {
        let _ = child.kill();
        let _ = child.wait();
        message(
            "WorkBuddy 管理台启动失败",
            &format!("后台服务没有在 127.0.0.1:{port} 就绪。\n\n{}", log_tail()),
        );
        return;
    }

    if let Some(password) = first_password {
        message(
            "初始管理员账号",
            &format!(
                "用户名: admin\n密码: {password}\n\n请登录后在「设置 → 管理用户」中修改密码。\n同一份密码也写在了数据目录的 initial-admin.txt 里。"
            ),
        );
    }

    let url = format!("http://127.0.0.1:{port}/");
    if let Err(err) = run_window(&url, child) {
        message(
            "无法打开窗口",
            &format!(
                "{err}\n\n这台电脑可能还没有 WebView2 运行时。\n请先安装 Microsoft Edge，或运行程序目录里的 WebView2Setup.exe，然后再打开一次。"
            ),
        );
    }
}

fn install_dir() -> PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|path| path.parent().map(Path::to_path_buf))
        .unwrap_or_else(|| PathBuf::from("."))
}

fn data_dir() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("APPDATA").map(PathBuf::from))
        .unwrap_or_else(|| PathBuf::from("."));
    let dir = base.join("workbuddy-manager");
    let _ = fs::create_dir_all(&dir);
    dir
}

fn start_server() -> Result<(Child, u16, Option<String>), String> {
    let root = install_dir();
    let python = root.join("python").join("python.exe");
    let app = root.join("app");
    if !python.is_file() {
        return Err(format!("找不到 Python 运行时：{}", python.display()));
    }
    if !app.join("server").join("main.py").is_file() {
        return Err(format!("找不到程序文件：{}", app.join("server").join("main.py").display()));
    }
    if !app.join("web").join("out").join("index.html").is_file() {
        return Err("找不到已构建的网页界面（web/out/index.html）".to_string());
    }

    let state = data_dir();
    let users = state.join("users.json");
    let port = free_port();
    let mut first_password = None;
    let mut cmd = Command::new(&python);
    cmd.current_dir(&app)
        .arg("-m")
        .arg("uvicorn")
        .arg("server.main:app")
        .arg("--host")
        .arg("127.0.0.1")
        .arg("--port")
        .arg(port.to_string())
        .env("PYTHONUTF8", "1")
        .env("PYTHONIOENCODING", "utf-8")
        .env("WB_MANAGER_HOST", "127.0.0.1")
        .env("WB_MANAGER_PORT", port.to_string())
        .env("WB_DATA_DIR", &state)
        .env("WB_DB", state.join("manager.db"))
        .env("WB_USERS_FILE", &users)
        .env("WB_STATIC_DIR", app.join("web").join("out"))
        .env("WB_SECURE_COOKIE", "false")
        .env("WB_ENABLE_DOCS", "0");

    if !users.is_file() {
        let password = random_token(12);
        let note = state.join("initial-admin.txt");
        let body = format!(
            "用户名: admin\n密码: {password}\n请登录后在「设置 → 管理用户」中修改，然后删除本文件。\n"
        );
        fs::write(&note, body).map_err(|err| format!("写不下初始密码文件：{err}"))?;
        cmd.env("WB_ADMIN_PASSWORD", &password);
        first_password = Some(password);
    }

    let log_path = state.join("server.log");
    let mut log = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .map_err(|err| format!("打不开日志 {}：{err}", log_path.display()))?;
    let _ = writeln!(log, "\n---- start port={port} ----");
    let log_err = log.try_clone().map_err(|err| format!("无法复制日志句柄：{err}"))?;

    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
    let child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_err))
        .creation_flags(CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP)
        .spawn()
        .map_err(|err| format!("启动后台服务失败：{err}"))?;
    Ok((child, port, first_password))
}

fn free_port() -> u16 {
    for port in 7864..7884 {
        if TcpListener::bind(("127.0.0.1", port)).is_ok() {
            return port;
        }
    }
    7864
}

fn wait_until_ready(port: u16, child: &mut Child) -> bool {
    let addr = format!("127.0.0.1:{port}");
    for _ in 0..160 {
        if matches!(child.try_wait(), Ok(Some(_))) {
            return false;
        }
        if TcpStream::connect_timeout(
            &addr.parse().expect("addr"),
            Duration::from_millis(250),
        )
        .is_ok()
        {
            return true;
        }
        thread::sleep(Duration::from_millis(250));
    }
    false
}

fn log_tail() -> String {
    let path = data_dir().join("server.log");
    let mut file = match fs::File::open(path) {
        Ok(file) => file,
        Err(_) => return "没有日志。".to_string(),
    };
    let len = file.metadata().map(|meta| meta.len()).unwrap_or(0);
    if len > 4000 {
        let _ = file.seek(SeekFrom::End(-4000));
    }
    let mut buf = String::new();
    let _ = file.read_to_string(&mut buf);
    buf.chars().rev().take(1200).collect::<String>().chars().rev().collect()
}

fn random_token(len: usize) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
    let mut bytes = vec![0u8; len];
    getrandom::fill(&mut bytes).expect("系统随机数不可用");
    bytes
        .into_iter()
        .map(|byte| ALPHABET[(byte as usize) % ALPHABET.len()] as char)
        .collect()
}

fn run_window(url: &str, mut server: Child) -> Result<(), String> {
    let event_loop = EventLoop::new();
    let (window_rgba, window_w, window_h) = scaled_icon(64);
    let window_icon = WindowIcon::from_rgba(window_rgba, window_w, window_h)
        .map_err(|err| format!("窗口图标无效：{err:?}"))?;
    let window = WindowBuilder::new()
        .with_title("WorkBuddy Manager")
        .with_inner_size(LogicalSize::new(1280.0, 800.0))
        .with_min_inner_size(LogicalSize::new(960.0, 640.0))
        .with_window_icon(Some(window_icon))
        .build(&event_loop)
        .map_err(|err| format!("创建窗口失败：{err}"))?;
    let webview = WebViewBuilder::new()
        .with_url(url)
        .build(&window)
        .map_err(|err| format!("WebView2 初始化失败：{err}"))?;

    let open_item = MenuItem::with_id("open", "打开主窗口", true, None);
    let quit_item = MenuItem::with_id("quit", "退出", true, None);
    let open_id = open_item.id().clone();
    let quit_id = quit_item.id().clone();
    let (tray_rgba, tray_w, tray_h) = scaled_icon(32);
    let tray_icon = TrayIcon::from_rgba(tray_rgba, tray_w, tray_h)
        .map_err(|err| format!("托盘图标无效：{err:?}"))?;

    let mut pending_open = Some(open_item);
    let mut pending_quit = Some(quit_item);
    let mut pending_icon = Some(tray_icon);
    let mut tray = None;
    event_loop.run(move |event, _target, control_flow| {
        *control_flow = ControlFlow::Wait;
        let _keepalive = &webview;

        if let Event::NewEvents(StartCause::Init) = &event {
            if let (Some(open_item), Some(quit_item), Some(icon)) = (
                pending_open.take(),
                pending_quit.take(),
                pending_icon.take(),
            ) {
                let menu = Menu::new();
                let _ = menu.append(&open_item);
                let _ = menu.append(&PredefinedMenuItem::separator());
                let _ = menu.append(&quit_item);
                tray = TrayIconBuilder::new()
                    .with_menu(Box::new(menu))
                    .with_tooltip("WorkBuddy Manager")
                    .with_icon(icon)
                    .build()
                    .ok();
            }
        }

        while let Ok(menu_event) = MenuEvent::receiver().try_recv() {
            if menu_event.id == open_id {
                window.set_visible(true);
                window.set_focus();
            } else if menu_event.id == quit_id {
                *control_flow = ControlFlow::Exit;
            }
        }

        match event {
            Event::WindowEvent {
                event: WindowEvent::CloseRequested,
                ..
            } => {
                if tray.is_some() {
                    window.set_visible(false);
                } else {
                    *control_flow = ControlFlow::Exit;
                }
            }
            Event::LoopDestroyed => {
                let _ = server.kill();
                let _ = server.wait();
            }
            _ => {}
        }
    });
}

fn scaled_icon(size: u32) -> (Vec<u8>, u32, u32) {
    let image = image::load_from_memory(ICON_PNG)
        .expect("内置图标损坏")
        .into_rgba8();
    let image = image::imageops::resize(&image, size, size, image::imageops::FilterType::Lanczos3);
    let (width, height) = image.dimensions();
    (image.into_raw(), width, height)
}

fn already_running() -> bool {
    use windows_sys::Win32::Foundation::GetLastError;
    use windows_sys::Win32::System::Threading::CreateMutexW;
    let name = wide("Local\\WorkBuddyManager");
    let handle = unsafe { CreateMutexW(std::ptr::null(), 0, name.as_ptr()) };
    !handle.is_null() && unsafe { GetLastError() } == windows_sys::Win32::Foundation::ERROR_ALREADY_EXISTS
}

fn message(title: &str, body: &str) {
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        MessageBoxW, MB_ICONINFORMATION, MB_OK,
    };
    let title = wide(title);
    let body = wide(body);
    unsafe {
        MessageBoxW(std::ptr::null_mut(), body.as_ptr(), title.as_ptr(), MB_OK | MB_ICONINFORMATION);
    }
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}
