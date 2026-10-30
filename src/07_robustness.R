# src/07_robustness.R  (component F)
# Re-runs the whole pipeline with one setting changed, at k = 4 only, and recomputes the primary
# contrast (M4 vs the better of M0 and M3). F5: the result is fragile if the sign or the ranking of
# M4 against M0 and M3 changes in any variant. The random-split run is a warning check only and
# is not used for the F5 decision.
# Run from the project root: Rscript src/07_robustness.R
source("src/lib_pipeline.R")
suppressPackageStartupMessages(library(data.table))
source_boot <- function() NULL

# same bootstrap helpers as 05 (kept here so 07 can run on its own)
boot_setup <- function(ps, models) {
  pids <- sort(unique(ps$pid))
  Yv <- ps[model == models[1], .(Yc = Y[match(pids, pid)])]$Yc
  A <- sapply(models, function(m) ps[model == m, A[match(pids, pid)]])
  colnames(A) <- models
  list(pids = pids, Y = Yv, A = A)
}
boot_draws <- function(bs, B = 2000L, seed = CFG_DEFAULT$seed) {
  set.seed(seed)
  n <- length(bs$Y)
  idx <- matrix(sample.int(n, n * B, replace = TRUE), nrow = n)
  Yb <- colSums(matrix(bs$Y[idx], nrow = n))
  Ab <- t(sapply(seq_len(ncol(bs$A)), function(j) colSums(matrix(bs$A[idx, j], nrow = n))))
  rownames(Ab) <- colnames(bs$A)
  sweep(Ab, 2, Yb, "/")
}

run_variant <- function(name, over) {
  cfg <- modifyList(CFG_DEFAULT, over)
  t0 <- Sys.time()
  res <- run_pipeline(cfg, ks = K_GRID, K = cfg$K, ks_eval = 4L)
  P <- res$preds[set == "test" & k == 4L]
  P[, abs_err := abs(point - y)]
  ps <- P[, .(A = sum(abs_err), Y = sum(y)), by = .(model, pid)]
  bs <- boot_setup(ps, c("M4", "M0", "M3"))
  W <- boot_draws(bs)
  pw <- colSums(bs$A) / sum(bs$Y)
  best_p <- min(pw["M0"], pw["M3"])
  best_b <- apply(W[c("M0", "M3"), , drop = FALSE], 2, min)
  diff_b <- W["M4", ] - best_b
  rank_order <- paste(names(sort(pw[c("M4", "M0", "M3")])), collapse = " < ")
  info4 <- res$info[k == 4L]
  out <- data.table(variant = name, setting = paste(names(over), unlist(over), sep = "=", collapse = "; "),
                    split = cfg$split, n_test_products = uniqueN(P$pid),
                    n_train_products = info4$n_train_products, tau_m4 = info4$tau,
                    wape_M4 = pw["M4"], wape_M0 = pw["M0"], wape_M3 = pw["M3"],
                    diff_M4_minus_best_pts = 100 * (pw["M4"] - best_p),
                    ci_low_pts = 100 * quantile(diff_b, 0.025), ci_high_pts = 100 * quantile(diff_b, 0.975),
                    ranking_low_to_high_WAPE = rank_order,
                    secs = round(as.numeric(difftime(Sys.time(), t0, units = "secs"))))
  message(name, " done in ", out$secs, " s")
  out
}

vars <- lapply(names(CFG_VARIANTS), function(nm) run_variant(nm, CFG_VARIANTS[[nm]]))
rob <- rbindlist(vars)
base <- rob[variant == "baseline"]
rob[, sign_same_as_baseline := sign(diff_M4_minus_best_pts) == sign(base$diff_M4_minus_best_pts)]
rob[, ranking_same_as_baseline := ranking_low_to_high_WAPE == base$ranking_low_to_high_WAPE]
rob[, counts_for_F5 := split == "time"]
f5 <- rob[counts_for_F5 == TRUE & (!sign_same_as_baseline | !ranking_same_as_baseline)]
print(rob[, .(variant, n_test_products, wape_M4, wape_M0, wape_M3, diff_M4_minus_best_pts,
              ci_low_pts, ci_high_pts, ranking_low_to_high_WAPE, sign_same_as_baseline, ranking_same_as_baseline)])
fwrite(rob, "results/F_robustness_k4.csv")
f5_row <- data.table(criterion = "F5 sign or ranking of M4 vs M0/M3 changes in any time-split robustness variant (k=4)",
                     triggered = nrow(f5) > 0,
                     evidence = if (nrow(f5) > 0) paste("changed in:", paste(f5$variant, collapse = ", ")) else "no change in sign or ranking across time-split variants")
print(f5_row)
fwrite(f5_row, "results/F_failure_criterion_F5.csv")
