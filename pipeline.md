# Production-Ready CI/CD Pipeline — Feane Static Site

## Context

The repo currently holds a pure static HTML/CSS/JS site ("Feane") with a single existing GitHub Actions workflow ([`.github/workflows/deploy.yml`](.github/workflows/deploy.yml)) that SSHes into a pre-existing EC2 and copies files. There is **no Dockerfile, no Terraform, no security scanning, and no `.gitignore`**. The existing workflow was disabled to `workflow_dispatch` in the previous turn.

**Goal:** Replace the ad-hoc SSH deployment with a production-grade pipeline that:
1. Scans code for secrets, quality issues, and vulnerabilities
2. Builds and scans a Docker image
3. Provisions AWS infra via Terraform (scalable — ALB + ASG)
4. Deploys the container and exposes it via a public DNS/IP
5. Is fully automated on push-to-main with proper approvals

**Outcome:** One `git push` triggers security scans → build → terraform apply → deploy → smoke test, and the site is reachable at the ALB DNS name.

---

## Architecture Overview

```
GitHub push → GitHub Actions
  ├─ Security/Quality (parallel): Gitleaks, SonarCloud, Trivy FS, tfsec, HTMLHint
  ├─ Build: Docker image → Trivy image scan → push to ghcr.io
  ├─ Terraform: init → plan → apply (main only, with env approval)
  └─ Deploy: ASG instance refresh → smoke test ALB endpoint

AWS runtime:
  Internet → ALB (public) → Target Group → ASG (EC2 in private-ish subnets)
                                             └─ user_data pulls ghcr.io image, runs container on :80
```

**Key choices (opinionated, tuned for an AWS school sandbox with NO custom IAM permissions):**
- **Registry: GitHub Container Registry (`ghcr.io`) — image published PUBLIC.** The EC2 instances pull it anonymously with a plain `docker pull`. This avoids needing an IAM instance profile or any registry credentials on the box.
- **Scalability: ALB + Launch Template + Auto Scaling Group** — production pattern the user asked for. All resources (VPC/ALB/ASG/EC2) are available in standard sandboxes.
- **AWS auth: sandbox-provided access key + secret (+ session token if applicable)** stored as GitHub Actions secrets. Use `aws-actions/configure-aws-credentials@v4` with `aws-access-key-id` / `aws-secret-access-key` / `aws-session-token` inputs. **No custom IAM user/role/policy creation required.**
- **No IAM instance profile on the EC2.** Because the image is public and we use SSM Session Manager only if the sandbox's default role happens to allow it (not relied upon), the launch template omits `iam_instance_profile`.
- **Terraform state: LOCAL state** (default for this sandbox). State lives inside the GitHub Actions runner during the job. No `backend "s3"` block. Tradeoff: if a run is interrupted mid-apply, state is lost and the next run may try to re-create existing resources → manual `terraform import` or a `terraform destroy` via a one-off job may be needed. For a class project this is acceptable; we document a manual destroy job below.
- **Base image: `nginx:1.27-alpine`** — small, well-maintained, serves static files natively.

**Sandbox caveat:** if the sandbox credentials expire on a schedule, the user refreshes `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` in GitHub secrets before each deploy. If they're stable, this is a one-time setup.

---

## Target File Layout

```
.
├── .github/
│   └── workflows/
│       ├── ci.yml              # security + build on every PR/push
│       └── cd.yml              # terraform + deploy on main only
├── .gitignore                  # NEW — exclude tf state, .terraform/, etc.
├── .gitleaks.toml              # NEW — allowlist rules
├── sonar-project.properties    # NEW — SonarCloud config
├── Dockerfile                  # NEW
├── nginx/
│   └── default.conf            # NEW — nginx vhost with /health endpoint
├── terraform/
│   ├── versions.tf             # required_providers + terraform block (no backend)
│   ├── providers.tf            # aws provider
│   ├── variables.tf
│   ├── main.tf                 # vpc, subnets, igw, routes, sg, alb, asg, lt
│   ├── outputs.tf              # alb_dns_name
│   └── terraform.tfvars.example
├── css/ js/ images/ fonts/     # existing
└── *.html                      # existing
```

