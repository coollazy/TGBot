// 開發者只會、只需要 `import TGBot`（見架構設計文件第 3／13 節）。但實際上 Scene、Context、
// ConversationState、Transition 這些型別定義在 TGBotConversation，AllowList 定義在
// TGBotAccessControl，UpdateSource／TelegramAPIClient／TimeProvider 定義在 TGBotTransport
// ——這幾個 target 對開發者來說純粹是內部拆分，不該變成「還要多 import 好幾個 module」
// 這種外洩的實作細節。用 @_exported import 把它們的 public API 一併透過 TGBot 這個
// 型別的 module 曝露出去，單一個 `import TGBot` 就能拿到全部。
//
// 這是先前只在同一個 package 裡加 executable target 測試時漏掉的東西：
// 同一個 package 內的 target 彼此可以直接 import 對方，掩蓋了「真正外部使用者只
// import TGBot 夠不夠」這個問題；換成獨立的 Example 專案（用 local path 依賴這個
// package）才真正驗證出來，這正是「垂直切片要做的事」——不夠外部視角的測試會漏掉這個。
@_exported import TGBotTransport
@_exported import TGBotAccessControl
@_exported import TGBotConversation
