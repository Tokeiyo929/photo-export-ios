import Foundation

@main
enum CoreTests {
    @MainActor
    static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0) // 行缓冲：管道/tee 下也能逐条看到 PASS
        var failures = 0
        for outcome in TestSupport.runSelfTests() {
            print("\(outcome.passed ? "PASS" : "FAIL") \(outcome.name)"
                  + (outcome.passed ? "" : " —— \(outcome.detail)"))
            if !outcome.passed { failures += 1 }
        }
        precondition(failures == 0, "\(failures) core test failures")
        print("RESULT: ALL PASS")
    }
}
