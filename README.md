# NRP snRNA-seq Explorer

An interactive web app for exploring single-nucleus RNA-seq (snRNA-seq) data from
iPSC-derived motoneuron (iMN) differentiation. A user pastes in a list of genes and the
app shows, on a UMAP, **how active that gene program is** across cells and ** quantification of active cells ** — with statistics broken down by timepoint and cluster.

- **Contact:** tyron@wustl.edu
- **Public URL:** https://nrp-snrna-seq.shinyapps.io/NRP-snRNA-seq_app/

---

## Design

The app is built around one main idea: **the heavy compute server is expensive, so keep it
off until someone actually needs it.** That single constraint explains every moving part.

![Architecture & workflow: Shiny frontend → FastAPI backend → R (Seurat + AUCell) on AWS, with API Gateway/Lambda wake-up and CloudWatch idle shutdown](docs/architecture.png)

### The wake-on-demand architecture

```mermaid
flowchart TD
    visitor([User])

    subgraph free["Frontend · free, always on"]
        wakeup["Shiny App<br/>wakeup_page.R + app.R<br/>(shinyapps.io)"]
    end

    subgraph control["AWS Control Plane · serverless"]
        apigw["API Gateway<br/>(HTTP API)"]
        startL["Lambda<br/>(start-ec2)"]
        ec2start["EC2<br/>(StartInstances)"]
    end

    subgraph compute["AWS Compute Plane · EC2, on-demand"]
        dl["download-rds.service<br/>oneshot at boot"]
        fastapi["FastAPI (Uvicorn)<br/>systemd auto-start<br/>/status · /run-analysis"]
        analysis["analysis.R<br/>Seurat + AUCell"]
        localrds[("Local FS<br/>seurat_object.rds<br/>(copy, deleted on stop)")]
    end

    subgraph shutdown["Shutdown triggers"]
        cw["CloudWatch alarm<br/>idle 15 min"]
        eventbridge["EventBridge rule<br/>every 3 hours"]
        stopL["Lambda (stop-ec2)<br/>1· delete local .rds via SSM<br/>2· stop instance"]
    end

    s3[("Amazon S3<br/>private bucket<br/>seurat_object.rds")]

    visitor -->|"1 · open app"| wakeup
    wakeup -->|"2 · POST /start-ec2"| apigw --> startL -->|"StartInstances()"| ec2start --> dl
    s3 -->|"download .rds on boot"| dl --> localrds
    dl -->|"then start"| fastapi
    wakeup -.->|"3 · poll GET /status"| apigw
    wakeup -->|"4 · POST /run-analysis"| fastapi --> analysis --> localrds
    fastapi -.->|"5 · results (JSON)"| wakeup
    fastapi -->|"publish ApiActivity metric"| cw
    cw -->|"alarm"| stopL
    eventbridge -->|"guaranteed shutdown"| stopL
    stopL -->|"stop"| compute
```

**Why two front-ends?**
- `frontend/wakeup_page.R` is a tiny page hosted **free** on shinyapps.io. Its only job is to
  wake the EC2 box (via API Gateway) and then redirect the visitor to the real app. It is the
  public entry point.
- `frontend/app.R` is the **real** app (all the plots and UI). It only runs on the EC2 box, served
  by shiny-server, and talks to the backend at `localhost:8000`.

Keeping the public page separate means the expensive EC2 instance can stay **stopped (and unbilled)**
whenever nobody is using it. The box is shut down **two ways**, both via a `stop-ec2` Lambda:
1. **Idle alarm** — `main.py` publishes an `ApiActivity` metric; a CloudWatch alarm fires after
   ~15 minutes of no activity.
2. **Guaranteed shutdown** — an EventBridge scheduled rule triggers the same Lambda every 3 hours,
   as a backstop in case the idle alarm is missed.

The `stop-ec2` Lambda first **deletes the local `.rds`** on the instance (via SSM Run Command),
then stops it.

