library(shiny)
#### this is the file uploaded onto https://nrp-snrna-seq.shinyapps.io/NRP-snRNA-seq_app/

# Infra URLs are kept OUT of source control. They load from a gitignored .Renviron
# (bundled on deploy) or from environment variables set in the shinyapps.io dashboard.
# Copy .Renviron.example -> .Renviron and fill in the real values. See README.
if (file.exists(".Renviron")) readRenviron(".Renviron")

API_BASE <- Sys.getenv("NRP_API_BASE")
APP_URL  <- Sys.getenv("NRP_APP_URL")

if (!nzchar(API_BASE) || !nzchar(APP_URL)) {
  stop("Missing NRP_API_BASE / NRP_APP_URL. Copy .Renviron.example to .Renviron and fill them in.")
}

ui <- fluidPage(
  title = "NRP snRNA-seq Explorer",
  tags$head(
    tags$style(HTML("
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body {
        background: #f5f5f3;
        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
        display: flex; align-items: center; justify-content: center; min-height: 100vh;
      }
      .card {
        background: #ffffff; border: 1px solid #e8e8e6; border-radius: 14px;
        padding: 2.5rem 2rem; width: 380px; text-align: center; margin: 2rem auto;
      }
      .icon-wrap {
        width: 52px; height: 52px; border-radius: 50%;
        background: #f5f5f3; border: 1px solid #e8e8e6;
        display: flex; align-items: center; justify-content: center; margin: 0 auto 1.25rem;
      }
      .title { font-size: 18px; font-weight: 500; color: #111; margin-bottom: 6px; }
      .subtitle { font-size: 13px; color: #888; margin-bottom: 1.75rem; }
      .bar-track { background: #efefed; border-radius: 99px; height: 6px; overflow: hidden; margin-bottom: 10px; }
      .bar-fill {
        height: 100%; border-radius: 99px; background: #555;
        transition: width 0.5s ease; width: 5%;
      }
      .bar-fill.pulsing {
        animation: shimmer 1.6s ease-in-out infinite;
        background: linear-gradient(90deg, #ccc 25%, #555 50%, #ccc 75%);
        background-size: 200% 100%;
      }
      @keyframes shimmer { 0% { background-position: 200% 0; } 100% { background-position: -200% 0; } }
      .status-text { font-size: 12px; color: #888; margin-bottom: 1.5rem; }
      .ready-row { display: none; align-items: center; justify-content: center; gap: 8px; margin-bottom: 12px; }
      .ready-dot { width: 8px; height: 8px; border-radius: 50%; background: #22c55e; }
      .ready-label { font-size: 13px; font-weight: 500; color: #111; }
      .open-btn {
        display: none; background: #111; color: #fff; border-radius: 8px;
        padding: 11px 20px; font-size: 14px; font-weight: 500; text-decoration: none;
        margin-top: 12px; width: 100%; border: none; cursor: pointer;
      }
      .open-btn:hover { background: #333; }
      .error-row { display: none; flex-direction: column; align-items: center; gap: 10px; }
      .error-text { font-size: 13px; color: #dc2626; }
      .retry-btn {
        background: transparent; border: 1px solid #ccc; border-radius: 8px;
        padding: 8px 18px; font-size: 13px; cursor: pointer; color: #111;
      }
      .retry-btn:hover { background: #f5f5f3; }
      .footer-note { border-top: 1px solid #efefed; padding-top: 1rem; margin-top: 1rem; font-size: 11px; color: #aaa; }
    ")),
    tags$script(HTML(paste0("
      var API_BASE = '", API_BASE, "';
      var APP_URL  = '", APP_URL, "';
      var pollTimer = null;
      var pollCount = 0;
      var MAX_POLLS = 45;

      var steps = [
        { pct: 10, text: 'Sending wake signal to AWS EC2...' },
        { pct: 18, text: 'Instance is booting...' },
        { pct: 26, text: 'Instance is booting...' },
        { pct: 35, text: 'Loading analysis environment...' },
        { pct: 43, text: 'Loading analysis environment...' },
        { pct: 51, text: 'Loading analysis environment...' },
        { pct: 60, text: 'Loading analysis environment...' },
        { pct: 68, text: 'Checking server health...' },
        { pct: 75, text: 'Checking server health...' },
        { pct: 82, text: 'Almost ready...' },
        { pct: 88, text: 'Almost ready...' },
        { pct: 93, text: 'Almost ready...' },
        { pct: 96, text: 'Almost ready...' }
      ];

      function setBar(pct, text) {
        var fill = document.getElementById('bar-fill');
        var stxt = document.getElementById('status-text');
        if (fill) fill.style.width = pct + '%';
        if (stxt) stxt.innerText = text;
      }

      function showReady() {
        document.getElementById('bar-track').style.display = 'none';
        document.getElementById('status-text').style.display = 'none';
        document.getElementById('ready-row').style.display = 'flex';
        document.getElementById('open-btn').style.display = 'block';
        if (pollTimer) clearInterval(pollTimer);
        setTimeout(function() { window.open(APP_URL, '_blank'); }, 800);
      }

      function showError() {
        document.getElementById('bar-track').style.display = 'none';
        document.getElementById('status-text').style.display = 'none';
        document.getElementById('error-row').style.display = 'flex';
        if (pollTimer) clearInterval(pollTimer);
      }

      function checkStatus() {
        fetch(API_BASE + '/status')
          .then(function(r) {
            if (r.status === 200) {
              showReady();
            } else {
              pollCount++;
              var idx = Math.min(pollCount - 1, steps.length - 1);
              setBar(steps[idx].pct, steps[idx].text);
              if (pollCount >= MAX_POLLS) showError();
            }
          })
          .catch(function() {
            pollCount++;
            var idx = Math.min(pollCount - 1, steps.length - 1);
            setBar(steps[idx].pct, steps[idx].text);
            if (pollCount >= MAX_POLLS) showError();
          });
      }

      function startPolling() {
        if (pollTimer) clearInterval(pollTimer);
        pollCount = 0;
        document.getElementById('bar-track').style.display = 'block';
        document.getElementById('status-text').style.display = 'block';
        document.getElementById('ready-row').style.display = 'none';
        document.getElementById('open-btn').style.display = 'none';
        document.getElementById('error-row').style.display = 'none';
        var fill = document.getElementById('bar-fill');
        if (fill) { fill.classList.add('pulsing'); fill.style.width = '5%'; }

        fetch(API_BASE + '/status')
          .then(function(r) {
            if (r.status === 200) {
              showReady();
            } else {
              fetch(API_BASE + '/start-ec2', { method: 'POST' }).catch(function(){});
              setBar(steps[0].pct, steps[0].text);
              pollTimer = setInterval(checkStatus, 5000);
            }
          })
          .catch(function() {
            fetch(API_BASE + '/start-ec2', { method: 'POST' }).catch(function(){});
            setBar(steps[0].pct, steps[0].text);
            pollTimer = setInterval(checkStatus, 5000);
          });
      }

      window.addEventListener('load', function() { startPolling(); });
      window.retryStart = function() {
        fetch(API_BASE + '/start-ec2', { method: 'POST' }).catch(function(){});
        startPolling();
      };
    ")))
  ),
  
  div(class = "card",
      div(class = "icon-wrap",
          tags$svg(width = "22", height = "22", viewBox = "0 0 24 24", fill = "none",
                   stroke = "#888", `stroke-width` = "1.5",
                   tags$path(d = "M9 3H5a2 2 0 00-2 2v4m6-6h10a2 2 0 012 2v4M9 3v18m0 0h10a2 2 0 002-2V9M9 21H5a2 2 0 01-2-2V9m0 0h18")
          )
      ),
      div(class = "title", "NRP snRNA-seq Explorer"),
      div(class = "subtitle", "contact:tyron@wustl.edu"),
      
      div(id = "bar-track", class = "bar-track",
          div(id = "bar-fill", class = "bar-fill pulsing")
      ),
      div(id = "status-text", class = "status-text", "Connecting..."),
      
      div(id = "ready-row", class = "ready-row",
          div(class = "ready-dot"),
          div(class = "ready-label", "Server is ready")
      ),
      tags$button(id = "open-btn", class = "open-btn",
                  onclick = paste0("window.open('", APP_URL, "', '_blank')"),
                  "Open app \u2192"),
      
      div(id = "error-row", class = "error-row",
          div(class = "error-text", "Failed to start server."),
          tags$button(class = "retry-btn", onclick = "retryStart()", "Try again")
      ),
      
      div(class = "footer-note", "Usually takes 2\u20133 minutes on first start")
  )
)

server <- function(input, output, session) {}

shinyApp(ui, server)
