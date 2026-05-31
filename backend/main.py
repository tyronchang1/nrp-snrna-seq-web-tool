from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from dotenv import load_dotenv
import boto3
import json
import os
import subprocess
import uuid
import threading

load_dotenv("/home/ec2-user/backend/.env")

app = FastAPI()

# ---- ENV ----
def getenv_required(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Missing environment variable: {name}")
    return value

AWS_REGION   = getenv_required("AWS_REGION")
S3_BUCKET    = getenv_required("S3_BUCKET")
S3_KEY       = getenv_required("S3_KEY")
LOCAL_RDS    = getenv_required("LOCAL_RDS")
R_SCRIPT     = getenv_required("R_SCRIPT")
CW_NAMESPACE = getenv_required("CW_NAMESPACE")

# ---- AWS CLIENTS ----
s3         = boto3.client("s3", region_name=AWS_REGION)
cloudwatch = boto3.client("cloudwatch", region_name=AWS_REGION)

# ---- IN-MEMORY JOB STORE ----
# { job_id: { "status": "running"|"done"|"error", "result": {...}, "detail": "..." } }
jobs: dict = {}
jobs_lock = threading.Lock()

# ---- RDS DOWNLOAD LOCK ----
# Prevents multiple simultaneous S3 downloads of the same file
rds_lock = threading.Lock()

# ---- REQUEST MODEL ----
class AnalysisRequest(BaseModel):
    mode: str
    genes: str
    name: str

# ---- ENSURE RDS ----
def ensure_rds():
    if not os.path.exists(LOCAL_RDS):
        with rds_lock:
            # double-check after acquiring lock in case another thread downloaded it
            if not os.path.exists(LOCAL_RDS):
                os.makedirs(os.path.dirname(LOCAL_RDS), exist_ok=True)
                print("Downloading RDS from S3...")
                s3.download_file(S3_BUCKET, S3_KEY, LOCAL_RDS)
                print("Download complete.")

# ---- BACKGROUND WORKER ----
def run_job(job_id: str, mode: str, genes: str, name: str):
    payload_path = f"/tmp/{job_id}_input.json"
    output_path  = f"/tmp/{job_id}_output.json"

    try:
        ensure_rds()

        try:
            cloudwatch.put_metric_data(
                Namespace=CW_NAMESPACE,
                MetricData=[{"MetricName": "ApiActivity", "Value": 1, "Unit": "Count"}]
            )
        except Exception:
            pass  # don't fail the job if CloudWatch is unreachable

        payload = {"mode": mode, "genes": genes, "name": name}
        with open(payload_path, "w") as f:
            json.dump(payload, f)

        result = subprocess.run(
            ["Rscript", R_SCRIPT, payload_path, output_path, LOCAL_RDS],
            capture_output=True,
            text=True,
            timeout=600
        )

        if result.returncode != 0:
            err = result.stderr.strip() or result.stdout.strip() or "analysis.R failed"
            with jobs_lock:
                jobs[job_id] = {"status": "error", "detail": err}
            return

        if not os.path.exists(output_path):
            with jobs_lock:
                jobs[job_id] = {"status": "error", "detail": "Output JSON not created"}
            return

        with open(output_path, "r") as f:
            data = json.load(f)

        with jobs_lock:
            jobs[job_id] = {"status": "done", "result": data}

    except subprocess.TimeoutExpired:
        with jobs_lock:
            jobs[job_id] = {"status": "error", "detail": "Analysis timed out (10 min limit)"}

    except Exception as e:
        with jobs_lock:
            jobs[job_id] = {"status": "error", "detail": str(e)}

    finally:
        for path in [payload_path, output_path]:
            if os.path.exists(path):
                os.remove(path)

# ---- STATUS ----
@app.get("/status")
def status():
    if not os.path.exists(R_SCRIPT):
        return JSONResponse(status_code=503, content={"status": "starting"})
    shiny = subprocess.run(["systemctl", "is-active", "shiny-server"], capture_output=True, text=True)
    if shiny.stdout.strip() != "active":
        return JSONResponse(status_code=503, content={"status": "starting"})
    return {"status": "ready"}

# ---- SUBMIT JOB ----
@app.post("/run-analysis")
def run_analysis(req: AnalysisRequest):
    if req.mode not in ["score", "auc"]:
        raise HTTPException(status_code=400, detail="mode must be 'score' or 'auc'")

    job_id = str(uuid.uuid4())

    with jobs_lock:
        jobs[job_id] = {"status": "running"}

    t = threading.Thread(target=run_job, args=(job_id, req.mode, req.genes, req.name), daemon=True)
    t.start()

    return {"job_id": job_id}

# ---- POLL RESULT ----
@app.get("/result/{job_id}")
def get_result(job_id: str):
    with jobs_lock:
        job = jobs.get(job_id)

    if job is None:
        raise HTTPException(status_code=404, detail="Job not found")

    if job["status"] == "running":
        return {"status": "running"}

    if job["status"] == "error":
        with jobs_lock:
            jobs.pop(job_id, None)
        raise HTTPException(status_code=500, detail=job["detail"])

    # done — return result and clean up
    result = job["result"]
    with jobs_lock:
        jobs.pop(job_id, None)

    return result
