import os
import json
import logging
from typing import Optional
from pydantic_settings import BaseSettings

logger = logging.getLogger("app.config")

class Settings(BaseSettings):
    app_name: str = "DevSecOps Secure Backend API"
    environment: str = os.getenv("ENVIRONMENT", "production")
    port: int = int(os.getenv("PORT", "8080"))
    db_host: str = "localhost"
    db_port: int = 5432
    db_user: str = "app_prod_user"
    db_password: Optional[str] = None
    db_name: str = "app_production"

    @classmethod
    def load_secure_settings(cls) -> "Settings":
        """
        Loads configuration securely.
        1. Checks for injected Secrets Manager JSON payload in DB_CONFIG env var.
        2. Falls back to individual environment variables (never hardcoded in code).
        3. Never logs or prints secrets to stdout/stderr.
        """
        db_config_raw = os.getenv("DB_CONFIG")
        if db_config_raw:
            try:
                secret_dict = json.loads(db_config_raw)
                logger.info("Successfully loaded database configuration from AWS Secrets Manager injection.")
                return cls(
                    db_host=secret_dict.get("host", "localhost"),
                    db_port=secret_dict.get("port", 5432),
                    db_user=secret_dict.get("username", "app_prod_user"),
                    db_password=secret_dict.get("password"),
                    db_name=secret_dict.get("database", "app_production")
                )
            except Exception as e:
                logger.error(f"Failed to parse DB_CONFIG secret JSON: {str(e)}")
        
        # Fallback to standard environment parameters
        return cls()

settings = Settings.load_secure_settings()
