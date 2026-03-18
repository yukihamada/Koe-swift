// Soluna プロトコル — Windows クライアント
// UDP マルチキャスト + IMA-ADPCM 4:1圧縮
// ESP32ファームウェアと完全互換のパケットフォーマット
//
// パケット: [magic 2B][device_id 4B][seq 4B][channel 4B][ntp_ms 4B][flags 1B][audio ADPCM]
// ヘッダ: 19 bytes

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use log::{error, info};
use std::net::{Ipv4Addr, SocketAddrV4, UdpSocket};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

// --- プロトコル定数 (ESP32と同一) ---
const MULTICAST_ADDR: Ipv4Addr = Ipv4Addr::new(239, 42, 42, 1);
const MULTICAST_PORT: u16 = 4242;
const MAGIC: [u8; 2] = [0x53, 0x4C]; // "SL"
const HEADER_SIZE: usize = 19;
const MAX_AUDIO_PER_PACKET: usize = 512;
const PACKET_BUF_SIZE: usize = HEADER_SIZE + MAX_AUDIO_PER_PACKET;

// フラグ
const FLAG_ADPCM: u8 = 0x01;
const FLAG_HEARTBEAT: u8 = 0x04;

// タイミング
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(5);
const PEER_TIMEOUT_SEC: u32 = 10;

// 音声パラメータ (ESP32と同じ16kHz mono)
const SAMPLE_RATE: u32 = 16000;
const CAPTURE_CHUNK_SAMPLES: usize = 1024; // 64ms分 → 512バイトADPCM

// --- IMA-ADPCM テーブル (ESP32と完全同一) ---
const STEP_TABLE: [i16; 89] = [
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
    34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
    157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544,
    598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707,
    1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
    5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635,
    13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
];

const INDEX_TABLE: [i8; 16] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8];

// --- ADPCM コーデック ---

#[derive(Clone, Copy)]
struct AdpcmState {
    predicted: i16,
    step_index: u8,
}

impl AdpcmState {
    fn new() -> Self {
        Self {
            predicted: 0,
            step_index: 0,
        }
    }
}

/// f32 PCM (-1.0..1.0) → ADPCM 4bit (2サンプル/バイト)
fn adpcm_encode_f32(pcm: &[f32], out: &mut [u8], state: &mut AdpcmState) -> usize {
    let n_samples = pcm.len();
    let out_len = (n_samples + 1) / 2;
    if out.len() < out_len {
        return 0;
    }

    let mut out_idx = 0;
    let mut nibble_hi = false;

    for &sample_f in pcm {
        let sample = (sample_f * 32767.0).clamp(-32768.0, 32767.0) as i16;
        let step = STEP_TABLE[state.step_index as usize] as i32;

        let mut diff = sample as i32 - state.predicted as i32;
        let mut code: u8 = 0;
        if diff < 0 {
            code = 8;
            diff = -diff;
        }

        if diff >= step {
            code |= 4;
            diff -= step;
        }
        if diff >= step >> 1 {
            code |= 2;
            diff -= step >> 1;
        }
        if diff >= step >> 2 {
            code |= 1;
        }

        // デコードして予測値更新 (エンコーダ内蔵デコーダ)
        let mut delta = step >> 3;
        if code & 4 != 0 {
            delta += step;
        }
        if code & 2 != 0 {
            delta += step >> 1;
        }
        if code & 1 != 0 {
            delta += step >> 2;
        }
        if code & 8 != 0 {
            delta = -delta;
        }

        state.predicted = (state.predicted as i32 + delta).clamp(-32768, 32767) as i16;

        let new_idx = (state.step_index as i8 + INDEX_TABLE[code as usize]).clamp(0, 88);
        state.step_index = new_idx as u8;

        if nibble_hi {
            out[out_idx] |= code << 4;
            out_idx += 1;
        } else {
            out[out_idx] = code & 0x0F;
        }
        nibble_hi = !nibble_hi;
    }

    out_len
}

