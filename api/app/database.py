import os
from datetime import date, datetime, timedelta, timezone

from dotenv import load_dotenv
from sqlalchemy import create_engine
from sqlalchemy.orm import declarative_base, sessionmaker

load_dotenv()

# Dates (months, quarters, "today", date filters) follow the farmers' local time,
# whatever timezone the server or the database runs in.
APP_TIMEZONE = os.getenv("APP_TIMEZONE", "Asia/Manila")
try:
    from zoneinfo import ZoneInfo

    LOCAL_TZ = ZoneInfo(APP_TIMEZONE)
except Exception:  # no tz database (Windows without tzdata); the Philippines has no DST
    LOCAL_TZ = timezone(timedelta(hours=8))
# Each database session uses the same zone, so timestamps come back in local time.
_SESSION_TZ = {"options": f"-c timezone={APP_TIMEZONE}"}


def local_today() -> date:
    return datetime.now(LOCAL_TZ).date()


DATABASE_URL = os.getenv("DATABASE_URL")
if not DATABASE_URL:
    raise RuntimeError(
        "DATABASE_URL is not set. Example: "
        "postgresql+psycopg://postgres:password@localhost:5432/your_database"
    )

engine = create_engine(
    DATABASE_URL,
    pool_pre_ping=True,
    connect_args=_SESSION_TZ,
)

SessionLocal = sessionmaker(
    autocommit=False,
    autoflush=False,
    bind=engine,
)

Base = declarative_base()


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


GEO_DATABASE_URL = os.getenv(
    "GEO_DATABASE_URL",
    "postgresql://user:pass@localhost:5432/rice_pest_geo",
)
geo_engine = create_engine(GEO_DATABASE_URL, pool_pre_ping=True, connect_args=_SESSION_TZ)
GeoSessionLocal = sessionmaker(bind=geo_engine, autocommit=False, autoflush=False)

def get_geo_db():
    db = GeoSessionLocal()
    try:
        yield db
    finally:
        db.close()