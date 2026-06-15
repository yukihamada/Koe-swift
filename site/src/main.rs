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
const SUPPORT: &str = include_str!("../support.html");
const OG_SVG: &str = include_str!("../og.svg");
const OG_PNG: &[u8] = include_bytes!("../og.png");
const INSTALL_SH: &str = include_str!("../install.sh");
const ELIO_ICON: &[u8] = include_bytes!("../elio-icon.png");
const ROBOTS_TXT: &str = include_str!("../robots.txt");
const SITEMAP_XML: &str = include_str!("../sitemap.xml");

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

async fn robots_txt() -> impl IntoResponse {
    (
        [("content-type", "text/plain; charset=utf-8"), ("cache-control", "public, max-age=3600")],
        ROBOTS_TXT,
    )
}

// ── SEO: Koe ユースケース別 LP (/use-cases, /use-cases/:slug) ──────────────────
// すべて index.html に実在する機能に基づく(会議文字起こし/音声操作/ローカル/議事録/リアルタイム)。
// (slug, 見出し, リード, 機能ポイント "|" 区切り)
const USE_CASES: &[(&str, &str, &str, &str)] = &[
    ("mac-transcription", "Macで会議を文字起こし", "Zoom や Teams の音声をそのまま取り込み、Mac の上で文字起こし。話者を分け、終わったら AI が要約します。", "Zoom / Teams の音声を直接キャプチャ|話者分離（誰が話したか）|リアルタイム文字起こし|AI 要約と TODO 抽出|文字起こしと AI チャット"),
    ("voice-control-mac", "声でMacを操作する", "「声で、Mac を操る」。話しかけるだけで、Mac が画面を見て操作する Screen AI Agent。", "音声によるシステム操作|画面を理解する Screen AI Agent|0.5 秒の高速認識|常時リッスン＋リアルタイムプレビュー|iPhone をリモコンに"),
    ("offline-transcription", "ローカルで完結する文字起こし", "音声は Mac の中だけで処理。クラウドに送らない、完全プライバシーの文字起こし。", "完全ローカル処理（クラウド送信なし）|オフラインでも動作|Whisper ベースの高精度認識|プライバシー重視の設計"),
    ("meeting-minutes", "議事録を自動で作る", "会議が終わると、文字起こしから AI が要約と TODO を自動生成。Slack / Notion / カレンダーへ。", "AI 要約と TODO 自動抽出|文字起こしと AI チャット|Slack / Notion / カレンダー連携|話者分離つき議事録"),
    ("realtime-transcription", "リアルタイム文字起こし", "話した先から、その場で文字に。リアルタイムプレビューで会話を止めない。", "リアルタイム文字起こし|リアルタイムプレビュー|0.5 秒の高速認識|Zoom / Teams 音声キャプチャ"),
];