**Files to DELETE:** [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) — replaced by `ci.yml` + `cd.yml`.

---

## 1. Containerization

**`Dockerfile`** — single-stage (no build step needed for static files):

```dockerfile
FROM nginx:1.27-alpine
RUN addgroup -S app && adduser -S app -G app
COPY nginx/default.conf /etc/nginx/conf.d/default.conf
COPY --chown=app:app index.html about.html book.html menu.html /usr/share/nginx/html/
COPY --chown=app:app css/ /usr/share/nginx/html/css/
COPY --chown=app:app js/ /usr/share/nginx/html/js/
COPY --chown=app:app images/ /usr/share/nginx/html/images/
COPY --chown=app:app fonts/ /usr/share/nginx/html/fonts/
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://localhost/health || exit 1
```

**`nginx/default.conf`** — serves site + `/health` for ALB target group health checks:

```nginx
server {
  listen 80 default_server;
  root /usr/share/nginx/html;
  index index.html;
  server_tokens off;
  location /health { return 200 'ok'; add_header Content-Type text/plain; }
  location / { try_files $uri $uri/ =404; }
}
```

**Tagging:** `ghcr.io/<owner>/feane:sha-<short_sha>` + `ghcr.io/<owner>/feane:latest`. The ASG launch template references `latest`; instance refresh pulls the new image.

---

## 2. Terraform Infrastructure

### State backend
**Local state only.** No `backend` block in [`terraform/versions.tf`](terraform/versions.tf). State files (`terraform.tfstate`) live inside the GitHub Actions runner during the `cd.yml` job and are gitignored locally. This is acceptable for a single-developer school project; for a real team you'd switch to S3 + DynamoDB.

### Networking ([`terraform/main.tf`](terraform/main.tf))
- `aws_vpc` (10.0.0.0/16)
- 2× `aws_subnet` public in different AZs (required by ALB)
- `aws_internet_gateway` + route table + associations
- `aws_security_group` **alb_sg**: ingress 80/443 from `0.0.0.0/0`
- `aws_security_group` **ec2_sg**: ingress 80 **only from alb_sg**, no SSH (use SSM)

### Compute
- `aws_launch_template`:
  - AMI: latest Amazon Linux 2023 via `data "aws_ami"`
  - **No `iam_instance_profile`** (avoids custom IAM work in the sandbox)
  - `user_data` (base64):
    ```bash
    #!/bin/bash
    set -e
    dnf update -y
    dnf install -y docker
    systemctl enable --now docker
    # Image is PUBLIC on ghcr.io — no login needed
    docker pull ghcr.io/<owner>/feane:latest
    docker run -d --restart=always -p 80:80 --name feane ghcr.io/<owner>/feane:latest
    ```
- `aws_autoscaling_group`: min=2, desired=2, max=4, across both subnets, attached to target group
- `aws_lb` (application, internet-facing) + `aws_lb_listener` (:80) + `aws_lb_target_group` (health check `/health`)

**Important:** in GitHub → repo → Packages, the `feane` package **must be made public** after the first push so EC2 can pull anonymously. One-time click.

### Outputs ([`terraform/outputs.tf`](terraform/outputs.tf))
```hcl
output "alb_dns_name" { value = aws_lb.this.dns_name }
```

### Security
- **No SSH from 0.0.0.0/0.** If SSH is needed at all, ec2_sg allows port 22 only from the user's admin IP (variable `admin_cidr`). Otherwise port 22 is closed entirely — recommended default.
- No custom IAM resources are created by Terraform.
- Pin all modules and provider versions in [`terraform/versions.tf`](terraform/versions.tf).

---

## 3. GitHub Actions Pipeline

### [`.github/workflows/ci.yml`](.github/workflows/ci.yml) — runs on PRs and pushes

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read
  security-events: write
  packages: write
  id-token: write

