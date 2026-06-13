# SkillPulse Deployment Plan

End-to-end plan for getting SkillPulse running on AWS via Terraform + GitHub Actions. **Validated end-to-end** on 2026-04-27 — every section below reflects what actually shipped and was tested (apply → CI → CD → live, then destroy → re-apply → still works, then frontend change → live).

---

## 1. Goal

One push to `main` →
1. `ci.yml` builds the backend image and pushes to Docker Hub.
2. `cd.yml` SSHes into the EC2, runs `git pull` + `docker compose pull` + `docker compose up -d`.
3. `http://<ec2-public-ip>` serves the latest SkillPulse.

The EC2 itself is created **once** by Terraform, run locally by the instructor. After that, every app deploy is automated.

---

## 2. Architecture

```
                    ┌─────────────────────────────────────┐
                    │              GitHub                 │
                    │  ┌──────────┐    ┌──────────────┐   │
   git push ───────►│  │  Repo    │───►│   Actions    │   │
                    │  └──────────┘    │ ci.yml→cd.yml│   │
                    └────────────────────────┬─────────┘
                                             │
                       ┌─────────────────────┼─────────────────┐
                       │                     │                 │
                       ▼                     ▼                 ▼
              ┌─────────────────┐   ┌─────────────────┐  ┌──────────┐
              │   Docker Hub    │   │      SSH        │  │  Secrets │
              │  (image push)   │   │  (deploy step)  │  │ (DH+EC2) │
              └────────┬────────┘   └────────┬────────┘  └──────────┘
                       │                     │
                       ▼                     ▼
              ┌──────────────────────────────────────────┐
              │  EC2 (t3.medium, Ubuntu 24.04, us-west-2)│
              │  ┌──────┐  ┌──────────┐  ┌────────────┐  │
              │  │nginx │──│ backend  │──│  mysql 8.4 │  │
              │  └──────┘  └──────────┘  └────────────┘  │
              │            docker compose                │
              └──────────────────────────────────────────┘
                              ▲
                              │  port 80 open to world
                          End user
```

One EC2 box runs everything (MySQL included, in a container with a named volume). No ALB, no RDS, no autoscaling. Course-grade simplicity.

---

## 3. Prerequisites (instructor-side, one-time)

- AWS account with billing alarm set
- AWS CLI configured locally (`aws configure`) — Terraform reads creds from there
- Terraform CLI (`>= 1.6`; we test on `1.14.x`)
- Docker Hub account + access token (PAT, not password)
- A **public** GitHub repo with the SkillPulse code
- `gh` CLI installed and authenticated (`gh auth login`) — used to set repo secrets from the terminal

---

## 4. Repository Layout

The repo IS the app — no `skillpulse/` subfolder. Repo root contains the compose file, app dirs, and the `terraform/` + `.github/` infra.

```
SkillPulse/
├── CLAUDE.md
├── DEPLOYMENT.md                  ← this file
├── README.md
├── .gitignore
├── docker-compose.yml             ← backend uses image: (see §8)
├── .env.example
├── backend/                       ← Go + Gin REST API
├── frontend/                      ← HTML/CSS/JS
├── nginx/                         ← reverse-proxy config
├── mysql/                         ← init.sql
├── chapters/
│   └── ...
├── terraform/
│   ├── main.tf                    ← provider, EC2, key pair, SG
│   ├── variables.tf               ← region, instance_type, repo_url, dockerhub_username
│   ├── outputs.tf                 ← public IP, ssh user, private key, app URL
│   ├── user_data.sh.tpl           ← bootstrap template (docker, compose, app dir)
│   ├── terraform.tfvars.example   ← copy to terraform.tfvars and fill in
│   └── .gitignore                 ← state files, .pem, *.tfvars
└── .github/
    └── workflows/
        ├── ci.yml                 ← build + push to Docker Hub
        └── cd.yml                 ← git pull + compose pull/up via SSH (workflow_run)
```

`terraform/` runs locally (not in CI). State is local — fine for a course.

---

## 5. Terraform Resources

### Provider versions (pinned in `main.tf`)
- `hashicorp/aws ~> 6.0` (lock file pins `6.42.0` as of 2026-04)
- `hashicorp/tls ~> 4.0` (lock pins `4.2.1`)

### `main.tf`
- `provider "aws"` — region from variable
- `tls_private_key` — generates a 4096-bit RSA key in-memory
- `aws_key_pair` — registers the public half with EC2
- `aws_security_group`:
  - ingress 22 from `var.ssh_ingress_cidr` (default `0.0.0.0/0`, with a comment to lock down for real use)
  - ingress 80 from `0.0.0.0/0`
  - egress all
