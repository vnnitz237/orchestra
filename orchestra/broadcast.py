import redis.asyncio as aioredis
import json, os, logging

_redis = None
logger = logging.getLogger(__name__)

async def get_redis():
    global _redis
    if _redis is None:
        _redis = aioredis.from_url(os.environ.get("REDIS_URL", "redis://localhost:6379"))
    return _redis

async def broadcast(project_id: str, event: dict):
    try:
        r = await get_redis()
        await r.publish(f"project:{project_id}", json.dumps(event, default=str))
    except Exception as e:
        logger.error(f"broadcast error: {e}")
