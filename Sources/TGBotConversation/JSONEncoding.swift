import Foundation

/// 統一的 session／state 編碼設定：sortedKeys 確保同一份資料在不同呼叫點、不同次
/// encode 之間 byte-for-byte 相同（只要語意相同）。這是 applyBackgroundTransition
/// 的 baseline／目前 session 比對能可靠運作的前提——如果 session 型別含
/// Dictionary／Set，沒有 sortedKeys 的話，key／元素順序不保證跨次呼叫穩定，
/// 會出現「session 其實沒變、卻被誤判成衝突」的偽陽性。
package func canonicalJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return encoder
}
