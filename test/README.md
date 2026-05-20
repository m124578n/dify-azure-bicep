# Dify Workflow Deploy Tool

將 Dify chatbot workflow 從 UAT 匯出並部署到 Prod 的自動化腳本。

## 環境需求

- Python 3.11+
- [uv](https://docs.astral.sh/uv/getting-started/installation/)

## 設定

### 1. 建立 `.env`

複製範例檔並填入實際值：

```bash
cp .env.example .env
```

編輯 `.env`：

```env
DIFY_UAT_URL=https://your-uat-nginx-url
DIFY_UAT_EMAIL=admin@example.com
DIFY_UAT_PASSWORD=your-uat-password

DIFY_PROD_URL=https://your-prod-nginx-url
DIFY_PROD_EMAIL=admin@example.com
DIFY_PROD_PASSWORD=your-prod-password
```

### 2. 設定 APP_ID_MAP

在 `deploy_workflow.py` 頂端填入 UAT → Prod 的 app_id 對應：

```python
APP_ID_MAP: dict[str, str] = {
    "uat-app-id-xxxx": "prod-app-id-yyyy",
}
```

> app_id 可透過 `list` 指令取得（見下方）。

---

## 使用方式

所有指令在 `test/` 目錄下執行：

```bash
cd test
```

### 列出所有 App

```bash
uv run deploy_workflow.py list
```

輸出範例：

```
app_id                                 mode         name
----------------------------------------------------------------------
4747ffa0-cb7a-4293-b951-01d171d3f75c   advanced-chat  test
7be84506-5f83-4aa0-8af5-0d5c5b39a137   advanced-chat  客服機器人
```

---

### Export（UAT → YAML）

```bash
uv run deploy_workflow.py export --app-id <uat_app_id>
```

- 將 workflow DSL 儲存至 `test/workflows/<app_id>.yml`
- 此檔案應納入 git 版控

---

### Deploy（YAML → Prod）

```bash
uv run deploy_workflow.py deploy --app-id <uat_app_id>
```

內部執行步驟：
1. 讀取 `test/workflows/<app_id>.yml`
2. 查找 `APP_ID_MAP` 取得對應的 prod app_id
3. GET prod draft 取得當前 hash（衝突保護用）
4. POST 更新 prod draft（graph、features、variables）
5. POST 發布新版本

---

### 一次完成 Export + Deploy

```bash
uv run deploy_workflow.py all --app-id <uat_app_id>
```

---

## 標準 UAT → Prod 流程

```
開發人員在 UAT 完成 workflow 開發
         │
         ▼
uv run deploy_workflow.py export --app-id <id>
         │  儲存 YAML 至 test/workflows/
         ▼
git add test/workflows/<id>.yml && git commit && git push
         │  PR review / merge to main
         ▼
uv run deploy_workflow.py deploy --app-id <id>
         │  更新 Prod draft → 自動發布
         ▼
Prod 上線
```

---

## 注意事項

| 項目 | 說明 |
|------|------|
| `.env` | gitignored，不會進版控 |
| `test/workflows/` | gitignored，需手動加入版控或另存 |
| `APP_ID_MAP` | UAT 和 Prod 的 app_id 不同，首次需手動在 Prod 建立 app |
| Secret | export 時帶 `include_secret=false`，Prod 的 API key 等 secret 需另外管理 |
| 首次部署 | 第一次需在 Prod 手動 import DSL 建立 app，之後才能用此腳本更新 |