/// ADPCM 4bit → f32 PCM (-1.0..1.0)
fn adpcm_decode_f32(adpcm: &[u8], out: &mut [f32], state: &mut AdpcmState) -> usize {
    let n_samples = adpcm.len() * 2;
    if out.len() < n_samples {
        return 0;
    }

    let mut out_idx = 0;
    for &byte in adpcm {
        for nibble_idx in 0..2u8 {
            let code = if nibble_idx == 0 {
                byte & 0x0F
            } else {
                byte >> 4
            };
            let step = STEP_TABLE[state.step_index as usize] as i32;

            let mut delta = step >> 3;
            if code & 4 != 0 {
                delta += step;
            }
            if code & 2 != 0 {
                delta += step >> 1;
            }
            if code & 1 != 0 {
                delta += step >> 2;
            }
            if code & 8 != 0 {
                delta = -delta;
            }

            state.predicted = (state.predicted as i32 + delta).clamp(-32768, 32767) as i16;

            let new_idx = (state.step_index as i8 + INDEX_TABLE[code as usize]).clamp(0, 88);
            state.step_index = new_idx as u8;

            out[out_idx] = state.predicted as f32 / 32768.0;
            out_idx += 1;
        }
    }

    n_samples
}

// --- FNV-1a ハッシュ (ESP32と同一) ---

fn fnv1a(data: &[u8]) -> u32 {
    let mut h: u32 = 0x811c9dc5;
    for &b in data {
        h ^= b as u32;
        h = h.wrapping_mul(0x01000193);
    }
    h
}

// --- NTPタイムスタンプ (簡易: SystemTimeベース) ---

fn ntp_now_ms() -> u32 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u32
}

// --- ジッタバッファ (f32 PCMリングバッファ) ---

struct JitterBuffer {
    buf: Vec<f32>,
    write_pos: usize,
    read_pos: usize,
    len: usize,
    capacity: usize,
}

impl JitterBuffer {
    fn new(capacity: usize) -> Self {
        Self {
            buf: vec![0.0; capacity],
            write_pos: 0,
            read_pos: 0,
            len: 0,
            capacity,
        }
    }

    fn push(&mut self, samples: &[f32]) {
        for &s in samples {
            if self.len == self.capacity {
                self.read_pos = (self.read_pos + 1) % self.capacity;
                self.len -= 1;
            }
            self.buf[self.write_pos] = s;
            self.write_pos = (self.write_pos + 1) % self.capacity;
            self.len += 1;
        }
    }

    fn pop(&mut self, out: &mut [f32]) -> usize {
        let to_read = out.len().min(self.len);
        for i in 0..to_read {
            out[i] = self.buf[self.read_pos];
            self.read_pos = (self.read_pos + 1) % self.capacity;
        }
        self.len -= to_read;
        to_read
    }

    fn available(&self) -> usize {
        self.len
    }

    fn clear(&mut self) {
        self.write_pos = 0;
        self.read_pos = 0;
        self.len = 0;
    }
}

// --- ピア管理 ---

#[derive(Clone, Copy)]
struct PeerInfo {
    hash: u32,
    last_seen: Instant,
    decode_state: AdpcmState,
}

impl PeerInfo {
    fn new() -> Self {
        Self {
            hash: 0,
            last_seen: Instant::now(),
            decode_state: AdpcmState::new(),
        }
    }

    fn is_active(&self) -> bool {
        self.hash != 0 && self.last_seen.elapsed().as_secs() <= PEER_TIMEOUT_SEC as u64
    }
}

// --- Soluna クライアント ---

/// Solunaモード全体の状態 (スレッド間共有)
pub struct SolunaState {
    active: Arc<AtomicBool>,
    channel_name: Arc<Mutex<String>>,
    channel_hash: Arc<AtomicU32>,
    device_hash: u32,
    peer_count: Arc<AtomicU32>,
}

impl SolunaState {
    pub fn is_active(&self) -> bool {
        self.active.load(Ordering::Relaxed)
    }

    pub fn channel_name(&self) -> String {
        self.channel_name.lock().unwrap().clone()
    }

    pub fn peer_count(&self) -> u32 {
        self.peer_count.load(Ordering::Relaxed)
    }
}

/// Solunaクライアント (メインスレッドから制御)
pub struct SolunaClient {
    pub state: Arc<SolunaState>,
    /// 停止フラグ (スレッドに通知)
    stop_flag: Arc<AtomicBool>,
    /// ワーカースレッドのJoinHandle
    worker_handle: Option<std::thread::JoinHandle<()>>,
}

impl SolunaClient {
    pub fn new() -> Self {
        let hostname = hostname::get()
            .map(|h| h.to_string_lossy().to_string())
            .unwrap_or_else(|_| "koe-windows".to_string());
        let device_hash = fnv1a(hostname.as_bytes());

        let state = Arc::new(SolunaState {
            active: Arc::new(AtomicBool::new(false)),
            channel_name: Arc::new(Mutex::new("soluna".to_string())),
            channel_hash: Arc::new(AtomicU32::new(fnv1a(b"soluna"))),
            device_hash,
            peer_count: Arc::new(AtomicU32::new(0)),
        });

        Self {
            state,
            stop_flag: Arc::new(AtomicBool::new(false)),
            worker_handle: None,
        }
    }

