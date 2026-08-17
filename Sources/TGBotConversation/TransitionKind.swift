/// Transition 擦除後的種類，跟 AnyScene 的回傳值搭配使用。純內部管線型別，package 存取層級。
/// 見架構設計文件 6.1.1 節「內部實作示意，非最終簽名」的標注。
package enum TransitionKind: Sendable {
    case moved
    case stayed
    case rolledBack
    case interrupted
    case ended
}