jobs:
  gitleaks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: gitleaks/gitleaks-action@v2
        env: { GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }} }

  sonarcloud:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: SonarSource/sonarcloud-github-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}

  trivy-fs:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: aquasecurity/trivy-action@0.24.0
        with:
          scan-type: fs
          scanners: vuln,secret,misconfig
          severity: HIGH,CRITICAL
          exit-code: '1'

  tf-validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
      - run: terraform -chdir=terraform fmt -check
      - run: terraform -chdir=terraform init -backend=false
      - run: terraform -chdir=terraform validate
      - uses: aquasecurity/tfsec-action@v1.0.3
        with: { working_directory: terraform }

  htmlhint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npx --yes htmlhint "**/*.html"

  build-image:
    needs: [gitleaks, trivy-fs, tf-validate]
    runs-on: ubuntu-latest
    outputs:
      image: ${{ steps.meta.outputs.tags }}
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/${{ github.repository_owner }}/feane
          tags: |
            type=sha,prefix=sha-
            type=raw,value=latest,enable={{is_default_branch}}
      - uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
      - uses: aquasecurity/trivy-action@0.24.0
        with:
          image-ref: ghcr.io/${{ github.repository_owner }}/feane:sha-${{ github.sha }}
          severity: HIGH,CRITICAL
          exit-code: '1'
```

### [`.github/workflows/cd.yml`](.github/workflows/cd.yml) — runs on main after CI passes

```yaml
name: CD
on:
  workflow_run:
    workflows: [CI]
    types: [completed]
    branches: [main]

permissions:
  contents: read

jobs:
  terraform:
    if: github.event.workflow_run.conclusion == 'success'
    runs-on: ubuntu-latest
    environment: production   # gated with manual approval in repo settings
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ap-southeast-1
      - uses: hashicorp/setup-terraform@v3
      - run: terraform -chdir=terraform init
      - run: terraform -chdir=terraform plan -out=tfplan
      - run: terraform -chdir=terraform apply -auto-approve tfplan
      - id: tf
        run: echo "alb=$(terraform -chdir=terraform output -raw alb_dns_name)" >> $GITHUB_OUTPUT

  deploy:
    needs: terraform
    runs-on: ubuntu-latest
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ap-southeast-1
      - name: Trigger ASG instance refresh
        run: |
          aws autoscaling start-instance-refresh \
            --auto-scaling-group-name feane-asg \
            --preferences MinHealthyPercentage=50,InstanceWarmup=60
      - name: Smoke test
        run: |
          for i in {1..30}; do
            if curl -fsS "http://${{ needs.terraform.outputs.alb }}/health"; then exit 0; fi
            sleep 10
          done
          exit 1
```

---

## 4. Secrets & IAM Setup (one-time)

**GitHub repo secrets:**
- `AWS_ACCESS_KEY_ID` — from sandbox credentials
- `AWS_SECRET_ACCESS_KEY` — from sandbox credentials
- `SONAR_TOKEN` — from SonarCloud project (permanent, set once)

**One-time setup (no IAM work, no extra AWS resources):**
1. **SonarCloud:** create org + project at sonarcloud.io, generate token, put key in [`sonar-project.properties`](sonar-project.properties) and the token in `SONAR_TOKEN` GitHub secret.
2. **ghcr.io package visibility:** after the first successful CI run, go to GitHub → your profile → Packages → `feane` → Package settings → **Change visibility to Public**. One-click action; required so EC2 can pull without auth.
3. **GitHub environment:** create a `production` environment in repo Settings → Environments and add yourself as a required reviewer (this gates `terraform apply`).

**Why this approach avoids extra setup:**
- Sandbox credentials come pre-provisioned → no IAM user created by us
- Public ghcr.io image → no instance profile / no IAM role on EC2
- Local Terraform state → no S3 bucket, no DynamoDB table
- Terraform creates zero `aws_iam_*` resources

---

## 5. Supporting Files

**`.gitignore`:**
```
# Terraform
**/.terraform/
*.tfstate
*.tfstate.*
*.tfvars
!*.tfvars.example
.terraform.lock.hcl
crash.log