**Data lifecycle:** the Seurat `.rds` lives permanently in a private S3 bucket. On **start**, the
`download-rds` systemd service pulls it to the instance's local disk (before FastAPI comes up); on
**stop**, the `stop-ec2` Lambda deletes that local copy. So the data only exists on EC2 while the
instance is actually running.

**Why a separate Python backend instead of doing the analysis in Shiny?**
The analysis needs Seurat + AUCell on a large `.rds` object. `backend/main.py` (FastAPI) runs each
request as an **async background job**: it returns a `job_id` immediately, runs `analysis.R` in a
subprocess, and the front-end **polls** `/result/{job_id}` every 4 seconds. This keeps the UI
responsive and lets the slow R computation run without blocking Shiny.

### What the app computes

| Tab | Question it answers | Method |
|-----|---------------------|--------|
| **Gene Activity Score** | "How strongly is this gene program expressed in each cell?" | Seurat `AddModuleScore` → UMAP heatmap + per-group violin plot |
| **Find Active Cells** | "Which cells have this program turned **on** (yes/no)?" | `AUCell` enrichment + adjustable sensitivity threshold → UMAPs + significance bar charts |

A preset **Motoneuron gene list (Yadav et al.)** is built in for one-click testing.

---

## Repo layout

```
.
├── frontend/
│   ├── wakeup_page.R     Public landing page (shinyapps.io). Wakes EC2, polls /status, redirects.
│   ├── app.R             The real Shiny app (runs on EC2 via shiny-server). All plots & UI.
│   └── .Renviron.example Template for the infra URLs the wake-up page needs (copy to .Renviron).
│
└── backend/              Everything that runs on the EC2 instance
    ├── main.py           FastAPI server. Endpoints: /status, /run-analysis, /result/{job_id}.
    ├── analysis.R        The computation: Seurat AddModuleScore + AUCell. Called by main.py.
    ├── download_rds.py   Pulls the Seurat .rds from S3. Run at boot by download-rds.service.
    ├── requirements.txt  Python dependencies for the backend.
    └── system_services/  systemd units installed on the EC2 box (boot order: download → api → shiny):
        ├── download-rds.service  oneshot — downloads the .rds at boot, before FastAPI starts.
        ├── fastapi.service       runs the FastAPI backend (uvicorn), restarts on crash.
        └── shiny-server.service  runs shiny-server, which serves frontend/app.R.
```

> **Not in this repo (but required to run in production):** the API Gateway + `start-ec2`/`stop-ec2`
> Lambdas, the SSM Run Command document (deletes the local `.rds` on stop), the CloudWatch idle alarm,
> the EventBridge 3-hour shutdown rule, the `backend/.env` secrets, and the `.rds` data file (S3).

---

## Runtime workflow (what happens on a visit)

1. A visitor opens the shinyapps.io page → `wakeup_page.R` loads.
2. Its JavaScript calls `POST {API_BASE}/start-ec2`, which triggers the `start-ec2` Lambda → starts the EC2 box.
3. On boot, the `download-rds` systemd service runs `download_rds.py` to copy the `.rds` from S3 to local disk (before FastAPI starts).
4. The page polls `GET {API_BASE}/status` every 5s, showing a progress bar ("Instance is booting…").
5. Once `/status` returns ready, the page opens `APP_URL` → the real `app.R` on EC2.
6. In `app.R`, the user enters genes and clicks **Compute Score** / **Find Active Cells**.
7. `app.R` calls `POST localhost:8000/run-analysis` → gets a `job_id`, then polls `GET /result/{job_id}` every 4s.
8. `main.py` runs `analysis.R` in the background; when done, the JSON result comes back and the plots render.
9. After ~15 min idle (or every 3 hours regardless), the `stop-ec2` Lambda deletes the local `.rds` and stops the box.

---

## Configuration

### Front-end infra URLs (kept out of git)
`wakeup_page.R` reads two values from the environment so the real URLs are **never committed**:

