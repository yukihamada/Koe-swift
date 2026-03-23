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
const PRICING: &str = include_str!("../pricing.html");
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

// --- Stripe Checkout ---

#[derive(Deserialize)]
struct CheckoutQuery {
    plan: String,
    interval: Option<String>,
}

async fn stripe_checkout(axum::extract::Query(q): axum::extract::Query<CheckoutQuery>) -> impl IntoResponse {
    let stripe_key = std::env::var("STRIPE_SECRET_KEY").unwrap_or_default();
    if stripe_key.is_empty() {
        return axum::response::Redirect::temporary("/pricing?error=stripe_not_configured").into_response();
    }

    let annual = q.interval.as_deref() == Some("annual");

    // Stripe Price IDsを環境変数から取得
    let price_id = match (q.plan.as_str(), annual) {
        ("pro", false)  => std::env::var("STRIPE_PRICE_PRO_MONTHLY").unwrap_or_default(),
        ("pro", true)   => std::env::var("STRIPE_PRICE_PRO_ANNUAL").unwrap_or_default(),
        ("team", false) => std::env::var("STRIPE_PRICE_TEAM_MONTHLY").unwrap_or_default(),
        ("team", true)  => std::env::var("STRIPE_PRICE_TEAM_ANNUAL").unwrap_or_default(),
        _ => return axum::response::Redirect::temporary("/pricing?error=invalid_plan").into_response(),
    };

    if price_id.is_empty() {
        return axum::response::Redirect::temporary("/pricing?error=price_not_configured").into_response();
    }

    // Stripe Checkout Session作成
    let client = reqwest::Client::new();
    let params = [
        ("mode", "subscription"),
        ("payment_method_types[]", "card"),
        ("line_items[0][price]", &price_id),
        ("line_items[0][quantity]", "1"),
        ("success_url", "https://koe.elio.love/pricing?success=true"),
        ("cancel_url", "https://koe.elio.love/pricing?canceled=true"),
        ("allow_promotion_codes", "true"),
    ];

    match client.post("https://api.stripe.com/v1/checkout/sessions")
        .basic_auth(&stripe_key, None::<&str>)
        .form(&params)
        .send()
        .await
    {
        Ok(resp) => {
            if let Ok(body) = resp.json::<serde_json::Value>().await {
                if let Some(url) = body["url"].as_str() {
                    return axum::response::Redirect::temporary(url).into_response();
                }
            }
            axum::response::Redirect::temporary("/pricing?error=stripe_error").into_response()
        }
        Err(_) => axum::response::Redirect::temporary("/pricing?error=network_error").into_response(),
    }
}

// --- License Verification API ---

#[derive(Deserialize)]
struct LicenseQuery {
    email: Option<String>,
    device_id: Option<String>,
}

#[derive(Serialize)]
struct LicenseResponse {
    plan: String,
    valid: bool,
    features: Vec<String>,
}

async fn verify_license(
    axum::extract::Query(q): axum::extract::Query<LicenseQuery>,
) -> impl IntoResponse {
    let stripe_key = std::env::var("STRIPE_SECRET_KEY").unwrap_or_default();
    let email = q.email.unwrap_or_default();

    if stripe_key.is_empty() || email.is_empty() {
        return Json(LicenseResponse {
            plan: "free".into(),
            valid: true,
            features: vec!["local_transcription".into(), "basic_summary".into()],
        }).into_response();
    }

    // Stripeでアクティブなサブスクリプションを検索
    let client = reqwest::Client::new();
    let search_url = format!(
        "https://api.stripe.com/v1/customers/search?query=email:'{}'",
        email
    );

    let plan = match client.get(&search_url)
        .basic_auth(&stripe_key, None::<&str>)
        .send()
        .await
    {
        Ok(resp) => {
            if let Ok(body) = resp.json::<serde_json::Value>().await {
                let customers = body["data"].as_array();
                if let Some(customers) = customers {
                    // 最初のカスタマーのサブスクリプションを確認
                    if let Some(customer) = customers.first() {
                        if let Some(cid) = customer["id"].as_str() {
                            check_subscription(&client, &stripe_key, cid).await
                        } else { "free".to_string() }
                    } else { "free".to_string() }
                } else { "free".to_string() }
            } else { "free".to_string() }
        }
        Err(_) => "free".to_string(),
    };

    let features = match plan.as_str() {
        "team" => vec![
            "local_transcription", "cloud_ai_summary", "sync", "unlimited_speakers",
            "all_templates", "unlimited_calls", "unlimited_storage",
            "slack_notion", "team_sharing", "search", "admin_dashboard", "sso",
        ],
        "pro" => vec![
            "local_transcription", "cloud_ai_summary", "sync", "unlimited_speakers",
            "all_templates", "unlimited_calls", "90day_storage",
            "slack_notion", "realtime_translation",
        ],
        _ => vec!["local_transcription", "basic_summary"],
    };

    Json(LicenseResponse {
        plan: plan.clone(),
        valid: true,
        features: features.into_iter().map(String::from).collect(),
    }).into_response()
}

async fn check_subscription(client: &reqwest::Client, key: &str, customer_id: &str) -> String {
    let url = format!(
        "https://api.stripe.com/v1/subscriptions?customer={}&status=active",
        customer_id
    );
    match client.get(&url).basic_auth(key, None::<&str>).send().await {
        Ok(resp) => {
            if let Ok(body) = resp.json::<serde_json::Value>().await {
                if let Some(subs) = body["data"].as_array() {
                    for sub in subs {
                        if let Some(items) = sub["items"]["data"].as_array() {
                            for item in items {
                                let price_id = item["price"]["id"].as_str().unwrap_or("");
                                let team_prices = [
                                    std::env::var("STRIPE_PRICE_TEAM_MONTHLY").unwrap_or_default(),
                                    std::env::var("STRIPE_PRICE_TEAM_ANNUAL").unwrap_or_default(),
                                ];
                                if team_prices.contains(&price_id.to_string()) {
                                    return "team".to_string();
                                }
                                let pro_prices = [
                                    std::env::var("STRIPE_PRICE_PRO_MONTHLY").unwrap_or_default(),
                                    std::env::var("STRIPE_PRICE_PRO_ANNUAL").unwrap_or_default(),
                                ];
                                if pro_prices.contains(&price_id.to_string()) {
                                    return "pro".to_string();
                                }
                            }
                        }
                    }
                }
            }
            "free".to_string()
        }
        Err(_) => "free".to_string(),
    }
}

#[tokio::main]
async fn main() {
    let port = std::env::var("PORT").unwrap_or_else(|_| "8080".into());
    let addr = format!("0.0.0.0:{port}");
    let analytics: SharedAnalytics = Arc::new(Mutex::new(Analytics::default()));

    let app = Router::new()
        .route("/", get(|| async { Html(PAGE) }))
        .route("/vs-notta", get(|| async { Html(VS_NOTTA) }))
        .route("/pricing", get(|| async { Html(PRICING) }))
        .route("/api/checkout", get(stripe_checkout))
        .route("/api/license", get(verify_license))
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
