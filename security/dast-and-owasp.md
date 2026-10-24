# Dynamic Application Security Testing (DAST) & OWASP Top 10 Integration
**Tooling:** OWASP ZAP (Zed Attack Proxy)  
**Standard:** OWASP Top 10:2021 / OWASP API Security Top 10

---

## 1. DAST Implementation Architecture

Dynamic Application Security Testing (DAST) inspects the compiled, running application from an external attacker's perspective without knowledge of the internal source code. This verifies that runtime configurations, web server behavior, HTTP security headers, and authentication controls function correctly.

```
+----------------------------------------------------------------------------------------------------+
|                                    DAST PIPELINE WORKFLOW                                          |
+----------------------------------------------------------------------------------------------------+
  [ Built Container Image ]
             │
             ▼
  [ 1. Ephemeral Staging Runner ] ──> Spin up container in isolated test network
             │
             ▼
  [ 2. Authentication Hook ]      ──> Inject synthetic test JWT token / session bearer
             │
             ▼
  [ 3. OWASP ZAP Engine ]         ──> 1. Passive Baseline Scan (Headers, Cookies, Leaks)
             │                        2. OpenAPI Specification Spidering
             │                        3. Targeted Active Fuzzing (SQLi, IDOR, SSRF)
             ▼
  [ 4. Automated Gate Analysis ]  ──> High / Critical CWEs ==> FAIL Pipeline
             │
             ▼
  [ 5. Ephemeral Teardown ]       ──> Destroy test container & purge synthetic mock data
```

---

## 2. Core Implementation Requirements

### 1. How the Application Is Made Available in a Safe Test Environment
- **Ephemeral Container Sandbox in CI/CD:**
  During the pipeline's `dast` stage, the freshly built Docker container is instantiated within an isolated Docker-in-Docker (DinD) bridge network or a dedicated staging ECS cluster.
  ```yaml
  # GitHub Actions / GitLab CI ephemeral test container startup
  docker run -d --name ephemeral-api \
    --network test-net \
    -e ENVIRONMENT=staging \
    -e DB_CONFIG='{"host":"mock-db","port":5432,"username":"test","password":"test-mock-password"}' \
    -p 8080:8080 app-backend-api:${CI_COMMIT_SHA}
  ```
- **Mocked / Isolated Data Layer:**
  The container connects to an in-memory mock database (e.g., PostgreSQL container seeded with synthetic dummy data). It has **zero connectivity** to real user data or production databases.

### 2. Which DAST Checks Are Executed Automatically
DAST testing is split into two automated passes to balance security depth with pipeline execution speed:
1. **Automated Baseline Scan (Passive):**
   - **Target:** All endpoints discovered via OpenAPI/Swagger definition (`/openapi.json`).
   - **Checks:**
     - Missing security headers (`Strict-Transport-Security`, `Content-Security-Policy`, `X-Content-Type-Options`, `X-Frame-Options`).
     - Insecure cookie attributes (`Secure`, `HttpOnly`, `SameSite`).
     - Information leakage (Server software version headers, stack traces, internal IP exposure).
     - Permissive CORS wildcards (`Access-Control-Allow-Origin: *`).
2. **Targeted Active Scan (Active Fuzzing on Feature/Release Branches):**
   - Automated injection attacks against API query parameters and JSON payloads:
     - SQL Injection (SQLi) and Blind SQLi payloads.
     - Remote Code Execution (RCE) / Command Injection characters.
     - Server-Side Request Forgery (SSRF) URL probes.
     - Cross-Site Scripting (Reflected XSS in error responses).

### 3. How Authentication Is Handled During Testing
Modern REST APIs require authenticated contexts to reach business logic. OWASP ZAP handles authentication via:
- **Bearer Token Injection via ZAP Replacer Rule:**
  The CI pipeline generates a short-lived synthetic JWT signed with a known test private key and passes it as a command option to OWASP ZAP:
  ```bash
  zap-api-scan.py -t http://localhost:8080/openapi.json -f openapi \
    -z "-config replacer.full_list(0).description=auth \
        -config replacer.full_list(0).enabled=true \
        -config replacer.full_list(0).matchtype=REQ_HEADER \
        -config replacer.full_list(0).matchstr=Authorization \
        -config replacer.full_list(0).replacement='Bearer eyJhbGciOi...' "
  ```