fn uc_shell(title: &str, desc: &str, canonical: &str, jsonld: &str, body: &str) -> String {
    format!(r##"<!doctype html><html lang=ja><head><meta charset=utf-8>
<title>{title}</title>
<meta name=viewport content="width=device-width,initial-scale=1">
<meta name=description content="{desc}">
<link rel=canonical href="{canonical}">
<meta property="og:title" content="{title}"><meta property="og:description" content="{desc}">
<meta property="og:type" content="website"><meta property="og:url" content="{canonical}">
<meta property="og:image" content="https://koe.live/og.png">
<meta name=theme-color content="#0a0a0a">
{jsonld}
<script defer src="https://enabler-analytics.fly.dev/t.js"></script>
<style>
*{{box-sizing:border-box;margin:0;padding:0}}
body{{background:#0a0a0a;color:#e8e8ea;font-family:-apple-system,'Hiragino Sans','Yu Gothic',sans-serif;line-height:1.8}}
.wrap{{max-width:760px;margin:0 auto;padding:40px 20px 80px}}
.bc{{font-size:12px;color:#888;margin:0 0 18px}}.bc a{{color:#8ad;text-decoration:none}}
.eyebrow{{font-size:11px;letter-spacing:.3em;color:#8ad;margin-bottom:12px}}
h1{{font-size:clamp(26px,5vw,40px);font-weight:700;line-height:1.3;margin:0 0 16px}}
.lead{{font-size:16px;color:#bcbcc4;margin:0 0 26px}}
ul.feat{{list-style:none;margin:0 0 28px}}ul.feat li{{padding:10px 0 10px 26px;border-bottom:1px solid #1c1c22;position:relative}}
ul.feat li::before{{content:"✓";position:absolute;left:0;color:#5c9}}
.cta{{display:inline-block;background:#5c9;color:#0a0a0a;padding:14px 28px;font-weight:700;text-decoration:none;border-radius:8px;font-size:15px}}
.cta.alt{{background:transparent;color:#8ad;border:1px solid #46c}}
.chips{{display:flex;flex-wrap:wrap;gap:8px;margin:14px 0 0}}
.chip{{font-size:12px;color:#cde;border:1px solid #234;background:#0e1620;padding:5px 10px;border-radius:99px;text-decoration:none}}
h2.sec{{font-size:18px;color:#8ad;margin:36px 0 14px}}
.note{{font-size:12px;color:#888;margin:30px 0 0;border-top:1px solid #1c1c22;padding-top:14px}}
</style></head><body><div class=wrap>{body}
<p class=note>Koe は Mac 上で動く音声 AI エージェントです。<a href="/">トップ</a> ／ <a href="/pricing">料金</a> ／ <a href="/support">サポート</a></p>
</div></body></html>"##)
}

async fn use_cases_index() -> Html<String> {
    let canonical = "https://koe.live/use-cases";
    let ld = r#"<script type="application/ld+json">{"@context":"https://schema.org","@type":"CollectionPage","name":"Koe の使い方・ユースケース","url":"https://koe.live/use-cases"}</script>"#;
    let mut cards = String::new();
    for (slug, label, lead, _f) in USE_CASES.iter() {
        cards.push_str(&format!("<a class=chip href=\"/use-cases/{slug}\">{label}</a>"));
        let _ = lead;
    }
    let mut sections = String::new();
    for (slug, label, lead, _f) in USE_CASES.iter() {
        sections.push_str(&format!("<h2 class=sec><a href=\"/use-cases/{slug}\" style=\"color:inherit;text-decoration:none\">{label} →</a></h2><p class=lead>{lead}</p>"));
    }
    let body = format!(r##"<nav class=bc><a href="/">Koe</a> ／ 使い方</nav>
<div class=eyebrow>USE CASES</div>
<h1>Koe でできること</h1>
<p class=lead>「声で、Mac を操る」音声 AI エージェント Koe の使い方を、目的別にまとめました。会議の文字起こしから、声での Mac 操作まで。</p>
<a class=cta href="/">Mac に入れる →</a>
<a class="cta alt" href="/pricing" style="margin-left:8px">料金を見る</a>
{sections}"##);
    Html(uc_shell(
        "Koe の使い方・ユースケース｜Mac の音声文字起こし・声で操作",
        "声で Mac を操る音声 AI エージェント Koe の使い方を目的別に。会議文字起こし(Zoom/Teams・話者分離・AI要約)、声での Mac 操作、ローカル処理、議事録自動化、リアルタイム文字起こし。",
        canonical, ld, &body))
}

async fn use_case_page(axum::extract::Path(slug): axum::extract::Path<String>) -> axum::response::Response {
    let item = USE_CASES.iter().find(|(s, ..)| *s == slug.as_str());
    let (slug, label, lead, feats) = match item {
        Some(e) => *e,
        None => return axum::response::Redirect::permanent("/use-cases").into_response(),
    };
    let canonical = format!("https://koe.live/use-cases/{slug}");
    let feat_li: String = feats.split('|').map(|f| format!("<li>{f}</li>")).collect();
    let mut siblings = String::new();
    for (s, l, _, _) in USE_CASES.iter() {
        if *s == slug { continue; }
        siblings.push_str(&format!("<a class=chip href=\"/use-cases/{s}\">{l}</a>"));
    }
    let faq = format!(r#"<script type="application/ld+json">{{"@context":"https://schema.org","@type":"FAQPage","mainEntity":[{{"@type":"Question","name":"{label}は無料で使えますか？","acceptedAnswer":{{"@type":"Answer","text":"Koe は Mac にインストールして使う音声 AI エージェントです。無料で試せます。詳しくは料金ページをご覧ください。"}}}}]}}</script>
<script type="application/ld+json">{{"@context":"https://schema.org","@type":"BreadcrumbList","itemListElement":[{{"@type":"ListItem","position":1,"name":"使い方","item":"https://koe.live/use-cases"}},{{"@type":"ListItem","position":2,"name":"{label}","item":"{canonical}"}}]}}</script>"#);
    let body = format!(r##"<nav class=bc><a href="/use-cases">使い方</a> ／ {label}</nav>
<div class=eyebrow>USE CASE</div>
<h1>{label}</h1>
<p class=lead>{lead}</p>
<ul class=feat>{feat_li}</ul>
<a class=cta href="/">Mac に入れて試す →</a>
<a class="cta alt" href="/pricing" style="margin-left:8px">料金を見る</a>
<h2 class=sec>ほかの使い方</h2>
<div class=chips>{siblings}</div>"##);
    Html(uc_shell(
        &format!("{label}｜Koe — 声で動く Mac の音声 AI"),
        &format!("{lead} Koe は Mac 上で動く音声 AI エージェント。", ),
        &canonical, &faq, &body)).into_response()
}

async fn sitemap_xml() -> impl IntoResponse {
    (
        [("content-type", "application/xml; charset=utf-8"), ("cache-control", "public, max-age=3600")],
        SITEMAP_XML,
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
        .route("/support", get(|| async { Html(SUPPORT) }))
        .route("/use-cases", get(use_cases_index))
        .route("/use-cases/:slug", get(use_case_page))
        .route("/api/checkout", get(stripe_checkout))
        .route("/api/license", get(verify_license))
        .route("/og.svg", get(og_image_svg))
        .route("/og.png", get(og_image_png))
        .route("/install.sh", get(install_script))
        .route("/elio-icon.png", get(elio_icon))
        .route("/robots.txt", get(robots_txt))
        .route("/sitemap.xml", get(sitemap_xml))
        .route("/api/event", post(track_event).options(track_options))
        .route("/api/stats", get(get_stats))
        .with_state(analytics);

    println!("Listening on {addr}");
    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
