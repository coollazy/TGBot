# 打包 Example 這個 bot 成一個可以丟到 Linux 上跑的 image，用來測試穩定度
# （長時間 polling 會不會掛、記憶體會不會一直長等等）。
#
# Example/Package.swift 用 local path 依賴上一層的 TGBot library
# （.package(path: "..")），所以 build context 必須是 repo 根目錄（見旁邊的
# docker-compose.yml 的 build.context: ..），這個 Dockerfile 才能同時拿到
# TGBot 本體跟 Example 兩邊的原始碼，複製進 image 時也維持跟本機一樣的相對路徑結構
# （/package 對應 repo 根目錄，/package/Example 對應這個資料夾），不然
# .package(path: "..") 在 image 裡會找不到東西。
#
# 兩階段建置：第一階段用完整的 swift 工具鏈編譯成 release build；第二階段換成
# 官方提供的 slim 版本（只有跑 Swift 執行檔需要的 runtime library，沒有編譯器），
# 只複製編譯好的執行檔進去，image 小很多，也比較貼近實際部署會用的樣子。
#
# 注意：build 階段的 WORKDIR 目錄名稱故意跟本機的 repo 目錄同名（TGBot），不是隨便取的
# 名字（例如原本試過 /package）——SwiftPM 對 local path 依賴的「package identity」是從
# 目錄名稱推導出來的，不是看 Package.swift 裡的 name: 欄位。Example/Package.swift 裡
# `.product(name: "TGBot", package: "TGBot")` 期待的 package identity 是 "TGBot"，
# 目錄名稱對不上就會在 `swift build` 時炸出「unknown package 'TGBot'」，是實際建置
# 才踩到的坑，不是文件看得出來的。
#
# 另外用的是 6.2、不是 Package.swift 宣告的 swift-tools-version: 6.0——Example/
# Package.resolved 目前釘住的 swift-log 1.15.0 本身要求 Swift tools 6.2.0，用
# swift:6.0-jammy 建置會直接在 swift build 這步報錯（tools version 不符）。如果
# Package.resolved 之後被重新解析、釘到別的 swift-log 版本，這裡可能需要跟著調整。

FROM swift:6.2-jammy AS build
WORKDIR /TGBot

# 先只複製兩邊的 Package.swift／Package.resolved 讓 SwiftPM 解析依賴，
# 這一層在原始碼變動但依賴沒變的時候可以被 Docker layer cache 重複利用，
# 不用每次改程式碼都重新抓一次依賴。
COPY Package.swift Package.resolved ./
COPY Example/Package.swift Example/Package.resolved ./Example/

COPY Sources ./Sources
COPY Example/Sources ./Example/Sources

WORKDIR /TGBot/Example
RUN swift build -c release

FROM swift:6.2-jammy-slim AS runtime
WORKDIR /app
COPY --from=build /TGBot/Example/.build/release/EchoBotExample ./EchoBotExample

# Bot Token 透過環境變數提供（見 EchoBotExample.swift 的 tokenFromEnv），不要
# 把 token 寫進 image 裡——實際的值由 docker-compose.yml 的 env_file 在啟動時帶入。
ENV TGBOT_TOKEN=""

CMD ["./EchoBotExample"]
