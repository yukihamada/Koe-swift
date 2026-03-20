//
//  AudioReceiverBridge.h
//  SolunaReceiver
//
//  Objective-C bridge for Swift interop with C++ audio receiver
//

#import <Foundation/Foundation.h>
#import <CoreMotion/CMHeadphoneMotionManager.h>

NS_ASSUME_NONNULL_BEGIN

/// Device health state based on underrun rate
typedef NS_ENUM(NSInteger, SolunaDeviceHealth) {
    SolunaDeviceHealthGood     = 0,  ///< Functioning normally
    SolunaDeviceHealthStressed = 1,  ///< High underrun rate, buffer auto-increased
    SolunaDeviceHealthSilenced = 2,  ///< Silenced to prevent noise (extreme underruns)
};

/// Receiver state enumeration
typedef NS_ENUM(NSInteger, SolunaReceiverState) {
    SolunaReceiverStateStopped = 0,
    SolunaReceiverStateConnecting,
    SolunaReceiverStateReceiving,
    SolunaReceiverStateError
};

/// Statistics from the receiver
@interface SolunaReceiverStats : NSObject
@property (nonatomic, readonly) uint64_t packetsReceived;
@property (nonatomic, readonly) uint64_t packetsDropped;
@property (nonatomic, readonly) uint64_t packetsConcealed;
@property (nonatomic, readonly) uint64_t sequenceErrors;
@property (nonatomic, readonly) uint64_t aes67Packets;
@property (nonatomic, readonly) uint64_t ostpPackets;
@end

/// Delegate protocol for receiver state changes
@protocol SolunaReceiverDelegate <NSObject>
@optional
- (void)receiverDidChange:(SolunaReceiverState)state;
- (void)receiverDidUpdate:(SolunaReceiverStats *)stats;
- (void)receiverDidEncounter:(NSError *)error;
@end

/// WAN relay connection state
typedef NS_ENUM(NSInteger, SolunaRelayState) {
    SolunaRelayStateDisconnected = 0,
    SolunaRelayStateConnecting,
    SolunaRelayStateConnected,
    SolunaRelayStateError
};

/// Main audio receiver bridge class
@interface SolunaAudioReceiver : NSObject

/// Current receiver state
@property (nonatomic, readonly) SolunaReceiverState state;

/// Volume (0.0 - 1.0)
@property (nonatomic, assign) float volume;

/// Muted state
@property (nonatomic, assign) BOOL muted;

/// Delegate for callbacks
@property (nonatomic, weak, nullable) id<SolunaReceiverDelegate> delegate;

/// Multicast group address (default: 239.69.0.1)
@property (nonatomic, copy) NSString *multicastGroup;

/// RTP port (default: 5004)
@property (nonatomic, assign) uint16_t port;

/// Number of channels (default: 1)
@property (nonatomic, assign) uint32_t channels;

/// Jitter buffer target in milliseconds (5–2000 ms, default 40 ms)
@property (nonatomic, assign) uint32_t bufferTargetMs;

/// Current device health (good / stressed / silenced)
@property (nonatomic, readonly) SolunaDeviceHealth deviceHealth;

/// When YES, the receive loop ignores multicast packets.
/// Audio only arrives via -injectRawPacket: (peer relay mode).
@property (nonatomic, assign) BOOL networkDisabled;

/// File-sync specific network disable flag (separate from WAN relay).
@property (nonatomic, assign) BOOL filesyncNetworkDisabled;

/// Singleton instance
+ (instancetype)sharedInstance;

/// Initialize with custom settings
- (instancetype)initWithMulticastGroup:(NSString *)group
                                  port:(uint16_t)port
                              channels:(uint32_t)channels;

/// Start receiving and playing audio
- (BOOL)start;

/// Stop receiving and playing audio
- (void)stop;

/// Get current statistics
- (SolunaReceiverStats *)currentStats;

// ── P2P Relay ──────────────────────────────────────────────────────────────

/// Set callback invoked for every raw RTP/OSTP packet received from the network.
/// Used in relay mode to forward packets to nearby peers via MultipeerConnectivity.
/// Pass nil to disable. Thread-safe.
- (void)setRelayCallback:(nullable void(^)(NSData * _Nonnull rawPacket))callback;

/// Inject a raw RTP/OSTP packet received from a relay peer.
/// The packet is parsed and fed directly into the audio ring buffer,
/// bypassing the UDP socket. Thread-safe.
- (void)injectRawPacket:(NSData * _Nonnull)data;

/// Inject decoded PCM samples directly into the ring buffer.
- (void)injectPcmSamples:(NSData * _Nonnull)data frameCount:(NSUInteger)frameCount;

/// Flush the ring buffer and reset prefill state for clean file-sync start.
- (void)flushRingBuffer;

