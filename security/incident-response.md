# Troubleshooting and Incident Response Playbook

This document details the standardized investigation procedures, root cause analyses, and corrective action playbooks for key security and operational incident scenarios.

---

## Scenario A: Pipeline Security Failure (Critical Vulnerability in Base Image)

### Incident Summary
A CI/CD deployment pipeline fails because Trivy flags a `CRITICAL` vulnerability (e.g., CVSS 9.8 remote code execution) in the base container image. The development team asserts the application functions correctly and requests an immediate emergency release to production.

### Operational Response & Investigation Steps

#### 1. Risk Assessment & Triage (Immediate - 15 Minutes)
- **Do Not Approve Unilateral Bypass:** The pipeline failure is working as designed to prevent a potential breach. Fast-tracking an unsafe deployment violates production controls.
- **Inspect Vulnerability Details:** Review the Trivy scan JSON report to identify:
  - Exact CVE ID (e.g., CVE-2024-XXXX), affected OS package, and version.
  - Exploitability factors: Is weaponized public exploit code available in CISA KEV or Exploit-DB?
  - Reachability: Is the vulnerable binary or shared object invoked by the application runtime, or is it an unused OS tool?
  - Network vector: Is the vulnerability remotely exploitable over HTTP without prior authentication?

#### 2. Rapid Remediation Options (The Fastest Path to Release)
Instead of arguing over an exception, guide developers through immediate technical fixes:
1. **Base Image Bump:** Check Docker Hub / AWS ECR Public for updated patch versions of the base image (e.g., upgrading from `python:3.11.7-slim` to `python:3.11.8-slim` often resolves OS CVEs within minutes).
2. **Targeted Package Update in Dockerfile:** If an updated base image is not yet published, add a targeted package update in the builder stage:
   ```dockerfile
   RUN apt-get update && apt-get install -y --no-install-recommends \
       libssl3=3.0.13-1~deb12u1 && rm -rf /var/lib/apt/lists/*
   ```
3. **Switch to Distroless:** Rebase to Google Distroless or Alpine, which eliminates vulnerable OS utilities completely.

#### 3. Emergency Exception & Release Authorization Process
If technical remediation is impossible and business leadership mandates an urgent deployment:
- **Compensating Controls Verification:** Before any sign-off, verify compensating defenses:
  - Is the container protected behind AWS WAF with rules blocking exploit signatures?
  - Does the ECS task enforce a read-only root filesystem and dropped capabilities?
  - Are egress rules restricted to prevent external C2 (Command & Control) callbacks?
- **Formal Exception Protocol:**
  - Create an urgent Security Exception Ticket documenting the CVE, residual risk score, and required compensating controls.
  - **Required Authorization:** Dual sign-off from the **Head of Engineering** and the **Chief Information Security Officer (CISO)**.
  - **Temporary Exemption Window:** Maximum 72-hour waiver in the CI/CD pipeline using a temporary, tracked `.trivyignore` entry with commit hash and expiration date.
  - Continuous runtime monitoring enabled via AWS GuardDuty container runtime protection.

---

## Scenario B: ECS Fargate Application Cannot Retrieve Secrets

### Incident Summary
An ECS Fargate task fails during startup (`Task stopped with exit code 1` or `ResourceInitializationError: unable to pull secrets or registry auth`).

### Root Cause Analysis & Investigation Framework (Least-Privilege Isolation)

To diagnose and isolate the issue **without granting broad administrator permissions (`*`)**, investigate the following five architectural components in sequence:

```
+----------------------------------------------------------------------------------------------------+
|                         ECS SECRETS RETRIEVAL INVESTIGATION PATH                                   |
+----------------------------------------------------------------------------------------------------+
  1. CloudWatch / ECS Stopped Reason ──> Look for exact error string & ARN
  2. ECS Task Execution Role         ──> Verify secretsmanager:GetSecretValue on Secret ARN
  3. KMS Key Policy                  ──> Verify kms:Decrypt on CMK ARN with viaService condition
  4. Network & VPC Endpoints         ──> Verify PrivateLink endpoint on 443 + DNS resolution
  5. Secrets Manager Resource Policy ──> Verify no explicit Deny blocking execution role
```

