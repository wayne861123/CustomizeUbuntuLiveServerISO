# CustomizeUbuntuLiveServerISO

CLI 工具，用於客製化 Ubuntu Live Server ISO。

## 功能

- 掛載 ISO
- 客製化內容（預裝軟體、組態設定等）
- 注入 cloud-init autoinstall 自動化安裝設定
- 重新封裝為可開機的自定義 ISO

## 未來規劃

- GUI 版本

## 需求

- `xorriso`
- `bsdtar` (libarchive-tools)
- `wget` 或 `curl`
- Root 權限（用於掛載 ISO）

## 使用方式

```bash
./scripts/build_iso.sh --iso <input_iso> --output <output_iso>
```
