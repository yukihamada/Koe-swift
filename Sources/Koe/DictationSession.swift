import Foundation

/// dictation `.began`/`.ended` 通知のライフサイクルを一本化する、小さな
/// 純粋な状態機械 (idle → starting(sessionID) → recording(sessionID) → idle)。
///
/// 2026-09-26 round-4 review: 個別のレース (identity ガード・encode error
/// 順序・watchdog・入力デバイス変更など) を1つずつ塞いでも収束しなかった
/// ため、「began/ended を実際に送ってよいか」の判定をここに一本化する。
/// `AppDelegate` のあらゆる停止経路 (通常停止・キャンセル・終了・
/// delegate失敗/encodeエラー・watchdog・入力デバイス変更) は、実際に
/// notifier を叩く前に必ずここを通す — `end(sessionID:)` は「そのセッション
/// が今アクティブな場合だけ」true を返し、二重終了・無関係な古い
/// sessionID (stale) には false を返して安全に無視させる。
///
/// 2026-09-26 round-6 review: `idle → recording` の1ステップだけだと、
/// `recorder.start()` の呼び出し中 (まだ recording に遷移する前) に
/// 想定外の停止が発火した場合に宛先を持てず握りつぶされ、その後
/// `recorder.start()` が (たまたま) true を返すと「誰も ended を送らない
/// began」が生まれてしまう。`starting(sessionID)` を挟むことで、
/// `recorder.start()` を呼ぶ**前**に sessionID を確保してハンドラを
/// バインドできるようにし、その窓の間に発火した想定外の停止は
/// `cancelStarting(sessionID:)` で「一度も recording にならなかった」
/// ことにする — began は `confirmStarted(sessionID:)` が
/// `starting(sessionID)` からの遷移としてのみ成功した時だけ出す。
///
/// **意図的にスレッドセーフではない** — メインスレッド専有という単純な
/// 契約にしている。AVFoundation のコールバック等、非メインスレッドから
/// 来うるイベントは、呼び出し側 (AppDelegate/AudioRecorder) が
/// `DispatchQueue.main.async` で hop してから触ること。
final class DictationSession {
    enum State: Equatable {
        case idle
        case starting(sessionID: Int)
        case recording(sessionID: Int)
    }

    private(set) var state: State = .idle
    private var nextSessionID = 0

    /// 今アクティブな (starting または recording) セッションの ID
    /// (idle なら nil)。呼び出し側はこれを自前で保持する必要がない —
    /// 終わらせたい時に読んで `end(sessionID:)` に渡すだけでよい。
    var currentSessionID: Int? {
        switch state {
        case .idle: return nil
        case .starting(let id): return id
        case .recording(let id): return id
        }
    }

    /// idle → starting(新しい sessionID) に遷移する。`recorder.start()` を
    /// 呼ぶ**前**に呼ぶこと — 呼び出し側はこの ID をハンドラにバインドして
    /// から `recorder.start()` を呼ぶ (2026-09-26 round-6)。
    /// 既に starting/recording 中なら何もせず nil を返す (二重 began の
    /// 最終防衛)。
    @discardableResult
    func beginStarting() -> Int? {
        guard case .idle = state else { return nil }
        nextSessionID += 1
        state = .starting(sessionID: nextSessionID)
        return nextSessionID
    }

    /// starting(sessionID) → recording(sessionID) に遷移し、true を返す —
    /// `recorder.start()` が成功した後に呼ぶ。既に `cancelStarting` 済み
    /// (= idle に戻っている) なら false — この場合 began は絶対に出しては
    /// いけない (呼び出し元はこの戻り値で判定する)。
    @discardableResult
    func confirmStarted(sessionID: Int) -> Bool {
        guard case .starting(let id) = state, id == sessionID else { return false }
        state = .recording(sessionID: sessionID)
        return true
    }

    /// starting(sessionID) → idle に遷移する。`recorder.start()` が失敗した
    /// 時、または starting 中 (recording に遷移する前) に想定外の停止が
    /// 発火した時に呼ぶ — どちらも「このセッションは一度も録音状態に
    /// ならなかった」という同じ結末なので、began も ended も一切発火しない。
    @discardableResult
    func cancelStarting(sessionID: Int) -> Bool {
        guard case .starting(let id) = state, id == sessionID else { return false }
        state = .idle
        return true
    }

    /// `sessionID` が今アクティブな recording と一致する場合だけ idle に
    /// 遷移して true を返す。以下は全て false (no-op):
    /// - 既に idle (二重終了 / 誰かが既に終わらせた後)
    /// - まだ starting のまま (recording に遷移していない — `end` の対象は
    ///   常に "began を出し終えたセッション" だけ)
    /// - 別の sessionID (stale — 古いセッションからの遅延コールバック、
    ///   または始まってすらいないセッションの終了要求)
    @discardableResult
    func end(sessionID: Int) -> Bool {
        guard case .recording(let current) = state, current == sessionID else {
            return false
        }
        state = .idle
        return true
    }

    /// 便宜メソッド: `beginStarting()` → 即 `confirmStarted()` を1回で行う。
    /// starting window 自体を気にしないテスト向け (production コードは
    /// `recorder.start()` を挟むため、必ず2ステップの API を明示的に使う)。
    @discardableResult
    func begin() -> Int? {
        guard let id = beginStarting() else { return nil }
        let confirmed = confirmStarted(sessionID: id)
        assert(confirmed, "confirmStarted() right after beginStarting() must always succeed")
        return confirmed ? id : nil
    }
}
