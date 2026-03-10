fn main() {
    // Windows: embed app manifest + icon (only when icon file exists)
    #[cfg(target_os = "windows")]
    {
        if std::path::Path::new("assets/koe.ico").exists() {
            let mut res = winresource::WindowsResource::new();
            res.set_icon("assets/koe.ico");
            res.set("ProductName", "Koe");
            res.set("FileDescription", "Koe — Ultra-fast voice input");
            res.set("CompanyName", "EnablerDAO");
            res.set("LegalCopyright", "Copyright 2026 Yuki Hamada");
            let _ = res.compile();
        }
    }
}