    /// Solunaモードを開始
    pub fn start(&mut self) {
        if self.state.is_active() {
            return;
        }

        info!(
            "Soluna: starting (device={:#010x}, channel={})",
            self.state.device_hash,
            self.state.channel_name()
        );

        self.state.active.store(true, Ordering::Relaxed);
        self.stop_flag.store(false, Ordering::Relaxed);

        let state = self.state.clone();
        let stop_flag = self.stop_flag.clone();

        self.worker_handle = Some(std::thread::spawn(move || {
            if let Err(e) = soluna_worker(state, stop_flag) {
                error!("Soluna worker error: {}", e);
            }
        }));
    }

    /// Solunaモードを停止
    pub fn stop(&mut self) {
        if !self.state.is_active() {
            return;
        }

        info!("Soluna: stopping");
        self.state.active.store(false, Ordering::Relaxed);
        self.stop_flag.store(true, Ordering::Relaxed);

        if let Some(handle) = self.worker_handle.take() {
            let _ = handle.join();
        }

        self.state.peer_count.store(0, Ordering::Relaxed);
        info!("Soluna: stopped");
    }

    /// Soluna ON/OFF トグル
    pub fn toggle(&mut self) {
        if self.state.is_active() {
            self.stop();
        } else {
            self.start();
        }
    }

    /// チャンネル変更
    pub fn set_channel(&self, channel: &str) {
        *self.state.channel_name.lock().unwrap() = channel.to_string();
        self.state
            .channel_hash
            .store(fnv1a(channel.as_bytes()), Ordering::Relaxed);
        info!("Soluna: channel changed to '{}'", channel);
    }
}

impl Drop for SolunaClient {
    fn drop(&mut self) {
        self.stop();
    }
}

// --- ワーカースレッド ---

