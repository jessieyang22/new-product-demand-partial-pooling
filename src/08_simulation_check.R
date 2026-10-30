# src/08_simulation_check.R  (component G)
# SIMULATION: a labelled method check, not evidence about real demand.
# Synthetic products with a known between-product spread (tau). Checks that the M4 fitting and
# prediction code recovers tau, and that partial pooling helps only when tau is large.
# Output files are named sim_* and every table here is labelled SIMULATION.
# Run from the project root: Rscript src/08_simulation_check.R
source("src/lib_pipeline.R")
suppressPackageStartupMessages(library(data.table))

sim_one <- function(tau_true, seed, n_dev = 800, n_test = 400, k = 4L) {
  set.seed(seed)
  n <- n_dev + n_test
  g <- rnorm(n, 0, tau_true)                       # true product effect
  a_log <- 0.5 * g + rnorm(n, 0, 0.5)              # noisy analog signal about the product effect
  theta_true <- 1.5
  mk <- function(ids) {
    rbindlist(lapply(ids, function(p) {
      s <- seq_len(k + H_MAX)
      mu <- exp(0.5 + 0.05 * log(s) + g[p])
      data.table(pid = p, s = s, y = rnbinom(length(s), size = theta_true, mu = mu),
                 is_target = s > k, h = s - k, log_s = log(s), analog_log = a_log[p] + 0.05 * log(s),
                 log_lp = 0, sin_s = 0, cos_s = 0, own_mean = NA_real_, own_var = NA_real_,
                 log1p_own = NA_real_, last = NA_real_, analog_raw = NA_real_, n_analog = 1L)
    }))
  }
  tr <- mk(seq_len(n_dev))
  te <- mk(n_dev + seq_len(n_test))
  f4 <- fit_m4(tr, family = "nb", use_re = TRUE)
  f4n <- fit_m4(tr, family = "nb", use_re = FALSE)
  pr <- predict_m4(f4, te)
  tg <- te[is_target == TRUE]
  m4_point <- pr$point
  # own-series baseline (M2-style: mean of own history, no pooling)
  hm <- te[is_target == FALSE, .(own = mean(y)), by = pid]
  m2_point <- hm$own[match(tg$pid, hm$pid)]
  wape <- function(p) sum(abs(p - tg$y)) / sum(tg$y)
  data.table(scenario = paste0("SIMULATION tau_true=", tau_true), seed = seed,
             tau_true = tau_true, tau_hat = f4$tau, theta_hat = f4$theta, theta_true = theta_true,
             lrt_stat = 2 * (f4$loglik - f4n$loglik), convergence = f4$convergence,
             wape_M4_sim = wape(m4_point), wape_M2_own_sim = wape(m2_point))
}
sims <- rbindlist(lapply(c(0, 0.3, 1.0), function(tt) rbindlist(lapply(1:5, function(i) sim_one(tt, seed = 20261029 + 100 * i + round(10 * tt))))))
sims[, wape_M4_minus_M2_pts := 100 * (wape_M4_sim - wape_M2_own_sim)]
fwrite(sims, "results/sim_pooling_check_by_replicate.csv")
summ <- sims[, .(label = "SIMULATION", reps = .N, tau_true = tau_true[1],
                 tau_hat_mean = mean(tau_hat), tau_hat_min = min(tau_hat), tau_hat_max = max(tau_hat),
                 wape_M4_sim_mean = mean(wape_M4_sim), wape_M2_own_sim_mean = mean(wape_M2_own_sim),
                 M4_minus_M2_pts_mean = mean(wape_M4_minus_M2_pts),
                 lrt_stat_median = median(lrt_stat)), by = tau_true]
print(summ)
fwrite(summ, "results/sim_pooling_check_summary.csv")
