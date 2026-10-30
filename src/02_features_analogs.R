# src/02_features_analogs.R  (component C)
# (a) Development-only choice of K (number of analog products). Uses development launches only.
# (b) Leakage test: rebuild features from data cut at earlier weeks and check they do not change.
# (c) Check that every fitted training row has a target week at or before week 52.
# Run from the project root: Rscript src/02_features_analogs.R
source("src/lib_pipeline.R")
suppressPackageStartupMessages(library(data.table))
dir.create("results", showWarnings = FALSE)

cfg <- CFG_DEFAULT
ctx <- prepare_context(cfg)
L <- ctx$launch$L

# ---------- (a) K selection on development launches only (k = 4, analog-only forecast M5) ----------
tr_ids <- make_sets(ctx, 4L)$train
glob4 <- global_curves(ctx, tr_ids, cfg$dev_last)
kt <- rbindlist(lapply(c(10L, 20L, 40L), function(K) {
  r <- build_rows(ctx, tr_ids, 4L, cfg$dev_last, glob4, K)
  t <- r[is_target == TRUE]
  data.table(K = K, dev_products = length(tr_ids), dev_WAPE_M5_k4 = sum(abs(t$analog_raw - t$y)) / sum(t$y),
             fallback_products = attr(r, "n_fallback"))
}))
print(kt)
fwrite(kt, "results/C_dev_K_selection.csv")
K_chosen <- kt$K[which.min(kt$dev_WAPE_M5_k4)]
cat("K chosen on development data:", K_chosen, "\n")

# ---------- (b) leakage test ----------
# Rebuild the whole context from data cut at week T. Every feature that uses data up to week
# w must be identical in the full and cut contexts for all w <= T.
checks <- list()
for (T_cut in c(40L, 90L)) {
  ct <- prepare_context(cfg, trunc_week = T_cut)
  Lt <- ct$launch$L
  common <- intersect(ctx$launch$StockCode, ct$launch$StockCode)
  pf <- match(common, ctx$launch$StockCode); pt <- match(common, ct$launch$StockCode)
  # launches must be the same set for products launching at or before T
  full_le <- ctx$launch$StockCode[L <= T_cut]
  trunc_set <- ct$launch$StockCode
  same_set <- setequal(full_le, trunc_set)
  nU <- 0L; mU <- 0L; nLP <- 0L; mLP <- 0L; nD <- 0L; mD <- 0L
  for (j in seq_along(common)) {
    a <- pf[j]; b <- pt[j]
    wk <- L[a]:T_cut
    nU <- nU + length(wk); mU <- mU + sum(ctx$U[a, wk] != ct$U[b, wk])
    nLP <- nLP + length(wk)
    lpa <- ctx$LP[a, wk]; lpb <- ct$LP[b, wk]
    mLP <- mLP + sum(!(is.na(lpa) & is.na(lpb)) & !(abs(lpa - lpb) < 1e-12 | (is.na(lpa) & is.na(lpb))))
    da <- ctx$desc_vocab[ctx$DESC_IDX[a, wk]]; db <- ct$desc_vocab[ct$DESC_IDX[b, wk]]
    nD <- nD + length(wk); mD <- mD + sum(!(da == db | (is.na(da) & is.na(db))))
  }
  # analog sets and curves for origins at or before T_cut
  cand <- which(L + 4L <= T_cut)           # origin = L + k - 1 <= T_cut for k <= 4 + ...
  set.seed(cfg$seed)
  samp <- sample(cand, min(150, length(cand)))
  na_mis <- 0L; na_n <- 0L; cur_mis <- 0L
  for (pid in samp) {
    for (k in c(1L, 4L, 8L)) {
      origin <- L[pid] + k - 1L
      if (origin > T_cut) next
      pid_t <- ct$launch$pid[match(ctx$launch$StockCode[pid], ct$launch$StockCode)]
      if (is.na(pid_t)) next
      na_n <- na_n + 1L
      a_full <- ctx$launch$StockCode[find_analogs(ctx, pid, k, K_chosen)]
      a_tr <- ct$launch$StockCode[find_analogs(ct, pid_t, k, K_chosen)]
      if (!identical(sort(a_full), sort(a_tr))) na_mis <- na_mis + 1L
      if (length(a_full) && length(a_tr)) {
        cf <- analog_curves(ctx, find_analogs(ctx, pid, k, K_chosen), k + H_MAX, origin)
        ctt <- analog_curves(ct, find_analogs(ct, pid_t, k, K_chosen), k + H_MAX, origin)
        if (max(abs(cf$log - ctt$log)) > 1e-12) cur_mis <- cur_mis + 1L
      }
    }
  }
  checks[[length(checks) + 1L]] <- data.table(
    truncation_week = T_cut,
    check = c("launch set up to truncation identical", "weekly units up to truncation identical",
              "as-of log median price up to truncation identical", "as-of description up to truncation identical",
              "analog sets identical (sampled origins)", "analog curves identical (sampled origins)"),
    n_compared = c(length(common), nU, nLP, nD, na_n, na_n),
    n_mismatch = c(as.integer(!same_set), mU, mLP, mD, na_mis, cur_mis)
  )
}
leak <- rbindlist(checks)
leak[, result := ifelse(n_mismatch == 0, "PASS", "FAIL")]
print(leak)
fwrite(leak, "results/C_leakage_test.csv")

# ---------- (c) training rows must end by week 52 (time split) ----------
pre_tr <- rbindlist(lapply(K_GRID, function(k) {
  s <- make_sets(ctx, k)
  r <- build_rows(ctx, s$train, k, s$train_cut, global_curves(ctx, s$train, s$train_cut), K_chosen)
  data.table(k = k, n_train_products = length(s$train), max_target_week_in_train = max(r$week),
             train_rows = nrow(r), test_launches_eligible = length(s$test))
}))
print(pre_tr)
pre_tr[, pass_cutoff_52 := max_target_week_in_train <= cfg$dev_last]
fwrite(pre_tr, "results/C_training_cutoff_check.csv")
stopifnot(all(pre_tr$pass_cutoff_52))

# ---------- write chosen K into a small record (applied in 00_config.R by hand, see DESIGN.md note) ----------
writeLines(paste0("K_chosen_on_dev=", K_chosen), "results/C_K_chosen.txt")
cat("K chosen:", K_chosen, "\n")
