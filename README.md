# Amster2k2x CI/CD Infrastructure

> Fully automated build → test → deploy pipeline for the Amster2k2x VPN service (VLESS/Trojan/X-Ray), replacing manual SSH deploys across 11+ VPS servers with a single reusable GitHub Actions pipeline and ephemeral AWS test infrastructure.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Repository Map](#repository-map)
- [Pipeline Stages](#pipeline-stages)
- [Infrastructure Layout](#infrastructure-layout)
- [Deployment Workflows](#deployment-workflows)
- [Amster2k2x-Test: Test Infrastructure Architecture in AWS Cloud](#amster2k2x-test-test-infrastructure-architecture-in-aws-cloud)
- [Blue-Green Deploy (Production VPS)](#blue-green-deploy-production-vps)
- [Database Backup & Restore](#database-backup--restore)
- [Hard Constraints](#hard-constraints)

---

## Overview

Amster2k2x is a commercial VPN service built on the Remnawave + Bedolaga ecosystem — a panel backend/frontend, a Telegram bot and cabinet MiniApp/WebApp, a subscription page for VPN clients, and a fleet of VPN proxy nodes. This repo (`amster2k2x-infrastructure`) is the **sole orchestration layer** — all six service repos are upstream forks that cannot host their own workflows, so every CI/CD workflow lives here.

```
GitHub push → Build + Scan → GHCR/DockerHub
           → AWS ECS Fargate (ephemeral smoke/ui tests)
           → VPS blue-green deploy (production)
           → VPN node fleet rolling deploy (production)
```

**What this eliminates:** manual SSH sessions, config drift, undocumented deploys, no rollback path.

---

## Architecture

### Ecosystem at a Glance

| Layer | Technology |
|---|---|
| VPN protocol | VLESS / Trojan / X-Ray (Reality) |
| Admin panel | Remnawave (backend + frontend, single baked image) |
| Bot & MiniApp/WebApp | Bedolaga (Telegram bot worker + Cabinet frontend) |
| Subscription portal | Remnawave subscription page for VPN clients/apps|
| Node fleet | Remnawave node (9+ VPS servers) |
| Container registry | `ghcr.io/amster2k2x/` (primary), Docker Hub (secondary) |
| Test infrastructure in AWS CLoud | AWS ECS Fargate, `eu-north-1` (ephemeral) |
| Production infrastructure | VPS fleet, Docker Compose, blue-green deploy via SSH from Self Hosted Runner |
| IaC | Terraform (AWS), Docker Compose (VPS prod) |
| CI/CD | GitHub Actions — reusable workflows in this repo only |
| Secrets | AWS Secrets Manager (test), GitHub Org Secrets (prod) |

### Panel Build Note

The Remnawave Panel is **not a single-repo artifact**. The build pipeline enforces this order:

1. `remnawave-frontend` builds and archives the compiled frontend bundle.
2. `remnawave-backend` copies that archive in during its Docker build, producing `ghcr.io/amster2k2x/remnawave-backend` — the final deployed panel image.

There is no separate "panel" image. The backend image **is** the panel.

---

## Repository Map

| Repo | Role | Production Host |
|---|---|---|
| `remnawave-bedolaga-telegram-bot` | Telegram bot backend, webhook receiver | Bot-VPS |
| `remnawave-bedolaga-cabinet` | Telegram MiniApp web frontend, cabinet UI | Bot-VPS |
| `remnawave-frontend` | Panel frontend — builds archive only, no direct deploy | — |
| `remnawave-backend` | Panel image — bakes in frontend archive at build time | Panel-VPS |
| `remnawave-node` | VPN proxy node fleet | 9× Node-VPS |
| `remnawave-subscription-page` | User subscription management portal | Sub-VPS |
| **`amster2k2x-infrastructure`** | **This repo — all reusable CI/CD workflows** | — |

> All six service repos are upstream forks. **No workflows live in those repos.** `amster2k2x-infrastructure` is the only place workflows run, called via `workflow_call`.

---

## Pipeline Stages

```
┌─────────────────────────────────────────────────────────────────┐
│  Stage 1 — BUILD                                                │
│  Trigger: push to main / semver tag                             │
│  • Gitleaks secret scan                                         │
│  • Docker build (frontend → backend bake for panel)             │
│  • Trivy CVE scan  →  CRITICAL fails build / HIGH warns         │
│  • Push to ghcr.io/amster2k2x/<service>:<semver> and DH         │
└───────────────────────┬─────────────────────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────────────────────┐
│  Stage 2 — TEST/STAGE (AWS ECS Fargate, ephemeral)              │
│  • Terraform apply  →  VPC + ALB + RDS + Redis + ECS            │
│  • DNS validation (ACM cert)                                    │
│  • Smoke tests + handshake verification                         │
│  • Manual tests with ui (pass / fail)                           │
│  • Terraform destroy after tests approve                        │
│  • Telegram notification (pass / fail /destroy)                 │
└───────────────────────┬─────────────────────────────────────────┘
                        │ (on stage pass)
┌───────────────────────▼─────────────────────────────────────────┐
│  Stage 3 — DEPLOY (Production VPS, blue-green)                  │
│  • SSH to VPS via Self Hosted Runner                            │
│  • Spin up new (green) container alongside live (blue)          │
│  • Health check green slot                                      │
│  • Switch nginx upstream to green                               │
│  • Stop blue container  (make-before-break)                     │
│  • Automatic rollback on health check failure                   │
└───────────────────────┬─────────────────────────────────────────┘
                        │ (panel + bot + cabinet + sub deployed)
┌───────────────────────▼─────────────────────────────────────────┐
│  Stage 4 — NODE FLEET                                           │
│  • Sequential SSH per node                                      │
│  • docker pull → docker compose down → docker compose up        │
│  • Health check per node before next proceeds                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Infrastructure Layout

### Terraform for AWS

```
terraform/
├── bootstrap/
│   ├── cicd-runner/        # Applied ONCE in cicd-runner-account
│   │                       # Provisions: GitHub OIDC provider, hub IAM role
│   └── workload-account/   # Applied ONCE per workload account
│                           # Provisions: cross-account role, state S3 bucket,
│                           #             ACM cert, backup bucket, app secrets
└── build/                  # Single root — reused for test and prod
    │                       # Environment differences: var.environment + GitHub
    │                       # Environment secrets only (no duplicated dirs)
    ├── versions.tf          # required_providers, Terraform version constraint
    ├── variables.tf         # environment, region, vpc_cidr, image tags
    ├── outputs.tf           # alb_dns_name, rds_endpoint → written to SSM
    ├── data.tf              # Bootstrap remote state, SSM params, ACM cert ARN
    │
    ├── networking.tf        # VPC, IGW, NAT GW + EIP, 3× subnet tiers, route tables
    ├── security_groups.tf   # sg-alb, sg-ecs-tasks, sg-rds, sg-elasticache
    ├── data_tier.tf         # RDS, ElastiCache, subnet groups, Secrets Manager
    ├── alb.tf               # ALB, HTTP→HTTPS redirect, HTTPS listener, target groups
    ├── ecs_cluster.tf       # ECS cluster, Cloud Map namespace (amster2k2x.local)
    ├── iam.tf               # Task execution roles, per-service task roles
    │
    ├── svc_panel.tf
    ├── svc_bot_worker.tf
    ├── svc_cabinet.tf
    ├── svc_sub_page.tf
    ├── svc_node.tf
    └── svc_db_tools.tf      # Task definition only — no ECS service (run-task)
```

### GitHub Actions Workflows (`.github/workflows/`)

```
upstream-sync.yml       Saturday cron — syncs all 6 forks from upstream
build-<service>.yml     Per-service build + scan + push to GHCR/DH
deploy-test.yml         apply → DNS → smoke → backup → destroy (unless auto_destroy=false)
destroy-test.yml        Manual teardown
backup-test.yml         Manual DB backup via ephemeral db-tools task
deploy-prod-panel.yml   Blue-green VPS deploy (reusable, called per service)
deploy-prod-bot.yml     Blue-green VPS deploy (reusable, called per service)
deploy-prod-nodes.yml   Sequential node fleet deploy
deploy-prod-sub.yml     Subscription page deploy
```

---

## Deployment Workflows

### Test Environment

```bash
# Deploy (applies Terraform, runs smoke tests, destroys on completion by default)
gh workflow run deploy-test.yml -f auto_destroy=false   # keep alive for debugging

# Tear down manually
gh workflow run destroy-test.yml

# Manual DB backup
gh workflow run backup-test.yml
```

### Production VPS

Production deploys are triggered automatically on a successful test-stage run, or manually via `workflow_dispatch` with a service selector.

```bash
# Manual deploy of a single service (workflow_dispatch)
gh workflow run deploy-prod-*.yml -f tag=4.1.0
```

---

## Amster2k2x-Test: Test Infrastructure Architecture in AWS Cloud
**Target Domain:** `test.amster2k2x.mywire.org`  
**Deployment Region:** `eu-north-1`  
**Deployment Model:** AWS ECS Fargate (Ephemeral / Cost-Optimized)  

---

### 1. Executive Summary & Architectural Overview

The **Amster2k2x-Test** infrastructure provides a complete, containerized deployment of the Remnawave ecosystem running on Amazon Web Services (AWS) in the **`eu-north-1` (Stockholm)** region using **Elastic Container Service (ECS) with AWS Fargate**. 

The design balances enterprise-grade security, high-performance web applications, and low monthly overhead:
- All services (Panel, Bot Worker, Cabinet, Subscription Page, and Node) run in **Private App Subnets** with full internal networking capability over AWS Service Connect / Cloud Map DNS.
- **AWS NAT Gateway** is deployed in the Public Subnet to allow private ECS tasks to make outbound TLS connections (e.g., pulling container images from GHCR/Docker Hub or hitting external APIs) while completely blocking unrequested inbound connections.
- **Application Load Balancer (ALB)** exposes public entry points for Panel, Subscription Page, and the shared `bot.test.amster2k2x.mywire.org` hostname (serving both the Telegram Bot Webhook worker/endpoints and the Cabinet MiniApp web assets).
- Data persistence stores (**Amazon RDS PostgreSQL** and **Amazon ElastiCache Redis**) reside in **Isolated Private Data Subnets** with no NAT Gateway route and **zero direct internet accessibility**.

---

### 2. Global Component Mapping

| Service Name | Description & Functionality | Infrastructure Type | Target Region | Public Access | Data Store / Service Access |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Panel Service** | Core administration hub; Web UI + REST API. | ECS Fargate Task | `eu-north-1` | Yes (via ALB) | RDS (`remnawave_panel`), ElastiCache (DB 0), Internal Task DNS |
| **Bedolaga Bot Worker** | Telegram Bot Webhook worker & Cabinet API backend. | ECS Fargate Task | `eu-north-1` | Yes (via ALB) | RDS (`remnawave_bot`), ElastiCache (DB 1), Panel API, External Telegram API (via NAT) |
| **Bedolaga Cabinet** | User Cabinet MiniApp Web Interface. | ECS Fargate Task | `eu-north-1` | Yes (via ALB) | Shared ALB domain (`bot.*`), Bot Worker Internal DNS (`bot.amster2k2x.local`) |
| **Subscription Page** | User-facing portal for subscription management. | ECS Fargate Task | `eu-north-1` | Yes (via ALB) | Panel Internal DNS (`panel.amster2k2x.local`) |
| **Remnawave Node** | Proxy routing and traffic node engine. | ECS Fargate Task | `eu-north-1` | Inbound Direct / Proxy | Panel Internal DNS (`panel.amster2k2x.local`) |
| **PostgreSQL 16** | Relational storage for panel and bot state. | Shared AWS RDS (`db.t4g.micro`) | `eu-north-1` | **NO (Isolated Private Subnet)** | EBS (20 GB gp3) |
| **Redis 7** | In-memory store for sessions, queues, and caching. | Shared ElastiCache (`cache.t4g.micro`) | `eu-north-1` | **NO (Isolated Private Subnet)** | In-Memory |
| **NAT Gateway** | Outbound internet egress for ECS image pulling and external API calls. | AWS Managed NAT Gateway + EIP | `eu-north-1` | Elastic IP (Outbound Only) | Routes `0.0.0.0/0` from Private App Subnets |

---

### 3. Network Architecture & Internal Task Intercommunication

All ECS tasks are assigned private IP addresses and communicate internally within the VPC via **AWS Service Connect / Private Route53 DNS (`.amster2k2x.local`)**. External traffic for the Telegram MiniApp frontend assets, backend API, and webhook endpoints lands on the `bot.test.amster2k2x.mywire.org` hostname at the ALB.

```
                                      [ Public Internet ]
                                         │           ▲
                       (Inbound HTTPS 443)           │ (Outbound Image Pulls / Telegram API / S3 Backups)
                                         │           │
                                         ▼           │
                           [ AWS Application Load Balancer (ALB) ]
                               (DNS: test.amster2k2x.mywire.org)
                                         │
             ┌───────────────────────────┼───────────────────────────┐
             │ Host: panel.*             │ Host: sub.*               │ Host: bot.*
             ▼                           ▼                           ▼
    ┌─────────────────┐         ┌─────────────────┐         ┌─────────────────┐
    │   Panel Task    │         │  Sub Page Task  │         │   Bot Worker    │──┐
    │  (UI & API)     │         │    (Web UI)     │         │  (Webhook &     │  │
    └────────┬────────┘         └────────┬────────┘         │  Cabinet API)   │  │
             │                           │                  └────────┬────────┘  │
             │                           │                           ▲           │
             │                           │                           │           │
             │                           │                  ┌────────┴────────┐  │
             │                           │                  │  Cabinet Task   │  │
             │                           │                  │  (MiniApp UI)   │  │
             │                           │                  └─────────────────┘  │
             │                           │                           │           │
             │                           └─────────────────┬─────────┘           │
             │                                             │                     │
             │                                             ▼                     │
             │                              [ Remnawave Node Task ]              │
             │                                             │                     │
             └─────────────────────────┬───────────────────┘                     │
                                       │ (Internal Private DNS / Service Connect)│
                                       │                                         │
                                       │ (0.0.0.0/0 Outbound Egress)             │
                                       ▼                                         │
                       ┌───────────────────────────────┐                         │
                       │  AWS NAT GATEWAY              │◄────────────────────────┘
                       │  (Public Subnet / Elastic IP) │
                       └───────────────┬───────────────┘
                                       │
                                       │ (NO Route to NAT Gateway)
                                       ▼
                       ┌────────────────────────────────┐
                       │  ISOLATED DATA SUBNET          │
                       │  (No Internet Routing / Access)│
                       ├────────────────────────────────┤
                       │ RDS PostgreSQL (Port 5432)     │
                       │  - remnawave_panel             │
                       │  - remnawave_bot               │
                       │                                │
                       │ ElastiCache Redis (Port 6379)  │
                       │  - DB 0 (Panel)                │
                       │  - DB 1 (Bot)                  │
                       └────────────────────────────────┘
```

---

### 4. Ingress Traffic Routing Rules & Priority Order

External public access is routed through the central ALB in `eu-north-1`. ALB evaluates rules strictly by **priority number (lowest integer evaluated first)**. Because `bot.test.amster2k2x.mywire.org` hosts API calls, Telegram webhook notifications (`/webhook`), and static frontend assets, explicit paths for the Bot Worker MUST have lower priority numbers than the catch-all `/*` route to avoid blackholing API and Webhook ingress into Cabinet.

| Rule Priority | Target Domain / Path Pattern | Target ALB Group | Target Container / Task | Protocol & Port | Internal Private DNS Name |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **10** | `panel.test.amster2k2x.mywire.org/*` | `tg-panel` | Panel Task | HTTP / 3000 | `panel.amster2k2x.local:3000` |
| **20** | `sub.test.amster2k2x.mywire.org/*` | `tg-sub-page` | Subscription Page Task | HTTP / 3010 | `sub.amster2k2x.local:3010` |
| **30** | `bot.test.amster2k2x.mywire.org/api/*` | `tg-bot-worker` | Bot Worker Task (API) | HTTP / 8080 | `bot.amster2k2x.local:8080` |
| **31** | `bot.test.amster2k2x.mywire.org/webhook` | `tg-bot-worker` | Bot Worker Task (Telegram Webhook) | HTTP / 8080 | `bot.amster2k2x.local:8080` |
| **40** | `bot.test.amster2k2x.mywire.org/*` | `tg-cabinet` | Cabinet Task (MiniApp Web Frontend) | HTTP / 80 | `cabinet.amster2k2x.local:80` |

---

### 5. Internal Service-to-Service Communication Matrix

Tasks bypass external endpoints and communicate over high-speed, secure internal VPC channels:

1. **Cabinet --> Bot Worker:** Cabinet queries `http://bot.amster2k2x.local:8080` directly inside the private subnet for backend state.
2. **Bot Worker --> Panel API:** Bot Worker manages state in RDS (`remnawave_bot`) and communicates with Panel via `http://panel.amster2k2x.local:3000`.
3. **Remnawave Node --> Panel API:** Node handles node syncing by talking to `http://panel.amster2k2x.local:3000`.
4. **Subscription Page --> Panel API:** Subscription UI fetches token configuration from `http://panel.amster2k2x.local:3000`.

---

### 6. VPC Routing & Subnet Architecture (`eu-north-1`)

#### 1. Public Subnets (`10.0.1.0/24`, `10.0.2.0/24`)
* **Associated Route Table:** Connected to **Internet Gateway (IGW)** (`0.0.0.0/0 -> igw-xxxx`).
* **Resources:** Application Load Balancer (ALB) and **AWS NAT Gateway** (with assigned Elastic IP).

#### 2. Private App Subnets (`10.0.10.0/24`, `10.0.11.0/24`)
* **Associated Route Table:** Connected to **NAT Gateway** (`0.0.0.0/0 -> nat-xxxx`).
* **Resources:** ECS Fargate Tasks (Panel, Bot, Cabinet, Sub, Node, and ephemeral `db-tools`).
* **Capability:** Enables outbound HTTPS traffic to GHCR, Docker Hub, S3, and Telegram API without exposing tasks directly to inbound internet traffic.

#### 3. Isolated Private Data Subnets (`10.0.20.0/24`, `10.0.21.0/24`)
* **Associated Route Table:** Local VPC routes only (`10.0.0.0/16 -> local`). No route to IGW or NAT Gateway.
* **Resources:** RDS PostgreSQL and ElastiCache Redis.
* **Capability:** **`publicly_accessible = false`** strictly enforced. Absolute network isolation.

#### AWS Security Group Matrix

```
[ ALB Security Group (sg-alb) ]
   ├── Inbound: TCP 80/443 from 0.0.0.0/0
   └── Egress: TCP 3000, 8080, 80, 3001, 3010 to sg-ecs-tasks

[ ECS Container Security Group (sg-ecs-tasks) ]
   ├── Inbound: App ports (3000, 8080, 80, 3001, 3010) from sg-alb
   ├── Inbound Internal: Full TCP traffic intercommunication between tasks in sg-ecs-tasks
   └── Egress: TCP 5432 to sg-rds, TCP 6379 to sg-elasticache, TCP 443 to 0.0.0.0/0 (via NAT Gateway)

[ RDS Private Security Group (sg-rds) ]
   ├── Inbound: TCP 5432 from sg-ecs-tasks ONLY
   └── Public Route: NONE (Isolated Subnet Group, Publicly Accessible = FALSE)

[ ElastiCache Security Group (sg-elasticache) ]
   ├── Inbound: TCP 6379 from sg-ecs-tasks ONLY
   └── Public Route: NONE
```

---

### 7. Shared Database & Cache Architecture

#### 1. Amazon RDS PostgreSQL (`db.t4g.micro` in `eu-north-1`)
- **Engine:** PostgreSQL 16
- **Network Security:** Deployed in Isolated Private DB Subnet Group, `publicly_accessible = false`. Zero internet routing.
- **Logical Databases:**
  - `remnawave_panel` (Panel Task)
  - `remnawave_bot` (Bot Worker Task)

#### 2. Amazon ElastiCache Redis (`cache.t4g.micro` in `eu-north-1`)
- **Engine:** Redis 7.x
- **Network Security:** Private Subnet Group access only.
- **Logical Index Separation:**
  - `DB 0`: Panel caching & sessions
  - `DB 1`: Bot worker queues & state

---

### 8. Ephemeral Tooling Task Infrastructure & Operations (`db-tools`)

Database maintenance (backup and restore) executes via an ephemeral **`db-tools`** ECS Fargate task definition registered in Terraform at `apply` time.

#### 8.1 Docker Image Build & CI Pipeline Source
To maintain consistency with the GHCR pipeline pattern, `db-tools` uses a minimal custom Dockerfile based on `postgres:16` packaged with AWS CLI and `jq`:

```dockerfile
# db-tools Dockerfile (Built and published to GHCR via CI pipeline)
FROM postgres:16-alpine

RUN apk add --no-cache     aws-cli     bash     jq     ca-certificates

COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

ENTRYPOINT ["/bin/bash"]
```

---

#### 8.2 S3 Bucket Infrastructure Architecture (Bootstrap Layer)
The target backup bucket (`amster2k2x-test-backups`) **MUST NOT** be declared inside the ephemeral environment Terraform module (`build/`). Destroying `build/` would terminate the bucket along with all persistent backups, defeating the ephemeral lifecycle design.

* **Placement:** Declared in the **`bootstrap/` Terraform layer** alongside golden-backup buckets and state stores.
* **Lifecycle:** Outlives ephemeral `build/` environments; persists indefinitely across `terraform apply` / `terraform destroy` iterations.

---

#### 8.3 IAM & Secrets Management Requirements (Terraform Provisions)
- **Task Execution Role:** ECR/GHCR pull and CloudWatch logging permissions.
- **Task Role (`aws_iam_role.db_tools_task_role`):**
  - **S3 Permissions:** `s3:PutObject` AND `s3:GetObject` on `arn:aws:s3:::amster2k2x-test-backups/*`.
  - **Secrets Manager Permissions:** `secretsmanager:GetSecretValue` on `amster2k2x/rds/master` secret ARN.
- **Authentication Alignment:** PostgreSQL connections use the RDS **Master User** (`postgres` / fetched via `amster2k2x/rds/master`) to execute `pg_dump` and `pg_restore` seamlessly against both `remnawave_panel` and `remnawave_bot` databases without permission or auth mismatches.

---

#### 8.4 Backup Execution Script (`backup.sh`)
GitHub Actions launches `db-tools` with command override `["/scripts/backup.sh"]`. The script writes both a timestamped audit copy and updates canonical restore pointers:

```bash
#!/usr/bin/env bash
# Executed inside ephemeral 'db-tools' Fargate task
set -e

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
S3_BUCKET="s3://amster2k2x-test-backups"

echo "=== Extracting Master Credentials from Secrets Manager ==="
SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id amster2k2x/rds/master --query SecretString --output text)
DB_USER=$(echo $SECRET_JSON | jq -r .username)
export PGPASSWORD=$(echo $SECRET_JSON | jq -r .password)

echo "=== Dumping Private RDS PostgreSQL Databases as Master User ($DB_USER) ==="
pg_dump -h $RDS_PRIVATE_ENDPOINT -U $DB_USER -d remnawave_panel -Fc -f /tmp/panel_db.dump
pg_dump -h $RDS_PRIVATE_ENDPOINT -U $DB_USER -d remnawave_bot -Fc -f /tmp/bot_db.dump

echo "=== Uploading Historical Backups ==="
aws s3 cp /tmp/panel_db.dump ${S3_BUCKET}/history/${TIMESTAMP}_panel.dump
aws s3 cp /tmp/bot_db.dump ${S3_BUCKET}/history/${TIMESTAMP}_bot.dump

echo "=== Updating Canonical Restore Pointers ==="
aws s3 cp /tmp/panel_db.dump ${S3_BUCKET}/panel_latest.dump
aws s3 cp /tmp/bot_db.dump ${S3_BUCKET}/bot_latest.dump

echo "=== Backup Complete. Task Exiting. ==="
```

---

#### 8.5 Symmetric Restore Execution Script (`restore.sh`)
Triggered manually or during disaster recovery workflows by launching `db-tools` with command override `["/scripts/restore.sh"]`. Downloads canonical `*_latest.dump` pointers and executes clean database restorations:

```bash
#!/usr/bin/env bash
# Executed inside ephemeral 'db-tools' Fargate task during database recovery
set -e

S3_BUCKET="s3://amster2k2x-test-backups"

echo "=== Extracting Master Credentials from Secrets Manager ==="
SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id amster2k2x/rds/master --query SecretString --output text)
DB_USER=$(echo $SECRET_JSON | jq -r .username)
export PGPASSWORD=$(echo $SECRET_JSON | jq -r .password)

echo "=== Fetching Canonical Latest Dumps from S3 ==="
aws s3 cp ${S3_BUCKET}/panel_latest.dump /tmp/panel_latest.dump
aws s3 cp ${S3_BUCKET}/bot_latest.dump /tmp/bot_latest.dump

echo "=== Performing Clean Database Restores as Master User ($DB_USER) ==="
pg_restore -h $RDS_PRIVATE_ENDPOINT -U $DB_USER -d remnawave_panel --clean --if-exists --no-owner /tmp/panel_latest.dump || true
pg_restore -h $RDS_PRIVATE_ENDPOINT -U $DB_USER -d remnawave_bot --clean --if-exists --no-owner /tmp/bot_latest.dump || true

echo "=== Database Restore Complete. Task Exiting. ==="
```

---

### 9. Monthly Cost Breakdown (`eu-north-1`)

| Component | Resource Specification | Monthly Cost (USD) |
| :--- | :--- | :--- |
| **AWS Fargate (Compute)** | 5 Tasks (Panel, Bot, Cabinet, Sub, Node) + Ephemeral Backups | ~$35.00 |
| **AWS NAT Gateway** | 1 Managed NAT Gateway + Data Processed | ~$32.00 |
| **Amazon RDS PostgreSQL** | `db.t4g.micro` (20 GB gp3, Private Subnet) | ~$15.00 |
| **Amazon ElastiCache Redis** | `cache.t4g.micro` (Private Subnet) | ~$10.00 |
| **Application Load Balancer** | 1 ALB (`eu-north-1`) | ~$18.00 |
| **AWS S3 Backup Storage** | Backup storage (< 5 GB) | ~$0.15 |
| **Estimated Total (Active 24/7)** | Full Deployment | **~$110.15 / mo** |
| **Estimated Total (Ephemeral)**| Destroyed on off-hours via `terraform destroy` | **~$42.00 / mo** |

> **Cost Optimization Note on NAT Gateway Lifecycle:**  
> AWS NAT Gateway incurs a fixed hourly charge (~$32/month) regardless of whether container tasks exist. The **$42/mo ephemeral cost estimate requires that the NAT Gateway, Elastic IP, and route table associations are included in the `terraform destroy` scope** alongside Fargate tasks and RDS during inactive periods [cite: 9]. Leaving the NAT Gateway provisioned 24/7 creates a ~$32/month fixed fee floor [cite: 9].


### 10. AWS ORG Architecture

```
GitHub Actions (environment: test)
   │  OIDC
   ▼
cicd-runner-account
   │  amster2k2x-cicd-hub role
   │  (permission: assume workload roles, nothing else)
   │  sts:AssumeRole
   ▼
test-account
   │  amster2k2x-test-deploy role
   │  (permission: provision ECS/VPC/ALB, read app secrets)
   ▼
   Terraform applies build/ here
```

Single OIDC trust point (cicd-runner-account). Workload accounts never talk
to GitHub directly — they only trust the hub role. Adding prod-account later
means one more cross-account role + one more line in the hub role's policy;
nothing about the trust model changes.

### 11. Terraform Layout

```
terraform/
├──  bootstrap/
│  ├──  cicd-runner/      # applied ONCE, in cicd-runner-account — OIDC + hub role
│  └──  workload-account/ # applied ONCE per workload account — cross-account role,
│                         # build/'s state bucket, ACM cert, S3 backups, app secrets
└──  build/               # single Terraform root, reused for test now / prod later.
                          # Environment differences come entirely from
                          # var.environment + which GitHub Environment's secrets
                          # the workflow uses — not from duplicated directories.

terraform/build/
├── versions.tf          # required_providers (aws), terraform version constraint
├── variables.tf         # var.environment, var.region, var.vpc_cidr, image tags
├── outputs.tf           # alb_dns_name, rds_endpoint (written to SSM by workflow)
├── data.tf              # data sources: bootstrap state, SSM params, ACM cert ARN
│
├── networking.tf        # VPC, IGW, NAT GW + EIP, 3x subnet tiers, 3x route tables
├── security_groups.tf   # sg-alb, sg-ecs-tasks, sg-rds, sg-elasticache
├── data_tier.tf         # RDS instance, ElastiCache cluster, subnet groups,
│                        # random_password + Secrets Manager secret (rds/master)
├── alb.tf               # ALB, HTTP→HTTPS redirect, HTTPS listener,
│                        # 5x target groups, 5x listener rules (priorities 10-40)
├── ecs_cluster.tf       # ECS cluster, Cloud Map namespace (amster2k2x.local),
│                        # Service Connect default config
├── iam.tf               # shared task execution role, per-service task roles,
│                        # db-tools task role (S3 + Secrets Manager)
│
├── svc_panel.tf         # task definition + ECS service + Service Connect config
├── svc_bot_worker.tf
├── svc_cabinet.tf
├── svc_sub_page.tf
├── svc_node.tf
└── svc_db_tools.tf      # task definition ONLY — no ECS service (run-task pattern)

.github/workflows/
├── deploy-test.yml      # apply → DNS → smoke test → (destroy, unless auto_destroy=false)
├── destroy-test.yml     # manual teardown
├── backup-test.yml      # capture golden DB backups via ECS Exec
scripts/
├── restore-helper.Dockerfile / restore.sh   # used inside build/'s restore sidecar containers
```

---

## Blue-Green Deploy (Production VPS)

Each VPS service runs two named Docker Compose slots: `blue` (live) and `green` (standby). The deploy sequence is:

```
1. Pull new image into green slot
2. docker compose up -d <service>-green
3. health-check.sh  →  waits for /health to return 200
4. blue-green-switch.sh  →  updates nginx upstream to green port
5. docker compose stop <service>-blue
6. On health check failure or pre-health error: rollback
   →  nginx reverted, green container stopped, blue remains live
```

**Compose file layout (per-service, independent):**

| Path | Owns |
|---|---|
| `/opt/remnawave/docker-compose.yml` | Remnawave Panel, DB sidecar, Redis, `remnawave-network` (external: false) |
| `/opt/bot/docker-compose.yml` | Bot, DB sidecar, Redis, `remnawave-network` (external: false) |
| `/opt/bot-cabinet/docker-compose.yml` | Cabinet — attaches to `remnawave-network` as external |
| `/opt/subscription/docker-compose.yml` | Subscription page — attaches as external |
| `/opt/nginx/docker-compose.yml` | nginx reverse proxy — attaches as external |

Cabinet deploys **after** bot to avoid a mid-swap connection window where Cabinet resolves bot's internal hostname but bot is not yet healthy.

---

## Hard Constraints

**Production stays on existing VPS.** The 11+ SSH-only servers are not being replaced. AWS is used exclusively for ephemeral CI/staging compute.

**AWS is ephemeral-only.** No persistent AWS resources beyond the bootstrap layer (OIDC, state bucket, ACM cert, backup bucket). No long-lived AWS credentials — OIDC federation only.

**All workflows run in `amster2k2x-infrastructure`.** The six service repos are upstream forks. Workflows cannot live in forked repos. Every `workflow_call` target is in this repo.

**Config lives in git.** `docker-compose.yml`, nginx configs, and node configs are version-controlled here. Deployed state must match committed state.

**Semver image tags.** Image tags are semver (`1.4.2`), not SHA. A version bump is required to trigger a re-pull on the VPS. SHA tags were evaluated and rejected for operational clarity.
