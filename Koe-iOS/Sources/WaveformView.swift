import SwiftUI

struct WaveformView: View {
    let level: Float
    @State private var bars: [Float] = Array(repeating: 0.1, count: 20)
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<bars.count, id: \.self) { i in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.red.opacity(0.9), Color.orange.opacity(0.7)],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 3, height: CGFloat(bars[i]) * 44 + 4)
                    .animation(.easeInOut(duration: 0.1), value: bars[i])
            }
        }
        .onAppear { startAnimation() }
        .onDisappear { timer?.invalidate() }
        .onChange(of: level) { _, newLevel in
            updateBars(level: newLevel)
        }
    }

    private func startAnimation() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
            updateBars(level: level)
        }
    }

    private func updateBars(level: Float) {
        var newBars = bars
        // シフト
        for i in 0..<newBars.count - 1 {
            newBars[i] = newBars[i + 1]
        }
        // 新しい値: レベル + ランダムノイズ
        let noise = Float.random(in: -0.1...0.1)
        newBars[newBars.count - 1] = max(0.05, min(1.0, level + noise))
        bars = newBars
    }
}
