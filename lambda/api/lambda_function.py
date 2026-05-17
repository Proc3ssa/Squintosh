"""
SquishIt — API Lambda
Handles two routes called via API Gateway:
  POST /upload-url  → returns a presigned S3 PUT URL for direct browser upload
  GET  /list        → returns list of compressed images with presigned GET URLs
"""

import boto3
import json
import logging
import os
import uuid

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")

RAW_BUCKET        = os.environ["RAW_BUCKET"]
COMPRESSED_BUCKET = os.environ["COMPRESSED_BUCKET"]
URL_EXPIRY        = int(os.environ.get("URL_EXPIRY_SECONDS", 900))   # 15 min default

# Allowed MIME types
ALLOWED_TYPES = {
    "image/jpeg", "image/jpg", "image/png",
    "image/webp", "image/gif", "image/bmp", "image/tiff",
}

CORS_HEADERS = {
    "Access-Control-Allow-Origin":  "*",
    "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
}


def lambda_handler(event, context):
    """Route requests based on HTTP method and path."""
    method = event.get("httpMethod", "")
    path   = event.get("path", "")

    logger.info(f"{method} {path}")

    # CORS preflight
    if method == "OPTIONS":
        return _resp(200, {})

    try:
        if method == "POST" and path.endswith("/upload-url"):
            return handle_upload_url(event)
        elif method == "GET" and path.endswith("/list"):
            return handle_list(event)
        else:
            return _resp(404, {"error": "Route not found"})
    except Exception as e:
        logger.error(f"Unhandled error: {e}", exc_info=True)
        return _resp(500, {"error": str(e)})


# ── Route: POST /upload-url ────────────────────────────────────────────────

def handle_upload_url(event):
    """
    Expects JSON body:
      { filename, content_type, quality, format, max_dimension }
    Returns:
      { upload_url, key }
    """
    body = json.loads(event.get("body") or "{}")

    filename     = body.get("filename", "image.jpg")
    content_type = body.get("content_type", "image/jpeg")
    quality      = max(10, min(95, int(body.get("quality", 75))))
    fmt          = body.get("format", "same")
    max_dim      = int(body.get("max_dimension", 0))

    # Validate content type
    if content_type not in ALLOWED_TYPES:
        return _resp(400, {"error": f"Unsupported content type: {content_type}"})

    # Build a unique S3 key
    safe_name = _safe_filename(filename)
    uid       = uuid.uuid4().hex[:8]
    key       = f"uploads/{uid}_{safe_name}"

    # Generate presigned PUT URL with compression settings in metadata
    upload_url = s3.generate_presigned_url(
        "put_object",
        Params={
            "Bucket":      RAW_BUCKET,
            "Key":         key,
            "ContentType": content_type,
            "Metadata": {
                "quality":        str(quality),
                "format":         fmt,
                "max_dimension":  str(max_dim),
            },
        },
        ExpiresIn=URL_EXPIRY,
    )

    logger.info(f"Presigned URL generated for key: {key}")
    return _resp(200, {"upload_url": upload_url, "key": key})


# ── Route: GET /list ───────────────────────────────────────────────────────

def handle_list(event):
    """
    Lists all objects in compressed/ prefix of the compressed bucket.
    Returns presigned GET URLs so images are viewable in browser.
    """
    paginator = s3.get_paginator("list_objects_v2")
    pages     = paginator.paginate(Bucket=COMPRESSED_BUCKET, Prefix="compressed/")

    files = []
    for page in pages:
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if key.endswith("/"):   # skip folder placeholders
                continue

            # Generate presigned GET URL
            url = s3.generate_presigned_url(
                "get_object",
                Params={"Bucket": COMPRESSED_BUCKET, "Key": key},
                ExpiresIn=URL_EXPIRY,
            )

            # Fetch metadata for savings info
            try:
                head     = s3.head_object(Bucket=COMPRESSED_BUCKET, Key=key)
                metadata = head.get("Metadata", {})
            except Exception:
                metadata = {}

            files.append({
                "key":            key,
                "url":            url,
                "size":           obj["Size"],
                "last_modified":  obj["LastModified"].isoformat(),
                "original_size":  int(metadata.get("original-size",  0)),
                "savings_pct":    float(metadata.get("savings-pct",  0)),
                "format":         metadata.get("format", ""),
            })

    # Most recent first
    files.sort(key=lambda f: f["last_modified"], reverse=True)
    logger.info(f"Returning {len(files)} compressed files")
    return _resp(200, files)


# ── Helpers ────────────────────────────────────────────────────────────────

def _resp(status, body):
    return {
        "statusCode": status,
        "headers":    {**CORS_HEADERS, "Content-Type": "application/json"},
        "body":       json.dumps(body, default=str),
    }


def _safe_filename(name):
    """Sanitise a filename for use as an S3 key segment."""
    import re
    name = name.strip().replace(" ", "_")
    name = re.sub(r"[^a-zA-Z0-9._-]", "", name)
    return name[:120] or "image"
