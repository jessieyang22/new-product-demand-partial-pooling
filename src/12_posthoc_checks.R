# src/12_posthoc_checks.R
# POST-HOC DESCRIPTIVE CHECKS (added after the test results had been read). None of these is
# pre-registered, and none changes F1 to F7. Each output file name starts with "P_".
#
# (a) Conformal step check: how coarse is the recalibration scale for 80% intervals?
# (b) Leave-one-product-out check: does any single excluded product change the sign of the
#     k = 4 comparison of M4 against the better of M0 and M3 on the test set?
# (c) Data facts quoted in README section 5.5 and section 7, recomputed from the cleaned lines.
#
# Uses data/interim/run_baseline.rds (written by src/03) and data/interim/lines_combined.rds.
# Run from the project root: Rscript src/12_posthoc_checks.R
source("src/lib_pipeline.R")
suppressPackageStartupMessages(library(data.table))

R <- readRDS("data/interim/run_baseline.rds")
P <- R$preds
cfg <- CFG_DEFAULT

# ------------------------------------------------------------------
# (a) Conformal step check, k = 4, 80% level, models M0 and M4
# ------------------------------------------------------------------
cov_at <- function(D, c) {
  lo <- D$q50 - c * (D$q50 - D$q10)
  hi <- D$q50 + c * (D$q90 - D$q50)
  mean(D$y >= lo & D$y <= hi)
}
c_grid <- sort(unique(c(seq(0.90, 1.10, by = 0.01), 0.995, 0.999, 1.000, 1.001)))
step_rows <- list()
for (m in c("M0", "M4")) {
  for (st in c("train", "test")) {
    D <- P[model == m & k == 4L & set == st]
    step_rows[[length(step_rows) + 1L]] <- data.table(
      model = m, set = st, c = c_grid,
      coverage80 = vapply(c_grid, function(cc) cov_at(D, cc), numeric(1)),
      share_y_equal_q10 = mean(D$y == D$q10),
      share_y_equal_q90 = mean(D$y == D$q90),
      n_rows = nrow(D)
    )
  }
}
step_tab <- rbindlist(step_rows)
fwrite(step_tab, "results/P_conformal_step_check_k4.csv")
print(step_tab[c %in% c(0.95, 0.99, 0.999, 1.000, 1.001, 1.05), .(model, set, c, coverage80)])
print(step_tab[c == 1.000, .(model, set, share_y_equal_q10, share_y_equal_q90, n_rows)])

# ------------------------------------------------------------------
# (b) Leave-one-product-out, k = 4, test set
# For each test product p, drop p from both models and recompute
# WAPE(M4) - min(WAPE(M0), WAPE(M3)) in percentage points.
# ------------------------------------------------------------------
Q <- P[k == 4L & set == "test"]
Q[, ae := abs(point - y)]
tot <- Q[, .(A = sum(ae), Y = sum(y)), by = .(model, pid)]
wide_A <- dcast(tot, pid ~ model, value.var = "A", fill = 0)
wide_Y <- dcast(tot, pid ~ model, value.var = "Y", fill = 0)
A_all <- colSums(wide_A[, -1]); Y_all <- sum(wide_Y$M4)
base_diff <- 100 * (A_all["M4"] / Y_all - min(A_all["M0"], A_all["M3"]) / Y_all)
loo <- rbindlist(lapply(seq_len(nrow(wide_A)), function(i) {
  A_m <- A_all - unlist(wide_A[i, -1]); Y_m <- Y_all - wide_Y$M4[i]
  d <- 100 * (A_m["M4"] / Y_m - min(A_m["M0"], A_m["M3"]) / Y_m)
  data.table(pid = wide_A$pid[i], diff_pts_without_product = d)
}))
loo <- merge(loo, unique(Q[, .(pid, StockCode)]), by = "pid")
loo[, flips_sign := diff_pts_without_product < 0]
loo_summary <- data.table(
  n_test_products = nrow(loo), baseline_diff_pts = base_diff,
  n_single_exclusions_flipping_sign = sum(loo$flips_sign),
  min_diff_pts = min(loo$diff_pts_without_product), median_diff_pts = median(loo$diff_pts_without_product),
  max_diff_pts = max(loo$diff_pts_without_product),
  stockcodes_flipping_sign = paste(loo[flips_sign == TRUE, StockCode], collapse = ";")
)
print(loo_summary)
fwrite(loo, "results/P_leave_one_product_out_k4.csv")
fwrite(loo_summary, "results/P_leave_one_product_out_summary_k4.csv")

# ------------------------------------------------------------------
# (c) Data facts for README sections 5.5 and 7
# ------------------------------------------------------------------
cl <- load_clean_lines(cfg)
x <- cl$lines
raw_facts <- readRDS(file.path("data", "interim", "lines_combined.rds"))
setDT(raw_facts)
f <- raw_facts[StockCode == "23166" & Invoice %in% c("541431", "C541433"),
               .(Invoice, inv_date, Quantity, Price, Country)]
print(f)
fact_rows <- data.table(
  fact = c("product 23166: quantity on invoice 541431",
           "product 23166: quantity on credit invoice C541433",
           "invoice 541431 date", "credit C541433 date"),
  value_text = c(as.character(sum(f[Invoice == "541431", Quantity])),
                 as.character(sum(f[Invoice == "C541433", Quantity])),
                 as.character(as.Date(f[Invoice == "541431", inv_date][1])),
                 as.character(as.Date(f[Invoice == "C541433", inv_date][1])))
)

# Weekly units per launch product: sum of positive sales-line quantities, weeks L to 105 (as in src/lib)
dem <- x[, .(units = max(0, sum(units_line))), by = .(StockCode, week)]
coh <- fread("results/A_launch_cohort.csv")
mean_w <- dem[StockCode %in% coh$StockCode]
mean_w <- merge(mean_w, coh[, .(StockCode, L = launch_week)], by = "StockCode")
mean_w <- mean_w[week >= L]
pm <- mean_w[, .(sum_units = sum(units)), by = StockCode]
pm <- merge(coh[, .(StockCode, pid, split)], pm, by = "StockCode", all.x = TRUE)
pm[is.na(sum_units), sum_units := 0]
pm <- merge(pm, coh[, .(StockCode, L = launch_week)], by = "StockCode")
pm[, n_weeks := LAST_WEEK - L + 1L]
pm[, mean_units_per_week := sum_units / n_weeks]
print(summary(pm$mean_units_per_week))
fwrite(pm, "results/P_launch_product_mean_units_per_week.csv")
fact_rows <- rbindlist(list(fact_rows,
  data.table(fact = c("launch products: min mean units per week (weeks L to 105)",
                      "launch products: max mean units per week (weeks L to 105)",
                      "launch products: max mean units per week, test split",
                      "launch products: number of launch products"),
             value_text = c(sprintf("%.4f", min(pm$mean_units_per_week)),
                            sprintf("%.2f", max(pm$mean_units_per_week)),
                            sprintf("%.2f", max(pm[split == "test", mean_units_per_week])),
                            as.character(nrow(pm))))))
fwrite(fact_rows, "results/P_data_facts.csv")
print(fact_rows)
