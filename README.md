## dify-azure-bicep

Deploy [langgenius/dify](https://github.com/langgenius/dify) on Azure with Bicep.

> Supports **Dify v1.10.1-fix.1**. Based on [dify-azure-terraform](https://github.com/nikawang/dify-azure-terraform), rewritten in Bicep with a VMSS + Docker Compose architecture.

---

### Architecture

```
Internet
   │
   ▼
Public Load Balancer (Standard)
   │
   ▼
nginx VM (NginxSubnet)
   │  reverse proxy
   ▼
Internal Load Balancer (AppSubnet, 10.x.2.4)
   │
   ▼
VM Scale Set — Ubuntu 22.04 + Docker Compose (AppSubnet)
   ├── nginx      (port 80, serves static assets)
   ├── api        (Dify API server)
   ├── worker     (Celery worker)
   ├── web        (Next.js frontend)
   ├── sandbox    (code execution)
   ├── ssrf_proxy (Squid)
   └── plugin     (plugin daemon)
   │
   ├── Azure Database for PostgreSQL Flexible (PostgresSubnet, delegated)
   ├── Azure Cache for Redis (private endpoint)
   └── Azure Storage Account (private endpoint, Azure Files + Blob)

NAT Gateway → outbound internet for AppSubnet
Log Analytics Workspace + AMA + DCR → syslog & perf monitoring
```

---

### ⚠️ Security Notice

`parameters.json` contains sensitive credentials and is gitignored. Never commit it.

```powershell
# Copy the example and fill in your values
cp parameters.example.json parameters.json
```

Required secrets to set:
- `pgsqlPassword` — PostgreSQL password (min 8 chars, upper + lower + number)
- `adminSshPublicKey` — SSH public key for VM access
- `alertEmail` — (optional) email address for CPU alerts

---

### Quick Start

```powershell
az login
az account set --subscription <subscription-id>

cp parameters.example.json parameters.json
# Edit parameters.json

# Deploy (dev)
.\deploy.ps1

# Deploy (prod)
.\deploy.ps1 -Environment prod
```

After deployment, the script prints the public IP / FQDN of the Dify endpoint.

---

### Deployment Parameters

#### Core

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `location` | string | `japaneast` | Azure region |
| `ipPrefix` | string | `10.99` | VNet address prefix (creates `x.x.0.0/16`) |
| `alertEmail` | string | *(empty)* | Email for CPU > 85% alert; leave empty to skip |

#### Container Images

| Parameter | Default |
|-----------|---------|
| `difyApiImage` | `langgenius/dify-api:1.10.1-fix.1` |
| `difyWebImage` | `langgenius/dify-web:1.10.1-fix.1` |
| `difySandboxImage` | `langgenius/dify-sandbox:0.2.12` |
| `difyPluginDaemonImage` | `langgenius/dify-plugin-daemon:0.4.1-local` |

#### VM / VMSS

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `vmSize` | string | `Standard_D4s_v3` | VMSS instance size |
| `nginxVmSize` | string | `Standard_B2s` | nginx VM size |
| `vmssInstanceCount` | int | `1` | Initial VMSS instance count |
| `adminUsername` | string | `azureuser` | VM admin username |
| `adminSshPublicKey` | string | *(required)* | SSH public key |

#### PostgreSQL

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `pgsqlUser` | string | `adminuser` | Admin login |
| `pgsqlPassword` | string (secure) | *(required)* | Admin password |
| `postgresSkuName` | string | `Standard_B1ms` | SKU name |
| `postgresSkuTier` | string | `Burstable` | SKU tier |
| `postgresStorageGB` | int | `32` | Storage size (GB) |
| `postgresEnableHA` | bool | `false` | High availability |

#### Redis

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `redisCapacity` | int | `0` | 0=250MB, 1=1GB, 2=6GB, 3=13GB |

#### Storage

| Parameter | Type | Default |
|-----------|------|---------|
| `storageAccountBase` | string | `acadifytest` |
| `storageAccountContainer` | string | `dfy` |

---

### Monitoring

A Log Analytics Workspace (`law-dify`) is deployed automatically. Azure Monitor Agent (AMA) is installed on each VMSS instance and collects:

- **Syslog** — daemon, kern, user, syslog, auth (all levels)
- **Performance** — CPU %, available memory, free disk space (every 60s)
- **Docker logs** — routed via journald log driver

If `alertEmail` is set, a metric alert fires when average CPU > 85% for 5 minutes.

---

### Version Update

See [`docs/update-dify-version.md`](docs/update-dify-version.md) for in-place and reimage update procedures.
