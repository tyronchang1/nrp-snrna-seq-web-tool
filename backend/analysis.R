#!/usr/bin/env Rscript
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3) {
  stop("Usage: Rscript analysis.R <payload.json> <output.json> <seurat.rds>")
}
payload_file <- args[1]
output_json  <- args[2]
rds_file     <- args[3]

library(jsonlite)
library(Seurat)
library(AUCell)

payload <- fromJSON(payload_file)
mode      <- payload$mode
genes_txt <- payload$genes
set_name  <- payload$name

parse_genes <- function(x) {
  if (is.null(x) || !nzchar(x)) return(character(0))
  genes <- unlist(strsplit(x, "[,\\s]+"))
  genes <- trimws(genes)
  unique(genes[nzchar(genes)])
}

genes_in <- parse_genes(genes_txt)
if (length(genes_in) == 0) {
  stop("No genes were provided")
}

seu <- readRDS(rds_file)

# ---- SAFE layer join ----
if ("layers" %in% slotNames(seu[["RNA"]])) {
  try(seu[["RNA"]] <- JoinLayers(seu[["RNA"]]), silent = TRUE)
}

available_reductions <- Reductions(seu)
default_reduction <- if ("umap.pca" %in% available_reductions) {
  "umap.pca"
} else if ("umap" %in% available_reductions) {
  "umap"
} else {
  stop("No UMAP reduction found")
}

coords <- Embeddings(seu, reduction = default_reduction)
meta   <- seu@meta.data

all_features <- rownames(seu)
found   <- genes_in[genes_in %in% all_features]
missing <- setdiff(genes_in, found)

if (length(found) == 0) {
  stop("None of the input genes were found")
}

coords_df <- data.frame(
  cell   = rownames(coords),
  UMAP_1 = coords[, 1],
  UMAP_2 = coords[, 2],
  stringsAsFactors = FALSE
)

meta_df <- data.frame(
  cell = rownames(meta),
  meta,
  stringsAsFactors = FALSE,
  check.names = FALSE
)

if (mode == "score") {
  
  seu@meta.data <- seu@meta.data[, !grepl("^Module_Scores", colnames(seu@meta.data)), drop = FALSE]
  seu <- AddModuleScore(seu, features = list(found), name = "Module_Scores")
  
  result <- list(
    mode          = "score",
    gene_set_name = set_name,
    found_genes   = found,
    missing_genes = missing,
    coords        = coords_df,
    meta          = meta_df,
    module_scores = data.frame(
      cell           = rownames(seu@meta.data),
      Module_Scores1 = seu@meta.data$Module_Scores1,
      stringsAsFactors = FALSE
    )
  )
  
} else if (mode == "auc") {
  
  expr_matrix <- GetAssayData(seu, layer = "data")
  
  # Motoneuron preset gene list — use fixed aucMaxRank of 500 to match original app
  mn_genes <- c(
    "TMSB4X", "TUBA1B", "TUBA1A", "TUBB4B", "TUBB2A", "TUBA4A",
    "ACTG1", "ACTB", "DYNC1H1", "KIF21A", "KLC1", "MAP1B",
    "HSP90AB1", "HSP90AA1", "HSPA8", "HSPB1", "YWHAQ", "YWHAH",
    "UBB", "UCHL1", "GAPDH", "PKM", "ATP1B1", "MT1X", "UTS2", "PRUNE2",
    "LGALS1", "MCAM", "S100A10", "AHNAK2", "ANXA2", "CALM1", "S100B", "PVALB",
    "CLU", "SPARCL1", "ACLY", "SLC5A7", "SPP1", "SOD1", "NEFL", "NEFM", "NEFH",
    "STMN2", "PRPH", "PLP1", "SNCG", "RTN1", "RTN3", "RTN4", "TMSB10"
  )
  is_mn_preset <- length(found) == length(mn_genes) && all(sort(found) == sort(mn_genes))
  auc_max_rank <- if (is_mn_preset) 500 else ceiling(0.05 * nrow(expr_matrix))
  
  rankings         <- AUCell_buildRankings(expr_matrix, plotStats = FALSE)
  cells_AUC        <- AUCell_calcAUC(list(GeneSet = found), rankings, aucMaxRank = auc_max_rank)
  cells_assignment <- AUCell_exploreThresholds(cells_AUC, plotHist = FALSE, assign = TRUE)
  
  auc_scores <- as.numeric(getAUC(cells_AUC)[1, ])
  names(auc_scores) <- colnames(expr_matrix)
  
  auto_threshold <- tryCatch(
    unname(cells_assignment[[1]]$aucThr$selected),
    error = function(e) NA
  )
  
  result <- list(
    mode          = "auc",
    gene_set_name = set_name,
    found_genes   = found,
    missing_genes = missing,
    coords        = coords_df,
    meta          = meta_df,
    auc_scores    = data.frame(
      cell      = names(auc_scores),
      auc_score = auc_scores,
      stringsAsFactors = FALSE
    ),
    auto_threshold = auto_threshold
  )
  
} else {
  stop("mode must be 'score' or 'auc'")
}

write(toJSON(result, auto_unbox = TRUE, dataframe = "rows", na = "null"), output_json)
