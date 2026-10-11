"""Employee Attendance & Analytics API for the HROne hiring assignment."""
import os
import re
import calendar
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP
from typing import Optional, Literal, Any

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query, Path as ApiPath
from pydantic import BaseModel, ConfigDict, Field, StrictInt, field_validator, model_validator
from pymongo import MongoClient, ASCENDING, DESCENDING, ReturnDocument
from pymongo.errors import DuplicateKeyError, PyMongoError
from bson import ObjectId

load_dotenv(override=False)
UTC = timezone.utc
IST = timezone(timedelta(hours=5, minutes=30))
PRESENCE = {"PRESENT", "WFH", "ON_DUTY"}
ALL_STATUS = PRESENCE | {"ABSENT", "LEAVE"}
EPOCH_MIN, EPOCH_MAX = 100_000_000_000, 4_102_444_800_000
client = MongoClient(os.getenv("MONGO_URI", "mongodb://localhost:27017"), tz_aware=True, serverSelectionTimeoutMS=3000)
db = client[os.getenv("MONGO_DB", "attendance_db")]
app = FastAPI(title="Employee Attendance & Analytics API", version="2.0.0")


def now_utc() -> datetime:
    return datetime.now(UTC).replace(microsecond=0)


def epoch_to_dt(value: Optional[int]) -> Optional[datetime]:
    if value is None:
        return None
    if type(value) is not int or not EPOCH_MIN <= value <= EPOCH_MAX:
        raise HTTPException(422, "timestamp must be an integer epoch-millisecond value in range")
    return datetime.fromtimestamp((value // 1000), UTC)


def dt_to_epoch(value: Optional[datetime]) -> Optional[int]:
    if value is None:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=UTC)
    return int(value.timestamp()) * 1000


def api_value(value: Any) -> Any:
    """Convert Mongo documents (including audit history) to contract JSON values."""
    if isinstance(value, ObjectId):
        return None
    if isinstance(value, datetime):
        return dt_to_epoch(value)
    if isinstance(value, dict):
        return {k: api_value(v) for k, v in value.items() if k != "_id" and k != "id"}
    if isinstance(value, list):
        return [api_value(v) for v in value]
    return value


def public_employee(doc: dict) -> dict:
    doc = dict(doc)
    doc.pop("_id", None)
    doc["created_at"] = dt_to_epoch(doc.get("created_at"))
    return doc


def public_attendance(doc: dict) -> dict:
    result = api_value(doc)
    result.setdefault("punch_in", None)
    result.setdefault("punch_out", None)
    result.setdefault("work_hours", None)
    result.setdefault("late_minutes", 0)
    result.setdefault("overtime_minutes", 0)
    result.setdefault("half_day", False)
    result.setdefault("history", [])
    return result


def parse_date(value: str, label: str = "date") -> date:
    try:
        parsed = date.fromisoformat(value)
    except (ValueError, TypeError):
        raise HTTPException(422, f"{label} must be YYYY-MM-DD")
    if parsed.isoformat() != value:
        raise HTTPException(422, f"{label} must be YYYY-MM-DD")
    return parsed


def month_bounds(month: str) -> tuple[str, str]:
    if not re.fullmatch(r"\d{4}-(0[1-9]|1[0-2])", month or ""):
        raise HTTPException(422, "month must be YYYY-MM")
    year, mon = map(int, month.split("-"))
    return f"{year:04d}-{mon:02d}-01", f"{year:04d}-{mon:02d}-{calendar.monthrange(year, mon)[1]:02d}"


def round_half_up(value: Optional[float], places: int = 2) -> Optional[float]:
    if value is None:
        return None
    quantum = Decimal("1").scaleb(-places)
    return float(Decimal(str(value)).quantize(quantum, rounding=ROUND_HALF_UP))


def time_on_day(day: date, hhmm: str) -> datetime:
    h, m = map(int, hhmm.split(":"))
    return datetime.combine(day, time(h, m), tzinfo=IST).astimezone(UTC).replace(microsecond=0)


def attendance_date(punch_in: datetime, emp: dict) -> str:
    local = punch_in.astimezone(IST)
    start = emp["shift_start"]
    end = emp["shift_end"]
    if end <= start and local.strftime("%H:%M") < end:
        local_day = local.date() - timedelta(days=1)
    else:
        local_day = local.date()
    return local_day.isoformat()


def compute_late_minutes(punch_in: datetime, shift_start: str, record_date: str) -> int:
    local_day = parse_date(record_date)
    shift_start_dt = time_on_day(local_day, shift_start)
    elapsed = int((punch_in - shift_start_dt).total_seconds() // 60)
    return elapsed if (punch_in - shift_start_dt).total_seconds() > 600 else 0


def compute_work_hours(punch_in: datetime, punch_out: datetime) -> float:
    seconds = int((punch_out - punch_in).total_seconds())
    return round_half_up(seconds / 3600, 2)


def compute_overtime(punch_out: datetime, shift_end: str, record_date: str, shift_start: str) -> int:
    day = parse_date(record_date)
    end_day = day + timedelta(days=1) if shift_end <= shift_start else day
    shift_end_dt = time_on_day(end_day, shift_end)
    minutes = int((punch_out - shift_end_dt).total_seconds() // 60)
    return minutes if minutes >= 30 else 0


def validate_instant(value: Optional[int]) -> Optional[datetime]:
    if value is None:
        return None
    return epoch_to_dt(value)


def serialize_explain(value: Any) -> Any:
    if isinstance(value, ObjectId):
        return str(value)
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, dict):
        return {k: serialize_explain(v) for k, v in value.items()}
    if isinstance(value, list):
        return [serialize_explain(v) for v in value]
    if isinstance(value, bytes):
        return value.hex()
    return value


@app.on_event("startup")
def create_indexes() -> None:
    # Unique indexes are the concurrency guarantees; the remaining indexes support filtered lists/analytics.
    db.employees.create_index([("emp_code", ASCENDING)], unique=True, name="uq_employee_code")
    db.employees.create_index([("department", ASCENDING), ("joined_on", ASCENDING)], name="ix_employee_department_joined")
    db.employees.create_index([("joined_on", ASCENDING)], name="ix_employee_joined")
    db.attendance_logs.create_index([("emp_code", ASCENDING), ("date", ASCENDING)], unique=True, name="uq_attendance_employee_date")
    db.attendance_logs.create_index([("date", DESCENDING), ("emp_code", ASCENDING)], name="ix_attendance_date_employee")
    db.attendance_logs.create_index([("status", ASCENDING), ("date", DESCENDING), ("emp_code", ASCENDING)], name="ix_attendance_status_date_employee")
    db.attendance_logs.create_index([("date", ASCENDING), ("late_minutes", DESCENDING), ("emp_code", ASCENDING)], name="ix_attendance_date_late_employee")
    db.attendance_logs.create_index([("emp_code", ASCENDING), ("punch_in", DESCENDING)], name="ix_attendance_employee_punchin")


# ------------------------------- Request models -------------------------------
class EmployeeIn(BaseModel):
    model_config = ConfigDict(extra="ignore")
    emp_code: str = Field(pattern=r"^EMP\d{4,6}$")
    name: str = Field(min_length=1, max_length=100)
    email: str = Field(max_length=120, pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
    department: str = Field(min_length=1, max_length=50)
    shift_start: str = Field(default="09:30", pattern=r"^([01]\d|2[0-3]):[0-5]\d$")
    shift_end: str = Field(default="18:30", pattern=r"^([01]\d|2[0-3]):[0-5]\d$")
    joined_on: str

    @field_validator("joined_on")
    @classmethod
    def valid_join_date(cls, v):
        parse_date(v, "joined_on")
        return v

    @model_validator(mode="after")
    def shifts_differ(self):
        if self.shift_start == self.shift_end:
            raise ValueError("shift_start must differ from shift_end")
        return self


class PunchInIn(BaseModel):
    model_config = ConfigDict(extra="ignore", strict=True)
    emp_code: str
    punched_at: Optional[StrictInt] = None
    status: Literal["PRESENT", "WFH", "ON_DUTY"] = "PRESENT"

    @field_validator("punched_at")
    @classmethod
    def valid_timestamp(cls, v):
        if v is not None and not EPOCH_MIN <= v <= EPOCH_MAX:
            raise ValueError("punched_at must be epoch milliseconds")
        return v


class PunchOutIn(BaseModel):
    model_config = ConfigDict(extra="ignore", strict=True)
    emp_code: str
    punched_at: Optional[StrictInt] = None

    @field_validator("punched_at")
    @classmethod
    def valid_timestamp(cls, v):
        if v is not None and not EPOCH_MIN <= v <= EPOCH_MAX:
            raise ValueError("punched_at must be epoch milliseconds")
        return v


class RegularizeIn(BaseModel):
    model_config = ConfigDict(extra="ignore", strict=True)
    status: Optional[Literal["PRESENT", "WFH", "ON_DUTY", "ABSENT", "LEAVE"]] = None
    punch_in: Optional[StrictInt] = None
    punch_out: Optional[StrictInt] = None
    reason: str = Field(min_length=5, max_length=200)
    regularized_by: str = Field(min_length=1, max_length=50)

    @field_validator("status", mode="before")
    @classmethod
    def status_must_not_be_null(cls, value):
        # Omission means "leave status unchanged"; explicit JSON null is invalid.
        if value is None:
            raise ValueError("status must be omitted or a valid status value")
        return value

    @field_validator("punch_in", "punch_out")
    @classmethod
    def valid_timestamp(cls, v):
        if v is not None and not EPOCH_MIN <= v <= EPOCH_MAX:
            raise ValueError("timestamps must be epoch milliseconds")
        return v


# ---------------------------------- Helpers ----------------------------------
def working_days_expr(start_expr: Any, end_expr: Any) -> dict:
    """Mongo expression: weekdays in inclusive BSON-date range."""
    return {"$size": {"$filter": {"input": {"$map": {"input": {"$range": [0, {"$add": [{"$dateDiff": {"startDate": start_expr, "endDate": end_expr, "unit": "day"}}, 1]}]}, "as": "i", "in": {"$dayOfWeek": {"$dateAdd": {"startDate": start_expr, "unit": "day", "amount": "$$i"}}}}}, "as": "dow", "cond": {"$and": [{"$gte": ["$$dow", 2]}, {"$lte": ["$$dow", 6]}]}}}}


def iso_to_date_expr(field: str) -> dict:
    return {"$dateFromString": {"dateString": field, "format": "%Y-%m-%d", "timezone": "UTC"}}


def month_log_match(start: str, end: str, emp_expr: Any = "$$code") -> dict:
    return {"$expr": {"$and": [{"$eq": ["$emp_code", emp_expr]}, {"$gte": ["$date", start]}, {"$lte": ["$date", end]}]}}


def list_attendance_query(emp_code, date_from, date_to, status):
    q = {}
    if emp_code: q["emp_code"] = emp_code
    if date_from or date_to:
        q["date"] = {}
        if date_from: q["date"]["$gte"] = date_from
        if date_to: q["date"]["$lte"] = date_to
    if status: q["status"] = status
    return q


def build_employee_monthly_pipeline(emp_code: str, month: str) -> list:
    start, end = month_bounds(month)
    start_dt = datetime.combine(parse_date(start), time.min, tzinfo=UTC)
    end_dt = datetime.combine(parse_date(end), time.min, tzinfo=UTC)
    return [
        {"$match": {"emp_code": emp_code}},
        {"$lookup": {"from": "attendance_logs", "let": {"code": "$emp_code"}, "pipeline": [
            {"$match": {"$expr": {"$and": [{"$eq": ["$emp_code", "$$code"]}, {"$gte": ["$date", start]}, {"$lte": ["$date", end]}]}}},
            {"$project": {"_id": 0, "date": 1, "status": 1, "half_day": 1, "late_minutes": 1, "overtime_minutes": 1}}
        ], "as": "logs"}},
        {"$set": {"month_start": {"$max": [iso_to_date_expr("$joined_on"), {"$literal": start_dt}]}, "month_end": {"$literal": end_dt}}},
        {"$set": {"working_days": {"$cond": [{"$gt": ["$month_start", "$month_end"]}, 0, working_days_expr("$month_start", "$month_end")]}}},
        {"$unwind": {"path": "$logs", "preserveNullAndEmptyArrays": True}},
        {"$set": {"log_dow": {"$cond": [{"$ifNull": ["$logs.date", False]}, {"$dayOfWeek": iso_to_date_expr("$logs.date")}, 0]}}},
        {"$group": {"_id": {"emp_code": "$emp_code", "month": {"$literal": month}}, "working_days": {"$first": "$working_days"},
            "present_days": {"$sum": {"$cond": [{"$and": [{"$in": ["$logs.status", list(PRESENCE)]}, {"$gte": ["$log_dow", 2]}, {"$lte": ["$log_dow", 6]}]}, {"$cond": [{"$eq": [{"$ifNull": ["$logs.half_day", False]}, True]}, 0.5, 1]}, 0]}},
            "leave_days": {"$sum": {"$cond": [{"$eq": ["$logs.status", "LEAVE"]}, 1, 0]}},
            "late_count": {"$sum": {"$cond": [{"$gt": [{"$ifNull": ["$logs.late_minutes", 0]}, 0]}, 1, 0]}},
            "total_late_minutes": {"$sum": {"$ifNull": ["$logs.late_minutes", 0]}},
            "total_overtime_minutes": {"$sum": {"$ifNull": ["$logs.overtime_minutes", 0]}}}},
        {"$project": {"_id": 0, "emp_code": "$_id.emp_code", "month": "$_id.month", "working_days": 1, "present_days": 1, "leave_days": 1, "late_count": 1, "total_late_minutes": 1, "total_overtime_minutes": 1,
            "attendance_pct": {"$cond": [{"$eq": ["$working_days", 0]}, None, {"$multiply": [{"$divide": ["$present_days", "$working_days"]}, 100]}]}}}
    ]


def build_department_summary_pipeline(month: str, department: Optional[str]) -> list:
    start, end = month_bounds(month)
    match = {"joined_on": {"$lte": end}}
    if department is not None: match["department"] = department
    start_dt = datetime.combine(parse_date(start), time.min, tzinfo=UTC)
    end_dt = datetime.combine(parse_date(end), time.min, tzinfo=UTC)
    return [
        {"$match": match},
        {"$lookup": {"from": "attendance_logs", "let": {"code": "$emp_code"}, "pipeline": [
            {"$match": {"$expr": {"$and": [{"$eq": ["$emp_code", "$$code"]}, {"$gte": ["$date", start]}, {"$lte": ["$date", end]}]}}},
            {"$project": {"_id": 0, "date": 1, "status": 1, "half_day": 1, "work_hours": 1, "late_minutes": 1, "overtime_minutes": 1}}
        ], "as": "logs"}},
        {"$unwind": {"path": "$logs", "preserveNullAndEmptyArrays": True}},
        {"$set": {"dow": {"$cond": [{"$ifNull": ["$logs.date", False]}, {"$dayOfWeek": iso_to_date_expr("$logs.date")}, 0]}}},
        {"$group": {"_id": {"department": "$department", "emp_code": "$emp_code"},
            "logs_present_days": {"$sum": {"$cond": [{"$and": [{"$in": ["$logs.status", list(PRESENCE)]}, {"$gte": ["$dow", 2]}, {"$lte": ["$dow", 6]}]}, {"$cond": [{"$eq": [{"$ifNull": ["$logs.half_day", False]}, True]}, 0.5, 1]}, 0]}},
            "work_hours_sum": {"$sum": {"$cond": [{"$and": [{"$in": ["$logs.status", list(PRESENCE)]}, {"$ne": [{"$ifNull": ["$logs.work_hours", None]}, None]}]}, "$logs.work_hours", 0]}},
            "work_hours_count": {"$sum": {"$cond": [{"$and": [{"$in": ["$logs.status", list(PRESENCE)]}, {"$ne": [{"$ifNull": ["$logs.work_hours", None]}, None]}]}, 1, 0]}},
            "late_count": {"$sum": {"$cond": [{"$gt": [{"$ifNull": ["$logs.late_minutes", 0]}, 0]}, 1, 0]}},
            "total_late_minutes": {"$sum": {"$ifNull": ["$logs.late_minutes", 0]}},
            "leave_count": {"$sum": {"$cond": [{"$eq": ["$logs.status", "LEAVE"]}, 1, 0]}},
            "on_duty_count": {"$sum": {"$cond": [{"$eq": ["$logs.status", "ON_DUTY"]}, 1, 0]}}}},
        {"$group": {"_id": "$_id.department", "headcount": {"$sum": 1}, "present_days": {"$sum": "$logs_present_days"},
            "work_hours_sum": {"$sum": "$work_hours_sum"}, "work_hours_count": {"$sum": "$work_hours_count"}, "late_count": {"$sum": "$late_count"},
            "total_late_minutes": {"$sum": "$total_late_minutes"}, "leave_count": {"$sum": "$leave_count"}, "on_duty_count": {"$sum": "$on_duty_count"}}},
        {"$project": {"_id": 0, "department": "$_id", "headcount": 1, "present_days": 1,
            "avg_work_hours": {"$cond": [{"$eq": ["$work_hours_count", 0]}, None, {"$divide": ["$work_hours_sum", "$work_hours_count"]}]},
            "late_count": 1, "total_late_minutes": 1, "leave_count": 1, "on_duty_count": 1}},
        {"$sort": {"department": 1}}
    ]


def build_leaderboard_pipeline(month: str, limit: int, department: Optional[str]) -> list:
    start, end = month_bounds(month)
    pipeline = [
        {"$match": {"date": {"$gte": start, "$lte": end}, "late_minutes": {"$gt": 0}}},
        {"$group": {"_id": "$emp_code", "total_late_minutes": {"$sum": "$late_minutes"}, "late_count": {"$sum": 1}}},
        {"$match": {"total_late_minutes": {"$gt": 0}}},
        {"$lookup": {"from": "employees", "localField": "_id", "foreignField": "emp_code", "as": "employee"}},
        {"$unwind": "$employee"},
    ]
    if department is not None:
        pipeline.append({"$match": {"employee.department": department}})
    pipeline += [
        {"$setWindowFields": {"sortBy": {"total_late_minutes": -1}, "output": {"rank": {"$rank": {}}}}},
        {"$match": {"rank": {"$lte": limit}}},
        {"$sort": {"total_late_minutes": -1, "_id": 1}},
        {"$project": {"_id": 0, "rank": 1, "emp_code": "$_id", "name": "$employee.name", "department": "$employee.department", "total_late_minutes": 1, "late_count": 1}}
    ]
    return pipeline


def build_trend_pipeline(department: str, start: str, end: str) -> list:
    start_day, end_day = parse_date(start, "from"), parse_date(end, "to")
    days = (end_day - start_day).days + 1
    start_dt = datetime.combine(start_day, time.min, tzinfo=UTC)
    end_dt = datetime.combine(end_day, time.min, tzinfo=UTC)
    return [
        {"$match": {"department": department}},
        {"$set": {"days": {"$map": {"input": {"$range": [0, days]}, "as": "i", "in": {"$dateAdd": {"startDate": {"$literal": start_dt}, "unit": "day", "amount": "$$i"}}}}}},
        {"$unwind": "$days"},
        {"$set": {"day_string": {"$dateToString": {"date": "$days", "format": "%Y-%m-%d", "timezone": "UTC"}}}},
        {"$lookup": {"from": "attendance_logs", "let": {"code": "$emp_code", "day": "$day_string"}, "pipeline": [
            {"$match": {"$expr": {"$and": [{"$eq": ["$emp_code", "$$code"]}, {"$eq": ["$date", "$$day"]}]}}},
            {"$project": {"_id": 0, "status": 1, "late_minutes": 1, "half_day": 1}}
        ], "as": "day_logs"}},
        {"$unwind": {"path": "$day_logs", "preserveNullAndEmptyArrays": True}},
        {"$group": {"_id": "$days", "headcount": {"$sum": {"$cond": [{"$lte": ["$joined_on", "$day_string"]}, 1, 0]}},
            "present_count": {"$sum": {"$cond": [{"$in": ["$day_logs.status", list(PRESENCE)]}, {"$cond": [{"$eq": [{"$ifNull": ["$day_logs.half_day", False]}, True]}, 0.5, 1]}, 0]}},
            "late_count": {"$sum": {"$cond": [{"$gt": [{"$ifNull": ["$day_logs.late_minutes", 0]}, 0]}, 1, 0]}}}},
        {"$densify": {"field": "_id", "range": {"step": 1, "unit": "day", "bounds": [start_dt, end_dt]}}},
        {"$set": {"date": {"$dateToString": {"date": "$_id", "format": "%Y-%m-%d", "timezone": "UTC"}},
            "is_working_day": {"$and": [{"$gte": [{"$dayOfWeek": "$_id"}, 2]}, {"$lte": [{"$dayOfWeek": "$_id"}, 6]}]},
            "headcount": {"$ifNull": ["$headcount", 0]}, "present_count": {"$ifNull": ["$present_count", 0]}, "late_count": {"$ifNull": ["$late_count", 0]}}},
        {"$set": {"attendance_rate": {"$cond": [{"$and": ["$is_working_day", {"$gt": ["$headcount", 0]}]}, {"$divide": ["$present_count", "$headcount"]}, None]}}},
        {"$setWindowFields": {"sortBy": {"_id": 1}, "output": {"moving_avg_7d": {"$avg": "$attendance_rate", "window": {"documents": [-6, 0]}}}}},
        {"$project": {"_id": 0, "date": 1, "is_working_day": 1, "headcount": 1, "present_count": 1, "late_count": 1, "attendance_rate": 1, "moving_avg_7d": 1}},
        {"$sort": {"date": 1}}
    ]


def explain_aggregate(collection: str, pipeline: list) -> dict:
    return db.command({"explain": {"aggregate": collection, "pipeline": pipeline, "cursor": {}}, "verbosity": "executionStats"})


# ----------------------------------- Routes -----------------------------------
@app.get("/health")
def health():
    try:
        db.command("ping")
        return {"status": "ok"}
    except PyMongoError:
        raise HTTPException(503, "MongoDB is unavailable")


@app.post("/employees", status_code=201)
def create_employee(body: EmployeeIn):
    doc = body.model_dump()
    doc["created_at"] = now_utc()
    try:
        db.employees.insert_one(doc)
    except DuplicateKeyError:
        raise HTTPException(409, "emp_code already exists")
    return public_employee(doc)


@app.get("/employees")
def list_employees(department: Optional[str] = None, page: int = Query(1, ge=1), page_size: int = Query(20, ge=1, le=100)):
    q = {"department": department} if department is not None else {}
    total = db.employees.count_documents(q)
    docs = list(db.employees.find(q, {"_id": 0}).sort("emp_code", ASCENDING).skip((page - 1) * page_size).limit(page_size))
    return {"items": [public_employee(d) for d in docs], "total": total, "page": page, "page_size": page_size}


@app.post("/attendance/punch-in", status_code=201)
def punch_in(body: PunchInIn):
    emp = db.employees.find_one({"emp_code": body.emp_code})
    if not emp:
        raise HTTPException(404, "employee not found")
    ts = validate_instant(body.punched_at) or now_utc()
    ts = ts.replace(microsecond=0)
    record_day = attendance_date(ts, emp)
    doc = {"emp_code": body.emp_code, "date": record_day, "status": body.status, "punch_in": ts, "punch_out": None,
           "work_hours": None, "late_minutes": compute_late_minutes(ts, emp["shift_start"], record_day),
           "overtime_minutes": 0, "half_day": False, "history": []}
    try:
        db.attendance_logs.insert_one(doc)
    except DuplicateKeyError:
        raise HTTPException(409, "already punched in for this date")
    return public_attendance(doc)


@app.post("/attendance/punch-out")
def punch_out(body: PunchOutIn):
    emp = db.employees.find_one({"emp_code": body.emp_code})
    if not emp:
        raise HTTPException(404, "employee not found")
    ts = validate_instant(body.punched_at) or now_utc()
    ts = ts.replace(microsecond=0)
    doc = db.attendance_logs.find_one({"emp_code": body.emp_code, "punch_in": {"$lte": ts}}, sort=[("punch_in", DESCENDING)])
    if not doc:
        raise HTTPException(404, "no punch-in found")
    if doc.get("punch_out") is not None:
        raise HTTPException(409, "record already punched out")
    delta = (ts - doc["punch_in"]).total_seconds()
    if delta <= 0 or delta > 24 * 3600:
        raise HTTPException(422, "punch-out must be after punch-in and within 24 hours")
    hours = compute_work_hours(doc["punch_in"], ts)
    overtime = compute_overtime(ts, emp["shift_end"], doc["date"], emp["shift_start"])
    updated = db.attendance_logs.find_one_and_update({"_id": doc["_id"], "punch_out": None},
        {"$set": {"punch_out": ts, "work_hours": hours, "overtime_minutes": overtime, "half_day": hours < 4.50}}, return_document=ReturnDocument.AFTER)
    if updated is None:
        raise HTTPException(409, "record already punched out")
    return public_attendance(updated)


@app.get("/attendance")
def list_attendance(emp_code: Optional[str] = None, date_from: Optional[str] = None, date_to: Optional[str] = None,
                    status: Optional[str] = None, page: int = Query(1, ge=1), page_size: int = Query(20, ge=1, le=100)):
    if date_from: parse_date(date_from, "date_from")
    if date_to: parse_date(date_to, "date_to")
    if date_from and date_to and date_from > date_to:
        raise HTTPException(422, "date_from must not be after date_to")
    if status and status not in ALL_STATUS:
        raise HTTPException(422, "invalid status")
    q = list_attendance_query(emp_code, date_from, date_to, status)
    total = db.attendance_logs.count_documents(q)
    docs = list(db.attendance_logs.find(q, {"_id": 0}).sort([("date", DESCENDING), ("emp_code", ASCENDING)]).skip((page - 1) * page_size).limit(page_size))
    return {"items": [public_attendance(d) for d in docs], "total": total, "page": page, "page_size": page_size}


@app.patch("/attendance/{emp_code}/{date}")
def regularize_attendance(emp_code: str, date: str, body: RegularizeIn):
    parse_date(date)
    emp = db.employees.find_one({"emp_code": emp_code})
    if not emp:
        raise HTTPException(404, "employee not found")
    old = db.attendance_logs.find_one({"emp_code": emp_code, "date": date})
    if not old:
        raise HTTPException(404, "attendance record not found")
    req = body.model_dump(exclude={"reason", "regularized_by"}, exclude_unset=True)
    old_status = old.get("status")
    new_status = req.get("status", old_status)
    old_in, old_out = old.get("punch_in"), old.get("punch_out")
    new_in = epoch_to_dt(req["punch_in"]) if "punch_in" in req and req["punch_in"] is not None else (None if "punch_in" in req else old_in)
    new_out = epoch_to_dt(req["punch_out"]) if "punch_out" in req and req["punch_out"] is not None else (None if "punch_out" in req else old_out)
    if new_status in {"ABSENT", "LEAVE"}:
        if ("punch_in" in req and req["punch_in"] is not None) or ("punch_out" in req and req["punch_out"] is not None):
            raise HTTPException(422, "ABSENT/LEAVE cannot include punch times")
        new_in, new_out = None, None
    elif new_in is None:
        raise HTTPException(422, "presence status requires punch_in")
    if new_in is not None and attendance_date(new_in, emp) != date:
        raise HTTPException(422, "punch_in must belong to the record attendance date")
    if new_out is not None:
        if new_in is None or (new_out - new_in).total_seconds() <= 0 or (new_out - new_in).total_seconds() > 86400:
            raise HTTPException(422, "punch_out must be after punch_in and within 24 hours")
    if new_status in {"ABSENT", "LEAVE"}:
        late, hours, overtime, half = 0, None, 0, False
    else:
        late = compute_late_minutes(new_in, emp["shift_start"], date)
        if new_out is None:
            hours, overtime, half = None, 0, False
        else:
            hours = compute_work_hours(new_in, new_out)
            overtime = compute_overtime(new_out, emp["shift_end"], date, emp["shift_start"])
            half = hours < 4.50
    final_fields = {"status": new_status, "punch_in": new_in, "punch_out": new_out, "work_hours": hours,
                    "late_minutes": late, "overtime_minutes": overtime, "half_day": half}
    changes = {}
    for field, new_val in final_fields.items():
        old_val = old.get(field, {"work_hours": None, "late_minutes": 0, "overtime_minutes": 0, "half_day": False}.get(field))
        if old_val != new_val:
            changes[field] = {"from": old_val, "to": new_val}
    if not changes:
        raise HTTPException(422, "regularization does not change the record")
    history_entry = {"at": now_utc(), "by": body.regularized_by, "reason": body.reason, "changes": changes}
    # Optimistic compare-and-set: concurrent regularizations cannot overwrite each other's history.
    guard = {"_id": old["_id"], "status": old.get("status"), "punch_in": old.get("punch_in"), "punch_out": old.get("punch_out")}
    if "history" in old: guard["history"] = old["history"]
    else: guard["history"] = {"$exists": False}
    update = {"$set": final_fields, "$push": {"history": history_entry}}
    updated = db.attendance_logs.find_one_and_update(guard, update, return_document=ReturnDocument.AFTER)
    if updated is None:
        raise HTTPException(409, "record changed concurrently; retry the correction")
    return public_attendance(updated)


@app.get("/analytics/employees/{emp_code}/monthly")
def employee_monthly(emp_code: str, month: str):
    month_bounds(month)
    if not db.employees.find_one({"emp_code": emp_code}, {"_id": 1}):
        raise HTTPException(404, "employee not found")
    result = list(db.employees.aggregate(build_employee_monthly_pipeline(emp_code, month)))
    if not result:
        raise HTTPException(404, "employee not found")
    doc = result[0]
    doc["present_days"] = round_half_up(doc.get("present_days", 0), 2)
    doc["attendance_pct"] = round_half_up(doc.get("attendance_pct"), 4)
    return doc


@app.get("/analytics/departments/summary")
def department_summary(month: str, department: Optional[str] = None):
    month_bounds(month)
    items = list(db.employees.aggregate(build_department_summary_pipeline(month, department)))
    for item in items:
        item["present_days"] = round_half_up(item.get("present_days", 0), 2)
        item["avg_work_hours"] = round_half_up(item.get("avg_work_hours"), 2)
    return {"month": month, "items": items}


@app.get("/analytics/leaderboard/late")
def late_leaderboard(month: str, limit: int = Query(10, ge=1, le=50), department: Optional[str] = None):
    month_bounds(month)
    items = list(db.attendance_logs.aggregate(build_leaderboard_pipeline(month, limit, department), allowDiskUse=True))
    return {"month": month, "items": items}


@app.get("/analytics/departments/{department}/trend")
def department_trend(department: str, from_: str = Query(..., alias="from"), to: str = Query(...)):
    start_day, end_day = parse_date(from_, "from"), parse_date(to, "to")
    if end_day < start_day:
        raise HTTPException(422, "to must be on or after from")
    if (end_day - start_day).days + 1 > 92:
        raise HTTPException(422, "date range cannot exceed 92 days")
    if not db.employees.find_one({"department": department}, {"_id": 1}):
        raise HTTPException(404, "department not found")
    items = list(db.employees.aggregate(build_trend_pipeline(department, from_, to), allowDiskUse=True))
    for item in items:
        item["attendance_rate"] = round_half_up(item.get("attendance_rate"), 4)
        item["moving_avg_7d"] = round_half_up(item.get("moving_avg_7d"), 4)
        item["present_count"] = round_half_up(item.get("present_count", 0), 2)
    # If all employees joined after `from`, pipeline filters their earlier dates; densify fills them with zero headcount.
    return {"department": department, "items": items}


@app.get("/admin/explain/{endpoint}")
def explain_endpoint(endpoint: Literal["attendance_list", "employee_monthly", "department_summary", "late_leaderboard", "department_trend"],
                     emp_code: Optional[str] = None, month: Optional[str] = None, department: Optional[str] = None,
                     limit: int = Query(10, ge=1, le=50), date_from: Optional[str] = None, date_to: Optional[str] = None,
                     status: Optional[str] = None, page: int = Query(1, ge=1), page_size: int = Query(20, ge=1, le=100),
                     from_: Optional[str] = Query(None, alias="from"), to: Optional[str] = None):
    if endpoint == "attendance_list":
        if date_from: parse_date(date_from, "date_from")
        if date_to: parse_date(date_to, "date_to")
        if date_from and date_to and date_from > date_to: raise HTTPException(422, "date_from must not be after date_to")
        q = list_attendance_query(emp_code, date_from, date_to, status)
        command = {"find": "attendance_logs", "filter": q, "sort": {"date": -1, "emp_code": 1}, "skip": (page - 1) * page_size, "limit": page_size}
        raw = db.command({"explain": command, "verbosity": "executionStats"})
        return {"endpoint": endpoint, "collection": "attendance_logs", "explain": serialize_explain(raw)}
    if not month and endpoint in {"employee_monthly", "department_summary", "late_leaderboard"}:
        raise HTTPException(422, "month is required")
    if month: month_bounds(month)
    if endpoint == "employee_monthly":
        if not emp_code: raise HTTPException(422, "emp_code is required")
        raw = explain_aggregate("employees", build_employee_monthly_pipeline(emp_code, month))
        return {"endpoint": endpoint, "collection": "employees", "explain": serialize_explain(raw)}
    if endpoint == "department_summary":
        raw = explain_aggregate("employees", build_department_summary_pipeline(month, department))
        return {"endpoint": endpoint, "collection": "employees", "explain": serialize_explain(raw)}
    if endpoint == "late_leaderboard":
        raw = explain_aggregate("attendance_logs", build_leaderboard_pipeline(month, limit, department))
        return {"endpoint": endpoint, "collection": "attendance_logs", "explain": serialize_explain(raw)}
    if endpoint == "department_trend":
        if not department or not from_ or not to: raise HTTPException(422, "department, from and to are required")
        start_day, end_day = parse_date(from_, "from"), parse_date(to, "to")
        if end_day < start_day or (end_day - start_day).days + 1 > 92: raise HTTPException(422, "invalid trend date range")
        raw = explain_aggregate("employees", build_trend_pipeline(department, from_, to))
        return {"endpoint": endpoint, "collection": "employees", "explain": serialize_explain(raw)}
    raise HTTPException(422, "unsupported endpoint")
