# src/14_reproducibility_check.R
# REPRODUCIBILITY CHECK (DESIGN.md sections 11.9 and 12.7). Post-hoc.
# Compares every CSV, TXT and PNG in results/ and data/summary/ in this folder with the same file
# produced by a fresh re-run of the full chain in a separate folder (copy of the repository, raw zip
# re-downloaded and checked against its published size, no committed outputs copied in).
# Numbers: exact match for text and integer cells, relative tolerance 1e-9 for other numeric cells.
# PNG files: byte comparison only (PNG bytes can differ between renders with no change in the data).
#
# Usage (from the project root):  Rscript src/14_reproducibility_check.R <path-to-rerun-folder>
# Output: results/R_reproducibility_check.csv
suppressPackageStartupMessages(library(data.table))

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1L) stop("usage: Rscript src/14_reproducibility_check.R <rerun folder>")
rerun <- args[1]
TOL <- 1e-9

list_outputs <- function(root) {
  r <- file.path("results", list.files(file.path(root, "results"), pattern = "\\.(csv|txt|png)$"))
  s <- file.path("data", "summary", list.files(file.path(root, "data", "summary"), pattern = "\\.(csv|txt)$"))
  g <- file.path("figures", list.files(file.path(root, "figures"), pattern = "\\.png$"))
  c(r, s, g)
}

repo_files <- list_outputs(".")
rerun_files <- list_outputs(rerun)
all_files <- sort(unique(c(repo_files, rerun_files)))
all_files <- setdiff(all_files, "results/R_reproducibility_check.csv")

compare_csv <- function(a, b) {
  A <- fread(a, showProgress = FALSE); B <- fread(b, showProgress = FALSE)
  out <- list(rows_repo = nrow(A), rows_rerun = nrow(B), cols_repo = ncol(A), cols_rerun = ncol(B),
              max_abs_diff = NA_real_, cells_differ = NA_integer_, note = "")
  if (nrow(A) != nrow(B) || ncol(A) != ncol(B) || !identical(names(A), names(B))) {
    out$note <- "shape or column names differ"
    return(list(status = "DIFFER", out = out))
  }
  maxd <- 0; ndiff <- 0L
  for (j in seq_len(ncol(A))) {
    x <- A[[j]]; y <- B[[j]]
    if (is.numeric(x) && is.numeric(y)) {
      nx <- is.na(x); ny <- is.na(y)
      if (!identical(nx, ny)) { ndiff <- ndiff + sum(nx != ny); maxd <- Inf; next }
      ok <- !nx
      d <- abs(x[ok] - y[ok]); scale <- pmax(abs(x[ok]), abs(y[ok]), 1)
      bad <- d > TOL * scale
      ndiff <- ndiff + sum(bad)
      if (length(d)) maxd <- max(maxd, max(d))
    } else {
      bad <- as.character(x) != as.character(y) | (is.na(x) != is.na(y))
      bad[is.na(bad)] <- FALSE
      ndiff <- ndiff + sum(bad)
    }
  }
  out$max_abs_diff <- maxd; out$cells_differ <- ndiff
  list(status = if (ndiff == 0L) "NUMERIC_MATCH" else "DIFFER", out = out)
}

rows <- lapply(all_files, function(f) {
  a <- f; b <- file.path(rerun, f)
  in_repo <- file.exists(a); in_rerun <- file.exists(b)
  base <- list(file = f, status = NA_character_, rows_repo = NA_integer_, rows_rerun = NA_integer_,
               cols_repo = NA_integer_, cols_rerun = NA_integer_, max_abs_diff = NA_real_,
               cells_differ = NA_integer_, note = "")
  if (!in_rerun) { base$status <- "MISSING_IN_RERUN"; return(as.data.table(base)) }
  if (!in_repo) { base$status <- "MISSING_IN_REPO"; return(as.data.table(base)) }
  if (grepl("\\.png$", f)) {
    same <- tools::md5sum(a) == tools::md5sum(b)
    base$status <- if (same) "BYTES_IDENTICAL" else "BYTES_DIFFER_PNG"
    base$note <- "PNG: byte comparison only"
    return(as.data.table(base))
  }
  if (grepl("\\.txt$", f)) {
    same <- tools::md5sum(a) == tools::md5sum(b)
    base$status <- if (same) "BYTES_IDENTICAL" else "TEXT_DIFFER"
    return(as.data.table(base))
  }
  res <- compare_csv(a, b)
  base$status <- res$status
  for (nm in names(res$out)) base[[nm]] <- res$out[[nm]]
  as.data.table(base)
})
out <- rbindlist(rows, fill = TRUE)
fwrite(out, "results/R_reproducibility_check.csv")
print(out[, .N, by = status])
