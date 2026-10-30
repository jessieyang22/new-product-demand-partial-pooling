# src/06_calibration.R  (component E)
# Interval coverage and sharpness before and after split-conformal recalibration.
# The width scale per model, k and nominal level is set on the development (train-set) predictions,
# then applied once to the test predictions. Development predictions for M3 and M4 are in-sample.
# Run from the project root: Rscript src/06_calibration.R
source("src/lib_pipeline.R")
suppressPackageStartupMessages(library(data.table))

R <- readRDS("data/interim/run_baseline.rds")
P <- R$preds
SCALE_GRID <- seq(0, 8, by = 0.01)

cov_fun <- function(lo, hi, y) mean(y >= lo & y <= hi)
scaled <- function(D, level) {
  if (level == 0.8) { lo0 <- D$q10; hi0 <- D$q90 } else { lo0 <- D$q25; hi0 <- D$q75 }
  list(lo0 = lo0, hi0 = hi0, med = D$q50)
}
rescale <- function(D, level, c) {
  s <- scaled(D, level)
  lo <- s$med - c * (s$med - s$lo0)
  hi <- s$med + c * (s$hi0 - s$med)
  list(lo = lo, hi = hi)
}
find_c <- function(D, level) {
  nominal <- level
  for (cc in SCALE_GRID) {
    r <- rescale(D, level, cc)
    if (cov_fun(r$lo, r$hi, D$y) >= nominal) return(cc)
  }
  NA_real_
}

rows <- list()
for (m in unique(P$model)) for (kk in K_GRID) {
  dev <- P[model == m & k == kk & set == "train"]
  tst <- P[model == m & k == kk & set == "test"]
  for (level in c(0.8, 0.5)) {
    c_hat <- find_c(dev, level)
    raw <- scaled(tst, level)
    dev_raw_cov <- cov_fun(raw$lo0, raw$hi0, tst$y)
    if (is.na(c_hat)) {
      r <- list(lo = raw$lo0, hi = raw$hi0)
    } else {
      r <- rescale(tst, level, c_hat)
    }
    dev_cov_raw <- cov_fun(scaled(dev, level)$lo0, scaled(dev, level)$hi0, dev$y)
    rows[[length(rows) + 1L]] <- data.table(
      model = m, k = kk, nominal = level, n_test_rows = nrow(tst),
      scale_c = c_hat, dev_coverage_raw = dev_cov_raw,
      test_coverage_raw = dev_raw_cov,
      test_width_raw = mean(raw$hi0 - raw$lo0),
      test_coverage_conformal = cov_fun(r$lo, r$hi, tst$y),
      test_width_conformal = mean(r$hi - r$lo),
      test_interval_score80_conformal = if (level == 0.8) mean((r$hi - r$lo) + (2 / 0.2) * (r$lo - tst$y) * (tst$y < r$lo) + (2 / 0.2) * (tst$y - r$hi) * (tst$y > r$hi)) else NA_real_
    )
  }
}
cal <- rbindlist(rows)
fwrite(cal, "results/E_calibration_before_after_conformal.csv")
print(cal[nominal == 0.8 & model %in% c("M0", "M3", "M4", "M5", "M5g")])

# F4: M4 80% interval after recalibration, test coverage must lie in [0.72, 0.88] (k = 4, pooled h = 1..4)
f4 <- cal[model == "M4" & k == 4L & nominal == 0.8]
f4_ok <- f4$test_coverage_conformal >= 0.72 & f4$test_coverage_conformal <= 0.88
fail4 <- data.table(criterion = "F4 M4 80% interval after conformal recalibration has test coverage outside 0.72 to 0.88 (k=4)",
                    triggered = !f4_ok,
                    evidence = sprintf("test coverage after recalibration %.4f (raw %.4f), scale c = %s",
                                       f4$test_coverage_conformal, f4$test_coverage_raw, f4$scale_c))
print(fail4)
fwrite(fail4, "results/E_failure_criterion_F4.csv")
