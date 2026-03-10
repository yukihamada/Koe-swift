use axum::{
    response::{Html, IntoResponse},
    routing::get,
    Router,
};

const PAGE: &str = include_str!("../index.html");
const OG_SVG: &str = include_str!("../og.svg");
const INSTALL_SH: &str = include_str!("../install.sh");

async fn og_image() -> impl IntoResponse {
    (
        [("content-type", "image/svg+xml"), ("cache-control", "public, max-age=86400")],
        OG_SVG,
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
    let app = Router::new()
        .route("/", get(|| async { Html(PAGE) }))
        .route("/og.svg", get(og_image))
        .route("/install.sh", get(install_script));
    println!("Listening on {addr}");
    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
