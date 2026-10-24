# DevSecOps Engineer Home Test: Secure AWS Containerized Backend API

[![DevSecOps Pipeline](https://github.com/Swildz/DevSecOpsIndico/actions/workflows/devsecops-pipeline.yml/badge.svg)](https://github.com/Swildz/DevSecOpsIndico/actions/workflows/devsecops-pipeline.yml)
[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=Swildz_DevSecOpsIndico&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=Swildz_DevSecOpsIndico)
[![Security Rating](https://sonarcloud.io/api/project_badges/measure?project=Swildz_DevSecOpsIndico&metric=security_rating)](https://sonarcloud.io/summary/new_code?id=Swildz_DevSecOpsIndico)
[![Vulnerabilities](https://sonarcloud.io/api/project_badges/measure?project=Swildz_DevSecOpsIndico&metric=vulnerabilities)](https://sonarcloud.io/summary/new_code?id=Swildz_DevSecOpsIndico)
![AWS Fargate](https://img.shields.io/badge/AWS-ECS%20Fargate-orange)
![Terraform](https://img.shields.io/badge/IaC-Terraform%201.5%2B-purple)

This repository contains the complete implementation and documentation for the **DevSecOps Engineer Home Test**. It establishes an enterprise-grade, defense-in-depth security architecture on AWS and implements an automated CI/CD security pipeline that detects vulnerabilities early and prevents unsafe releases.

---

## Repository Structure

```
devsecops-home-test/
├── README.md                              # Main technical documentation & quickstart
├── Jenkinsfile                            # Production Jenkins Declarative DevSecOps Pipeline
├── .gitlab-ci.yml                         # Production GitLab CI/CD Pipeline
├── sonar-project.properties               # SonarCloud / SonarQube Quality Gate configuration
├── .github/
│   └── workflows/
│       └── devsecops-pipeline.yml         # Production GitHub Actions Pipeline (OIDC)
├── .gitleaks.toml                         # Custom secret scanning configuration
├── architecture/
│   ├── architecture-design.md             # Detailed AWS architecture, request flows & IAM design
│   ├── architecture-diagram.svg           # High-resolution vector architecture diagram
│   └── architecture_diagram.png           # Visual multi-AZ architecture overview
├── app/
│   ├── Dockerfile                         # Hardened multi-stage non-root container definition
│   ├── .dockerignore                      # Context exclusions preventing credential leaks
│   ├── requirements.txt                   # Pinned application dependencies
│   └── src/
│       ├── main.py                        # FastAPI backend with security middleware
│       └── config.py                      # Dynamic AWS Secrets Manager integration
├── terraform/
│   ├── main.tf                            # Provider setup and remote state definitions
│   ├── variables.tf                       # Variable definitions and validation rules
│   ├── outputs.tf                         # Infrastructure ARNs and endpoints
│   ├── vpc.tf                             # Multi-AZ VPC, subnets, flow logs & PrivateLink endpoints
│   ├── security_groups.tf                 # Strict least-privilege security groups
│   ├── iam.tf                             # Execution Role, Task Role & CI/CD OIDC Role
│   ├── kms.tf                             # Customer Managed Keys (CMK) with rotation
│   ├── secrets.tf                         # Secrets Manager with KMS encryption
│   ├── ecs.tf                             # Immutable ECR, Cluster, and Fargate Service
│   ├── alb.tf                             # ALB with TLS 1.3 redirect and AWS WAFv2
│   ├── environments/                      # Multi-environment parameter files
│   │   ├── dev.tfvars                     # Cost-optimized development configuration
│   │   ├── staging.tfvars                 # Pre-production UAT & DAST configuration
│   │   └── production.tfvars              # High-availability Multi-AZ production
│   ├── terraform.tfvars.example           # Example configuration variables
│   └── .checkov.yml                       # IaC security scanner policy configuration
├── security/
│   ├── vulnerability-policy.md            # Severity SLAs and unpatched CVE handling policy
│   ├── incident-response.md               # Playbooks for pipeline failure, secret issue, and compromised IAM
│   ├── scenarios-remediation.md           # Deep dives for Task 3 Scenarios A, B, and C
├── evidence/
│   ├── scan-results.md                    # Complete tool scan logs (Gitleaks, Semgrep, Trivy, Checkov, ZAP)
│   └── live-deployment-and-troubleshooting.md # Live AWS deployment proof, RCA of all solved issues & teardown guide
└── sonar-project.properties               # SonarQube Scanner project configuration
```

---

## 1. Architecture Overview

The backend API is deployed inside a dedicated, multi-AZ Amazon VPC across two Availability Zones, enforcing strict network tiering:
1. **Edge Tier:** Amazon Route 53 with DNSSEC and AWS WAF inspecting Layer 7 traffic against the AWS Core Rule Set, Known Bad Inputs, and IP Reputation lists.
2. **Public Edge Tier:** Application Load Balancer (ALB) terminating TLS 1.3 and redirecting all unencrypted HTTP traffic to HTTPS.
3. **Private Application Tier:** Amazon ECS with AWS Fargate tasks running in private subnets with **no public IP addresses**, read-only root filesystems, and unprivileged user execution (`UID 10001`).
4. **Isolated Data Tier:** Amazon RDS PostgreSQL residing in isolated subnets with zero route to the internet, accepting traffic exclusively from the ECS task security group on port 5432.
5. **Zero-Egress Private Backbone (AWS PrivateLink):** Interface VPC Endpoints for Amazon ECR, AWS Secrets Manager, AWS KMS, and CloudWatch Logs allow tasks to communicate with AWS APIs without internet gateways or NAT gateways.

Detailed request flows, subnet allocations, and threat mitigations are documented in [architecture-design.md](file:///d:/2026%20-%20REC/Indico/architecture/architecture-design.md).

```
                      +---------------------------------------+
                      |               INTERNET                |
                      +---------------------------------------+
                                          │ HTTPS (TLS 1.3)
                                          ▼
                      +---------------------------------------+
                      |         AWS WAF (Web ACL)             |
                      +---------------------------------------+
                                          │
                                          ▼
                      +---------------------------------------+
                      |   Application Load Balancer (ALB)     |  [Public Subnets]
                      +---------------------------------------+
                                          │ Ingress Port 8080 ONLY
                                          ▼
                      +---------------------------------------+
                      |  Amazon ECS Fargate (Backend API)     |  [Private Subnets - No Public IPs]
                      +---------------------------------------+
                         │                                 │
                         ▼ (Port 5432)                     ▼ (HTTPS 443 via PrivateLink)
      +------------------------------------+    +------------------------------------+
      |  Amazon RDS PostgreSQL (Multi-AZ)  |    |  VPC Endpoints (Secrets/KMS/Logs)  |
      +------------------------------------+    +------------------------------------+
```

---

## 2. CI/CD Workflow & Automated Security Gates

The pipeline automates security verification at every step of the release cycle and is implemented for all three major platforms:
- **Jenkins:** [Jenkinsfile](file:///d:/2026%20-%20REC/Indico/Jenkinsfile) (Declarative Pipeline with Docker container agents and approval gate)
- **GitLab CI/CD:** [.gitlab-ci.yml](file:///d:/2026%20-%20REC/Indico/.gitlab-ci.yml) (10-stage pipeline with OIDC authentication)
- **GitHub Actions:** [devsecops-pipeline.yml](file:///d:/2026%20-%20REC/Indico/.github/workflows/devsecops-pipeline.yml) (OIDC + SARIF security tab uploads)

### The 10-Stage Security & Multi-Environment Promotion Pipeline:
```
[1. Source Validation] ──> [2. Secret Scan] ──> [3. SAST Scan] ──> [4. SCA Scan] ──> [5. IaC Scan]
     (Flake8/Black)          (Gitleaks)           (Semgrep)         (Trivy fs)          (Checkov)
                                                                                            │
     ┌──────────────────────────────────────────────────────────────────────────────────────┘
     ▼
[6. Docker Build] ───> [7. Container Scan] ───> [8. DAST Scan] ───> [9. Staging Deploy] ───> [10. Prod Deploy]
  (Multi-Stage)            (Trivy image)          (OWASP ZAP)          (Pre-Prod Test)        (Manual Gate)
```

### Security Gates & Enforcement Rules:
- **Gate 1: Secret Scanning (Gitleaks):** Zero tolerance. Fails on any detected passwords, private keys, or AWS access keys.
- **Gate 2: SAST (Semgrep):** Fails on `HIGH` or `CRITICAL` severity CWE findings (e.g., SQLi, command injection).
- **Gate 3: SCA Dependencies (Trivy fs):** Fails on `CRITICAL` or `HIGH` CVEs with an available upstream patch.
- **Gate 4: IaC Security (Checkov):** Blocks open database ports (`0.0.0.0/0`), missing encryption, or wildcard IAM policies (`*`).
- **Gate 5: Container Security (Trivy image):** Fails on `CRITICAL` vulnerabilities in the container image filesystem.
- **Gate 6: Dynamic Testing (OWASP ZAP):** Ephemeral container spin-up with baseline active exploit scanning.
- **Gate 7: Staging Automated Deployment:** Deploys validated image to the staging environment for automated integration and smoke tests.
- **Gate 8: Production Promotion Gate:** Requires **Manual Approval** in GitHub/GitLab protected environments. Uses the exact immutable Docker image verified in Staging (no rebuilding from code) and authenticates to AWS via **OIDC temporary credentials** (STS `AssumeRoleWithWebIdentity`). Zero static keys exist.

---

## 3. Security Decisions & Assumptions

1. **Elimination of Static IAM Keys:** Long-lived `AKIA...` keys are banned. All CI/CD jobs authenticate via short-lived OpenID Connect (OIDC) tokens restricted to the repository and branch.
2. **Zero Inbound SSH (Bastionless):** Ports 22 and 3389 are closed. If interactive debugging is required, administrators connect via **AWS Systems Manager (SSM) Session Manager** with MFA and full session auditing.
3. **No Hardcoded Secrets:** Application secrets reside exclusively in **AWS Secrets Manager**, encrypted with a Customer Managed Key (CMK) in AWS KMS. ECS injects secrets directly into container memory at startup via the ECS Task Execution Role.
4. **Least-Privilege Role Separation:**
   - **CI/CD Role:** Can only push to ECR and update the specific ECS service.
   - **Task Execution Role:** Used only by the AWS Fargate agent to pull ECR layers and decrypt Secrets Manager secrets.
   - **Task Role:** Assigned to the running application process with zero infrastructure deployment permissions.
5. **Read-Only Root Filesystem:** Container root filesystem is mounted read-only (`readonlyRootFilesystem = true`) with Linux capabilities dropped to prevent attackers from installing packages or rootkits.

---

## 4. Prerequisites & Execution Instructions

### Prerequisites
- Python 3.11+
- Docker & Docker Compose
- Terraform >= 1.5.0
- Security Tooling: `gitleaks`, `semgrep`, `trivy`, `checkov`

### Step-by-Step Validation Commands

#### A. Validate Source Code & Run Secret Scan
```bash
# 1. Lint code
black --check app/src/
flake8 app/src/ --max-line-length=100

# 2. Scan git history for secrets
gitleaks detect --source=. --config=.gitleaks.toml --verbose
```

#### B. Run SAST and SCA Scans
```bash
# 3. Static Application Security Testing
semgrep scan --config=auto --error --severity=ERROR app/

# 4. Software Composition Analysis (Dependencies)
trivy fs --exit-code 1 --severity CRITICAL,HIGH app/
```

#### C. Validate Terraform and Run IaC Security Scan
```bash
# 5. Initialize and validate Terraform syntax
cd terraform
terraform init -backend=false
terraform validate

# 6. Run Checkov IaC security scanner
checkov -d . --framework terraform --compact

# 7. Multi-Environment Provisioning Commands
# Development (Cost-optimized, 1 replica)
terraform plan -var-file="environments/dev.tfvars"

# Staging (Pre-production testing, 1 replica)
terraform plan -var-file="environments/staging.tfvars"

# Production (High availability, Multi-AZ, 2+ replicas)
terraform plan -var-file="environments/production.tfvars"
cd ..
```

#### D. Build and Scan Container Image
```bash
# 7. Build hardened Docker container
docker build -t indico-api:latest app/

# 8. Scan container image for OS and package vulnerabilities
trivy image --exit-code 1 --severity CRITICAL indico-api:latest
```

#### E. Execute DAST Scan (OWASP ZAP)
```bash
# 9. Start container locally
docker run -d --name test-api -p 8080:8080 indico-api:latest

# 10. Run OWASP ZAP baseline scan
docker run -v $(pwd)/evidence:/zap/wrk:rw -t zaproxy/zap-stable:latest \
  zap-baseline.py -t http://host.docker.internal:8080 -r zap-report.html -I

# Cleanup test container
docker stop test-api && docker rm test-api
```

---

## 5. Summary of Home Test Scenarios & Deliverables

| Task / Scenario | Deliverable Document | Core Solution / Key Takeaway |
| :--- | :--- | :--- |
| **Task 1: AWS Architecture** | [architecture-design.md](file:///d:/2026%20-%20REC/Indico/architecture/architecture-design.md) | Multi-AZ VPC, ALB + WAF, Fargate in private subnets, PrivateLink endpoints, zero public IPs. |
| **Task 2: CI/CD Pipeline** | [.gitlab-ci.yml](file:///d:/2026%20-%20REC/Indico/.gitlab-ci.yml) / [devsecops-pipeline.yml](file:///d:/2026%20-%20REC/Indico/.github/workflows/devsecops-pipeline.yml) | 9 automated stages, SARIF reporting, fail-on-critical gates, OIDC AWS authentication. |
| **Task 3: Scenario A (IAM `*`)** | [scenarios-remediation.md](file:///d:/2026%20-%20REC/Indico/security/scenarios-remediation.md) | Prevent account takeover by scoping resource ARNs, separating CI/CD from runtime, and enforcing OIDC. |
| **Task 3: Scenario B (DB `0.0.0.0/0`)**| [scenarios-remediation.md](file:///d:/2026%20-%20REC/Indico/security/scenarios-remediation.md) | Checkov rules `CKV_AWS_17` and `CKV_AWS_260` fail the CI build; PR branch protection blocks merge. |
| **Task 3: Scenario C (State Secret)** | [scenarios-remediation.md](file:///d:/2026%20-%20REC/Indico/security/scenarios-remediation.md) | Immediate DB password rotation, git history purge via filter-repo, migrate to AWS IAM DB Auth. |
| **Task 4: Container Security** | [app/Dockerfile](file:///d:/2026%20-%20REC/Indico/app/Dockerfile) & [vulnerability-policy.md](file:///d:/2026%20-%20REC/Indico/security/vulnerability-policy.md) | Multi-stage build, unprivileged user (`UID 10001`), no compilers, severity handling & unpatched CVE policy. |
| **Task 5: Scenario A (Base Image CVE)**| [incident-response.md](file:///d:/2026%20-%20REC/Indico/security/incident-response.md) | Reachability analysis, immediate package bump, dual sign-off (CISO + Eng Head) 72h time-bound exception. |
| **Task 5: Scenario B (Secrets Failure)**| [incident-response.md](file:///d:/2026%20-%20REC/Indico/security/incident-response.md) | Systematic isolation: Task Execution Role vs Task Role, KMS decrypt permissions, VPC endpoint SGs. |
| **Task 5: Scenario C (Compromised IAM)**| [incident-response.md](file:///d:/2026%20-%20REC/Indico/security/incident-response.md) | Immediate inline DenyAll, revoke active STS sessions, CloudTrail Athena blast radius query, OIDC hardening. |
| **Task 6: DAST & OWASP Top 10** | [dast-and-owasp.md](file:///d:/2026%20-%20REC/Indico/security/dast-and-owasp.md) | OWASP ZAP baseline + active scans in ephemeral test container, bearer auth injection, mitigation of BOLA, SQLi, and misconfig. |
| **Scan Execution Evidence** | [scan-results.md](file:///d:/2026%20-%20REC/Indico/evidence/scan-results.md) | Complete logs for Gitleaks, Semgrep, Trivy, Checkov, and OWASP ZAP showing passed gates. |
| **Live Deployment & RCA** | [live-deployment-and-troubleshooting.md](file:///d:/2026%20-%20REC/Indico/evidence/live-deployment-and-troubleshooting.md) | Full proof of live AWS deployment, root-cause analysis (RCA) of all solved challenges, and teardown steps. |

---

## 6. Known Limitations & Remaining Risks

1. **Third-Party Dependency Zero-Day Vulnerabilities:** While SCA tools detect known CVEs, unknown 0-day exploits require defense-in-depth runtime protection (AWS WAF, GuardDuty, and read-only root filesystems).
2. **DAST Single-Page Application (SPA) Coverage:** Baseline DAST testing scans REST endpoints efficiently, but complex multi-step client workflows require authenticated browser-based end-to-end integration tests (e.g., Playwright / Cypress combined with ZAP proxy).
3. **KMS API Rate Limits at High Scale:** If hundreds of Fargate tasks launch simultaneously during a massive auto-scaling surge, concurrent KMS decrypt requests can encounter API throttling. **Mitigation:** Implement AWS Secrets Manager local in-memory caching with a 5-minute TTL.

---

## 7. Security Compliance & Redaction Notice

- **Zero Plaintext Secrets:** No real AWS access keys, passwords, private certificates, or customer tokens are embedded in this repository.
- **Redacted Demonstration Data:** All account IDs (`858093958225`), domain names (`example.com`), and credentials use sanitized RFC 2606 placeholders or dynamic secret references.
