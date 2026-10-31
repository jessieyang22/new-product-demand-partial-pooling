# src/13_m4_numerical_checks.R
# POST-HOC NUMERICAL AND SPECIFICATION CHECKS for the M4 fit (added after the test results had been read).
# None of these is pre-registered. None changes F1 to F7. Output names start with "Q_" (quadrature),
# "S_" (multi-start), "F3_" (nested spread test) and "N_" (netted variant, product exclusion).
#
# Part 1 (Q_): does the quadrature grid used to integrate the random effect change the M4 fit?
#   The grid is re-set for each run; the 61-point grid on [-6, 6] is the pipeline default and must
#   reproduce the saved baseline (tau, log-likelihood and test WAPE) before the other grids are read.
# Part 2 (S_): do fits from several starting values reach the same maximum? (k = 4 and k = 8)
# Part 3 (F3_): corrected test of the between-product spread. The original F3 null (design_m4 with
#   tau = 0) has no product-level term at all. This check adds the product's own mean (log1p_own) to
#   both the random-effect model and its null, so the test asks whether the spread adds anything once
#   the product's own history is in the model.
# Part 4 (N_): the netted variant with product StockCode 23166 removed from the test set.
#
# Run from the project root: Rscript src/13_m4_numerical_checks.R
# Takes a long time on a loaded laptop (the 401-point grids dominate). Each part writes its own CSV.
source("src/lib_pipeline.R")
suppressPackageStartupMessages(library(data.table))

cfg <- CFG_DEFAULT
R0 <- readRDS("data/interim/run_baseline.rds")
K_CHECK <- 4L
K_CHECK_B <- 8L

set_grid <- function(lo, hi, n) {
  z <- seq(lo, hi, length.out = n)
  assign("Z_GRID", z, envir = globalenv())
  assign("DZ", z[2] - z[1], envir = globalenv())
  assign("LOG_W_Z", dnorm(z, log = TRUE) + log(z[2] - z[1]), envir = globalenv())
  invisible(z)
}

t_start <- Sys.time()
set.seed(cfg$seed)
set_grid(-6, 6, 61)
ctx <- prepare_context(cfg)
pre <- prepare_pooled(ctx, K_GRID, cfg$K)
message("context and pooled rows built in ", round(as.numeric(difftime(Sys.time(), t_start, units = "mins")), 1), " min")

# Test rows for the two checked k values (same construction as src/03)
test_rows <- list(); glob_k <- list()
for (k in c(K_CHECK, K_CHECK_B)) {
  sets <- make_sets(ctx, k)
  glob_k[[as.character(k)]] <- pre$globs[[as.character(k)]]
  test_rows[[as.character(k)]] <- build_rows(ctx, sets$test, k, sets$test_cut, pre$globs[[as.character(k)]], cfg$K)
}
wape_test <- function(rows, pt) {
  tg <- rows[is_target == TRUE]
  sum(abs(pt - tg$y)) / sum(tg$y)
}

# ------------------------------------------------------------------
# Part 1: quadrature grids
# ------------------------------------------------------------------
grids <- list(
  list(lo = -6, hi = 6, n = 61),
  list(lo = -6, hi = 6, n = 121),
  list(lo = -6, hi = 6, n = 201),
  list(lo = -8, hi = 8, n = 321),
  list(lo = -6, hi = 6, n = 401)
)
q_rows <- list()
for (k in c(K_CHECK, K_CHECK_B)) {
  tr <- pre$rows[[as.character(k)]]
  for (g in grids) {
    set_grid(g$lo, g$hi, g$n)
    t0 <- Sys.time()
    set.seed(cfg$seed + k)
    f <- fit_m4(tr, family = cfg$family, use_re = TRUE)
    pr <- predict_m4(f, test_rows[[as.character(k)]], n_draws = 10L)
    w <- wape_test(test_rows[[as.character(k)]], pr$point)
    q_rows[[length(q_rows) + 1L]] <- data.table(
      k = k, grid_lo = g$lo, grid_hi = g$hi, grid_points = g$n,
      spacing = (g$hi - g$lo) / (g$n - 1L),
      tau = f$tau, loglik = f$loglik, convergence = f$convergence,
      test_wape_M4 = w,
      secs = round(as.numeric(difftime(Sys.time(), t0, units = "secs")))
    )
    message("Q k=", k, " grid ", g$lo, ",", g$hi, ",", g$n, " done")
    fwrite(rbindlist(q_rows), "results/Q_quadrature_check.csv")
  }
}
set_grid(-6, 6, 61)
q_tab <- rbindlist(q_rows)
print(q_tab)
# The baseline grid must reproduce the saved run
base_k4 <- R0$info[k == K_CHECK]
stopifnot(abs(q_tab[k == K_CHECK & grid_points == 61, tau] - base_k4$tau) < 1e-4)
stopifnot(abs(q_tab[k == K_CHECK & grid_points == 61, test_wape_M4] -
                R0$preds[model == "M4" & k == K_CHECK & set == "test", sum(abs(point - y)) / sum(y)]) < 1e-6)