/// UDPマルチキャスト + 音声キャプチャ/再生のメインループ
fn soluna_worker(state: Arc<SolunaState>, stop_flag: Arc<AtomicBool>) -> Result<(), String> {
    // UDPソケット作成
    let socket = UdpSocket::bind(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, MULTICAST_PORT))
        .map_err(|e| format!("UDP bind failed: {}", e))?;

    socket
        .join_multicast_v4(&MULTICAST_ADDR, &Ipv4Addr::UNSPECIFIED)
        .map_err(|e| format!("Multicast join failed: {}", e))?;

    socket
        .set_nonblocking(true)
        .map_err(|e| format!("Set nonblocking failed: {}", e))?;

    // マルチキャスト送信先
    let dest = SocketAddrV4::new(MULTICAST_ADDR, MULTICAST_PORT);

    info!(
        "Soluna: UDP socket ready ({}:{})",
        MULTICAST_ADDR, MULTICAST_PORT
    );

    // 共有バッファ: キャプチャスレッド → ワーカースレッド
    let capture_buf: Arc<Mutex<Vec<f32>>> = Arc::new(Mutex::new(Vec::new()));
    // 再生バッファ: ワーカースレッド → 再生スレッド
    let playback_jitter: Arc<Mutex<JitterBuffer>> =
        Arc::new(Mutex::new(JitterBuffer::new(SAMPLE_RATE as usize * 2))); // 2秒分

    // ピア管理
    let mut peers: [PeerInfo; 8] = [PeerInfo::new(); 8];
    let mut encode_state = AdpcmState::new();
    let mut seq: u32 = 0;

    // 音声キャプチャ開始
    let capture_stream = start_capture(capture_buf.clone(), stop_flag.clone())?;

    // 音声再生開始
    let playback_stream = start_playback(playback_jitter.clone(), stop_flag.clone())?;

    // Heartbeatタイマー
    let mut last_heartbeat = Instant::now();

    info!("Soluna: audio capture & playback started");

    // メインループ
    while !stop_flag.load(Ordering::Relaxed) {
        // 1. キャプチャバッファからPCMを取得 → ADPCM → 送信
        {
            let mut buf = capture_buf.lock().unwrap();
            while buf.len() >= CAPTURE_CHUNK_SAMPLES {
                let chunk: Vec<f32> = buf.drain(..CAPTURE_CHUNK_SAMPLES).collect();

                // ADPCM エンコード
                let mut adpcm_buf = [0u8; MAX_AUDIO_PER_PACKET];
                let adpcm_len = adpcm_encode_f32(&chunk, &mut adpcm_buf, &mut encode_state);

                if adpcm_len > 0 {
                    // パケット構築
                    let mut packet = [0u8; PACKET_BUF_SIZE];
                    let pkt_len = build_audio_packet(
                        &state,
                        seq,
                        &adpcm_buf[..adpcm_len],
                        &mut packet,
                    );
                    seq = seq.wrapping_add(1);

                    let _ = socket.send_to(&packet[..pkt_len], dest);
                }
            }
        }

        // 2. 受信パケット処理
        let mut recv_buf = [0u8; PACKET_BUF_SIZE];
        while let Ok((len, _addr)) = socket.recv_from(&mut recv_buf) {
            if len < HEADER_SIZE {
                continue;
            }

            let packet = &recv_buf[..len];

            // マジック確認
            if packet[0] != MAGIC[0] || packet[1] != MAGIC[1] {
                continue;
            }

            let sender_hash =
                u32::from_le_bytes([packet[2], packet[3], packet[4], packet[5]]);

            // 自分自身のパケット → スキップ (エコー防止)
            if sender_hash == state.device_hash {
                continue;
            }

            // チャンネル確認
            let ch = u32::from_le_bytes([packet[10], packet[11], packet[12], packet[13]]);
            let my_ch = state.channel_hash.load(Ordering::Relaxed);
            if ch != my_ch {
                continue;
            }

            let flags = packet[18];

            // Heartbeat
            if flags & FLAG_HEARTBEAT != 0 {
                register_peer(&mut peers, sender_hash, &state.peer_count);
                continue;
            }

            // 音声パケット
            if flags & FLAG_ADPCM != 0 && len > HEADER_SIZE {
                let peer_idx = register_peer(&mut peers, sender_hash, &state.peer_count);
                let audio_data = &packet[HEADER_SIZE..len];

                let decode_state = if let Some(idx) = peer_idx {
                    &mut peers[idx].decode_state
                } else {
                    // ピアスロット満杯 — 一時デコードstate使用
                    continue;
                };

                let mut pcm_buf = vec![0.0f32; audio_data.len() * 2];
                let decoded = adpcm_decode_f32(audio_data, &mut pcm_buf, decode_state);

                if decoded > 0 {
                    let mut jitter = playback_jitter.lock().unwrap();
                    jitter.push(&pcm_buf[..decoded]);
                }
            }
        }

        // 3. Heartbeat送信 (5秒間隔)
        if last_heartbeat.elapsed() >= HEARTBEAT_INTERVAL {
            let mut packet = [0u8; PACKET_BUF_SIZE];
            let pkt_len = build_heartbeat_packet(&state, &mut packet);
            let _ = socket.send_to(&packet[..pkt_len], dest);
            last_heartbeat = Instant::now();
        }

        // 4. ピアのタイムアウトチェック
        let mut active_count = 0u32;
        for peer in &peers {
            if peer.is_active() {
                active_count += 1;
            }
        }
        state.peer_count.store(active_count, Ordering::Relaxed);

        // CPU負荷軽減: 短いスリープ (4ms ≈ 256サンプル分)
        std::thread::sleep(Duration::from_millis(4));
    }

    // クリーンアップ
    drop(capture_stream);
    drop(playback_stream);
    let _ = socket.leave_multicast_v4(&MULTICAST_ADDR, &Ipv4Addr::UNSPECIFIED);
    info!("Soluna: worker stopped");

    Ok(())
}

// --- パケット構築 ---

/// 音声パケット構築 (ADPCM圧縮済みデータをラップ)
fn build_audio_packet(
    state: &SolunaState,
    seq: u32,
    adpcm: &[u8],
    out: &mut [u8; PACKET_BUF_SIZE],
) -> usize {
    out[0..2].copy_from_slice(&MAGIC);
    out[2..6].copy_from_slice(&state.device_hash.to_le_bytes());
    out[6..10].copy_from_slice(&seq.to_le_bytes());
    let ch_hash = state.channel_hash.load(Ordering::Relaxed);
    out[10..14].copy_from_slice(&ch_hash.to_le_bytes());
    out[14..18].copy_from_slice(&ntp_now_ms().to_le_bytes());
    out[18] = FLAG_ADPCM;

    let copy_len = adpcm.len().min(MAX_AUDIO_PER_PACKET);
    out[HEADER_SIZE..HEADER_SIZE + copy_len].copy_from_slice(&adpcm[..copy_len]);

    HEADER_SIZE + copy_len
}

