# src/03_models_baselines.R  (components B: models M0 to M5g, fitted and predicted for every k)
# Runs the full baseline pipeline: cleaning, analogs, every model, development fit, test predictions.
# Also produces the M4 fit (random intercept, empirical Bayes) for each k, which 04 and 05 read.
# Run from the project root: Rscript src/03_models_baselines.R
source("src/lib_pipeline.R")
suppressPackageStartupMessages(library(data.table))
dir.create("data/interim", showWarnings = FALSE, recursive = TRUE)

cfg <- CFG_DEFAULT
res <- run_pipeline(cfg, ks = K_GRID, K = cfg$K, ks_eval = K_GRID)
saveRDS(list(preds = res$preds, info = res$info, counts = res$counts, fits = res$fits,
             m3_coef = res$m3_coef, m3_theta = res$m3_theta, m3_rows = res$m3_rows,
             launch = res$ctx_launch, K = res$K),
        "data/interim/run_baseline.rds")

fwrite(res$info, "results/B_per_k_run_info.csv")
fwrite(data.table(term = names(res$m3_coef), estimate = as.numeric(res$m3_coef)),
       "results/B_M3_pooled_glm_coefficients.csv")
fit_rows <- rbindlist(lapply(names(res$fits), function(k) {
  f <- res$fits[[k]]
  data.table(k = as.integer(k), tau = f$tau, theta = f$theta, loglik = f$loglik,
             convergence = f$convergence, message = f$message, n_rows = f$n_rows, n_products = f$n_products,
             beta_intercept = f$beta[1], beta_log_s = f$beta[2], beta_analog_log = f$beta[3],
             beta_log_price = f$beta[4], beta_season_sin = f$beta[5], beta_season_cos = f$beta[6])
}))
fwrite(fit_rows, "results/B_M4_fit_by_k.csv")
cat("M3 theta:", res$m3_theta, " M3 rows:", res$m3_rows, "\n")
print(res$info[, .(k, n_train_products, n_test_products, tau, m4_convergence, fb_analog_train, fb_analog_test)])
cat("Run complete. Predictions rows:", nrow(res$preds), "\n")
