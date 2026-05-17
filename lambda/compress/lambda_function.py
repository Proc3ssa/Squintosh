"""
SquishIt — Image Compression Lambda
Triggered by S3 PUT events on the raw-uploads bucket.
Downloads the image, compresses it using Pillow, and saves to the compressed bucket.
"""

import boto3
import json
import logging
import os
import urllib.parse
from io import BytesIO
from PIL import Image, ImageOps

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")

# ── Config (set via Lambda environment variables) ──────────────────────────
COMPRESSED_BUCKET = os.environ["COMPRESSED_BUCKET"]   # destination bucket name
DEFAULT_QUALITY   = int(os.environ.get("DEFAULT_QUALITY", 75))
DEFAULT_MAX_DIM   = int(os.environ.get("DEFAULT_MAX_DIM", 0))   # 0 = no resize
DEFAULT_FORMAT    = os.environ.get("DEFAULT_FORMAT", "same")    # same|jpeg|png|webp

# Formats Pillow can save
SUPPORTED_FORMATS = {"jpeg", "jpg", "png", "webp", "gif"}

# Map extension → Pillow format string
EXT_TO_PIL = {
    "jpg":  "JPEG",
    "jpeg": "JPEG",
    "png":  "PNG",
    "webp": "WEBP",
    "gif":  "GIF",
}

MIME_MAP = {
    "JPEG": "image/jpeg",
    "PNG":  "image/png",
    "WEBP": "image/webp",
    "GIF":  "image/gif",
}


def lambda_handler(event, context):
    """Entry point — handles S3 trigger events."""
    results = []

    for record in event.get("Records", []):
        try:
            result = process_record(record)
            results.append(result)
        except Exception as e:
            key = record.get("s3", {}).get("object", {}).get("key", "unknown")
            logger.error(f"Failed to process {key}: {e}", exc_info=True)
            results.append({"key": key, "status": "error", "error": str(e)})

    return {"statusCode": 200, "body": json.dumps(results)}


def process_record(record):
    """Download, compress, and re-upload a single image."""
    source_bucket = record["s3"]["bucket"]["name"]
    raw_key       = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

    logger.info(f"Processing s3://{source_bucket}/{raw_key}")

    # ── 1. Read compression settings from S3 object metadata ──────────────
    head     = s3.head_object(Bucket=source_bucket, Key=raw_key)
    metadata = head.get("Metadata", {})

    quality    = int(metadata.get("quality",       DEFAULT_QUALITY))
    fmt_choice = metadata.get("format",            DEFAULT_FORMAT)
    max_dim    = int(metadata.get("max_dimension", DEFAULT_MAX_DIM))

    # ── 2. Download the original image ─────────────────────────────────────
    response     = s3.get_object(Bucket=source_bucket, Key=raw_key)
    image_bytes  = response["Body"].read()
    original_size = len(image_bytes)

    # ── 3. Open with Pillow ────────────────────────────────────────────────
    img = Image.open(BytesIO(image_bytes))

    # Correct EXIF orientation (prevents rotated images on mobile uploads)
    img = ImageOps.exif_transpose(img)

    source_ext    = raw_key.rsplit(".", 1)[-1].lower() if "." in raw_key else "jpg"
    source_format = EXT_TO_PIL.get(source_ext, "JPEG")

    # ── 4. Determine output format ─────────────────────────────────────────
    if fmt_choice == "same" or fmt_choice not in ("jpeg", "jpg", "png", "webp"):
        out_format = source_format
        out_ext    = source_ext if source_ext in EXT_TO_PIL else "jpg"
    else:
        out_format = EXT_TO_PIL[fmt_choice]
        out_ext    = "jpg" if fmt_choice == "jpeg" else fmt_choice

    # ── 5. Convert RGBA/P → RGB for JPEG (JPEG doesn't support alpha) ──────
    if out_format == "JPEG" and img.mode in ("RGBA", "P", "LA"):
        background = Image.new("RGB", img.size, (255, 255, 255))
        if img.mode == "P":
            img = img.convert("RGBA")
        background.paste(img, mask=img.split()[-1] if img.mode in ("RGBA", "LA") else None)
        img = background
    elif out_format == "JPEG" and img.mode != "RGB":
        img = img.convert("RGB")

    # ── 6. Resize if max_dim is set ────────────────────────────────────────
    if max_dim > 0:
        img.thumbnail((max_dim, max_dim), Image.LANCZOS)
        logger.info(f"Resized to fit within {max_dim}px — new size: {img.size}")

    # ── 7. Compress into buffer ────────────────────────────────────────────
    buffer = BytesIO()
    save_kwargs = {"format": out_format}

    if out_format == "JPEG":
        save_kwargs.update({
            "quality":   quality,
            "optimize":  True,
            "progressive": True,
        })
    elif out_format == "PNG":
        # PNG quality maps to compression level (0-9); invert the 0-95 scale
        png_compress = max(0, min(9, int((100 - quality) / 11)))
        save_kwargs.update({
            "optimize":  True,
            "compress_level": png_compress,
        })
    elif out_format == "WEBP":
        save_kwargs.update({
            "quality": quality,
            "method":  6,       # slowest = best compression
        })
    elif out_format == "GIF":
        save_kwargs.update({"optimize": True})

    img.save(buffer, **save_kwargs)
    buffer.seek(0)
    compressed_bytes = buffer.read()
    compressed_size  = len(compressed_bytes)

    # ── 8. Build destination key ───────────────────────────────────────────
    # Strip any leading folder, place under compressed/
    base_name   = raw_key.rsplit("/", 1)[-1]          # e.g. photo.jpg
    stem        = base_name.rsplit(".", 1)[0]          # e.g. photo
    dest_key    = f"compressed/{stem}_compressed.{out_ext}"

    # ── 9. Upload to compressed bucket ────────────────────────────────────
    s3.put_object(
        Bucket      = COMPRESSED_BUCKET,
        Key         = dest_key,
        Body        = compressed_bytes,
        ContentType = MIME_MAP.get(out_format, "image/jpeg"),
        Metadata    = {
            "original-key":     raw_key,
            "original-size":    str(original_size),
            "compressed-size":  str(compressed_size),
            "quality":          str(quality),
            "format":           out_format.lower(),
            "savings-pct":      str(round((1 - compressed_size / original_size) * 100, 1)),
        }
    )

    savings_pct = round((1 - compressed_size / original_size) * 100, 1)
    logger.info(
        f"✓ Compressed {raw_key} → {dest_key} | "
        f"{_fmt(original_size)} → {_fmt(compressed_size)} ({savings_pct}% saved)"
    )

    return {
        "status":          "ok",
        "source_key":      raw_key,
        "dest_key":        dest_key,
        "original_size":   original_size,
        "compressed_size": compressed_size,
        "savings_pct":     savings_pct,
        "dimensions":      list(img.size),
        "format":          out_format,
    }


def _fmt(n):
    """Human-readable byte size."""
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} GB"