#### Step 1: Inspect ECS Task Event Stream & Stopped Reason
Run the following targeted AWS CLI command (requiring only `ecs:DescribeTasks` permission):
```bash
aws ecs describe-tasks \
  --cluster app-production-cluster \
  --tasks <task-id> \
  --query "tasks[0].containers[0].[exitCode,reason]" \
  --output text
```
- **Diagnostic Signal:** If the reason states `Fetching secret data from Secrets Manager in region ...: AccessDeniedException`, this confirms an IAM or KMS permission block.
- If it states `Task failed to start: Context deadline exceeded / Timeout`, this indicates a **network routing or VPC endpoint failure**.

#### Step 2: Differentiate ECS Task Execution Role vs. Task Role
- **Common Confusion:** Developers often attach `secretsmanager:GetSecretValue` to the **Task Role** instead of the **Task Execution Role**.
- **Correct Configuration:**
  - **Task Execution Role (`execution_role_arn`):** Used by the AWS Fargate agent before container initialization to pull images and fetch secrets defined in the `secrets` block of the task definition.
  - **Task Role (`task_role_arn`):** Used by the application code *inside* the container during runtime.
  - **Action:** Inspect the IAM policy attached to the **Execution Role** to verify it includes:
    ```json
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": "arn:aws:secretsmanager:ap-southeast-1:123456789012:secret:app/production/database-*"
    }
    ```

#### Step 3: Inspect KMS Key Permissions (Customer Managed Key)
- If the secret is encrypted with a Customer Managed Key (CMK), the Execution Role must also have KMS decryption permissions.
- **Check Key Policy:** Confirm the KMS Key Policy allows the execution role to perform `kms:Decrypt`:
  ```json
  {
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::123456789012:role/app-production-ecs-execution-role" },
    "Action": ["kms:Decrypt", "kms:DescribeKey"],
    "Resource": "*",
    "Condition": {
      "StringEquals": {
        "kms:ViaService": "secretsmanager.ap-southeast-1.amazonaws.com"
      }
    }
  }
  ```

#### Step 4: Verify Network Connectivity & PrivateLink VPC Endpoints
- Since ECS Fargate tasks reside in private subnets with no public IPs, they cannot reach public AWS API endpoints unless a NAT Gateway or VPC Endpoints exist.
- **Verification Checklist:**
  1. Confirm interface VPC Endpoints exist for both:
     - `com.amazonaws.ap-southeast-1.secretsmanager`
     - `com.amazonaws.ap-southeast-1.kms`
  2. Confirm `private_dns_enabled = true` on both VPC endpoints.
  3. Confirm the **VPC Endpoint Security Group** allows inbound TCP port 443 from the **ECS Task Security Group**.
  4. Confirm the ECS Task Security Group allows outbound TCP port 443 to the VPC Endpoint Security Group.

#### Step 5: Secrets Manager Resource-Based Policies
- Inspect the secret in AWS Secrets Manager:
  ```bash
  aws secretsmanager get-resource-policy --secret-id app/production/database
  ```
- Verify that no resource-based policy explicitly denies the execution role or requires conditions (such as specific VPC Endpoint IDs) that are failing.

---

## Scenario C: Unauthorized AWS API Activity by Deployment Pipeline Principal

### Incident Summary
AWS CloudTrail and GuardDuty generate high-severity alerts showing unexpected API calls (e.g., `iam:CreateUser`, `s3:ListBuckets`, `ec2:DescribeInstances`, or calls from foreign IP addresses) originating from the IAM principal assigned to the CI/CD deployment pipeline.

### Immediate Containment, Forensics, and Recovery Playbook

```
+----------------------------------------------------------------------------------------------------+
|                               UNAUTHORIZED API INCIDENT WORKFLOW                                   |
+----------------------------------------------------------------------------------------------------+
  1. CONTAINMENT (Min 0-10)   ──> Apply Inline DenyAll, Revoke Active STS Sessions, Kill Runners
  2. FORENSICS (Min 10-60)    ──> CloudTrail Athena Query, Blast Radius, Identify Persisted Backdoors
  3. REMEDIATION (Hour 1-4)   ──> Delete Rogues, Invalidate Compromised Secrets, Verify Integrity
  4. HARDENING (Post-Mortem)  ──> Enforce OIDC Token Binding, GuardDuty Automated Remediation
```