/// Heartbeatパケット構築 (音声なし、ヘッダのみ)
fn build_heartbeat_packet(state: &SolunaState, out: &mut [u8; PACKET_BUF_SIZE]) -> usize {
    out[0..2].copy_from_slice(&MAGIC);
    out[2..6].copy_from_slice(&state.device_hash.to_le_bytes());
    out[6..10].copy_from_slice(&0u32.to_le_bytes());
    let ch_hash = state.channel_hash.load(Ordering::Relaxed);
    out[10..14].copy_from_slice(&ch_hash.to_le_bytes());
    out[14..18].copy_from_slice(&ntp_now_ms().to_le_bytes());
    out[18] = FLAG_HEARTBEAT;
    HEADER_SIZE
}

// --- ピア管理 ---

fn register_peer(
    peers: &mut [PeerInfo; 8],
    peer_hash: u32,
    peer_count: &Arc<AtomicU32>,
) -> Option<usize> {
    // 既存ピア
    for i in 0..8 {
        if peers[i].hash == peer_hash {
            peers[i].last_seen = Instant::now();
            return Some(i);
        }
    }
    // 空きスロットまたは期限切れスロット
    for i in 0..8 {
        if peers[i].hash == 0 || !peers[i].is_active() {
            peers[i] = PeerInfo::new();
            peers[i].hash = peer_hash;
            peers[i].last_seen = Instant::now();

            let count = peers.iter().filter(|p| p.is_active()).count();
            peer_count.store(count as u32, Ordering::Relaxed);
            info!("Soluna: peer +1 ({:#010x}), total={}", peer_hash, count);
            return Some(i);
        }
    }
    None
}

// --- 音声キャプチャ (cpal) ---

/// マイク入力を開始し、f32 PCMをバッファに書き込む
fn start_capture(
    buf: Arc<Mutex<Vec<f32>>>,
    stop_flag: Arc<AtomicBool>,
) -> Result<cpal::Stream, String> {
    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .ok_or("Soluna: no input device found")?;

    info!(
        "Soluna: capture device: {}",
        device.name().unwrap_or_default()
    );

    let config = cpal::StreamConfig {
        channels: 1,
        sample_rate: cpal::SampleRate(SAMPLE_RATE),
        buffer_size: cpal::BufferSize::Default,
    };

    let stream = device
        .build_input_stream(
            &config,
            move |data: &[f32], _: &cpal::InputCallbackInfo| {
                if stop_flag.load(Ordering::Relaxed) {
                    return;
                }
                let mut b = buf.lock().unwrap();
                b.extend_from_slice(data);
            },
            move |err| {
                error!("Soluna: capture error: {}", err);
            },
            None,
        )
        .map_err(|e| format!("Soluna: failed to build capture stream: {}", e))?;

    stream
        .play()
        .map_err(|e| format!("Soluna: failed to start capture: {}", e))?;

    Ok(stream)
}

// --- 音声再生 (cpal) ---

/// スピーカー出力を開始し、ジッタバッファからf32 PCMを読み出す
fn start_playback(
    jitter: Arc<Mutex<JitterBuffer>>,
    stop_flag: Arc<AtomicBool>,
) -> Result<cpal::Stream, String> {
    let host = cpal::default_host();
    let device = host
        .default_output_device()
        .ok_or("Soluna: no output device found")?;

    info!(
        "Soluna: playback device: {}",
        device.name().unwrap_or_default()
    );

    let config = cpal::StreamConfig {
        channels: 1,
        sample_rate: cpal::SampleRate(SAMPLE_RATE),
        buffer_size: cpal::BufferSize::Default,
    };

    let stream = device
        .build_output_stream(
            &config,
            move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                if stop_flag.load(Ordering::Relaxed) {
                    for s in data.iter_mut() {
                        *s = 0.0;
                    }
                    return;
                }
                let mut jb = jitter.lock().unwrap();
                let read = jb.pop(data);
                // バッファ不足分は無音
                for s in &mut data[read..] {
                    *s = 0.0;
                }
            },
            move |err| {
                error!("Soluna: playback error: {}", err);
            },
            None,
        )
        .map_err(|e| format!("Soluna: failed to build playback stream: {}", e))?;

    stream
        .play()
        .map_err(|e| format!("Soluna: failed to start playback: {}", e))?;

    Ok(stream)
}

// --- プリセットチャンネル (ESP32と同一) ---

pub const CHANNELS: &[&str] = &["soluna", "voice", "music", "ambient"];
