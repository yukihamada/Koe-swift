import Foundation

/// dictation `.began`/`.ended` 通知のライフサイクルを一本化する、小さな
/// 純粋な状態機械 (idle → recording(sessionID) → idle)。
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
/// **意図的にスレッドセーフではない** — メインスレッド専有という単純な
/// 契約にしている。AVFoundation のコールバック等、非メインスレッドから
/// 来うるイベントは、呼び出し側 (AppDelegate/AudioRecorder) が
/// `DispatchQueue.main.async` で hop してから触ること。
final class DictationSession {
    enum State: Equatable {
        case idle
        case recording(sessionID: Int)
    }

    private(set) var state: State = .idle
    private var nextSessionID = 0

    /// 今アクティブな録音セッションの ID (idle なら nil)。呼び出し側はこれを
    /// 自前で保持する必要がない — 終わらせたい時に読んで `end(sessionID:)`
    /// に渡すだけでよい。
    var currentSessionID: Int? {
        if case .recording(let id) = state { return id }
        return nil
    }

    /// idle → recording(新しい sessionID) に遷移する。既に recording 中なら
    /// 何もせず nil を返す (二重 began の最終防衛 — 呼び出し側の再入防止
    /// ガードをすり抜けても、ここで必ず一度しか begin できない)。
    @discardableResult
    func begin() -> Int? {
        guard case .idle = state else { return nil }
        nextSessionID += 1
        state = .recording(sessionID: nextSessionID)
        return nextSessionID
    }

    /// `sessionID` が今アクティブな recording と一致する場合だけ idle に
    /// 遷移して true を返す。以下は全て false (no-op):
    /// - 既に idle (二重終了 / 誰かが既に終わらせた後)
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
}
