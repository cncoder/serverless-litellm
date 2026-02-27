"""
DynamoDB API Key Authentication Module for LiteLLM

Environment Variables:
- AWS_REGION: AWS region for DynamoDB
- DYNAMODB_API_KEYS_TABLE: DynamoDB table name

DynamoDB Table Schema:
- api_key (String, Hash Key): API key
- user_id (String): User identifier
- max_budget (Number): Maximum budget for this key
- enabled (Boolean): Whether the key is active
"""

import hashlib
import os
import time
from typing import Optional, Dict

import boto3
from botocore.exceptions import ClientError

try:
    from litellm.proxy._types import UserAPIKeyAuth
    from litellm.proxy.utils import ProxyException
except ImportError:
    raise ImportError("This module requires litellm proxy types")


class DynamoDBAuthCache:
    """In-memory cache for API key lookups with 60 second TTL"""

    def __init__(self, ttl_seconds: int = 60):
        self._cache: Dict[str, tuple[UserAPIKeyAuth, float]] = {}
        self._ttl = ttl_seconds

    def get(self, api_key: str) -> Optional[UserAPIKeyAuth]:
        if api_key not in self._cache:
            return None

        auth_obj, timestamp = self._cache[api_key]
        if time.time() - timestamp > self._ttl:
            del self._cache[api_key]
            return None

        return auth_obj

    def set(self, api_key: str, auth_obj: UserAPIKeyAuth) -> None:
        self._cache[api_key] = (auth_obj, time.time())

    def invalidate(self, api_key: str) -> None:
        self._cache.pop(api_key, None)


# Global cache instance
_auth_cache = DynamoDBAuthCache(ttl_seconds=60)

# Global DynamoDB client
_dynamodb_client = None


def get_dynamodb_client():
    """Get or create DynamoDB client"""
    global _dynamodb_client
    if _dynamodb_client is None:
        region = os.environ.get("AWS_REGION", "us-east-1")
        _dynamodb_client = boto3.client("dynamodb", region_name=region)
    return _dynamodb_client


async def user_api_key_auth(request, api_key: str) -> UserAPIKeyAuth:
    """
    Verify API key against DynamoDB table.
    LiteLLM calls this as: user_api_key_auth(request, api_key)

    Args:
        request: The incoming HTTP request (unused)
        api_key: The API key to verify

    Returns:
        UserAPIKeyAuth object with user_id and max_budget

    Raises:
        ProxyException: If key is invalid or DynamoDB error occurs
    """
    # Reject missing API key immediately (e.g. health checks without auth)
    if not api_key:
        raise ProxyException(
            message="Missing API key",
            type="auth_error",
            param=None,
            code=401
        )

    # Allow master key to bypass DynamoDB lookup
    # LiteLLM hashes the API key with SHA256 before passing to custom_auth
    # when master_key is configured in general_settings
    master_key = os.environ.get("LITELLM_MASTER_KEY")
    if master_key:
        master_key_hash = hashlib.sha256(master_key.encode()).hexdigest()
        if api_key == master_key or api_key == master_key_hash:
            return UserAPIKeyAuth(
                api_key=api_key,
                user_id="master",
                max_budget=None
            )

    # Check cache first
    cached_auth = _auth_cache.get(api_key)
    if cached_auth is not None:
        return cached_auth

    # Get table name from environment
    table_name = os.environ.get("DYNAMODB_API_KEYS_TABLE")
    if not table_name:
        raise ProxyException(
            message="DynamoDB table not configured",
            type="auth_error",
            param=None,
            code=500
        )

    try:
        # Query DynamoDB
        dynamodb = get_dynamodb_client()
        response = dynamodb.get_item(
            TableName=table_name,
            Key={"api_key": {"S": api_key}},
            ConsistentRead=False  # Eventually consistent reads are cheaper
        )

        # Check if key exists
        if "Item" not in response:
            raise ProxyException(
                message="Invalid API key",
                type="auth_error",
                param=None,
                code=401
            )

        item = response["Item"]

        # Check if key is enabled
        enabled = item.get("enabled", {}).get("BOOL", False)
        if not enabled:
            raise ProxyException(
                message="API key is disabled",
                type="auth_error",
                param=None,
                code=401
            )

        # Extract fields
        user_id = item.get("user_id", {}).get("S", "")
        max_budget_str = item.get("max_budget", {}).get("N")

        if not user_id:
            raise ProxyException(
                message="Invalid key configuration: missing user_id",
                type="auth_error",
                param=None,
                code=500
            )

        # Parse max_budget
        max_budget = None
        if max_budget_str:
            try:
                max_budget = float(max_budget_str)
            except (ValueError, TypeError):
                raise ProxyException(
                    message="Invalid key configuration: invalid max_budget",
                    type="auth_error",
                    param=None,
                    code=500
                )

        # Create auth object
        auth_obj = UserAPIKeyAuth(
            api_key=api_key,
            user_id=user_id,
            max_budget=max_budget
        )

        # Cache the result
        _auth_cache.set(api_key, auth_obj)

        return auth_obj

    except ProxyException:
        raise
    except ClientError as e:
        error_code = e.response.get("Error", {}).get("Code", "Unknown")
        raise ProxyException(
            message=f"DynamoDB error: {error_code}",
            type="auth_error",
            param=None,
            code=500
        )
    except Exception as e:
        raise ProxyException(
            message=f"Authentication error: {str(e)}",
            type="auth_error",
            param=None,
            code=500
        )


def invalidate_cache(api_key: str) -> None:
    """
    Invalidate cached auth for a specific API key
    Useful when keys are rotated or disabled
    """
    _auth_cache.invalidate(api_key)