- `aws_instance`:
  - AMI: latest **Ubuntu 24.04 LTS (Noble Numbat)** via `data "aws_ami"` (Canonical owner `099720109477`, name pattern `ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*`)
  - `instance_type = var.instance_type` (default `t3.medium`)
  - `key_name = aws_key_pair.this.key_name`
  - `vpc_security_group_ids = [aws_security_group.this.id]`
  - `user_data = templatefile("${path.module}/user_data.sh.tpl", { repo_url = ..., dockerhub_username = ... })`
  - `root_block_device { volume_size = 20, volume_type = "gp3" }` — `delete_on_termination` defaults to `true`, so destroy is clean
  - tags: `Name = "skillpulse"`

### `variables.tf`
```hcl
variable "region"             { default = "us-west-2" }
variable "instance_type"      { default = "t3.medium" }
variable "ssh_ingress_cidr"   { default = "0.0.0.0/0" }   # tighten in real use
variable "key_pair_name"      { default = "skillpulse-key" }

variable "repo_url" {
  description = "Public GitHub repo URL containing the SkillPulse code"
  # e.g. "https://github.com/LondheShubham153/SkillPulse.git"
}

variable "dockerhub_username" {
  description = "Docker Hub username — written into .env on the EC2 box"
}
```

### `outputs.tf`
```hcl
output "ec2_public_ip"  { value = aws_instance.this.public_ip }
output "ec2_user"       { value = "ubuntu" }
output "ssh_private_key" {
  value     = tls_private_key.this.private_key_pem
  sensitive = true
}
output "app_url"        { value = "http://${aws_instance.this.public_ip}" }
```

After `apply`, run `terraform output -raw ssh_private_key > skillpulse-key.pem && chmod 600 skillpulse-key.pem`.

---

## 6. `user_data.sh.tpl` (bootstrap on first boot)

Templated by Terraform — `${repo_url}` and `${dockerhub_username}` get filled in at apply time.

```bash
#!/bin/bash
set -euxo pipefail

# --- Install Docker + Compose plugin from Docker's official apt repo ---
apt-get update -y
apt-get install -y ca-certificates curl gnupg git

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

usermod -aG docker ubuntu
newgrp docker

# --- Clone the repo (the repo root IS the app dir) ---
sudo -u ubuntu git clone ${repo_url} /home/ubuntu/skillpulse

# --- Build the .env file for compose ---
sudo -u ubuntu cp /home/ubuntu/skillpulse/.env.example /home/ubuntu/skillpulse/.env
echo "DOCKERHUB_USERNAME=${dockerhub_username}" | sudo -u ubuntu tee -a /home/ubuntu/skillpulse/.env

# Compose will pull the backend image from Docker Hub on first `up` (after CI runs once).
```

> Cosmetic note: the resulting `.env` ends up with `DOCKERHUB_USERNAME` listed twice — once with the placeholder from `.env.example`, once with the real value appended. Compose uses the last occurrence, so behavior is correct. A `sed -i` replace would polish this if you care.

---

## 7. Outputs → GitHub Secrets

Five secrets total. Three flow from Terraform, two from Docker Hub.

| Secret | Source | Refresh on each `terraform apply`? |
|---|---|---|
| `EC2_HOST` | `terraform output -raw ec2_public_ip` | **Yes** — public IP changes each instance |
| `EC2_SSH_KEY` | `skillpulse-key.pem` (from `terraform output`) | **Yes** — key pair regenerated each apply |
| `EC2_USER` | constant `ubuntu` | No |
| `DOCKERHUB_USERNAME` | your Docker Hub login | No |
| `DOCKERHUB_TOKEN` | Docker Hub → Account Settings → Security → New Access Token | No (rotate when leaked) |

### Setting them via `gh` CLI

```bash
# After `terraform apply`, from the terraform/ directory:
terraform output -raw ssh_private_key > skillpulse-key.pem && chmod 600 skillpulse-key.pem

REPO=<user>/<repo>

# Stable secrets (set once, ever)
gh secret set EC2_USER            --body "ubuntu"                 --repo $REPO
gh secret set DOCKERHUB_USERNAME  --body "<your-dh-username>"     --repo $REPO
gh secret set DOCKERHUB_TOKEN     --repo $REPO   # paste PAT when prompted, or pipe via stdin

# Refreshed every terraform apply
gh secret set EC2_HOST            --body "$(terraform output -raw ec2_public_ip)" --repo $REPO
gh secret set EC2_SSH_KEY         --repo $REPO < skillpulse-key.pem
```

---

## 8. Compose Change Required

`docker-compose.yml` backend service references an image, not a build context:

```yaml
backend:
  image: ${DOCKERHUB_USERNAME}/skillpulse-backend:latest
```

`DOCKERHUB_USERNAME` is read from `.env` on the EC2 box (written by `user_data.sh.tpl`, see §6).

For local dev: either set `DOCKERHUB_USERNAME` in your local `.env`, or temporarily flip the line back to `build: ./backend` while iterating on backend code.

---

## 9. What flows through CI/CD (and what doesn't)

The pipeline has **two delivery paths**. Knowing this is the difference between a deploy that works and one that silently does nothing.

