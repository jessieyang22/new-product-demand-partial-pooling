# src/05_cold_start_eval.R  (component B metrics, primary decision, F1 to F3, F6, F7)
# Reads the test predictions written by 03_models_baselines.R. Test set only, after the protocol lock.
# Run from the project root: Rscript src/05_cold_start_eval.R
source("src/lib_pipeline.R")
suppressPackageStartupMessages(library(data.table))
set.seed(CFG_DEFAULT$seed)
B_BOOT <- 2000L

R <- readRDS("data/interim/run_baseline.rds")
P <- R$preds[set == "test"]
P[, abs_err := abs(point - y)]
P[, is80 := (q90 - q10) + (2 / 0.2) * (q10 - y) * (y < q10) + (2 / 0.2) * (y - q90) * (y > q90)]

metric_tab <- function(D) D[, .(
  n_rows = .N, n_products = uniqueN(pid),
  wape = sum(abs_err) / sum(y), bias = mean(point - y),
  cov80_draws = mean(y >= q10 & y <= q90), cov50_draws = mean(y >= q25 & y <= q75),
  width80_draws = mean(q90 - q10), width50_draws = mean(q75 - q25),
  interval_score80_draws = mean(is80), crps = mean(crps)
), by = .(model, k)]

pooled <- metric_tab(P)
byh <- P[, c(metric_tab(.SD)), by = h]
fwrite(pooled, "results/B_cold_start_metrics_pooled_h1to4.csv")
fwrite(byh, "results/B_cold_start_metrics_by_h.csv")

wide_k <- dcast(pooled, k ~ model, value.var = "wape")
print(wide_k)
fwrite(wide_k, "results/B_cold_start_wape_curve.csv")

# ---- product-clustered bootstrap for a difference in pooled WAPE at a given k ----
# per product sums over h = 1..4: absolute error and actual units, for every model
product_sums <- function(D, k_val) {
  Dk <- D[k == k_val]
  Dk[, .(A = sum(abs_err), Y = sum(y)), by = .(model, pid)]
}
boot_setup <- function(ps, models) {
  pids <- sort(unique(ps$pid))
  Y <- ps[model == models[1], .(Y = Y[match(pids, pid)])]$Y
  A <- sapply(models, function(m) ps[model == m, A[match(pids, pid)]])
  colnames(A) <- models
  list(pids = pids, Y = Y, A = A)
}
boot_draws <- function(bs, B = B_BOOT, seed = CFG_DEFAULT$seed) {
  set.seed(seed)
  n <- length(bs$Y)
  idx <- matrix(sample.int(n, n * B, replace = TRUE), nrow = n)
  Yb <- colSums(matrix(bs$Y[idx], nrow = n))
  Ab <- t(sapply(seq_len(ncol(bs$A)), function(j) colSums(matrix(bs$A[idx, j], nrow = n))))
  rownames(Ab) <- colnames(bs$A)
  W <- sweep(Ab, 2, Yb, "/")   # models x B, WAPE in each resample
  W
}
primary_contrast <- function(ps, k_val, target = "M4", comps = c("M0", "M3")) {
  bs <- boot_setup(ps, c(target, comps))
  W <- boot_draws(bs)
  point_w <- colSums(bs$A) / sum(bs$Y)
  best_point <- min(point_w[comps])
  diff_point <- point_w[target] - best_point
  best_b <- apply(W[comps, , drop = FALSE], 2, min)
  diff_b <- W[target, ] - best_b
  data.table(k = k_val, target = target, comparators = paste(comps, collapse = "/"),
             wape_target = point_w[target], wape_best_comparator = best_point,
             wape_comparators = paste(sprintf("%s=%.4f", comps, point_w[comps]), collapse = " "),
             diff_pts = 100 * diff_point,
             ci_low_pts = 100 * quantile(diff_b, 0.025), ci_high_pts = 100 * quantile(diff_b, 0.975),
             n_products = length(bs$Y))
}

