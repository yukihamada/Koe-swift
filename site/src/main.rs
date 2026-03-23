use axum::{
    extract::State,
    http::HeaderMap,
    response::{Html, IntoResponse, Json},
    routing::{get, post},
    Router,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

const PAGE: &str = include_str!("../index.html");
const VS_NOTTA: &str = include_str!("../vs-notta.html");
const OG_SVG: &str = include_str!("../og.svg");
const OG_PNG: &[u8] = include_bytes!("../og.png");
const INSTALL_SH: &str = include_str!("../install.sh");
const ELIO_ICON: &[u8] = include_bytes!("../elio-icon.png");

// --- Privacy-first analytics ---
// No cookies, no IP storage, no PII. Just counters.

fn today() -> String {
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
    let jst_secs = secs + 9 * 3600; // JST = UTC+9
    let mut yr = 1970i64;
    let mut remaining = jst_secs as i64 / 86400;
    loop {
        let days_in_year = if yr % 4 == 0 && (yr % 100 != 0 || yr % 400 == 0) { 366 } else { 365 };
        if remaining < days_in_year { break; }
        remaining -= days_in_year;
        yr += 1;
    }
    let leap = yr % 4 == 0 && (yr % 100 != 0 || yr % 400 == 0);
    let month_days = [31, if leap { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let mut m = 0;
    for (i, &md) in month_days.iter().enumerate() {
        if remaining < md as i64 { m = i + 1; break; }
        remaining -= md as i64;
    }
    format!("{:04}-{:02}-{:02}", yr, m, remaining + 1)
}

#[derive(Debug, Clone, Default, Serialize)]
struct DayStats {
    pageviews: u64,
    unique_visits: u64, // approximate via daily counter reset
    app_launches: u64,
    app_recordings: u64,
    referrers: HashMap<String, u64>,
    paths: HashMap<String, u64>,
    platforms: HashMap<String, u64>,
}

#[derive(Debug, Clone, Default)]
struct Analytics {
    days: HashMap<String, DayStats>,
    total_pageviews: u64,
    total_app_launches: u64,
    total_app_recordings: u64,
}

type SharedAnalytics = Arc<Mutex<Analytics>>;

#[derive(Deserialize)]
struct EventPayload {
    #[serde(rename = "t")]
    event_type: String, // "pageview", "app_launch", "app_recording"
    #[serde(rename = "r", default)]
    referrer: String,
    #[serde(rename = "p", default)]
    path: String,
    #[serde(rename = "v", default)]
    app_version: String,
}

async fn track_event(
    State(analytics): State<SharedAnalytics>,
    headers: HeaderMap,
    Json(payload): Json<EventPayload>,
) -> impl IntoResponse {
    let date = today();
    let mut a = analytics.lock().unwrap();

    // Extract platform from User-Agent (just os, no fingerprinting)
    let ua = headers.get("user-agent").and_then(|v| v.to_str().ok()).unwrap_or("");
    let platform = if ua.contains("Macintosh") || ua.contains("Mac OS") {
        "macOS"
    } else if ua.contains("iPhone") || ua.contains("iPad") {
        "iOS"
    } else if ua.contains("Android") {
        "Android"
    } else if ua.contains("Windows") {
        "Windows"
    } else if ua.contains("Linux") {
        "Linux"
    } else {
        "Other"
    }.to_string();

    // Update totals first
    match payload.event_type.as_str() {
        "pageview" => a.total_pageviews += 1,
        "app_launch" => a.total_app_launches += 1,
        "app_recording" => a.total_app_recordings += 1,
        _ => {}
    }

    // Then update daily stats
    let day = a.days.entry(date).or_default();
    match payload.event_type.as_str() {
        "pageview" => {
            day.pageviews += 1;
            let path = if payload.path.is_empty() { "/".to_string() } else { payload.path };
            *day.paths.entry(path).or_default() += 1;
            if !payload.referrer.is_empty() && !payload.referrer.contains("koe.elio.love") {
                let referrer_domain = payload.referrer
                    .split("//").nth(1).unwrap_or(&payload.referrer)
                    .split('/').next().unwrap_or(&payload.referrer)
                    .to_string();
                *day.referrers.entry(referrer_domain).or_default() += 1;
            }
        }
        "app_launch" => {
            day.app_launches += 1;
            if !payload.app_version.is_empty() {
                *day.platforms.entry(format!("Koe v{}", payload.app_version)).or_default() += 1;
            }
        }
        "app_recording" => {
            day.app_recordings += 1;
        }
        _ => {}
    }
    *day.platforms.entry(platform).or_default() += 1;

    (
        [("cache-control", "no-store"), ("access-control-allow-origin", "*")],
        "ok",
    )
}

async fn track_options() -> impl IntoResponse {
    (
        [
            ("access-control-allow-origin", "*"),
            ("access-control-allow-methods", "POST, OPTIONS"),
            ("access-control-allow-headers", "content-type"),
            ("access-control-max-age", "86400"),
        ],
        "",
    )
}

#[derive(Serialize)]
struct StatsResponse {
    total_pageviews: u64,
    total_app_launches: u64,
    total_app_recordings: u64,
    days: HashMap<String, DayStats>,
}

async fn get_stats(
    State(analytics): State<SharedAnalytics>,
    headers: HeaderMap,
) -> impl IntoResponse {
    // Simple auth: require ?key= param or X-Stats-Key header
    let key = std::env::var("STATS_KEY").unwrap_or_else(|_| "koe-stats-2026".into());
    let auth = headers.get("x-stats-key").and_then(|v| v.to_str().ok()).unwrap_or("");
    if auth != key {
        return (
            axum::http::StatusCode::UNAUTHORIZED,
            Json(serde_json::json!({"error": "unauthorized"})),
        ).into_response();
    }
    let a = analytics.lock().unwrap();
    Json(StatsResponse {
        total_pageviews: a.total_pageviews,
        total_app_launches: a.total_app_launches,
        total_app_recordings: a.total_app_recordings,
        days: a.days.clone(),
    }).into_response()
}

// --- Static handlers ---

async fn og_image_svg() -> impl IntoResponse {
    (
        [("content-type", "image/svg+xml"), ("cache-control", "public, max-age=86400")],
        OG_SVG,
    )
}

async fn og_image_png() -> impl IntoResponse {
    (
        [("content-type", "image/png"), ("cache-control", "public, max-age=86400")],
        OG_PNG,
    )
}

async fn elio_icon() -> impl IntoResponse {
    (
        [("content-type", "image/png"), ("cache-control", "public, max-age=86400")],
        ELIO_ICON,
    )
}

async fn install_script() -> impl IntoResponse {
    (
        [("content-type", "text/plain; charset=utf-8"), ("cache-control", "public, max-age=300")],
        INSTALL_SH,
    )
}

#[tokio::main]
async fn main() {
    let port = std::env::var("PORT").unwrap_or_else(|_| "8080".into());
    let addr = format!("0.0.0.0:{port}");
    let analytics: SharedAnalytics = Arc::new(Mutex::new(Analytics::default()));

    let app = Router::new()
        .route("/", get(|| async { Html(PAGE) }))
        .route("/vs-notta", get(|| async { Html(VS_NOTTA) }))
        .route("/og.svg", get(og_image_svg))
        .route("/og.png", get(og_image_png))
        .route("/install.sh", get(install_script))
        .route("/elio-icon.png", get(elio_icon))
        .route("/api/event", post(track_event).options(track_options))
        .route("/api/stats", get(get_stats))
        .with_state(analytics);

    println!("Listening on {addr}");
    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