# OS / IDE
.DS_Store
.idea/
.vscode/
```

**`sonar-project.properties`:**
```
sonar.projectKey=<owner>_feane
sonar.organization=<sonar-org>
sonar.sources=.
sonar.exclusions=fonts/**,images/**,**/*.min.js,**/*.min.css
```

**`.gitleaks.toml`:** start with default rules; add allowlist entries only as needed.

**Dependabot** — `.github/dependabot.yml` to keep GH Actions and Docker base image pinned:
```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule: { interval: weekly }
  - package-ecosystem: docker
    directory: /
    schedule: { interval: weekly }
```

---

## 6. Security Best Practices Baked In

- Sandbox temporary credentials stored as GitHub secrets (including session token); refreshed each lab session
- Zero custom IAM resources created by this project (sandbox constraint)
- No SSH open to the world; SSM Session Manager only
- ALB is the only public ingress; EC2 SG only accepts traffic from the ALB SG
- Trivy scans: filesystem + image (fails on HIGH/CRITICAL)
- tfsec on Terraform
- Gitleaks on every commit
- SonarCloud quality gate blocks merge on regression
- Pin action versions (upgrade via Dependabot)
- `environment: production` requires manual approval before `terraform apply`
- Branch protection on `main`: require CI + review + up-to-date
- Image tags immutable by SHA (launch template could pin to sha-<commit> instead of `latest` for stricter deploys — tradeoff: requires `terraform apply` on each deploy. **Recommendation: pin to SHA** and let the CD job update the launch template version, making deploys fully auditable.)

**Stretch (mention, don't implement now):** ACM cert + ALB :443 listener + Route53 record for HTTPS.

---

## 7. Verification Plan

**Local (before pushing):**
- `docker build -t feane:test .` then `docker run -p 8080:80 feane:test` → visit http://localhost:8080 and http://localhost:8080/health
- `terraform -chdir=terraform fmt && terraform -chdir=terraform validate`
- `gitleaks detect --source .` locally

**First pipeline run (on a feature branch):**
- Open a PR → confirm all CI jobs run and pass (gitleaks, sonarcloud, trivy-fs, tf-validate, htmlhint, build-image)
- Confirm image appears in `ghcr.io/<owner>/feane` with `sha-...` tag
- Merge to main → CD workflow triggers
- Approve the `production` environment gate
- Watch `terraform apply` create VPC/ALB/ASG
- Confirm ASG instances reach `InService` and target group health = healthy
- `curl http://<alb_dns_name>/health` → `ok`
- Browser: `http://<alb_dns_name>/` → Feane homepage loads

**Ongoing verification:**
- Push a trivial HTML change → full pipeline runs → instance refresh rolls new containers → new content visible without downtime (ALB keeps 50% healthy)
- Introduce a fake secret (e.g. `AKIA...`) → confirm Gitleaks fails the job
- Introduce a vulnerable base image tag → confirm Trivy fails the job

---

## Critical Files to Create/Modify

| Action | Path |
|---|---|
| Create | [Dockerfile](Dockerfile) |
| Create | [nginx/default.conf](nginx/default.conf) |
| Create | [terraform/versions.tf](terraform/versions.tf), [providers.tf](terraform/providers.tf), [backend.tf](terraform/backend.tf), [variables.tf](terraform/variables.tf), [main.tf](terraform/main.tf), [outputs.tf](terraform/outputs.tf), [terraform.tfvars.example](terraform/terraform.tfvars.example) |
| Create | [.github/workflows/ci.yml](.github/workflows/ci.yml) |
| Create | [.github/workflows/cd.yml](.github/workflows/cd.yml) |
| Create | [.github/dependabot.yml](.github/dependabot.yml) |
| Create | [.gitignore](.gitignore), [.gitleaks.toml](.gitleaks.toml), [sonar-project.properties](sonar-project.properties) |
| Delete | [.github/workflows/deploy.yml](.github/workflows/deploy.yml) |

---

## Remaining Items to Provide at Implementation Time

1. **AWS region** — plan assumes `ap-southeast-1`; confirm or override
2. **SonarCloud org slug and project key** for `sonar-project.properties`
3. **GitHub repo owner/name** (for ghcr.io image path)
4. **Domain name** for HTTPS/ACM — skip TLS for v1, add as stretch later
