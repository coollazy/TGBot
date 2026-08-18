# 驗證 + 範例用：確認 TGBot 在 Linux 上真的能 build/test，需求書非功能需求裡寫的
# 「需能在 macOS 與 Linux 上執行、支援打包成 Docker image」在這之前從沒被驗證過。
#
# 這裡只驗證 library 本身（build + test）；要打包成實際可執行的 bot 服務，
# 依你自己 bot 專案的結構調整第二階段的 COPY／CMD。
FROM swift:6.0-jammy AS build
WORKDIR /package

COPY Package.swift Package.resolved ./
COPY Sources ./Sources
COPY Tests ./Tests

RUN swift build && swift test
