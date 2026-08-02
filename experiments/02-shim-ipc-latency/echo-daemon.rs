// Spike: minimal echo daemon for measuring shim<->daemon round-trip latency.
// std only, compiled with plain rustc — this is evidence for ADR-100's
// protocol section, not product code.
//
// Serves a Unix socket. Each request is one newline-terminated line; each
// reply is one ~2KB newline-terminated line, sized like a rendered card
// (JSON with text and span offsets).

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;

fn main() {
    let path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "/tmp/clicue-spike.sock".to_string());
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path).expect("bind");

    // Card-sized single-line payload, multibyte glyphs included on purpose.
    let mut payload = String::with_capacity(2200);
    while payload.len() < 2000 {
        payload.push_str(r#"{"line":"│ ▸ cargo  ─ Rust package manager │","spans":[0,42,"fg=#a277ff"]}"#);
    }
    payload.push('\n');

    for stream in listener.incoming() {
        let stream = stream.expect("accept");
        let payload = payload.clone();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stream.try_clone().expect("clone"));
            let mut stream = stream;
            let mut line = String::new();
            loop {
                line.clear();
                match reader.read_line(&mut line) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {
                        if stream.write_all(payload.as_bytes()).is_err() {
                            break;
                        }
                    }
                }
            }
        });
    }
}
