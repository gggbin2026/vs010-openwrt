# 自动构建记录（BUILD_HISTORY）

> 每次 `Run workflow` 编译成功后，workflow 会自动把本行追加到本表并 commit 回仓库。
> 出问题时按时间倒查：哪一轮编译、哪个 commit、产出了什么、当时生效的配置是什么。
> **请勿手动清空本文件**；覆盖整包时如果把它一起覆盖，自动记录会从头开始（历史仍在 git log 里）。
> 人工修复的来龙去脉见 [CHANGELOG.md](CHANGELOG.md)。
> Release 归档（`fw-YYYYMMDD-HHMMSS-rN`）永久保留，可和本表按 run 号对上。

| 构建时间(上海) | Run | Commit | 产物 | 本版关键配置 |
|---|---|---|---|---|
