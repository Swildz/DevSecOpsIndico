# ==============================================================================
# Hardened Multi-Stage Dockerfile for Production Backend API
# Standard: CIS Docker Benchmark & DevSecOps Best Practices
# ==============================================================================

# ------------------------------------------------------------------------------
# Stage 1: Build & Dependency Compilation Stage
# ------------------------------------------------------------------------------
FROM python:3.11-slim AS builder

WORKDIR /build

# Install build dependencies if needed, compile wheels, avoid residual caches
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .

# Compile wheels into an isolated wheelhouse directory
RUN pip install --no-cache-dir --user -r requirements.txt

# ------------------------------------------------------------------------------
# Stage 2: Hardened Runtime Stage (Minimal Attack Surface)
# ------------------------------------------------------------------------------
FROM python:3.11-slim AS runtime

# Labeling for supply-chain provenance and compliance auditing
LABEL org.opencontainers.image.title="Indico Secure Backend API" \
      org.opencontainers.image.description="Minimal unprivileged container for backend API" \
      org.opencontainers.image.vendor="Indico DevSecOps" \
      org.opencontainers.image.version="1.0.0"

# Install minimal runtime shared library for libpq (PostgreSQL) and cleanup package index
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /usr/share/doc /usr/share/man

# Create dedicated unprivileged non-root user and group (UID 10001)
RUN groupadd -g 10001 appgroup && \
    useradd -u 10001 -g appgroup -s /sbin/nologin -M appuser

WORKDIR /app

# Copy pre-installed Python wheels and binaries from builder stage to non-root home
COPY --from=builder /root/.local /home/appuser/.local
COPY src/ /app/src/

# Ensure application ownership is assigned to non-root user
RUN chown -R appuser:appgroup /app /home/appuser

# Setup unprivileged environment PATH
ENV PATH="/home/appuser/.local/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8080

# Switch to unprivileged non-root user
USER 10001:10001

# Document container port
EXPOSE 8080

# Container liveness check
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/healthz')" || exit 1

# Launch production server without bash shell invocation
ENTRYPOINT ["python", "src/main.py"]