| Change to… | Reaches EC2 via | Why |
|---|---|---|
| Backend Go code | **Docker Hub image** (built by `ci.yml`) | The Dockerfile bakes the binary into the image; `docker compose pull` fetches it. |
| Frontend (HTML/CSS/JS) | **`git pull` in `cd.yml`** | nginx serves frontend from a volume mount of `/home/ubuntu/skillpulse/frontend/`, not from an image. |
| `docker-compose.yml`, `nginx/`, `mysql/init.sql` | **`git pull` in `cd.yml`** | Same — these are read from the EC2 disk. |

That's why `cd.yml` does **both** `git pull` *and* `docker compose pull`:

```yaml
script: |
  cd ~/skillpulse
  git pull origin main
  docker compose pull
  docker compose up -d
  docker image prune -f
```

If you remove `git pull`, frontend and config edits will silently never deploy — confirmed during dry-run.

---

## 10. End-to-End Deployment Flow

**One-time per EC2 (instructor):**

1. `cd terraform && cp terraform.tfvars.example terraform.tfvars` — fill in `repo_url` and `dockerhub_username`
2. `terraform init && terraform apply -auto-approve`
3. Set the 5 GitHub secrets (see §7 commands)
4. Verify SSH + cloud-init: `ssh -i skillpulse-key.pem ubuntu@<ip> 'cloud-init status --wait && docker --version'`

**Every push to `main` (automated):**

1. **`ci.yml`** — checkout → setup-buildx → login Docker Hub → build & push `:latest` and `:${sha}`
2. **`cd.yml`** — triggers via `workflow_run` after CI succeeds → SSH to EC2 → `git pull origin main` + `docker compose pull` + `docker compose up -d` + `docker image prune -f`
3. Refresh `http://<ec2-public-ip>` → new version live

**Re-running from scratch (e.g., between recordings):**

1. `terraform destroy -auto-approve`
2. `terraform apply -auto-approve` (new IP, new key)
3. Refresh **only** `EC2_HOST` + `EC2_SSH_KEY` secrets (the other 3 are stable)
4. Push (or `git commit --allow-empty -m "trigger"`) → pipeline runs

---

## 11. Cost Estimate (us-west-2)

| Resource | Monthly (approx) |
|---|---|
| t3.medium (730 hrs) | ~$30 |
| 20 GiB gp3 EBS | ~$1.60 |
| Data transfer | ~$1 (light traffic) |
| **Total running 24/7** | **~$33/mo** |
| **Total if stopped between sessions** | **~$2/mo** |
| **Total per recording (apply → record → destroy)** | **a few cents** |

`terraform destroy` is verified clean: 0 leftover EC2/EBS/snapshots/EIPs after destroy. The only AWS cost-incurring resources Terraform doesn't manage are Elastic IPs and EBS snapshots — and we don't create either. See dry-run audit in §13.

---

## 12. Decisions Locked

| Decision | Choice |
|---|---|
| AWS region | `us-west-2` (Oregon) |
| Instance type | `t3.medium` |
| AMI | **Ubuntu 24.04 LTS (Noble Numbat)** — `hvm-ssd-gp3` family |
| AWS Terraform provider | `~> 6.0` (lock pins `6.42.0`) |
| Repo visibility | **Public** — user_data clones over HTTPS, no deploy key needed |
| Backend delivery | Docker Hub image, pulled by compose on each deploy |
| Frontend / config delivery | `git pull origin main` in `cd.yml` |
| CI/CD layout | **Split** — `ci.yml` builds & pushes; `cd.yml` triggered via `workflow_run` |
| Terraform run location | Local, one-time — not in a GitHub Actions workflow |
| Terraform state | Local file, gitignored |
| MySQL | Container on EC2 with a named volume (no RDS); destroy = data loss |
| SSH ingress | `0.0.0.0/0` for course simplicity (callout to lock down in real use) |
| Domain / TLS | None — IP-only access |
| EBS root volume | 20 GiB gp3, `delete_on_termination = true` (destroy is clean) |
| Pinned action versions | `actions/checkout@v6`, `docker/setup-buildx-action@v4`, `docker/login-action@v4`, `docker/build-push-action@v7`, `appleboy/ssh-action@v1` |
| Stack versions | Go `1.26`, Alpine `3.23`, MySQL `8.4`, nginx `alpine` |

---

## 13. Validation Status (2026-04-27)

| Check | Result |
|---|---|
| `terraform apply` (4 resources) | ~20s ✓ |
| user_data finishes (cloud-init) | ~90s ✓ |
| `ci.yml` build + push (Docker Hub) | ~55s ✓ |
| `cd.yml` SSH deploy | ~38s ✓ |
| Backend image change end-to-end | ✓ |
| Frontend change end-to-end | ✓ (after adding `git pull`) |
| `POST /api/skills` write path | ✓ |
| MySQL persistence (named volume) | ✓ |
| Destroy → re-apply repeatability | ✓ |
| AWS leftovers post-destroy | 0 (no EC2, EBS, snapshots, EIPs, key pairs, SGs) |