- **Dual-Persona Scanning:**
  To detect Broken Object Level Authorization (BOLA/IDOR), ZAP runs two consecutive scans with distinct user tokens (`User_A` and `User_B`) to verify that `User_A` cannot access resources created by `User_B`.

### 4. Which Findings Should Block a Release
- **Mandatory Release Blocking Gate (Pipeline Fails / Exit Code 1):**
  - **High & Critical Vulnerabilities:**
    - Any confirmed SQL Injection, Command Injection, or RCE.
    - Path Traversal / Arbitrary File Read.
    - Broken Authentication / Session Hijacking flaws.
    - Unvalidated redirects to external untrusted domains.
- **Informational / Low Severity (Non-Blocking):**
  - Minor missing caching headers or timestamp disclosures are logged to SARIF/Jira reports for resolution during regular sprint cycles.

### 5. Preventing Security Testing from Affecting Production Systems
Running active vulnerability scans against production systems can cause Denial of Service (DoS), database corruption, or financial charges. We enforce strict isolation:
1. **Network Segmentation:** DAST scans run exclusively in isolated VPCs or runner containers with no route table entry to production VPCs.
2. **Disabled Outbound Integrations:** Third-party webhooks (Stripe, Twilio, SendGrid) are mocked with dummy endpoints in the test configuration so scans never trigger external charges or emails.
3. **Synthetic Test Data Only:** Databases are pre-seeded with sanitized dummy records and wiped immediately upon scan completion.
4. **Target URL Whitelisting:** ZAP execution scripts are hardcoded with strict scope rules (`-t http://localhost:8080` or `https://staging-api.internal`) preventing scans from straying into production URLs.

---

## 3. Analysis & Mitigation of Three Key OWASP Top 10 Risks

### Risk 1: A01:2021 – Broken Access Control (BOLA / IDOR)
- **Description:** Flaws that allow an authenticated user to view, edit, or delete another user's private data simply by altering an ID parameter (e.g., `GET /api/v1/orders/1002` accessed by User 1001).
- **Automated DAST Detection:**
  OWASP ZAP fuzzes sequential object IDs while presenting a low-privilege JWT. If the API returns HTTP 200 with sensitive customer data instead of HTTP 403 Forbidden, an access control violation is flagged.
- **Engineered Mitigation:**
  - Enforce tenant and user authorization checks in the data layer (e.g., `SELECT * FROM orders WHERE id = :id AND tenant_id = :current_user_tenant_id`).
  - Use cryptographically random UUIDv4 identifiers instead of predictable sequential integer IDs.

### Risk 2: A03:2021 – Injection (SQL Injection / Command Injection)
- **Description:** Untrusted user data is concatenated directly into SQL queries or system commands, allowing an attacker to execute arbitrary database queries or shell commands.
- **Automated DAST Detection:**
  OWASP ZAP injects classic SQLi payloads (e.g., `' OR '1'='1`, `SLEEP(5)`, `UNION SELECT`) into all URL parameters and JSON body fields, monitoring for database error strings or delayed response times.
- **Engineered Mitigation:**
  - Strictly prohibit raw SQL string concatenation. Enforce parameterized queries or typed Object Relational Mapping (ORM) tools.
  - Implement strict Pydantic input validation using regex whitelists (e.g., `pattern=r"^[a-zA-Z0-9_\-\s]+$"`).
  - Deploy AWS WAF with `AWSManagedRulesCommonRuleSet` and `AWSManagedRulesSQLiRuleSet` at the ALB edge.

### Risk 3: A05:2021 – Security Misconfiguration
- **Description:** Default credentials, verbose error stack traces enabled in production, open cloud storage buckets, or missing HTTP security headers that leave the application vulnerable to clickjacking or cross-site attacks.
- **Automated DAST Detection:**
  OWASP ZAP baseline scan sends malformed HTTP requests and checks responses for:
  - Presence of Python/FastAPI tracebacks containing file paths or environment variables.
  - Absence of `Strict-Transport-Security`, `Content-Security-Policy`, and `X-Content-Type-Options`.
- **Engineered Mitigation:**
  - Implement centralized custom exception handlers returning clean JSON errors (`{"error": "Internal server error"}`) without stack traces.
  - Disable interactive Swagger/OpenAPI documentation (`docs_url=None`) in production environments.
  - Enforce security headers middleware in FastAPI on every HTTP response.