### Phase 1: Immediate Containment (T + 0 to 10 Minutes)
1. **Immediate Revocation of Permissions (Lockdown Policy):**
   Attach an inline `DenyAll` policy directly to the compromised IAM role to instantly neutralize any further actions by the attacker:
   ```bash
   aws iam put-role-policy \
     --role-name cicd-deployer-role \
     --policy-name ImmediateIncidentLockdown \
     --policy-document '{
       "Version": "2012-10-17",
       "Statement": [{
         "Effect": "Deny",
         "Action": "*",
         "Resource": "*"
       }]
     }'
   ```
2. **Invalidate Active Temporary STS Sessions:**
   Revoke all STS sessions issued before the incident timestamp using an IAM role policy statement condition:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Deny",
       "Action": "*",
       "Resource": "*",
       "Condition": {
         "DateLessThan": {
           "aws:TokenIssueTime": "2026-10-24T12:00:00Z"
         }
       }
     }]
   }
   ```
3. **Revoke Static Credentials (if applicable):**
   If static access keys were in use, immediately deactivate and delete them:
   ```bash
   aws iam update-access-key --user-name cicd-user --access-key-id AKIAEXAMPLE --status Inactive
   ```
4. **Pause CI/CD Runners:**
   Temporarily disable GitLab/GitHub pipeline execution to prevent compromised build scripts from executing further steps.

### Phase 2: Forensics & Blast Radius Investigation (T + 10 to 60 Minutes)
1. **CloudTrail Investigation via Amazon Athena / CloudWatch Insights:**
   Query all events generated by the compromised ARN within the incident window:
   ```sql
   SELECT eventTime, eventSource, eventName, awsRegion, sourceIPAddress, userAgent, responseElements
   FROM cloudtrail_logs
   WHERE userIdentity.arn LIKE '%cicd-deployer-role%'
     AND eventTime >= '2026-10-24T00:00:00Z'
   ORDER BY eventTime ASC;
   ```
2. **Determine Initial Compromise Vector:**
   - Was a static key committed to a public GitHub repo?
   - Was a third-party GitHub Action malicious / compromised (Supply chain attack)?
   - Was the OIDC trust condition too broad (e.g., missing repository constraint)?
3. **Audit Potential Backdoors & Persistence Mechanisms:**
   Search CloudTrail logs specifically for persistence actions:
   - `iam:CreateAccessKey`, `iam:CreateUser`, `iam:AttachUserPolicy`, `iam:CreateRole`
   - `ec2:AuthorizeSecurityGroupIngress` (opening ports to 0.0.0.0/0)
   - `s3:PutBucketPolicy` (making S3 buckets public)
   - `lambda:CreateFunction` or `kms:PutKeyPolicy`.

### Phase 3: Remediation & Recovery (T + 1 to 4 Hours)
1. **Dismantle Attacker Infrastructure:**
   - Delete any unauthorized IAM users, roles, access keys, or EC2 instances created during the breach.
   - Revert security groups and bucket policies to known-good Terraform baseline.
2. **Re-verify Terraform State:**
   - Run `terraform plan -refresh-only` to detect unauthorized drift between actual AWS infrastructure and the committed code.
3. **Re-issue Infrastructure & Workload Attestation:**
   - Force rebuild of container images from verified source commits.
   - Rotate application database credentials in AWS Secrets Manager.

### Phase 4: Long-Term Post-Incident Hardening
1. **Mandate GitHub / GitLab OIDC Integration:**
   Completely eliminate static IAM credentials. Enforce strict OIDC claims:
   ```json
   "Condition": {
     "StringEquals": {
       "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
     },
     "StringLike": {
       "token.actions.githubusercontent.com:sub": "repo:my-org/my-repo:ref:refs/heads/main"
     }
   }
   ```
2. **Attach IAM Permissions Boundaries:**
   Apply an IAM Permissions Boundary preventing deployment roles from modifying IAM policies, creating users, or disabling logging.
3. **Automated Incident Response via EventBridge & Lambda:**
   Configure an AWS EventBridge rule triggered by GuardDuty findings to automatically quarantine compromised IAM roles within seconds.