// ── WAN Relay ────────────────────────────────────────────────────────────

/// Connect to WAN relay server. Returns NO on immediate failure.
- (BOOL)connectToRelay:(NSString *)host port:(uint16_t)port
                 group:(NSString *)group password:(NSString *)password;

- (BOOL)connectToRelay:(NSString *)host port:(uint16_t)port
                 group:(NSString *)group password:(NSString *)password
              deviceId:(NSString *)deviceId;

/// Send MIC_ALLOW command for a specific device (owner/DJ only)
- (void)sendMicAllow:(NSString *)deviceId;

/// Send MIC_DENY command for a specific device (owner/DJ only)
- (void)sendMicDeny:(NSString *)deviceId;

/// Request mic list from relay
- (void)requestMicList;

/// Request members list from relay
- (void)requestMembers;

/// Send remote volume command to a specific device in the same group
- (void)sendVolumeToDevice:(NSString *)deviceId level:(int)level;

/// Disconnect from WAN relay.
- (void)disconnectRelay;

/// Forward raw audio packet to all WAN relay peers (relay server + P2P).
/// Call this when acting as a local relay to extend reach over the internet.
- (void)sendAudioViaWanRelay:(NSData * _Nonnull)data;

/// Current relay connection state.
@property (nonatomic, readonly) SolunaRelayState relayState;

/// Currently joined relay group name (nil if disconnected).
@property (nonatomic, readonly, copy, nullable) NSString *relayGroup;

/// Relay error message (nil if no error).
@property (nonatomic, readonly, copy, nullable) NSString *relayError;

/// External IP:port as reported by relay YOUR_ADDR response (§6.6).
/// Non-nil once the relay has responded to JOIN. Useful for P2P diagnostics.
@property (nonatomic, readonly, copy, nullable) NSString *relayExternalAddr;

// ── Sync Mode ─────────────────────────────────────────────────────────────

/// Synchronized playback mode: all receivers play at the same wall-clock time.
/// Uses OSTP media_timestamp to compute ideal buffer depth for alignment.
@property (nonatomic, assign) BOOL syncMode;

/// Target end-to-end delay in ms (50-1000, default 200). Only used when syncMode=YES.
@property (nonatomic, assign) uint32_t syncDelayMs;

// ── Mic Transmit (TX) ────────────────────────────────────────────────────

/// Whether mic transmit is currently active
@property (nonatomic, readonly) BOOL isMicTransmitting;

/// Number of TX packets sent
@property (nonatomic, readonly) uint64_t txPacketsSent;

/// Mic input peak level (0.0 - 1.0), updated per audio callback
@property (nonatomic, readonly) float micInputLevel;

/// Output audio peak level (0.0 - 1.0), updated per audio callback for visualization
@property (nonatomic, readonly) float outputPeakLevel;

// ── Metadata ────────────────────────────────────────────────────────────

/// Set callback for metadata received from WAN relay (META: messages).
/// JSON string with title, artist, artwork_url fields.
- (void)setMetaCallback:(nullable void(^)(NSString * _Nonnull jsonMeta))callback;

/// Set callback for FILE: messages (file-sync mode). Filename to download.
- (void)setFileCallback:(nullable void(^)(NSString * _Nonnull filename))callback;

/// Set callback for SYNC: messages (file-sync mode). e.g. "play:0:1234567890"
- (void)setSyncCallback:(nullable void(^)(NSString * _Nonnull syncCmd))callback;

/// Send READY notification to relay after file download completes
- (void)sendReady:(NSString * _Nonnull)filename;

// ── Network Quality Stats ───────────────────────────────────────────────

/// Estimated network latency in milliseconds
@property (nonatomic, readonly) float networkLatencyMs;

/// Jitter (variation in latency) in milliseconds
@property (nonatomic, readonly) float jitterMs;

/// Packet loss percentage (0.0 - 100.0)
@property (nonatomic, readonly) float packetLossPercent;

/// When YES, mic audio is sent to WAN relay. When NO (default), sent to LAN multicast.
@property (nonatomic, assign) BOOL micGlobal;

/// Start capturing from the microphone and transmitting.
/// Sends to LAN multicast by default, or WAN relay if micGlobal=YES.
- (BOOL)startMicTransmit;

/// Karaoke mode: capture mic and mix into local audio output (no network send)
- (BOOL)startMicMonitor;
- (void)stopMicMonitor;

/// Stop mic capture and transmission. Restores AVAudioSession to .playback.
- (void)stopMicTransmit;

// ── Output Latency Compensation ───────────────────────────────────────────

/// Hardware output latency in milliseconds (Bluetooth/AirPlay).
/// Set this from AVAudioSession.outputLatency when the audio route changes.
/// The sync engine adds this to buffer target so all devices stay aligned.
@property (nonatomic, assign) float outputLatencyMs;

