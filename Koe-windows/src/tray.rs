use global_hotkey::GlobalHotKeyEvent;
use log::info;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tray_icon::{
    menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem},
    TrayIconBuilder,
};
use winit::event_loop::{ControlFlow, EventLoop};

use crate::audio::Recorder;
use crate::config;
use crate::hotkey;
use crate::SharedState;

/// システムトレイアイコンを作成し、メインイベントループを実行
pub fn run(shared: Arc<Mutex<SharedState>>, mut recorder: Recorder) {
    let event_loop = EventLoop::new().expect("Failed to create event loop");

    // メニュー構築
    let menu = Menu::new();
    let item_status = MenuItem::new("Koe — 待機中", false, None);
    let item_hotkey = MenuItem::new("ショートカット: Ctrl+Alt+V", false, None);
    let item_sep1 = PredefinedMenuItem::separator();

    let languages = config::supported_languages();
    let lang_items: Vec<MenuItem> = languages
        .iter()
        .map(|(flag, name, code)| {
            MenuItem::new(format!("{} {} ({})", flag, name, code), true, None)
        })
        .collect();

    let item_sep2 = PredefinedMenuItem::separator();
    let item_quit = MenuItem::new("終了 / Quit", true, None);

    let _ = menu.append(&item_status);
    let _ = menu.append(&item_hotkey);
    let _ = menu.append(&item_sep1);
    for item in &lang_items {
        let _ = menu.append(item);
    }
    let _ = menu.append(&item_sep2);
    let _ = menu.append(&item_quit);

    // トレイアイコン
    let icon = create_icon();
    let _tray = TrayIconBuilder::new()
        .with_menu(Box::new(menu))
        .with_tooltip("Koe — Voice Input (Ctrl+Alt+V)")
        .with_icon(icon)
        .build()
        .expect("Failed to create tray icon");

    // ホットキー登録
    let (_hotkey_manager, hotkey_id) =
        hotkey::HotkeyManager::new().expect("Failed to register hotkey");

    info!("Koe is running. Press Ctrl+Alt+V to start voice input.");

    let quit_id = item_quit.id().clone();
    let lang_ids: Vec<_> = lang_items.iter().map(|i| i.id().clone()).collect();

    // イベントループ
    #[allow(deprecated)]
    event_loop
        .run(move |_event, elwt| {
            elwt.set_control_flow(ControlFlow::WaitUntil(
                std::time::Instant::now() + Duration::from_millis(50),
            ));

            // ホットキーイベント
            if let Ok(event) = GlobalHotKeyEvent::receiver().try_recv() {
                if event.id() == hotkey_id {
                    hotkey::handle_hotkey_event(&shared, &mut recorder);
                }
            }

            // メニューイベント
            if let Ok(event) = MenuEvent::receiver().try_recv() {
                if event.id == quit_id {
                    info!("Quit requested");
                    std::process::exit(0);
                }

                for (i, lang_id) in lang_ids.iter().enumerate() {
                    if event.id == *lang_id {
                        let (_, name, code) = &languages[i];
                        info!("Language changed: {} ({})", name, code);
                        let mut s = shared.lock().unwrap();
                        s.config.language = code.to_string();
                        let _ = s.config.save();
                        break;
                    }
                }
            }
        })
        .expect("Event loop error");
}

/// 32x32 の簡易アイコンを生成（赤い丸）
fn create_icon() -> tray_icon::Icon {
    let size = 32u32;
    let mut rgba = vec![0u8; (size * size * 4) as usize];

    let cx = size as f64 / 2.0;
    let cy = size as f64 / 2.0;
    let r = size as f64 / 2.0 - 1.0;

    for y in 0..size {
        for x in 0..size {
            let dx = x as f64 - cx;
            let dy = y as f64 - cy;
            let dist = (dx * dx + dy * dy).sqrt();

            let idx = ((y * size + x) * 4) as usize;
            if dist <= r {
                rgba[idx] = 220;
                rgba[idx + 1] = 60;
                rgba[idx + 2] = 60;
                rgba[idx + 3] = 255;
            }
        }
    }

    tray_icon::Icon::from_rgba(rgba, size, size).expect("Failed to create icon")
}