# ------------------------------------------------------------------
# Part 2: multi-start (61-point grid)
# ------------------------------------------------------------------
s_rows <- list()
for (k in c(K_CHECK, K_CHECK_B)) {
  tr <- pre$rows[[as.character(k)]]
  X <- design_m4(tr)
  b0 <- coef(lm(log1p(tr$y) ~ X[, -1])); b0[is.na(b0)] <- 0
  for (tau0 in c(0.05, 0.5, 5)) {
    set.seed(cfg$seed + k)
    init <- c(b0, log(5), log(tau0))
    f <- fit_m4(tr, family = cfg$family, use_re = TRUE, init = init)
    s_rows[[length(s_rows) + 1L]] <- data.table(k = k, start_tau = tau0, tau = f$tau, loglik = f$loglik,
                                                theta = f$theta, convergence = f$convergence)
    fwrite(rbindlist(s_rows), "results/S_multistart_check.csv")
  }
}
s_tab <- rbindlist(s_rows)
print(s_tab)

# ------------------------------------------------------------------
# Part 3: F3, nested test with the product's own mean (log1p_own) in both models
# ------------------------------------------------------------------
f3_rows <- list()
k <- K_CHECK
tr <- pre$rows[[as.character(k)]]
X2 <- cbind(design_m4(tr), tr$log1p_own)
set.seed(cfg$seed + k)
alt <- fit_m4(tr, family = cfg$family, use_re = TRUE, X_design = X2)
set.seed(cfg$seed + k)
nul <- fit_m4(tr, family = cfg$family, use_re = FALSE, X_design = X2)
st <- max(0, 2 * (alt$loglik - nul$loglik))
f3_rows[[1]] <- data.table(
  k = k, null_model = "design_m4 + log1p_own, no random effect", alt_model = "design_m4 + log1p_own, random intercept",
  alt_tau = alt$tau, alt_loglik = alt$loglik, null_loglik = nul$loglik,
  lrt_stat = st, lrt_p_boundary = 0.5 * pchisq(st, df = 1, lower.tail = FALSE),
  alt_convergence = alt$convergence, null_convergence = nul$convergence,
  note = "post-hoc; the original F3 null (design_m4 without log1p_own) is kept in results/B_failure_criteria_F1_F3_F6_F7.csv"
)
# Reference: the original F3 comparison, re-fitted here, so the two can be read side by side
nul0 <- fit_m4(tr, family = cfg$family, use_re = FALSE)
f3_rows[[2]] <- data.table(
  k = k, null_model = "design_m4, no random effect (original F3 null)", alt_model = "design_m4, random intercept (M4)",
  alt_tau = R0$info[k == K_CHECK, tau], alt_loglik = R0$info[k == K_CHECK, m4_loglik],
  null_loglik = nul0$loglik, lrt_stat = max(0, 2 * (R0$info[k == K_CHECK, m4_loglik] - nul0$loglik)),
  lrt_p_boundary = 0.5 * pchisq(max(0, 2 * (R0$info[k == K_CHECK, m4_loglik] - nul0$loglik)), df = 1, lower.tail = FALSE),
  alt_convergence = R0$info[k == K_CHECK, m4_convergence], null_convergence = nul0$convergence,
  note = "original F3 comparison, re-fitted here as a reference"
)
f3_tab <- rbindlist(f3_rows)
print(f3_tab)
fwrite(f3_tab, "results/F3_nested_spread_check_k4.csv")

# ------------------------------------------------------------------
# Part 4: netted variant, with product 23166 removed from the test set
# ------------------------------------------------------------------
cfg_n <- modifyList(CFG_DEFAULT, list(netted = TRUE))
set_grid(-6, 6, 61)
res_n <- run_pipeline(cfg_n, ks = K_GRID, K = cfg_n$K, ks_eval = K_CHECK)
Pn <- res_n$preds[set == "test" & k == K_CHECK]
Pn[, ae := abs(point - y)]
launch_n <- res_n$ctx_launch
pid_23166 <- launch_n[StockCode == "23166", pid]
in_test_n <- length(pid_23166) == 1L && launch_n[pid == pid_23166, L] >= cfg$test_first
pw_of <- function(D) {
  s <- D[, .(A = sum(ae), Y = sum(y)), by = model]
  setNames(s$A / s$Y, s$model)
}
w_all <- pw_of(Pn)
w_ex <- if (in_test_n) pw_of(Pn[pid != pid_23166]) else w_all
n_row <- data.table(
  variant = "netted", excluded_product = "StockCode 23166 (test set only)",
  product_in_netted_test_cohort = in_test_n,
  n_test_products_all = uniqueN(Pn$pid),
  n_test_products_used = uniqueN(Pn[pid != if (in_test_n) pid_23166 else -1L, pid]),
  wape_M4_all = w_all["M4"], wape_M0_all = w_all["M0"], wape_M3_all = w_all["M3"],
  wape_M4_excl = w_ex["M4"], wape_M0_excl = w_ex["M0"], wape_M3_excl = w_ex["M3"],
  diff_M4_minus_best_all_pts = 100 * (w_all["M4"] - min(w_all["M0"], w_all["M3"])),
  diff_M4_minus_best_excl_pts = 100 * (w_ex["M4"] - min(w_ex["M0"], w_ex["M3"]))
)
print(n_row)
fwrite(n_row, "results/N_netted_excluding_23166_k4.csv")

message("all parts done in ", round(as.numeric(difftime(Sys.time(), t_start, units = "mins")), 1), " min")