| Variable | Meaning |
|----------|---------|
| `NRP_API_BASE` | API Gateway base URL (the `/start-ec2` + `/status` wake-up endpoints) |
| `NRP_APP_URL`  | Public address of the running app on EC2 (e.g. `http://<ip>:3838/nrp/`) |

Set them up by copying the template:
```bash
cp frontend/.Renviron.example frontend/.Renviron   # then fill in the real values
```
`.Renviron` is gitignored (so it stays out of source control) but is still bundled to shinyapps.io
on deploy, which is what makes the app work. Alternatively, set the two variables in the
shinyapps.io dashboard instead of using a file.

> ⚠️ These URLs are sent to the visitor's browser at runtime (the page has to call them), so they
> are visible via View-Source / Network tab. Keeping them out of git protects the *repo*, not the
> deployed page. To stop strangers from actually starting your EC2 box, lock down API Gateway with
> an API key + throttling (AWS-side).

### Backend environment (`backend/.env` on the EC2 box)
`main.py` reads these and refuses to start if any are missing:

```dotenv
AWS_REGION=us-east-2
S3_BUCKET=nrp-snrna-seq
S3_KEY=iMN/all_WT_iMN_no_harmony_050826.rds
LOCAL_RDS=/home/ec2-user/backend/all_WT_iMN_no_harmony_050826.rds
R_SCRIPT=/home/ec2-user/backend/analysis.R
CW_NAMESPACE=NRP/ShinyApp
```

---

## Deploy workflow (production)

**A. EC2 compute box**
1. Launch EC2 (Amazon Linux, user `ec2-user`) with an IAM role allowing `s3:GetObject` on the data
   bucket and `cloudwatch:PutMetricData`.
2. Install R + shiny-server, Python 3.10+, and the package deps (`requirements.txt`; Seurat/AUCell for R).
3. Copy `backend/` to `/home/ec2-user/backend/` and create `backend/.env` (see above).
4. Install the systemd units so the box self-configures on every boot:
   ```bash
   sudo cp backend/system_services/*.service /etc/systemd/system/
   sudo systemctl daemon-reload
   # download-rds runs first (oneshot), then FastAPI, then shiny-server
   sudo systemctl enable --now download-rds fastapi shiny-server
   ```
   On boot the chain is: `download-rds.service` pulls the `.rds` from S3 → `fastapi.service`
   starts the backend → `shiny-server.service` serves the app.
5. Put `frontend/app.R` where shiny-server serves it (e.g. `/srv/shiny-server/nrp/app.R`) so it is
   reachable at `http://<EC2-IP>:3838/nrp/`.

**B. Wake-up / auto-stop infra** (currently configured only in the AWS console — see note above)
- API Gateway + `start-ec2` Lambda (`ec2:StartInstances`) and the `GET /status` health route.
- `stop-ec2` Lambda that deletes the local `.rds` (via an SSM Run Command) and stops the instance.
  (The start-side download is handled on the box by `download-rds.service`, not SSM.)
- CloudWatch alarm on `NRP/ShinyApp → ApiActivity` (idle ~15 min) → `stop-ec2`.
- EventBridge scheduled rule (every 3 hours) → `stop-ec2`, as a guaranteed-shutdown backstop.

**C. Public landing page**
- Set `NRP_API_BASE` and `NRP_APP_URL`, then publish `frontend/wakeup_page.R` to shinyapps.io.

---

## Backend API reference

| Method | Path | Purpose |
|--------|------|---------|
| `GET`  | `/status` | `ready` if `analysis.R` exists and shiny-server is active, else `503 starting` |
| `POST` | `/run-analysis` | Body `{mode, genes, name}`, `mode` ∈ `"score"`/`"auc"`. Returns `{job_id}` |
| `GET`  | `/result/{job_id}` | `{"status":"running"}`, the result JSON when done, or `500` with error detail |

Jobs run asynchronously in a background thread; the front-end polls `/result/{job_id}` every 4s.
