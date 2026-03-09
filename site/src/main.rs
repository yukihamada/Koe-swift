use axum::{response::Html, routing::get, Router};

const PAGE: &str = include_str!("../index.html");

#[tokio::main]
async fn main() {
    let port = std::env::var("PORT").unwrap_or_else(|_| "8080".into());
    let addr = format!("0.0.0.0:{port}");
    let app = Router::new().route("/", get(|| async { Html(PAGE) }));
    println!("Listening on {addr}");
    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