prim <- primary_contrast(product_sums(P, 4L), 4L, "M4", c("M0", "M3"))
prim[, decision_F1_M4_better := diff_pts <= -3 & ci_high_pts < 0]
print(prim)
fwrite(prim, "results/B_primary_k4_M4_vs_best_of_M0_M3.csv")

# Secondary contrasts at k = 4 (no decision attached)
sec <- rbindlist(list(
  primary_contrast(product_sums(P, 4L), 4L, "M4", "M1"),
  primary_contrast(product_sums(P, 4L), 4L, "M4", "M2"),
  primary_contrast(product_sums(P, 4L), 4L, "M4", "M5"),
  primary_contrast(product_sums(P, 4L), 4L, "M3", "M0"),
  primary_contrast(product_sums(P, 4L), 4L, "M5", "M5g")
))
fwrite(sec, "results/B_secondary_contrasts_k4.csv")
print(sec[, .(k, target, comparators, wape_target, wape_best_comparator, diff_pts, ci_low_pts, ci_high_pts)])

# ---- F2: analog-only prior M5 vs global-average prior M5g at k = 4 ----
w4 <- pooled[k == 4L, .(model, wape)]
f2_m5 <- w4[model == "M5", wape]; f2_g <- w4[model == "M5g", wape]
f2_triggered <- f2_m5 >= f2_g

# ---- F3: between-product spread tau versus zero (k = 4 likelihood-ratio test, boundary) ----
d4 <- fread("results/D_tau_test_by_k.csv")
f3_p <- d4[k == 4L, lrt_p_boundary]
f3_triggered <- f3_p >= 0.05

# ---- F6: sample size at k = 12 ----
n12 <- R$info[k == 12L, n_test_products]
f6_triggered <- n12 < 500

# ---- F7: optimiser convergence of the M4 fit (empirical Bayes; Bayesian fit not run) ----
f7_bad <- R$info[m4_convergence != 0, k]
f7_triggered <- length(f7_bad) > 0

fail <- data.table(
  criterion = c("F1 M4 beats best of M0/M3 at k=4 by >=3 pts with CI excluding 0",
                "F2 analog-only M5 not better than global-average M5g at k=4",
                "F3 tau indistinguishable from zero (LRT p >= 0.05 at k=4)",
                "F6 fewer than 500 test launches at k=12 (4 target weeks)",
                "F7 M4 optimiser did not converge at any k"),
  triggered = c(!prim$decision_F1_M4_better, f2_triggered, f3_triggered, f6_triggered, f7_triggered),
  evidence = c(sprintf("diff=%.2f pts, CI [%.2f, %.2f], M4 WAPE %.4f, best comparator %.4f",
                       prim$diff_pts, prim$ci_low_pts, prim$ci_high_pts, prim$wape_target, prim$wape_best_comparator),
               sprintf("WAPE M5=%.4f, M5g=%.4f", f2_m5, f2_g),
               sprintf("LRT boundary p at k=4 = %.4g, tau = %.4f", f3_p, d4[k == 4L, tau]),
               sprintf("test launches with k=12 and 4 targets = %d", n12),
               if (f7_triggered) paste("k:", paste(f7_bad, collapse = ",")) else "all k converged (optim code 0)")
)
print(fail)
fwrite(fail, "results/B_failure_criteria_F1_F3_F6_F7.csv")

# ---- POST-HOC CHECK (added after the test results had been read; NOT one of the pre-registered F1 to F7) ----
# The pre-registered F7 uses only the optimiser code. That check does not catch the failure seen at
# k = 8, 12, 16, 20, where the optimiser returned code 0 but the random-effect spread diverged
# (tau in the order of 1e8 to 1e9) and the marginal log-likelihood fell below the nested model with
# no random effect. Such a fit is treated as failed here. It is reported, not repaired (DESIGN.md section 6, F7).
post <- R$info[, .(k, tau, m4_loglik, m4_null_loglik,
                   loglik_below_nested = m4_loglik < m4_null_loglik,
                   tau_above_10 = tau > 10)]
post[, posthoc_failed := loglik_below_nested | tau_above_10]
print(post)
fwrite(post, "results/B_posthoc_M4_fit_sanity_by_k.csv")
