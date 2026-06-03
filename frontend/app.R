library(shiny)
library(bslib)
library(ggplot2)
library(viridis)
library(dplyr)
library(AUCell)
library(httr)
library(jsonlite)

API_BASE <- "http://localhost:8000"

DEFAULT_REDUCTION <- "umap.pca"
CLUSTER_COL       <- "cluster_id"

group_choice_cols <- c("cell_subtypes", "group", "cluster_id")
timepoint_cols    <- c("group", "cell_subtypes")

preset_gene_lists <- list(
  "Motoneuron (Yadav et al)" = c(
    "TMSB4X", "TUBA1B", "TUBA1A", "TUBB4B", "TUBB2A", "TUBA4A",
    "ACTG1", "ACTB",
    "DYNC1H1", "KIF21A", "KLC1", "MAP1B",
    "HSP90AB1", "HSP90AA1", "HSPA8", "HSPB1",
    "YWHAQ", "YWHAH",
    "UBB", "UCHL1",
    "GAPDH", "PKM",
    "ATP1B1", "MT1X", "UTS2", "PRUNE2",
    "LGALS1", "MCAM", "S100A10", "AHNAK2", "ANXA2",
    "CALM1", "S100B", "PVALB",
    "CLU", "SPARCL1",
    "ACLY", "SLC5A7",
    "SPP1", "SOD1",
    "NEFL", "NEFM", "NEFH",
    "STMN2", "PRPH",
    "PLP1", "SNCG",
    "RTN1", "RTN3", "RTN4", "TMSB10"
  )
)

motoneuron_colors <- c("Motoneuron" = "#E41A1C", "Other" = "gray75")

col_labels <- c(
  "group"         = "Timepoint (iPSC / Day7 / Day15)",
  "cluster_id"    = "Cluster ID",
  "cell_subtypes" = "Cell Identity (Motoneuron / Other)"
)

label_cols <- function(cols) {
  setNames(cols, ifelse(cols %in% names(col_labels), col_labels[cols], cols))
}

theme_app <- function() {
  theme_classic(base_size = 12) %+replace%
    theme(
      plot.title      = element_text(face = "bold", hjust = 0.5, size = 14),
      axis.title      = element_text(size = 12),
      axis.text       = element_text(size = 11, color = "black"),
      legend.title    = element_text(size = 11, face = "bold"),
      legend.text     = element_text(size = 11),
      legend.key.size = unit(1.0, "lines")
    )
}

parse_genes <- function(x) {
  if (is.null(x) || !nzchar(x)) return(character(0))
  genes <- unlist(strsplit(x, "[,\\s]+"))
  trimws(genes[nzchar(trimws(genes))]) |> unique()
}

safe_df <- function(x) {
  as.data.frame(x, stringsAsFactors = FALSE, check.names = FALSE)
}