// ── Loudness Normalization ──────────────────────────────────────────────────

/// EBU R128 loudness normalization (target -23 LUFS). Toggleable at runtime.
@property (nonatomic, assign) BOOL loudnessNormEnabled;

// ── Spatial Audio ───────────────────────────────────────────────────────────

/// AirPods head tracking via CMHeadphoneMotionManager. Toggleable at runtime.
@property (nonatomic, assign) BOOL spatialAudioEnabled;

// ── Sample Tap (for fingerprinting) ──────────────────────────────────────

/// Set a callback that receives rendered float samples (interleaved, channels_ ch).
/// Called from the audio render callback — keep work minimal.
/// Pass nil to disable. Thread-safe.
- (void)setSampleTapCallback:(nullable void(^)(const float * _Nonnull samples, uint32_t sampleCount, uint32_t channels))callback;

// ── 3-Band EQ ─────────────────────────────────────────────────────────────

/// Set 3-band parametric EQ gain (band: 0=low 200Hz, 1=mid 1kHz, 2=high 5kHz; gain in dB, -12..+12)
- (void)setEQBand:(int)band gain:(float)gainDb;

// ── Compressor ────────────────────────────────────────────────────────────

/// Set compressor parameters (threshold dB, ratio, attack ms, release ms, enabled)
- (void)setCompressorThreshold:(float)thresh ratio:(float)ratio attack:(float)attackMs release:(float)releaseMs enabled:(BOOL)enabled;

// ── Recording ─────────────────────────────────────────────────────────────

/// Start recording received audio to a WAV file at the given path.
/// Returns YES on success. Recording captures primary output audio.
- (BOOL)startRecordingToFile:(NSString *)path;

/// Stop recording and finalize the WAV file.
- (void)stopRecording;

/// Whether currently recording
@property (nonatomic, readonly) BOOL isRecording;

/// Debug log string for on-screen diagnostics (LAN discovery, relay, recv stats)
@property (nonatomic, readonly, copy) NSString *debugLog;

// ── Talk Mode (multi-speaker) ─────────────────────────────────────────────

/// Enable/disable talk mode (multiple simultaneous speakers).
/// Sends TALK:on/off to relay and enables multi-source audio mixing.
- (void)setTalkMode:(BOOL)enabled;

// ── DJ Mode ──────────────────────────────────────────────────────────────

/// Start DJ broadcast: decode audio file and stream via OSTP to relay
- (BOOL)startDJBroadcast:(NSString *)filePath;

/// Stop DJ broadcast
- (void)stopDJ;

/// Skip to next track (for playlist mode)
- (void)skipDJTrack;

/// Whether DJ mode is active
@property (nonatomic, readonly) BOOL isDJActive;

/// Current track filename
@property (nonatomic, readonly, copy, nullable) NSString *djCurrentTrack;

/// Playback progress (0.0 - 1.0)
@property (nonatomic, readonly) float djProgress;

/// Enable/disable mic mixing in DJ mode (talk over music)
@property (nonatomic, assign) BOOL djMicMixEnabled;

/// Mic mix gain (0.0 - 2.0, default 1.0). Music gain is always 1.0.
@property (nonatomic, assign) float djMicGain;

/// Music gain when mic mixing (0.0 - 1.0, default 0.7 = auto-duck)
@property (nonatomic, assign) float djMusicGain;

// ── DJ Dual-Deck Mode ─────────────────────────────────────────────────────

/// Load and start Deck A (track A)
- (BOOL)startDeckA:(NSString *)filePath;
/// Load and start Deck B (track B)
- (BOOL)startDeckB:(NSString *)filePath;
/// Pause/resume Deck A
- (void)toggleDeckA;
/// Pause/resume Deck B
- (void)toggleDeckB;
/// Stop both decks and reset DJ controller
- (void)stopDualDeck;

/// Crossfader position: 0.0 = Deck A only, 0.5 = equal mix, 1.0 = Deck B only
/// Equal-power law: gain_A = cos(cf * π/2), gain_B = sin(cf * π/2)
@property (nonatomic, assign) float djCrossfader;  // 0.0–1.0, default 0.5

/// Whether dual-deck mode is active
@property (nonatomic, readonly) BOOL isDualDeckActive;

/// Track names
@property (nonatomic, readonly, copy, nullable) NSString *deckATrack;
@property (nonatomic, readonly, copy, nullable) NSString *deckBTrack;

/// Progress 0.0–1.0
@property (nonatomic, readonly) float deckAProgress;
@property (nonatomic, readonly) float deckBProgress;

/// Playing state
@property (nonatomic, readonly) BOOL deckAPlaying;
@property (nonatomic, readonly) BOOL deckBPlaying;

@end

NS_ASSUME_NONNULL_END
