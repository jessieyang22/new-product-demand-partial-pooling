# src/04_pooling_diagnostics.R  (component D)
# Between-product spread (tau), its likelihood-ratio test against zero, and how much each test
# product's forecast relies on its own weeks versus the pooled prior (shrinkage).
# Run from the project root: Rscript src/04_pooling_diagnostics.R
source("src/lib_pipeline.R")
suppressPackageStartupMessages(library(data.table))

R <- readRDS("data/interim/run_baseline.rds")
info <- R$info
diag_k <- info[, .(k, tau, theta_m4, m4_loglik, m4_null_loglik, lrt_stat, lrt_p_boundary,
                   m4_convergence, m4_null_convergence, n_train_products)]
diag_k[, tau_distinguishable_from_zero := lrt_p_boundary < 0.05]
fwrite(diag_k, "results/D_tau_test_by_k.csv")
print(diag_k)

# Shrinkage at k = 4 (test products): rebuild the same objects the baseline run used
cfg <- CFG_DEFAULT
set.seed(cfg$seed)
ctx <- prepare_context(cfg)
pre <- prepare_pooled(ctx, K_GRID, cfg$K)
sets <- make_sets(ctx, 4L)
tr <- pre$rows[["4"]]
glob <- pre$globs[["4"]]
f4 <- R$fits[["4"]]
te <- build_rows(ctx, sets$test, 4L, sets$test_cut, glob, cfg$K)
pr <- predict_m4(f4, te)
own <- te[, .(own_mean = mean(y[!is_target])), by = pid]
sh <- data.table(pid = pr$pids, u_post_mean = pr$u_post_mean, u_post_sd = pr$u_post_sd)
sh <- merge(sh, own, by = "pid")
sh[, shrink_own_data := 1 - (u_post_sd / f4$tau)^2]     # share of prior spread removed by own weeks
sh[, log_own_mean := log1p(own_mean)]
summ <- data.table(
  k = 4L, tau = f4$tau, n_test_products = nrow(sh),
  median_shrink_own_data = median(sh$shrink_own_data),
  q25_shrink_own_data = quantile(sh$shrink_own_data, 0.25),
  q75_shrink_own_data = quantile(sh$shrink_own_data, 0.75),
  corr_posterior_u_vs_log_own_mean = cor(sh$u_post_mean, sh$log_own_mean),
  median_abs_posterior_u = median(abs(sh$u_post_mean))
)
print(summ)
fwrite(summ, "results/D_shrinkage_summary_k4.csv")
fwrite(sh, "results/D_shrinkage_by_test_product_k4.csv")