# ----------------------------
# UI
# ----------------------------
ui <- page_sidebar(
  title    = NULL,
  fillable = FALSE,

  sidebar = sidebar(
    width = 200,
    open  = "open",
    tags$div(
      style = "padding: 6px 0;",
      actionButton("nav_howto", "How to Use",          width = "100%", class = "nav-btn"),
      actionButton("nav_score", "Gene Activity Score", width = "100%", class = "nav-btn"),
      actionButton("nav_auc",   "Find Active Cells",   width = "100%", class = "nav-btn")
    )
  ),

  tags$head(tags$style(HTML("
    .navbar-brand {
      position: absolute !important; left: 50% !important;
      transform: translateX(-50%) !important;
      font-size: 18px !important; font-weight: 700 !important; color: #111 !important;
    }
    .navbar { background-color: #ffffff !important; border-bottom: 1px solid #ececec !important; position: relative !important; }
    .nav-btn {
      display: block !important; width: 100% !important; text-align: left !important;
      background: transparent !important; border: none !important; border-radius: 6px !important;
      padding: 9px 12px !important; font-size: 14px !important; font-weight: 600 !important;
      color: #444 !important; margin-bottom: 4px !important; box-shadow: none !important;
      transition: background 0.12s, color 0.12s;
    }
    .nav-btn:hover { background: #f0f0f0 !important; color: #111 !important; }
    .nav-btn-active { background: #2b2b2b !important; color: #fff !important; }
    body { padding-top: 10px; background-color: #fafafa; }
    .shiny-notification-message {
      background-color: #d4edda !important; border-left: 4px solid #28a745 !important;
      color: #155724 !important; font-weight: 600;
    }
    .shiny-notification-error { border-left: 4px solid #dc3545 !important; }
    .section-header {
      font-size: 16px; font-weight: 700; color: #222;
      margin-top: 18px; margin-bottom: 6px;
      border-bottom: 1px solid #ddd; padding-bottom: 4px; text-align: center;
    }
    .help-hero { padding: 28px 0 18px 0; text-align: center; margin-bottom: 20px; border-bottom: 1px solid #e0e0e0; }
    .help-hero h2 { font-size: 22px; font-weight: 700; color: #222; margin-bottom: 6px; }
    .help-hero p { font-size: 14px; color: #666; margin: 0; }
    .workflow-banner { background: #f9f9f9; border-left: 3px solid #aaa; padding: 12px 18px; margin-bottom: 22px; font-size: 14px; line-height: 1.7; }
    .help-cards-row { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin-bottom: 22px; }
    .help-card { background: #ffffff; border: 1px solid #e0e0e0; border-radius: 6px; padding: 22px 24px; }
    .help-card-title { font-size: 15px; font-weight: 700; color: #222; margin: 0 0 3px 0; }
    .help-step { display: flex; align-items: flex-start; margin-bottom: 11px; gap: 10px; }
    .step-num { min-width: 22px; height: 22px; border-radius: 50%; background: #555; color: white; font-size: 11px; font-weight: 700; display: flex; align-items: center; justify-content: center; flex-shrink: 0; margin-top: 2px; }
    .step-body { font-size: 13px; line-height: 1.6; color: #444; }
    .tips-card { background: #f9f9f9; border: 1px solid #e0e0e0; border-radius: 6px; padding: 16px 22px; margin-bottom: 40px; font-size: 14px; line-height: 1.8; }
    .tips-card ul { margin: 8px 0 0 0; padding-left: 18px; }
    .tips-card li { margin-bottom: 4px; }
    .progress-wrap { margin-top: 8px; margin-bottom: 2px; display: none; }
    .progress-wrap.active { display: block; }
    .progress-bar-track { width: 100%; height: 6px; background: #e0e0e0; border-radius: 4px; overflow: hidden; }
    .progress-bar-fill { height: 100%; width: 0%; background: #28a745; border-radius: 4px; transition: width 0.4s ease; }
    .progress-bar-fill.pulsing {
      animation: pulse-bar 1.6s ease-in-out infinite;
      width: 100% !important;
      background: linear-gradient(90deg, #e0e0e0 25%, #28a745 50%, #e0e0e0 75%);
      background-size: 200% 100%;
    }
    @keyframes pulse-bar { 0% { background-position: 200% 0; } 100% { background-position: -200% 0; } }
    .progress-label { font-size: 11px; color: #666; margin-top: 3px; text-align: center; }
  "))),

  tags$script(HTML("
    Shiny.addCustomMessageHandler('set_active_nav', function(tab) {
      var ids  = ['nav_howto', 'nav_score', 'nav_auc'];
      var vals = ['howto',     'score',     'auc'];
      for (var i = 0; i < ids.length; i++) {
        var el = document.getElementById(ids[i]);
        if (!el) continue;
        if (vals[i] === tab) { el.classList.add('nav-btn-active'); }
        else { el.classList.remove('nav-btn-active'); }
      }
    });
    Shiny.addCustomMessageHandler('progress_bar', function(msg) {
      var wrap = document.getElementById(msg.id + '_wrap');
      var fill = document.getElementById(msg.id + '_fill');
      var lbl  = document.getElementById(msg.id + '_label');
      if (!wrap || !fill || !lbl) return;
      if (msg.state === 'running') {
        wrap.classList.add('active'); fill.classList.add('pulsing');
        fill.style.width = '100%'; lbl.innerText = msg.label || 'Running on AWS...';
      } else if (msg.state === 'done') {
        fill.classList.remove('pulsing'); fill.style.background = '#28a745';
        fill.style.width = '100%'; lbl.innerText = msg.label || 'Done!';
        setTimeout(function() { wrap.classList.remove('active'); fill.style.width = '0%'; }, 2000);
      } else if (msg.state === 'error') {
        fill.classList.remove('pulsing'); fill.style.background = '#dc3545';
        fill.style.width = '100%'; lbl.innerText = msg.label || 'Error';
        setTimeout(function() { wrap.classList.remove('active'); fill.style.width = '0%'; fill.style.background = '#28a745'; }, 3000);
      } else {
        wrap.classList.remove('active'); fill.classList.remove('pulsing'); fill.style.width = '0%';
      }
    });
  ")),

  navset_hidden(
    id = "tabs",

    nav_panel("How to Use", value = "howto",
      div(style = "background:#fff; min-height:100vh; padding:24px 0 60px 0;",
        fluidRow(column(10, offset = 1,
          div(class = "help-hero", tags$h2("NRP snRNA-seq Explorer")),
          div(class = "workflow-banner",
            tags$b("Start here:"), " Run ", tags$b("Gene Activity Score"), " first, then use ",
            tags$b("Find Active Cells"), " to identify which cells have that program turned on."
          ),
          div(class = "help-cards-row",
            div(class = "help-card",
              tags$p(class = "help-card-title", "Tab 1 — Gene Activity Score"),
              div(class = "help-step", div(class = "step-num", "1"), div(class = "step-body", tags$b("Name your list"), " and enter genes (comma-separated), or load the preset.")),
              div(class = "help-step", div(class = "step-num", "2"), div(class = "step-body", tags$b("Click Compute Score."), " The app computes in the background — results appear automatically.")),
              div(class = "help-step", div(class = "step-num", "3"), div(class = "step-body", tags$b("Read the plots:"), " activity map (yellow = high), cell groups map, and violin plot per group."))
            ),
            div(class = "help-card",
              tags$p(class = "help-card-title", "Tab 2 — Find Active Cells"),
              div(class = "help-step", div(class = "step-num", "1"), div(class = "step-body", tags$b("Enter genes & a name,"), " then click Find Active Cells.")),
              div(class = "help-step", div(class = "step-num", "2"), div(class = "step-body", tags$b("Adjust the Sensitivity slider"), " — drag left for more cells, right for fewer.")),
              div(class = "help-step", div(class = "step-num", "3"), div(class = "step-body", tags$b("Four UMAPs:"), " timepoint, active cells (pink = on), clusters, identity/AUC scores.")),
              div(class = "help-step", div(class = "step-num", "4"), div(class = "step-body", tags$b("Bar charts:"), " stars (*, **, ***) indicate significant enrichment."))
            )
          ),
          div(class = "tips-card",
            tags$b("Tips:"),
            tags$ul(
              tags$li("Gene names are case-sensitive — ", tags$code("ISL1"), " not ", tags$code("isl1"), "."),
              tags$li("The Sensitivity slider updates all plots instantly.")
            )
          )
        ))
      )
    ),

    nav_panel("Gene Activity Score", value = "score",
      br(),
      sidebarLayout(
        sidebarPanel(
          div(class = "section-header", "Enter Your Genes"),
          actionButton("load_preset_score", "Load Motoneuron gene list (Yadav et al)",
                       class = "btn btn-outline-secondary btn-sm", style = "width:100%; margin-bottom:8px;"),
          textInput("score_label", "Gene list name:", placeholder = "e.g. MN"),
          helpText("Type gene names separated by commas or new lines."),
          textAreaInput("genes", NULL, placeholder = "ISL1, CHAT, MNX1", rows = 6),
          actionButton("run", "Compute Score", class = "btn btn-dark btn-sm", style = "width:100%; margin-bottom:10px;"),
          tags$div(id = "score_wrap", class = "progress-wrap",
            tags$div(class = "progress-bar-track", tags$div(id = "score_fill", class = "progress-bar-fill")),
            tags$div(id = "score_label", class = "progress-label")
          ),
          hr(),
          selectInput("group", "Color cells by:",
                      choices  = label_cols(group_choice_cols),
                      selected = if ("cell_subtypes" %in% group_choice_cols) "cell_subtypes" else group_choice_cols[1])
        ),
        mainPanel(
          div(class = "section-header", "Gene Activity Map"),
          plotOutput("score_umap", height = "550px"),
          hr(),
          div(class = "section-header", "Cell Groups Map"),
          plotOutput("group_umap", height = "550px"),
          hr(),
          div(class = "section-header", "Score per Group"),
          plotOutput("violinPlot", height = "350px")
        )
      )
    ),

    nav_panel("Find Active Cells", value = "auc",
      br(),
      sidebarLayout(
        sidebarPanel(width = 3,
          div(class = "section-header", "Enter Your Genes"),
          actionButton("load_preset_auc", "Load Motoneuron gene list (Yadav et al)",
                       class = "btn btn-outline-secondary btn-sm", style = "width:100%; margin-bottom:8px;"),
          helpText("Type gene names separated by commas or new lines."),
          textAreaInput("auc_genes", NULL, placeholder = "MKI67, TOP2A, PCNA", rows = 6),
          textInput("auc_setname", "Name this gene set:", value = "MyGeneSet"),
          actionButton("run_auc", "Find Active Cells", class = "btn btn-dark btn-sm", style = "width:100%; margin-bottom:10px;"),
          tags$div(id = "auc_wrap", class = "progress-wrap",
            tags$div(class = "progress-bar-track", tags$div(id = "auc_fill", class = "progress-bar-fill")),
            tags$div(id = "auc_label", class = "progress-label")
          ),
          hr(),
          div(class = "section-header", "Group Cells By"),
          selectInput("auc_timepoint_col", "Color cells by:",
                      choices  = label_cols(timepoint_cols),
                      selected = timepoint_cols[1]),
          hr(),
          div(class = "section-header", "Sensitivity"),
          helpText("Drag left to include more cells, right to be stricter."),
          uiOutput("auc_threshold_ui")
        ),
        mainPanel(width = 9,
          div(class = "section-header", "AUC Score Distribution & Cutoff"),
          helpText("Run first, then drag the Sensitivity slider to adjust which cells count as active."),
          plotOutput("auc_histogram", height = "260px"),
          hr(),
          div(class = "section-header", "Cell Maps"),
          fluidRow(
            column(6, plotOutput("auc_umap_timepoint", height = "420px")),
            column(6, plotOutput("auc_umap_passing",   height = "420px"))
          ),
          fluidRow(
            column(6, plotOutput("auc_umap_clusters",  height = "420px")),
            column(6, plotOutput("auc_umap_score",     height = "420px"))
          ),
          hr(),
          div(class = "section-header", "Active Cells by Cluster"),
          plotOutput("auc_bar_cluster", height = "400px"),
          hr(),
          uiOutput("bar_timepoint_header"),
          plotOutput("auc_bar_timepoint", height = "400px")
        )
      )
    )
  )
)

# ----------------------------
# Server
# ----------------------------
server <- function(input, output, session) {

  started <- reactiveVal(FALSE)
  observe({
    if (!started()) {
      res <- tryCatch(httr::GET(paste0(API_BASE, "/status"), timeout(2)), error = function(e) NULL)
      if (is.null(res) || httr::status_code(res) != 200) {
        message("Starting EC2...")
        try(httr::POST(paste0(API_BASE, "/start-ec2")), silent = TRUE)
      } else {
        message("Backend already running")
      }
      started(TRUE)
    }
  })

  backend_ready <- reactiveVal(FALSE)
  observe({
    invalidateLater(3000, session)
    res <- tryCatch(httr::GET(paste0(API_BASE, "/status"), timeout(2)), error = function(e) NULL)
    backend_ready(!is.null(res) && httr::status_code(res) == 200)
  })

  nav_switch <- function(tab) {
    nav_select("tabs", tab)
    session$sendCustomMessage("set_active_nav", tab)
  }
  observeEvent(input$nav_howto, nav_switch("howto"), ignoreInit = TRUE)
  observeEvent(input$nav_score, nav_switch("score"), ignoreInit = TRUE)
  observeEvent(input$nav_auc,   nav_switch("auc"),   ignoreInit = TRUE)

  progress_bar <- function(id, state, label = NULL) {
    session$sendCustomMessage("progress_bar", list(id = id, state = state, label = label))
  }

  rv <- reactiveValues(
    coords = NULL, meta = NULL, module_scores = NULL,
    found_genes = character(0), missing_genes = character(0),
    score_label = NULL, job_id = NULL, polling = FALSE
  )

  auc_rv <- reactiveValues(
    coords = NULL, meta = NULL, auc_scores = NULL,
    auto_threshold = NULL, threshold = NULL, pass = NULL,
    gene_set_name = NULL, found_genes = character(0),
    missing_genes = character(0), job_id = NULL, polling = FALSE
  )

  mn_genes_text <- paste(preset_gene_lists[["Motoneuron (Yadav et al)"]], collapse = ", ")
  observeEvent(input$load_preset_score, {
    updateTextAreaInput(session, "genes",      value = mn_genes_text)
    updateTextInput(session,    "score_label", value = "Motoneuron")
  })
  observeEvent(input$load_preset_auc, {
    updateTextAreaInput(session, "auc_genes",  value = mn_genes_text)
    updateTextInput(session,    "auc_setname", value = "Motoneuron")
  })

  submit_job <- function(mode, genes, name) {
    res <- tryCatch({
      httr::POST(paste0(API_BASE, "/run-analysis"),
                 body = list(mode = mode, genes = genes, name = name),
                 encode = "json", timeout(15))
    }, error = function(e) e)
    if (inherits(res, "error")) stop(res$message)
    if (httr::status_code(res) == 429) stop("Another analysis is already running. Please wait.")
    if (httr::status_code(res) != 200) {
      msg <- tryCatch(httr::content(res, "text", encoding = "UTF-8"), error = function(e) "Submission error")
      stop(msg)
    }
    jsonlite::fromJSON(httr::content(res, "text", encoding = "UTF-8"))$job_id
  }

  poll_job <- function(job_id) {
    res <- tryCatch(httr::GET(paste0(API_BASE, "/result/", job_id), timeout(10)), error = function(e) e)
    if (inherits(res, "error")) return(list(status = "network_error"))
    if (httr::status_code(res) == 200) {
      data <- jsonlite::fromJSON(httr::content(res, "text", encoding = "UTF-8"))
      if (!is.null(data$status) && data$status == "running") return(list(status = "running"))
      return(list(status = "done", data = data))
    }
    if (httr::status_code(res) == 500) {
      msg <- tryCatch(jsonlite::fromJSON(httr::content(res, "text", encoding = "UTF-8"))$detail, error = function(e) "Backend error")
      return(list(status = "error", detail = msg))
    }
    list(status = "error", detail = paste("Unexpected status:", httr::status_code(res)))
  }

  observeEvent(input$run, {
    if (rv$polling) { showNotification("Analysis already running. Please wait.", type = "warning"); return(NULL) }
    if (length(parse_genes(input$genes)) == 0) { showNotification("Please enter at least 1 gene.", type = "error"); return(NULL) }
    if (!backend_ready()) { showNotification("Backend is still starting. Please wait.", type = "warning"); return(NULL) }
    job_id <- tryCatch(submit_job("score", input$genes, input$score_label),
                       error = function(e) { showNotification(paste("Error:", e$message), type = "error"); progress_bar("score", "error", "Submission failed"); NULL })
    if (is.null(job_id)) return(NULL)
    rv$job_id <- job_id; rv$polling <- TRUE; rv$score_label <- input$score_label
    progress_bar("score", "running", "Computing on AWS...")
    showNotification("Computing module score on AWS...", type = "message", duration = NULL, id = "score_progress")
  })

  observe({
    req(rv$polling, !is.null(rv$job_id))
    invalidateLater(4000, session)
    result <- poll_job(rv$job_id)
    if (result$status %in% c("running", "network_error")) return()
    removeNotification("score_progress")
    rv$polling <- FALSE; rv$job_id <- NULL
    if (result$status == "error") { progress_bar("score", "error", "Error"); showNotification(paste("Backend error:", result$detail), type = "error", duration = 8); return() }
    data <- result$data
    rv$coords <- safe_df(data$coords); rv$meta <- safe_df(data$meta)
    rv$module_scores <- safe_df(data$module_scores)
    rv$found_genes <- data$found_genes; rv$missing_genes <- data$missing_genes
    progress_bar("score", "done", "Done!")
    if (length(data$missing_genes) == 0) {
      showNotification(paste0("All ", length(data$found_genes), " genes found."), type = "message", duration = 6)
    } else {
      showNotification(paste0(length(data$missing_genes), " gene(s) not found: ", paste(data$missing_genes, collapse = ", ")), type = "error", duration = 8)
    }
  })

  observeEvent(input$run_auc, {
    if (auc_rv$polling) { showNotification("Analysis already running. Please wait.", type = "warning"); return(NULL) }
    if (length(parse_genes(input$auc_genes)) == 0) { showNotification("Please enter at least 1 gene.", type = "error"); return(NULL) }
    if (!backend_ready()) { showNotification("Backend is still starting. Please wait.", type = "warning"); return(NULL) }
    job_id <- tryCatch(submit_job("auc", input$auc_genes, input$auc_setname),
                       error = function(e) { showNotification(paste("Error:", e$message), type = "error"); progress_bar("auc", "error", "Submission failed"); NULL })
    if (is.null(job_id)) return(NULL)
    auc_rv$job_id <- job_id; auc_rv$polling <- TRUE
    progress_bar("auc", "running", "Running AUCell on AWS...")
    showNotification("Running AUCell on AWS...", type = "message", duration = NULL, id = "auc_progress")
  })

  observe({
    req(auc_rv$polling, !is.null(auc_rv$job_id))
    invalidateLater(4000, session)
    result <- poll_job(auc_rv$job_id)
    if (result$status %in% c("running", "network_error")) return()
    removeNotification("auc_progress")
    auc_rv$polling <- FALSE; auc_rv$job_id <- NULL
    if (result$status == "error") { progress_bar("auc", "error", "Error"); showNotification(paste("Backend error:", result$detail), type = "error", duration = 8); return() }
    data <- result$data
    auc_rv$coords <- safe_df(data$coords); auc_rv$meta <- safe_df(data$meta)
    auc_rv$gene_set_name <- data$gene_set_name
    auc_rv$found_genes <- data$found_genes; auc_rv$missing_genes <- data$missing_genes
    auc_rv$auto_threshold <- data$auto_threshold; auc_rv$threshold <- data$auto_threshold
    auc_scores_df <- safe_df(data$auc_scores)
    auc_rv$auc_scores <- setNames(auc_scores_df$auc_score, auc_scores_df$cell)
    auc_rv$pass <- auc_rv$auc_scores > auc_rv$threshold
    progress_bar("auc", "done", paste0("Done! ", sum(auc_rv$pass, na.rm = TRUE), " active cells"))
    if (length(data$missing_genes) == 0) {
      showNotification(paste0("All ", length(data$found_genes), " genes found. ", sum(auc_rv$pass, na.rm = TRUE), " active cells detected."), type = "message", duration = 6)
    } else {
      showNotification(paste0(length(data$missing_genes), " gene(s) not found: ", paste(data$missing_genes, collapse = ", ")), type = "error", duration = 8)
    }
  })

  output$auc_threshold_ui <- renderUI({
    req(!is.null(auc_rv$auc_scores))
    scores <- as.numeric(auc_rv$auc_scores)
    score_min <- round(min(scores, na.rm = TRUE), 5)
    score_max <- round(max(scores, na.rm = TRUE), 5)
    score_step <- round((score_max - score_min) / 200, 6)
    tagList(
      sliderInput("auc_manual_threshold", label = NULL, min = score_min, max = score_max,
                  value = auc_rv$auto_threshold, step = ifelse(score_step == 0, 0.0001, score_step), round = FALSE, width = "100%"),
      helpText(paste0("Auto threshold: ", round(auc_rv$auto_threshold, 5)))
    )
  })

  observeEvent(input$auc_manual_threshold, {
    req(!is.null(auc_rv$auc_scores))
    auc_rv$threshold <- input$auc_manual_threshold
    auc_rv$pass      <- auc_rv$auc_scores > input$auc_manual_threshold
  }, ignoreInit = TRUE)

  score_df <- reactive({
    req(!is.null(rv$coords), !is.null(rv$meta), !is.null(rv$module_scores))
    out <- safe_df(rv$coords) %>%
      left_join(safe_df(rv$meta),          by = "cell") %>%
      left_join(safe_df(rv$module_scores), by = "cell")
    req(all(c("UMAP_1", "UMAP_2", "Module_Scores1") %in% colnames(out)))
    out
  })

  auc_df <- reactive({
    req(!is.null(auc_rv$coords), !is.null(auc_rv$meta), !is.null(auc_rv$auc_scores))
    scores <- data.frame(cell = names(auc_rv$auc_scores), auc_score = as.numeric(auc_rv$auc_scores), stringsAsFactors = FALSE)
    out <- safe_df(auc_rv$coords) %>%
      left_join(safe_df(auc_rv$meta), by = "cell") %>%
      left_join(scores,               by = "cell")
    req(all(c("UMAP_1", "UMAP_2", "auc_score") %in% colnames(out)))
    out$status <- ifelse(out$auc_score > auc_rv$threshold, "Above threshold", "Below threshold")
    out
  })

  output$score_umap <- renderPlot({
    df    <- score_df()
    label <- if (!is.null(rv$score_label) && nzchar(rv$score_label)) rv$score_label else "Gene Set"
    ggplot(df, aes(UMAP_1, UMAP_2, color = Module_Scores1)) +
      geom_point(size = 0.5, alpha = 0.9) +
      scale_color_viridis_c(option = "plasma", name = "Module Score") +
      labs(title = paste0(label, " Module Score"), x = "UMAP_1", y = "UMAP_2") +
      theme_app() + theme(plot.title = element_text(face = "bold", hjust = 0.5, size = 13))
  })

  output$group_umap <- renderPlot({
    req(input$group %in% group_choice_cols)
    df <- score_df()
    req(input$group %in% colnames(df))
    title_label <- if (input$group %in% names(col_labels)) col_labels[input$group] else input$group
    centers <- df %>% filter(!is.na(.data[[input$group]])) %>%
      group_by(.data[[input$group]]) %>%
      summarise(UMAP_1 = median(UMAP_1), UMAP_2 = median(UMAP_2), .groups = "drop")
    names(centers)[1] <- "group"
    p <- ggplot(df, aes(UMAP_1, UMAP_2, color = .data[[input$group]])) +
      geom_point(size = 0.4, alpha = 0.7) +
      ggrepel::geom_label_repel(data = centers, aes(UMAP_1, UMAP_2, label = group, color = group),
        size = 4.5, fontface = "bold", fill = scales::alpha("white", 0.75),
        label.size = 0.35, force = 10, force_pull = 0.5, max.overlaps = Inf, show.legend = FALSE) +
      labs(title = title_label, x = "UMAP_1", y = "UMAP_2", color = NULL) +
      theme_app() + theme(plot.title = element_text(face = "bold", hjust = 0.5))
    if (input$group == "group") {
      p <- p + scale_color_manual(values = c("iPSC" = "#F5A623", "Day7" = "#E41A1C", "Day15" = "#377EB8"), na.value = "gray80")
    } else if (input$group == "cell_subtypes") {
      p <- p + scale_color_manual(values = motoneuron_colors, na.value = "gray80")
    }
    p
  })

  output$violinPlot <- renderPlot({
    req(input$group %in% group_choice_cols)
    df <- score_df()
    req(input$group %in% colnames(df))
    ggplot(df, aes(x = .data[[input$group]], y = Module_Scores1, fill = .data[[input$group]])) +
      geom_violin(scale = "width", trim = FALSE) +
      geom_jitter(size = 0.1, alpha = 0.2, width = 0.2) +
      labs(title = "Module Score by Group", x = NULL, y = "Module Score") +
      theme_app() + theme(plot.title = element_text(face = "bold", hjust = 0.5), legend.position = "none", axis.text.x = element_text(angle = 45, hjust = 1))
  })

  output$auc_histogram <- renderPlot({
    req(!is.null(auc_rv$auc_scores), !is.null(auc_rv$threshold))
    df  <- data.frame(score = as.numeric(auc_rv$auc_scores))
    thr <- auc_rv$threshold
    ggplot(df, aes(x = score)) +
      geom_histogram(bins = 60, fill = "steelblue", alpha = 0.75, color = "white") +
      geom_vline(xintercept = thr, color = "deeppink", linewidth = 1.2, linetype = "dashed") +
      annotate("text", x = thr, y = Inf, label = paste0("thr = ", round(thr, 4)),
               hjust = -0.1, vjust = 1.5, color = "deeppink", fontface = "bold") +
      labs(title = paste0(auc_rv$gene_set_name, " — AUC Distribution"), x = "AUC Score", y = "# Cells") +
      theme_app() + theme(plot.title = element_text(face = "bold", hjust = 0.5))
  })

  output$auc_umap_timepoint <- renderPlot({
    df <- auc_df()
    req("group" %in% colnames(df))
    df$timepoint <- factor(df$group, levels = c("iPSC", "Day7", "Day15"))
    centers <- df %>% filter(!is.na(timepoint)) %>% group_by(timepoint) %>%
      summarise(UMAP_1 = median(UMAP_1), UMAP_2 = median(UMAP_2), .groups = "drop")
    ggplot(df, aes(UMAP_1, UMAP_2, color = timepoint)) +
      geom_point(size = 0.4, alpha = 0.7) +
      scale_color_manual(values = c("iPSC" = "#F5A623", "Day7" = "#E41A1C", "Day15" = "#377EB8"), na.value = "gray80") +
      ggrepel::geom_label_repel(data = centers, aes(UMAP_1, UMAP_2, label = timepoint, color = timepoint),
        size = 4.5, fontface = "bold", fill = scales::alpha("white", 0.75),
        label.size = 0.35, force = 10, force_pull = 0.5, max.overlaps = Inf, show.legend = FALSE) +
      labs(title = "Timepoint (iPSC / Day7 / Day15)", x = "UMAP_1", y = "UMAP_2", color = NULL) +
      guides(color = guide_legend(override.aes = list(size = 3))) +
      theme_app() + theme(plot.title = element_text(face = "bold", hjust = 0.5), legend.position = "right", legend.text = element_text(face = "bold"))
  })

  output$auc_umap_passing <- renderPlot({
    df <- auc_df()
    ggplot(df, aes(UMAP_1, UMAP_2, color = status)) +
      geom_point(size = 0.5, alpha = 0.8) +
      scale_color_manual(values = c("Above threshold" = "deeppink", "Below threshold" = "gray75")) +
      labs(title = paste0("Above threshold: ", sum(df$status == "Above threshold", na.rm = TRUE),
                          " | Below: ", sum(df$status == "Below threshold", na.rm = TRUE)),
           x = "UMAP_1", y = "UMAP_2") +
      theme_app() + theme(plot.title = element_text(face = "bold", hjust = 0.5, size = 11), legend.position = "top")
  })

  output$auc_umap_clusters <- renderPlot({
    df <- auc_df()
    req(CLUSTER_COL %in% colnames(df))
    grp_df  <- df %>% mutate(group = factor(.data[[CLUSTER_COL]]))
    centers <- grp_df %>% filter(!is.na(group)) %>% group_by(group) %>%
      summarise(UMAP_1 = median(UMAP_1), UMAP_2 = median(UMAP_2), .groups = "drop")
    title_label <- if (CLUSTER_COL %in% names(col_labels)) col_labels[CLUSTER_COL] else CLUSTER_COL
    ggplot(grp_df, aes(UMAP_1, UMAP_2, color = group)) +
      geom_point(size = 0.4, alpha = 0.7) +
      ggrepel::geom_label_repel(data = centers, aes(UMAP_1, UMAP_2, label = group, color = group),
        size = 4.5, fontface = "bold", fill = scales::alpha("white", 0.75),
        label.size = 0.35, force = 10, force_pull = 0.5, max.overlaps = Inf, show.legend = FALSE) +
      labs(title = title_label, x = "UMAP_1", y = "UMAP_2", color = "Cluster") +
      guides(color = guide_legend(override.aes = list(size = 3), ncol = ceiling(nlevels(grp_df$group) / 10))) +
      theme_app() + theme(plot.title = element_text(face = "bold", hjust = 0.5), legend.position = "right")
  })

  output$auc_umap_score <- renderPlot({
    df <- auc_df()
    if (input$auc_timepoint_col == "cell_subtypes" && "cell_subtypes" %in% colnames(df)) {
      grp_df  <- df %>% mutate(group = factor(cell_subtypes))
      centers <- grp_df %>% filter(!is.na(group)) %>% group_by(group) %>%
        summarise(UMAP_1 = median(UMAP_1), UMAP_2 = median(UMAP_2), .groups = "drop")
      ggplot(grp_df, aes(UMAP_1, UMAP_2, color = group)) +
        geom_point(size = 0.4, alpha = 0.7) +
        scale_color_manual(values = motoneuron_colors, na.value = "gray80") +
        ggrepel::geom_label_repel(data = centers, aes(UMAP_1, UMAP_2, label = group, color = group),
          size = 4, fontface = "bold", fill = scales::alpha("white", 0.7),
          label.size = 0.3, force = 10, force_pull = 0.5, max.overlaps = Inf, show.legend = FALSE) +
        labs(title = "Cell Identity (Motoneuron / Other)", x = "UMAP_1", y = "UMAP_2", color = NULL) +
        theme_app() + theme(plot.title = element_text(face = "bold", hjust = 0.5, size = 11), legend.position = "right")
    } else {
      score_min       <- min(df$auc_score, na.rm = TRUE)
      score_max       <- max(df$auc_score, na.rm = TRUE)
      df$score_scaled <- (df$auc_score - score_min) / (score_max - score_min + 1e-9)
      ggplot(df, aes(UMAP_1, UMAP_2)) +
        geom_point(color = "gray85", size = 0.4) +
        geom_point(aes(color = score_scaled), size = 0.5, alpha = 0.9) +
        scale_color_viridis_c(option = "plasma", name = "Scaled AUC", limits = c(0, 1)) +
        labs(title = paste0(auc_rv$gene_set_name, " — AUC Score (scaled)"), x = "UMAP_1", y = "UMAP_2") +
        theme_app() + theme(plot.title = element_text(face = "bold", hjust = 0.5, size = 11), legend.position = "right")
    }
  })

  # ==========================================
  # BAR CHARTS — fixed duplicate column name
  # ==========================================
  fisher_stars <- function(df_cells, group_col) {
    groups  <- levels(df_cells[[group_col]])
    results <- lapply(groups, function(g) {
      a      <- sum(df_cells[[group_col]] == g & df_cells$status == "Above threshold")
      b      <- sum(df_cells[[group_col]] == g & df_cells$status == "Below threshold")
      others <- df_cells[df_cells[[group_col]] != g, ]
      c      <- sum(others$status == "Above threshold")
      d      <- sum(others$status == "Below threshold")
      mat    <- matrix(c(a, b, c, d), nrow = 2)
      pval   <- tryCatch(fisher.test(mat)$p.value, error = function(e) NA_real_)
      data.frame(group = g, p = pval, stringsAsFactors = FALSE)
    })
    res       <- bind_rows(results)
    res$p_adj <- p.adjust(res$p, method = "BH")
    res$stars <- cut(res$p_adj, breaks = c(-Inf, 0.001, 0.01, 0.05, Inf), labels = c("***", "**", "*", "ns"))
    res
  }

  make_bar_chart <- function(df_cells, group_col, title_label) {
    df_cells <- as.data.frame(df_cells)
    if (group_col != "group") {
      df_cells[["group"]] <- factor(df_cells[[group_col]])
      df_cells <- df_cells[, !colnames(df_cells) %in% group_col, drop = FALSE]
    } else {
      df_cells[["group"]] <- factor(df_cells[["group"]])
    }

    counts_df <- df_cells %>%
      group_by(group, status) %>%
      summarise(n = n(), .groups = "drop") %>%
      as.data.frame()

    fisher_res <- fisher_stars(df_cells, "group")

    global_max  <- max(counts_df$n)
    max_per_grp <- counts_df %>% group_by(group) %>% summarise(max_n = max(n), .groups = "drop")
    fisher_res        <- left_join(fisher_res, max_per_grp, by = "group")
    fisher_res$y_pos  <- fisher_res$max_n + global_max * 0.12
    counts_df$y_label <- counts_df$n + global_max * 0.015

    dodge <- position_dodge(width = 0.85)
    ggplot(counts_df, aes(x = group, y = n, fill = status)) +
      geom_bar(stat = "identity", position = dodge, width = 0.75, alpha = 0.85) +
      geom_text(aes(y = y_label, label = n), position = dodge, size = 3, fontface = "bold") +
      geom_text(data = filter(fisher_res, stars != "ns"),
                aes(x = group, y = y_pos, label = as.character(stars)), inherit.aes = FALSE, size = 5, fontface = "bold") +
      geom_text(data = filter(fisher_res, stars == "ns"),
                aes(x = group, y = y_pos, label = as.character(stars)), inherit.aes = FALSE, size = 3.5, color = "gray40") +
      scale_fill_manual(values = c("Above threshold" = "deeppink", "Below threshold" = "gray70")) +
      scale_y_continuous(limits = c(0, global_max * 1.4), expand = expansion(mult = c(0, 0))) +
      labs(title = title_label, x = NULL, y = "Number of Cells", fill = "AUC Status") +
      theme_app() + theme(axis.text.x = element_text(angle = 45, hjust = 1), legend.position = "top", plot.title = element_text(face = "bold", hjust = 0.5))
  }

  output$auc_bar_cluster <- renderPlot({
    df <- auc_df()
    req(CLUSTER_COL %in% colnames(df))
    df_cells <- df %>% filter(!is.na(.data[[CLUSTER_COL]]))
    make_bar_chart(df_cells, CLUSTER_COL, paste0(auc_rv$gene_set_name, " — Above/Below Threshold by Cluster"))
  })

  output$bar_timepoint_header <- renderUI({
    label <- if (input$auc_timepoint_col %in% names(col_labels)) col_labels[input$auc_timepoint_col] else input$auc_timepoint_col
    div(class = "section-header", paste0("Active Cells by ", label))
  })

  output$auc_bar_timepoint <- renderPlot({
    df <- auc_df()
    req(input$auc_timepoint_col %in% colnames(df))
    col_vals   <- df[[input$auc_timepoint_col]]
    timepoints <- if (input$auc_timepoint_col == "group") c("iPSC", "Day7", "Day15") else sort(unique(col_vals[!is.na(col_vals)]))
    df_cells   <- df %>% filter(.data[[input$auc_timepoint_col]] %in% timepoints)
    if (nrow(df_cells) == 0) { showNotification("No cells matched the specified timepoints.", type = "warning"); return(NULL) }
    group_label <- if (input$auc_timepoint_col %in% names(col_labels)) col_labels[input$auc_timepoint_col] else input$auc_timepoint_col
    make_bar_chart(df_cells, input$auc_timepoint_col, paste0(auc_rv$gene_set_name, " — Above/Below Threshold by ", group_label))
  })

}

shinyApp(ui, server)
